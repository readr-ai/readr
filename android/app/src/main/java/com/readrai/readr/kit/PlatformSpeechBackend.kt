package com.readrai.readr.kit

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
import java.util.Locale
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** One installed voice as the facade wants it — see `Narration.swift`'s `VoiceWire`. */
@Serializable
private data class VoiceWire(
    val id: String,
    val name: String,
    val language: String,
    val quality: String,
    val isDefault: Boolean,
)

/**
 * The phone's own voice behind the kit's `SpeechEngine`: the facade's
 * [SpeechBackend] over `android.speech.tts.TextToSpeech`.
 *
 * Nothing here decides anything about playback. Which sentence is next, what a
 * skip does to a completion that was already in flight, how a speed change
 * picks the sentence back up — all of that is `NarrationController`'s, in the
 * kit, where it is tested against a mock. This class does three things the
 * kit cannot: drive the platform synthesizer, put every callback on the main
 * looper (the controller is main-thread-confined), and paper over the one
 * thing Android's synthesizer does not have.
 *
 * **Pause.** `TextToSpeech` cannot pause. So a pause is `stop()` plus the last
 * word boundary, and a resume re-speaks the rest of the sentence under the
 * same request id — with `resumeBase` added back to every boundary the engine
 * then reports, so the kit is never told that the text it handed over was cut.
 * That matters: the controller adds boundaries to its own `activeRequestOrigin`
 * to place the spoken word in the chapter, and offsets into a shortened string
 * would land a page and a half early. `state()` answers `paused` in between,
 * so the controller's stall watchdog reads a held utterance as held rather
 * than as one that fell silent.
 *
 * **Ids.** The platform is given `<requestID>#<generation>`, never the request
 * id itself. A resume re-speaks the same request, and an `onDone` from the
 * *stopped* half of it, arriving late, would otherwise match the utterance now
 * in flight and finish a sentence nobody heard.
 *
 * **Network voices are not offered.** Reading is a zero-egress promise
 * (PRIVACY.md): nothing about the book leaves the device to be read aloud. A
 * voice that says it needs a connection would send the sentence to a server.
 */
class PlatformSpeechBackend(context: Context, private val events: NarrationEvents) : SpeechBackend {

    /** What the platform was asked to say, whole — a resume re-speaks its tail. */
    private class Utterance(
        val id: String,
        val text: String,
        val language: String,
        val voiceID: String,
        val rate: Double,
        val pitch: Double,
        val volume: Double,
    )

    /** An utterance waiting for the engine to finish starting up. */
    private class Pending(val utterance: Utterance, val from: Int)

    private val main = Handler(Looper.getMainLooper())
    private var engine: TextToSpeech? = null
    private var ready = false

    /** The utterance in flight, and the id the *platform* knows it by. */
    private var active: Utterance? = null
    private var activePlatformID: String? = null
    /** Whether audio has actually begun — until it has, `isSpeaking` may lie low. */
    private var started = false
    /** Where in `active.text` the string handed to the platform begins. */
    private var resumeBase = 0
    /** The last word boundary reported, in whole-text UTF-16 offsets. */
    private var spokenUtf16 = 0
    /** Set aside by [pause]; [resume] speaks its remainder. */
    private var held: Utterance? = null
    private var pending: Pending? = null
    private var generation = 0

    /** Hand the platform engine back. Nothing may be spoken afterwards. */
    fun release() {
        stop()
        engine?.shutdown()
        engine = null
        ready = false
    }

    // MARK: SpeechBackend

    override fun speak(
        requestID: String,
        text: String,
        language: String,
        voiceID: String,
        rate: Double,
        pitch: Double,
        volume: Double,
    ) {
        val utterance = Utterance(requestID, text, language, voiceID, rate, pitch, volume)
        held = null
        val tts = engine
        if (tts == null || !ready) {
            // One request is queued, never a list: the controller speaks one
            // sentence at a time, and a queue would say the ones it cancelled.
            pending = Pending(utterance, 0)
            active = utterance
            activePlatformID = null
            started = false
            return
        }
        enqueue(tts, utterance, from = 0)
    }

