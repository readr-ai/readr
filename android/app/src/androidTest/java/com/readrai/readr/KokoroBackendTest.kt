package com.readrai.readr

import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.kit.*
import com.readrai.readr.data.kitJson
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.swift.swiftkit.core.SwiftArena

class KokoroBackendTest {
    @Test fun onlyNamedKokoroVoicesAreOfferedWithoutStartingASystemSynthesizer() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val backend = KokoroSpeechBackend(context, NarrationEvents.init(SwiftArena.ofAuto()))
        try {
            val voices = JSONObject(backend.voicesJSON()).getJSONArray("voices")
            assertEquals(3, voices.length())
            assertEquals("Heart · Kokoro", voices.getJSONObject(0).getString("name"))
            for (index in 0 until voices.length()) assertTrue(voices.getJSONObject(index).getString("id").startsWith("kokoro."))
            assertEquals("idle", backend.state())
        } finally { backend.release() }
    }
    @Test fun unsupportedBookLanguagePausesWithGuidanceAndNoSystemFallback() = kotlinx.coroutines.runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = java.io.File(context.cacheDir, "kokoro-language-${System.nanoTime()}").apply { mkdirs() }
        try {
            val file = java.io.File(root, "french.epub")
            val files = mapOf(
                "mimetype" to "application/epub+zip",
                "META-INF/container.xml" to """<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""",
                "book.opf" to """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">test</dc:identifier><dc:title>French test</dc:title><dc:language>fr</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>""",
                "chapter.xhtml" to """<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Bonjour. Ceci est un livre.</p></body></html>""",
            )
            java.util.zip.ZipOutputStream(file.outputStream()).use { zip -> for ((name, text) in files) { zip.putNextEntry(java.util.zip.ZipEntry(name)); zip.write(text.toByteArray()); zip.closeEntry() } }
            val kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoModel(context))
            val repository = com.readrai.readr.data.LibraryRepository(context, kit)
            val book = repository.import(android.net.Uri.fromFile(file))
            assertEquals("fr", book.language)
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val arena = SwiftArena.ofAuto()
                val events = NarrationEvents.init(arena)
                val backend = KokoroSpeechBackend(context, events)
                val observer = RecordingNarrationObserver()
                val narration = AndroidNarration.init(kit.library, book.id, backend, events, observer, "{}", "en-US", arena)
                try {
                    narration.start(0, 0, "containingSentence")
                    val state = JSONObject(narration.stateJSON())
                    assertEquals("paused", state.getString("status"))
                    assertTrue(state.getString("holdText"), state.getString("holdText").contains("English"))
                    assertEquals("idle", backend.state())
                } finally { narration.stop(); backend.release() }
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun longSentencesAreBoundedWithoutDroppingWords() {
        val text = (1..300).joinToString(" ") { "word$it" }
        val chunks = KokoroSpeechBackend.chunks(text)
        assertTrue(chunks.all { it.length <= 400 })
        assertEquals(text, chunks.joinToString(" "))
        assertTrue(KokoroSpeechBackend.chunks("  ").isEmpty())
    }
}
