package jp.keihan.doorbell

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import org.json.JSONObject

/** Foreground-service-owned core, camera, encoder, retries, and watchdog heartbeat. */
class RuntimeSupervisor(private val app: App) {
    private val thread = HandlerThread("doorbell-runtime", Process.THREAD_PRIORITY_BACKGROUND)
    private val contractStore = RuntimeStatusStore(File(app.filesDir, "core-contract.json"))
    private val statusStore = RuntimeStatusStore(File(app.filesDir, "runtime-status.json")) {
        app.core.setRuntimeStatus(it)
        if (::handler.isInitialized) handler.post(::captureContract)
    }
    private val helper = RootKeepaliveClient()
    val kioskController = KioskController(app, app.boot, helper, statusStore)
    private val camera = CameraFeeder(app.core)
    private val buildTier = try {
        app.getString(R.string.android_build_tier)
    } catch (_: Exception) {
        "unknown"
    }
    private val legacy19 = buildTier == "legacy19"
    private val commissioningStore = H264CommissioningStore.forDevice(app, app.core.version())
    private val releaseQualification = if (legacy19)
        Api19ReleaseQualification.load(app) else null
    private val encoder = VideoEncoder(
        app.core,
        ::onEncoderStatus,
        if (legacy19) commissioningStore else AlwaysCommissionedEncoder,
    )
    private lateinit var handler: Handler

    @Volatile var isCoreReady = false
        private set
    @Volatile private var running = false
    private var retryAttempt = 0
    private var cameraStarted = false
    private var resolutionIndex = 0
    private var currentActualResolution = ""
    private val triedActualResolutions = LinkedHashSet<String>()
    private var encoderExhausted = false
    private var encoderRetryAtMs = 0L
    private var cameraRetryAtMs = 0L
    private var lastHelperHeartbeatMs = 0L
    private var lastRuntimeHeartbeatMs = 0L
    private var lastCapabilityPublishMs = 0L
    private var lastEncoderSnapshot = VideoEncoder.Snapshot("idle")
    private var lastEncoderWanted = false
    private var decoderState = "idle"
    private var lastRecoveryStatusJson = ""
    @Volatile private var safeMode = app.safeMode
    private var safeModeReason = if (safeMode) "local_crash_loop" else ""

    private val mediaPoll = object : Runnable {
        override fun run() {
            if (!running || !isCoreReady) return
            heartbeatHelper()
            refreshSafeMode()
            publishRuntimeHealth()
            ensureCamera()
            updateEncoderDemand()
            reconcileEmergencyState()
            publishCapabilitiesIfDue()
            handler.postDelayed(this, if (encoder.isRunning) 1_000L else 250L)
        }
    }

    init {
        thread.start()
        handler = Handler(thread.looper)
        statusStore.update("android", JSONObject()
            .put("sdk", Build.VERSION.SDK_INT)
            .put("abi", Build.CPU_ABI)
            .put("build_tier", buildTier)
            .put("sku", Api19ReleaseQualification.currentSku())
            .put("fingerprint", Build.FINGERPRINT))
        statusStore.update("device_info", app.core.platformDeviceInfo())
        statusStore.update("avc_commissioning", JSONObject()
            .put("required", commissioningRequired())
            .put("trigger", if (commissioningRequired()) "install_or_upgrade" else "none")
            .put("release_qualified", releaseQualified())
            .put("qualification_note", if (legacy19)
                "physical-device Camera/SIP/thermal/8-hour qualification is still required" else ""))
        publishDeviceAlertChannels()
        publishRecoveryStatus()
        publishRuntimeHealth(force = true)
    }

    fun start() {
        handler.post {
            if (running) return@post
            running = true
            statusStore.update("runtime", JSONObject().put("state", "starting"))
            publishRuntimeHealth(force = true)
            startCore()
        }
    }

    fun stop(reason: String) {
        handler.post {
            if (!running) return@post
            running = false
            handler.removeCallbacks(mediaPoll)
            camera.encoder = null
            encoder.stop()
            camera.stop()
            cameraStarted = false
            setCoreReady(false, reason)
            publishRuntimeHealth(force = true)
            app.core.destroy()
            statusStore.update("runtime", JSONObject().put("state", "stopped").put("reason", reason))
        }
    }

    fun onPermissionsChanged() {
        handler.post { if (running && isCoreReady) ensureCamera() }
    }

    fun onConfigChanged() {
        handler.post {
            applyHelperConfiguration()
            resolutionIndex = 0
            triedActualResolutions.clear()
            encoderExhausted = false
            encoderRetryAtMs = 0L
            restartCamera()
        }
    }