    override fun pause() {
        val utterance = active ?: return
        held = utterance
        // Stale from here: the flush that follows must not look like a finish.
        activePlatformID = null
        pending = null
        started = false
        engine?.stop()
    }

    override fun resume() {
        val utterance = held ?: return
        held = null
        val from = wordBoundary(utterance.text, spokenUtf16)
        val tts = engine
        if (tts == null || !ready) {
            pending = Pending(utterance, from)
            active = utterance
            activePlatformID = null
            started = false
            return
        }
        enqueue(tts, utterance, from)
        // The kit hears a fresh beginning for the same sentence, which is
        // what a resume that re-speaks actually is.
        events.didBegin(utterance.id)
    }

    override fun stop() {
        active = null
        activePlatformID = null
        held = null
        pending = null
        started = false
        resumeBase = 0
        spokenUtf16 = 0
        engine?.stop()
    }

    /**
     * Truthful, because this is the only evidence the controller's stall
     * watchdog has: a completion callback going missing is the case it exists
     * for, and a flag that only those callbacks set would say `speaking`
     * forever exactly when it mattered.
     *
     * The one softening is the gap between asking and hearing: `isSpeaking`
     * reads false while the engine gets going (and while one waits for
     * `onInit`), so an utterance that has not reported `onStart` yet still
     * counts as speaking. Once it has, the platform is believed.
     */
    override fun state(): String = when {
        held != null -> PAUSED
        pending != null -> SPEAKING
        activePlatformID == null -> IDLE
        !started -> SPEAKING
        engine?.isSpeaking == true -> SPEAKING
        else -> IDLE
    }

    /**
     * The installed voices, network ones left out (see the class note). Android
     * gives a voice a machine name — `en-us-x-sfg#female_1-local` — so the
     * readable half is its locale, with the variant after it when there is one.
     */
    override fun voicesJSON(): String {
        val tts = engine?.takeIf { ready } ?: return "[]"
        val defaultID = runCatching { tts.defaultVoice?.name }.getOrNull()
        val voices = installedVoices(tts).map { voice ->
            VoiceWire(
                id = voice.name,
                name = displayName(voice),
                language = voice.locale.toLanguageTag(),
                quality = quality(voice),
                isDefault = voice.name == defaultID,
            )
        }
        return json.encodeToString(voices)
    }

    // MARK: Driving the engine

    private fun engineInitialized(status: Int) {
        val tts = engine
        if (status != TextToSpeech.SUCCESS || tts == null) {
            Log.w(TAG, "text-to-speech unavailable: status $status")
            ready = false
            val waiting = pending ?: active?.let { Pending(it, 0) }
            pending = null
            active = null
            activePlatformID = null
            // The kit turns this into its own sentence; nothing here writes copy.
            waiting?.let { events.didFail(it.utterance.id, "engine init $status") }
            return
        }
        ready = true
        val waiting = pending ?: return
        pending = null
        enqueue(tts, waiting.utterance, waiting.from)
    }

