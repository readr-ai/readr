package com.readrai.readr.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.readrai.readr.kit.KitLimits
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/**
 * One inline image, sized for the page it is about to be laid into: the id its
 * annotation carries, the [Placeholder] the text is *measured* with, and where
 * its bytes are. The picture itself is **not** here: the placeholder is fixed
 * the moment the bounds are read, and the bitmap arrives afterwards into a
 * map the page draws from, so a picture landing never re-measures a page.
 *
 * `hasPicture` is false when the archive holds no such entry (or it decodes to
 * nothing) — that image still takes a placeholder, one line tall, holding its
 * alt text, so the page that was measured is the page that is drawn either way.
 */
class InlineImage(
    val id: String,
    val utf16Offset: Int,
    val archivePath: String,
    val placeholder: Placeholder,
    /**
     * The line height the paragraph holding this image is given. Every
     * paragraph on the page carries an explicit line height, and Compose
     * forces a line to the height it is told — so an image's own line has to
     * be told to be as tall as the picture, or the picture is squeezed.
     */
    val lineHeight: TextUnit,
    /** True when there are bytes behind it, so a bitmap is on its way. */
    val hasPicture: Boolean,
    val alt: String,
)

/**
 * The pictures inside a book. The kit leaves an image as a U+FFFC placeholder
 * in the chapter text plus an entry path into the book's retained original;
 * the bytes never cross the bridge (a chapter of plates would be megabytes of
 * JSON), so the reader opens the archive itself, here.
 *
 * The work is in two halves on purpose. [place] opens the archive **once** and
 * reads nothing but each image's header, which is what fixes the placeholders
 * and therefore the pagination; [load] decodes the bitmaps afterwards, in
 * parallel, into a map the page draws from. So a chapter of plates paginates
 * at header speed and the pictures fill in behind it without moving a line.
 *
 * Everything an untrusted archive can do is bounded: an entry is read only up
 * to the kit's own per-entry ceiling ([KitLimits.epubPerEntryByteCap], read
 * through the bridge so the two cannot drift), a path that names no entry
 * yields null rather than an exception (and is remembered as missing, so a
 * broken chapter does not re-open the archive on every geometry change), and
 * the decode is down-sampled so a 6000-pixel plate never becomes a 140 MB
 * bitmap.
 */
object ChapterImages {
    private const val TAG = "Readr.Images"

    /** Decoded bitmaps, bounded by the bytes they hold rather than by their number. */
    const val CACHE_BYTES = 24 * 1024 * 1024

    /**
     * No single picture may take more than this. A plate that would is
     * down-sampled further until it fits: one image that filled the cache
     * would evict every other picture in the chapter on its way in.
     */
    private const val PER_IMAGE_BYTES = CACHE_BYTES / 4

    /** How many entries are decoded at once — enough to use the disk, few enough to bound the peak. */
    private const val DECODE_PARALLELISM = 3

    /** Air below an image's line, so the forced line height never clips the picture. */
    private val lineGap = 4.dp

    /**
     * The margin the page keeps below the tallest image. Shared with the
     * reading surface, which takes the same band off the measured page height:
     * two constants would be two different ideas of where a page ends.
     */
    val pageMargin = 4.dp

    private val perEntryCap: Long by lazy { KitLimits.epubPerEntryByteCap() }

    /**
     * Keyed by book, entry and the sample size it was decoded at: the same
     * picture at two column widths may be two bitmaps, and a re-import is a
     * new book id, so nothing here can outlive the bytes it came from.
     */
    private val cache = object : LruCache<String, Decoded>(CACHE_BYTES) {
        override fun sizeOf(key: String, value: Decoded): Int = value.bitmap.byteCount

        override fun entryRemoved(evicted: Boolean, key: String, oldValue: Decoded, newValue: Decoded?) {
            // Deliberately nothing. An evicted bitmap may still be on screen —
            // Compose holds the `ImageBitmap` for as long as a page draws it —
            // and recycling under it draws a hole (or throws). Dropping the
            // cache's own reference is the whole of the eviction; the pixels
            // go when the last drawer lets go of them.
        }
    }

    /**
     * What the archive says an entry's picture measures, read from its header
     * alone. [missing] stands for "no such entry, or nothing decodable in it"
     * and is remembered like any other answer, so a book with a broken plate
     * does not re-open its archive every time the geometry changes.
     */
    class Bounds(val width: Int, val height: Int) {
        val isMissing: Boolean get() = width <= 0 || height <= 0

        companion object {
            val missing = Bounds(0, 0)
        }
    }

    /** Header sizes already read, keyed by book and entry — including the misses. */
    private val bounds = ConcurrentHashMap<String, Bounds>()

    /** A decoded bitmap and the size of the image it was decoded from, in source pixels. */
    class Decoded(val bitmap: Bitmap, val sourceWidth: Int, val sourceHeight: Int) {
        val image: ImageBitmap by lazy { bitmap.asImageBitmap() }
    }

