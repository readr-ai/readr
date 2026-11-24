package com.readrai.readr.kit

import android.content.Context

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream

sealed interface KokoroState {
    data object Missing : KokoroState
    data class Downloading(val progress: Float) : KokoroState
    data object Ready : KokoroState
    data class Failed(val message: String) : KokoroState
}

/** Explicit model installation, separate from offline synthesis. No book text enters this class's network path. */
class KokoroModelStore private constructor(private val context: Context) {
    private val root = File(context.filesDir, "voices/kokoro-int8-v1")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val installLock = Mutex()
    private val engineLock = Mutex()
    private var engine: KokoroSynthesizer? = null
    @Volatile private var download: Job? = null
    private val mutableState = MutableStateFlow<KokoroState>(if (installed()) KokoroState.Ready else KokoroState.Missing)
    val state = mutableState.asStateFlow()

    private fun installed(): Boolean = File(root, "READY").let { it.isFile && it.readText() == SHA256 } &&
        required.all { (name, size) -> File(root, name).length() == size }

    fun prepare() { installation() }
    @Synchronized private fun installation(): Job? {
        if (installed()) { mutableState.value = KokoroState.Ready; return null }
        download?.takeIf { it.isActive }?.let { return it }
        val task = scope.launch(start = CoroutineStart.LAZY) {
            try { install() }
            catch (e: CancellationException) { if (download === currentCoroutineContext()[Job]) mutableState.value = KokoroState.Missing; throw e }
            catch (e: Exception) {
                android.util.Log.e("Readr.Kokoro", "Voice installation failed", e)
                if (download === currentCoroutineContext()[Job]) mutableState.value = KokoroState.Failed("Voice download didn't finish. Check your connection and tap Retry.")
            }
        }
        download = task
        task.start()
        return task
    }
    fun cancelDownload() { download?.cancel(); if (state.value is KokoroState.Downloading) mutableState.value = KokoroState.Missing }

    /** Listen and Settings share the same explicitly cancellable installation. */
    suspend fun ensureInstalled() {
        if (!installed()) installation()?.join()
        check(installed()) { "Kokoro voice is not installed. Download it in Settings and retry." }
    }

    private suspend fun install() = installLock.withLock {
        if (installed()) { mutableState.value = KokoroState.Ready; return@withLock }
        root.parentFile!!.mkdirs()
        val archive = File(root.parentFile, "kokoro.tar.bz2.partial")
        val staging = File(root.parentFile, "kokoro-staging")
        mutableState.value = KokoroState.Downloading(0f)
        try {
            // A single bounded retry. Each retry starts a fresh archive; verified
            // installation is atomic and an interrupted archive is never opened.
            var last: Exception? = null
            for (attempt in 0..1) {
                try { fetch(archive); last = null; break }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { last = e; if (attempt == 0) delay(800) }
            }
            last?.let { throw it }
            check(sha256(archive) == SHA256) { "Voice archive integrity check failed" }
            staging.deleteRecursively(); check(staging.mkdirs())
            extract(archive, staging)
            check(required.all { (name, size) -> File(staging, name).length() == size }) { "Incomplete voice archive" }
            File(staging, "READY").writeText(SHA256)
            currentCoroutineContext().ensureActive()
            check(root.deleteRecursively()) { "Could not replace voice files" }
            check(staging.renameTo(root)) { "Could not install voice files" }
            mutableState.value = KokoroState.Ready
        } finally { archive.delete(); staging.deleteRecursively() }
    }

    private suspend fun fetch(target: File) {
        val connection = URL(MODEL_URL).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000; connection.readTimeout = 30_000
        // GitHub redirects to its HTTPS asset host. URLConnection follows HTTPS
        // redirects; a protocol downgrade is rejected by the platform.
        try {
            check(connection.responseCode == 200) { "Voice server unavailable" }
            var count = 0L
            connection.inputStream.use { input -> target.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val n = input.read(buffer); if (n < 0) break
                    currentCoroutineContext().ensureActive()
                    count += n
                    check(count <= ARCHIVE_SIZE) { "Voice archive too large" }
                    output.write(buffer, 0, n)
                    mutableState.value = KokoroState.Downloading(count.toFloat() / ARCHIVE_SIZE)
                }
            } }
            check(count == ARCHIVE_SIZE) { "Incomplete voice download" }
        } finally { connection.disconnect() }
    }

    private suspend fun extract(archive: File, into: File) {
        TarArchiveInputStream(BZip2CompressorInputStream(archive.inputStream().buffered())).use { tar ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val entry = tar.nextEntry ?: break
                if (!entry.isFile || entry.isSymbolicLink || entry.isLink) continue
                val name = entry.name.removePrefix("kokoro-int8-multi-lang-v1_0/")
                val size = required[name] ?: continue
                check(entry.size == size) { "Invalid voice file size" }
                // Only exact allowlisted basenames can be written, never archive paths.
                File(into, name).outputStream().use { out ->
                    val buffer = ByteArray(65536); var written = 0L
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val n = tar.read(buffer); if (n < 0) break
                        written += n; check(written <= size); out.write(buffer, 0, n)
                    }
                    check(written == size)
                }
            }
        }
    }

    /** Serialized native ownership: a cancelled request cannot free/re-enter a live engine. */
    suspend fun <T> withEngine(body: (KokoroSynthesizer) -> T): T = engineLock.withLock {
        ensureInstalled()
        val tts = engine ?: KokoroSynthesizer(context, root).also { engine = it }
        body(tts)
    }

    companion object {
        const val MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"
        const val SHA256 = "72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653"
        const val ARCHIVE_SIZE = 132353410L
        private val required = mapOf("model.int8.onnx" to 114202993L, "voices.bin" to 28200960L, "tokens.txt" to 687L, "lexicon-us-en.txt" to 5956885L, "LICENSE" to 11358L)
        @Volatile private var instance: KokoroModelStore? = null
        fun get(context: Context): KokoroModelStore = instance ?: synchronized(this) { instance ?: KokoroModelStore(context.applicationContext).also { instance = it } }
        private fun sha256(file: File): String {
            val md = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val n = input.read(buffer); if (n < 0) break; md.update(buffer, 0, n) } }
            return md.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
