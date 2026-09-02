package jp.ox.doorbell

import java.io.File
import java.io.FileOutputStream
import org.json.JSONObject

/** Atomic last-known-good UI style storage. Only validated styles are passed to this store. */
internal class UiStyleLkgStore(private val file: File) {
    private var entries = load(file) ?: load(backup()) ?: JSONObject()

    @Synchronized
    fun get(nodeId: String, semanticId: String): JSONObject? =
        entries.optJSONObject(nodeId)?.optJSONObject(semanticId)?.let {
            JSONObject(it.toString())
        }

    @Synchronized
    fun save(nodeId: String, semanticId: String, style: JSONObject): Boolean {
        if (nodeId.isBlank() || nodeId.length > 256 || semanticId.isBlank() ||
            semanticId.length > 128) return false
        val serializedStyle = style.toString()
        if (serializedStyle.toByteArray(Charsets.UTF_8).size > MAX_STYLE_BYTES) return false
        if (entries.optJSONObject(nodeId)?.optJSONObject(semanticId)?.toString() == serializedStyle)
            return true
        val updated = JSONObject(entries.toString())
        val node = updated.optJSONObject(nodeId) ?: JSONObject().also { updated.put(nodeId, it) }
        node.put(semanticId, JSONObject(serializedStyle))
        val root = JSONObject().put("schema_version", 1).put("entries", updated)
        val bytes = root.toString().toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_BYTES) return false
        val parent = file.parentFile ?: return false
        if (!parent.exists() && !parent.mkdirs()) return false
        val tmp = File(parent, file.name + ".tmp")
        return try {
            if (file.isFile) file.copyTo(backup(), overwrite = true)
            FileOutputStream(tmp).use { output ->
                output.write(bytes)
                output.flush()
                output.fd.sync()
            }
            if (!tmp.renameTo(file)) throw java.io.IOException("rename failed")
            entries = updated
            true
        } catch (_: Exception) {
            tmp.delete()
            false
        }
    }

    private fun backup(): File = File(file.parentFile, file.name + ".bak")

    private fun load(source: File): JSONObject? {
        if (!source.isFile || source.length() !in 1..MAX_BYTES.toLong()) return null
        return try {
            val root = JSONObject(source.readText(Charsets.UTF_8))
            if (root.optInt("schema_version") != 1) null
            else root.optJSONObject("entries")?.let { JSONObject(it.toString()) }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val MAX_STYLE_BYTES = 4 * 1024
        private const val MAX_BYTES = 256 * 1024
    }
}