    /** Forgets every decoded bitmap and every remembered size; for tests, and for a shelf that just lost a book. */
    fun clearCache() {
        cache.evictAll()
        bounds.clear()
    }

    /**
     * The chapter's images, sized for a page `textWidthPx` wide and
     * `pageHeightPx` tall — header reads only, so this is cheap enough to run
     * on every geometry change. Runs on the IO dispatcher: it opens a zip.
     *
     * Sizing follows the Apple reader's `fittedBounds`: where the markup
     * declares both dimensions the aspect is theirs; where it declares only a
     * height the width comes back through the source's aspect (and the other
     * way round); where it declares neither the image's own pixels are read as
     * dp. The result is then fitted to the text column, and an image taller
     * than the page is scaled down — by height — until its whole line fits one.
     */
    suspend fun place(
        archive: File?,
        bookId: String,
        images: List<ChapterImage>,
        density: Density,
        textWidthPx: Int,
        pageHeightPx: Int,
        fallbackLineHeightPx: Float,
    ): List<InlineImage> = withContext(Dispatchers.IO) {
        if (images.isEmpty()) return@withContext emptyList()
        val sizes = measureAll(archive, bookId, images.map { it.archivePath })
        images.map { image ->
            inline(image, sizes[image.archivePath], density, textWidthPx, pageHeightPx, fallbackLineHeightPx)
        }
    }

    /**
     * Decodes the pictures behind `images` and hands each one over as it
     * lands, by placeholder id. One coroutine per entry, a few at a time:
     * the pages are already measured and drawn, so every bitmap that arrives
     * only fills a box that was there all along.
     */
    suspend fun load(
        archive: File?,
        bookId: String,
        images: List<InlineImage>,
        columnWidthPx: Int,
        onDecoded: (String, ImageBitmap) -> Unit,
    ) {
        if (archive == null) return
        val wanted = images.filter { it.hasPicture }
        if (wanted.isEmpty()) return
        val gate = Semaphore(DECODE_PARALLELISM)
        withContext(Dispatchers.IO) {
            coroutineScope {
                wanted.map { image ->
                    async {
                        val decoded = gate.withPermit { decode(archive, bookId, image.archivePath, columnWidthPx) }
                        if (decoded != null) withContext(Dispatchers.Main) { onDecoded(image.id, decoded.image) }
                    }
                }.awaitAll()
            }
        }
    }

    /**
     * The header sizes for `paths`, reading the archive once for all of them
     * that are not already known. A path that names no entry (or whose header
     * says nothing) is remembered as [Bounds.missing]; nothing is remembered
     * when there is no archive to ask, since one may yet arrive.
     */
    private fun measureAll(archive: File?, bookId: String, paths: List<String>): Map<String, Bounds> {
        val known = HashMap<String, Bounds>()
        val wanted = LinkedHashSet<String>()
        for (path in paths) {
            val cached = bounds["$bookId|$path"]
            if (cached != null) known[path] = cached else wanted += path
        }
        if (wanted.isEmpty()) return known
        if (archive == null || !archive.isFile) {
            for (path in wanted) known[path] = Bounds.missing
            return known
        }
        try {
            ZipFile(archive).use { zip ->
                for (path in wanted) {
                    val measured = measure(zip, path)
                    bounds["$bookId|$path"] = measured
                    known[path] = measured
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "archive unreadable: ${e.javaClass.simpleName}")
        } catch (e: SecurityException) {
            Log.w(TAG, "archive refused: ${e.javaClass.simpleName}")
        }
        for (path in wanted) known.getOrPut(path) { Bounds.missing }
        return known
    }

    /**
     * One entry's pixel size, from its header. `inJustDecodeBounds` reads only
     * as far into the stream as the format's header, so a chapter of plates
     * costs a few kilobytes rather than a few megabytes.
     */
    private fun measure(zip: ZipFile, archivePath: String): Bounds {
        val entry = zip.getEntry(archivePath) ?: return Bounds.missing
        if (entry.size > perEntryCap) return Bounds.missing
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            zip.getInputStream(entry).use { BitmapFactory.decodeStream(it, null, options) }
        } catch (e: IOException) {
            Log.w(TAG, "image header unreadable: ${e.javaClass.simpleName}")
            return Bounds.missing
        }
        return if (options.outWidth > 0 && options.outHeight > 0) {
            Bounds(options.outWidth, options.outHeight)
        } else {
            Bounds.missing
        }
    }

