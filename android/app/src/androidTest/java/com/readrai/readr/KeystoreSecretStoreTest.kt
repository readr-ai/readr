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
        val store = KeystoreSecretStore(context, alias = "readr.secrets.test")
        assertEquals("", store.read("credentials.anthropic"))
        assertTrue(store.write("credentials.anthropic", "{\"apiKey\":{\"_0\":\"sk-test\"}}"))
        assertEquals("{\"apiKey\":{\"_0\":\"sk-test\"}}", store.read("credentials.anthropic"))
        assertTrue(store.remove("credentials.anthropic"))
        assertEquals("", store.read("credentials.anthropic"))
    }

    @Test
    fun ciphertextOnDiskIsNotThePlaintext() {
        val store = KeystoreSecretStore(context, alias = "readr.secrets.test")
        store.write("k", "plain-secret-value")
        val raw = context.getSharedPreferences("secrets", 0).getString("k", "")!!
        assertFalse(raw.contains("plain-secret-value"))
        assertTrue(raw.contains(":"))
        store.remove("k")
    }
}
