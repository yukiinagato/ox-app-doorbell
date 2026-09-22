"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const source = fs.readFileSync(path.join(__dirname, "../panel/runtime.js"), "utf8");

function fixture(options = {}) {
  let now = 0, nextId = 0;
  const timers = new Map(), requests = [];
  const root = {
    setTimeout(fn, delay) { const id = ++nextId; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    XMLHttpRequest: function () {
      requests.push(this);
      this.headers = {}; this.aborts = 0; this.status = 0; this.readyState = 0;
      this.open = (method, url, async) => { Object.assign(this, { method, url, async }); };
      this.setRequestHeader = (name, value) => { this.headers[name] = value; };
      this.send = body => {
        this.body = body;
        if (options.sendThrows) throw new Error("fixture transport failure");
        if (options.syncResponse) this.respond(200, '{"ok":true}');
      };
      this.abort = () => { this.aborts++; if (this.onabort) this.onabort(); };
      this.respond = (status, text) => {
        this.status = status; this.responseText = text; this.readyState = 4;
        const ready = this.onreadystatechange, loaded = this.onload;
        if (ready) ready();
        if (loaded) loaded();
      };
      if (options.noNativeTimeout) Object.defineProperty(this, "timeout", {
        set() { throw new Error("fixture legacy timeout setter"); }
      });
    }
  };
  const context = vm.createContext({ window: root, AbortController: undefined, Promise: undefined,
    fetch: undefined });
  vm.runInContext(source, context);
  return { api: root.DoorbellPanelRuntime, timers, requests,
    advance(ms) {
      now += ms;
      for (const [id, timer] of Array.from(timers)) {
        if (timer.at <= now) { timers.delete(id); timer.fn(); }
      }
    }
  };
}

{
  const f = fixture(), lane = f.api.createRequestLane(), results = [];
  const handle = lane.start({ url: "/api/panel/call-info", deadline_ms: 4000 }, r => results.push(r));
  assert.strictEqual(f.requests[0].timeout, 4000, "the real XHR timeout must be configured");
  assert.strictEqual(lane.pending(), true);
  assert.strictEqual(lane.start({ url: "/duplicate" }), null, "one lane admits only one request");
  f.advance(3999);
  assert.strictEqual(results.length, 0);
  f.advance(1);
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].kind, "timeout");
  assert.strictEqual(results[0].outcome_unknown, false);
  assert.strictEqual(handle.pending(), false);
  assert.strictEqual(lane.pending(), false);
  assert.strictEqual(f.requests[0].aborts, 1);
  assert.strictEqual(f.timers.size, 0);
  console.log("T09-01: silent production XHR times out once and releases its lane: PASS");
}
for (const nativeFirst of [true, false]) {
  const f = fixture(), results = [];
  f.api.requestWithDeadline({ url: "/read", deadline_ms: 1000 }, r => results.push(r));
  const nativeTimeout = f.requests[0].ontimeout, watchdog = Array.from(f.timers.values())[0].fn;
  (nativeFirst ? nativeTimeout : watchdog)();
  (nativeFirst ? watchdog : nativeTimeout)();
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].kind, "timeout");
  assert.strictEqual(f.timers.size, 0);
  assert.strictEqual(f.requests[0].aborts, 1);
}
console.log("T09-02: native timeout and watchdog settle once in both orders with no timers: PASS");

{
  const f = fixture(), lane = f.api.createRequestLane(), results = [];
  const first = lane.start({ url: "/old" }, r => results.push(r));
  const xhr = f.requests[0], lateSuccess = xhr.onload, lateError = xhr.onerror;
  lane.cancel();
  const second = lane.start({ url: "/new" }, r => results.push(r));
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].kind, "aborted");
  xhr.status = 200; xhr.responseText = '{"value":"old"}';
  lateSuccess(); lateError(); first.cancel();
  assert.strictEqual(results.length, 1, "late old callbacks cannot publish another result");
  assert.strictEqual(lane.pending(), true, "old completion must not clear the new busy gate");
  assert.strictEqual(second.pending(), true);
  assert.strictEqual(second.generation, first.generation + 1);
  assert.strictEqual(f.timers.size, 1, "only the new watchdog remains");
  f.requests[1].respond(200, '{"value":"new"}');
  assert.strictEqual(results.length, 2);
  assert.strictEqual(results[1].data.value, "new");
  assert.strictEqual(results[1].generation, second.generation);
  assert.strictEqual(lane.pending(), false);
  assert.strictEqual(f.timers.size, 0);
  console.log("T09-03: late cancelled success/error cannot replace or release the successor: PASS");
}

