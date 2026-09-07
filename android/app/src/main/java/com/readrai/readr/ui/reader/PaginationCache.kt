package com.readrai.readr.ui.reader

/**
 * A chapter styled for one layout, and its pages for one geometry. The chapter
 * index travels with the pages: for a composition after a jump the surface
 * still holds the chapter just left, and every offset on screen belongs to
 * *this* chapter, never to whichever one the ViewModel has moved on to.
 */
class PageSet(val chapterIndex: Int, val styled: StyledChapter, val pagination: Pagination)

/**
 * What a pagination depends on. `widthPx` is the width of **one text column**
 * — in a facing-page spread that is half the block, minus the spine — so the
 * two pages of a spread share one key and one measurement. `heightPx` is the
 * page's text height, which the chrome changes: the bar is not an overlay,
 * the surface sits below it, so a page is shorter with the chrome up than
 * with it down. Density and font scale matter because the ViewModel outlives
 * a configuration change.
 */
data class PageKey(val chapterIndex: Int, val widthPx: Int, val heightPx: Int, val density: Float, val fontScale: Float, val layout: LayoutKey)

/**
 * The last few paginations, so an appearance change and back, a rotation and
 * back, or — the everyday one — the chrome shown and hidden again, does not
 * measure the chapter a second time. Several slots because those geometries
 * alternate: chrome up and chrome down are two page heights the reader flips
 * between all through a book, and each keeps its own pagination here while
 * the reading place stays the anchor, from which the page index is re-derived
 * (so the place does not jump when the geometry changes underneath it).
 */
class PaginationCache(private val capacity: Int = 4) {
    private val entries = object : LinkedHashMap<PageKey, PageSet>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<PageKey, PageSet>?): Boolean = size > capacity
    }

    /** Paginations served from the cache rather than measured; the reader's proof that a toggle is free. */
    var hits: Int = 0
        @Synchronized get
        private set

    @Synchronized
    fun get(key: PageKey): PageSet? = entries[key]?.also { hits++ }

    @Synchronized
    fun put(key: PageKey, value: PageSet) { entries[key] = value }
}
