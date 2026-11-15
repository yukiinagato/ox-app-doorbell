package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

/**
 * Coalesces snapshot reloads. Main-thread only: [request] says whether the caller starts a
 * load, and a request that arrives while one is running makes [complete] ask for one more.
 */
internal class ReloadGate {
    private var running = false
    private var queued = false

    fun request(): Boolean {
        if (running) {
            queued = true
            return false
        }
        running = true
        return true
    }

    /** True when another load must start right away; the gate then stays running. */
    fun complete(): Boolean {
        if (queued) {
            queued = false
            return true
        }
        running = false
        return false
    }
}

/**
 * Counts this screen's own writes in flight. Core echoes each write as a change event; while
 * any is pending the event refresh is dropped because the write's own completion reloads.
 */
internal class PendingWrites {
    private var count = 0

    val idle: Boolean get() = count == 0

    fun begin() {
        count++
    }

    fun end() {
        if (count > 0) count--
    }
}

/** Decides whether a reloaded snapshot needs the page rebuilt. */
internal class RenderGate {
    private var rendered: String? = null

    fun rendered(fingerprint: String) {
        rendered = fingerprint
    }

    fun needed(fingerprint: String): Boolean = fingerprint != rendered
}

internal object SettingsFingerprint {
    fun of(vararg documents: JSONObject?): String =
        documents.joinToString("\u0000") { it?.toString().orEmpty() }

    /** Every `secret:<name>` reference in [node], so presence can be read off the main thread. */
    fun secretNames(node: Any?, out: MutableSet<String> = HashSet()): Set<String> {
        when (node) {
            is JSONObject -> for (key in node.keys()) secretNames(node.opt(key), out)
            is JSONArray -> for (i in 0 until node.length()) secretNames(node.opt(i), out)
            is String -> SecretRefs.storeKey(node)?.let { out.add(it) }
        }
        return out
    }
}
