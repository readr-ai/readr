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
import java.util.zip.ZipFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * One inline image, sized for the page it is about to be laid into: the id its
 * annotation carries, the [Placeholder] the text is *measured* with, and the
 * bitmap that fills it. `bitmap` is null when the entry could not be read or
 * decoded — that image still takes a placeholder, one line tall, so the page
 * that was measured is the page that is drawn either way.
 */
class InlineImage(
    val id: String,
    val utf16Offset: Int,
    val placeholder: Placeholder,
    /**
     * The line height the paragraph holding this image is given. Every
     * paragraph on the page carries an explicit line height, and Compose
     * forces a line to the height it is told — so an image's own line has to
     * be told to be as tall as the picture, or the picture is squeezed.
     */
    val lineHeight: TextUnit,
    val bitmap: ImageBitmap?,
    val alt: String,
)

/**
 * The pictures inside a book. The kit leaves an image as a U+FFFC placeholder
 * in the chapter text plus an entry path into the book's retained original;
 * the bytes never cross the bridge (a chapter of plates would be megabytes of
 * JSON), so the reader opens the archive itself, here.
 *
 * Everything an untrusted archive can do is bounded: an entry is read only up
 * to the kit's own per-entry ceiling ([KitLimits.epubPerEntryByteCap], read
 * through the bridge so the two cannot drift), a path that names no entry
 * yields null rather than an exception, and the decode is down-sampled so a
 * 6000-pixel plate never becomes a 140 MB bitmap.
 */
object ChapterImages {
    private const val TAG = "Readr.Images"

    /** Decoded bitmaps, bounded by the bytes they hold rather than by their number. */
    private const val CACHE_BYTES = 24 * 1024 * 1024

    /**
     * How much finer than the text column an image is decoded. Two is enough
     * for a picture drawn at column width on a 3x screen to stay crisp, and
     * cheap enough that a plate-heavy chapter still fits the cache.
     */
    private const val OVERSAMPLE = 2

    /** Air below an image's line, so the forced line height never clips the picture. */
    private val lineGap = 4.dp

    /** The margin the page keeps below the tallest image — the reader's own 4 dp. */
    private val pageMargin = 4.dp

    private val perEntryCap: Long by lazy { KitLimits.epubPerEntryByteCap() }

    /**
     * Keyed by book, entry and the width it was decoded for: the same picture
     * at two column widths is two bitmaps, and a re-import is a new book id,
     * so nothing here can outlive the bytes it came from.
     */
    private val cache = object : LruCache<String, Decoded>(CACHE_BYTES) {
        override fun sizeOf(key: String, value: Decoded): Int = value.bitmap.byteCount
    }

    /** A decoded bitmap and the size of the image it was decoded from, in source pixels. */
    class Decoded(val bitmap: Bitmap, val sourceWidth: Int, val sourceHeight: Int) {
        val image: ImageBitmap by lazy { bitmap.asImageBitmap() }
    }

    /** Forgets every decoded bitmap; for tests, and for a shelf that just lost a book. */
    fun clearCache() = cache.evictAll()

    /**
     * The chapter's images, read and sized for a page `textWidthPx` wide and
     * `pageHeightPx` tall. Runs on the IO dispatcher: it opens a zip and
     * decodes bitmaps.
     *
     * Sizing follows the source's intent where it states one: the width is the
     * markup's `width` in CSS pixels read as dp, or else the image's own pixel
     * width read as dp, and never more than the text column. The height comes
     * from the image's true aspect ratio, and an image taller than the page is
     * scaled down — by height — until its whole line fits one page.
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
        images.map { image ->
            val decoded = if (archive == null) null else decode(archive, bookId, image.archivePath, textWidthPx * OVERSAMPLE)
            inline(image, decoded, density, textWidthPx, pageHeightPx, fallbackLineHeightPx)
        }
    }

    private fun inline(
        image: ChapterImage,
        decoded: Decoded?,
        density: Density,
        textWidthPx: Int,
        pageHeightPx: Int,
        fallbackLineHeightPx: Float,
    ): InlineImage = with(density) {
        val id = "image-${image.utf16Offset}"
        val alt = image.alt.orEmpty().trim()
        val gapPx = lineGap.toPx()
        if (decoded == null || decoded.sourceWidth <= 0 || decoded.sourceHeight <= 0) {
            // Nothing to draw: one line, holding the alt text (or a rule).
            val height = maxOf(1f, fallbackLineHeightPx)
            return@with InlineImage(
                id = id,
                utf16Offset = image.utf16Offset,
                placeholder = Placeholder(textWidthPx.toFloat().toSp(), height.toSp(), PlaceholderVerticalAlign.Center),
                lineHeight = (height + gapPx).toSp(),
                bitmap = null,
                alt = alt,
            )
        }
        val column = maxOf(1f, textWidthPx.toFloat())
        val intrinsic = (image.displayWidth?.toFloat() ?: decoded.sourceWidth.toFloat()).dp.toPx()
        val aspect = decoded.sourceHeight.toFloat() / decoded.sourceWidth.toFloat()
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
            placeholder = Placeholder(width.toSp(), height.toSp(), PlaceholderVerticalAlign.Center),
            lineHeight = (height + gapPx).toSp(),
            bitmap = decoded.image,
            alt = alt,
        )
    }

    /**
     * The bitmap for one archive entry, down-sampled so it is at most
     * `maxWidthPx` across. Null — never an exception — for an entry that is
     * missing, too large, or not an image: a book with a broken plate still
     * reads.
     */
    fun decode(archive: File, bookId: String, archivePath: String, maxWidthPx: Int = 2048): Decoded? {
        val key = "$bookId|$archivePath|$maxWidthPx"
        cache.get(key)?.let { return it }
        val bytes = readEntry(archive, archivePath) ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxWidthPx > 0 && bounds.outWidth / (sample * 2) >= maxWidthPx) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "image too large to decode (${bounds.outWidth}x${bounds.outHeight})")
            null
        } ?: return null
        return Decoded(bitmap, bounds.outWidth, bounds.outHeight).also { cache.put(key, it) }
    }

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
