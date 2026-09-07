package com.readrai.readr

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.AskEvent
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
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withTimeout
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
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        kit = Kit.open(root, KeystoreSecretStore(context, alias = TEST_ALIAS), NanoProbe(context))
        library = LibraryRepository(context, kit)
        asks = AskRepository(kit)
        settingsName = "ask-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
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
        // The secrets file belongs to the test alias, so emptying it takes
        // nothing of the reader's with it.
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
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

    /**
     * A fast answer arrives whole. The sink is called from Swift's executor
     * and cannot wait for a full buffer, so a channel that could fill would
     * drop the middle of an answer — 500 deltas with no gap between them,
     * into a collector doing work between each one, is what that would look
     * like.
     */
    @Test
    fun everyTokenOfAFastAnswerReachesTheReader() = runBlocking {
        val deltas = (1..500).map { "w$it " }
        FakeChatServer(deltas = deltas, gapMillis = 0).use { server ->
            connect(server)
            val received = StringBuilder()
            var completed: String? = null
            withTimeout(3.minutes) {
                asks.ask(book.id, "What happens?", null, null, emptyList()).collect { event ->
                    when (event) {
                        is AskEvent.Token -> {
                            received.append(event.text)
                            // A collector with something to do between tokens:
                            // the sheet laying out what it was just handed.
                            delay(1)
                        }
                        is AskEvent.Completed -> completed = event.text
                        is AskEvent.Failed -> throw AssertionError("the answer failed: ${event.message}")
                        else -> Unit
                    }
                }
            }
            assertEquals(deltas.joinToString(""), received.toString())
            assertEquals(received.toString(), completed)
        }
    }

    /**
     * The grounding caption promises nothing about citations until the kit
     * has routed something, and then says what THAT tier provides: this book
     * is short enough to ride along whole, which retrieves no passages and
     * therefore has no sources to offer.
     */
    @Test
    fun theCaptionFollowsTheTierTheKitRouted() {
        FakeChatServer().use { server ->
            connect(server)
            openSheet(askModel())
            awaitTag("ask.grounding")
            assertEquals(
                "nothing routed yet, so nothing promised",
                "Grounded in what you\u2019ve read so far.",
                textOf("ask.grounding"),
            )

            compose.onNodeWithTag("ask.suggestion.0").performClick()
            compose.waitUntil(180_000) {
                compose.onAllNodes(hasText(FakeChatServer.DEFAULT_ANSWER, substring = true))
                    .fetchSemanticsNodes().isNotEmpty()
            }
            val grounding = textOf("ask.grounding")
            assertTrue("a whole-book answer has no passages to cite: $grounding", !grounding.contains("citations"))
            assertTrue(grounding, grounding.contains("plus the model"))
        }
    }

    /**
     * A turn that failed says so where it failed. The composer's error card is
     * cleared by the next question; a transcript that then showed the question
     * with nothing under it would read as an app that lost the answer.
     */
    @Test
    fun aFailedTurnKeepsItsReasonInTheTranscript() {
        FakeChatServer(
            status = 401,
            errorBody = "{\"error\":{\"message\":\"Incorrect API key provided.\"}}",
        ).use { server ->
            connect(server)
            openSheet(askModel())
            awaitTag("ask.suggestion.0")
            compose.onNodeWithTag("ask.suggestion.0").performClick()
            awaitTag("ask.exchangeFailure.1", 180_000)

            compose.onNodeWithTag("ask.field").performTextInput("And then what?")
            compose.onNodeWithTag("ask.send").performClick()
            compose.waitUntil(180_000) { nodes("ask.exchangeFailure.2").isNotEmpty() }
            // Scrolled back to, because the transcript follows the newest
            // answer down: the point is that it is still THERE, under the
            // question it belongs to, once the composer's card has moved on.
            compose.onNodeWithTag("ask.transcript")
                .performScrollToNode(hasTestTag("ask.exchangeFailure.1"))
            compose.onNodeWithTag("ask.exchangeFailure.1").assertIsDisplayed()
        }
    }

    /**
     * The answer's shape is the kit's: a numbered list keeps its numbers,
     * because the same parser the Apple panel uses cut it.
     */
    @Test
    fun anOrderedListInAnAnswerKeepsItsNumbers() {
        FakeChatServer(
            deltas = listOf("Two things happen:\n\n", "1. She follows him.\n", "2. She falls.\n"),
        ).use { server ->
            connect(server)
            openSheet(askModel())
            awaitTag("ask.suggestion.0")
            compose.onNodeWithTag("ask.suggestion.0").performClick()
            compose.waitUntil(180_000) {
                compose.onAllNodes(hasText("She falls.", substring = true)).fetchSemanticsNodes().isNotEmpty()
            }
            for (marker in listOf("1.", "2.")) {
                assertTrue(
                    "the list lost its $marker marker",
                    compose.onAllNodes(hasText(marker)).fetchSemanticsNodes().isNotEmpty(),
                )
            }
        }
    }

    private companion object {
        /** This suite's Keystore key, and its own secrets file. */
        const val TEST_ALIAS = "readr.secrets.test"
    }
}
