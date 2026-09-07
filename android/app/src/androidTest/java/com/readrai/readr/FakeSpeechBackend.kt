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
 * It has no pause, because [com.readrai.readr.kit.PlatformSpeechBackend] has
 * none: the kit stops this backend on a pause and re-speaks the remainder of
 * the sentence as a fresh request on play, so what a pause looks like from
 * here is a `stop()` followed by a `speak()` of a shorter text.
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
    /** What the last `speak` was handed. */
    val lastText: String? get() = spoken.lastOrNull()?.text
    /** How many times the kit asked for silence. */
    @Volatile var stops = 0
        private set
    /** What voices the phone claims to have; empty by default. */
    var voices: String = "[]"
    /**
     * A phone with no working synthesizer: every sentence is refused on the
     * spot, the way [com.readrai.readr.kit.PlatformSpeechBackend] refuses one
     * after its engine failed to start.
     */
    var refusesEverySentence = false

    private var state = IDLE
    private var activeID: String? = null

    override fun speak(
        requestID: String,
        text: String,
        language: String,
        voiceID: String,
        rate: Double,
        pitch: Double,
        volume: Double,
    ) {
        spoken += Spoken(requestID, text, language, voiceID, rate, pitch, volume)
        if (refusesEverySentence) {
            activeID = null
            state = IDLE
            events.didFail(requestID, "text-to-speech unavailable")
            return
        }
        activeID = requestID
        state = SPEAKING
    }

    override fun stop() {
        stops += 1
        activeID = null
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
     * A word boundary, in offsets into the text this backend was last handed
     * — which is exactly what a real one reports, since nothing on the Kotlin
     * side ever shortens a request.
     */
    fun speakWord(start: Int, end: Int) {
        val id = activeID ?: return
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
    }
}
