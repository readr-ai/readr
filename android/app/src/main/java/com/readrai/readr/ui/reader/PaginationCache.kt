package com.readrai.readr.ui.reader

/**
 * A chapter styled for one layout, and its pages for one geometry. The chapter
 * index travels with the pages: for a composition after a jump the surface
 * still holds the chapter just left, and every offset on screen belongs to
 * *this* chapter, never to whichever one the ViewModel has moved on to.
 *
 * In a scroll the "pages" are the measurement chunks the surface draws
 * ([LayoutPaginator.chunks]); nothing is cut to a page height there.
 */
class PageSet(val chapterIndex: Int, val styled: StyledChapter, val pagination: Pagination)

/**
 * What a styled chapter and its pagination depend on — everything, so a set
 * that comes back from the cache can only be a set that would have been built
 * again identically. The inline images are placed inside the same computation,
 * so their inputs are keyed here too.
 *
 * `widthPx` is the width of **one text column** — in a facing-page spread that
 * is half the block, minus the spine — so the two pages of a spread share one
 * key and one measurement. `heightPx` is the page's text height, which the
 * chrome changes: the bar is not an overlay, the surface sits below it, so a
 * page is shorter with the chrome up than with it down; it is 0 in a scroll,
 * which has no page to fill and must not re-measure when the bar comes and
 * goes. `imageCeilingPx` is how tall a picture may be drawn — the page height
 * on a cut page, and in a scroll the surface's height with the chrome *down*,
 * which the bar cannot change. Density and font scale matter because the
 * ViewModel outlives a configuration change, and the font size (in `layout`)
 * both sets the type and stands in for the fallback line an unreadable image
 * takes.
 */
data class PageKey(
    val chapterIndex: Int,
    val widthPx: Int,
    val heightPx: Int,
    val imageCeilingPx: Int,
    val density: Float,
    val fontScale: Float,
    val layout: LayoutKey,
)

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

    @Synchronized
    fun get(key: PageKey): PageSet? = entries[key]

    @Synchronized
    fun put(key: PageKey, value: PageSet) { entries[key] = value }

    /** The keys held, least recently used first — for tests, which is where eviction is proved. */
    @Synchronized
    fun keys(): List<PageKey> = entries.keys.toList()
}
