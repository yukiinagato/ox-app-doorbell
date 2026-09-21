"use strict";

const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const source = fs.readFileSync("webui/panel/call.html", "utf8");
const match = source.match(/function finishRecovery\(binding, expectedSession, ok\) \{[\s\S]*?\n\}/);
assert(match, "call controller must own recovery completion in the production page");

function controller(currentBinding, currentSession) {
  const state = { activeLifecycle: currentBinding, session: currentSession, sessionConfirmed: true,
    ended: 0, status: "" };
  const context = {
    get activeLifecycle() { return state.activeLifecycle; },
    get session() { return state.session; },
    get sessionConfirmed() { return state.sessionConfirmed; },
    setStatus(text) { state.status = text; }, t(key) { return key; },
    endCall(_reason, binding, expectedSession) {
      if (state.activeLifecycle !== binding || state.session !== expectedSession) return false;
      state.ended++;
      state.session = null;
      state.activeLifecycle = null;
      return true;
    }
  };
  vm.runInNewContext(match[0], context);
  return { state, finish: context.finishRecovery };
}

const sessionA = {}, sessionB = {};
const bindingA = { recoveryPending: true, callId: "A", stageRevision: 1 };
const bindingB = { recoveryPending: true, callId: "B", stageRevision: 2 };
const lateA = controller(bindingB, sessionB);
assert.strictEqual(lateA.finish(bindingA, sessionA, false), false);
assert.strictEqual(bindingA.recoveryPending, false, "late A clears only its own pending flag");
assert.strictEqual(lateA.state.ended, 0, "late A failure cannot terminate B");
assert.strictEqual(lateA.state.session, sessionB);

bindingA.recoveryPending = true;
assert.strictEqual(lateA.finish(bindingA, sessionA, true), false);
assert.strictEqual(bindingA.recoveryPending, false, "late A success also clears only A's pending flag");
assert.strictEqual(lateA.state.session, sessionB, "late A success cannot touch B's session");

const currentA = controller(bindingA, sessionA);
bindingA.recoveryPending = true;
assert.strictEqual(currentA.finish(bindingA, sessionA, false), true);
assert.strictEqual(currentA.state.ended, 1, "the current failed recovery still converges its call");

const videoMatch = source.match(/onError: (\(error, binding\) => \{[\s\S]*?\n  \})\n\}\);/);
assert(videoMatch, "the production page must own video-binding error cleanup");
const videoState = { videoBinding: bindingB, status: "", checked: true };
const videoContext = {
  get videoBinding() { return videoState.videoBinding; },
  set videoBinding(value) { videoState.videoBinding = value; },
  setStatus(text) { videoState.status = text; }, t(key, values) { return key + values.reason; },
  els: { sendVideo: { get checked() { return videoState.checked; },
    set checked(value) { videoState.checked = value; } } },
  handler: null
};
vm.runInNewContext("handler = " + videoMatch[1], videoContext);
videoContext.handler({ name: "NotAllowedError" }, bindingA);
assert.strictEqual(videoState.videoBinding, bindingB, "an old camera failure cannot clear B's binding");
assert.strictEqual(videoState.checked, true, "an old camera failure cannot change B's UI control");
videoContext.handler({ name: "NotAllowedError" }, bindingB);
assert.strictEqual(videoState.videoBinding, null, "the current camera failure releases its retry gate");
assert.strictEqual(videoState.checked, false, "the current camera failure unchecks its own UI control");

console.log("call recovery controller tests: ok");
