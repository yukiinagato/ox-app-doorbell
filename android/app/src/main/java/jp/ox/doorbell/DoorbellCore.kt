// Kotlin wrapper for libdoorbell.so. Native callbacks arrive on Core-owned threads; listeners
// must marshal UI work to the main looper.
package jp.ox.doorbell

import android.content.Context
import org.json.JSONObject

class DoorbellCore(context: Context) {
    private val secureStore = AndroidSecureStore(context)
    private val deviceInfo = AndroidDeviceInfo(context)
    val secureStoreAvailable: Boolean = secureStore.selfTest()

    interface Listener {
        /** Versioned JSON UI event from a Core-owned thread. */
        fun onUiEvent(ev: JSONObject)
        /** TTS request for a quick reply, delivered on a Core-owned thread. */
        fun onTts(text: String, lang: String)
    }

    @Volatile
    var listener: Listener? = null

    @Volatile
    private var handle: Long = 0

    val isCreated: Boolean get() = handle != 0L

    /** Create and start Core after verifying the ABI and real SIP backend. */
    @Synchronized
    fun start(dataDir: String, bootJson: String): Boolean {
        if (handle != 0L) return true
        val backend = backend()
        if (backend.optInt("platform_abi") != 2 || backend.optString("sip") != "pjsip")
            return false
        handle = nativeCreate(dataDir, bootJson)
        if (handle == 0L) return false
        nativeSetUiCallback(handle, true)
        if (nativeStart(handle) != 0) {
            destroy()
            return false
        }
        return true
    }

    @Synchronized
    fun destroy() {
        if (handle == 0L) return
        nativeSetUiCallback(handle, false)
        nativeStop(handle)
        nativeDestroy(handle)
        handle = 0
    }

    fun press(doorId: String) {
        if (handle != 0L) nativePress(handle, doorId)
    }

    /** Legacy press API carrying a configured visit-purpose identifier. */
    fun pressPurpose(doorId: String, purpose: String) {
        if (handle != 0L) nativePressPurpose(handle, doorId, purpose)
    }

    /** Legacy purpose-selection API retained for one compatibility cycle. */
    fun selectPurpose(doorId: String, purpose: String) {
        if (handle != 0L) nativeSelectPurpose(handle, doorId, purpose)
    }

    fun cancelCall(doorId: String) {
        if (handle != 0L) nativeCancelCall(handle, doorId)
    }

    fun pressV2(doorId: String, purpose: String = ""): String? {
        val value = if (handle != 0L) nativePressV2(handle, doorId, purpose) else null
        return value?.takeIf { it.isNotEmpty() }
    }

    fun selectPurposeV2(doorId: String, callId: String, purpose: String): Boolean =
        handle != 0L && nativeSelectPurposeV2(handle, doorId, callId, purpose) == 0

    fun cancelCallV2(doorId: String, callId: String, reason: String): Boolean =
        handle != 0L && nativeCancelCallV2(handle, doorId, callId, reason) == 0

    fun reportCallAnsweredV2(doorId: String, callId: String, stageRevision: Int): Boolean =
        handle != 0L &&
            nativeReportCallAnsweredV2(handle, doorId, callId, stageRevision) == 0

    fun reportCallEndedV2(
        doorId: String,
        callId: String,
        stageRevision: Int,
        reason: String,
    ): Boolean = handle != 0L &&
        nativeReportCallEndedV2(handle, doorId, callId, stageRevision, reason) == 0

    fun reportCallRecovery(callId: String, restored: Boolean) {
        if (handle != 0L) nativeReportCallRecovery(handle, callId, restored)
    }

    fun emergency(active: Boolean): Boolean =
        handle != 0L && nativeEmergencyV2(handle, active)

    /** Set the replicated visitor language for a door. */
    fun setVisitorLang(door: String, lang: String) {
        if (handle != 0L) nativeSetVisitorLang(handle, door, lang)
    }

    fun status(): JSONObject? = parse(if (handle != 0L) nativeStatusJson(handle) else null)

    /**
     * Render a wall-clock instant in the cluster time zone with core's NTP correction applied.
     * Pass zero for "now". Every clock in the shell goes through this rather than the OS clock.
     */
    fun localTime(wallMs: Long = 0L): JSONObject? =
        parse(if (handle != 0L) nativeLocalTimeJson(handle, wallMs) else null)

    /** Start one immediate SNTP round; false when NTP is off or core is not started. */
    fun timeSyncNow(): Boolean = handle != 0L && nativeTimeSyncNow(handle) == 1

    /** Effective call/sos/idle volumes for one device; empty id means this node. */
    fun audio(deviceId: String = ""): JSONObject? =
        parse(if (handle != 0L) nativeAudioJson(handle, deviceId) else null)

