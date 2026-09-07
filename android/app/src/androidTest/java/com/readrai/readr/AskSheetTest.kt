package com.readrai.readr

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.AskFrontier
import com.readrai.readr.data.AskRepository
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.ask.AskConversation
import com.readrai.readr.ui.ask.AskRequest
import com.readrai.readr.ui.ask.AskSheet
import com.readrai.readr.ui.ask.AskViewModel
import com.readrai.readr.ui.reader.ReaderScreen
import com.readrai.readr.ui.reader.ReaderSettings
import com.readrai.readr.ui.reader.ReaderViewModel
import com.readrai.readr.ui.theme.ReadrTheme
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Ask on a real device, over a real kit: the guided empty state, a recap
 * streamed in from a server the test runs itself, and the error card's Retry.
 *
 * The provider is pointed at that local server through the facade's test-only
 * endpoint override, so nothing here needs a key, a network or a bill.
 */
@RunWith(AndroidJUnit4::class)
class AskSheetTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var library: LibraryRepository
    private lateinit var asks: AskRepository
    private lateinit var settings: ReaderSettings
    private lateinit var settingsName: String
    private lateinit var book: BookSummary

    @Before
    fun setUp() = runBlocking {
        root = File(context.cacheDir, "ask-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoProbe(context))
        library = LibraryRepository(context, kit)
        asks = AskRepository(kit)
        settingsName = "ask-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
        // The Keystore file is shared by alias, the library root is not: a key
        // an earlier test left behind would make "nothing connected" untrue.
        clearCredentials()
        val text = buildString {
            for (chapter in 1..3) {
                append("# Chapter $chapter\n\n")
                for (paragraph in 1..8) {
                    append("$chapter.$paragraph Alice followed the White Rabbit down the rabbit-hole, ")
                    append("never once considering how in the world she was to get out again.\n\n")
                }
            }
        }
        val file = File(root, "wonderland.txt").apply { writeText(text) }
        book = kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "Wonderland").await())
        library.refresh()
    }

    @After
    fun tearDown() {
        clearCredentials()
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
    }

    private fun clearCredentials() {
        for (kind in listOf("openAI", "anthropic", "openRouter")) runCatching { kit.providers.deleteCredential(kind) }
    }

    /** A provider pointed at `server`, connected and made active. */
    private fun connect(server: FakeChatServer) {
        kit.providers.overrideEndpoint("openAI", server.origin)
        kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
        kit.providers.setActive("openAI", "gpt-5.6-sol")
    }

    private fun askModel() = AskViewModel({ asks }, AskConversation(book.id))

    private fun nodes(tag: String) = compose.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes()
    private fun awaitTag(tag: String, timeout: Long = 30_000) = compose.waitUntil(timeout) { nodes(tag).isNotEmpty() }
    private fun textOf(tag: String): String =
        nodes(tag).firstOrNull()?.config?.get(SemanticsProperties.Text)?.joinToString("") { it.text } ?: ""

    /** The sheet on its own, opened on the book at the very start. */
    private fun openSheet(model: AskViewModel, onOpenProviders: () -> Unit = {}) {
        compose.setContent {
            ReadrTheme {
                LaunchedEffect(Unit) { model.open(AskRequest(frontier = AskFrontier(0, 0))) }
                AskSheet(
                    model = model,
                    onDismiss = {},
                    onShowInBook = { _, _ -> },
                    onOpenProviders = onOpenProviders,
                )
            }
        }
    }

    /**
     * Nothing connected: the sheet does not just say so, it offers the way
     * out — the same actionable empty state the Apple panel has.
     */
    @Test
    fun withoutAProviderTheSheetOffersTheProviderScreen() {
        var opened = false
        openSheet(askModel()) { opened = true }
        awaitTag("ask.openProviders")
        compose.onNodeWithTag("ask.openProviders").assertIsDisplayed().performClick()
        compose.waitUntil(10_000) { opened }
        assertTrue("nothing to type into until a provider is connected", nodes("ask.field").isEmpty())
    }

    /**
     * The reader's ✦ opens Ask scoped to where the reader is, the recap chip
     * sends itself, and the answer streams in under a caption that promises
     * only what a cloud model can deliver.
     */
    @Test
    fun theRecapChipSendsItselfAndTheAnswerStreamsIn() {
        FakeChatServer().use { server ->
            connect(server)
            val ask = askModel()
            val reader = ReaderViewModel({ library }, book.id)
            compose.setContent {
                ReadrTheme { ReaderScreen(reader, settings, ask = ask, onOpenProviders = {}, onBack = {}) }
            }
            awaitTag("reader.ask")
            compose.onNodeWithTag("reader.ask").performClick()

            // Scoped to where the reader is, so the first chip is the recap.
            awaitTag("ask.suggestion.0")
            assertEquals(AskViewModel.RECAP_QUESTION, textOf("ask.suggestion.0"))
            compose.onNodeWithTag("ask.suggestion.0").performClick()

            compose.waitUntil(180_000) {
                compose.onAllNodes(hasText(FakeChatServer.DEFAULT_ANSWER, substring = true))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            val grounding = textOf("ask.grounding")
            assertTrue(
                "a cloud model's answer promises its wider knowledge too: $grounding",
                grounding.contains("plus the model") && grounding.contains("wider knowledge"),
            )
            assertTrue("a scoped answer says what it is grounded in: $grounding", grounding.contains("read so far"))
        }
    }

    /**
     * A rejected key: the card carries the provider's own sentence, and Retry
     * asks the same question again rather than making the reader retype it.
     */
    @Test
    fun aRejectedKeyShowsTheErrorCardAndRetryAsksAgain() {
        FakeChatServer(
            status = 401,
            errorBody = "{\"error\":{\"message\":\"Incorrect API key provided.\"}}",
        ).use { server ->
            connect(server)
            openSheet(askModel())
            awaitTag("ask.suggestion.0")
            compose.onNodeWithTag("ask.suggestion.0").performClick()

            awaitTag("ask.error", 180_000)
            compose.onNodeWithTag("ask.error").assertIsDisplayed()
            // The card carries the provider's own sentence — the card itself
            // is a container, so the words live on the Text inside it.
            assertTrue(
                "the reader is told what the provider said",
                compose.onAllNodes(hasText("Incorrect API key provided.", substring = true))
                    .fetchSemanticsNodes().isNotEmpty(),
            )
            compose.waitUntil(10_000) { server.requests >= 1 }
            val asked = server.requests

            compose.onNodeWithTag("ask.retry").performClick()
            compose.waitUntil(180_000) { server.requests > asked }
            assertTrue("the error card is still the reader's answer", nodes("ask.error").isNotEmpty())
        }
    }
}
