"use strict";
const assert = require("assert");
const { runtime } = require("./call_page_fixture.js");
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const info = { webrtc: { ws_url: "ws://localhost", sip_user: "260" }, doors: {} };
function pending(r, url) { return r.requests.filter(x => x.url === url && !x.completed && !(x.xhr && x.xhr.aborted)); }
async function reply(r, url, body, status = 200) {
  const request = pending(r, url)[0]; assert(request, "missing request: " + url);
  request.completed = true;
  await request.response.resolve({ ok: status >= 200 && status < 300, status, json: async () => body });
  await flush(); return request;
}
const state = active => ({ doors: [], emergency: { active } });
const tests = {
  async "T10-01"() {
    const r = runtime(); r.run("load()");
    await reply(r, "/state", state(true));
    assert.strictEqual(r.emergencyUpdates.length, 1, "state/SOS applies before hung call-info settles");
    assert.strictEqual(r.emergencyUpdates[0].emergency.active, true);
    const hung = pending(r, "/api/panel/call-info")[0];
    for (let i = 0; i < 4; i++) { r.advance(1000); await reply(r, "/state", state(i < 3)); }
    assert.strictEqual(hung.xhr.aborted, true, "call-info is bounded at 4000 ms");
    assert.strictEqual(r.emergencyUpdates.length, 5);
    assert.strictEqual(r.emergencyUpdates[4].emergency.active, false, "authoritative clear still applies");
    assert.strictEqual(r.elements.get("offlineBand").style.display, "none");
    assert.strictEqual(r.elements.get("configBand").style.display, "block");
    r.advance(5000);
    await reply(r, "/api/panel/call-info", info);
    assert.strictEqual(r.run("webrtc.sip_user"), "260");
    assert.strictEqual(r.elements.get("configBand").style.display, "none");
    r.advance(5000); await reply(r, "/api/panel/call-info", {}, 503);
    assert.strictEqual(r.run("webrtc.sip_user"), "260", "failed config preserves working SIP settings");
    assert.strictEqual(r.elements.get("configBand").style.display, "block");
  },
  async "T10-02"() {
    const r = runtime(); r.activate("A", "current", 2);
    r.run('LANG="ja"; I18N={"panel.call_title":"Retained dictionary"}; activeLifecycle.answered=true; activeLifecycle.dialogId="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; activeLifecycle.leaseDeadline=10000; heartbeatLifecycle(activeLifecycle); start();');
    assert.strictEqual(pending(r, "/state").length, 1, "startup state does not wait for locale");
    await reply(r, "/api/panel/call-info", info);
    for (let i = 0; i < 5; i++) {
      if (i) r.advance(1000);
      await reply(r, "/state", { doors: [{ id: "A", call_id: "current", stage_revision: 2, call_state: "in_call", dialog_owner: "mine" }] });
      if (pending(r, "/api/panel/call-lifecycle").length)
        await reply(r, "/api/panel/call-lifecycle", { ok: true, dialog_owner: "mine",
          call_id: "current", stage_revision: 2, lease_remaining_ms: 10000 });
    }
    assert.strictEqual(r.run('t("panel.call_title")'), "Retained dictionary", "failed locale retains valid dictionary");
    assert.strictEqual(r.run("LANG"), "ja");
    assert(r.requests.filter(x => x.url === "/api/panel/call-lifecycle").length >= 2, "locale cannot block existing heartbeat invocation");
    assert.strictEqual(r.requests.filter(x => x.url === "/locale/en.json").length, 1, "unchanged failed language is not polled every second");
    assert.strictEqual(r.emergencyUpdates.length, 5);
    r.run('ensureLanguage("zh")');
    await reply(r, "/locale/zh.json", { invalid: 42 });
    assert.strictEqual(r.run('t("panel.call_title")'), "Retained dictionary", "malformed locale cannot replace valid language");
  },
  async "T10-03"() {
    const r = runtime();
    r.run('I18N={"panel.state_stale":"Last update {sec}s ago","panel.state_waiting":"Waiting"}; load();');
    await reply(r, "/api/panel/call-info", info); await reply(r, "/state", state(true));
    for (let i = 0; i < 3; i++) { r.advance(2000); await reply(r, "/state", {}, 503); }
    assert.strictEqual(r.emergencyUpdates.length, 1, "failed reads never clear or synthesize SOS");
    assert.strictEqual(r.emergencyUpdates[0].emergency.active, true);
    assert.strictEqual(r.elements.get("offlineBand").style.display, "block");
    assert.strictEqual(r.elements.get("offlineBand").textContent, "Last update 6s ago", "stale age uses the last successful monotonic sample");
    r.advance(1000); await reply(r, "/state", state(false));
    assert.strictEqual(r.elements.get("offlineBand").style.display, "none");
    assert.strictEqual(r.emergencyUpdates[1].emergency.active, false);
    r.advance(1000);
    const blackhole = pending(r, "/state")[0];
    assert.strictEqual(blackhole.xhr.timeout, 3000);
    r.advance(3000);
    assert.strictEqual(blackhole.xhr.aborted, true);
    assert.strictEqual(r.elements.get("offlineBand").style.display, "block");
    r.advance(1000); await reply(r, "/state", state(false));
    assert.strictEqual(r.elements.get("offlineBand").style.display, "none");
  },
  async "T10-04"() {
    const r = runtime(); r.run('LANG="ja"; start();');
    const retired = r.requests.slice();
    r.listeners.pagehide(); assert.strictEqual(r.timers.size, 0, "closed page has no polling/watchdog timers");
    r.listeners.pageshow();
    const successors = r.requests.filter(x => !retired.includes(x));
    assert(successors.some(x => x.url === "/state"), "restored page immediately queries authority even with hung locale");
    assert(retired.filter(x => x.xhr).every(x => x.xhr.aborted), "all retired XHR lanes are cancelled");
    for (const old of retired) {
      await old.response.resolve({ ok: true, status: 200, json: async () => old.url === "/state" ? state(true) : { old: "retired" } });
    }
    await flush();
    assert.strictEqual(r.emergencyUpdates.length, 0, "old page cannot update replacement");
    await reply(r, "/state", state(false)); await reply(r, "/api/panel/call-info", info);
    await reply(r, "/locale/en.json", { "panel.call_title": "Current" });
    assert.strictEqual(r.run("LANG"), "en");
    assert.strictEqual(r.emergencyUpdates.length, 1);
    for (let i = 0; i < 3; i++) {
      r.listeners.pagehide(); assert.strictEqual(r.timers.size, 0);
      r.listeners.pageshow(); assert(r.timers.size <= 3, "at most three lane watchdogs/timers");
    }
    r.context.document.hidden = true; r.listeners.visibilitychange();
    assert.strictEqual(r.timers.size, 0, "hidden page retires all read timers");
    r.context.document.hidden = false; r.listeners.visibilitychange();
    assert.strictEqual(pending(r, "/state").length, 1, "foreground return reacquires authoritative state");
    assert.strictEqual(r.elements.get("offlineBand").style.display, "block", "old success is stale until foreground refresh completes");
  }
};
(async () => {
  for (const [id, test] of Object.entries(tests)) {
    if (process.argv[2] && process.argv[2] !== id) continue;
    await test(); console.log(id + " production page: PASS");
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
