// What the editor's "Try it" walks: the administrator's steps (saved or still a draft) turned into
// the shape Core's resolved document has, so the same walker and page renderer as the door
// station's own screen run it. Nothing here calls Core.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

internal object FlowPreview {

    /** A resolved-looking document for [steps] starting at the page [start]. */
    fun document(config: JSONObject?, steps: Map<String, JSONObject>, start: String): JSONObject {
        val resolved = JSONObject()
        for ((id, raw) in steps) resolved.put(id, resolveStep(config, raw))
        return JSONObject()
            .put("enabled", true)
            .put("start", start)
            .put("idle_s", 3600)
            .put("revision", "preview")
            .put("steps", resolved)
    }

    /** A page's options take the purpose's label and icon when they carry none of their own. */
    private fun resolveStep(config: JSONObject?, raw: JSONObject): JSONObject {
        val step = JSONObject(raw.toString())
        if (step.optString("kind") != "page") return step
        val options = JSONArray()
        val source = step.optJSONArray("options")
        if (source != null) for (i in 0 until source.length()) {
            val option = source.optJSONObject(i) ?: continue
            if (!option.optBoolean("enabled", true)) continue
            val purpose = option.optString("purpose")
            val copy = JSONObject(option.toString())
            if (copy.optJSONObject("label") == null && purpose.isNotEmpty())
                VisitPurposes.rootOf(config)?.optJSONObject(purpose)?.optJSONObject("label")
                    ?.let { copy.put("label", it) }
            if (copy.optString("icon").isEmpty() && purpose.isNotEmpty())
                VisitPurposes.icon(config, purpose).takeIf { it.isNotEmpty() }
                    ?.let { copy.put("icon", it) }
            options.put(copy)
        }
        return step.put("options", options)
    }

    /** What a walk of the preview did at the end of a tap, for the line under the page. */
    sealed class Outcome {
        object None : Outcome()
        data class Ring(val purpose: String) : Outcome()
        data class Message(val step: String, val then: String?) : Outcome()
    }

    /** The terminal action a list of walker calls stands for; the last one decides. */
    fun outcome(calls: List<FlowCall>, endStep: String?): Outcome {
        val press = calls.filterIsInstance<FlowCall.Press>().lastOrNull()
        if (press != null) return Outcome.Ring(press.purpose)
        val notify = calls.filterIsInstance<FlowCall.Notify>().lastOrNull() ?: return Outcome.None
        return Outcome.Message(notify.step, endStep)
    }
}
