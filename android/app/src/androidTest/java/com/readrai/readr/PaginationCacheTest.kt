package com.readrai.readr

import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.readrai.readr.ui.reader.LayoutKey
import com.readrai.readr.ui.reader.PageKey
import com.readrai.readr.ui.reader.PageSet
import com.readrai.readr.ui.reader.Pagination
import com.readrai.readr.ui.reader.PaginationCache
import com.readrai.readr.ui.reader.ReaderAppearance
import com.readrai.readr.ui.reader.StyledChapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The slots the chrome toggle lives in. The cache is what makes showing and
 * hiding the bar free: two page heights the reader flips between all through a
 * book, each keeping its own pagination.
 */
@RunWith(AndroidJUnit4::class)
class PaginationCacheTest {
    private val layout = LayoutKey(ReaderAppearance())

    private fun key(
        chapterIndex: Int = 0,
        widthPx: Int = 900,
        heightPx: Int = 1_600,
        imageCeilingPx: Int = heightPx,
    ) = PageKey(chapterIndex, widthPx, heightPx, imageCeilingPx, density = 3f, fontScale = 1f, layout = layout)

    private fun set(chapterIndex: Int = 0) =
        PageSet(chapterIndex, StyledChapter(AnnotatedString(""), intArrayOf(0)), Pagination(emptyList()))

    @Test
    fun aSetComesBackForTheKeyItWasStoredUnder() {
        val cache = PaginationCache()
        val stored = set()
        assertNull("nothing is there until it is put there", cache.get(key()))
        cache.put(key(), stored)
        assertSame(stored, cache.get(key()))
        // The key is a value: an equal one is the same slot.
        assertSame(stored, cache.get(key(heightPx = 1_600)))
    }

    /**
     * Every field of the key is part of the shape. A set built for one of them
     * must never be handed back for another — that is a page measured for a
     * geometry that is gone, which is exactly how a page comes to overflow.
     */
    @Test
    fun everyFieldOfTheKeyIsASlotOfItsOwn() {
        val cache = PaginationCache(capacity = 16)
        val stored = set()
        cache.put(key(), stored)
        assertNull("another chapter", cache.get(key(chapterIndex = 1)))
        assertNull("another column width", cache.get(key(widthPx = 901)))
        assertNull("another page height", cache.get(key(heightPx = 1_601)))
        assertNull("another picture ceiling", cache.get(key(imageCeilingPx = 1_700)))
        assertNull(
            "another density",
            cache.get(PageKey(0, 900, 1_600, 1_600, density = 2f, fontScale = 1f, layout = layout)),
        )
        assertNull(
            "another font scale",
            cache.get(PageKey(0, 900, 1_600, 1_600, density = 3f, fontScale = 1.3f, layout = layout)),
        )
        assertNull(
            "another type size",
            cache.get(PageKey(0, 900, 1_600, 1_600, density = 3f, fontScale = 1f, layout = layout.copy(fontSize = 22))),
        )
    }

    /** The chrome up and the chrome down are two slots, and both survive the flipping. */
    @Test
    fun bothChromeGeometriesStayThroughAToggleAndBack() {
        val cache = PaginationCache()
        val withBar = set()
        val withoutBar = set()
        cache.put(key(heightPx = 1_400), withBar)
        cache.put(key(heightPx = 1_600), withoutBar)
        repeat(4) {
            assertSame(withBar, cache.get(key(heightPx = 1_400)))
            assertSame(withoutBar, cache.get(key(heightPx = 1_600)))
        }
    }

    @Test
    fun theOldestUnusedSlotIsTheOneThatGoes() {
        val cache = PaginationCache(capacity = 2)
        cache.put(key(chapterIndex = 0), set(0))
        cache.put(key(chapterIndex = 1), set(1))
        // Touching the first makes the second the least recently used.
        assertNotNull(cache.get(key(chapterIndex = 0)))
        cache.put(key(chapterIndex = 2), set(2))
        assertEquals(2, cache.keys().size)
        assertNotNull("the one just read is kept", cache.get(key(chapterIndex = 0)))
        assertNotNull("and the one just written", cache.get(key(chapterIndex = 2)))
        assertNull("the untouched one went", cache.get(key(chapterIndex = 1)))
        assertTrue(cache.keys().none { it.chapterIndex == 1 })
    }
}
