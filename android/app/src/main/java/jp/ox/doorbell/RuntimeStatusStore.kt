package jp.ox.doorbell

import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** Atomic local mirror of the runtime JSON also published through core ABI v2. */
class RuntimeStatusStore(
    private val file: File,
    private val onChanged: (JSONObject) -> Unit = {},
) {
    private val root = load()

    fun update(section: String, value: JSONObject) {
        updateValue(section, value)
    }

    fun update(section: String, value: JSONArray) {
        updateValue(section, value)
    }

    fun updateFields(values: JSONObject) {
        val copy = synchronized(this) {
            val keys = values.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = values.opt(key)
                if (value == null || value === JSONObject.NULL) root.remove(key)
                else root.put(key, value)
            }
            persist()
            JSONObject(root.toString())
        }
        try { onChanged(copy) } catch (_: Exception) { }
    }

    private fun updateValue(section: String, value: Any) {
        val copy = synchronized(this) {
            root.put(section, value)
            persist()
            JSONObject(root.toString())
        }
        try { onChanged(copy) } catch (_: Exception) { }
    }

    @Synchronized
    fun snapshot(): JSONObject = JSONObject(root.toString())

    private fun persist() {
        val parent = file.parentFile ?: return
        if (!parent.exists() && !parent.mkdirs()) return
        val tmp = File(parent, file.name + ".tmp")
        try {
            FileOutputStream(tmp).use { out ->
                out.write(root.toString().toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(file)) tmp.delete()
        } catch (_: Exception) {
            tmp.delete()
        }
    }

    private fun load(): JSONObject {
        if (!file.isFile || file.length() !in 1..MAX_BYTES) return JSONObject()
        return try { JSONObject(file.readText(Charsets.UTF_8)) } catch (_: Exception) { JSONObject() }
    }

    companion object {
        private const val MAX_BYTES = 512 * 1024L
    }
}
