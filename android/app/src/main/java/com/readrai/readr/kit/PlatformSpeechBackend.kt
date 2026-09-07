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
 * kit cannot: drive the platform synthesizer and put every callback on the
 * main looper (the controller is main-thread-confined).
 *
 * **There is no pause here.** `TextToSpeech` cannot pause, so
 * `BridgedSpeechEngine` answers the kit's `pausesInPlace` with false and the
 * controller stops this backend on a pause and re-speaks the remainder of the
 * sentence — as a fresh request, from the last word boundary — on play. That
 * is the same path a sleep-timer stop already resumes by, and it lives in the
 * kit where it is unit-tested. This class used to fake a pause instead, and
 * had to rebase every word boundary afterwards so the kit was never told the
 * text had been cut; none of that is needed now, and boundaries reported here
 * are plain offsets into the string that was handed over.
 *
 * **Ids.** The platform is given the request id itself. The controller never
 * speaks one request twice — a re-spoken remainder is a new request with a new
 * id — so the id alone tells a late report from a stopped utterance apart from
 * the one in flight.
 *
 * **Network voices are not offered.** Reading is a zero-egress promise
 * (PRIVACY.md): nothing about the book leaves the device to be read aloud. A
 * voice that says it needs a connection would send the sentence to a server.
 */
class PlatformSpeechBackend(context: Context, private val events: NarrationEvents) : SpeechBackend {

    /** What the platform was asked to say. */
    private class Utterance(
        val id: String,
        val text: String,
        val language: String,
        val voiceID: String,
        val rate: Double,
        val pitch: Double,
        val volume: Double,
    )

    private val main = Handler(Looper.getMainLooper())
    private var engine: TextToSpeech? = null
    private var ready = false
    /**
     * Whether the phone has no working synthesizer for us — the engine
     * refused to start, or it has been handed back. A request then fails at
     * once instead of parking in [pending] for a readiness that will never
     * come, which is what left the card on Pause with no sentence and no
     * explanation.
     */
    private var dead = false

    /** The utterance in flight (its own id is what the platform is given). */
    private var active: Utterance? = null
    private var activePlatformID: String? = null
    /** Whether audio has actually begun — until it has, `isSpeaking` may lie low. */
    private var started = false
    /** An utterance waiting for the engine to finish starting up. */
    private var pending: Utterance? = null

    /**
     * The voice the last utterance resolved to, and the (voiceID, language)
     * it was resolved for. Resolving walks `tts.voices`, which is a list of
     * every installed voice on the phone; doing it once a *sentence* is a
     * walk a second for as long as the book is read, and the answer cannot
     * change between two sentences of the same book in the same voice.
     */
    private var voiceKey: Pair<String, String>? = null
    private var resolvedVoice: Voice? = null
    /** Why the last resolution left the engine with no language it can read. */
    private var languageFailure: String? = null

    /** Hand the platform engine back. Nothing may be spoken afterwards. */
    fun release() {
        stop()
        engine?.shutdown()
        engine = null
        ready = false
        dead = true
        forgetVoice()
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
        if (dead) {
            // Nothing will ever speak this. Say so rather than parking it.
            events.didFail(requestID, "text-to-speech unavailable")
            return
        }
        val utterance = Utterance(requestID, text, language, voiceID, rate, pitch, volume)
        val tts = engine
        if (tts == null || !ready) {
            // One request is queued, never a list: the controller speaks one
            // sentence at a time, and a queue would say the ones it cancelled.
            pending = utterance
            active = utterance
            activePlatformID = null
            started = false
            return
        }
        enqueue(tts, utterance)
    }