    fun frameRotationForDeviceRotation(deviceRotation: Int): Int =
        camera.frameRotationForDeviceRotation(deviceRotation)

    fun trimMemory(level: Int) {
        handler.post {
            if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) {
                camera.encoder = null
                encoder.stop()
                encoderExhausted = false
                encoderRetryAtMs = SystemClock.elapsedRealtime() + MEMORY_CODEC_PAUSE_MS
                statusStore.update("memory", JSONObject()
                    .put("state", "critical")
                    .put("trim_level", level)
                    .put("action", "released_avc_encoder"))
            }
        }
    }

    fun status(): JSONObject = statusStore.snapshot()

    fun reportDecoderStatus(state: String, codec: String = "", error: String = "",
                            fallback: String = "") {
        val previous = statusStore.snapshot().optJSONObject("avc_decode")
        decoderState = state
        statusStore.update("avc_decode", JSONObject()
            .put("state", state)
            .put("codec", codec.ifEmpty { previous?.optString("codec").orEmpty() })
            .put("error", error)
            .put("fallback", fallback))
        handler.post { publishCapabilities() }
    }

    fun reportEmergencyPresentation(value: JSONObject) {
        statusStore.update("emergency_presentation", value)
    }

    internal fun reportUiStyleApplication(value: UiStyleApplyReport) {
        handler.post {
            val snapshot = statusStore.snapshot()
            val previous = snapshot.optJSONObject("ui_style")
                ?: snapshot.optJSONObject("ui_style_application")
            val root = if (previous?.optString("node_id") == value.nodeId)
                JSONObject(previous.toString()) else JSONObject()
                    .put("schema_version", 1)
                    .put("node_id", value.nodeId)
                    .put("minimum_touch_dp", 48)
                    .put("elements", JSONObject())
            val elements = root.optJSONObject("elements") ?: JSONObject().also {
                root.put("elements", it)
            }
            val result = JSONObject()
                .put("result", value.result)
                .put("validation_valid", value.validationValid)
                .put("last_known_good_persisted", value.lastKnownGoodPersisted)
                .put("validation_error", value.validationError)
                .put("persistence_error", value.persistenceError)
            if (elements.optJSONObject(value.semanticId)?.toString() == result.toString())
                return@post
            elements.put(value.semanticId, result)
            statusStore.update("ui_style", root)
        }
    }

    fun onRecoveryPolicyChanged() {
        handler.post { refreshSafeMode() }
    }

    private fun reconcileEmergencyState() {
        val emergency = app.core.status()?.optJSONObject("emergency") ?: return
        app.emergencyAlerts.reconcileCoreState(
            emergency.optBoolean("active", false),
            emergency.optString("hlc"),
        )
    }

    private fun startCore() {
        if (!running || isCoreReady) return
        val ok = try { app.core.start(app.filesDir.absolutePath, app.boot.rawJson) }
            catch (e: Throwable) {
                Log.e(TAG, "core start failed", e)
                false
            }
        if (ok) {
            retryAttempt = 0
            val backend = app.core.backend()
            if (backend.optString("sip") != "pjsip" || backend.optInt("platform_abi") != 2) {
                app.core.destroy()
                setCoreReady(false, "invalid_native_backend")
                statusStore.update("runtime", JSONObject()
                    .put("state", "fatal")
                    .put("reason", "real PJSIP / ABI v2 assertion failed"))
                return
            }
            setCoreReady(true, "started")
            publishRuntimeHealth(force = true)
            statusStore.update("native_backend", backend)
            statusStore.update("runtime", JSONObject().put("state", "ready"))
            app.core.setUiManifest(AndroidRuntimeContracts.uiManifest())
            publishCapabilities()
            applyHelperConfiguration()
            refreshSafeMode()
            handler.removeCallbacks(mediaPoll)
            handler.post(mediaPoll)
        } else {
            val retryDelayMs = RecoveryPolicy.restartBackoffMs(retryAttempt)
            setCoreReady(false, "core_start_failed")
            statusStore.update("runtime", JSONObject()
                .put("state", "retrying")
                .put("retry_ms", retryDelayMs))
            handler.postDelayed({ startCore() }, retryDelayMs)
            retryAttempt = (retryAttempt + 1).coerceAtMost(4)
        }
    }

    private fun setCoreReady(value: Boolean, reason: String) {
        isCoreReady = value
        app.onRuntimeAvailability(value, reason)
    }

    private fun hasCameraPermission(): Boolean = Build.VERSION.SDK_INT < 23 ||
        app.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun ensureCamera() {
        if (app.boot.role != "door_station" || cameraStarted) return
        if (SystemClock.elapsedRealtime() < cameraRetryAtMs) return
        if (!hasCameraPermission()) {
            statusStore.update("camera", JSONObject().put("state", "permission_required"))
            return
        }
        val target = resolutionCandidates()[resolutionIndex.coerceIn(0, resolutionCandidates().lastIndex)]
        val fps = operatingPoint().fps
        cameraStarted = camera.startHeadless(target.first, target.second, fps)
        if (cameraStarted) {
            currentActualResolution = "${camera.frameWidth}x${camera.frameHeight}"
            triedActualResolutions.add(currentActualResolution)
            statusStore.update("camera", JSONObject()
                .put("state", "active")
                .put("width", camera.frameWidth)
                .put("height", camera.frameHeight)
                .put("requested_width", target.first)
                .put("requested_height", target.second))
        } else {
            cameraRetryAtMs = SystemClock.elapsedRealtime() + CAMERA_RETRY_MS
            statusStore.update("camera", JSONObject().put("state", "degraded")
                .put("error", "Camera1 start failed"))
        }
    }

    private fun updateEncoderDemand() {
        if (!cameraStarted || app.boot.role != "door_station") return
        if (safeMode) {
            camera.encoder = null
            if (encoder.isRunning) encoder.stop()
            val previous = statusStore.snapshot().optJSONObject("avc_encode")
            if (previous?.optString("state") != "degraded" ||
                previous.optString("error") != "safe mode disables H.264") {
                statusStore.update("avc_encode", JSONObject()
                    .put("state", "degraded")
                    .put("certified", false)
                    .put("error", "safe mode disables H.264")
                    .put("fallback", "mjpeg"))
                lastEncoderSnapshot = VideoEncoder.Snapshot(
                    "degraded",
                    certified = false,
                    error = "safe mode disables H.264",
                )
                publishCapabilities()
            }
            return
        }
        if (legacy19 && (camera.frameWidth != AndroidCodecPolicy.api19.width ||
                camera.frameHeight != AndroidCodecPolicy.api19.height)) {
            camera.encoder = null
            if (encoder.isRunning) encoder.stop()
            val error = "Camera1 does not provide the required 480x360 commissioning mode"
            val previous = statusStore.snapshot().optJSONObject("avc_encode")
            if (previous?.optString("state") != "degraded" ||
                previous.optString("error") != error) {
                onEncoderStatus(VideoEncoder.Snapshot(
                    state = "degraded",
                    width = camera.frameWidth,
                    height = camera.frameHeight,
                    fps = AndroidCodecPolicy.api19.fps,
                    certified = false,
                    error = error,
                ))
            }
            return
        }
        val wanted = app.core.videoEncoderWanted()
        val newSubscriber = wanted && !lastEncoderWanted
        lastEncoderWanted = wanted
        val commissioning = commissioningRequired()
        if (!wanted && !commissioning) {
            encoderExhausted = false
            encoderRetryAtMs = 0L
            if (encoder.isRunning) {
                camera.encoder = null
                encoder.stop()
            }
            return
        }
        if (encoderExhausted || SystemClock.elapsedRealtime() < encoderRetryAtMs) return
        if (!encoder.isRunning) {
            val config = cameraConfig()
            val operatingPoint = operatingPoint()
            encoder.start(
                operatingPoint.fps,
                operatingPoint.bitrateKbps,
                !legacy19,
                !legacy19 &&
                    (config?.optBoolean("h264_software_fallback", false) ?: false),
            )
            camera.encoder = encoder
        } else if (encoder.hasTerminalFailure) {
            camera.encoder = null
            encoder.stop()
            if (!tryLowerResolution()) {
                encoderExhausted = true
                statusStore.update("avc_encode", JSONObject()
                    .put("state", "degraded")
                    .put("certified", false)
                    .put("error", "all safe codec/resolution candidates failed")
                    .put("fallback", "mjpeg"))
            }
        }
        if (newSubscriber && encoder.isRunning) encoder.requestKeyFrame()
    }

    private fun tryLowerResolution(): Boolean {
        val candidates = resolutionCandidates()
        while (resolutionIndex + 1 < candidates.size) {
            resolutionIndex++
            val previouslyTried = triedActualResolutions.toSet()
            restartCamera()
            ensureCamera()
            if (cameraStarted && currentActualResolution !in previouslyTried) return true
        }
        return false
    }

    private fun restartCamera() {
        camera.encoder = null
        encoder.stop()
        camera.stop()
        cameraStarted = false
        cameraRetryAtMs = 0L
        currentActualResolution = ""
    }

    private fun resolutionCandidates(): List<Pair<Int, Int>> {
        if (safeMode) return listOf(320 to 240)
        if (legacy19) return listOf(480 to 360)
        val configured = cameraConfig()?.optString("h264_resolution", "")?.let(::parseResolution)
        val tierDefault = 640 to 360
        return listOfNotNull(configured, tierDefault, 480 to 360, 320 to 240, 176 to 144).distinct()
    }

    private fun parseResolution(value: String): Pair<Int, Int>? {
        val split = value.lowercase().split('x')
        if (split.size != 2) return null
        val w = split[0].toIntOrNull() ?: return null
        val h = split[1].toIntOrNull() ?: return null
        return if (w in 160..1920 && h in 120..1080) w to h else null
    }

    private fun cameraConfig(): JSONObject? {
        val status = app.core.status()
        val nodeId = status?.optJSONObject("node")?.optString("id").orEmpty()
        if (nodeId.isEmpty()) return null
        return app.core.dig(app.core.config(), "devices.$nodeId.local.camera") as? JSONObject
    }

    private fun operatingPoint(): AvcOperatingPoint {
        val config = cameraConfig()
        return AndroidCodecPolicy.operatingPoint(
            Build.VERSION.SDK_INT,
            config?.optString("h264_resolution", "")?.let(::parseResolution),
            config?.takeIf { it.has("h264_fps") }?.optInt("h264_fps"),
            config?.takeIf { it.has("h264_bitrate_kbps") }?.optInt("h264_bitrate_kbps"),
        )
    }

    private fun commissioningRequired(): Boolean = legacy19 &&
        app.boot.role == "door_station" && !safeMode && !commissioningStore.hasCurrentMeasurement()

    private fun onEncoderStatus(value: VideoEncoder.Snapshot) {
        lastEncoderSnapshot = value
        val previous = statusStore.snapshot().optJSONObject("avc_encode")
        if (previous?.optString("state") == value.state &&
            previous.optString("codec") == value.codec &&
            previous.optString("error") == value.error) return
        statusStore.update("avc_encode", JSONObject()
            .put("state", value.state)
            .put("codec", value.codec)
            .put("input_mode", "byte_buffer")
            .put("color_format", value.colorFormat)
            .put("width", value.width)
            .put("height", value.height)
            .put("fps", value.fps)
            .put("certified", value.certified)
            .put("error", value.error)
            .put("degraded", value.state == "degraded" ||
                value.state.endsWith("_uncommissioned"))
            .put("fallback", if (value.state == "degraded" ||
                value.state.endsWith("_uncommissioned")) "mjpeg" else ""))
        if (legacy19) statusStore.update("avc_commissioning", JSONObject()
            .put("required", !commissioningStore.hasCurrentMeasurement())
            .put("trigger", if (commissioningStore.hasCurrentMeasurement())
                "measured_complete" else "install_or_upgrade")
            .put("codec", value.codec)
            .put("release_qualified", releaseQualified())
            .put("qualification_note",
                "physical-device Camera/SIP/thermal/8-hour qualification is still required"))
        handler.post { publishCapabilities() }
    }

    private fun applyHelperConfiguration() {
        kioskController.updateHelperMode(configuredHelperMode())
    }

    private fun refreshSafeMode() {
        val local = app.processRecoveryState()
        val helperSafe = kioskController.helperSafeMode
        val desired = local.safeMode || helperSafe
        val reason = when {
            local.safeMode && helperSafe -> "local_crash_loop_and_helper"
            local.safeMode -> "local_crash_loop"
            helperSafe -> "root_helper"
            else -> ""
        }
        if (desired != safeMode) {
            safeMode = desired
            safeModeReason = reason
            resolutionIndex = 0
            triedActualResolutions.clear()
            encoderExhausted = false
            if (isCoreReady) restartCamera()
            app.onSafeModeChanged(desired, reason)
            publishCapabilities()
        } else {
            safeModeReason = reason
        }
        publishRecoveryStatus()
    }

    private fun publishRecoveryStatus() {
        val local = app.processRecoveryState()
        val value = JSONObject()
            .put("generation", local.generation)
            .put("safe_mode", safeMode)
            .put("reason", safeModeReason)
            .put("local_safe_mode", local.safeMode)
            .put("helper_safe_mode", kioskController.helperSafeMode)
            .put("crashes_in_window", local.crashWallMs.size)
            .put("window_ms", RecoveryPolicy.WINDOW_MS)
            .put("restart_attempt", local.restartAttempt)
            .put("next_backoff_ms", local.restartBackoffMs)
            .put("last_exit_reason", local.lastExitReason)
        val serialized = value.toString()
        if (serialized == lastRecoveryStatusJson) return
        lastRecoveryStatusJson = serialized
        statusStore.update("process_recovery", value)
    }

    private fun publishRuntimeHealth(force: Boolean = false) {
        val elapsed = SystemClock.elapsedRealtime()
        if (!force && elapsed - lastRuntimeHeartbeatMs < RUNTIME_HEARTBEAT_MS) return
        lastRuntimeHeartbeatMs = elapsed
        val local = app.processRecoveryState()
        val snapshot = statusStore.snapshot()
        val helper = snapshot.optJSONObject("recovery_helper")
        val measured = helper?.optJSONObject("measured")
        val components = JSONObject()
            .put("core", if (isCoreReady) "running" else "stopped")
            .put("sip", if (isCoreReady) "available" else "stopped")
            .put("media", when {
                safeMode -> "degraded"
                lastEncoderSnapshot.state == "degraded" || decoderState == "degraded" ->
                    "degraded"
                lastEncoderSnapshot.state == "active" || decoderState == "active" -> "active"
                else -> "idle"
            })
        val health = JSONObject()
            .put("schema_version", 1)
            .put("generation", local.generation)
            .put("heartbeat_ms", System.currentTimeMillis().coerceAtLeast(0L))
            .put("last_exit_reason", CrashLoopStore.runtimeToken(local.lastExitReason))
            .put("safe_mode", safeMode)
            .put("components", components)
            .put("helper_mode", JSONObject.NULL)
            .put("helper_available", JSONObject.NULL)
        helper?.optString("effective")?.takeIf { it.isNotEmpty() }?.let {
            health.put("helper_mode", CrashLoopStore.runtimeToken(it))
        }
        if (measured?.has("helper_installed") == true)
            health.put("helper_available", measured.optBoolean("helper_installed"))
        statusStore.updateFields(health)
    }

    private fun heartbeatHelper() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastHelperHeartbeatMs < HELPER_HEARTBEAT_MS) return
        lastHelperHeartbeatMs = now
        kioskController.heartbeat()
    }

    private fun configuredHelperMode(): String? {
        val nodeId = app.core.status()?.optJSONObject("node")?.optString("id").orEmpty()
        if (nodeId.isEmpty()) return null
        val configured = app.core.dig(
            app.core.config(),
            "devices.$nodeId.local.recovery.helper_mode",
        ) ?: return null
        return if (configured is String) configured else INVALID_HELPER_MODE
    }

    private fun publishCapabilitiesIfDue() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastCapabilityPublishMs >= CAPABILITY_REFRESH_MS) publishCapabilities()
    }

    private fun publishCapabilities() {
        if (!isCoreReady) return
        lastCapabilityPublishMs = SystemClock.elapsedRealtime()
        publishDeviceAlertChannels()
        app.core.setCapabilities(AndroidRuntimeContracts.capabilities(
            app,
            lastEncoderSnapshot,
            decoderState,
            !safeMode && legacy19 &&
                commissioningStore.hasCurrentMeasurement(),
            safeMode,
            legacy19,
            releaseQualified(),
        ))
        captureContract()
    }

    private fun publishDeviceAlertChannels() {
        val channels = AndroidRuntimeContracts.deviceAlertChannels()
        val support = AndroidRuntimeContracts.deviceAlertChannelSupport(
            app.emergencyAlerts.notificationPermissionStatus(),
        )
        var snapshot = statusStore.snapshot()
        if (snapshot.optJSONArray("device_alert_channels")?.toString() != channels.toString()) {
            statusStore.update("device_alert_channels", channels)
            snapshot = statusStore.snapshot()
        }
        if (snapshot.optJSONObject("device_alert_channel_support")?.toString() !=
            support.toString()) {
            statusStore.update("device_alert_channel_support", support)
        }
    }

    private fun captureContract() {
        app.core.capabilities()?.let { contractStore.update("capabilities", it) }
    }

    private fun releaseQualified(): Boolean = !legacy19 ||
        (commissioningStore.hasCurrentMeasurement() &&
            releaseQualification?.matchesCurrentDevice(
                commissioningStore.currentCodecIdentities(),
            ) == true)

    companion object {
        private const val TAG = "doorbell-runtime"
        private const val CAMERA_RETRY_MS = 5_000L
        private const val MEMORY_CODEC_PAUSE_MS = 30_000L
        private const val HELPER_HEARTBEAT_MS = 5_000L
        private const val RUNTIME_HEARTBEAT_MS = 10_000L
        private const val CAPABILITY_REFRESH_MS = 15_000L
        private const val INVALID_HELPER_MODE = "invalid"
    }
}
