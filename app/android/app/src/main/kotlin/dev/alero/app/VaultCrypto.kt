package dev.alero.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Hardware-backed Android Keystore when the device supports it; AES-GCM
 * authenticates both the content and the per-entry random IV.
 * No plaintext, key or note title is stored in shared preferences.
 */
internal object VaultCrypto {
    private const val ALIAS = "alero.vault.aesgcm.v1"
    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val IV_LENGTH = 12

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val current = store.getKey(ALIAS, null) as? SecretKey
        if (current != null) return current
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore"
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setKeySize(256)
             .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
             .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
             .setRandomizedEncryptionRequired(true)
             .build()
        )
        return generator.generateKey()
    }

    @Synchronized
    fun seal(input: ByteArray): ByteArray {
        require(input.size <= 15 * 1024 * 1024) { "Contenido demasiado grande" }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        require(iv.size == IV_LENGTH)
        return byteArrayOf(1) + iv + cipher.doFinal(input)
    }

    @Synchronized
    fun open(blob: ByteArray): ByteArray {
        require(blob.size >= 1 + IV_LENGTH + 16 && blob[0] == 1.toByte()) {
            "Formato de bóveda no compatible"
        }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(
            Cipher.DECRYPT_MODE, key(),
            GCMParameterSpec(128, blob.copyOfRange(1, 1 + IV_LENGTH))
        )
        return cipher.doFinal(blob.copyOfRange(1 + IV_LENGTH, blob.size))
    }
}
