package com.readrai.readr.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Mirrors ReadrAndroid's `BookSummary`. */
@Serializable
data class BookSummary(
    val id: String,
    val title: String,
    val authors: List<String> = emptyList(),
    val language: String? = null,
    val chapterCount: Int,
    val estimatedTokenCount: Int,
    val isImageOnly: Boolean = false,
    val isFixedLayout: Boolean = false,
    val coverPath: String? = null,
    val sourceFilename: String? = null,
)

/**
 * Mirrors ReadrAndroid's `ChapterSummary`. `sourcePath` is the chapter's entry
 * path inside the EPUB — null for a book with no archive behind it — and is
 * what an internal link's archive path is matched against.
 */
@Serializable
data class ChapterSummary(
    val index: Int,
    val title: String,
    val characterCount: Int,
    val isLinear: Boolean = true,
    val sourcePath: String? = null,
)

/**
 * Mirrors ReadrAndroid's `ChapterImageSummary`: an inline image anchored to
 * the U+FFFC placeholder at `utf16Offset` in the chapter text. The bytes stay
 * in the book's retained original at `archivePath`; the reader reads them
 * itself (see `ChapterImages`). `displayWidth`/`displayHeight` are the source
 * markup's CSS-pixel intent, absent far more often than not.
 */
@Serializable
data class ChapterImage(
    val utf16Offset: Int,
    val archivePath: String,
    val alt: String? = null,
    val displayWidth: Double? = null,
    val displayHeight: Double? = null,
)

/** Mirrors ReadrAndroid's `FootnoteSummary`: a note lifted out of the reading flow. */
@Serializable
data class Footnote(val id: String, val text: String)

/**
 * The saved place as the facade reports it: `utf16Offset` is the coordinate
 * Kotlin and Compose use and is required, so a producer that forgets the
 * conversion fails to decode rather than restoring the wrong page;
 * `characterOffset` is the kit's count, kept for diagnostics and tests.
 */
@Serializable
data class ReadingPosition(val chapterIndex: Int, val utf16Offset: Int, val characterOffset: Int = utf16Offset)

/** Mirrors ReadrAndroid's `LayoutSpan`: a format run with UTF-16 offsets. */
@Serializable
data class LayoutSpan(
    val start: Int,
    val end: Int,
    val kind: String,
    val level: Int? = null,
    val alignment: String? = null,
    val url: String? = null,
    val linkPath: String? = null,
    val linkFragment: String? = null,
)

/** Mirrors ReadrAndroid's `ChapterLayout`. */
@Serializable
data class ChapterLayout(
    val index: Int,
    val utf16Length: Int,
    val spans: List<LayoutSpan> = emptyList(),
    val anchors: Map<String, Int> = emptyMap(),
)

/** Mirrors ReadrAndroid's `ContentsRow`. */
@Serializable
data class ContentsRow(val id: Int, val title: String, val chapterIndex: Int, val depth: Int = 0, val utf16Offset: Int = 0)

/** Mirrors ReadrAndroid's `Contents`. */
@Serializable
data class Contents(val rows: List<ContentsRow>, val isFallback: Boolean)

/**
 * Mirrors ReadrAndroid's `SearchHit`: one in-book match, `utf16Offset` into
 * the chapter text as Kotlin indexes it. `chapterTitle` is what the kit found
 * on the chapter — absent for books that title none, in which case the reader
 * falls back to the chapter list it already has.
 */
@Serializable
data class SearchResult(
    val id: Int,
    val chapterIndex: Int,
    val chapterTitle: String? = null,
    val utf16Offset: Int,
    val snippet: String,
)

/** Mirrors ReadrAndroid's `HighlightSummary`: a text highlight with UTF-16 offsets. */
@Serializable
data class Highlight(
    val id: String,
    val chapterIndex: Int,
    val utf16Start: Int,
    val utf16End: Int,
    val quotedText: String,
    val note: String? = null,
    val color: String,
    val createdAt: String,
) {
    val markerColor: HighlightColor get() = HighlightColor.fromKey(color)
}

/** Mirrors ReadrAndroid's `BookmarkSummary`. PDF-page bookmarks never cross the bridge. */
@Serializable
data class Bookmark(
    val id: String,
    val chapterIndex: Int,
    val utf16Offset: Int,
    val snippet: String,
    val createdAt: String,
)

/**
 * The kit's `HighlightColor`, by raw value. A colour the kit adds later
 * decodes as yellow rather than crashing an older build's Highlights sheet —
 * the same fallback `Highlight.markerColor` makes on the Swift side.
 */
enum class HighlightColor(val key: String) {
    YELLOW("yellow"),
    GREEN("green"),
    BLUE("blue"),
    PINK("pink"),
    PURPLE("purple");

    companion object {
        fun fromKey(key: String): HighlightColor = entries.firstOrNull { it.key == key } ?: YELLOW
    }
}

val kitJson = Json { ignoreUnknownKeys = true }
