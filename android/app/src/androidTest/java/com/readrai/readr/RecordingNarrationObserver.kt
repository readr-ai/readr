package com.readrai.readr

import com.readrai.readr.kit.NarrationObserver
import java.util.concurrent.CopyOnWriteArrayList

/** What the facade told the card, in order. */
class RecordingNarrationObserver : NarrationObserver {
    data class Position(val chapterIndex: Int, val utf16Offset: Int, val utf16SentenceStart: Int)
    data class Spoken(val chapterIndex: Int, val utf16Start: Int, val utf16End: Int)

    val statuses = CopyOnWriteArrayList<String>()
    val positions = CopyOnWriteArrayList<Position>()
    val spoken = CopyOnWriteArrayList<Spoken>()
    val sentences = CopyOnWriteArrayList<String>()
    val sleeps = CopyOnWriteArrayList<String>()
    val holds = CopyOnWriteArrayList<String>()

    override fun statusChanged(status: String) { statuses += status }

    override fun positionChanged(chapterIndex: Long, utf16Offset: Long, utf16SentenceStart: Long) {
        positions += Position(chapterIndex.toInt(), utf16Offset.toInt(), utf16SentenceStart.toInt())
    }

    override fun spokenRange(chapterIndex: Long, utf16Start: Long, utf16End: Long) {
        spoken += Spoken(chapterIndex.toInt(), utf16Start.toInt(), utf16End.toInt())
    }

    override fun sentenceChanged(text: String) { sentences += text }

    override fun sleepTimerChanged(json: String) { sleeps += json }

    override fun holdChanged(reason: String) { holds += reason }
}
