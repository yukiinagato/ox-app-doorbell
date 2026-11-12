package jp.ox.doorbell

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Runs the production Activity with an inert Core and a recording call gateway. */
class VisitorUiInstrumentation : Instrumentation() {
    private lateinit var args: Bundle
    private lateinit var activity: MainActivity
    private lateinit var app: App
    private var callClockMs = System.currentTimeMillis()
    private lateinit var gateway: Gateway
    private val results = JSONArray()
    private lateinit var output: File
    private val applicationReady = CountDownLatch(1)

    override fun callApplicationOnCreate(application: Application) {
        super.callApplicationOnCreate(application)
        applicationReady.countDown()
    }

    override fun onCreate(arguments: Bundle?) {
        args = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        var failure: Throwable? = null
        try {
            check(applicationReady.await(15, TimeUnit.SECONDS)) { "Application initialization did not finish" }
            app = targetContext.applicationContext as App
            check(!app.core.isCreated) { "The UI fixture must never start Core" }
            set(app, "bootSetupRequired", false)
            app.deferPairing()
            set(app.runtime, "isCoreReady", true)
            set(app.runtime, "handler", Handler(Looper.getMainLooper()))
            output = File(targetContext.getExternalFilesDir(null), "t35-ui").apply { mkdirs() }
            activity = startActivitySync(Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            uiAutomation.rootInActiveWindow?.findAccessibilityNodeInfosByText("Got it")?.firstOrNull()
                ?.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK)
            ui { activity.requestedOrientation = if (args.getString("orientation") == "landscape")
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            val expected = if (args.getString("orientation") == "landscape") 2 else 1
            val deadline = SystemClock.uptimeMillis() + 5000
            while (activity.resources.configuration.orientation != expected && SystemClock.uptimeMillis() < deadline)
                Thread.sleep(50)
            settle()
            if (args.getString("phase") == "baseline") {
                prepare("purpose_first")
                capture("idle")
                ui { button(R.id.call_button).performClick() }
                capture("ringing")
                results.put(JSONObject().put("id", "baseline_capture").put("status", "RECORDED"))
            } else {
                case("T35-01 purpose_first") {
                    prepare("purpose_first")
                    ui { button(R.id.call_button).performClick() }
                    check(gateway.presses == listOf(""))
                    ui { button(R.id.cancel_button).performClick() }
                    check(gateway.cancels == 1 && gateway.hangups == 0)
                    prepare("purpose_first")
                    ui { (activity.findViewById<ViewGroup>(R.id.purpose_grid).getChildAt(0) as Button).performClick() }
                    check(gateway.presses == listOf("delivery"))
                }
                case("T35-01 ring_then_purpose") {
                    prepare("ring_then_purpose")
                    ui { button(R.id.call_button).performClick() }
                    check(gateway.presses == listOf(""))
                    check(button(R.id.purpose_cancel_button).visibility == View.VISIBLE)
                    ui { (activity.findViewById<ViewGroup>(R.id.purpose_grid).getChildAt(0) as Button).performClick() }
                    check(gateway.selections == listOf("delivery"))
                    ui { button(R.id.cancel_button).performClick() }
                    check(gateway.cancels == 1)
                    prepare("ring_then_purpose")
                    ui { button(R.id.call_button).performClick(); button(R.id.purpose_skip_button).performClick() }
                    check(gateway.presses.size == 1 && gateway.selections.isEmpty())
                }
                case("T35-02 stable slot and gesture ownership") {
                    prepare("purpose_first")
                    ui { button(R.id.call_button).performClick() }
                    capture("ringing")
                    val before = bounds(button(R.id.cancel_button))
                    val now = SystemClock.uptimeMillis()
                    ui {
                        val b = button(R.id.cancel_button)
                        b.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, b.width / 2f, b.height / 2f, 0))
                        invoke("applyCallProjection", app.callFlow.markEstablished())
                        invoke("showEstablished")
                        b.dispatchTouchEvent(MotionEvent.obtain(now, now + 20, MotionEvent.ACTION_UP, b.width / 2f, b.height / 2f, 0))
                    }
                    settle()
                    check(gateway.cancels == 0 && gateway.hangups == 0) { "A held cancel changed semantics" }
                    check(before == bounds(button(R.id.cancel_button))) { "The primary action moved" }
                    capture("established")
                    ui { button(R.id.cancel_button).performClick() }
                    check(gateway.hangups == 1 && gateway.cancels == 0)
                }
                case("T35-03 neutral recovery and accessible SOS") {
                    prepare("purpose_first")
                    ui { button(R.id.call_button).performClick(); invoke("showOffline") }
                    val pane = activity.findViewById<View>(R.id.offline_view)
                    // Neutral recovery: the pane is the theme's plain background, never an alarm colour.
                    val neutral = android.util.TypedValue()
                    check(activity.theme.resolveAttribute(android.R.attr.colorBackground, neutral, true))
                    @Suppress("DEPRECATION")
                    val expected = if (neutral.resourceId != 0)
                        activity.resources.getColor(neutral.resourceId) else neutral.data
                    check((pane.background as ColorDrawable).color == expected)
                    check(!button(R.id.cancel_button).isEnabled)
                    capture("recovering")
                    prepare("purpose_first")
                    val trigger = get(activity, "sosSlider") as SosTriggerView
                    var fired = 0
                    // A tap, or the accessibility click, only opens the confirmation surface.
                    ui {
                        trigger.onTrigger = { fired++ }
                        triggerButton(trigger).performAccessibilityAction(
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null)
                    }
                    ui {
                        val surface = checkNotNull(trigger.surface) { "The tap opened no surface" }
                        check(surface.showing && !trigger.isArmed() && fired == 0)
                        check(!surface.sendButton.isFocused) { "Send SOS took the default focus" }
                        check(triggerButton(trigger).height < activity.resources.displayMetrics.density * 72) {
                            "The SOS trigger competes with the primary action"
                        }
                    }
                    capture("sos-confirm")
                    // The focusable Send SOS button is the non-drag path into the same countdown.
                    ui { trigger.surface!!.sendButton.performClick() }
                    ui {
                        check(trigger.isArmed() && fired == 0)
                        check(trigger.surface!!.sendButton.visibility == View.GONE)
                        trigger.surface!!.cancelButton.performClick()
                    }
                    ui { check(!trigger.isArmed() && fired == 0 && trigger.surface == null) }
                    // A slide released short of the end springs back; a full slide arms.
                    ui { trigger.open() }
                    ui {
                        val slide = trigger.surface!!.slide
                        val time = SystemClock.uptimeMillis()
                        slide.dispatchTouchEvent(MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, 4f, slide.height / 2f, 0))
                        slide.dispatchTouchEvent(MotionEvent.obtain(time, time + 20, MotionEvent.ACTION_UP, slide.width / 2f, slide.height / 2f, 0))
                        check(!trigger.isArmed() && fired == 0) { "A short slide armed the SOS" }
                        slide.dispatchTouchEvent(MotionEvent.obtain(time, time + 40, MotionEvent.ACTION_DOWN, 4f, slide.height / 2f, 0))
                        slide.dispatchTouchEvent(MotionEvent.obtain(time, time + 60, MotionEvent.ACTION_UP, slide.width.toFloat(), slide.height / 2f, 0))
                        check(trigger.isArmed() && fired == 0)
                        // A press held on the slide or on the trigger arms nothing by itself.
                        trigger.cancelCountdown()
                        check(!triggerButton(trigger).performLongClick() || trigger.surface == null)
                    }
                    ui { check(!trigger.isArmed() && fired == 0) }
                }
                for (interruption in listOf("cancel", "detach", "replace")) {
                    case("T35-R1 stale SOS confirmation after $interruption") {
                        prepare("purpose_first")
                        val trigger = get(activity, "sosSlider") as SosTriggerView
                        var fired = 0
                        var replacement: SosConfirmSurface? = null
                        ui {
                            trigger.configure("SOS", "", "Cancel", 3) { it.toString() }
                            trigger.onTrigger = { fired++ }
                            trigger.open()
                        }
                        ui {
                            val original = checkNotNull(trigger.surface)
                            original.sendButton.performClick()
                            check(trigger.isArmed())
                            if (interruption == "detach") {
                                val parent = trigger.parent as ViewGroup
                                val index = parent.indexOfChild(trigger)
                                val parameters = trigger.layoutParams
                                parent.removeView(trigger)
                                parent.addView(trigger, index, parameters)
                            } else {
                                trigger.cancelCountdown()
                            }
                            // The surface that was closed must never deliver its confirmation.
                            original.slide.confirm()
                            original.sendButton.performClick()
                        }
                        if (interruption == "replace") {
                            ui {
                                trigger.configure("SOS", "", "Cancel", 0) { it.toString() }
                                trigger.onTrigger = { fired++ }
                                trigger.open()
                            }
                            ui { replacement = checkNotNull(trigger.surface) }
                        }
                        ui {
                            check(fired == 0 && !trigger.isArmed()) {
                                "A closed SOS confirmation survived $interruption: triggers=$fired"
                            }
                            replacement?.let {
                                check(trigger.surface === it && it.showing) {
                                    "The old surface cleared its replacement"
                                }
                                it.sendButton.performClick()
                            }
                        }
                        ui {
                            check(fired == if (interruption == "replace") 1 else 0)
                            check(!trigger.isArmed())
                        }
                    }
                }
                case("T35-04 long text and scaled primary actions") {
                    prepare("purpose_first")
                    ui { button(R.id.call_button).text = "Call the resident at the main entrance / 呼叫主入口的住户" }
                    settle()
                    assertFullyVisible(button(R.id.call_button))
                    capture("long-idle")
                    tap(button(R.id.call_button))
                    ui { button(R.id.cancel_button).text = "Cancel this visitor call / 取消本次访客呼叫" }
                    settle()
                    assertFullyVisible(button(R.id.cancel_button))
                    capture("long-calling")
                    tap(button(R.id.cancel_button))
                    check(gateway.cancels == 1)
                    prepare("purpose_first")
                    tap(button(R.id.call_button))
                    ui {
                        callClockMs += 120_000
                        (get(activity, "callTimeout") as Runnable).run()
                    }
                    val status = activity.findViewById<TextView>(R.id.visitor_status)
                    check(status.visibility == View.VISIBLE && status.text.isNotEmpty())
                    val area = bounds(status)
                    check(area.height() == status.height)
                    assertFullyVisible(button(R.id.call_button))
                    check(gateway.cancels == 1)
                    capture("no-answer")
                }
            }
            check(!app.core.isCreated) { "Fixture started Core unexpectedly" }
        } catch (t: Throwable) { failure = t }
        val report = JSONObject().put("phase", args.getString("phase", "green"))
            .put("orientation", args.getString("orientation", "portrait"))
            .put("font_scale", targetContext.resources.configuration.fontScale)
            .put("source_id", BuildConfig.DOORBELL_SOURCE_ID).put("results", results)
            .put("core_started", app.core.isCreated).put("failure", failure?.stackTraceToString() ?: JSONObject.NULL)
        if (::output.isInitialized) File(output, "result.json").writeText(report.toString(2))
        if (::activity.isInitialized) ui { activity.finish() }
        finish(if (failure == null) Activity.RESULT_OK else Activity.RESULT_CANCELED,
            Bundle().apply { putString("stream", report.toString(2)) })
    }

    private fun prepare(mode: String) {
        gateway = Gateway()
        val store = object : OriginatedCallPersistence {
            override fun load(): OriginatedCall? = null
            override fun save(call: OriginatedCall) = true
            override fun clear() { }
        }
        set(app, "callFlow", CallFlowController(gateway, store) { callClockMs })
        ui {
            (get(activity, "ui") as Handler).removeCallbacksAndMessages(null)
            set(activity, "homeHandler", null)
            val config = JSONObject().put("ui", JSONObject().put("call_flow", mode)
                .put("call_sound", "").put("button_sound", "").put("launch_sound", ""))
                .put("visit_purposes", JSONObject().put("delivery", JSONObject().put("label", JSONObject()
                    .put("en", "Delivery at the main entrance / 主入口配送").put("ja", "配送 / Delivery"))))
                .put("emergency", JSONObject().put("button_on_roles", JSONArray().put("door_station"))
                    .put("trigger", JSONObject().put("countdown_s", 3)))
            invoke("applyConfigCache", config)
            invoke("clearCallProjection")
            invoke("buildPurposeButtons")
            invoke("applyStrings")
            invoke("configureSos")
            invoke("applyVisitorLayout")
            invoke("showIdle", null)
            activity.findViewById<View>(R.id.pairing_banner).visibility = View.GONE
        }
        settle()
    }

    private fun case(name: String, body: () -> Unit) {
        try { body(); results.put(JSONObject().put("id", name).put("status", "PASS")) }
        catch (t: Throwable) { results.put(JSONObject().put("id", name).put("status", "FAIL").put("error", t.toString())); throw t }
    }
    private fun settle(frames: Int = 2) {
        val frame = CountDownLatch(1)
        var remaining = frames
        val callback = object : Runnable {
            override fun run() {
                if (--remaining == 0) frame.countDown()
                else activity.window.decorView.postOnAnimation(this)
            }
        }
        runOnMainSync { activity.window.decorView.postOnAnimation(callback) }
        check(frame.await(5, TimeUnit.SECONDS)) { "UI frames did not advance" }
    }
    private fun tap(view: View) {
        val rect = bounds(view)
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action,
                rect.exactCenterX(), rect.exactCenterY(), 0)
            sendPointerSync(event)
            event.recycle()
        }
        settle()
    }
    private fun button(id: Int) = activity.findViewById<Button>(id)
    private fun triggerButton(trigger: SosTriggerView) = trigger.getChildAt(0) as Button
    private fun ui(body: () -> Unit) {
        var failure: Throwable? = null
        runOnMainSync { try { body() } catch (t: Throwable) { failure = t } }
        failure?.let { throw it }
        settle()
    }
    private fun invoke(name: String, vararg values: Any?) = MainActivity::class.java.declaredMethods
        .first { it.name == name && it.parameterTypes.size == values.size }
        .apply { isAccessible = true }.invoke(activity, *values)
    private fun get(owner: Any, name: String): Any? = owner.javaClass.getDeclaredField(name)
        .apply { isAccessible = true }.get(owner)
    private fun set(owner: Any, name: String, value: Any?) = owner.javaClass.getDeclaredField(name)
        .apply { isAccessible = true }.set(owner, value)
    private fun bounds(view: View) = Rect().also { check(view.getGlobalVisibleRect(it)) }
    private fun assertFullyVisible(view: View) {
        val area = bounds(view)
        check(area.height() == view.height && area.width() == view.width && view.height >= 48 * activity.resources.displayMetrics.density)
        check(view.isEnabled && view.isFocusable)
    }
    private fun capture(name: String) {
        settle(20)
        uiAutomation.takeScreenshot()?.let { bitmap ->
            File(output, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        fun tree(view: View): JSONObject {
            val area = Rect(); view.getGlobalVisibleRect(area)
            val o = JSONObject().put("class", view.javaClass.simpleName).put("visibility", view.visibility)
                .put("enabled", view.isEnabled).put("bounds", area.toShortString())
                .put("id", if (view.id == View.NO_ID) "" else try { view.resources.getResourceEntryName(view.id) } catch (_: Exception) { "" })
            if (view is TextView) o.put("text", view.text.toString())
            if (view is ViewGroup) o.put("children", JSONArray().also { a -> for (i in 0 until view.childCount) a.put(tree(view.getChildAt(i))) })
            return o
        }
        ui { File(output, "$name-tree.json").writeText(tree(activity.window.decorView).toString(2)) }
    }
    private class Gateway : CallFlowGateway {
        val presses = mutableListOf<String>(); val selections = mutableListOf<String>()
        var cancels = 0; var hangups = 0
        override fun press(door: String, purpose: String): String { presses.add(purpose); return "fixture-call-${presses.size}" }
        override fun selectPurpose(door: String, callId: String, purpose: String): Boolean { selections.add(purpose); return true }
        override fun cancel(door: String, callId: String, reason: String): Boolean { cancels++; return true }
        override fun reportRecovery(callId: String, restored: Boolean) { }
        override fun hangup() { hangups++ }
    }
}