    private fun enqueue(tts: TextToSpeech, utterance: Utterance, from: Int) {
        val start = from.coerceIn(0, utterance.text.length)
        val platformID = "${utterance.id}#${++generation}"
        active = utterance
        activePlatformID = platformID
        started = false
        resumeBase = start
        spokenUtf16 = start
        applyVoice(tts, utterance)
        tts.setSpeechRate(utterance.rate.toFloat())
        tts.setPitch(utterance.pitch.toFloat())
        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, utterance.volume.toFloat())
        }
        val body = utterance.text.substring(start)
        val result = tts.speak(body, TextToSpeech.QUEUE_FLUSH, params, platformID)
        if (result != TextToSpeech.SUCCESS) {
            activePlatformID = null
            active = null
            events.didFail(utterance.id, "speak refused ($result)")
        }
    }

    /**
     * The named voice while it is installed; otherwise the book's own language,
     * falling back to the device's. Choosing again by a second rule would undo
     * the kit's choice, which was made with the whole installed list and the
     * reader's stored preference in hand.
     */
    private fun applyVoice(tts: TextToSpeech, utterance: Utterance) {
        if (utterance.voiceID.isNotEmpty()) {
            val named = installedVoices(tts).firstOrNull { it.name == utterance.voiceID }
            if (named != null) {
                tts.voice = named
                return
            }
        }
        val wanted = utterance.language.takeIf { it.isNotBlank() }
            ?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()
        val result = runCatching { tts.setLanguage(wanted) }.getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
            runCatching { tts.setLanguage(Locale.getDefault()) }
        }
    }

    private fun installedVoices(tts: TextToSpeech): List<Voice> =
        runCatching { tts.voices }.getOrNull().orEmpty().filter { voice ->
            !voice.isNetworkConnectionRequired &&
                voice.features?.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) != true
        }

    private fun quality(voice: Voice): String = when {
        voice.quality >= Voice.QUALITY_VERY_HIGH -> "premium"
        voice.quality >= Voice.QUALITY_HIGH -> "enhanced"
        else -> "standard"
    }

    private fun displayName(voice: Voice): String {
        val locale = voice.locale.getDisplayName(voice.locale).ifBlank { voice.locale.toLanguageTag() }
        val variant = voice.name.substringAfter('#', "").substringBefore("-local")
            .replace('_', ' ').trim()
        return if (variant.isEmpty()) locale else "$locale ($variant)"
    }

    /**
     * A resume point that is a whole character: word boundaries land between
     * words, but clamping and a stray low surrogate would both cut a code
     * point in half and hand the engine a replacement character to pronounce.
     */
    private fun wordBoundary(text: String, offset: Int): Int {
        var index = offset.coerceIn(0, text.length)
        if (index in 1 until text.length && Character.isLowSurrogate(text[index])) index -= 1
        return index
    }

    // MARK: The platform's reports, all of them on the main looper

    private val listener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) = post(utteranceId) { utterance ->
            started = true
            events.didBegin(utterance.id)
        }

        override fun onDone(utteranceId: String?) = post(utteranceId) { utterance ->
            active = null
            activePlatformID = null
            started = false
            events.didFinish(utterance.id)
        }

        /**
         * Always something this side asked for — a skip, a speed change, the
         * sleep timer, a pause. Reporting it as a finish would advance the book
         * by a sentence the reader never heard, so it is reported as nothing.
         */
        override fun onStop(utteranceId: String?, interrupted: Boolean) = Unit

        override fun onError(utteranceId: String?, errorCode: Int) = post(utteranceId) { utterance ->
            active = null
            activePlatformID = null
            started = false
            events.didFail(utterance.id, "tts error $errorCode")
        }

        @Deprecated("Replaced by onError(String, Int); some engines still call this one.")
        override fun onError(utteranceId: String?) = post(utteranceId) { utterance ->
            active = null
            activePlatformID = null
            started = false
            events.didFail(utterance.id, "tts error")
        }

        override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) =
            post(utteranceId) { utterance ->
                // A word boundary is audio, whatever else the engine forgot to say.
                started = true
                val base = resumeBase
                spokenUtf16 = base + start
                events.willSpeak(utterance.id, (base + start).toLong(), (base + end).toLong())
            }

        /**
         * Every report goes to the main looper and is dropped unless it belongs
         * to the utterance actually in flight — the guard `AVSpeechEngine`
         * makes by matching the `AVSpeechUtterance` object.
         */
        private inline fun post(platformID: String?, crossinline body: (Utterance) -> Unit) {
            if (platformID == null) return
            main.post {
                if (platformID != activePlatformID) return@post
                val utterance = active ?: return@post
                body(utterance)
            }
        }
    }

    // Last, because the listener above has to exist before the engine can be
    // handed it: Kotlin initializes properties in declaration order.
    init {
        val tts = TextToSpeech(context.applicationContext) { status ->
            main.post { engineInitialized(status) }
        }
        tts.setOnUtteranceProgressListener(listener)
        engine = tts
    }

    private companion object {
        const val TAG = "Readr.Speech"
        const val IDLE = "idle"
        const val SPEAKING = "speaking"
        const val PAUSED = "paused"
        val json = Json { encodeDefaults = true }
    }
}