    /**
     * Publish a replicated announcement. expiresMs of zero means until cleared, and a door of
     * [GLOBAL_DOOR] writes the cluster-wide announcement at notice.global, which a door-specific
     * value always overrides.
     */
    fun setDoorNotice(door: String, text: String, expiresMs: Long): Boolean =
        handle != 0L && door.isNotEmpty() &&
            nativeSetDoorNotice(handle, door, text, expiresMs) == 0

    fun clearDoorNotice(door: String): Boolean =
        handle != 0L && door.isNotEmpty() && nativeClearDoorNotice(handle, door) == 0

    /**
     * Trigger the configured unlock action for one door. Returns core's result: zero when the
     * action was queued and [DoorUnlocks.NOT_CONFIGURED] when nothing is configured anywhere.
     */
    fun openDoor(door: String): Int =
        if (handle != 0L && door.isNotEmpty()) nativeOpenDoor(handle, door) else -1

    /**
     * Call history newest first. sinceMs is an inclusive lower bound and zero is the whole log;
     * beforeMs is an exclusive upper bound used to page backwards, and zero means "from now".
     * Falls back to the v1 entry point, which has no upper bound, on a core without v2.
     */
    fun callLog(sinceMs: Long = 0L, beforeMs: Long = 0L, limit: Int = 50): JSONObject? {
        if (handle == 0L) return null
        if (exports.callLogV2)
            parse(nativeCallLogJsonV2(handle, sinceMs, beforeMs, limit))?.let { return it }
        return parse(nativeCallLogJson(handle, sinceMs, limit))
    }

    /** Mute or unmute the microphone on the active SIP leg. False when core cannot do it. */
    fun sipSetMicMuted(muted: Boolean): Boolean =
        handle != 0L && exports.micMute && nativeSipSetMicMuted(handle, muted) == 0

    /** Move the device-local seen watermark; an empty hlc marks everything as seen. */
    fun callLogMarkSeen(upToHlc: String = ""): Boolean =
        handle != 0L && nativeCallLogMarkSeen(handle, upToHlc) == 0

    /** Diagnostic snapshot for the maintenance information screen. */
    fun debugInfo(): JSONObject? = parse(if (handle != 0L) nativeDebugJson(handle) else null)

    fun config(): JSONObject? = parse(if (handle != 0L) nativeConfigJson(handle) else null)

    fun capabilities(): JSONObject? =
        parse(if (handle != 0L) nativeCapabilitiesJson(handle) else null)

    fun backend(): JSONObject = parse(nativeBackendJson()) ?: JSONObject()

