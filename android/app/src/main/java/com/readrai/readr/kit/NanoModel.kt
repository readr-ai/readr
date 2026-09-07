package com.readrai.readr.kit

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
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
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Gemini Nano, through ML Kit's GenAI Prompt API — the facade's
 * [OnDeviceModel], and the only part of Readr that can see AICore.
 *
 * Two answers, one object. [readiness] says whether this phone can run the
 * model at all; [generate] runs one question through it and streams the answer
 * back. Both speak in bare tokens and reason codes: the sentence a reader sees
 * is written on the Swift side (`OnDevice.swift`), so this class writes no
 * reader-facing copy and the Android card says what the Apple one says.
 *
 * Nothing here reaches the network. AICore runs the model on the phone, and
 * the passages a question carries never leave it.
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
 */
class NanoModel(context: Context) : OnDeviceModel {
    private val appContext = context.applicationContext
    private val packages = appContext.packageManager

    /** One client for the process; ML Kit's own worker pool does the work. */
    @Volatile private var client: GenerativeModel? = null

    /** Generations in flight, by the handle the facade cancels with. */
    private val running = ConcurrentHashMap<Long, Job>()
    private val handles = AtomicLong(1)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun readiness(): String = try {
        when {
            !hasSystemSupport() -> UNSUPPORTED
            else -> when (checkStatus()) {
                FeatureStatus.AVAILABLE -> READY
                // Fixable by waiting: the model is on its way. The facade
                // turns this into "Gemini Nano is still downloading."
                FeatureStatus.DOWNLOADING, FeatureStatus.DOWNLOADABLE -> "$UNAVAILABLE:$DOWNLOADING"
                else -> UNSUPPORTED
            }
        }
    } catch (e: Throwable) {
        // A check that cannot be made is not a model that can answer. Every
        // ML Kit call is wrapped: on a phone with a stub AICore the failure
        // modes are many and none of them mean "ready".
        UNSUPPORTED
    }

    override fun generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
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
                val request = request(model, instructions, prompt, maxOutputTokens)
                // ML Kit hands back the new text; the facade wants the whole
                // answer so far, which is what `SnapshotAnswerStream` reads —
                // so the accumulating happens here, on this side of the bridge.
                val answer = StringBuilder()
                val response = model.generateContent(
                    request,
                    StreamingCallback { text ->
                        val snapshot = synchronized(answer) { accumulate(answer, text) }
                        if (isActive) sink.snapshot(snapshot)
                    },
                )
                if (!isActive) return@launch
                val finished = finalText(response, synchronized(answer) { answer.toString() })
                if (declined(response)) sink.failed(DECLINED) else sink.completed(finished)
            } catch (e: CancellationException) {
                // The facade asked for the stop and owns what happens next:
                // neither ending is reported, as the protocol says.
                throw e
            } catch (e: Throwable) {
                sink.failed(code(e))
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

    override fun cancel(handle: Long) {
        running.remove(handle)?.cancel()
    }

    // ---- Readiness -------------------------------------------------------

    /**
     * ML Kit's own answer, on a leash. `checkStatus` binds to AICore, which on
     * a phone that has a broken or half-installed one can sit there; a
     * settings screen must not.
     */
    private fun checkStatus(): Int = runBlocking {
        withTimeoutOrNull(STATUS_TIMEOUT_MS) {
            client()?.checkStatus() ?: FeatureStatus.UNAVAILABLE
        } ?: FeatureStatus.UNAVAILABLE
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

    // ---- Generating ------------------------------------------------------

    private fun client(): GenerativeModel? {
        client?.let { return it }
        return synchronized(this) {
            client ?: try {
                Generation.getClient().also { client = it }
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
     */
    private suspend fun request(
        model: GenerativeModel,
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
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
        // Some warmth: greedy-ish decoding is what sends a small model round
        // the same sentence, which is the loop `RepetitionGuard` then has to
        // cut. The same figure the Apple provider uses.
        builder.temperature = TEMPERATURE
        return builder.build()
    }

    private suspend fun supportsSystemPrompt(model: GenerativeModel): Boolean = try {
        model.isSystemPromptAvailable()
    } catch (e: Throwable) {
        false
    }

    /**
     * The next cumulative snapshot. ML Kit's streaming callback is documented
     * as delivering the new text, but a build that hands back the whole answer
     * each time would otherwise double every word — so a chunk that already
     * contains everything seen so far replaces it rather than being appended.
     */
    private fun accumulate(answer: StringBuilder, chunk: String): String {
        if (chunk.length >= answer.length && chunk.startsWith(answer)) {
            answer.setLength(0)
            answer.append(chunk)
        } else {
            answer.append(chunk)
        }
        return answer.toString()
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
     * The reason code the facade turns into a sentence. Anything unmapped is
     * "" — the facade's "Gemini Nano couldn't answer that on this phone."
     */
    private fun code(e: Throwable): String {
        val failure = e as? GenAiException ?: return ""
        return when (failure.errorCode) {
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

        const val TEMPERATURE = 0.5f
        const val STATUS_TIMEOUT_MS = 5_000L
    }
}
