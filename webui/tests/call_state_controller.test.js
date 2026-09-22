"use strict";
const assert = require("assert");
const { runtime } = require("./call_page_fixture.js");
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
(async () => {
  {
    const r = runtime(); r.run("load()");
    const state = r.requests.find(request => request.url === "/state");
    await state.response.resolve({ ok: true, status: 200, json: async () => ({ doors: [] }) });
    await flush();
    r.advance(4000); await flush();
    assert.strictEqual(r.run("callInfoPoll.pending"), null,
      "a silent call-info request releases only its own production gate at the deadline");
    assert.strictEqual(r.elements.get("configBand").style.display, "block");
    assert.strictEqual(r.timers.size, 2, "state and call-info each retain one timer or watchdog");
    console.log("T09 retained read deadline under independent scheduling: PASS");
  }
  if (process.argv.includes("--deadline-regression")) return;
  {
    const r = runtime(); r.run("load()");
    const failedState = r.requests.find(request => request.url === "/state");
    await failedState.response.resolve({ ok: false, status: 500, json: async () => ({}) });
    await flush();
    r.requests.splice(0); r.advance(1000); r.respond({ doors: [] }); await flush();
    assert.strictEqual(r.elements.get("offlineBand").style.display, "none",
      "state recovers while the earlier call-info remains pending");
    assert.strictEqual(r.run("statePoll.pending"), null);
    assert.strictEqual(r.run("callInfoPoll.lane.pending()"), true);
    r.advance(3000); await flush();
    assert.strictEqual(r.run("callInfoPoll.lane.pending()"), false);
    console.log("T09 retained early state failure recovery: PASS");
  }
  if (process.argv.includes("--early-state-failure")) return;
  {
    const r = runtime();
    r.run('var heldCallInfo = callInfoPoll.lane.start({url:"/held-call-info",deadline_ms:4000}, function(){}); loadCallInfo();');
    assert.strictEqual(r.run("callInfoPoll.pending"), null,
      "rejected admission must settle instead of leaving the controller pending");
    assert.strictEqual(r.run("heldCallInfo.pending()"), true,
      "a rejected owner cannot cancel another request");
    r.run("heldCallInfo.cancel()");
    assert.strictEqual(r.timers.size, 1);
  }
  {
    const r = runtime(); r.activate("A", "old", 1); r.run("load()");
    const state = r.requests.find(request => request.url === "/state");
    await state.response.resolve({ ok: true, status: 200, json: async () => ({ doors: [
      { id: "A", call_id: "old", stage_revision: 1, call_state: "in_call" }
    ] }) });
    await flush();
    const current = r.activate("B", "new", 2);
    const info = r.requests.find(request => request.url === "/api/panel/call-info");
    await info.response.resolve({ ok: true, status: 200, json: async () => ({ webrtc: {}, doors: {} }) });
    await flush();
    assert.strictEqual(r.run("selected.id"), "B", "late config cannot reproject an old call snapshot over a new selection");
    assert.strictEqual(r.run("session"), current);
    assert.strictEqual(current.terminated, 0);
  }
  for (const state of ["in_call", "cancelled", "ended", "expired"]) {
    const r = runtime();
    r.activate("A", "call-A", 1);
    const pending = r.run("load()");
    const current = r.activate("B", "call-B", 2);
    r.respond({ doors: [{ id: "A", call_id: "call-A", stage_revision: 1,
      call_state: state, dialog_owner: "other" }, { id: "B", call_id: "call-B", stage_revision: 2 }] });
    await flush();
    assert.strictEqual(r.run("selected.id"), "B");
    assert.strictEqual(r.run("session"), current);
    assert.strictEqual(current.terminated, 0, "late A cannot terminate B");
    assert.strictEqual(r.timers.size, 2, "each independent read schedules only one successor");
  }
  for (const stale of [{ call_id: "old", stage_revision: 9 }, { call_id: "current", stage_revision: 1 }]) {
    const r = runtime(), current = r.activate("A", "current", 2);
    const pending = r.run("load()");
    r.respond({ doors: [{ id: "A", ...stale, call_state: "ended", dialog_owner: "other" }] });
    await flush();
    assert.strictEqual(current.terminated, 0, "an old call or revision has no authority over the session");
  }
  {
    const r = runtime(), current = r.activate("A", "current", 2);
    const pending = r.run("load()");
    r.respond({ doors: [{ id: "A", call_id: "current", stage_revision: 2,
      call_state: "in_call", dialog_owner: "other" }] });
    await flush();
    assert.strictEqual(current.terminated, 1, "a current winning owner still ends the losing session");
    assert.strictEqual(r.run("session"), null);
  }
  {
    const r = runtime(); r.activate("A", "old", 1);
    r.run('LANG="ja"');
    const pending = r.run("load()");
    r.respond({ doors: [{ id: "A", call_id: "old", stage_revision: 1 }] });
    for (let i = 0; i < 8; i++) await Promise.resolve();
    const locale = r.requests.find(request => request.url === "/locale/en.json");
    assert(locale, "language request runs independently of state");
    const current = r.activate("B", "new", 2);
    locale.response.resolve({ ok: true, json: async () => ({ stale: "dictionary" }) });
    await flush();
    assert.strictEqual(r.run("session"), current);
    assert.strictEqual(r.run("LANG"), "ja", "old language completion has no authority over the page");
    assert.strictEqual(r.run("selected.id"), "B");
  }
  {
    const r = runtime(); r.activate("A", "current", 2);
    const pending = r.run("load()");
    r.listeners.pagehide();
    r.respond({ doors: [{ id: "A", call_id: "current", stage_revision: 2 }] });
    await flush();
    assert.strictEqual(r.timers.size, 0, "retired pages cannot resurrect polling");
    assert.strictEqual(r.run("session"), null);
  }
  {
    const r = runtime();
    const overlay = r.run("emergencyOverlay");
    r.run("installEmergency(); installEmergency();");
    assert.strictEqual(r.run("emergencyOverlay"), overlay,
      "restoring a cached page reuses its SOS controls and event listeners");
  }
  console.log("call state controller tests: ok");
})().catch(error => { console.error(error); process.exitCode = 1; });
