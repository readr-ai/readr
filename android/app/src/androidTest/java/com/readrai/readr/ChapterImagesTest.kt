package com.readrai.readr

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.ChapterImage
import com.readrai.readr.data.ChapterImages
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
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
        val big = File(root, "big.epub")
        // A plate far wider than any column, in an archive of its own.
        java.util.zip.ZipOutputStream(big.outputStream()).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("plate.png"))
            zip.write(IllustratedBook.png(1600, 800))
            zip.closeEntry()
        }
        val decoded = ChapterImages.decode(big, bookId, "plate.png", maxWidthPx = 200)!!
        assertEquals(1600, decoded.sourceWidth)
        assertEquals(800, decoded.sourceHeight)
        assertTrue("down-sampled to ${decoded.bitmap.width}px", decoded.bitmap.width <= 400)
        assertTrue("but not to nothing", decoded.bitmap.width >= 100)
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
        assertNotNull("the figure has bytes behind it", figure.bitmap)
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
        assertNull("nothing to draw", missing.bitmap)
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
        val tall = File(root, "tall.epub")
        java.util.zip.ZipOutputStream(tall.outputStream()).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("tall.png"))
            zip.write(IllustratedBook.png(200, 1400))
            zip.closeEntry()
        }
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
}
