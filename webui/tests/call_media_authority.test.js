"use strict";
const assert = require("assert");
const { runtime } = require("./call_page_fixture.js");
const flush = async () => { for (let i = 0; i < 12; ++i) await Promise.resolve(); };
const generation = "abcdef0123456789abcdef0123456789";
const csrf = "0123456789abcdef0123456789abcdef";
function grant(call = "call-A", revision = 1, remaining = 10000) {
  return { ok: true, call_id: call, stage_revision: revision, dialog_owner: "mine",
    media_generation: generation, publish_remaining_ms: remaining };
}
async function answer(request, data, status = 200) {
  await request.response.resolve({ status, json: async () => data }); await flush();
}
function setup() {
  const driver = { starts: [], stopped: 0, start(binding) { this.starts.push(binding); return true; },
    stop() { this.stopped++; } };
  const r = runtime({ videoDriver: driver }); r.activate("A", "call-A", 1);
  r.run('activeLifecycle.answered=true; selected.station="http://untrusted-peer"; els.sendVideo.checked=true');
  return { r, driver };
}
(async () => {
  {
    const { r, driver } = setup(); r.run("startSendingVideo()");
    const auth = r.requests.shift();
    assert.strictEqual(auth.url, "/api/panel/media-authorize");
    assert.strictEqual(auth.headers["X-Doorbell-CSRF"], csrf);
    assert.strictEqual(driver.starts.length, 0, "capture waits for authority");
    await answer(auth, grant());
    assert.strictEqual(driver.starts.length, 1);
    r.context.frameBlob = { type: "image/jpeg" };
    r.run("postVideoFrame(videoBinding,frameBlob)");
    const upload = r.requests.shift();
    assert(upload.url.startsWith("/call-frame?"));
    assert(!upload.url.includes("http:"));
    assert(!("Authorization" in upload.headers), "no empty or long-lived bearer is forwarded");
    assert.strictEqual(upload.headers["X-Doorbell-CSRF"], csrf);
    assert(upload.url.includes("frame_sequence=1"));
    await answer(upload, { ok: true, media_generation: generation, frame_sequence: "1",
      acceptance: "remote_core_accepted" });
    assert.strictEqual(r.run("videoBinding.sequence"), 1);
    assert.strictEqual(r.run("videoState"), "REMOTE_CORE_ACCEPTED");
    assert.strictEqual(r.run("videoBinding.acceptedSequence"), 1);
    assert.strictEqual(r.run("videoBinding.acceptedAt"), 0, "monotonic acceptance time is recorded at the test clock origin");
  }
  {
    const { r, driver } = setup(); r.run("startSendingVideo()");
    const old = r.requests.shift(); r.run("stopSendingVideo()");
    r.activate("B", "call-B", 2); r.run('activeLifecycle.answered=true;els.sendVideo.checked=true;startSendingVideo()');
    const successor = r.requests.shift(); await answer(old, grant());
    assert.strictEqual(driver.starts.length, 0);
    await answer(successor, grant("call-B", 2));
    assert.strictEqual(driver.starts.length, 1);
    assert.strictEqual(r.run("videoBinding.door"), "B");
  }
  for (const response of [{ status: 403, data: { ok: false, error_code: "publisher_not_owner" } },
                          { status: 409, data: { ok: false, error_code: "stale_media_generation" } },
                          { status: 200, data: grant("other-call") }]) {
    const { r, driver } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), response.data, response.status);
    assert.strictEqual(driver.starts.length, 0);
    assert.strictEqual(r.run("videoBinding"), null);
    assert.strictEqual(r.elements.get("sendVideo").checked, false);
  }
  {
    const { r, driver } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), grant());
    r.context.frameBlob = { type: "image/jpeg" }; r.run("postVideoFrame(videoBinding,frameBlob).catch(()=>{})");
    await answer(r.requests.shift(), { ok: false, error_code: "temporary_peer_unavailable" }, 503);
    assert.strictEqual(r.run("videoState"), "RECOVERING");
    assert.strictEqual(r.elements.get("sendVideo").checked, true);
    assert.strictEqual(driver.stopped, 0);
    r.advance(250);
    assert.strictEqual(r.run("videoState"), "SENDING");
  }
  {
    const { r } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), grant());
    r.context.frameBlob = { type: "image/jpeg" }; r.run("postVideoFrame(videoBinding,frameBlob).catch(()=>{})");
    await answer(r.requests.shift(), { ok: false, error_code: "temporary_peer_unavailable" }, 503);
    const staleRetry = Array.from(r.timers.values()).find(timer => timer.at > 0).fn;
    r.run("stopSendingVideo()");
    r.activate("B", "call-B", 2); r.run("activeLifecycle.answered=true;els.sendVideo.checked=true;startSendingVideo()");
    const next = r.run("videoBinding"); staleRetry();
    assert.strictEqual(r.run("videoBinding"), next, "obsolete retry never touches the next call binding");
  }
  {
    const { r } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), grant());
    r.context.frameBlob = { type: "image/jpeg" }; r.run("postVideoFrame(videoBinding,frameBlob).catch(()=>{})");
    await answer(r.requests.shift(), { ok: false, error_code: "temporary_peer_unavailable" }, 503);
    assert.strictEqual(r.timers.size, 1);
    r.run("els.sendVideo.checked=false;stopSendingVideo()");
    assert.strictEqual(r.timers.size, 0, "manual video-off cancels recovery retry");
    assert.strictEqual(r.run("videoState"), "OFF");
  }
  {
    const { r } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), grant());
    r.context.frameBlob = { type: "image/jpeg" }; r.run("postVideoFrame(videoBinding,frameBlob).catch(()=>{})");
    const pending = r.requests.shift();
    r.run("stopSendingVideo()");
    r.activate("B", "call-B", 2); r.run("activeLifecycle.answered=true;els.sendVideo.checked=true;startSendingVideo()");
    await answer(pending, { ok: true, media_generation: generation, frame_sequence: "1",
      acceptance: "remote_core_accepted" });
    assert.notStrictEqual(r.run("videoState"), "REMOTE_CORE_ACCEPTED", "stale accepted result cannot update a replacement call");
    assert.strictEqual(r.run("videoBinding.callId"), "call-B");
    r.run("stopSendingVideo()");
  }
  {
    const { r, driver } = setup(); r.run("startSendingVideo()");
    r.advance(1500); await flush();
    assert.strictEqual(driver.starts.length, 0);
    assert.strictEqual(r.run("videoState"), "RECOVERING");
    assert.strictEqual(r.elements.get("sendVideo").checked, true);
    assert.strictEqual(r.timers.size, 1, "timeout schedules a bounded retry");
  }
  {
    const { r } = setup(); r.run("startSendingVideo()");
    await answer(r.requests.shift(), { ok: false, error_code: "temporary_peer_unavailable" }, 503);
    const delays = [250, 500, 1000, 2000, 4000];
    for (const delay of delays) {
      r.advance(delay); await flush();
      const retry = r.requests.shift();
      assert(retry, "each bounded backoff attempts a fresh authorization");
      await answer(retry, { ok: false, error_code: "temporary_peer_unavailable" }, 503);
    }
    assert.strictEqual(r.run("videoState"), "INTERRUPTED");
    assert.strictEqual(r.elements.get("sendVideo").checked, true, "bounded exhaustion reports interrupted without erasing intent");
    assert.strictEqual(r.timers.size, 0);
    r.run("stopSendingVideo()");
  }
  {
    const { r } = setup(); r.run('panelCsrf="";loadPanelSession()');
    const pending = r.requests.shift(); r.listeners.pagehide();
    await answer(pending, { ok: true, csrf_token: csrf });
    assert.strictEqual(r.run("panelCsrf"), "", "late page metadata cannot reauthorize a hidden page");
    assert.strictEqual(r.run("panelCsrfRequest"), null);
  }
  console.log("T17 production page media authority, recovery and stale callback regressions: PASS");
})().catch(error => { console.error(error); process.exitCode = 1; });
