"use strict";
const assert = require("assert");
const { runtime } = require("./call_page_fixture.js");
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function fixture() {
  const r = runtime(), instances = [];
  r.context.JsSIP = {
    WebSocketInterface: function (url) { this.url = url; },
    UA: function (config) {
      this.config = config; this.events = {}; this.retained = {}; this.running = false;
      this.on = (name, fn) => { this.events[name] = fn; this.retained[name] = fn; };
      this.removeListener = (name, fn) => { if (this.events[name] === fn) delete this.events[name]; };
      this.emit = (name, event = {}) => { if (this.events[name]) this.events[name](event); };
      this.start = () => { this.running = true; };
      this.unregister = () => { this.unregisterCount = (this.unregisterCount || 0) + 1; };
      this.transport = { isConnected: () => this.running, disconnect: () => {
        this.running = false; this.emit("disconnected");
      } };
      this.stop = () => { this.stopCount = (this.stopCount || 0) + 1;
        if (!this.holdStop) this.transport.disconnect(); };
      instances.push(this);
    }
  };
  r.run('ua=null; registered=false; I18N={"panel.registered":"Registered {extension}","panel.config_pending":"Pending","panel.config_applying":"Applying {target}","panel.config_apply_failed":"Failed {target}; current {current}","panel.config_revoked":"Revoked"};');
  async function info(generation, user = generation, extra = {}, status = 200) {
    r.run("loadCallInfo()");
    const request = r.requests.filter(x => x.url === "/api/panel/call-info" && !x.completed && !x.xhr.aborted).pop();
    assert(request, "missing production call-info request"); request.completed = true;
    await request.response.resolve({ status, json: async () => ({ ok: status === 200,
      webrtc: Object.assign({config_generation:generation, ws_url:"ws://localhost", sip_user:user,
        sip_pass_ref:"secret:test", sip_pass:"test-password", server:"localhost"}, extra), doors:{} }) });
    await flush(); r.advance(0); await flush();
  }
  return { r, instances, info };
}
const tests = {
  async "T14-01"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    await info("g2", "261", {ws_url:"ws://new-gateway"});
    assert.strictEqual(instances.length, 2, "Idle configuration change must replace the UA");
    assert.strictEqual(instances.filter(x => x.running).length, 1, "Only one UA may remain active");
    assert.strictEqual(instances[0].stopCount, 1); assert.strictEqual(instances[0].unregisterCount, 1);
    assert.notStrictEqual(r.elements.get("regState").textContent, "Registered 261", "New extension cannot be shown as registered before ACK");
    instances[1].emit("registered");
    assert.strictEqual(r.elements.get("regState").textContent, "Registered 261");
    assert.strictEqual(r.run("applied_generation === desired_config_generation"), true);
  },
  async "T14-02"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    const session = r.activate("A", "call-1", 1);
    await info("g2", "261"); await info("g3", "262");
    assert.strictEqual(session.terminated, 0, "Ordinary config changes cannot interrupt an active call");
    assert.strictEqual(instances.length, 1); assert.strictEqual(r.run("webrtc.sip_user"), "260", "Active call retains its applied config");
    assert.strictEqual(r.elements.get("connectionBand").textContent, "Pending");
    r.run('endCall("local_hangup")'); r.advance(0); await flush();
    assert.strictEqual(instances.length, 2); assert(instances[1].config.uri.includes("262@"));
    instances[1].emit("registered"); assert.strictEqual(r.run("webrtc.sip_user"), "262");
  },
  async "T14-03"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    const old = instances[0]; await info("g2", "261");
    assert.strictEqual(instances.length, 2, "A new generation needs a distinct UA");
    instances[1].emit("registered");
    for (const name of ["connected", "registered", "unregistered", "registrationFailed", "disconnected"])
      if (old.retained[name]) old.retained[name]({cause:"late old error"});
    assert.strictEqual(r.run("registered"), true, "Retired callbacks cannot clear current registration");
    assert.strictEqual(r.elements.get("regState").textContent, "Registered 261");
    assert.strictEqual(Object.keys(old.events).length, 0, "Retired UA listeners must detach");
  },
  async "T14-04"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].holdStop = true;
    await info("g2", "261"); await info("g3", "262"); await info("g4", "263");
    r.advance(2200); await flush(); r.advance(0); await flush();
    assert.strictEqual(instances.length, 2, "Slow retirement must coalesce changes into one successor");
    assert(instances[1].config.uri.includes("263@"), "Only latest desired configuration may start");
    instances[0].retained.registered();
    assert.strictEqual(r.run("registered"), false, "Late initial registration cannot apply the retired generation");
    instances[1].emit("registered");
    assert.strictEqual(r.run("applied_generation === desired_config_generation"), true);
    assert.strictEqual(instances.filter(x => x.running).length, 1);
  },
  async "registration failures remain bounded"() {
    const {r, instances, info} = fixture();
    await info("g1", "260");
    r.advance(10000); await flush();
    assert.strictEqual(instances[0].running, false, "Registration timeout closes its UA");
    for (let i = 0; i < 3; i++) await info("g1", "260");
    assert.strictEqual(instances.length, 1, "Polling cannot retry a failed generation indefinitely");
    assert.strictEqual(r.elements.get("connectionBand").textContent, "Failed 260; current —");
    await info("g2", "261"); instances[1].emit("registered");
    assert.strictEqual(r.run("registered"), true);
  },
  async "explicit revocation overrides active-call deferral"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    const session = r.activate("A", "current", 1);
    await info("g2", "261");
    await info("ignored", "262", {}, 503);
    assert.strictEqual(session.terminated, 0, "Transient config failure keeps active media");
    await info("ignored", "262", {}, 403);
    assert.strictEqual(session.terminated, 1, "Explicit permission denial ends the active call");
    assert.strictEqual(instances.length, 1, "Revocation cannot start the pending UA");
    assert.strictEqual(instances[0].running, false);
    assert.strictEqual(r.elements.get("connectionBand").textContent, "Revoked");
  },
  async "registration error preserves an existing call"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    const session = r.activate("A", "current", 1);
    instances[0].emit("registrationFailed", {cause:"network"});
    assert.strictEqual(session.terminated, 0);
    assert.strictEqual(instances[0].running, true, "Re-registration failure must not stop active media");
    r.run('endCall("local_hangup")');
    assert.strictEqual(instances[0].running, false);
    assert.strictEqual(instances.length, 1, "Failed generation has no automatic UA storm");
  },
  async "credential and reference changes participate in identity"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered");
    await info("g1", "260", {sip_pass:"rotated-password"});
    assert.strictEqual(instances.length, 2, "Resolved secret changes must be observed even on an old server");
    instances[1].emit("registered");
    await info("g1", "260", {sip_pass:"rotated-password", sip_pass_ref:"secret:replacement"});
    assert.strictEqual(instances.length, 3, "Credential reference is part of identity");
    const old = instances[2]; r.listeners.pagehide();
    assert.strictEqual(r.timers.size, 0, "Page close clears request, registration and retirement timers");
    old.retained.registered();
    assert.strictEqual(r.run("registered"), false, "Closed page ignores late registration");
  },
  async "failed transport retirement never overlaps a successor"() {
    const {r, instances, info} = fixture();
    await info("g1", "260"); instances[0].emit("registered"); instances[0].holdStop = true;
    instances[0].transport.disconnect = () => { throw new Error("Controlled disconnect failure"); };
    await info("g2", "261"); r.advance(2200); await flush();
    await info("g3", "262");
    assert.strictEqual(instances.length, 1, "Unknown transport state must block a second UA");
    assert.strictEqual(r.elements.get("connectionBand").textContent, "Failed 262; current 260");
  }
};
(async () => {
  for (const [id, test] of Object.entries(tests)) {
    if (process.argv[2] && process.argv[2] !== id) continue;
    await test(); console.log(id + " production UA generation: PASS");
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
