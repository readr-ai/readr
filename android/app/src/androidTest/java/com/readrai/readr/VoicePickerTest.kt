package com.readrai.readr

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.listen.NarrationModel
import com.readrai.readr.ui.reader.ReaderScreen
import com.readrai.readr.ui.reader.ReaderSettings
import com.readrai.readr.ui.reader.ReaderViewModel
import com.readrai.readr.ui.theme.ReadrTheme
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Choosing the narrator: the Appearance sheet's Voice row, over a real book
 * with a language of its own and a synthesizer that says it has three voices.
 *
 * The point of the test is that Kotlin decides nothing here. The order, the
 * split between the book's own language and "Other voices", which row is
 * recommended, and the sentence shown when the phone has no voice data at all
 * are all the facade's, over the kit's `VoiceSelector` — so what is checked is
 * that the sheet draws what the kit said, and that a pick reaches the kit and
 * the preferences file.
 */
@RunWith(AndroidJUnit4::class)
class VoicePickerTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var repository: LibraryRepository
    private lateinit var settings: ReaderSettings
    private lateinit var settingsName: String
    private lateinit var book: BookSummary
    private lateinit var narration: NarrationModel
    private lateinit var backend: FakeSpeechBackend
    private lateinit var store: ViewModelStore

    /**
     * Two voices for the book's language and one for another. The book —
     * `IllustratedBook` — declares `dc:language` en, so which group each falls
     * into is the kit's answer over a stated fact rather than the emulator's
     * locale.
     */
    private val installedVoices = """[
      {"id":"en-us-x-sfg#female_1-local","name":"English (United States)","language":"en-US","quality":"enhanced","isDefault":true},
      {"id":"en-gb-x-rjs#male_1-local","name":"English (United Kingdom)","language":"en-GB","quality":"standard","isDefault":false},
      {"id":"fr-fr-x-vlf#female_1-local","name":"French (France)","language":"fr-FR","quality":"standard","isDefault":false}
    ]"""

    private val american = "en-us-x-sfg#female_1-local"
    private val british = "en-gb-x-rjs#male_1-local"
    private val french = "fr-fr-x-vlf#female_1-local"

    @Before
    fun setUp() = runBlocking {
        grantNotifications()
        root = File(context.cacheDir, "voice-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoProbe(context))
        repository = LibraryRepository(context, kit)
        settingsName = "voice-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
        val archive = IllustratedBook.write(File(root, "illustrated.epub"))
        val extracted = File(root, "illustrated-extracted")
        EpubExtractor.extract(archive.inputStream(), extracted)
        book = kitJson.decodeFromString(
            kit.library.importEPUB(extracted.absolutePath, archive.absolutePath, "Illustrated").await()
        )
        repository.refresh()
    }

    @After
    fun tearDown() {
        if (::narration.isInitialized) onMain { narration.release() }
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
    }

    /** The reader, over a synthesizer that claims [voices]. */
    private fun open(voices: String = installedVoices) {
        val model = ReaderViewModel({ repository }, book.id)
        narration = NarrationModel(
            context, { kit }, book.id, settings,
            backends = { events -> FakeSpeechBackend(events).also { it.voices = voices; backend = it } },
        )
        store = ViewModelStore()
        val owner = object : ViewModelStoreOwner {
            override val viewModelStore: ViewModelStore get() = store
        }
        compose.setContent {
            ReadrTheme {
                CompositionLocalProvider(LocalViewModelStoreOwner provides owner) {
                    ReaderScreen(model, settings, narration = narration, onBack = {})
                }
            }
        }
        awaitTag("reader.pageLabel")
    }

    private fun nodes(tag: String) = compose.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes()
    private fun awaitTag(tag: String) = compose.waitUntil(20_000) { nodes(tag).isNotEmpty() }

    private fun textOf(tag: String): String =
        nodes(tag).firstOrNull()?.config?.getOrNull(SemanticsProperties.Text)
            ?.joinToString(" ") { it.text } ?: ""

    /** Open the Aa sheet and wait for the Voice row to have something to say. */
    private fun openAppearance() {
        compose.onNodeWithTag("reader.appearance").performClick()
        awaitTag("appearance.voice")
        compose.waitUntil(20_000) { textOf("appearance.voice").isNotBlank() }
    }

    /**
     * The row opens on the voice that is reading — which, with nothing stored,
     * is the one the kit recommends for this book's language. Behind it: the
     * English voices first, in `VoiceSelector`'s order, and the French one
     * behind "Other voices".
     */
    @Test
    fun theRowShowsTheRecommendedVoiceAndTheListIsTheKitsOrder() {
        open()
        openAppearance()

        val voices = narration.voices
        assertEquals("the kit's choice for an English book", american, voices.recommendedID)
        assertEquals(american, voices.selectedID)
        assertEquals(
            "the book's own language, best first",
            listOf(american, british),
            voices.voices.map { it.id },
        )
        assertEquals("and the rest behind the disclosure", listOf(french), voices.otherVoices.map { it.id })
        assertTrue(
            "the row names the voice that is reading: '${textOf("appearance.voice")}'",
            textOf("appearance.voice").contains("English (United States)"),
        )

        compose.onNodeWithTag("appearance.voice").performScrollTo().performClick()
        awaitTag("voice.$american")
        assertTrue("the other English voice is offered", nodes("voice.$british").isNotEmpty())
        assertTrue("the French one is not, until asked for", nodes("voice.$french").isEmpty())
        assertTrue("and there is a way to ask", nodes("appearance.otherVoices").isNotEmpty())
    }

    /** Picking a voice reaches the kit and the preferences file the iOS app shares. */
    @Test
    fun pickingAVoiceChangesTheStateAndIsRemembered() {
        open()
        openAppearance()
        compose.onNodeWithTag("appearance.voice").performScrollTo().performClick()
        awaitTag("voice.$british")

        compose.onNodeWithTag("voice.$british").performClick()

        compose.waitUntil(10_000) { narration.voiceID == british }
        assertEquals("the kit is reading in it", british, narration.voices.selectedID)
        assertEquals("and it is written down", british, settings.narrationVoiceID)
        assertEquals(
            "the recommendation is unchanged — it is not the same thing as the choice",
            american,
            narration.voices.recommendedID,
        )
    }

    /** "Other voices" is what the languages the book is not written in are behind. */
    @Test
    fun theOtherVoicesDisclosureOffersTheRest() {
        open()
        openAppearance()
        compose.onNodeWithTag("appearance.voice").performScrollTo().performClick()
        awaitTag("appearance.otherVoices")

        compose.onNodeWithTag("appearance.otherVoices").performClick()
        awaitTag("voice.$french")
        compose.onNodeWithTag("voice.$french").performClick()

        compose.waitUntil(10_000) { narration.voiceID == french }
        assertEquals(french, settings.narrationVoiceID)
    }

    /**
     * A phone whose synthesizer has no voice data says so, in the facade's
     * words — Kotlin writes no copy here, as it writes none anywhere a reader
     * could be stopped by it.
     */
    @Test
    fun aPhoneWithNoVoicesSaysSoInTheFacadesWords() {
        open(voices = "[]")
        openAppearance()

        assertTrue("nothing to offer", narration.voices.isEmpty)
        val text = textOf("appearance.voice")
        assertEquals("the sentence is the facade's", narration.voices.emptyText, text)
        assertTrue("and it says something", text.isNotBlank())
        assertFalse("there is nothing to pick from", text.contains("null"))
    }
}
