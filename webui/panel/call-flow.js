/* Pure call-flow helpers shared by Web panel pages. ES5 parse-safe. */
(function (root, factory) {
  var api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DoorbellCallFlow = api;
})(typeof window !== "undefined" ? window : {}, function () {
  "use strict";
  function flowMode(v) {
    var mode = typeof v === "string" ? v : ((v && v.mode) || "purpose_first");
    return mode === "ring_then_purpose" ? mode : "purpose_first";
  }
  function form(fields) {
    var out = [];
    for (var k in fields) if (fields[k] !== undefined && fields[k] !== null && fields[k] !== "")
      out.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(fields[k])));
    return out.join("&");
  }
  function pressForm(door, token, purpose) {
    return form({ door: door, purpose: purpose || undefined });
  }
  function cancelForm(door, callId, token) {
    if (!door || !callId) throw new Error("door and call_id are required");
    return form({ door: door, call_id: callId });
  }
  function purposeForm(door, callId, purpose, token) {
    if (!door || !callId || !purpose) throw new Error("door, call_id and purpose are required");
    return form({ door: door, call_id: callId, purpose: purpose });
  }
  function recoveryForm(door, callId, restored, token, dialogId) {
    if (!door || !callId) throw new Error("door and call_id are required");
    return form({ door: door, call_id: callId, restored: restored ? 1 : 0,
                  dialog_id: dialogId || undefined });
  }
  function lifecycleForm(door, callId, stageRevision, state, dialogId, reason) {
    var revision = Number(stageRevision);
    if (!door || !callId || !/^[0-9a-f]{32}$/.test(dialogId || "") ||
        !isFinite(revision) || revision < 0 ||
        Math.floor(revision) !== revision)
      throw new Error("door, call_id, dialog_id and a non-negative stage_revision are required");
    if (state !== "answered" && state !== "ended" && state !== "heartbeat")
      throw new Error("lifecycle state must be answered, ended or heartbeat");
    return form({ door: door, call_id: callId, stage_revision: revision,
                  state: state, dialog_id: dialogId,
                  reason: state === "ended" ? (reason || "sip_ended") : undefined });
  }
  function mergeState(current, remote) {
    current = current || {}; remote = remote || {};
    var localId = current.call_id || "", remoteId = remote.call_id || "";
    if (localId && remoteId && localId !== remoteId) return { accepted: false, reason: "call_id" };
    var localRev = Number(current.stage_revision) || 0, remoteRev = Number(remote.stage_revision) || 0;
    if (remoteRev && remoteRev < localRev) return { accepted: false, reason: "stage_revision" };
    return { accepted: true, call_id: localId || remoteId,
      stage_revision: Math.max(localRev, remoteRev), call_state: remote.call_state || "",
      calling: !!remote.calling, expires_at_ms: Number(remote.expires_at_ms) || 0 };
  }
  function residentDisposition(callState, sessionConfirmed, lifecycleBound) {
    if (lifecycleBound && !callState) return sessionConfirmed ? "end" : "cancelled";
    if (callState === "ended") return "end";
    if (callState === "cancelled") return "cancelled";
    if (callState === "expired") return "expired";
    if ((callState === "answered" || callState === "in_call") && !sessionConfirmed)
      return "answered_elsewhere";
    return "keep";
  }
  function deadlineDelay(expiresAtMs, nowMs) {
    var expires = Number(expiresAtMs), now = Number(nowMs);
    if (!isFinite(expires) || expires <= 0 || !isFinite(now)) return 0;
    return Math.max(1, expires - now);
  }
  return { flowMode: flowMode, form: form, pressForm: pressForm, cancelForm: cancelForm,
           purposeForm: purposeForm, recoveryForm: recoveryForm, lifecycleForm: lifecycleForm,
           mergeState: mergeState, residentDisposition: residentDisposition,
           deadlineDelay: deadlineDelay };
});
