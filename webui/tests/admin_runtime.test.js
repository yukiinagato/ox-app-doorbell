"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

class Element {
  constructor() {
    this.classList = { add() {}, remove() {} };
    this.style = {};
    this.attributes = {};
    this.parentNode = null;
    this.children = [];
    this.textContent = "";
    this.innerHTML = "";
    this.value = "";
    this.disabled = false;
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

function makeRuntime() {
  const elements = new Map();
  const document = {
    body: new Element(),
    documentElement: { getAttribute() { return ""; }, removeAttribute() {}, setAttribute() {} },
    createElement() { return new Element(); },
    querySelector(selector) {
      if (!elements.has(selector)) elements.set(selector, new Element());
      return elements.get(selector);
    },
    querySelectorAll() { return []; }
  };
  let nextTimer = 1;
  const timers = new Map();
  const server = { login: { status: 401, body: { ok: false } }, status: 401, deferred: [] };
  class Xhr {
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader() {}
    send() {
      if (this.url === "/locale/en.json") this.respond(200, JSON.parse(
        fs.readFileSync(path.join(__dirname, "../locale/en.json"), "utf8")));
      else if (this.url === "/api/login") this.respond(server.login.status, server.login.body);
      else if (this.url === "/api/config") this.respond(200, {});
      else if (this.url === "/api/status") this.respond(server.status, { node: { id: "test" } });
      else this.respond(200, {});
    }
    abort() { if (this.onabort) this.onabort(); }
    respond(status, body) {
      this.status = status;
      this.responseText = JSON.stringify(body);
      this.readyState = 4;
      if (this.onreadystatechange) this.onreadystatechange();
      if (this.onerror) this.onerror(); // R4-T04: duplicate browser notifications settle once.
    }
  }
  const streams = [];
  const navigator = { mediaDevices: { getUserMedia() {
    const deferred = { ok: null, fail: null, then(ok, fail) { this.ok = ok; this.fail = fail; } };
    streams.push(deferred);
    return deferred;
  } } };
  const hooks = {};
  const window = {
    location: { search: "?lang=en" }, isSecureContext: true, navigator, __DOORBELL_TEST_HOOKS: hooks,
    BarcodeDetector: class { detect() { return Promise.resolve([]); } },
    addEventListener() {}, setTimeout(fn) { const id = nextTimer++; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval(fn) { const id = nextTimer++; timers.set(id, fn); return id; },
    clearInterval(id) { timers.delete(id); }
  };
  const context = { window, document, navigator, XMLHttpRequest: Xhr, localStorage: { getItem() { return null; }, setItem() {} },
                    console, Promise, setTimeout: window.setTimeout, clearTimeout: window.clearTimeout,
                    setInterval: window.setInterval, clearInterval: window.clearInterval, Date, JSON, RegExp };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8"), context);
  return { elements, hooks, server, streams, timers };
}

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
  assert.strictEqual(button.disabled, false);
}

{
  const runtime = makeRuntime();
  runtime.server.status = 200;
  runtime.hooks.adminRuntime.boot();
  runtime.hooks.adminRuntime.boot();
  assert.strictEqual(runtime.timers.size, 1, "R5: boot is idempotent per generation");
  runtime.hooks.adminRuntime.stop();
  assert.strictEqual(runtime.timers.size, 0, "R5: stop clears the runtime timer");
}

{
  const runtime = makeRuntime();
  runtime.server.status = 200;
  runtime.hooks.adminRuntime.boot();
  runtime.hooks.adminRuntime.pairScanOpen();
  const first = runtime.streams[0];
  runtime.hooks.adminRuntime.pairScanClose();
  runtime.hooks.adminRuntime.pairScanOpen();
  const second = runtime.streams[1];
  const oldTrack = { stopped: false, stop() { this.stopped = true; } };
  first.ok({ getTracks() { return [oldTrack]; } });
  assert.strictEqual(oldTrack.stopped, true, "R6: stale camera streams are stopped");
  const newTrack = { stopped: false, stop() { this.stopped = true; } };
  second.ok({ getTracks() { return [newTrack]; } });
  runtime.hooks.adminRuntime.pairScanClose();
  assert.strictEqual(newTrack.stopped, true, "R6: current camera streams are stopped on close");
}

console.log("admin runtime tests: ok");
