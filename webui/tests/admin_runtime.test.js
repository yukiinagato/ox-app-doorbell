"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

class Element {
  constructor() {
    this.classList = { add() {}, remove() {} }; this.style = {}; this.attributes = {};
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
  const server = { login: { status: 401, body: { ok: false } }, status: 200, config: 200,
    deferred: new Set(options.deferred || []), requests: [], pending: [], throwSend: new Set() };
  function responseFor(url) {
    if (url === "/locale/en.json") return [200, JSON.parse(
      fs.readFileSync(path.join(__dirname, "../locale/en.json"), "utf8"))];
    if (url === "/api/login") return [server.login.status, server.login.body];
    if (url === "/api/config") return [server.config, {}];
    if (url === "/api/status") return [server.status, { node: { id: "test" } }];
    if (url === "/api/pairing") return [200, { state: "unpaired", pending: { devices: [] } }];
    return [200, { ok: true }];
  }
  class Xhr {
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader() {}
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
    setTimeout(fn) { const id = nextTimer++; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    setInterval(fn) { const id = nextTimer++; timers.set(id, fn); return id; },
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
    fire(name) { (listeners[name] || []).slice().forEach((fn) => fn()); },
    runOneTimer() {
      const entry = timers.entries().next().value;
      assert(entry, "expected a pending timer"); entry[1]();
    },
    runLastTimer() {
      const entries = Array.from(timers.entries());
      assert(entries.length, "expected a pending timer"); entries[entries.length - 1][1]();
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
    const runtime = makeRuntime({ deferred: ["/api/config"] });
    assert.strictEqual(runtime.timers.size, 1,
      "only the in-flight initialization timeout exists before config/status initialize");
    runtime.respond("/api/config", 500, {});
    assert.strictEqual(runtime.timers.size, 0, "failed initialization leaves no dead poller");
    runtime.server.deferred.delete("/api/config");
    runtime.fire("pageshow");
    assert.strictEqual(runtime.timers.size, 1, "pageshow recovers a failed runtime");
    runtime.hooks.adminRuntime.stop();
    assert.strictEqual(runtime.timers.size, 0, "stop clears the runtime timer");
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

  console.log("admin runtime tests: ok");
})().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
