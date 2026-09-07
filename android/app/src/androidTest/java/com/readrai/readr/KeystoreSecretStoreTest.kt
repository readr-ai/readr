package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.kit.KeystoreSecretStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeystoreSecretStoreTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun roundTripsAndRemoves() {
        val store = KeystoreSecretStore(context, alias = TEST_ALIAS)
        assertEquals("", store.read("credentials.anthropic"))
        assertTrue(store.write("credentials.anthropic", "{\"apiKey\":{\"_0\":\"sk-test\"}}"))
        assertEquals("{\"apiKey\":{\"_0\":\"sk-test\"}}", store.read("credentials.anthropic"))
        assertTrue(store.remove("credentials.anthropic"))
        assertEquals("", store.read("credentials.anthropic"))
    }

    @Test
    fun ciphertextOnDiskIsNotThePlaintext() {
        val store = KeystoreSecretStore(context, alias = TEST_ALIAS)
        store.write("k", "plain-secret-value")
        val raw = context.getSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS), 0).getString("k", "")!!
        assertFalse(raw.contains("plain-secret-value"))
        assertTrue(raw.contains(":"))
        store.remove("k")
    }

    /**
     * A store under a test alias writes a file of its own. Ciphertext written
     * under one Keystore key cannot be read back with another, so a test
     * sharing the reader's `secrets` file would leave unreadable entries in
     * it — and a test that tidied up after itself would be deleting the
     * reader's provider keys.
     */
    @Test
    fun eachAliasKeepsItsOwnFile() {
        assertEquals("secrets", KeystoreSecretStore.fileName(KeystoreSecretStore.DEFAULT_ALIAS))
        assertEquals("secrets.$TEST_ALIAS", KeystoreSecretStore.fileName(TEST_ALIAS))

        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        KeystoreSecretStore(context, alias = TEST_ALIAS).write("credentials.openAI", "under-the-test-key")
        assertTrue(context.getSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS), 0).contains("credentials.openAI"))
        assertFalse(
            "the reader's own file is untouched",
            context.getSharedPreferences("secrets", 0).contains("credentials.openAI"),
        )
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
    }

    /** Presence without decryption — what the settings payload asks. */
    @Test
    fun presenceIsAnsweredWithoutReadingTheValue() {
        val store = KeystoreSecretStore(context, alias = TEST_ALIAS)
        assertFalse(store.has("credentials.anthropic"))
        store.write("credentials.anthropic", "{\"apiKey\":{\"_0\":\"sk-test\"}}")
        assertTrue(store.has("credentials.anthropic"))
        store.remove("credentials.anthropic")
        assertFalse(store.has("credentials.anthropic"))
    }

    /**
     * Ciphertext no key of this store's can read is not a stored credential:
     * it is dropped where it is found, so [KeystoreSecretStore.has] and
     * [KeystoreSecretStore.read] cannot disagree. This is what an invalidated
     * Keystore key looks like from the outside — the entry is there, and
     * nothing will ever decrypt it.
     */
    @Test
    fun anEntryThatWillNotDecryptIsRemovedRatherThanKeptForever() {
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(OTHER_ALIAS))

        KeystoreSecretStore(context, alias = TEST_ALIAS).write("credentials.openAI", "sk-written-under-the-other-key")
        val foreign = context
            .getSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS), 0)
            .getString("credentials.openAI", null)!!
        // The same ciphertext, in the file a store under the OTHER alias
        // reads — which is a key that cannot decrypt it.
        context.getSharedPreferences(KeystoreSecretStore.fileName(OTHER_ALIAS), 0)
            .edit().putString("credentials.openAI", foreign).commit()

        val store = KeystoreSecretStore(context, alias = OTHER_ALIAS)
        assertTrue("the entry is there to begin with", store.has("credentials.openAI"))
        assertEquals("", store.read("credentials.openAI"))
        assertFalse("an unreadable entry must not go on claiming to be a key", store.has("credentials.openAI"))

        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(OTHER_ALIAS))
    }

    private companion object {
        const val TEST_ALIAS = "readr.secrets.test"

        /** A second Keystore key, so "written under another alias" is real. */
        const val OTHER_ALIAS = "readr.secrets.test.other"
    }
}
