package com.readrai.readr.kit

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * ReadrKit's credential storage on Android — the counterpart of the iOS
 * `KeychainCredentialStore`. Values are AES-256-GCM encrypted with a key that
 * lives in the Android Keystore (non-exportable, this device only, usable only
 * while the device is unlocked — the same protection class as the iOS store's
 * `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); only the ciphertext and IV
 * are written to a private SharedPreferences file. Secrets are never written
 * anywhere in plaintext, and `allowBackup` is off for the app so the
 * ciphertext is not backed up either.
 *
 * Failures are logged by exception class (never by value) so a bug report can
 * tell "no credential stored" from "the key was invalidated" — and an entry
 * that cannot be decrypted is dropped as it is found, so `has` never claims a
 * key `read` cannot produce.
 */
class KeystoreSecretStore(context: Context, private val alias: String = DEFAULT_ALIAS) : SecretStore {
    // One file per Keystore key. The alias is what the ciphertext can be read
    // back with, so a store under a test alias writing into the app's own
    // "secrets" file leaves entries there that the reader's key cannot
    // decrypt — and a test that clears up after itself would be deleting the
    // reader's provider keys.
    private val prefs = context.applicationContext.getSharedPreferences(fileName(alias), Context.MODE_PRIVATE)

    override fun write(key: String, value: String): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        prefs.edit().putString(key, encoded).commit()
    } catch (e: Exception) {
        Log.w(TAG, "write failed for $key: ${e::class.java.simpleName}")
        false
    }

    /**
     * The stored value, or "" when absent or unreadable (the bridge cannot
     * return an optional).
     *
     * An entry that will not decrypt is REMOVED. A Keystore key invalidated
     * by a lock-screen change (or ciphertext written under another alias)
     * leaves a value nothing can ever read, and leaving it there makes [has]
     * and [read] disagree for good: the settings screen would show a key on
     * the card, the reader would be told to remove one that is not there, and
     * every ask would fail on a credential the app insists it holds. The
     * exception class is logged — never the value — so a bug report can still
     * tell "the key was invalidated" from "nothing was stored".
     */
    override fun read(key: String): String {
        val encoded = prefs.getString(key, null) ?: return ""
        return try {
            val (iv, ciphertext) = encoded.split(":", limit = 2).map { Base64.decode(it, Base64.NO_WRAP) }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w(TAG, "read failed for $key: ${e::class.java.simpleName} (unreadable entry dropped)")
            remove(key)
            ""
        }
    }

    override fun remove(key: String): Boolean = prefs.edit().remove(key).commit()

    /**
     * Whether there is an entry, without decrypting it. Settings asks this of
     * every provider on every read of the screen; going through [read] would
     * be a Keystore round trip per card for an answer the preferences file
     * already has, and would hand the value out to learn nothing but that it
     * exists.
     */
    override fun has(key: String): Boolean = prefs.contains(key)

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUnlockedDeviceRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        /** The reader's own key, and the file it writes: `secrets`. */
        const val DEFAULT_ALIAS = "readr.secrets"

        /**
         * The preferences file a store under `alias` writes. One file per
         * Keystore key: ciphertext written under one key cannot be read back
         * with another, so a second store sharing the file would leave
         * entries in it that the first cannot decrypt — and clearing up after
         * itself would take the reader's own keys with it.
         */
        fun fileName(alias: String): String = if (alias == DEFAULT_ALIAS) "secrets" else "secrets.$alias"

        private const val TAG = "Readr.Secrets"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
