package com.readrai.readr.ui.reader

import androidx.compose.ui.text.AnnotatedString

/** A chapter styled for one appearance, and its pages for one geometry. */
class PageSet(val styled: AnnotatedString, val pagination: Pagination)

/**
 * The last few paginations, keyed by chapter + geometry + appearance. More
 * than one slot on purpose: toggling the chrome changes the surface height,
 * and a single slot would re-paginate on every tap.
 */
class PaginationCache(private val capacity: Int = 4) {
    private val entries = object : LinkedHashMap<String, PageSet>(capacity, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, PageSet>?): Boolean = size > capacity
    }

    @Synchronized
    fun get(key: String): PageSet? = entries[key]

    @Synchronized
    fun put(key: String, value: PageSet) { entries[key] = value }
}
