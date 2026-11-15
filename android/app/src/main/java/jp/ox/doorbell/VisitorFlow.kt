// Shell-side model of the door station's visitor flow (docs/en/visitor-flow-contract.md, section 5).
//
// Core resolves the flow; this walks the resolved document. It holds a stack of page ids, turns a
// tap into the next page or into one of the two terminal Core calls, and answers Back, the idle
// timeout, an unanswered call, a throttled or failed notify, a replaced document and a reply
// overlay. It never reads raw configuration and never invents text. Pure Kotlin (org.json only),
// host-tested against tools/conformance/fixtures/visitor-flow-v1.json.
package jp.ox.doorbell

import org.json.JSONArray
import org.json.JSONObject

/** The two terminal calls a walk can cause, in the order Core must see them. */
internal sealed class FlowCall {
    data class Press(val purpose: String) : FlowCall()
    data class Notify(val step: String) : FlowCall()
}

internal data class FlowOptionView(
    val id: String,
    val semanticId: String,
    val label: String,
    val icon: String,
    val primary: Boolean,
    val purpose: String = "",
    /** True when the option leads straight to a call step: the only kind that rings. */
    val call: Boolean = false,
)

internal data class FlowImageView(
    val asset: String,
    val path: String?,
    val alt: String,
    val above: Boolean,
)

/** What is on screen. [page] is the page or end-step id; [options] is empty off a page. */
internal data class FlowSnapshot(
    val mode: String,
    val page: String?,
    val title: String?,
    val body: String?,
    val options: List<FlowOptionView>,
    val images: List<FlowImageView>,
    val back: Boolean,
    val done: Boolean,
    val notice: String?,
    val reply: Boolean,
)

/** What a tap leads to, so the shell can run the Core call before the walker records the result. */
internal sealed class FlowTarget {
    object Nothing : FlowTarget()
    object Page : FlowTarget()
    object End : FlowTarget()
    data class Call(val purpose: String) : FlowTarget()
    data class Notify(val step: String, val purpose: String) : FlowTarget()

    /** Unknown kind or a target missing from the document: ring with no purpose. */
    object Direct : FlowTarget()
}

internal sealed class FlowEvent {
    /** [notifyOk] is the notify result's `ok` (a throttled result is still ok). */
    data class Tap(
        val option: String,
        val notifyOk: Boolean = true,
        val pressFailed: Boolean = false,
    ) : FlowEvent()
    object Back : FlowEvent()
    object IdleTimeout : FlowEvent()
    object Done : FlowEvent()
    data class CallEnded(val reason: String) : FlowEvent()
    data class Reply(val showing: Boolean) : FlowEvent()
    data class Language(val lang: String) : FlowEvent()
    data class FlowChanged(val flow: JSONObject?) : FlowEvent()
}

internal object FlowText {
    /** The language, then Japanese, then whatever the document carries. */
    fun textIn(labels: JSONObject?, lang: String): String? {
        if (labels == null) return null
        for (key in arrayOf(lang, "ja")) {
            val value = labels.optString(key, "")
            if (value.isNotEmpty()) return value
        }
        for (key in labels.keys()) {
            val value = labels.optString(key, "")
            if (value.isNotEmpty()) return value
        }
        return null
    }
}

internal class FlowWalker(flow: JSONObject?, var lang: String = "ja") {

    private var flow: JSONObject = JSONObject()
    var mode: String = MODE_LEGACY
        private set
    private var stack: MutableList<String> = ArrayList()
    private var activeStep: String? = null
    private var notice: String? = null
    private var reply = false

    init {
        load(flow)
        home()
    }

    val enabled: Boolean get() = enabled(flow)
    val revision: String get() = flow.optString("revision", "")
    val idleSeconds: Int get() = flow.optInt("idle_s", DEFAULT_IDLE_S).coerceIn(5, 3600)
    val startId: String get() = flow.optString("start", "")

    /** The seconds an end page stays up, from the step on screen. */
    val returnSeconds: Int
        get() = step(activeStep).optInt("return_s", DEFAULT_RETURN_S).coerceIn(1, 600)

    val currentPageId: String?
        get() = when (mode) {
            MODE_PAGE -> stack.lastOrNull()
            MODE_END -> activeStep
            else -> null
        }

