// Where a native settings change is written (spec §3, §5.5).
//
// Core owns configuration writes through db_core_set_config_json, db_core_config_batch_json and
// db_core_delete_config_key, which apply the same keys and the same validation the web admin does,
// including its advisory colour warnings. The loopback administration API stays behind them as the
// fallback for a core built before those exports, so a settings screen is never read-only just
// because the device is running an older build.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

internal interface ConfigWriter {
    fun setKey(key: String, valueJson: String): ConfigWriteResult
    fun setBatch(values: List<Pair<String, String>>): ConfigWriteResult
    fun deleteKey(key: String): ConfigWriteResult

    fun setString(key: String, value: String): ConfigWriteResult =
        setKey(key, JSONObject.quote(value))

    fun setInt(key: String, value: Int): ConfigWriteResult = setKey(key, value.toString())

    fun setBool(key: String, value: Boolean): ConfigWriteResult =
        setKey(key, if (value) "true" else "false")
}

/** Writes straight through core. Blocking, so callers stay off the main thread. */
internal class NativeConfigWriter(private val core: DoorbellCore) : ConfigWriter {

    override fun setKey(key: String, valueJson: String): ConfigWriteResult {
        val result = resultOf(core.setConfigJson(key, valueJson))
        if (!result.ok) return result
        // The write committed; a readability warning is advisory and is read straight afterwards.
        return result.copy(warnings = core.lastWriteWarnings())
    }

    override fun deleteKey(key: String): ConfigWriteResult =
        resultOf(core.deleteConfigKey(key))

    override fun setBatch(values: List<Pair<String, String>>): ConfigWriteResult {
        if (values.isEmpty()) return ConfigWriteResult(true)
        val document = core.configBatchJson(ConfigOps.build(values)) ?: return UNSUPPORTED
        val ok = document.optBoolean("ok", false)
        return ConfigWriteResult(
            ok, document.optString("err"), if (ok) 200 else 400,
            warnings = document.optJSONArray("warnings"),
        )
    }

    private fun resultOf(result: Int?): ConfigWriteResult = when (result) {
        null -> UNSUPPORTED
        0 -> ConfigWriteResult(true, status = 200)
        // -1 is a malformed call from this shell; -2 is core refusing or failing to persist.
        -1 -> ConfigWriteResult(false, "bad_request", status = 400)
        else -> ConfigWriteResult(false, "config_rejected", status = 400)
    }

    private companion object {
        /** Distinguishes "this core has no such export" from "core refused the write". */
        val UNSUPPORTED = ConfigWriteResult(false, ConfigWriters.ERR_UNSUPPORTED, 0)
    }
}

internal object ConfigWriters {
    const val ERR_UNSUPPORTED = "unsupported"

    /**
     * Prefer core; fall back to the loopback session. [loopback] is null when the operator only
     * proved themselves locally, in which case a core without the export leaves settings
     * read-only, which is what the screen already reports.
     */
    fun choose(core: DoorbellCore, loopback: AdminSession?): ConfigWriter? = when {
        core.exports.configWrite -> NativeConfigWriter(core)
        loopback != null -> loopback
        else -> null
    }
}

internal object ConfigOps {
    /** The ops document shared by db_core_config_batch_json and POST /api/config/batch. */
    fun build(values: List<Pair<String, String>>): String {
        val ops = JSONArray()
        for ((key, valueJson) in values)
            ops.put(JSONObject().put("op", "set").put("key", key).put("value", parse(valueJson)))
        return JSONObject().put("ops", ops).toString()
    }

    /** A key's value is a JSON document, not a display string; fall back to a bare string. */
    fun parse(valueJson: String): Any = try {
        when {
            valueJson.startsWith("{") -> JSONObject(valueJson)
            valueJson.startsWith("[") -> JSONArray(valueJson)
            else -> JSONObject("{\"v\":$valueJson}").get("v")
        }
    } catch (_: Exception) {
        valueJson
    }
}
