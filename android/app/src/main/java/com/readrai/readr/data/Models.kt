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
 * ReadrKit's `ReadingPosition` plus `utf16Offset`, the same place in the
 * coordinates Kotlin and Compose use. Only `utf16Offset` is meaningful on
 * this side of the bridge; `characterOffset` is the kit's count and is kept
 * for diagnostics.
 */
@Serializable
data class ReadingPosition(
    val chapterIndex: Int,
    val characterOffset: Int = 0,
    val pdfPageIndex: Int? = null,
    val utf16Offset: Int = characterOffset,
)

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
    val title: String,
    val isLinear: Boolean = true,
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
