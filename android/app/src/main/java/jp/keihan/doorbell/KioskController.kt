package jp.keihan.doorbell

import android.app.Activity
import android.content.Context
import android.os.Build
import org.json.JSONObject

class KioskController(
    private val context: Context,
    private val boot: BootConfig,
    private val helper: RootKeepaliveClient,
    private val statusStore: RuntimeStatusStore,
) {
    @Volatile
    private var effectiveMode = if (boot.kiosk) "pending_activity" else "disabled"
    @Volatile
    private var rawHelperMode: String? = null
    @Volatile
    private var appliedHelperMode: String? = null
    private val nativeHealthTracker = NativeKioskHealthTracker(
        if (nativeKioskCandidate() && NativeLockTaskApi21.isAvailable(context))
            NativeKioskHealth.UNKNOWN else NativeKioskHealth.UNAVAILABLE,
    )

    private val nativeHealth: NativeKioskHealth
        get() = nativeHealthTracker.health

    @Volatile
    var helperSafeMode: Boolean = false
        private set

    @Synchronized
    fun updateHelperMode(rawMode: String?) {
        rawHelperMode = rawMode
        reconcileHelper(sendHeartbeat = false)
    }

    @Synchronized
    fun enter(activity: Activity) {
        if (!boot.kiosk) {
            nativeHealthTracker.unavailable()
            publishKiosk("disabled", reconcileHelper(sendHeartbeat = false))
            return
        }
        if (nativeKioskCandidate() && NativeLockTaskApi21.isAvailable(context)) {
            if (nativeHealthTracker.record(NativeLockTaskApi21.tryEnter(activity)) ==
                NativeKioskHealth.HEALTHY) {
                publishKiosk("native", reconcileHelper(sendHeartbeat = false))
                return
            }
        } else {
            nativeHealthTracker.unavailable()
        }
        val state = reconcileHelper(sendHeartbeat = false)
        val decision = HelperModePolicy.decide(rawHelperMode, state.installed, nativeHealth)
        val effective = when {
            helperEffective(decision, state) == "helper" -> "root_helper"
            decision.configured == "off" -> "home_only"
            else -> "home_only_degraded"
        }
        publishKiosk(effective, state)
    }

    @Synchronized
    fun leaveForMaintenance(activity: Activity) {
        val measured = helper.status()
        val helperState = if (measured.installed && measured.enabled)
            helper.pauseLease(MAINTENANCE_SECONDS) else measured
        if (Build.VERSION.SDK_INT >= 21) NativeLockTaskApi21.leave(activity)
        publishRecovery(helperState, "maintenance")
        publishKiosk("maintenance", helperState)
    }

    @Synchronized
    fun heartbeat() {
        measureNativeKioskHealth()
        reconcileHelper(sendHeartbeat = true)
    }

    private fun measureNativeKioskHealth() {
        if (!nativeKioskCandidate() || !NativeLockTaskApi21.isAvailable(context)) {
            nativeHealthTracker.unavailable()
            return
        }
        nativeHealthTracker.record(NativeLockTaskApi21.isActive(context))
    }

    private fun reconcileHelper(sendHeartbeat: Boolean): RootKeepaliveClient.Status {
        var state = helper.status()
        if (!state.installed) appliedHelperMode = null
        var decision = HelperModePolicy.decide(rawHelperMode, state.installed, nativeHealth)
        if (state.installed && appliedHelperMode != decision.configured) {
            state = helper.setMode(decision.configured)
            appliedHelperMode = if (state.error.isEmpty()) decision.configured else null
            decision = HelperModePolicy.decide(rawHelperMode, state.installed, nativeHealth)
        }
        if (decision.shouldUseHelper) {
            if (!state.enabled) state = helper.enable()
            if (state.enabled && (sendHeartbeat || !state.running)) state = helper.kick()
        } else if (state.enabled) {
            state = helper.disable()
        }
        publishRecovery(state)
        publishKiosk(effectiveMode, state)
        return state
    }

    private fun publishRecovery(
        helperState: RootKeepaliveClient.Status,
        effectiveOverride: String? = null,
    ) {
        helperSafeMode = helperState.safeMode
        val decision = HelperModePolicy.decide(rawHelperMode, helperState.installed, nativeHealth)
        statusStore.update("recovery_helper", JSONObject()
            .put("configured", decision.configured)
            .put("effective", effectiveOverride ?: helperEffective(decision, helperState))
            .put("measured", JSONObject()
                .put("config_valid", decision.configValid)
                .put("native_kiosk_api_available", Build.VERSION.SDK_INT >= 21)
                .put("native_kiosk_health", nativeHealth.wireValue)
                .put("native_kiosk_consecutive_failures",
                     nativeHealthTracker.consecutiveFailures)
                .put("helper_installed", helperState.installed)
                .put("helper_enabled", helperState.enabled)
                .put("helper_running", helperState.running)
                .put("helper_version", helperState.version)
                .put("helper_safe_mode", helperState.safeMode)
                .put("helper_error", helperState.error)))
    }

    private fun helperEffective(
        decision: HelperModeDecision,
        helperState: RootKeepaliveClient.Status,
    ): String = when {
        decision.shouldUseHelper && !helperState.installed -> "helper_unavailable"
        decision.shouldUseHelper &&
            (!helperState.enabled || !helperState.running || helperState.error.isNotEmpty()) ->
            "helper_degraded"
        decision.shouldUseHelper -> "helper"
        helperState.enabled -> "policy_mismatch"
        else -> decision.targetEffective
    }

    private fun publishKiosk(effective: String, helperState: RootKeepaliveClient.Status) {
        effectiveMode = effective
        statusStore.update("kiosk", JSONObject()
            .put("requested", boot.kioskMode)
            .put("enabled", boot.kiosk)
            .put("effective", effective)
            .put("native_lock_task_available", Build.VERSION.SDK_INT >= 21)
            .put("helper_installed", helperState.installed)
            .put("helper_enabled", helperState.enabled)
            .put("helper_running", helperState.running)
            .put("helper_version", helperState.version)
            .put("helper_safe_mode", helperState.safeMode)
            .put("helper_error", helperState.error))
    }

    private fun nativeKioskCandidate(): Boolean = boot.kiosk && Build.VERSION.SDK_INT >= 21 &&
        boot.kioskMode in listOf("auto", "native")

    companion object {
        private const val MAINTENANCE_SECONDS = 600
    }
}
