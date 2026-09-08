package com.readrai.readr.kit

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.common.StreamingCallback
import com.google.mlkit.genai.prompt.Candidate
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.GenerateContentResponse
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * Gemini Nano, through ML Kit's GenAI Prompt API — the facade's
 * [OnDeviceModel], and the only part of Readr that can see AICore.
 *
 * Three answers, one object. [readiness] says whether this phone can run the
 * model at all, [windowTokens] how much it can hold, and [generate] runs one
 * question through it and streams the answer back. All of them speak in bare
 * tokens, numbers and reason codes: the sentence a reader sees is written on
 * the Swift side (`OnDevice.swift`), so this class writes no reader-facing
 * copy and the Android card says what the Apple one says.
 *
 * Nothing here reaches the network. AICore runs the model on the phone, and
 * the passages a question carries never leave it. The model's own download is
 * AICore's to fetch and to schedule; [readiness] only asks for it to start.
 *
 * Eligibility is narrow and worth stating plainly: Android 14+, a flagship
 * with AICore installed and the model downloaded, and Readr on screen — AICore
 * refuses a background app. Everything else answers `unsupported`, which is
 * what keeps the card off the reader's list of things they could choose.
 *
 * The stub matters: Firebase Test Lab devices and every emulator image ship a
 * `com.google.android.aicore` package that exists and does nothing, and ML
 * Kit's own check answers UNAVAILABLE there. Both are read as "not on this
 * phone".
 *
 * **Every call into ML Kit runs on a leash.** `checkStatus`, `getTokenLimit`
 * and the cancellation join all bind to AICore, and a phone with a broken or
 * half-installed one can sit inside that bind without ever suspending — which
 * `withTimeout` cannot interrupt. So each of them runs on a thread of its own
 * and is waited for with a bounded `join`: the Swift caller (a cooperative
 * thread, and sometimes a settings screen) is never held longer than that.
 */
class NanoModel(context: Context) : OnDeviceModel {
    private val appContext = context.applicationContext
    private val packages = appContext.packageManager

    /** One client for the process; ML Kit's own worker pool does the work. */
    @Volatile private var client: GenerativeModel? = null

    /**
     * Whether this client takes a system instruction. One question per
     * client — it is a property of the model, not of a request, and asking it
     * per generation put an AICore round trip in front of every answer.
     */
    @Volatile private var systemPrompt: Boolean? = null

    /** The window this client reports, in tokens. Asked once. */
    @Volatile private var tokenLimit: Long = 0

    /** True while a model download this class started is still running. */
    private val downloading = AtomicBoolean(false)

    /** So a runtime that streams cumulatively is noted once, not per token. */
    private val cumulativeNoted = AtomicBoolean(false)

    /** Generations in flight, by the handle the facade cancels with. */
    private val running = ConcurrentHashMap<Long, Job>()
    private val handles = AtomicLong(1)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun readiness(): String = try {
        when {
            !hasSystemSupport() -> UNSUPPORTED
            else -> when (checkStatus()) {
                FeatureStatus.AVAILABLE -> READY
                // On its way already: waiting is the whole fix.
                FeatureStatus.DOWNLOADING -> "$UNAVAILABLE:$DOWNLOADING"
                // Available to this phone but not on it. Saying "downloading"
                // without asking for the download left a reader watching a
                // card that would never change; ML Kit fetches nothing until
                // an app asks, so this asks — once — and reports the same
                // waiting state. AICore owns the schedule from there.
                FeatureStatus.DOWNLOADABLE -> {
                    startDownload()
                    "$UNAVAILABLE:$DOWNLOADING"
                }
                else -> UNSUPPORTED
            }
        }
    } catch (e: Throwable) {
        // A check that cannot be made is not a model that can answer. Every
        // ML Kit call is wrapped: on a phone with a stub AICore the failure
        // modes are many and none of them mean "ready".
        UNSUPPORTED
    }

    /**
     * The window ML Kit reports for this model, or `0` when it cannot say —
     * an AICore that is not there, a model not yet downloaded, an older
     * runtime. The facade turns `0` into its own documented fallback; a
     * guessed number reported as the model's own would be worse than none.
     */
    override fun windowTokens(): Long {
        tokenLimit.takeIf { it > 0 }?.let { return it }
        val reported = onALeash(STATUS_TIMEOUT_MS, 0L) {
            runBlocking { client()?.getTokenLimit()?.toLong() ?: 0L }
        }
        if (reported > 0) tokenLimit = reported
        return reported
    }

