package jp.ox.doorbell

import android.content.Context
import android.security.KeyPairGeneratorSpec
import android.util.Base64
import android.util.Log
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.util.Calendar
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

/** API 19-compatible encrypted secret storage with a non-exportable AndroidKeyStore RSA key. */
internal class AndroidSecureStore(context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val random = SecureRandom()

    @Synchronized
    fun get(key: String): String? {
        if (!validKey(key)) return null
        val encoded = prefs.getString(valueKey(key), null) ?: return null
        return try {
            val master = masterMaterial() ?: return null
            val blob = Base64.decode(encoded, Base64.NO_WRAP)
            if (blob.size < 1 + IV_BYTES + MAC_BYTES || blob[0].toInt() != VERSION) return null
            val iv = blob.copyOfRange(1, 1 + IV_BYTES)
            val tag = blob.copyOfRange(1 + IV_BYTES, 1 + IV_BYTES + MAC_BYTES)
            val encrypted = blob.copyOfRange(1 + IV_BYTES + MAC_BYTES, blob.size)
            val calculated = mac(master, blob, 0, 1 + IV_BYTES, encrypted)
            if (!MessageDigest.isEqual(tag, calculated)) return null
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(master, 0, AES_BYTES, "AES"),
                        IvParameterSpec(iv))
            String(cipher.doFinal(encrypted), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w(TAG, "secure get failed for key id", e)
            null
        }
    }

    @Synchronized
    fun put(key: String, value: String): Boolean {
        if (!validKey(key) || value.toByteArray(Charsets.UTF_8).size > MAX_VALUE_BYTES) return false
        return try {
            val master = masterMaterial() ?: return false
            val iv = ByteArray(IV_BYTES).also(random::nextBytes)
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(master, 0, AES_BYTES, "AES"),
                        IvParameterSpec(iv))
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val prefix = ByteArray(1 + IV_BYTES)
            prefix[0] = VERSION.toByte()
            System.arraycopy(iv, 0, prefix, 1, iv.size)
            val tag = mac(master, prefix, 0, prefix.size, encrypted)
            val blob = ByteArray(prefix.size + tag.size + encrypted.size)
            System.arraycopy(prefix, 0, blob, 0, prefix.size)
            System.arraycopy(tag, 0, blob, prefix.size, tag.size)
            System.arraycopy(encrypted, 0, blob, prefix.size + tag.size, encrypted.size)
            prefs.edit().putString(valueKey(key), Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
        } catch (e: Exception) {
            Log.w(TAG, "secure put failed for key id", e)
            false
        }
    }

    /** Remove one secret. A key that was never stored is already in the requested state. */
    @Synchronized
    fun delete(key: String): Boolean {
        if (!validKey(key)) return false
        return try {
            prefs.edit().remove(valueKey(key)).commit()
        } catch (e: Exception) {
            Log.w(TAG, "secure delete failed for key id", e)
            false
        }
    }

    @Synchronized
    fun selfTest(): Boolean {
        val key = "platform.self_test"
        val value = ByteArray(24).also(random::nextBytes).joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
        val ok = put(key, value) && get(key) == value
        prefs.edit().remove(valueKey(key)).commit()
        return ok
    }

    private fun masterMaterial(): ByteArray? {
        val wrapped = prefs.getString(WRAPPED_MASTER, null)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (wrapped != null && !keyStore.containsAlias(KEY_ALIAS)) return null
        if (!keyStore.containsAlias(KEY_ALIAS)) generateKeyPair()
        return if (wrapped != null) {
            val privateKey = keyStore.getKey(KEY_ALIAS, null) as? PrivateKey ?: return null
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(Cipher.DECRYPT_MODE, privateKey)
            cipher.doFinal(Base64.decode(wrapped, Base64.NO_WRAP)).takeIf {
                it.size == MASTER_BYTES
            }
        } else {
            val publicKey = keyStore.getCertificate(KEY_ALIAS)?.publicKey ?: return null
            val material = ByteArray(MASTER_BYTES).also(random::nextBytes)
            val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
            cipher.init(Cipher.ENCRYPT_MODE, publicKey)
            val stored = prefs.edit().putString(
                WRAPPED_MASTER,
                Base64.encodeToString(cipher.doFinal(material), Base64.NO_WRAP),
            ).commit()
            if (stored) material else null
        }
    }

    @Suppress("DEPRECATION")
    private fun generateKeyPair() {
        val start = Calendar.getInstance()
        val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }
        val spec = KeyPairGeneratorSpec.Builder(app)
            .setAlias(KEY_ALIAS)
            .setSubject(X500Principal("CN=Doorbell Platform Secure Store"))
            .setSerialNumber(BigInteger.ONE)
            .setStartDate(start.time)
            .setEndDate(end.time)
            .setKeySize(2048)
            .build()
        KeyPairGenerator.getInstance("RSA", "AndroidKeyStore").apply {
            initialize(spec)
            generateKeyPair()
        }
    }

    private fun mac(
        master: ByteArray,
        prefix: ByteArray,
        offset: Int,
        length: Int,
        encrypted: ByteArray,
    ): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(master, AES_BYTES, HMAC_BYTES, "HmacSHA256"))
        update(prefix, offset, length)
        doFinal(encrypted)
    }

    private fun valueKey(key: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        return "v_" + Base64.encodeToString(digest, Base64.NO_WRAP or Base64.URL_SAFE)
    }

    private fun validKey(key: String): Boolean = key.isNotBlank() && key.length <= 512

    companion object {
        private const val TAG = "doorbell-secure-store"
        private const val PREFS = "doorbell_secure_v1"
        private const val KEY_ALIAS = "jp.ox.doorbell.platform.v1"
        private const val WRAPPED_MASTER = "wrapped_master"
        private const val VERSION = 1
        private const val AES_BYTES = 16
        private const val HMAC_BYTES = 32
        private const val MASTER_BYTES = AES_BYTES + HMAC_BYTES
        private const val IV_BYTES = 16
        private const val MAC_BYTES = 32
        private const val MAX_VALUE_BYTES = 64 * 1024
    }
}
