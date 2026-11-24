package com.readrai.readr.kit

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Kokoro PCM playback, with no Android TextToSpeech dependency or fallback. */
class KokoroSpeechBackend(context: Context, private val events: NarrationEvents) : SpeechBackend {
    private val store = KokoroModelStore.get(context)
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val revision = AtomicLong()
    @Volatile private var active = false
    @Volatile private var track: AudioTrack? = null
    private var job: Job? = null
    private var prefetchJob: Job? = null
    @Volatile private var playbackStarted = false
    @Volatile private var sentencePrepared = false
    private val buffer = SpeechAudioBuffer()
    private val json = Json { ignoreUnknownKeys = true }
    @Serializable private data class Ahead(val text: String, val language: String, val voiceID: String, val rate: Double) {
        fun key() = voiceID.ifBlank { "kokoro.af_heart" } + "\n" + rate + "\n" + text
        fun speaker() = when (voiceID) { "", "kokoro.af_heart" -> 3; "kokoro.af_bella" -> 2; "kokoro.am_michael" -> 16; else -> -1 }
        fun english() = language.isBlank() || language.substringBefore('-').equals("en", ignoreCase = true)
    }
    private fun ahead(requestsJSON: String): List<Ahead> = try { json.decodeFromString<List<Ahead>>(requestsJSON).take(2) }
    catch (e: Exception) { android.util.Log.e("Readr.Kokoro", "Could not decode narration lookahead"); emptyList() }
    override fun prefetch(requestsJSON: String) {
        prefetchJob?.cancel()
        val requests = ahead(requestsJSON)
        if (requests.isEmpty() || !active) return
        prefetchJob = scope.launch {
            try {
                while (active && (!playbackStarted || !sentencePrepared)) delay(25)
                if (!active || store.state.value != KokoroState.Ready) return@launch
                for (request in requests) {
                    ensureActive()
                    if (!request.english() || request.speaker() < 0 || request.text.length > 1600 || buffer.seconds(request.key()) != null) continue
                    val audio = store.withEngine { it.generate(request.text, request.speaker(), request.rate.toFloat().coerceIn(0.5f, 3f)) }
                    buffer.put(request.key(), audio)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { android.util.Log.w("Readr.Kokoro", "Lookahead synthesis failed; the sentence will be retried when played", e) }
        }
    }
    override fun secondsBuffered(requestsJSON: String): Double {
        var seconds = 0.0
        for (request in ahead(requestsJSON)) seconds += buffer.seconds(request.key()) ?: break
        return seconds
    }

    override fun speak(requestID: String, text: String, language: String, voiceID: String, rate: Double, pitch: Double, volume: Double) {
        stop()
        val token = revision.get()
        if (language.isNotBlank() && language.substringBefore('-').lowercase() != "en") {
            events.didFail(requestID, "unsupportedLanguage")
            return
        }
        val speaker = when (voiceID) {
            "", "kokoro.af_heart" -> 3
            "kokoro.af_bella" -> 2
            "kokoro.am_michael" -> 16
            else -> { events.didFail(requestID, "Choose a Kokoro voice in Appearance"); return }
        }
        if (text.isBlank()) { events.didFinish(requestID); return }
        active = true
        events.didPrepare(requestID)
        job = scope.launch {
            var audio: AudioTrack? = null
            try {
                // Hold the inference mutex only while synthesizing. Playback
                // releases it so future sentences can be prepared concurrently.
                store.ensureInstalled()
                val sampleRate = 24000
                val output = AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(sampleRate).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(maxOf(sampleRate * 4 * 3, AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)))
                    .setTransferMode(AudioTrack.MODE_STREAM).build()
                audio = output; track = output
                check(output.state == AudioTrack.STATE_INITIALIZED) { "Audio output unavailable" }
                // A short heading may be smaller than the three-second output
                // buffer. Default startup thresholds would wait forever for it.
                if (android.os.Build.VERSION.SDK_INT >= 31) output.setStartThresholdInFrames(1)
                else output.setBufferSizeInFrames(sampleRate / 8)
                output.setVolume(volume.toFloat().coerceIn(0f, 1f))
                var written = 0L
                val prepared = buffer.take(Ahead(text, language, voiceID, rate).key())
                coroutineScope {
                    // Keep one chunk ahead while AudioTrack consumes the current
                    // chunk. Future-sentence lookahead waits until this sentence
                    // is prepared, so it cannot starve a long sentence midway.
                    val generatedChunks = Channel<KokoroAudio>(capacity = 1)
                    val producer = launch {
                        try {
                            if (prepared != null) generatedChunks.send(prepared)
                            else for (chunk in chunks(text)) {
                                ensureActive(); checkCurrent(token)
                                val generated = store.withEngine { it.generate(chunk, speaker, rate.toFloat().coerceIn(0.5f, 3f)) }
                                ensureActive(); checkCurrent(token)
                                generatedChunks.send(generated)
                            }
                            checkCurrent(token)
                            sentencePrepared = true
                        } catch (e: CancellationException) { generatedChunks.close(e); throw e }
                        catch (e: Exception) { generatedChunks.close(e) }
                        finally { generatedChunks.close() }
                    }
                    try {
                        for (generated in generatedChunks) {
                            checkCurrent(token)
                            check(generated.sampleRate == sampleRate) { "Unsupported voice sample rate" }
                            var offset = 0
                            if (!playbackStarted) output.play()
                            while (offset < generated.samples.size) {
                                checkCurrent(token)
                                val amount = if (!playbackStarted) minOf(sampleRate / 8, generated.samples.size) else generated.samples.size - offset
                                val n = output.write(generated.samples, offset, amount, AudioTrack.WRITE_BLOCKING)
                                check(n > 0) { "Audio playback interrupted" }
                                offset += n; written += n
                                if (!playbackStarted) {
                                    playbackStarted = true
                                    post(token) { events.didBegin(requestID); events.willSpeak(requestID, 0, text.length.toLong()) }
                                }
                            }
                        }
                    } finally { producer.cancel(); generatedChunks.cancel() }
                }
                check(written > 0) { "Voice produced no audio" }
                if (android.os.Build.VERSION.SDK_INT < 31 && written < output.bufferSizeInFrames) {
                    // Older APIs cannot lower the start threshold directly.
                    // Prime their minimum buffer with a brief silent tail.
                    val padding = FloatArray(output.bufferSizeInFrames - written.toInt())
                    var offset = 0
                    while (offset < padding.size) {
                        checkCurrent(token)
                        val count = output.write(padding, offset, padding.size - offset, AudioTrack.WRITE_BLOCKING)
                        check(count > 0); offset += count; written += count
                    }
                }
                val deadline = System.nanoTime() + (written * 1_000_000_000L / sampleRate) + 5_000_000_000L
                while ((output.playbackHeadPosition.toLong() and 0xffffffffL) < written) {
                    checkCurrent(token)
                    check(System.nanoTime() < deadline) { "Audio output stalled" }
                    delay(15)
                }
                post(token) { active = false; events.didFinish(requestID) }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (revision.get() == token) {
                    android.util.Log.e("Readr.Kokoro", "Narration synthesis/playback failed", e)
                    post(token) { active = false; events.didFail(requestID, "Kokoro could not prepare or play this sentence") }
                }
            } finally {
                audio?.let { output -> synchronized(this@KokoroSpeechBackend) {
                    if (track === output) track = null
                    output.release()
                } }
            }
        }
    }
    private fun checkCurrent(token: Long) {
        if (revision.get() != token || Thread.currentThread().isInterrupted) throw CancellationException()
    }
    private fun post(token: Long, body: () -> Unit) { main.post { if (revision.get() == token) body() } }
    override fun stop() {
        revision.incrementAndGet(); active = false; playbackStarted = false; sentencePrepared = false
        prefetchJob?.cancel(); prefetchJob = null
        job?.cancel(); job = null
        synchronized(this) { track?.let { if (it.state == AudioTrack.STATE_INITIALIZED) { it.pause(); it.flush() } } }
    }
    fun release() { stop(); buffer.clear(); scope.cancel() }
    override fun state() = if (active) "speaking" else "idle"
    // Voice names remain selectable before installation. Listen/Settings explain
    // the one-time download; no installed system voices are enumerated.
    override fun voicesJSON() = """{"ready":true,"voices":[{"id":"kokoro.af_heart","name":"Heart · Kokoro","language":"en-US","quality":"premium","isDefault":true},{"id":"kokoro.af_bella","name":"Bella · Kokoro","language":"en-US","quality":"premium","isDefault":false},{"id":"kokoro.am_michael","name":"Michael · Kokoro","language":"en-US","quality":"premium","isDefault":false}]}"""

    internal companion object {
        fun chunks(text: String): List<String> {
            val result = mutableListOf<String>()
            var rest = text.trim()
            while (rest.length > 400) {
                val split = rest.lastIndexOf(' ', 400).takeIf { it > 0 } ?: 400
                result.add(rest.take(split)); rest = rest.drop(split).trimStart()
            }
            if (rest.isNotEmpty()) result.add(rest)
            return result
        }
    }
}
