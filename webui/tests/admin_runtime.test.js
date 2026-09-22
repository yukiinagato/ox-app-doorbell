"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

class Element {
  constructor() {
    const classes = new Set();
    this.classList = { add(name) { classes.add(name); }, remove(name) { classes.delete(name); },
      contains(name) { return classes.has(name); } };
    this.style = {}; this.attributes = {};
    this.parentNode = null; this.children = []; this.textContent = ""; this.innerHTML = "";
    this.value = ""; this.disabled = false;
  }
  addEventListener() {}
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  removeChild(child) { child.parentNode = null; }
  setAttribute(key, value) { this.attributes[key] = value; }
  getAttribute(key) { return this.attributes[key] || ""; }
  querySelector() { return new Element(); }
  querySelectorAll() { return []; }
  pause() {}
  play() { return Promise.resolve(); }
}

function makeRuntime(options) {
  options = options || {};
  const elements = new Map();
  const document = {
    body: new Element(), activeElement: null,
    documentElement: { getAttribute() { return ""; }, removeAttribute() {}, setAttribute() {} },
    createElement() { return new Element(); },
    querySelector(selector) {
      if (!elements.has(selector)) elements.set(selector, new Element());
      return elements.get(selector);
    }, querySelectorAll() { return []; }
  };
  let nextTimer = 1;
  const timers = new Map(), listeners = {};
  const server = { login: options.login || { status: 401, body: { ok: false } },
    status: options.status === undefined ? 200 : options.status,
    config: options.config === undefined ? 200 : options.config,
    deferred: new Set(options.deferred || []), requests: [], pending: [], throwSend: new Set() };
  function responseFor(url) {
    if (url === "/locale/en.json") return [200, JSON.parse(
      fs.readFileSync(path.join(__dirname, "../locale/en.json"), "utf8"))];
    if (url === "/api/login") return [server.login.status, server.login.body];
    if (url === "/api/session") return [server.status, { csrf_token: "test-csrf" }];
    if (url === "/api/config/snapshot") return [server.config, { schema_version: 2, revision: "fixture-revision", config: {} }];
    if (url === "/api/status") return [server.status, { node: { id: "test" } }];
    if (url === "/api/pairing") return [200, { state: "unpaired", pending: { devices: [] } }];
    return [200, { ok: true }];
  }
  class Xhr {
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(key, value) { (this.headers || (this.headers = {}))[key] = value; }
    send() {
      server.requests.push({ method: this.method, url: this.url, xhr: this });
      if (server.throwSend.has(this.url)) throw new Error("send failed");
      if (server.deferred.has(this.url)) { server.pending.push(this); return; }
      const response = responseFor(this.url); this.respond(response[0], response[1]);
    }
    abort() {
      this.status = 0; this.readyState = 4;
      if (this.onreadystatechange) this.onreadystatechange();
      if (this.onabort) this.onabort();
    }
    respond(status, body) {
      this.status = status; this.responseText = JSON.stringify(body); this.readyState = 4;
      if (this.onreadystatechange) this.onreadystatechange();
      if (this.onerror) this.onerror(); // Duplicate browser notifications must settle once.
    }
  }
  const streams = [];
  const navigator = { mediaDevices: { getUserMedia() {
    const deferred = { ok: null, fail: null, then(ok, fail) { this.ok = ok; this.fail = fail; } };
    streams.push(deferred); return deferred;
  } } };
  const hooks = {};
  const window = {
    location: { search: "?lang=en" }, isSecureContext: true, navigator,
    __DOORBELL_TEST_HOOKS: hooks, confirm() { return true; },
    BarcodeDetector: class { detect() {
      return options.detect ? options.detect() : Promise.resolve([]);
    } },
    addEventListener(name, fn) { (listeners[name] || (listeners[name] = [])).push(fn); },
    setTimeout(fn) { const id = nextTimer++; timers.set(id, { fn, repeat: false }); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn) { const id = nextTimer++; timers.set(id, { fn, repeat: true }); return id; },
    clearInterval(id) { timers.delete(id); }
  };
  const context = { window, document, navigator, XMLHttpRequest: Xhr,
    localStorage: { getItem() { return null; }, setItem() {} }, console, Promise,
    setTimeout: window.setTimeout, clearTimeout: window.clearTimeout,
    setInterval: window.setInterval, clearInterval: window.clearInterval, Date, JSON, RegExp };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8"), context);
  return {
    elements, hooks, server, streams, timers, window,
    respond(url, status, body) {
      const index = server.pending.findIndex((xhr) => xhr.url === url);
      assert.notStrictEqual(index, -1, `pending request for ${url}`);
      server.pending.splice(index, 1)[0].respond(status, body);
    },
    fire(name, event) { (listeners[name] || []).slice().forEach((fn) => fn(event)); },
    runOneTimer() {
      const entry = timers.entries().next().value;
      assert(entry, "expected a pending timer");
      if (!entry[1].repeat) timers.delete(entry[0]);
      entry[1].fn();
    },
    runLastTimer() {
      const entries = Array.from(timers.entries());
      assert(entries.length, "expected a pending timer");
      const entry = entries[entries.length - 1];
      if (!entry[1].repeat) timers.delete(entry[0]);
      entry[1].fn();
    }
  };
}