    /** The call step a call in progress belongs to. */
    val callStepId: String? get() = if (mode == MODE_CALLING) activeStep else null

    fun snapshot(): FlowSnapshot {
        val page = currentPageId
        val step = step(page)
        val options = ArrayList<FlowOptionView>()
        if (mode == MODE_PAGE) {
            val array = step.optJSONArray("options") ?: JSONArray()
            for (i in 0 until array.length()) {
                val option = array.optJSONObject(i) ?: continue
                options.add(FlowOptionView(
                    id = option.optString("id"),
                    semanticId = option.optString("semantic_id"),
                    label = FlowText.textIn(option.optJSONObject("label"), lang).orEmpty(),
                    icon = option.optString("icon"),
                    primary = option.optString("style") == "primary",
                    purpose = option.optString("purpose"),
                    call = kind(option.optString("to")) == "call",
                ))
            }
        }
        val images = ArrayList<FlowImageView>()
        if (page != null) {
            val array = step.optJSONArray("images") ?: JSONArray()
            for (i in 0 until array.length()) {
                val image = array.optJSONObject(i) ?: continue
                images.add(FlowImageView(
                    asset = image.optString("asset"),
                    path = if (image.isNull("path")) null else image.optString("path").ifEmpty { null },
                    alt = FlowText.textIn(image.optJSONObject("alt"), lang).orEmpty(),
                    above = image.optString("place", "above") != "below",
                ))
            }
        }
        return FlowSnapshot(
            mode = mode,
            page = page,
            title = if (page != null) FlowText.textIn(step.optJSONObject("title"), lang) else null,
            body = if (page != null) FlowText.textIn(step.optJSONObject("body"), lang) else null,
            options = options,
            images = images,
            back = mode == MODE_PAGE && stack.size > 1,
            done = mode == MODE_END,
            notice = notice,
            reply = reply,
        )
    }

    /** What tapping [optionId] leads to on the current page. */
    fun targetOf(optionId: String): FlowTarget {
        if (mode != MODE_PAGE) return FlowTarget.Nothing
        val option = optionOf(optionId) ?: return FlowTarget.Nothing
        val target = option.optString("to")
        return when (kind(target)) {
            "page" -> FlowTarget.Page
            "call" -> FlowTarget.Call(purposeOf(target))
            "notify" -> FlowTarget.Notify(target, purposeOf(target))
            "end" -> FlowTarget.End
            else -> FlowTarget.Direct
        }
    }

    /** Applies one input and returns the Core calls it caused, in order. */
    fun apply(event: FlowEvent): List<FlowCall> {
        when (event) {
            is FlowEvent.Reply -> reply = event.showing
            is FlowEvent.Language -> lang = event.lang
            is FlowEvent.FlowChanged -> replace(event.flow)
            is FlowEvent.Tap -> return tap(event)
            FlowEvent.Back -> if (mode == MODE_PAGE && stack.size > 1) {
                stack.removeAt(stack.size - 1)
                notice = null
            }
            FlowEvent.IdleTimeout -> if (mode == MODE_PAGE) {
                stack = stack.take(1).toMutableList()
                notice = null
            }
            FlowEvent.Done -> if (mode == MODE_END) home()
            is FlowEvent.CallEnded -> callEnded(event.reason)
        }
        return emptyList()
    }

    /** A press that came back without a call id after the walker had already moved to calling. */
    fun callFailed() {
        if (mode != MODE_CALLING) return
        mode = MODE_PAGE
        activeStep = null
        notice = PRESS_FAILED_NOTICE
    }

    private fun load(document: JSONObject?) {
        flow = document ?: JSONObject()
    }

    private fun home() {
        activeStep = null
        if (enabled(flow)) {
            mode = MODE_PAGE
            stack = mutableListOf(flow.optString("start"))
        } else {
            mode = MODE_LEGACY
            stack = ArrayList()
        }
    }

    private fun enabled(document: JSONObject): Boolean =
        document.optBoolean("enabled", false) && kindIn(document, document.optString("start")) == "page"

    private fun step(id: String?): JSONObject =
        if (id == null) JSONObject()
        else flow.optJSONObject("steps")?.optJSONObject(id) ?: JSONObject()

