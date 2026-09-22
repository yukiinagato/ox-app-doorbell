"use strict";
const assert = require("assert");
const { runtime } = require("./call_page_fixture.js");
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function pending(r, state) {
  return r.requests.find(x => !x.completed && !(x.xhr && x.xhr.aborted) &&
    x.url === "/api/panel/call-lifecycle" && new URLSearchParams(x.body).get("state") === state);
}
async function reply(request, body, status = 200) {
  assert(request, "expected lifecycle request"); request.completed = true;
  await request.response.resolve({ ok: status >= 200 && status < 300, status, json: async () => body });
  await flush();
}
function lease(call = "A", remaining = 10000) {
  return { ok: true, call_id: call, stage_revision: 2, dialog_owner: "owner-" + call,
    lease_remaining_ms: remaining };
}
async function connect(r, call = "A", remaining = 10000) {
  const events = {}, sip = { terminated: 0, isEnded() { return false; },
    terminate() { this.terminated++; }, on(name, cb) { events[name] = cb; },
    connection: { addEventListener() {} } };
  r.context.sipFixture = sip;
  r.context.window.crypto = { getRandomValues(bytes) { bytes.fill(call === "A" ? 1 : 2); } };
  r.activate("door", call, 2);
  r.run('session=null; activeLifecycle=null; selected.calling=true; webrtc={server:"localhost"}; ua={call(){return sipFixture}}; startCall();');
  events.confirmed();
  await reply(pending(r, "answered"), lease(call, remaining));
  return { sip, binding: r.run("activeLifecycle") };
}
const tests = {
  async "T11-01"() {
    const r = runtime(), { sip } = await connect(r);
    r.advance(2000); r.run("heartbeatLifecycle(activeLifecycle)");
    await reply(pending(r, "heartbeat"), { ok: false, error_code: "not_started" }, 503);
    assert.strictEqual(sip.terminated, 0, "a single 503 cannot end a valid leased media session");
    assert.strictEqual(r.elements.get("status").textContent, "panel.control_reconnecting");
    r.advance(499); assert(!pending(r, "heartbeat"), "first retry waits 500 ms");
    r.advance(1); const retry = pending(r, "heartbeat");
    assert(retry, "heartbeat retries independently of state/config/locale");
    assert.strictEqual(retry.xhr.timeout, 1500);
    r.advance(1000); await reply(retry, lease());
    assert.strictEqual(r.run("activeLifecycle.leaseDeadline"), 12500,
      "a delayed ACK uses request start plus server remaining duration, not arrival plus a full lease");
    assert.strictEqual(r.elements.get("status").textContent, "incall.title");
    assert.strictEqual(sip.terminated, 0);
  },
  async "T11-02"() {
    const r = runtime(), { sip } = await connect(r);
    r.run("heartbeatLifecycle(activeLifecycle)");
    await reply(pending(r, "heartbeat"), { ok: false, error_code: "stale_revision" }, 409);
    assert.strictEqual(sip.terminated, 0, "an unrelated 409 is not terminal ownership evidence");
    r.advance(500);
    await reply(pending(r, "heartbeat"), { ok: false, error_code: "stale_owner" }, 409);
    assert.strictEqual(sip.terminated, 1);
    assert.strictEqual(r.run("session"), null);
    const winner = await connect(r, "B");
    const ended = pending(r, "ended");
    if (ended) await reply(ended, { ok: false, error_code: "stale_owner" }, 409);
    assert.strictEqual(r.run("session"), winner.sip, "old owner's end result cannot stop winner");
    assert.strictEqual(winner.sip.terminated, 0);
  },
  async "T11-03"() {
    const r = runtime(), { sip } = await connect(r);
    r.run("heartbeatLifecycle(activeLifecycle)");
    await reply(pending(r, "heartbeat"), {}, 503);
    assert.strictEqual(sip.terminated, 0, "failure remains transient before lease expiry");
    for (let i = 0; i < 19; i++) { r.advance(500); await flush(); }
    assert.strictEqual(sip.terminated, 0, "media remains while the original lease is valid");
    r.advance(500); await flush();
    assert.strictEqual(sip.terminated, 1, "no endless ownership past server lease boundary");
    assert.strictEqual(r.run("activeLifecycle"), null);
  },
  async "T11-04"() {
    const r = runtime(), first = await connect(r);
    r.run("heartbeatLifecycle(activeLifecycle)"); const old = pending(r, "heartbeat");
    r.run('endCall("local_hangup")');
    const current = await connect(r, "B", 6000);
    assert.strictEqual(current.binding.leaseDeadline, 6000, "new lease comes from its own server snapshot");
    await reply(old, lease("A"));
    assert.strictEqual(current.binding.leaseDeadline, 6000, "old success cannot renew new call");
    assert.strictEqual(r.run("session"), current.sip);
    assert.strictEqual(current.sip.terminated, 0);
    assert.strictEqual(first.sip.terminated, 1);
    r.run("heartbeatLifecycle(activeLifecycle)"); const cancelled = pending(r, "heartbeat");
    r.run('endCall("local_hangup")');
    const third = await connect(r, "C", 7000);
    await reply(cancelled, { ok: false, error_code: "stale_owner" }, 409);
    assert.strictEqual(r.run("session"), third.sip, "late terminal response cannot end successor");
    assert.strictEqual(third.binding.leaseDeadline, 7000);
  }
};
(async () => {
  for (const [id, test] of Object.entries(tests)) {
    if (process.argv[2] && process.argv[2] !== id) continue;
    await test(); console.log(id + " production heartbeat: PASS");
  }
  if (process.argv[2]) return;
  for (const mismatch of [
    { call_id: "old" }, { stage_revision: 1 }, { dialog_owner: "another-owner" },
    { lease_remaining_ms: 10001 }, { lease_remaining_ms: -1 },
    { lease_remaining_ms: "10000" }, { lease_remaining_ms: 1.5 }
  ]) {
    const r = runtime(), { binding, sip } = await connect(r);
    r.advance(2000);
    await reply(pending(r, "heartbeat"), Object.assign(lease(), mismatch));
    assert.strictEqual(binding.leaseDeadline, 10000, "unbound or invalid ACK cannot renew the lease");
    assert.strictEqual(sip.terminated, 0, "invalid ACK remains bounded by original lease");
  }
  for (const code of ["auth_required", "permission_denied", "call_ended"]) {
    const r = runtime(), { sip } = await connect(r);
    r.advance(2000);
    await reply(pending(r, "heartbeat"), { ok: false, error_code: code }, 403);
    assert.strictEqual(sip.terminated, 1, "explicit terminal evidence retires exact call: " + code);
  }
  {
    const r = runtime(), { binding, sip } = await connect(r);
    r.context.document.hidden = true; r.listeners.visibilitychange();
    r.advance(2500); await flush();
    assert(!pending(r, "heartbeat"), "hidden page does not issue more ownership claims");
    r.context.document.hidden = false; r.listeners.visibilitychange();
    assert(!pending(r, "heartbeat"), "foreground waits for authority before claiming its old owner");
    const request = r.requests.find(x => x.url === "/state" && !x.completed && !x.xhr.aborted);
    await reply(request, { doors: [{ id: "door", call_id: "A", stage_revision: 2,
      call_state: "in_call", dialog_owner: "owner-A" }] });
    assert(pending(r, "heartbeat"), "fresh matching state permits ownership verification");
    assert.strictEqual(binding.leaseDeadline, 10000, "foreground snapshot alone does not renew lease");
    assert.strictEqual(sip.terminated, 0);
    r.context.document.hidden = true; r.listeners.visibilitychange();
    r.advance(8000); await flush();
    assert.strictEqual(sip.terminated, 1, "sleep cannot extend the old lease");
  }
  {
    const r = runtime(), { sip } = await connect(r);
    r.advance(2000); const expiredRequest = pending(r, "heartbeat");
    r.advance(1500); await flush();
    assert.strictEqual(expiredRequest.xhr.aborted, true);
    assert.strictEqual(sip.terminated, 0, "bounded transport timeout keeps media within remaining lease");
    r.advance(500); const successor = pending(r, "heartbeat");
    assert(successor && successor !== expiredRequest);
    await reply(expiredRequest, lease());
    assert.strictEqual(r.run("activeLifecycle.heartbeatPending"), true, "retired timeout cannot release successor gate");
    await reply(successor, lease());
    assert.strictEqual(r.run("activeLifecycle.leaseDeadline"), 14000);
  }
  console.log("heartbeat identity bounds, auth, visibility, timeout and late-success guards: PASS");
})().catch(error => { console.error(error); process.exitCode = 1; });
