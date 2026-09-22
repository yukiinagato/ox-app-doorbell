"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const source = fs.readFileSync(path.join(__dirname, "../panel/runtime.js"), "utf8");
const id = "a".repeat(32), authority = "b".repeat(32), csrf = "c".repeat(32);

function fixture(page, storage = new Map()) {
  let now = 0, counter = 0;
  const requests = [], timers = new Map(), events = {}, notices = [];
  class Element {
    constructor(tag) { this.tagName = tag; this.children = []; this.style = {}; this.attributes = {}; this.events = {}; this.disabled = false; this.text = ""; }
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; }
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); return child; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    getAttribute(key) { return this.attributes[key] || null; }
    get firstChild() { return this.children[0]; }
    get textContent() { return this.text + this.children.map(child => child.textContent).join(""); }
    set textContent(value) { this.text = String(value); this.children = []; }
    get innerHTML() { return this.textContent; }
    set innerHTML(value) {
      this.children = []; this.text = "";
      const stack = [this], tokens = value.match(/<[^>]+>|[^<]+/g) || [];
      for (const token of tokens) {
        if (token.startsWith("</")) { stack.pop(); continue; }
        if (token.startsWith("<")) {
          const child = new Element(token.match(/^<([\w]+)/)[1]);
          const cls = token.match(/class=['"]([^'"]+)/); if (cls) child.className = cls[1];
          stack[stack.length - 1].appendChild(child); stack.push(child);
        } else stack[stack.length - 1].appendChild({ textContent: token });
      }
    }
    getElementsByTagName(tag) {
      const all = []; for (const child of this.children) { if (child.tagName === tag) all.push(child); if (child.getElementsByTagName) all.push(...child.getElementsByTagName(tag)); } return all;
    }
    addEventListener(name, fn) { (this.events[name] || (this.events[name] = [])).push(fn); }
    fire(name, value = {}) { if (this.disabled) return; (this.events[name] || []).forEach(fn => fn(Object.assign({ preventDefault() {} }, value))); }
  }
  const document = { body: new Element("body"), head: new Element("head"), createElement: tag => new Element(tag), createTextNode: value => ({ textContent: String(value) }) };
  document.getElementsByClassName = name => document.body.getElementsByTagName("div").concat(document.body.getElementsByTagName("button")).filter(el => (el.className || "").split(" ").includes(name));
  const root = { document, navigator: {}, sessionStorage: {
    getItem: key => storage.get(key) || null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)
  }, location: { pathname: "/panel/" + (page || "call") },
    addEventListener(name, fn) { events[name] = fn; },
    performance: { now: () => now },
    setTimeout(fn, delay) { const token = ++counter; timers.set(token, { fn, at: now + delay }); return token; },
    clearTimeout(token) { timers.delete(token); },
    XMLHttpRequest: function () {
      requests.push(this); this.headers = {}; this.status = 0; this.readyState = 0;
      this.open = (method, url) => Object.assign(this, { method, url });
      this.setRequestHeader = (name, value) => { this.headers[name] = value; };
      this.send = body => { this.body = body; };
      this.abort = () => { this.aborted = true; if (this.onabort) this.onabort(); };
      this.respond = (status, data) => {
        this.status = status; this.responseText = typeof data === "string" ? data : JSON.stringify(data); this.readyState = 4;
        const loaded = this.onload, ready = this.onreadystatechange; if (ready) ready(); if (loaded) loaded();
      };
    }
  };
  const context = vm.createContext({ window: root, document, console });
  vm.runInContext(source, context);
  let overlay;
  if (page) {
    const html = fs.readFileSync(path.join(__dirname, "../panel/" + page + ".html"), "utf8");
    const indent = page === "call" ? "" : "  ";
    const functionSource = name => html.match(new RegExp("function " + name + "\\(\\) \\{[\\s\\S]*?\\n" + indent + "\\}(?=\\n)"))[0];
    const install = functionSource("installEmergency");
    const translate = functionSource("applyEmergencyI18n");
    Object.assign(context, { DoorbellPanelRuntime: root.DoorbellPanelRuntime, emergencyOverlay: null, t: key => key, esc: value => value });
    vm.runInContext(translate + "\n" + install + "\ninstallEmergency();", context);
    overlay = context.emergencyOverlay;
  } else overlay = root.DoorbellPanelRuntime.installEmergencyOverlay({ translate: key => key, onTriggerResult: (ok, status, result) => notices.push(result) });
  function advance(ms) {
    now += ms;
    for (const [token, timer] of Array.from(timers)) if (timer.at <= now) { timers.delete(token); timer.fn(); }
  }
  return { overlay, requests, timers, advance, events, notices, document,
    begin() { overlay.hold.start(); advance(2000); },
    session() { assert.strictEqual(requests.at(-1).url, "/api/panel/session"); requests.at(-1).respond(200, { ok: true, csrf_token: csrf }); },
    prepare() {
      const request = requests.at(-1); assert.strictEqual(request.url, "/api/operations/prepare");
      assert.deepStrictEqual(JSON.parse(request.body), { schema_version: 2, action: "sos_start", parameters: {} });
      assert.strictEqual(request.headers["X-Doorbell-CSRF"], csrf);
      request.respond(200, { schema_version: 2, ok: true, operation_id: id, authority_node: authority,
        execution_state: "prepared", config_generation: "opaque", prepared_remaining_ms: 30000 });
    },
    action() { const button = document.getElementsByClassName("dbSosOperationAction")[0]; assert(button); button.fire("click"); },
    message() { return document.getElementsByClassName("dbSosOperation")[0].textContent; }
  };
}
const cases = [];
function test(name, run) { cases.push([name, run]); }
function record(state) { return { schema_version: 2, ok: true, operation_id: id, authority_node: authority, execution_state: state, config_generation: "opaque", prepared_remaining_ms: 25000 }; }

