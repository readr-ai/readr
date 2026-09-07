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

@Serializable
data class ChapterSummary(val index: Int, val title: String, val characterCount: Int, val isLinear: Boolean = true)

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

val kitJson = Json { ignoreUnknownKeys = true }
