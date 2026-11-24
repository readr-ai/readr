package com.readrai.readr

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.ChapterImage
import com.readrai.readr.data.ChapterImages
import com.readrai.readr.data.InlineImage
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Reading a picture out of a book: the bytes, the size, and what stands in when there are none. */
@RunWith(AndroidJUnit4::class)
class ChapterImagesTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var archive: File
    private val density by lazy { Density(context) }
    private val bookId = "book-under-test"

    @Before
    fun setUp() {
        root = File(context.cacheDir, "images-test-${System.nanoTime()}").apply { mkdirs() }
        archive = IllustratedBook.write(File(root, "illustrated.epub"))
        ChapterImages.clearCache()
    }

    @After
    fun tearDown() {
        ChapterImages.clearCache()
        root.deleteRecursively()
    }

    /** An archive of one picture at a stated pixel size, in a file of its own. */
    private fun archiveOf(name: String, entry: String, width: Int, height: Int): File =
        File(root, name).also { file ->
            java.util.zip.ZipOutputStream(file.outputStream()).use { zip ->
                zip.putNextEntry(java.util.zip.ZipEntry(entry))
                zip.write(IllustratedBook.png(width, height))
                zip.closeEntry()
            }
        }

    @Test
    fun anEntryInTheArchiveDecodesToABitmap() {
        val decoded = ChapterImages.decode(archive, bookId, IllustratedBook.IMAGE_PATH)
        assertNotNull("the figure decodes", decoded)
        assertEquals(IllustratedBook.FIGURE_WIDTH, decoded!!.sourceWidth)
        assertEquals(IllustratedBook.FIGURE_HEIGHT, decoded.sourceHeight)
        assertTrue(decoded.bitmap.width > 0 && decoded.bitmap.height > 0)
        // The second read is the same bitmap: decoding is cached, not repeated.
        assertTrue(ChapterImages.decode(archive, bookId, IllustratedBook.IMAGE_PATH)!!.bitmap === decoded.bitmap)
    }

    @Test
    fun aPathTheArchiveDoesNotHoldIsNullRatherThanAThrow() {
        assertNull(ChapterImages.decode(archive, bookId, IllustratedBook.MISSING_PATH))
        assertNull(ChapterImages.decode(archive, bookId, "../../etc/hosts"))
        // Nor does a file that is no archive at all — a plain-text book's original.
        val plain = File(root, "notes.txt").apply { writeText("no pictures here") }
        assertNull(ChapterImages.decode(plain, bookId, IllustratedBook.IMAGE_PATH))
        // Nor one that is not there at all.
        assertNull(ChapterImages.decode(File(root, "gone.epub"), bookId, IllustratedBook.IMAGE_PATH))
    }

    @Test
    fun aLargeImageIsDownSampledButKeepsItsSourceSize() {
        val big = archiveOf("big.epub", "plate.png", 1600, 800)
        val decoded = ChapterImages.decode(big, bookId, "plate.png", targetWidthPx = 200)!!
        assertEquals(1600, decoded.sourceWidth)
        assertEquals(800, decoded.sourceHeight)
        assertTrue("down-sampled to ${decoded.bitmap.width}px", decoded.bitmap.width <= 400)
        assertTrue("but not to nothing", decoded.bitmap.width >= 200)
    }

    /**
     * The decode budget: a plate is decoded for the column it is drawn in and
     * no finer, and a single picture never takes more than a quarter of the
     * cache — one that did would evict every other plate in the chapter on its
     * way in.
     */
    @Test
    fun aPlateIsDecodedForItsColumnAndFitsTheCache() {
        val column = 936
        val plate = archiveOf("plate.epub", "plate.png", 2500, 1600)
        val decoded = ChapterImages.decode(plate, bookId, "plate.png", targetWidthPx = column)!!
        assertEquals(2500, decoded.sourceWidth)
        assertTrue("at least the column ($column) wide, at ${decoded.bitmap.width}px", decoded.bitmap.width >= column)
        assertTrue("and under twice it, at ${decoded.bitmap.width}px", decoded.bitmap.width < 2 * column)
        assertTrue(
            "one picture takes at most a quarter of the cache (${decoded.bitmap.byteCount} bytes)",
            decoded.bitmap.byteCount <= ChapterImages.CACHE_BYTES / 4,
        )
    }

    @Test
    fun aPlacedImageFitsTheColumnAndAMissingOneTakesOneLine() = runTest {
        val textWidthPx = with(density) { 300.dp.roundToPx() }
        val pageHeightPx = with(density) { 480.dp.roundToPx() }
        val lineHeightPx = with(density) { 22.dp.toPx() }
        val placed = ChapterImages.place(
            archive = archive,
            bookId = bookId,
            images = listOf(
                ChapterImage(utf16Offset = 4, archivePath = IllustratedBook.IMAGE_PATH, alt = IllustratedBook.ALT),
                ChapterImage(utf16Offset = 9, archivePath = IllustratedBook.MISSING_PATH, alt = "A missing plate"),
            ),
            density = density,
            textWidthPx = textWidthPx,
            pageHeightPx = pageHeightPx,
            fallbackLineHeightPx = lineHeightPx,
        )
        assertEquals(2, placed.size)

        val figure = placed[0]
        assertTrue("the figure has bytes behind it", figure.hasPicture)
        val widthPx = with(density) { figure.placeholder.width.toPx() }
        val heightPx = with(density) { figure.placeholder.height.toPx() }
        assertTrue("never wider than the column ($widthPx of $textWidthPx)", widthPx <= textWidthPx + 0.5f)
        assertEquals(
            "the figure keeps its shape",
            IllustratedBook.FIGURE_HEIGHT.toFloat() / IllustratedBook.FIGURE_WIDTH,
            heightPx / widthPx,
            0.02f,
        )
        assertTrue("and fits a page", with(density) { figure.lineHeight.toPx() } <= pageHeightPx)

        val missing = placed[1]
        assertFalse("nothing to draw", missing.hasPicture)
        assertEquals("A missing plate", missing.alt)
        assertEquals(
            "a line's worth of page, no more",
            lineHeightPx,
            with(density) { missing.placeholder.height.toPx() },
            0.5f,
        )
    }

    @Test
    fun anImageTallerThanThePageIsScaledDownToFitOne() = runTest {
        val tall = archiveOf("tall.epub", "tall.png", 200, 1400)
        val textWidthPx = with(density) { 300.dp.roundToPx() }
        val pageHeightPx = with(density) { 400.dp.roundToPx() }
        val placed = ChapterImages.place(
            archive = tall,
            bookId = bookId,
            images = listOf(ChapterImage(utf16Offset = 0, archivePath = "tall.png")),
            density = density,
            textWidthPx = textWidthPx,
            pageHeightPx = pageHeightPx,
            fallbackLineHeightPx = with(density) { 22.dp.toPx() },
        ).single()
        val lineHeightPx = with(density) { placed.lineHeight.toPx() }
        assertTrue("the whole line fits one page ($lineHeightPx of $pageHeightPx)", lineHeightPx <= pageHeightPx)
        val widthPx = with(density) { placed.placeholder.width.toPx() }
        val heightPx = with(density) { placed.placeholder.height.toPx() }
        assertEquals("shrunk, not squashed", 1400f / 200f, heightPx / widthPx, 0.05f)
    }

    /**
     * The four sizing branches, as the Apple reader's `fittedBounds` decides
     * them. The source is 320×200, so its own aspect is 0.625; the column and
     * the page are wide and tall enough that nothing here is clipped by them.
     */
    @Test
    fun theMarkupsStatedSizeDecidesTheShapeWhereItStatesOne() = runTest {
        val textWidthPx = with(density) { 700.dp.roundToPx() }
        val pageHeightPx = with(density) { 2_000.dp.roundToPx() }
        val sourceAspect = IllustratedBook.FIGURE_HEIGHT.toFloat() / IllustratedBook.FIGURE_WIDTH

        suspend fun sized(width: Double?, height: Double?): Pair<Float, Float> {
            val placed = ChapterImages.place(
                archive = archive,
                bookId = bookId,
                images = listOf(
                    ChapterImage(
                        utf16Offset = 0,
                        archivePath = IllustratedBook.IMAGE_PATH,
                        displayWidth = width,
                        displayHeight = height,
                    ),
                ),
                density = density,
                textWidthPx = textWidthPx,
                pageHeightPx = pageHeightPx,
                fallbackLineHeightPx = with(density) { 22.dp.toPx() },
            ).single()
            return with(density) { placed.placeholder.width.toPx() to placed.placeholder.height.toPx() }
        }

        // Both declared: the markup states the shape, whatever the bitmap is.
        val (bothWidth, bothHeight) = sized(100.0, 400.0)
        assertEquals(with(density) { 100.dp.toPx() }, bothWidth, 1f)
        assertEquals("the declared aspect, not the source's", 4f, bothHeight / bothWidth, 0.02f)

        // Width only: the height comes back through the source's aspect.
        val (wideWidth, wideHeight) = sized(160.0, null)
        assertEquals(with(density) { 160.dp.toPx() }, wideWidth, 1f)
        assertEquals(sourceAspect, wideHeight / wideWidth, 0.02f)

        // Height only — common in EPUB markup — is a size intent all the same.
        val (tallWidth, tallHeight) = sized(null, 200.0)
        assertEquals(with(density) { 200.dp.toPx() }, tallHeight, 1f)
        assertEquals(with(density) { (200f / sourceAspect).dp.toPx() }, tallWidth, 1f)

        // Neither: the image's own pixels, read as dp.
        val (plainWidth, plainHeight) = sized(null, null)
        assertEquals(with(density) { IllustratedBook.FIGURE_WIDTH.dp.toPx() }, plainWidth, 1f)
        assertEquals(with(density) { IllustratedBook.FIGURE_HEIGHT.dp.toPx() }, plainHeight, 1f)
    }

    /** A picture whose bytes have not arrived yet is still a picture: the box is the header's. */
    @Test
    fun theBitmapArrivesAfterwardsIntoTheBoxTheHeaderSized() = runTest {
        val textWidthPx = with(density) { 300.dp.roundToPx() }
        val placed: List<InlineImage> = ChapterImages.place(
            archive = archive,
            bookId = bookId,
            images = listOf(ChapterImage(utf16Offset = 0, archivePath = IllustratedBook.IMAGE_PATH)),
            density = density,
            textWidthPx = textWidthPx,
            pageHeightPx = with(density) { 480.dp.roundToPx() },
            fallbackLineHeightPx = with(density) { 22.dp.toPx() },
        )
        val box = placed.single().placeholder

        val arrived = LinkedHashMap<String, Boolean>()
        ChapterImages.load(archive, bookId, placed, textWidthPx) { id, _ -> arrived[id] = true }
        assertEquals(listOf(placed.single().id), arrived.keys.toList())
        // And nothing about the box changed on the way.
        assertEquals(box.width, placed.single().placeholder.width)
        assertEquals(box.height, placed.single().placeholder.height)
    }
}