    override fun generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
        temperature: Double,
        sink: OnDeviceSink,
    ): Long {
        val handle = handles.getAndIncrement()
        // Foreground-only, and AICore says so with an exception several
        // seconds in. Asked first, the reader gets a sentence at once.
        if (isBackgrounded()) {
            sink.failed(BACKGROUND)
            return handle
        }
        val job = scope.launch {
            try {
                val model = client() ?: throw IllegalStateException("no on-device model")
                val request = request(model, instructions, prompt, maxOutputTokens, temperature)
                // What has been sent, so a cumulative runtime can be told from
                // an incremental one — and so a response that carries no final
                // text of its own still has one.
                val sent = StringBuilder()
                val response = model.generateContent(
                    request,
                    StreamingCallback { text ->
                        val piece = synchronized(sent) {
                            delta(sent.toString(), text).also { sent.append(it) }
                        }
                        if (isActive && piece.isNotEmpty()) sink.delta(piece)
                    },
                )
                if (!isActive) return@launch
                val finished = finalText(response, synchronized(sent) { sent.toString() })
                if (declined(response)) sink.failed(DECLINED) else sink.completed(finished)
            } catch (e: CancellationException) {
                // The facade asked for the stop and owns what happens next:
                // neither ending is reported, as the protocol says.
                throw e
            } catch (e: Throwable) {
                // A null code is a generation that was cancelled somewhere
                // inside ML Kit rather than one that failed — the same
                // "neither ending" a coroutine cancellation gets.
                code(e)?.let { sink.failed(it) }
            } finally {
                running.remove(handle)
            }
        }
        running[handle] = job
        // A generation that finished between `launch` and here has already
        // removed itself; putting it back would leak the entry.
        if (job.isCompleted) running.remove(handle)
        return handle
    }

    /**
     * Stop the generation `handle` names, and come back only once its sink
     * can no longer be called — the facade lets go of that sink the moment
     * this returns. The join is bounded: a runtime wedged inside AICore must
     * not take the reader's cancel with it.
     */
    override fun cancel(handle: Long) {
        val job = running.remove(handle) ?: return
        onALeash(CANCEL_TIMEOUT_MS, Unit) { runBlocking { job.cancelAndJoin() } }
    }

    // ---- Readiness -------------------------------------------------------

    /** ML Kit's own answer, on a leash — see the class note. */
    private fun checkStatus(): Int = onALeash(STATUS_TIMEOUT_MS, FeatureStatus.UNAVAILABLE) {
        runBlocking { client()?.checkStatus() ?: FeatureStatus.UNAVAILABLE }
    }

    /**
     * Ask AICore to fetch the model, once. Progress is deliberately ignored:
     * the card says "still downloading" and nothing more, the schedule
     * (metered networks, battery, idle time) is AICore's own, and a percentage
     * this app cannot influence is not information a reader can act on.
     */
    private fun startDownload() {
        if (!downloading.compareAndSet(false, true)) return
        val model = client()
        if (model == null) {
            downloading.set(false)
            return
        }
        scope.launch {
            try {
                model.download().collect { }
            } catch (e: Throwable) {
                // A download that failed is not a crash. The next readiness
                // read asks AICore again, and may ask for it again.
            } finally {
                downloading.set(false)
            }
        }
    }

    /** Android 14+, and AICore installed — not the do-nothing stub. */
    private fun hasSystemSupport(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasAICore()

    private fun hasAICore(): Boolean {
        val info = try {
            packages.getPackageInfo(AICORE_PACKAGE, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            return false
        }
        return info.versionName?.contains("stub", ignoreCase = true) != true
    }

    /**
     * Whether this process is out of sight. AICore will not run a generation
     * for a backgrounded app, and `ActivityManager` answers without pulling in
     * a lifecycle library for one boolean.
     */
    private fun isBackgrounded(): Boolean = try {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        state.importance > ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    } catch (e: Throwable) {
        false
    }

    /**
     * [work] on a thread of its own, waited for no longer than [millis].
     * A call that overruns leaves [fallback] and its thread behind — daemon,
     * so it can never hold the process open — because the alternative is a
     * caller that never comes back.
     */
    private fun <T> onALeash(millis: Long, fallback: T, work: () -> T): T {
        val result = AtomicReference(fallback)
        val thread = Thread {
            try {
                result.set(work())
            } catch (e: Throwable) {
                // The fallback stands.
            }
        }
        thread.isDaemon = true
        thread.start()
        thread.join(millis)
        return result.get()
    }

    // ---- Generating ------------------------------------------------------

    private fun client(): GenerativeModel? {
        client?.let { return it }
        return synchronized(this) {
            client ?: try {
                Generation.getClient().also {
                    client = it
                    systemPrompt = null
                    tokenLimit = 0
                }
            } catch (e: Throwable) {
                null
            }
        }
    }

    /**
     * The request, with the instructions in the system slot where the model
     * supports one and folded into the prompt where it does not — an
     * instruction the model never reads is an answer written to the wrong
     * rules.
     *
     * [temperature] is the caller's: `0` for the kit's one-word classifier
     * hop, which is a routing decision and wants the likeliest token every
     * time, and some warmth for the answer, because greedy decoding is what
     * sends a small model round the same sentence.
     */
    private suspend fun request(
        model: GenerativeModel,
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
        temperature: Double,
    ): GenerateContentRequest {
        val systemPrompt = instructions.isNotBlank() && supportsSystemPrompt(model)
        val builder = if (systemPrompt) {
            GenerateContentRequest.Builder(SystemInstruction(instructions), TextPart(prompt))
        } else if (instructions.isBlank()) {
            GenerateContentRequest.Builder(TextPart(prompt))
        } else {
            GenerateContentRequest.Builder(TextPart(instructions + "\n\n" + prompt))
        }
        builder.maxOutputTokens = maxOutputTokens.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
        builder.temperature = temperature.coerceIn(0.0, 1.0).toFloat()
        return builder.build()
    }

    /** Asked once per client: it is the model's answer, not the request's. */
    private suspend fun supportsSystemPrompt(model: GenerativeModel): Boolean {
        systemPrompt?.let { return it }
        val supported = try {
            model.isSystemPromptAvailable()
        } catch (e: Throwable) {
            false
        }
        systemPrompt = supported
        return supported
    }

    /**
     * What is NEW in [chunk], given the [sent] so far.
     *
     * ML Kit's callback is `onNewText(String)`, and that name is all the
     * documentation the AAR ships — it carries no javadoc, and neither a
     * sources nor a javadoc jar is published for `genai-common:1.0.0-beta4`.
     * So the argument is read as **the delta**, which is what the name says,
     * and the accumulating happens on the Swift side where the kit wants it.
     *
     * The one hedge is for a build that hands back the whole answer each
     * time: a chunk that begins with everything already sent and is longer
     * than it would double every word if appended, so its tail is taken
     * instead and the fact is logged once. Anything else is a fresh delta.
     */
    internal fun delta(sent: String, chunk: String): String {
        if (sent.isEmpty() || chunk.length <= sent.length || !chunk.startsWith(sent)) return chunk
        if (cumulativeNoted.compareAndSet(false, true)) {
            Log.i(TAG, "ML Kit streamed a cumulative snapshot; reading the new text off its tail")
        }
        return chunk.substring(sent.length)
    }

    /** The model's own final text, or what streamed if it sent none. */
    private fun finalText(response: GenerateContentResponse, streamed: String): String {
        val text = try {
            response.candidates.firstOrNull()?.text.orEmpty()
        } catch (e: Throwable) {
            ""
        }
        return if (text.isNotBlank()) text else streamed
    }

    /** A guardrail refusal comes back as a candidate that stopped for neither reason. */
    private fun declined(response: GenerateContentResponse): Boolean = try {
        val candidate = response.candidates.firstOrNull()
        candidate != null &&
            candidate.text.isNullOrBlank() &&
            candidate.finishReason == Candidate.FinishReason.OTHER
    } catch (e: Throwable) {
        false
    }

    /**
     * The reason code the facade turns into a sentence, or `null` for a
     * generation that should report NOTHING.
     *
     * `CANCELLED` is that null: ML Kit raises it for a generation that was
     * stopped, which is the same event as a coroutine cancellation and is
     * already what the caller asked for. Reported as a failure it put "Gemini
     * Nano couldn't answer that on this phone." under an answer the reader
     * themselves had stopped.
     *
     * Anything else unmapped is `""` — the facade's generic sentence.
     */
    internal fun code(e: Throwable): String? {
        val failure = e as? GenAiException ?: return ""
        return when (failure.errorCode) {
            GenAiException.ErrorCode.CANCELLED -> null
            GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> BACKGROUND
            GenAiException.ErrorCode.BUSY,
            GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> BUSY
            GenAiException.ErrorCode.REQUEST_TOO_LARGE -> TOO_LONG
            GenAiException.ErrorCode.NOT_AVAILABLE,
            GenAiException.ErrorCode.NOT_SUPPORTED,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE -> UNAVAILABLE
            else -> ""
        }
    }

    private companion object {
        const val TAG = "NanoModel"
        const val AICORE_PACKAGE = "com.google.android.aicore"

        /** The three readiness tokens the facade parses, and one reason code. */
        const val READY = "ready"
        const val UNAVAILABLE = "unavailable"
        const val UNSUPPORTED = "unsupported"
        const val DOWNLOADING = "downloading"

        /** Failure reason codes; the sentences for them live in the facade. */
        const val BACKGROUND = "background"
        const val BUSY = "busy"
        const val DECLINED = "declined"
        const val TOO_LONG = "tooLong"

        const val STATUS_TIMEOUT_MS = 5_000L
        const val CANCEL_TIMEOUT_MS = 2_000L
    }
}
