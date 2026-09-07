package com.readrai.readr.ui.reader

/**
 * A chapter styled for one layout, and its pages for one geometry. The chapter
 * index travels with the pages: for a composition after a jump the surface
 * still holds the chapter just left, and every offset on screen belongs to
 * *this* chapter, never to whichever one the ViewModel has moved on to.
 */
class PageSet(val chapterIndex: Int, val styled: StyledChapter, val pagination: Pagination)

/** What a pagination depends on. Density and font scale matter because the ViewModel outlives a configuration change. */
data class PageKey(val chapterIndex: Int, val widthPx: Int, val heightPx: Int, val density: Float, val fontScale: Float, val layout: LayoutKey)

/**
 * The last few paginations, so an appearance change and back, or a rotation
 * and back, does not measure the chapter again.
 */
class PaginationCache(private val capacity: Int = 4) {
    private val entries = object : LinkedHashMap<PageKey, PageSet>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PageKey, PageSet>?): Boolean = size > capacity
    }

    @Synchronized
    fun get(key: PageKey): PageSet? = entries[key]

    @Synchronized
    fun put(key: PageKey, value: PageSet) { entries[key] = value }
}