test("T12-01: silent execute reaches a real deadline and exposes an unknown result", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare();
  const send = f.requests.at(-1); assert.strictEqual(send.timeout, 4000);
  f.advance(4000);
  assert.strictEqual(f.overlay.operationState().phase, "unknown");
  assert.strictEqual(send.aborted, true);
  assert.strictEqual(f.overlay.trigger().disabled, false);
  assert(f.message().includes("emergency.sos_unknown"));
  assert(f.message().includes("emergency.sos_alternative"));
  assert.strictEqual(f.timers.size, 0);
  assert.strictEqual(f.overlay.state().active, false, "unknown must not manufacture replicated SOS state");
});
test("T12-02: accepted response lost; repeated recovery queries only the original intent", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare(); f.advance(4000);
  f.action(); const query = f.requests.at(-1);
  assert.strictEqual(query.method, "GET");
  assert.strictEqual(query.headers["X-Doorbell-CSRF"], csrf);
  assert.strictEqual(query.url, "/api/operations/" + id + "?authority_node=" + authority + "&action=sos_start");
  query.respond(200, record("dispatched"));
  assert.strictEqual(f.overlay.operationState().phase, "accepted");
  f.action(); f.requests.at(-1).respond(200, record("dispatched"));
  assert.strictEqual(f.requests.filter(r => r.url === "/api/operations/prepare").length, 1);
  assert.strictEqual(f.requests.filter(r => r.url.endsWith("/execute")).length, 1);
  assert(f.message().includes("emergency.sos_accepted"));
});
test("T12-03: permission, validation, and authentication failures remain actionable", () => {
  for (const [status, code, key] of [[403, "permission_denied", "emergency.sos_permission_denied"], [400, "invalid_request", "emergency.sos_invalid"], [401, "auth_required", "emergency.sos_auth_required"]]) {
    const f = fixture(); f.begin(); f.session(); f.requests.at(-1).respond(status, { ok: false, error_code: code });
    assert.strictEqual(f.overlay.operationState().phase, "rejected");
    assert.strictEqual(f.overlay.trigger().disabled, false); assert(f.message().includes(key));
    f.action(); assert.strictEqual(f.overlay.operationState().busy, true);
  }
});
test("T12-04: double activation and native timeout/watchdog/late success settle once", () => {
  const f = fixture(); f.begin(); f.overlay.hold.start(); f.advance(2000);
  assert.strictEqual(f.requests.length, 1); f.session(); f.prepare();
  const send = f.requests.at(-1), nativeTimeout = send.ontimeout, lateSuccess = send.onload;
  const watchdog = Array.from(f.timers.values())[0].fn;
  nativeTimeout(); watchdog(); f.action();
  send.status = 202; send.responseText = JSON.stringify(record("dispatched")); lateSuccess();
  assert.strictEqual(f.overlay.operationState().phase, "querying");
  assert.strictEqual(f.requests.filter(r => r.url.endsWith("/execute")).length, 1);
  assert.strictEqual(f.notices.filter(r => r.phase === "unknown").length, 1);
  const deliveries = f.notices.length;
  f.overlay.refreshText(); f.overlay.refreshText();
  assert.strictEqual(f.notices.length, deliveries, "language repaint must not redeliver an operation result");
  f.requests.at(-1).respond(200, record("dispatched")); assert.strictEqual(f.timers.size, 0);
});
test("prepared query requires explicit same-handle execution, with no second preparation", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare(); f.advance(4000); f.action();
  f.requests.at(-1).respond(200, record("prepared"));
  assert.strictEqual(f.overlay.operationState().phase, "not_started");
  assert.strictEqual(f.requests.filter(r => r.url.endsWith("/execute")).length, 1);
  f.action(); assert.strictEqual(JSON.parse(f.requests.at(-1).body).operation_id, id);
  f.requests.at(-1).respond(202, record("unknown_after_dispatch")); f.action();
  assert.strictEqual(f.requests.at(-1).method, "GET");
  assert.strictEqual(f.requests.filter(r => r.url === "/api/operations/prepare").length, 1);
});
test("server 500, network and malformed write replies never imply not started", () => {
  for (const failure of [r => r.respond(500, { ok: false }), r => r.onerror(), r => r.respond(200, "invalid json")]) {
    const f = fixture(); f.begin(); f.session(); f.prepare(); failure(f.requests.at(-1));
    assert.strictEqual(f.overlay.operationState().phase, "unknown"); f.action(); assert.strictEqual(f.requests.at(-1).method, "GET");
  }
});
test("page retirement cancels its request, retains the handle, and ignores late completion", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare(); const send = f.requests.at(-1), late = send.onload;
  f.events.pagehide(); assert.strictEqual(f.timers.size, 0); assert.strictEqual(send.aborted, true);
  send.status = 202; send.responseText = JSON.stringify(record("dispatched")); late();
  assert.strictEqual(f.overlay.operationState().phase, "unknown"); f.action(); assert.strictEqual(f.requests.at(-1).method, "GET");
});
test("all production page integrations visibly render translated SOS outcomes", () => {
  for (const page of ["door", "monitor", "call"]) {
    const f = fixture(page); f.begin(); f.session(); f.prepare(); f.advance(4000);
    assert(f.message().includes("emergency.sos_unknown"), page);
    assert(f.message().includes("emergency.sos_query"), page);
    f.overlay.update({ emergency: { active: true } });
    assert.strictEqual(f.overlay.state().active, true);
    f.overlay.update({}); assert.strictEqual(f.overlay.state().active, true);
    f.overlay.update({ emergency: { active: false } }); assert.strictEqual(f.overlay.state().active, false);
  }
});
test("silent preparation never executes or automatically creates another intent", () => {
  const f = fixture(); f.begin(); f.session(); f.advance(4000);
  assert.strictEqual(f.overlay.operationState().phase, "unknown");
  assert.strictEqual(f.overlay.operationState().operation_id, "");
  assert(f.message().includes("emergency.sos_prepare_unknown"));
  assert.strictEqual(f.requests.filter(r => r.url.endsWith("/execute")).length, 0);
  assert.strictEqual(f.requests.filter(r => r.url === "/api/operations/prepare").length, 1);
  f.advance(60000); assert.strictEqual(f.requests.length, 2);
  f.action(); assert.strictEqual(f.requests.filter(r => r.url === "/api/operations/prepare").length, 2);
});
test("only authoritative unstarted states permit a new preparation", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare();
  f.requests.at(-1).respond(503, { ok: false, error_code: "not_started" });
  assert.strictEqual(f.overlay.operationState().phase, "not_started");
  f.action(); assert.strictEqual(f.requests.at(-1).method, "GET");
  f.requests.at(-1).respond(200, record("expired_not_started"));
  f.action(); assert.strictEqual(f.requests.at(-1).url, "/api/operations/prepare");
});
test("a denied status query retains the ambiguous original handle", () => {
  const f = fixture(); f.begin(); f.session(); f.prepare(); f.advance(4000); f.action();
  f.requests.at(-1).respond(403, { ok: false, error_code: "permission_denied" });
  assert.strictEqual(f.overlay.operationState().phase, "unknown");
  assert.strictEqual(f.overlay.operationState().operation_id, id);
  assert(f.message().includes("emergency.sos_permission_denied"));
  f.action(); f.session(); assert.strictEqual(f.requests.at(-1).method, "GET");
  assert(f.requests.at(-1).url.includes(id));
});
test("assistive button activation shares one intent, and authoritative clear permits a later SOS", () => {
  const f = fixture(); f.overlay.trigger().fire("click", { detail: 0 });
  assert.strictEqual(f.requests.length, 1); f.session(); f.prepare();
  f.requests.at(-1).respond(202, record("dispatched"));
  f.overlay.update({ emergency: { active: true } });
  assert.strictEqual(f.overlay.trigger().disabled, true);
  f.overlay.update({ emergency: { active: false } });
  assert.strictEqual(f.overlay.operationState().phase, "idle");
  f.overlay.trigger().fire("click", { detail: 0 });
  assert.strictEqual(f.requests.at(-1).url, "/api/operations/prepare");
});
test("page reload recovers the persisted handle by query without another SOS", () => {
  const storage = new Map(), first = fixture(null, storage);
  first.begin(); first.session(); first.prepare(); first.events.pagehide();
  const restored = fixture(null, storage);
  assert.strictEqual(restored.overlay.operationState().phase, "unknown");
  assert.strictEqual(restored.overlay.operationState().operation_id, id);
  assert.strictEqual(restored.requests.length, 0);
  restored.action(); restored.session();
  assert.strictEqual(restored.requests.at(-1).method, "GET");
  assert(restored.requests.at(-1).url.includes(id));
  assert.strictEqual(restored.requests.filter(r => r.url === "/api/operations/prepare").length, 0);
});
let failures = 0;
for (const [name, run] of cases) { try { run(); console.log(name + ": PASS"); } catch (error) { failures++; console.error(name + ": FAIL\n" + error.stack); } }
if (failures) process.exitCode = 1;
