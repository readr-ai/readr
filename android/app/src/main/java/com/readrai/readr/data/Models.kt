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
data class ChapterSummary(val index: Int, val title: String, val characterCount: Int)

/** ReadrKit's `ReadingPosition`, field for field. */
@Serializable
data class ReadingPosition(val chapterIndex: Int, val characterOffset: Int = 0, val pdfPageIndex: Int? = null)

val kitJson = Json { ignoreUnknownKeys = true }