    private fun inline(
        image: ChapterImage,
        source: Bounds?,
        density: Density,
        textWidthPx: Int,
        pageHeightPx: Int,
        fallbackLineHeightPx: Float,
    ): InlineImage = with(density) {
        val id = "image-${image.utf16Offset}"
        val alt = image.alt.orEmpty().trim()
        val gapPx = lineGap.toPx()
        if (source == null || source.isMissing) {
            // Nothing to draw: one line, holding the alt text (or a rule).
            val height = maxOf(1f, fallbackLineHeightPx)
            return@with InlineImage(
                id = id,
                utf16Offset = image.utf16Offset,
                archivePath = image.archivePath,
                placeholder = Placeholder(textWidthPx.toFloat().toSp(), height.toSp(), PlaceholderVerticalAlign.Center),
                lineHeight = (height + gapPx).toSp(),
                hasPicture = false,
                alt = alt,
            )
        }
        val column = maxOf(1f, textWidthPx.toFloat())
        val sourceAspect = source.height.toFloat() / source.width.toFloat()
        val declaredWidth = image.displayWidth?.takeIf { it > 0.0 }?.toFloat()
        val declaredHeight = image.displayHeight?.takeIf { it > 0.0 }?.toFloat()
        // Both declared: the markup states the shape, and it wins over the
        // bitmap's. One declared: the other comes back through the source's.
        val aspect = if (declaredWidth != null && declaredHeight != null) {
            declaredHeight / declaredWidth
        } else {
            sourceAspect
        }
        val intrinsic = when {
            declaredWidth != null -> declaredWidth
            declaredHeight != null -> declaredHeight / maxOf(0.0001f, aspect)
            else -> source.width.toFloat()
        }.dp.toPx()
        var width = minOf(column, maxOf(1f, intrinsic))
        var height = maxOf(1f, width * aspect)
        // A picture taller than the page is not a page: shrink it, keeping its
        // shape, until the line it sits on fits between the page's margins.
        val ceiling = maxOf(1f, pageHeightPx - pageMargin.toPx() - gapPx)
        if (height > ceiling) {
            height = ceiling
            width = maxOf(1f, height / aspect)
        }
        InlineImage(
            id = id,
            utf16Offset = image.utf16Offset,
            archivePath = image.archivePath,
            placeholder = Placeholder(width.toSp(), height.toSp(), PlaceholderVerticalAlign.Center),
            lineHeight = (height + gapPx).toSp(),
            hasPicture = true,
            alt = alt,
        )
    }

    /**
     * The bitmap for one archive entry, down-sampled to the width it is drawn
     * at. The sample is the largest power of two that still leaves at least
     * `targetWidthPx` across, so the result lands in `[target, 2·target)` — a
     * picture at column width on a 3x screen, and no finer; then, if the
     * pixels would take more than a quarter of the cache, the sample doubles
     * again until they do not. Null — never an exception — for an entry that
     * is missing, too large, or not an image: a book with a broken plate
     * still reads.
     */
    fun decode(archive: File, bookId: String, archivePath: String, targetWidthPx: Int = 2048): Decoded? {
        val bytes = readEntry(archive, archivePath) ?: return null
        val header = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, header)
        if (header.outWidth <= 0 || header.outHeight <= 0) return null
        var sample = 1
        while (targetWidthPx > 0 && header.outWidth / (sample * 2) >= targetWidthPx) sample *= 2
        while (sampledBytes(header.outWidth, header.outHeight, sample) > PER_IMAGE_BYTES &&
            (header.outWidth / sample > 1 || header.outHeight / sample > 1)
        ) {
            sample *= 2
        }
        val key = "$bookId|$archivePath|$sample"
        cache.get(key)?.let { return it }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "image too large to decode (${header.outWidth}x${header.outHeight})")
            null
        } ?: return null
        return Decoded(bitmap, header.outWidth, header.outHeight).also { cache.put(key, it) }
    }

    /** What a decode at this sample size would cost in pixels: four bytes each, rounded up. */
    private fun sampledBytes(width: Int, height: Int, sample: Int): Long =
        ((width + sample - 1) / sample).toLong() * ((height + sample - 1) / sample).toLong() * 4L

    /**
     * One entry's bytes, or null when the archive holds no such entry (or is
     * no archive at all — a plain-text book has a .txt behind it). The cap is
     * enforced while reading, not from the entry header: a zip may declare a
     * size of -1, and a declared size is the archive's word, not a fact.
     */
    private fun readEntry(archive: File, archivePath: String): ByteArray? {
        if (!archive.isFile) return null
        return try {
            ZipFile(archive).use { zip ->
                val entry = zip.getEntry(archivePath) ?: return null
                if (entry.size > perEntryCap) return null
                zip.getInputStream(entry).use { input ->
                    val out = ByteArrayOutputStream(if (entry.size in 1..(1 shl 22)) entry.size.toInt() else 1 shl 16)
                    val buffer = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        if (out.size() + n > perEntryCap) return null
                        out.write(buffer, 0, n)
                    }
                    out.toByteArray()
                }
            }
        } catch (e: IOException) {
            Log.w(TAG, "image entry unreadable: ${e.javaClass.simpleName}")
            null
        } catch (e: SecurityException) {
            Log.w(TAG, "image entry refused: ${e.javaClass.simpleName}")
            null
        }
    }
}