    private fun kind(id: String?): String = step(id).optString("kind", "")

    private fun kindIn(document: JSONObject, id: String): String =
        document.optJSONObject("steps")?.optJSONObject(id)?.optString("kind", "").orEmpty()

    private fun purposeOf(id: String?): String = step(id).optString("purpose", "")

    private fun optionOf(optionId: String): JSONObject? {
        val array = step(stack.lastOrNull()).optJSONArray("options") ?: return null
        var found: JSONObject? = null
        for (i in 0 until array.length()) {
            val option = array.optJSONObject(i) ?: continue
            if (option.optString("id") == optionId) found = option
        }
        return found
    }

    private fun directCall(purpose: String, event: FlowEvent.Tap): List<FlowCall> {
        if (event.pressFailed) notice = PRESS_FAILED_NOTICE else mode = MODE_CALLING
        return listOf(FlowCall.Press(purpose))
    }

    private fun tap(event: FlowEvent.Tap): List<FlowCall> {
        if (mode != MODE_PAGE) return emptyList()
        val chosen = optionOf(event.option) ?: return emptyList()
        notice = null
        val target = chosen.optString("to")
        when (kind(target)) {
            "page" -> {
                val index = stack.indexOf(target)
                if (index >= 0) stack = stack.take(index + 1).toMutableList() else stack.add(target)
                return emptyList()
            }
            "call" -> {
                activeStep = target
                return directCall(purposeOf(target), event)
            }
            "notify" -> {
                val calls = ArrayList<FlowCall>()
                calls.add(FlowCall.Notify(target))
                val after = step(target).optString("to")
                if (!event.notifyOk || kind(after) != "end") {
                    // A message that could not be sent must not look delivered: ring instead.
                    activeStep = null
                    calls.addAll(directCall(purposeOf(target), event))
                    return calls
                }
                mode = MODE_END
                activeStep = after
                return calls
            }
            "end" -> {
                mode = MODE_END
                activeStep = target
                return emptyList()
            }
        }
        // Unknown kind or a target that is not in the document: a visitor can always ring.
        activeStep = null
        return directCall("", event)
    }

    private fun callEnded(reason: String) {
        if (mode != MODE_CALLING) return
        val unanswered = step(activeStep).optString("on_unanswered", "")
        home()
        if (reason != "timeout" || mode != MODE_PAGE) return
        if (kind(unanswered) == "page") {
            if (unanswered != stack[0]) stack.add(unanswered)
        } else {
            notice = NO_ANSWER_NOTICE
        }
    }

    private fun replace(document: JSONObject?) {
        val previousMode = mode
        val previousStack = ArrayList(stack)
        val previousStep = activeStep
        load(document)
        if (!enabled(flow)) {
            if (previousMode != MODE_CALLING) home()
            return
        }
        if (previousMode == MODE_CALLING) return
        if (previousMode == MODE_END && kind(previousStep) == "end") return
        val keep = previousMode == MODE_PAGE &&
            previousStack.firstOrNull() == flow.optString("start") &&
            previousStack.all { kind(it) == "page" }
        home()
        if (keep) stack = previousStack
    }

    companion object {
        const val MODE_PAGE = "page"
        const val MODE_CALLING = "calling"
        const val MODE_END = "end"
        const val MODE_LEGACY = "legacy"
        const val NO_ANSWER_NOTICE = "calling.no_answer"
        const val PRESS_FAILED_NOTICE = "flow.call_failed"
        const val DEFAULT_IDLE_S = 45
        const val DEFAULT_RETURN_S = 8
    }
}

/** The three Core entry points a flow shell uses; also lets the model be tested without Core. */
internal object FlowDocuments {
    /** A resolved document, or null when Core published none (classic screen). */
    fun usable(document: JSONObject?): JSONObject? {
        document ?: return null
        if (!document.optBoolean("enabled", false)) return null
        val start = document.optString("start")
        val kind = document.optJSONObject("steps")?.optJSONObject(start)?.optString("kind")
        return if (kind == "page") document else null
    }

    /** The notify result's `ok`; a missing or unreadable result is a failure. */
    fun notifyOk(result: JSONObject?): Boolean = result?.optBoolean("ok", false) == true
}