    /** Which of the optional core entry points this build actually links against (§5.5). */
    internal val exports: CoreExports by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        CoreExports.parse(parse(nativeCoreExportsJson()))
    }

    /**
     * Write one configuration key through core, using the same validation the web admin does.
     * Returns null when this core has no configuration-write export and the caller must fall back
     * to the loopback administration API.
     */
    fun setConfigJson(key: String, valueJson: String): Int? {
        if (handle == 0L || !exports.configWrite) return null
        return nativeSetConfigJson(handle, key, valueJson)
    }

    /** Readability warnings produced by the most recent single-key write; never null-safe. */
    fun lastWriteWarnings(): org.json.JSONArray? {
        if (handle == 0L || !exports.configWrite) return null
        val raw = nativeLastWriteWarningsJson(handle) ?: return null
        return try { org.json.JSONArray(raw) } catch (_: Exception) { null }
    }

    /** Apply several keys at once. The document is the same one /api/config/batch accepts. */
    fun configBatchJson(opsJson: String): JSONObject? {
        if (handle == 0L || !exports.configWrite) return null
        return parse(nativeConfigBatchJson(handle, opsJson))
    }

    fun deleteConfigKey(key: String): Int? {
        if (handle == 0L || !exports.configWrite) return null
        return nativeDeleteConfigKey(handle, key)
    }

    /**
     * Verify the cluster-wide administrator password. Positive means accepted, zero means wrong,
     * -1 means entry is locked out, and -2 means no password has been set yet. Null when this core
     * cannot answer at all.
     */
    fun adminPasswordVerify(password: String): Int? {
        if (handle == 0L || !exports.adminPassword) return null
        return nativeAdminPasswordVerify(handle, password)
    }

    /** Set the cluster-wide administrator password; pass an empty current when none exists. */
    fun adminPasswordSet(current: String, next: String): Int? {
        if (handle == 0L || !exports.adminPassword) return null
        return nativeAdminPasswordSet(handle, current, next)
    }

    fun setCapabilities(value: JSONObject) {
        if (handle != 0L) nativeSetCapabilitiesJson(handle, value.toString())
    }

    fun setRuntimeStatus(value: JSONObject) {
        if (handle != 0L) nativeSetRuntimeStatusJson(handle, value.toString())
    }

    fun setUiManifest(value: JSONObject) {
        if (handle != 0L) nativeSetUiManifestJson(handle, value.toString())
    }

    /** Push a camera frame: 0=NV21, 1=NV12, 2=YUY2, 3=BGRA. */
    fun onCameraFrame(data: ByteArray, format: Int, width: Int, height: Int, stride: Int,
                      tsMs: Long) {
        if (handle != 0L) nativeOnCameraFrame(handle, data, format, width, height, stride, tsMs)
    }

    /** Publishes the door station sensor angle; a configured fixed angle wins in Core. */
    fun setVideoSensorRotation(degrees: Int) {
        if (handle != 0L) nativeSetVideoSensorRotation(handle, degrees)
    }

    /** Push an Annex-B H.264 access unit for Core's fMP4 stream. */
    fun onEncodedFrame(annexb: ByteArray, isKeyframe: Boolean, tsMs: Long) {
        if (handle != 0L) nativeOnEncodedFrame(handle, annexb, isKeyframe, tsMs)
    }

    /** Whether Core currently needs the H.264 encoder. */
    fun videoEncoderWanted(): Boolean =
        handle != 0L && nativeVideoEncoderWanted(handle)

    /**
     * Place a SIP call to an extension or complete SIP URI. Empty mode is bidirectional;
     * "monitor" is receive-only audio.
     */
    fun sipCall(target: String, mode: String = "") {
        if (handle != 0L) nativeSipCall(handle, target, mode)
    }

    fun sipHangup() {
        if (handle != 0L) nativeSipHangup(handle)
    }

    fun sipSendDtmf(digits: String): Boolean =
        handle != 0L && nativeSipSendDtmf(handle, digits) == 0

    /** Deliver a display/TTS quick reply; an empty door selects the latest visitor call. */
    fun quickReply(replyId: String, door: String) {
        if (handle != 0L) nativeQuickReply(handle, replyId, door)
    }

    /** Deliver a reply only to the exact active visitor-call revision. */
    fun quickReplyV2(replyId: String, door: String, callId: String,
                     stageRevision: Int): Boolean =
        handle != 0L && replyId.isNotEmpty() && callId.isNotEmpty() && stageRevision >= 0 &&
            nativeQuickReplyV2(handle, replyId, door, callId, stageRevision)

    fun version(): String = nativeVersion()

    // Pairing discovery and invitation.

    /** Pairing state for the enrollment UI. */
    fun pairingInfo(): JSONObject? = parse(if (handle != 0L) nativePairingJson(handle) else null)

    /** Join from an unpaired node using a seed address and PIN. */
    fun joinCluster(host: String, pin: String) {
        if (handle != 0L) nativeJoinCluster(handle, host, pin)
    }

    /** Enable pairing mode for the requested duration; zero seconds closes the window. */
    fun setPairingMode(seconds: Int) {
        if (handle != 0L) nativePairingMode(handle, seconds)
    }

    /**
     * Open the bulk-add window and mint a Pairing PIN in one step. The result carries
     * ok, host, pin, and expires_s, or ok=false with err.
     */
    fun startPairing(seconds: Int): JSONObject? =
        parse(if (handle != 0L) nativeStartPairingJson(handle, seconds) else null)

    /**
     * Mint or refresh the Pairing PIN **without** opening the bulk-add window. This is what the
     * founder's PIN card uses; [startPairing] belongs only to the explicit 「まとめて追加」 button
     * and its warning. seconds is clamped by core to 30..600; zero keeps core's default.
     */
    fun mintJoinToken(seconds: Int): JSONObject? =
        parse(if (handle != 0L) nativeMintJoinTokenJson(handle, seconds) else null)

    /** Approve and invite one pending node. */
    fun inviteDevice(nodeId: String) {
        if (handle != 0L) nativeInviteDevice(handle, nodeId)
    }

    /** Invite an address, ID, and public key directly, as carried by an Add QR. */
    fun inviteDirect(addr: String, nodeId: String, pk: String) {
        if (handle != 0L) nativeInviteDirect(handle, addr, nodeId, pk)
    }

    /** Drop one pending device and ignore its announcements for a while. */
    fun denyDevice(nodeId: String) {
        if (handle != 0L) nativeDenyDevice(handle, nodeId)
    }

    /** Re-run the secure-store write after pairing state "persist_error". */
    fun retryPairingPersistence(): Boolean =
        handle != 0L && nativeRetryPairingPersistence(handle)

    /** Leave the cluster and drop the stored pre-shared key. */
    fun unpair() {
        if (handle != 0L) nativeUnpair(handle)
    }

    /** Decode camera frames already delivered through [onCameraFrame] until stopped. */
    fun qrScanStart() {
        if (handle != 0L) nativeQrScanStart(handle)
    }

    fun qrScanStop() {
        if (handle != 0L) nativeQrScanStop(handle)
    }

    /**
     * Parse a doorbell:// pairing link with core's own parser, which checks the expiry against
     * corrected cluster time. Null when core is not running -- a link can be scanned before it
     * starts -- and the shell then uses its own parse of the same grammar.
     */
    fun parsePairUri(uri: String): JSONObject? =
        if (uri.isEmpty() || handle == 0L) null else parse(nativeParsePairUriJson(handle, uri))

    /** Encode QR data as [side length, row-major module values...]. */
    fun qrEncode(text: String): IntArray? = if (text.isEmpty()) null else nativeQrEncode(text)

    /** Bootstrap a new cluster from this unpaired device. */
    fun foundCluster(): Boolean = handle != 0L && nativeFoundCluster(handle)

    private fun parse(s: String?): JSONObject? =
        try { if (s == null) null else JSONObject(s) } catch (_: Exception) { null }

    /** Traverse the configuration tree by dotted path. */
    fun dig(root: JSONObject?, dotpath: String): Any? {
        var cur: Any? = root ?: return null
        for (part in dotpath.split(".")) {
            val o = cur as? JSONObject ?: return null
            cur = o.opt(part) ?: return null
        }
        return cur
    }

    // JNI callbacks from Core-owned threads.

    @Suppress("unused")
    private fun onUiEventFromNative(json: String) {
        val ev = try { JSONObject(json) } catch (_: Exception) { return }
        listener?.onUiEvent(ev)
    }

    @Suppress("unused")
    private fun onTtsFromNative(text: String, lang: String) {
        listener?.onTts(text, lang)
    }

    @Suppress("unused")
    private fun onHttpsRequestFromNative(
        method: String,
        url: String,
        headersJson: String,
        body: ByteArray,
    ): ByteArray? = AndroidHttpsClient.request(method, url, headersJson, body)

    @Suppress("unused")
    private fun onSecureGetFromNative(key: String): String? = secureStore.get(key)

    @Suppress("unused")
    private fun onSecurePutFromNative(key: String, value: String): Boolean =
        secureStore.put(key, value)

    @Suppress("unused")
    private fun onSecureDeleteFromNative(key: String): Boolean = secureStore.delete(key)

    @Suppress("unused")
    private fun onDeviceInfoFromNative(): String = deviceInfo.snapshot()

    /** db_platform_v2.power_state: battery percentage, charging, and mains presence. */
    @Suppress("unused")
    private fun onPowerStateFromNative(): String = deviceInfo.powerState()

    fun isOnMainsPower(): Boolean = deviceInfo.isOnMainsPower()

    internal fun putPlatformSecret(key: String, value: String): Boolean =
        secureStore.put(key, value)

    /** Remove one platform secret; used by the factory reset that follows a revocation. */
    internal fun deletePlatformSecret(key: String): Boolean = secureStore.delete(key)

    internal fun platformDeviceInfo(): JSONObject = parse(deviceInfo.snapshot()) ?: JSONObject()

    // ---------- native ----------

    private external fun nativeCreate(dataDir: String, bootJson: String): Long
    private external fun nativeBackendJson(): String
    private external fun nativeStart(handle: Long): Int
    private external fun nativeStop(handle: Long)
    private external fun nativeDestroy(handle: Long)
    private external fun nativeSetUiCallback(handle: Long, enabled: Boolean)
    private external fun nativePress(handle: Long, doorId: String)
    private external fun nativePressPurpose(handle: Long, doorId: String, purpose: String)
    private external fun nativeSelectPurpose(handle: Long, doorId: String, purpose: String)
    private external fun nativeCancelCall(handle: Long, doorId: String)
    private external fun nativePressV2(handle: Long, doorId: String, purpose: String): String?
    private external fun nativeSelectPurposeV2(
        handle: Long,
        doorId: String,
        callId: String,
        purpose: String,
    ): Int
    private external fun nativeCancelCallV2(
        handle: Long,
        doorId: String,
        callId: String,
        reason: String,
    ): Int
    private external fun nativeReportCallAnsweredV2(
        handle: Long,
        doorId: String,
        callId: String,
        stageRevision: Int,
    ): Int
    private external fun nativeReportCallEndedV2(
        handle: Long,
        doorId: String,
        callId: String,
        stageRevision: Int,
        reason: String,
    ): Int
    private external fun nativeReportCallRecovery(handle: Long, callId: String, restored: Boolean)
    private external fun nativeEmergencyV2(handle: Long, active: Boolean): Boolean
    private external fun nativeSetVisitorLang(handle: Long, door: String, lang: String)
    private external fun nativeStatusJson(handle: Long): String?
    private external fun nativeLocalTimeJson(handle: Long, wallMs: Long): String?
    private external fun nativeTimeSyncNow(handle: Long): Int
    private external fun nativeAudioJson(handle: Long, deviceId: String): String?
    private external fun nativeSetDoorNotice(
        handle: Long,
        door: String,
        text: String,
        expiresMs: Long,
    ): Int
    private external fun nativeClearDoorNotice(handle: Long, door: String): Int
    private external fun nativeOpenDoor(handle: Long, door: String): Int
    private external fun nativeCallLogJson(handle: Long, sinceMs: Long, limit: Int): String?
    private external fun nativeCallLogJsonV2(
        handle: Long,
        sinceMs: Long,
        beforeMs: Long,
        limit: Int,
    ): String?
    private external fun nativeCoreExportsJson(): String?
    private external fun nativeSetConfigJson(handle: Long, key: String, valueJson: String): Int
    private external fun nativeConfigBatchJson(handle: Long, opsJson: String): String?
    private external fun nativeLastWriteWarningsJson(handle: Long): String?
    private external fun nativeDeleteConfigKey(handle: Long, key: String): Int
    private external fun nativeAdminPasswordVerify(handle: Long, password: String): Int
    private external fun nativeAdminPasswordSet(
        handle: Long,
        current: String,
        next: String,
    ): Int
    private external fun nativeSipSetMicMuted(handle: Long, muted: Boolean): Int
    private external fun nativeCallLogMarkSeen(handle: Long, upToHlc: String): Int
    private external fun nativeConfigJson(handle: Long): String?
    private external fun nativeSetCapabilitiesJson(handle: Long, json: String)
    private external fun nativeSetRuntimeStatusJson(handle: Long, json: String)
    private external fun nativeSetUiManifestJson(handle: Long, json: String)
    private external fun nativeCapabilitiesJson(handle: Long): String?
    private external fun nativeOnCameraFrame(handle: Long, data: ByteArray, format: Int,
                                             width: Int, height: Int, stride: Int, tsMs: Long)
    private external fun nativeSetVideoSensorRotation(handle: Long, degrees: Int)
    private external fun nativeOnEncodedFrame(handle: Long, annexb: ByteArray,
                                              isKeyframe: Boolean, tsMs: Long)
    private external fun nativeVideoEncoderWanted(handle: Long): Boolean
    private external fun nativeSipCall(handle: Long, target: String, mode: String)
    private external fun nativeSipHangup(handle: Long)
    private external fun nativeSipSendDtmf(handle: Long, digits: String): Int
    private external fun nativeQuickReply(handle: Long, replyId: String, door: String)
    private external fun nativeQuickReplyV2(handle: Long, replyId: String, door: String,
                                            callId: String, stageRevision: Int): Boolean
    private external fun nativeVersion(): String
    private external fun nativeDebugJson(handle: Long): String?
    private external fun nativePairingJson(handle: Long): String?
    private external fun nativeJoinCluster(handle: Long, host: String, pin: String)
    private external fun nativePairingMode(handle: Long, seconds: Int)
    private external fun nativeStartPairingJson(handle: Long, seconds: Int): String?
    private external fun nativeMintJoinTokenJson(handle: Long, seconds: Int): String?
    private external fun nativeInviteDevice(handle: Long, nodeId: String)
    private external fun nativeInviteDirect(handle: Long, addr: String, nodeId: String, pk: String)
    private external fun nativeDenyDevice(handle: Long, nodeId: String)
    private external fun nativeRetryPairingPersistence(handle: Long): Boolean
    private external fun nativeUnpair(handle: Long)
    private external fun nativeQrScanStart(handle: Long)
    private external fun nativeQrScanStop(handle: Long)
    private external fun nativeQrEncode(text: String): IntArray?
    private external fun nativeParsePairUriJson(handle: Long, uri: String): String?
    private external fun nativeFoundCluster(handle: Long): Boolean

    companion object {
        /** The door identifier that addresses the cluster-wide announcement (notice.global). */
        const val GLOBAL_DOOR = "*"


        init {
            System.loadLibrary("doorbell")
        }
    }
}
