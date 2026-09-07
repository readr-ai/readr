package com.readrai.readr

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.ProvidersRepository
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.library.LibraryScreen
import com.readrai.readr.ui.library.LibraryViewModel
import com.readrai.readr.ui.settings.ProvidersScreen
import com.readrai.readr.ui.settings.ProvidersViewModel
import com.readrai.readr.ui.theme.ReadrTheme
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * AI provider settings on a real device: reached from the shelf, connected
 * with a key, and pointed at a model — over a real kit on a scratch library
 * root, so nothing here touches the reader's own settings.
 */
@RunWith(AndroidJUnit4::class)
class ProvidersScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var repository: ProvidersRepository
    private lateinit var library: LibraryRepository

    @Before
    fun setUp() {
        root = File(context.cacheDir, "settings-test-${System.nanoTime()}").apply { mkdirs() }
        // Everything this test touches is its own: a scratch library root, and
        // the secrets file belonging to the test Keystore alias. Nothing here
        // reads or writes the reader's library or the reader's provider keys.
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        kit = Kit.open(root, KeystoreSecretStore(context, alias = TEST_ALIAS), NanoProbe(context))
        repository = ProvidersRepository(kit)
        library = LibraryRepository(context, kit)
    }

    @After
    fun tearDown() {
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        root.deleteRecursively()
    }

    /** Settings on its own, as the gear opens it. */
    private fun openSettings() {
        compose.setContent { ReadrTheme { ProvidersScreen(ProvidersViewModel { repository }, onBack = {}) } }
        awaitTag("settings.askUses")
    }

    private fun nodes(tag: String) = compose.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes()
    private fun awaitTag(tag: String) = compose.waitUntil(30_000) { nodes(tag).isNotEmpty() }

    private fun textOf(tag: String): String =
        nodes(tag).firstOrNull()?.config?.get(SemanticsProperties.Text)?.joinToString("") { it.text } ?: ""

    private fun askUses(): String = textOf("settings.askUses")

    /** What a text field shows — masked, so never the key that was typed. */
    private fun fieldText(tag: String): String {
        val config = nodes(tag).firstOrNull()?.config ?: return ""
        config.getOrNull(SemanticsProperties.EditableText)?.let { return it.text }
        return config.getOrNull(SemanticsProperties.Text)?.joinToString("") { it.text } ?: ""
    }

    @Test
    fun theGearOnTheShelfOpensSettings() {
        compose.setContent {
            ReadrTheme {
                val nav = rememberNavController()
                NavHost(nav, startDestination = "library") {
                    composable("library") {
                        // Over the scratch library, not the app's own: opening
                        // Settings from the shelf must not seed or read the
                        // books on the phone this test is running on.
                        LibraryScreen(
                            LibraryViewModel { library },
                            onOpen = {},
                            onSettings = { nav.navigate("settings") },
                        )
                    }
                    composable("settings") {
                        ProvidersScreen(ProvidersViewModel { repository }) { nav.popBackStack() }
                    }
                }
            }
        }
        awaitTag("library.settings")
        compose.onNodeWithTag("library.settings").performClick()
        awaitTag("settings.askUses")
        compose.onNodeWithTag("settings.askUses").assertIsDisplayed()
        // And back the way it came.
        compose.onNodeWithTag("settings.back").performClick()
        awaitTag("library.settings")
    }

    /** Nothing connected: the line says so, and every card says what to do. */
    @Test
    fun anUnconnectedScreenSaysWhatToDo() {
        openSettings()
        assertEquals("Ask uses no model yet — connect one below.", askUses())
        for (vendor in listOf("openai", "openrouter", "anthropic")) {
            compose.onNodeWithTag("settings.card.$vendor").performScrollTo().assertIsDisplayed()
            assertEquals("Paste an API key to connect.", textOf("settings.hint.$vendor"))
            assertEquals("API KEY", textOf("settings.badge.$vendor"))
        }
        assertEquals("Not connected", textOf("settings.status.openAI"))
    }

    /**
     * A key goes in, the card says something about it, and the field is empty
     * again — a secret is not left sitting on the screen. Then the reader
     * points Ask at it, and the line at the top names the model.
     */
    @Test
    fun aKeyConnectsACardAndCanBeMadeActive() {
        openSettings()
        compose.onNodeWithTag("settings.apiKey.openAI").performScrollTo().performTextInput("sk-test-not-a-real-key")
        compose.onNodeWithTag("settings.saveKey.openAI").performScrollTo().performClick()

        // Whatever the network says, the card settles on a sentence and the
        // key it was given is no longer on screen.
        compose.waitUntil(60_000) { textOf("settings.status.openAI") != "Not connected" }
        compose.onNodeWithTag("settings.status.openAI").performScrollTo().assertIsDisplayed()
        val status = textOf("settings.status.openAI")
        assertTrue("the card says something about the key", status.isNotBlank())
        assertFalse("the field does not keep the key", fieldText("settings.apiKey.openAI").contains("sk-"))

        awaitTag("settings.removeKey.openAI")
        compose.onNodeWithTag("settings.makeActive.openAI").performScrollTo().performClick()
        compose.waitUntil(30_000) { askUses().contains("GPT-5.6") }
        assertTrue(askUses(), askUses().startsWith("Ask uses GPT-5.6"))
        awaitTag("settings.activeBadge.openAI")

        // And the key can be taken away again.
        compose.onNodeWithTag("settings.removeKey.openAI").performScrollTo().performClick()
        compose.waitUntil(30_000) { nodes("settings.removeKey.openAI").isEmpty() }
    }

    /**
     * The phone's own card explains itself instead of vanishing: no emulator
     * carries AICore, so it says so — in the kit's words — and offers a
     * re-check rather than a key field. Nothing here can be made active,
     * because only a check that came back *ready* offers that.
     */
    @Test
    fun theOnThisPhoneCardExplainsItself() {
        openSettings()
        compose.onNodeWithTag("settings.card.android").performScrollTo().assertIsDisplayed()
        assertEquals("ON-DEVICE", textOf("settings.badge.android"))
        compose.waitUntil(30_000) { textOf("settings.status.geminiNano") == "Gemini Nano isn't available on this phone." }
        compose.onNodeWithTag("settings.recheck.geminiNano").performScrollTo().assertIsDisplayed()
        assertTrue("nothing to paste into an on-device card", nodes("settings.apiKey.geminiNano").isEmpty())
        assertTrue(
            "a model this phone cannot run is never offered as the one to use",
            nodes("settings.makeActive.geminiNano").isEmpty(),
        )
    }

    private companion object {
        /** This suite's Keystore key, and its own secrets file. */
        const val TEST_ALIAS = "readr.secrets.test"
    }
}
