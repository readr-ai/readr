package com.readrai.readr

import com.readrai.readr.kit.NarrationEvents
import com.readrai.readr.kit.SpeechBackend
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A synthesizer that never makes a sound and never makes progress on its own:
 * a test says when a sentence finishes and where the voice is. It is the
 * Android counterpart of the kit's `PlainMockSpeechEngine`, one layer further
 * out — everything from `BridgedSpeechEngine` inwards is the real thing.
 *
 * It keeps [PlatformSpeechBackend]'s bargain about pause, because that bargain
 * is the interesting half of the contract: a pause stops the utterance and
 * remembers the last word boundary, a resume re-speaks the remainder under the
 * same request id, and every boundary reported afterwards has the cut added
 * back in — so the facade never learns that the text it handed over was
 * shortened.
 */
class FakeSpeechBackend(private val events: NarrationEvents) : SpeechBackend {

    /** One thing the backend was asked to say. */
    data class Spoken(
        val requestID: String,
        val text: String,
        val language: String,
        val voiceID: String,
        val rate: Double,
        val pitch: Double,
        val volume: Double,
    )

    val spoken = CopyOnWriteArrayList<Spoken>()
    /** What the last `speak` (or the last resume) was handed. */
    val lastText: String? get() = spoken.lastOrNull()?.text
    /** What voices the phone claims to have; empty by default. */
    var voices: String = "[]"

    private var state = IDLE
    private var activeID: String? = null
    private var activeText = ""
    /** Where in the whole sentence the string handed over begins. */
    private var base = 0
    /** The last word boundary, in whole-sentence offsets. */
    private var spokenUtf16 = 0
    private var held: Pair<String, String>? = null

    override fun speak(
        requestID: String,
        text: String,
        language: String,
        voiceID: String,
        rate: Double,
        pitch: Double,
        volume: Double,
    ) {
        held = null
        activeID = requestID
        activeText = text
        base = 0
        spokenUtf16 = 0
        state = SPEAKING
        spoken += Spoken(requestID, text, language, voiceID, rate, pitch, volume)
    }

    override fun pause() {
        val id = activeID ?: return
        held = id to activeText
        activeID = null
        state = PAUSED
    }

    override fun resume() {
        val (id, text) = held ?: return
        held = null
        activeID = id
        activeText = text
        base = spokenUtf16.coerceIn(0, text.length)
        state = SPEAKING
        val last = spoken.lastOrNull()
        spoken += Spoken(
            id, text.substring(base), last?.language.orEmpty(), last?.voiceID.orEmpty(),
            last?.rate ?: 1.0, last?.pitch ?: 1.0, last?.volume ?: 1.0,
        )
        events.didBegin(id)
    }

    override fun stop() {
        activeID = null
        held = null
        activeText = ""
        base = 0
        spokenUtf16 = 0
        state = IDLE
    }

    override fun state(): String = state

    override fun voicesJSON(): String = voices

    // MARK: Driving it from a test

    /** The voice speaks the current sentence through to the end. */
    fun finishCurrent() {
        val id = activeID ?: return
        activeID = null
        state = IDLE
        events.didFinish(id)
    }

    /**
     * A word boundary, in offsets into the **whole** sentence.
     *
     * Whole-sentence is the contract, not a convenience: the facade keeps one
     * offset table per request, over the text it handed to `speak`, and a
     * resume re-speaks only a tail without the kit ever hearing about it. So a
     * real backend adds its cut back in before reporting, and so does this one
     * — which here means reporting the number the test wrote.
     */
    fun speakWord(start: Int, end: Int) {
        val id = activeID ?: return
        spokenUtf16 = start
        events.willSpeak(id, start.toLong(), end.toLong())
    }

    /** The engine refuses the sentence. */
    fun fail(diagnostic: String = "no voice") {
        val id = activeID ?: return
        activeID = null
        state = IDLE
        events.didFail(id, diagnostic)
    }

    private companion object {
        const val IDLE = "idle"
        const val SPEAKING = "speaking"
        const val PAUSED = "paused"
    }
}
