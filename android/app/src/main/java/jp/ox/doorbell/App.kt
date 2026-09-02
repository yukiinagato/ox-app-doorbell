// Owns Core across Activity lifetimes and forwards UI events to the foreground listener.
// Chime events can launch the visitor monitor independently of the current Activity.
package jp.ox.doorbell

import android.app.Application
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.io.File
import org.json.JSONObject

class App : Application(), DoorbellCore.Listener {

    lateinit var boot: BootConfig
        private set
    @Volatile
    var bootSetupRequired: Boolean = false
        private set
    val core: DoorbellCore by lazy(LazyThreadSafetyMode.NONE) { DoorbellCore(this) }
    lateinit var runtime: RuntimeSupervisor
        private set
    internal lateinit var emergencyAlerts: EmergencyAlertController
        private set
    internal lateinit var callFlow: CallFlowController
        private set
    private lateinit var processRecovery: ProcessRecovery
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    internal val pairingPersistence = PairingPersistenceGate()
    internal val uiStyleLkg: UiStyleLkgStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        UiStyleLkgStore(File(filesDir, "ui-style-lkg-v1.json"))
    }
    val coreOk: Boolean get() = ::runtime.isInitialized && runtime.isCoreReady

    @Volatile
    var safeMode: Boolean = false
        private set

    private val foregroundListeners = ForegroundListenerRegistry()

    /** Foreground Activity that receives Core UI events. */
    val activityListener: DoorbellCore.Listener?
        get() = foregroundListeners.current

    /** Called from Activity.onResume so a screen closing above never silences the one below. */
    fun bindForeground(listener: DoorbellCore.Listener) = foregroundListeners.bind(listener)

    /** Called from Activity.onPause and onDestroy. */
    fun unbindForeground(listener: DoorbellCore.Listener) = foregroundListeners.unbind(listener)

    @Volatile
    private var pairingDeferredForSession = false

    /**
     * The operator chose "set up later" on the onboarding screen. The main UI then keeps a
     * persistent banner instead of relaunching onboarding on every resume.
     */
    fun deferPairing() {
        pairingDeferredForSession = true
    }

    /** Tapping the banner or the maintenance menu asks for onboarding again. */
    fun resumePairingSetup() {
        pairingDeferredForSession = false
    }

    val pairingDeferred: Boolean get() = pairingDeferredForSession

    @Volatile
    var incomingActivity: IncomingActivity? = null

    @Volatile
    internal var emergencyActivity: EmergencyActivity? = null

    // Metadata for the most recent visitor call shown by the incoming UI.
    @Volatile
    var lastPressDoor = ""
        private set
    @Volatile
    var lastPurpose = ""
        private set
    @Volatile
    var lastVisitorLang = ""
        private set
    @Volatile
    var lastCallId = ""
        private set
    @Volatile
    var lastStageRevision = 0
        private set
    @Volatile
    var lastCallExpiresAtMs = 0L
        private set
    private val chimeGate = ChimeGate()
    private val manualSipLifecycle = ManualSipCallLifecycle()
    private val recoveryLock = Any()
    private var pendingRecovery: PendingRecovery? = null
    private val recoveryTimeout = Runnable { failPendingRecovery() }

    override fun onCreate() {
        super.onCreate()
        boot = BootConfig.load(File(filesDir, "boot.json"))
        bootSetupRequired = boot.setupRequired
        pairingPersistence.initialize(BootConfig.hasSecureMeshReference(boot.rawJson))
        callFlow = CallFlowController(
            gateway = object : CallFlowGateway {
                override fun press(door: String, purpose: String): String? =
                    core.pressV2(door, purpose)

                override fun selectPurpose(
                    door: String,
                    callId: String,
                    purpose: String,
                ): Boolean = core.selectPurposeV2(door, callId, purpose)

                override fun cancel(door: String, callId: String, reason: String): Boolean =
                    core.cancelCallV2(door, callId, reason)

                override fun reportRecovery(callId: String, restored: Boolean) =
                    core.reportCallRecovery(callId, restored)

                override fun hangup() = core.sipHangup()
            },
            persistence = OriginatedCallFileStore(File(filesDir, "originated-call-v2.bin")),
        )
        migrateLegacyPairingSecret()
        core.listener = this
        emergencyAlerts = EmergencyAlertController(this)
        processRecovery = ProcessRecovery(this).also { it.install() }
        safeMode = processRecovery.snapshot().safeMode
        runtime = RuntimeSupervisor(this)
        DeviceOwnerPolicies.apply(this)
        if (!bootSetupRequired) {
            startResidentService()
            emergencyAlerts.restore()
        }
    }

    /** Start the resident foreground service, including from the boot receiver. */
    fun startResidentService() {
        if (bootSetupRequired) return
        try {
            val i = Intent(this, DoorbellService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ServiceStartApi26.start(this, i) else startService(i)
        } catch (_: Exception) { /* The next foreground transition retries a restricted start. */ }
    }

    /** Completes the local identity gate before this device is allowed to join or originate calls. */
    fun completeBootSetup(name: String, role: String, door: String): Boolean {
        val persisted = BootConfig.persistSetup(File(filesDir, "boot.json"), name, role, door)
            ?: return false
        boot = persisted
        bootSetupRequired = false
        pairingPersistence.initialize(BootConfig.hasSecureMeshReference(boot.rawJson))
        startResidentService()
        return true
    }

    // Core callbacks run on Core-owned threads.

    override fun onUiEvent(ev: JSONObject) {
        val eventType = ev.optString("t")
        if (eventType == "chime" && !acceptChimeV2(ev)) return
        if (eventType == "call_recovery_required") {
            handleCallRecoveryRequest(ev)
            return
        }
        if (eventType == "emergency") emergencyAlerts.onCoreEvent(ev)
        if (eventType == "pairing_persistence_error") pairingPersistence.recordFailure()
        if (eventType == "pairing_state" &&
            ev.optString("state") == PairingModel.UNPAIRED) onClusterLeft()
        // A revocation is a factory reset of this device's cluster identity and its setup.
        if (eventType == "pairing_revoked") factoryResetClusterIdentity("revoked")
        val forwarded = if (eventType == "paired") {
            val persisted = onPaired(ev)
            JSONObject(ev.toString()).apply {
                put("secure_persisted", persisted)
            }
        } else ev
        if (eventType == "config_changed" && ::runtime.isInitialized)
            runtime.onConfigChanged()
        if (eventType == "event") handleLifecycleEvent(ev)

        // IncomingActivity stays independent from the main activity listener, so it receives
        // the local SIP and reply lifecycle explicitly.
        when (eventType) {
            "state" -> {
                val state = ev.optString("state")
                handleManualSipLifecycle(state)
                incomingActivity?.onSipState(state)
            }
            "reply" -> {
                callFlow.observeResolvedDoor(ev.optString("door"))
                incomingActivity?.onReply(ev.optString("door"))
            }
        }
        activityListener?.onUiEvent(forwarded)
        // Door stations retain their visitor UI; only indoor profiles open the incoming monitor.
        if (eventType == "chime" && boot.role != "door_station") {
            IncomingActivity.launch(this, lastPressDoor,
                                    lastPurpose, lastVisitorLang, lastCallId,
                                    lastStageRevision, lastCallExpiresAtMs)
        }
    }

    private fun handleLifecycleEvent(ev: JSONObject) {
        val type = ev.optString("type")
        val door = ev.optString("door")
        val callId = ev.optString("call_id")
        val stage = ev.optInt("stage_revision", 0)
        val expiresAtMs = ev.optLong("expires_at_ms", 0L)
        when (type) {
            "press" -> {
                lastPressDoor = door
                lastPurpose = ev.optString("purpose")
                lastVisitorLang = ev.optString("visitor_lang")
                lastCallId = callId
                lastStageRevision = stage
                lastCallExpiresAtMs = expiresAtMs
                callFlow.observePress(door, callId, stage, expiresAtMs, lastPurpose)
            }
            "purpose_selected" -> {
                val supersededAnswer =
                    manualSipLifecycle.observeWinningPurpose(callId, stage)
                if (lastPressDoor.isEmpty() || door == lastPressDoor) {
                    lastPressDoor = door
                    lastPurpose = ev.optString("purpose")
                    ev.optString("visitor_lang").takeIf { it.isNotEmpty() }
                        ?.let { lastVisitorLang = it }
                    callId.takeIf { it.isNotEmpty() }?.let { lastCallId = it }
                    lastStageRevision = stage
                    lastCallExpiresAtMs = expiresAtMs
                }
                callFlow.observePurpose(door, callId, stage, expiresAtMs, ev.optString("purpose"))
                incomingActivity?.onPurposeSelected(
                    door,
                    callId,
                    stage,
                    expiresAtMs,
                    ev.optString("purpose"),
                    ev.optString("visitor_lang"),
                )
                if (supersededAnswer != ManualSipPurposeResult.NONE) {
                    mainHandler.post { core.sipHangup() }
                }
            }
            "call_cancelled" -> {
                manualSipLifecycle.clear(callId)
                callFlow.observeCancellation(callId, stage)
                clearPendingRecovery(callId)
                clearLastCall(callId)
                incomingActivity?.onCallCancelled(door, callId, stage)
            }
            "call_answered" -> {
                val dialogOwner = ev.optString("dialog_owner")
                    .ifEmpty { ev.optString("device") }
                when (manualSipLifecycle.observeAnsweredClaim(callId, dialogOwner)) {
                    ManualSipClaimResult.LOST_PENDING,
                    ManualSipClaimResult.LOST_ESTABLISHED -> stopLosingManualSipLeg(callId)
                    ManualSipClaimResult.NONE,
                    ManualSipClaimResult.OWNED -> Unit
                }
                callFlow.observeAnswered(callId, stage, expiresAtMs)
                incomingActivity?.onCallAnswered(door, callId, stage)
            }
            "call_ended" -> {
                manualSipLifecycle.clear(callId)
                callFlow.observeEnded(callId, stage)
                clearPendingRecovery(callId)
                clearLastCall(callId)
                incomingActivity?.onCallEnded(door, callId, stage)
            }
            "reply" -> {
                callFlow.observeResolvedDoor(door)
                incomingActivity?.onReply(door)
            }
        }
    }

    private fun clearLastCall(callId: String) {
        if (callId.isEmpty() || callId != lastCallId) return
        lastCallId = ""
        lastStageRevision = 0
        lastCallExpiresAtMs = 0L
    }

    /** Bind only the bidirectional leg started by the resident's Answer action. */
    internal fun bindManualSipAnswer(
        door: String,
        callId: String,
        stageRevision: Int,
    ): Boolean {
        val current = currentVisitorCall() ?: return false
        if (door != current.door || callId != current.callId ||
            stageRevision < 0 || stageRevision > current.stageRevision) return false
        val localNodeId = core.status()?.optJSONObject("node")?.optString("id").orEmpty()
        return manualSipLifecycle.bind(current, localNodeId)
    }

    /** Activity teardown drops an unconfirmed INVITE but preserves an established leg until idle. */
    internal fun abandonPendingManualSipAnswer(callId: String) {
        manualSipLifecycle.abandonPending(callId)
    }

    private fun currentVisitorCall(): ManualSipCallIdentity? {
        val door = lastPressDoor
        val callId = lastCallId
        val revision = lastStageRevision
        return if (door.isNotBlank() && callId.isNotBlank() && revision >= 0)
            ManualSipCallIdentity(door, callId, revision) else null
    }

    private fun handleManualSipLifecycle(state: String) {
        val report = manualSipLifecycle.onSipState(state, currentVisitorCall()) ?: return
        mainHandler.post {
            if (!manualSipLifecycle.isCurrent(report)) return@post
            val current = currentVisitorCall()
            if (current == null || current.door != report.identity.door ||
                current.callId != report.identity.callId ||
                current.stageRevision < report.identity.stageRevision) {
                manualSipLifecycle.clear(report.identity.callId)
                return@post
            }
            val accepted = when (report.kind) {
                ManualSipCallReportKind.ANSWERED -> core.reportCallAnsweredV2(
                    current.door,
                    current.callId,
                    current.stageRevision,
                )
                ManualSipCallReportKind.ENDED -> core.reportCallEndedV2(
                    current.door,
                    current.callId,
                    current.stageRevision,
                    report.reason.ifEmpty { "sip_ended" },
                )
            }
            if (!accepted) {
                manualSipLifecycle.clear(report.identity.callId)
                if (report.kind == ManualSipCallReportKind.ANSWERED) {
                    core.sipHangup()
                    incomingActivity?.onManualSipClaimLost(report.identity.callId)
                }
                Log.w(TAG, "manual SIP lifecycle report rejected as stale: ${report.kind}")
            } else {
                manualSipLifecycle.complete(report)
            }
        }
    }

    private fun stopLosingManualSipLeg(callId: String) {
        mainHandler.post {
            core.sipHangup()
            incomingActivity?.onManualSipClaimLost(callId)
        }
    }

    private fun handleCallRecoveryRequest(ev: JSONObject) {
        val callId = ev.optString("call_id")
        val door = ev.optString("door")
        val candidate = callFlow.recoveryCandidate(callId, door)
        if (candidate == null) {
            mainHandler.post { callFlow.reportRecovery(callId, false) }
            return
        }
        if (ev.optString("state") == "in_call" && candidate.phase != CallUiPhase.ESTABLISHED)
            callFlow.markEstablished()
        val deadlineMs = ev.optLong("deadline_ms", RECOVERY_DEADLINE_MS)
            .coerceIn(MIN_RECOVERY_DEADLINE_MS, RECOVERY_DEADLINE_MS)
        val pending = PendingRecovery(
            callId = callId,
            deadlineAtElapsedMs = SystemClock.elapsedRealtime() + deadlineMs,
        )
        synchronized(recoveryLock) { pendingRecovery = pending }
        mainHandler.removeCallbacks(recoveryTimeout)
        mainHandler.postDelayed(recoveryTimeout, (deadlineMs - RECOVERY_REPORT_MARGIN_MS)
            .coerceAtLeast(0L))
        dispatchPendingRecovery()
    }

    private fun dispatchPendingRecovery() {
        if (!coreOk) return
        val pending = synchronized(recoveryLock) { pendingRecovery } ?: return
        mainHandler.post {
            val current = synchronized(recoveryLock) { pendingRecovery }
            if (current?.callId != pending.callId) return@post
            try {
                startActivity(Intent(this, MainActivity::class.java)
                    .setAction(ACTION_RESTORE_CALL)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    .putExtra(EXTRA_RECOVERY_CALL_ID, pending.callId))
            } catch (e: Exception) {
                Log.e(TAG, "failed to launch call recovery UI", e)
            }
        }
    }

    internal fun completeCallRecovery(callId: String, restored: Boolean): Boolean {
        val pending = synchronized(recoveryLock) {
            val value = pendingRecovery
            if (value?.callId != callId ||
                SystemClock.elapsedRealtime() >= value.deadlineAtElapsedMs) null
            else {
                pendingRecovery = null
                value
            }
        } ?: return false
        mainHandler.removeCallbacks(recoveryTimeout)
        callFlow.reportRecovery(pending.callId, restored)
        return true
    }

    private fun failPendingRecovery() {
        val pending = synchronized(recoveryLock) {
            val value = pendingRecovery
            pendingRecovery = null
            value
        } ?: return
        callFlow.reportRecovery(pending.callId, false)
    }

    private fun clearPendingRecovery(callId: String) {
        if (callId.isEmpty()) return
        val cleared = synchronized(recoveryLock) {
            if (pendingRecovery?.callId != callId) false
            else {
                pendingRecovery = null
                true
            }
        }
        if (cleared) mainHandler.removeCallbacks(recoveryTimeout)
    }

    private fun acceptChimeV2(ev: JSONObject): Boolean {
        val callId = ev.optString("call_id")
        val stage = ev.optInt("stage_revision", 0)
        val expires = ev.optLong("expires_at_ms", 0L)
        if (!chimeGate.accept(ev.optInt("schema_version"), callId, stage, expires,
                              System.currentTimeMillis())) return false
        val supersededAnswer = manualSipLifecycle.observeWinningPurpose(callId, stage)
        val door = ev.optString("door")
        val same = door.isEmpty() || lastPressDoor.isEmpty() || door == lastPressDoor
        lastPressDoor = door
        lastCallId = callId
        lastStageRevision = stage
        lastCallExpiresAtMs = expires
        lastPurpose = ev.optString("purpose", if (same) lastPurpose else "")
        lastVisitorLang = ev.optString("visitor_lang", if (same) lastVisitorLang else "")
        if (supersededAnswer != ManualSipPurposeResult.NONE) {
            // Queue the activity demotion before the losing SIP leg can publish Idle.
            incomingActivity?.onPurposeSelected(
                door, callId, stage, expires, lastPurpose, lastVisitorLang,
            )
            mainHandler.post { core.sipHangup() }
        }
        return true
    }

    private fun onPaired(ev: JSONObject): Boolean {
        val secretRef = ev.optString("psk_ref")
        val seeds = ArrayList<String>()
        ev.optJSONArray("seeds")?.let { arr ->
            for (i in 0 until arr.length()) arr.optString(i).takeIf { it.isNotEmpty() }
                ?.let { seeds.add(it) }
        }
        val js = if (secretRef == PairingPersistenceGate.MESH_PSK_REFERENCE)
            BootConfig.persistPskReference(File(filesDir, "boot.json"), seeds) else null
        val persisted = pairingPersistence.recordPaired(secretRef, js != null)
        if (persisted) {
            boot = BootConfig.load(File(filesDir, "boot.json"))
            Log.i(TAG, "paired: secure PSK reference and seeds persisted")
        } else {
            Log.e(TAG, "paired: failed to persist the secure mesh PSK reference")
        }
        android.os.Handler(mainLooper).post {
            android.widget.Toast.makeText(
                this,
                getString(if (persisted) R.string.pair_joined else R.string.pair_persist_error_title),
                android.widget.Toast.LENGTH_LONG,
            ).show()
        }
        return persisted
    }

    /**
     * Core reported that this device holds no cluster key any more, either because the
     * administrator revoked it or because the maintenance menu cleared the pairing. Drop the
     * boot reference so the shell fails closed and reopens onboarding.
     */
    internal fun onClusterLeft() {
        // A failed join on a device that never had a key also reports "unpaired"; that must not
        // discard the seed peers this device was configured with.
        if (!BootConfig.hasSecureMeshReference(boot.rawJson)) return
        pairingPersistence.recordFailure()
        val rewritten = BootConfig.clearPskReference(File(filesDir, "boot.json"))
        if (rewritten != null) {
            boot = BootConfig.load(File(filesDir, "boot.json"))
            Log.i(TAG, "cluster left: cleared the secure PSK reference and seeds")
        }
        pairingPersistence.initialize(BootConfig.hasSecureMeshReference(boot.rawJson))
    }

    /**
     * Wipe everything this device holds about the cluster and about its own role, then reopen
     * first-run setup (spec §5.4). Used when the administrator revokes this device and when the
     * operator confirms 「クラスタから外す」 on the device itself. Safe to call more than once.
     */
    internal fun factoryResetClusterIdentity(reason: String) {
        pairingPersistence.recordFailure()
        try { core.unpair() } catch (_: Exception) { }
        // The pre-shared key must not survive; an orphaned entry would be readable material.
        try { core.deletePlatformSecret("mesh.psk") } catch (_: Exception) { }
        val bootFile = File(filesDir, "boot.json")
        if (BootConfig.factoryReset(bootFile) == null) {
            Log.e(TAG, "factory reset ($reason): boot.json could not be rewritten")
            return
        }
        boot = BootConfig.load(bootFile)
        bootSetupRequired = boot.setupRequired
        pairingPersistence.initialize(BootConfig.hasSecureMeshReference(boot.rawJson))
        resumePairingSetup()
        Log.i(TAG, "factory reset ($reason): cleared the cluster key, seeds, and local identity")
        mainHandler.post {
            try {
                startActivity(
                    Intent(this, BootSetupActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TASK),
                )
            } catch (_: Exception) {
                // A background start may be denied; the next resume reopens setup anyway.
            }
        }
    }

    /** True once core reports "ready" and the shell has its own durable secure reference. */
    internal fun pairingReady(): Boolean {
        if (!coreOk) return false
        val pairing = core.pairingInfo() ?: return false
        if (PairingModel.state(pairing) != PairingModel.READY) return false
        return pairingPersistence.canMarkReady(
            pairing.optBoolean("paired"),
            pairing.optBoolean("persistence_ready"),
            BootConfig.hasSecureMeshReference(boot.rawJson),
        )
    }

    private fun migrateLegacyPairingSecret() {
        val legacy = try { JSONObject(boot.rawJson).optString("psk_hex") }
            catch (_: Exception) { "" }
        if (!legacy.matches(Regex("^[0-9A-Fa-f]{64}$"))) return
        pairingPersistence.recordFailure()
        if (!core.putPlatformSecret("mesh.psk", legacy)) {
            Log.e(TAG, "legacy psk_hex migration to secure storage failed")
            return
        }
        val updated = BootConfig.persistPskReference(File(filesDir, "boot.json"), emptyList())
        if (updated != null) {
            boot = BootConfig.load(File(filesDir, "boot.json"))
            pairingPersistence.initialize(BootConfig.hasSecureMeshReference(boot.rawJson))
            Log.i(TAG, "migrated legacy psk_hex to secret:mesh.psk")
        } else {
            Log.e(TAG, "secure PSK stored but boot reference rewrite failed")
        }
    }

    override fun onTts(text: String, lang: String) {
        activityListener?.onTts(text, lang)
    }

    override fun onTerminate() {
        if (::processRecovery.isInitialized) processRecovery.endSession("application_terminate")
        if (::runtime.isInitialized) runtime.stop("application_terminate")
        super.onTerminate()
    }

    override fun onTrimMemory(level: Int) {
        if (::runtime.isInitialized) runtime.trimMemory(level)
        incomingActivity?.onMemoryPressure()
        activityListener?.onUiEvent(JSONObject().put("t", "memory_pressure").put("level", level))
        super.onTrimMemory(level)
    }

    override fun onLowMemory() {
        if (::runtime.isInitialized)
            runtime.trimMemory(android.content.ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
        super.onLowMemory()
    }

    internal fun onRuntimeAvailability(ready: Boolean, reason: String) {
        activityListener?.onUiEvent(JSONObject()
            .put("t", "runtime")
            .put("state", if (ready) "ready" else "offline")
            .put("reason", reason))
        if (ready) dispatchPendingRecovery()
    }

    internal fun reportEmergencyPresentation(value: JSONObject) {
        if (::runtime.isInitialized) runtime.reportEmergencyPresentation(value)
    }

    internal fun commitEmergency(active: Boolean): Boolean {
        val committed = core.emergency(active)
        if (!committed) {
            Log.e(TAG, "SOS state was not durably committed")
            activityListener?.onUiEvent(JSONObject()
                .put("t", "emergency_commit_failed")
                .put("active", active))
        }
        return committed
    }

    internal fun reportUiStyleApplication(value: UiStyleApplyReport) {
        if (::runtime.isInitialized) runtime.reportUiStyleApplication(value)
    }

    internal fun processRecoveryState(): ProcessRecoveryState =
        if (::processRecovery.isInitialized) processRecovery.snapshot() else ProcessRecoveryState()

    internal fun recoveryStartupDelayMs(): Long =
        if (::processRecovery.isInitialized) processRecovery.startupDelayMs() else 0L

    internal fun onProcessRecoveryChanged() {
        if (::runtime.isInitialized) runtime.onRecoveryPolicyChanged()
    }

    internal fun onSafeModeChanged(active: Boolean, reason: String) {
        safeMode = active
        val event = JSONObject()
            .put("t", "safe_mode")
            .put("active", active)
            .put("reason", reason)
        activityListener?.onUiEvent(event)
        incomingActivity?.onSafeModeChanged(active)
        emergencyActivity?.let { activity ->
            emergencyAlerts.current()?.let(activity::renderPresentation)
        }
    }

    internal fun onTaskRemoved() {
        if (::processRecovery.isInitialized) processRecovery.onTaskRemoved()
    }

    companion object {
        private const val TAG = "doorbell-app"
        internal const val ACTION_RESTORE_CALL = "jp.ox.doorbell.action.RESTORE_CALL"
        internal const val EXTRA_RECOVERY_CALL_ID = "recovery_call_id"
        private const val MIN_RECOVERY_DEADLINE_MS = 1_000L
        private const val RECOVERY_DEADLINE_MS = 10_000L
        private const val RECOVERY_REPORT_MARGIN_MS = 750L
    }

    private data class PendingRecovery(
        val callId: String,
        val deadlineAtElapsedMs: Long,
    )
}
