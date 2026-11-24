package com.readrai.readr

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.kit.*
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Manual real-model check, selected explicitly; downloads 132 MB if needed. */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.CLASS)
annotation class ModelDownloadTest

@ModelDownloadTest
@RunWith(AndroidJUnit4::class)
class KokoroAudioTest {
    @Test fun shortChapterHeadingStartsAndFinishesRealPlayback() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        KokoroModelStore.get(context).ensureInstalled()
        val root = File(context.cacheDir, "kokoro-short-${System.nanoTime()}").apply { mkdirs() }
        val kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoModel(context))
        val repository = LibraryRepository(context, kit)
        val sample = File(root, "alice.epub")
        context.assets.open(LibraryRepository.SAMPLE_ASSET).use { input -> sample.outputStream().use { input.copyTo(it) } }
        val alice = repository.import(Uri.fromFile(sample))
        val chapter = repository.chapterText(alice.id, 0)
        val passage = chapter.substring(chapter.indexOf("Alice was beginning")).substringBefore(".") + "."
        assertTrue("Use the real long sentence from the sample book", passage.length > 400)
        val file = File(root, "heading.txt").apply { writeText("CHAPTER I. Down the Rabbit-Hole\n\n" + passage) }
        val book = repository.import(Uri.fromFile(file))
        val observer = RecordingNarrationObserver()
        val arena = org.swift.swiftkit.core.SwiftArena.ofAuto()
        val events = NarrationEvents.init(arena)
        val backend = KokoroSpeechBackend(context, events)
        val narration = onMain { AndroidNarration.init(kit.library, book.id, backend, events, observer, "{}", "en-US", arena) }
        try {
            onMain { narration.start(0, 0, "containingSentence") }
            kotlinx.coroutines.withTimeout(120_000) {
                while (onMain { org.json.JSONObject(narration.stateJSON()).getString("status") } != "finished") {
                    assertFalse("Short heading must not stall: ${observer.holds}", observer.holds.contains("engineFailed"))
                    kotlinx.coroutines.delay(100)
                }
            }
            assertTrue(observer.statuses.contains("speaking"))
            assertTrue("The long Alice passage was played", observer.sentences.any { it.contains("Alice was beginning") })
        } finally { onMain { narration.stop(); backend.release() }; root.deleteRecursively() }
    }

    @Test fun realImportedBookProducesNonSilentKokoroAudio() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "kokoro-book-proof").apply { mkdirs() }
        val kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoModel(context))
        val repository = LibraryRepository(context, kit)
        val file = File(root, "alice.epub")
        context.assets.open(LibraryRepository.SAMPLE_ASSET).use { input -> file.outputStream().use { input.copyTo(it) } }
        val book = repository.import(Uri.fromFile(file))
        val text = repository.chapterText(book.id, 0)
        val start = text.indexOf("Alice was beginning")
        assertTrue(text.take(300), start >= 0)
        val passage = text.substring(start).substringBefore(".") + "."
        File(context.cacheDir, "kokoro-proof-text.txt").writeText(passage)
        val pdfFile = File(root, "readr-pdf-test-book.pdf")
        val pdf = android.graphics.pdf.PdfDocument()
        try {
            for ((index, line) in listOf("Alice follows the white rabbit on the first page.", "The second page finishes this little story.").withIndex()) {
                val page = pdf.startPage(android.graphics.pdf.PdfDocument.PageInfo.Builder(612, 792, index + 1).create())
                page.canvas.drawText(line, 32f, 80f, android.graphics.Paint().apply { textSize = 20f; color = android.graphics.Color.BLACK; isAntiAlias = true })
                pdf.finishPage(page)
            }
            pdfFile.outputStream().use { pdf.writeTo(it) }
        } finally { pdf.close() }
        val pdfBook = repository.import(Uri.fromFile(pdfFile))
        assertEquals(2, pdfBook.chapterCount)
        val pdfText = repository.chapterText(pdfBook.id, 0)
        assertTrue(pdfText, pdfText.contains("first page"))
        File(context.cacheDir, "kokoro-pdf-text.txt").writeText(pdfText)
        pdfFile.copyTo(File(context.cacheDir, "readr-pdf-test-book.pdf"), overwrite = true)
        val store = KokoroModelStore.get(context)
        store.ensureInstalled()
        store.withEngine { engine ->
            for (word in listOf("Alice", "conversations", "daisies", "quizzaciously")) {
                assertTrue("Every word receives a pronunciation", engine.phonemes(word).isNotBlank())
            }
            File(context.cacheDir, "kokoro-proof-phonemes.txt").writeText(engine.phonemes(passage))
            val started = System.nanoTime()
            val audio = engine.generate(passage, sid = 3, speed = 1f)
            val metrics = "synthesisSeconds=${(System.nanoTime() - started) / 1e9}\naudioSeconds=${audio.samples.size.toDouble() / audio.sampleRate}\n"
            File(context.cacheDir, "kokoro-timing.txt").writeText(metrics)
            assertEquals(24000, audio.sampleRate)
            assertTrue("at least 3 seconds of real samples", audio.samples.size > audio.sampleRate * 3)
            assertTrue("non-silent speech", audio.samples.any { kotlin.math.abs(it) > 0.05f })
            assertTrue(audio.save(File(context.cacheDir, "kokoro-alice-proof.wav").path))
            val fast = engine.generate("Alice follows the rabbit down the hole.", sid = 3, speed = 1.5f)
            val normal = engine.generate("Alice follows the rabbit down the hole.", sid = 3, speed = 1f)
            assertTrue("speed changes actual audio duration", fast.samples.size < normal.samples.size)
            assertTrue(engine.generate(pdfText, sid = 3).save(File(context.cacheDir, "kokoro-pdf-proof.wav").path))
            try { engine.generate("Alice", speed = Float.NaN); fail("Non-finite speed accepted") } catch (expected: IllegalArgumentException) { }
            try { engine.generate("   "); fail("Empty speech accepted") } catch (expected: IllegalArgumentException) { }
        }
        // Exercise the real AudioTrack + Swift controller, including automatic
        // page transition. A WAV alone cannot establish that Listen finishes.
        val observer = RecordingNarrationObserver()
        val arena = org.swift.swiftkit.core.SwiftArena.ofAuto()
        val events = NarrationEvents.init(arena)
        val backend = KokoroSpeechBackend(context, events)
        val narration = onMain { AndroidNarration.init(kit.library, pdfBook.id, backend, events, observer, "{}", "en-US", arena) }
        try {
            onMain { narration.start(0, 0, "containingSentence") }
            kotlinx.coroutines.withTimeout(90_000) {
                while (onMain { org.json.JSONObject(narration.stateJSON()).getString("status") } != "finished") kotlinx.coroutines.delay(100)
            }
            assertTrue("Real PCM playback began", observer.statuses.contains("speaking"))
            assertTrue("First PDF page was played", observer.spoken.any { it.chapterIndex == 0 })
            assertTrue("Second PDF page was played", observer.spoken.any { it.chapterIndex == 1 })
            assertFalse(observer.holds.toString(), observer.holds.contains("engineFailed"))
        } finally { onMain { narration.stop(); backend.release() } }
        // Preserve the requested recording outside app data: Gradle's connected
        // runner may uninstall its target after testing. No passage is uploaded.
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            for ((name, type) in listOf("kokoro-alice-proof.wav" to "audio/wav", "kokoro-proof-text.txt" to "text/plain", "kokoro-proof-phonemes.txt" to "text/plain", "kokoro-pdf-proof.wav" to "audio/wav", "kokoro-pdf-text.txt" to "text/plain", "kokoro-timing.txt" to "text/plain", "readr-pdf-test-book.pdf" to "application/pdf")) {
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(android.provider.MediaStore.MediaColumns.MIME_TYPE, type)
                    put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Download/Readr Launch QA")
                }
                val uri = context.contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)!!
                context.contentResolver.openOutputStream(uri)!!.use { output -> File(context.cacheDir, name).inputStream().use { it.copyTo(output) } }
            }
        }
    }
}