for (const noNativeTimeout of [true, false]) {
  const f = fixture({ noNativeTimeout }), results = [];
  f.api.requestWithDeadline({ url: "/legacy", deadline_ms: 1000 }, r => results.push(r));
  f.advance(1000);
  assert.strictEqual(results[0].kind, "timeout");
  assert.strictEqual(f.timers.size, 0);
  assert.strictEqual(f.requests[0].aborts, 1);
}
console.log("T09-04: no AbortController, Promise or fetch; legacy XHR watchdog remains bounded: PASS");

const classifications = [
  [200, '{"ok":true}', "success", ""],
  [204, "", "success", ""],
  [409, '{"ok":false,"error_code":"stale_owner"}', "http", "stale_owner"],
  [503, "not JSON", "http", ""],
  [200, '{"ok":false,"error_code":"permission_denied"}', "business", "permission_denied"],
  [200, '{"ok":false,"err":"legacy_failure"}', "business", ""],
  [200, '{"error_code":"config_conflict"}', "business", "config_conflict"],
  [200, "{", "parse_error", ""],
  [200, "", "parse_error", ""],
  [0, "", "network", ""]
];
for (const [status, body, kind, errorCode] of classifications) {
  const f = fixture(), results = [];
  f.api.requestWithDeadline({ url: "/result" }, r => results.push(r));
  f.requests[0].respond(status, body);
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].kind, kind);
  assert.strictEqual(results[0].error_code, errorCode);
  assert.strictEqual(f.timers.size, 0);
}

for (const event of ["onerror", "onabort", "ontimeout"]) {
  const f = fixture(), results = [];
  const options = { url: "/write", method: "post", headers: { "Content-Type": "application/json" },
    body: '{"operation_id":"test-only"}', generation: 7, deadline_ms: 1500 };
  const handle = f.api.requestWithDeadline(options, r => results.push(r));
  options.generation = 9;
  const xhr = f.requests[0], eventCallback = xhr[event];
  assert.strictEqual(xhr.method, "POST");
  assert.strictEqual(xhr.async, true);
  assert.strictEqual(xhr.timeout, 1500);
  assert.strictEqual(xhr.headers["Content-Type"], "application/json");
  assert.strictEqual(xhr.body, options.body);
  eventCallback(); eventCallback(); handle.cancel();
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].kind, { onerror: "network", onabort: "aborted", ontimeout: "timeout" }[event]);
  assert.strictEqual(results[0].outcome_unknown, true, "local failure must not claim the write was cancelled");
  assert.strictEqual(results[0].generation, 7, "a request freezes its original callback generation");
  assert.strictEqual(f.requests.length, 1, "uncertain writes are never retried by the adapter");
  assert.strictEqual(f.timers.size, 0);
}

{
  const f = fixture(), results = [];
  f.api.requestWithDeadline({ url: "/write", method: "POST" }, r => results.push(r));
  f.requests[0].respond(200, "{");
  assert.strictEqual(results[0].kind, "parse_error");
  assert.strictEqual(results[0].outcome_unknown, true);
  assert.strictEqual(f.requests.length, 1);
  assert.strictEqual(f.timers.size, 0);
}
{
  const f = fixture(), lane = f.api.createRequestLane(), results = [];
  lane.start({ url: "/old" }, result => {
    results.push(result);
    lane.start({ url: "/replacement" }, next => results.push(next));
  });
  lane.cancel();
  assert.strictEqual(lane.pending(), true, "a cancellation callback may start its own successor");
  f.requests[1].respond(200, '{"ok":true}');
  assert.strictEqual(results.length, 2);
  assert.strictEqual(lane.pending(), false);
  assert.strictEqual(f.timers.size, 0);
}

{
  const f = fixture({ sendThrows: true }), lane = f.api.createRequestLane(), results = [];
  const handle = lane.start({ url: "/read" }, r => results.push(r));
  assert.strictEqual(results[0].kind, "network");
  assert.strictEqual(lane.pending(), false);
  assert.strictEqual(handle.pending(), false);
  assert.strictEqual(f.timers.size, 0);
  assert.throws(() => lane.start({ url: "/read", deadline_ms: 0 }), /deadline_ms/);
  assert.strictEqual(lane.pending(), false, "invalid options do not strand the lane");
}
{
  const f = fixture({ syncResponse: true }), lane = f.api.createRequestLane();
  let completions = 0;
  lane.start({ url: "/read" }, () => { completions++; });
  assert.strictEqual(completions, 1);
  assert.strictEqual(lane.pending(), false, "synchronous completion cannot restore a stale busy gate");
  assert.strictEqual(f.timers.size, 0);
}
console.log("request deadline classifications, headers/body, frozen generation and no write retry: PASS");