    override fun stop() {
        active = null
        activePlatformID = null
        pending = null
        started = false
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
     *
     * Never `paused`: this backend is stopped rather than paused (see the
     * class note), so there is no held utterance to report.
     */
    override fun state(): String = when {
        pending != null -> SPEAKING
        activePlatformID == null -> IDLE
        !started -> SPEAKING
        engine?.isSpeaking == true -> SPEAKING
        else -> IDLE
    }

    /**
     * The installed voices, network ones left out (see the class note). Android
     * gives a voice a machine name — `en-us-x-sfg#female_1-local` — so the
     * readable half is its locale, with whatever tells it from its siblings
     * after it (see [variant]).
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
            // Dead for good: an engine that would not start does not start
            // later, and a request parked waiting for it would hold the card
            // on Pause for ever. Hand back whatever the platform gave us.
            dead = true
            engine?.shutdown()
            engine = null
            forgetVoice()
            val waiting = pending ?: active
            pending = null
            active = null
            activePlatformID = null
            // The kit turns this into its own sentence; nothing here writes copy.
            waiting?.let { events.didFail(it.id, "engine init $status") }
            return
        }
        ready = true
        // A fresh engine has its own voices; whatever was resolved against the
        // last one means nothing to it.
        forgetVoice()
        val waiting = pending ?: return
        pending = null
        enqueue(tts, waiting)
        // Only now, with the sentence that was waiting already on its way:
        // the kit may pick a voice on this and re-speak, and it should be
        // re-speaking something rather than racing the first dispatch.
        events.voicesReady()
    }

    private fun enqueue(tts: TextToSpeech, utterance: Utterance) {
        active = utterance
        activePlatformID = utterance.id
        started = false
        val unreadable = applyVoice(tts, utterance)
        if (unreadable != null) {
            // No voice and no language: the engine would take the sentence and
            // say nothing, which reads to the kit as a stall a second later.
            activePlatformID = null
            active = null
            events.didFail(utterance.id, unreadable)
            return
        }
        tts.setSpeechRate(utterance.rate.toFloat())
        tts.setPitch(utterance.pitch.toFloat())
        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, utterance.volume.toFloat())
        }
        val result = tts.speak(utterance.text, TextToSpeech.QUEUE_FLUSH, params, utterance.id)
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
     *
     * Resolved once per (voice, language) and remembered: the walk over
     * `tts.voices` is the expensive part, and the answer is the same for every
     * sentence of a book read in one voice. Null when the engine can speak;
     * otherwise the diagnostic for a failure — an engine left with no language
     * it has data for would take the sentence and say nothing at all.
     */
    private fun applyVoice(tts: TextToSpeech, utterance: Utterance): String? {
        val key = utterance.voiceID to utterance.language
        if (key == voiceKey) {
            resolvedVoice?.let { runCatching { tts.voice = it } }
            return languageFailure
        }
        voiceKey = key
        resolvedVoice = null
        languageFailure = null
        if (utterance.voiceID.isNotEmpty()) {
            val named = installedVoices(tts).firstOrNull { it.name == utterance.voiceID }
            if (named != null) {
                resolvedVoice = named
                runCatching { tts.voice = named }
                return null
            }
        }
        val wanted = utterance.language.takeIf { it.isNotBlank() }
            ?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()
        val result = runCatching { tts.setLanguage(wanted) }.getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        if (result != TextToSpeech.LANG_MISSING_DATA && result != TextToSpeech.LANG_NOT_SUPPORTED) return null
        val fallback = runCatching { tts.setLanguage(Locale.getDefault()) }
            .getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        if (fallback != TextToSpeech.LANG_MISSING_DATA && fallback != TextToSpeech.LANG_NOT_SUPPORTED) return null
        languageFailure = "language missing ($fallback)"
        return languageFailure
    }

    /** Nothing resolved holds against a different engine. */
    private fun forgetVoice() {
        voiceKey = null
        resolvedVoice = null
        languageFailure = null
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
        val variant = variant(voice.name)
        return if (variant.isEmpty()) locale else "$locale · $variant"
    }

    /**
     * What tells one installed voice from another. Android gives a voice a
     * machine name and no human one, in two common shapes:
     * `en-us-x-sfg#female_1-local`, where a `#` marks the variant, and
     * `en-us-x-tpd-local`, where nothing does and the `x-` token is all there
     * is. Google's engine ships nine local English voices of the second shape,
     * and the picker showed nine rows all reading "English (United States)"
     * until this took it into account: a list whose rows cannot be told apart
     * is not a picker.
     */
    private fun variant(name: String): String {
        val marked = name.substringAfter('#', "")
        val raw = if (marked.isNotEmpty()) marked else name.substringAfter("-x-", "")
        return raw.substringBefore("-local").substringBefore("-network")
            .replace('_', ' ').replace('-', ' ').trim()
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
                // Plain offsets into the text this backend was handed: nothing
                // here shortens a request, so there is nothing to add back.
                events.willSpeak(utterance.id, start.toLong(), end.toLong())
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
        val json = Json { encodeDefaults = true }
    }
}