function enterPair(runtime) { runtime.hooks.adminRuntime.switchTab("pair"); }

(async function main() {
  {
    const runtime = makeRuntime();
    const button = runtime.elements.get("#loginBtn");
    button.onclick();
    const error = runtime.elements.get("#loginErr");
    assert.strictEqual(error.textContent, "Wrong admin password");
    assert.strictEqual(button.disabled, false);
    runtime.server.login = { status: 429, body: { ok: false, err: "locked" } };
    button.onclick();
    assert.strictEqual(error.textContent, "Admin password entry locked for 10 minutes");
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/config/snapshot"] });
    assert.strictEqual(runtime.timers.size, 1,
      "only the in-flight initialization timeout exists before config/status initialize");
    runtime.respond("/api/config/snapshot", 500, {});
    assert(runtime.timers.size >= 1, "failed initialization schedules a bounded retry");
    assert(runtime.elements.get("#msg").textContent,
      "failed initialization leaves an operator-visible server error");
    runtime.server.deferred.delete("/api/config/snapshot");
    runtime.runLastTimer();
    assert(runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length >= 2,
      "the bounded retry re-enters the production boot path");
    runtime.hooks.adminRuntime.stop();
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/status"] });
    const initialProbes = runtime.server.requests.filter((r) => r.url === "/api/status").length;
    runtime.fire("pagehide");
    runtime.server.deferred.delete("/api/status");
    runtime.fire("pageshow");
    const beforeStale = runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length;
    runtime.respond("/api/status", 401, {});
    assert.strictEqual(runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length, beforeStale,
      "a stale auth probe cannot hide the new page or start another boot");
    assert.strictEqual(initialProbes, 1, "the initial activation creates one effective probe");
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/login"], status: 401 });
    runtime.elements.get("#loginBtn").onclick();
    runtime.fire("pagehide");
    runtime.fire("pageshow");
    runtime.respond("/api/login", 200, { ok: true });
    assert.strictEqual(runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length, 0,
      "a login response from an old page activation cannot boot the new page");
    assert.strictEqual(runtime.elements.get("#loginBtn").disabled, false,
      "retiring a login attempt restores the retained form");
    runtime.elements.get("#loginBtn").onclick();
    assert.strictEqual(runtime.server.requests.filter((r) => r.url === "/api/login").length, 2);
  }

  for (const probeStatus of [200, 401]) {
    const runtime = makeRuntime({ status: 401 });
    runtime.fire("pagehide");
    runtime.server.deferred.add("/api/status");
    runtime.fire("pageshow");
    const probe = runtime.server.pending.shift();
    runtime.server.deferred.delete("/api/status");
    runtime.server.status = 200;
    runtime.server.login = { status: probeStatus === 401 ? 200 : 401,
      body: { ok: probeStatus === 401 } };
    runtime.elements.get("#loginBtn").onclick();
    const before = runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length;
    probe.respond(probeStatus, {});
    assert.strictEqual(runtime.server.requests.filter((r) => r.url === "/api/config/snapshot").length, before,
      "a retired probe cannot boot after a newer login decision");
    assert.strictEqual(runtime.elements.get("#app").classList.contains("hidden"),
      probeStatus !== 401, "a retired probe cannot override login visibility");
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/login"], status: 401 });
    const button = runtime.elements.get("#loginBtn");
    button.onclick();
    runtime.fire("pagehide");
    runtime.fire("pageshow");
    button.onclick();
    runtime.respond("/api/login", 401, {});
    assert.strictEqual(button.disabled, true, "old completion cannot enable the new attempt");
    runtime.respond("/api/login", 401, {});
    assert.strictEqual(button.disabled, false);
  }

  for (const reverse of [false, true]) {
    const runtime = makeRuntime();
    runtime.server.deferred.add("/api/status");
    enterPair(runtime);
    enterPair(runtime);
    const entries = runtime.server.pending.splice(0);
    assert.strictEqual(entries.length, 2);
    if (reverse) entries.reverse();
    entries.forEach(xhr => xhr.respond(200, { peers: [] }));
    const before = runtime.server.requests.filter(r => r.url === "/api/pairing").length;
    runtime.server.deferred.delete("/api/status");
    Array.from(runtime.timers.values()).filter(timer => timer.repeat).forEach(timer => timer.fn());
    assert.strictEqual(runtime.server.requests.filter(r => r.url === "/api/pairing").length, before + 1,
      "only the current Pair visit polls after overlapping entry responses");
    runtime.hooks.adminRuntime.switchTab("dash");
    assert.strictEqual(Array.from(runtime.timers.values()).filter(timer => timer.repeat).length, 0);
  }

  {
    const runtime = makeRuntime();
    runtime.server.deferred.add("/api/status");
    enterPair(runtime);
    const entry = runtime.server.pending.shift();
    runtime.hooks.adminRuntime.switchTab("dash");
    const before = runtime.server.requests.filter(r => r.url === "/api/pairing").length;
    entry.respond(200, { peers: [] });
    assert.strictEqual(runtime.server.requests.filter(r => r.url === "/api/pairing").length, before);
    assert.strictEqual(Array.from(runtime.timers.values()).filter(timer => timer.repeat).length, 0,
      "late Pair entry cannot restart timers after navigation");
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/pairing/found"] });
    enterPair(runtime);
    runtime.hooks.adminRuntime.pairAct("found");
    assert(runtime.server.requests.some((r) => r.url === "/api/pairing/found"));
    runtime.fire("pagehide");
    runtime.respond("/api/pairing/found", 200, { ok: true });
    assert(!runtime.server.requests.some((r) => r.url === "/api/join-token"),
      "a stale pairing completion must not start a follow-up POST");
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/pairing"] });
    enterPair(runtime);
    enterPair(runtime);
    runtime.respond("/api/pairing", 200, { state: "unpaired", pending: { devices: [] } });
    assert.strictEqual(runtime.server.pending.filter((xhr) => xhr.url === "/api/pairing").length, 1,
      "a response from the retired pair-tab visit cannot consume or replace the new visit");
    runtime.respond("/api/pairing", 200, { state: "unpaired", pending: { devices: [] } });
  }

  {
    const runtime = makeRuntime({ deferred: ["/api/delayed"] });
    const outcomes = [];
    runtime.hooks.adminRuntime.api("GET", "/api/delayed", null,
      (status, _body, detail) => outcomes.push([status, detail.reason]), { timeout_ms: 1 });
    runtime.runLastTimer();
    assert.deepStrictEqual(outcomes, [[0, "timeout"]],
      "timeout intent wins over abort and status=0 ready-state notifications");
    runtime.server.throwSend.add("/api/send-failure");
    runtime.hooks.adminRuntime.api("GET", "/api/send-failure", null,
      (status, _body, detail) => outcomes.push([status, detail.reason]));
    assert.deepStrictEqual(outcomes[1], [0, "send"], "synchronous send failure settles once");
    const request = runtime.hooks.adminRuntime.api("GET", "/api/delayed", null,
      (status, _body, detail) => outcomes.push([status, detail.reason]));
    request.abort();
    assert.deepStrictEqual(outcomes[2], [0, "abort"],
      "an external XHR.abort reports abort rather than a spurious network failure");
  }

  {
    const runtime = makeRuntime();
    enterPair(runtime);
    runtime.hooks.adminRuntime.pairScanOpen();
    const first = runtime.streams[0];
    runtime.hooks.adminRuntime.pairScanClose();
    runtime.hooks.adminRuntime.pairScanOpen();
    const second = runtime.streams[1];
    const oldTrack = { stopped: false, stop() { this.stopped = true; } };
    first.ok({ getTracks() { return [oldTrack]; } });
    assert.strictEqual(oldTrack.stopped, true, "stale camera streams are stopped");
    const newTrack = { stopped: false, stop() { this.stopped = true; } };
    second.ok({ getTracks() { return [newTrack]; } });
    runtime.hooks.adminRuntime.pairScanClose();
    assert.strictEqual(newTrack.stopped, true, "current camera streams are stopped on close");
  }

  {
    const runtime = makeRuntime({ detect() { throw new Error("detector unavailable"); } });
    enterPair(runtime);
    runtime.hooks.adminRuntime.pairScanOpen();
    const track = { stopped: false, stop() { this.stopped = true; } };
    runtime.streams[0].ok({ getTracks() { return [track]; } });
    runtime.runLastTimer();
    runtime.runLastTimer();
    runtime.runLastTimer();
    assert.strictEqual(track.stopped, true,
      "three detector failures close the scanner instead of leaving a busy retry loop");
  }

  {
    const runtime = makeRuntime();
    const count = () => runtime.server.requests.filter(r => r.url === "/api/session/activity").length;
    assert.strictEqual(count(), 0, "boot and automatic polling do not report interaction");
    runtime.fire("keydown", { isTrusted: false });
    assert.strictEqual(count(), 0, "synthetic events cannot keep a session active");
    runtime.fire("keydown", { isTrusted: true });
    assert.strictEqual(count(), 1, "an authenticated user interaction renews the idle window");
    assert.strictEqual(runtime.server.requests.find(r => r.url === "/api/session/activity").xhr.headers["X-Doorbell-CSRF"], "test-csrf");
    runtime.fire("mousedown", { isTrusted: true });
    assert.strictEqual(count(), 1, "interaction notifications are bounded");
    runtime.fire("pagehide");
    runtime.fire("keydown", { isTrusted: true });
    assert.strictEqual(count(), 1, "a retired page cannot renew a session");
  }

  console.log("admin runtime tests: ok");
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
