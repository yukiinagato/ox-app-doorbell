"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const source = fs.readFileSync(path.join(__dirname, "../panel/call.html"), "utf8")
  .match(/<script>\s*([\s\S]*?)<\/script>/)[1].replace(/\nstart\(\);\s*$/, "");
function deferred() {
  let resolve;
  return { promise: new Promise(ok => { resolve = ok; }), resolve: value => resolve(value) };
}
function runtime(options = {}) {
  const elements = new Map(), requests = [], timers = new Map(), listeners = {}, emergencyUpdates = [];
  let timerId = 0, now = 0;
  function schedule(fn, delay) {
    const id = ++timerId; timers.set(id, { fn, at: now + (delay || 0) }); return id;
  }
  function advance(ms) {
    now += ms;
    for (const [id, timer] of Array.from(timers)) {
      if (timer.at <= now) { timers.delete(id); timer.fn(); }
    }
  }
  const element = () => ({ style: {}, classList: { add() {}, remove() {} }, children: [],
    setAttribute(name, value) { this[name] = value; }, getAttribute(name) { return this[name] || null; },
    appendChild(child) { return this.insertBefore(child, null); },
    insertBefore(child, before) {
      if (child.parentNode) child.parentNode.removeChild(child);
      this.children.splice(before ? this.children.indexOf(before) : this.children.length, 0, child);
      child.parentNode = this; return child;
    },
    removeChild(child) { this.children.splice(this.children.indexOf(child), 1); child.parentNode = null; },
    focus() { context.document.activeElement = this; },
    click() { if (!this.disabled && this.onclick) this.onclick(); },
    textContent: "", checked: false, scrollLeft: 0, scrollTop: 0 });
  const context = vm.createContext({ URLSearchParams, Uint8Array, console, Promise,
    performance: { now: () => now },
    location: { search: options.search || "?lang=en", hostname: "localhost" },
    document: { hidden: false, addEventListener(name, fn) { listeners[name] = fn; }, getElementById(id) {
      if (!elements.has(id)) elements.set(id, element()); return elements.get(id);
    }, createElement: element, documentElement: { setAttribute() {} },
    getElementsByClassName() { return []; } },
    window: { location: {}, addEventListener(name, fn) { listeners[name] = fn; },
      setTimeout: schedule, clearTimeout(id) { timers.delete(id); },
      XMLHttpRequest: function () {
        this.open = (method, url) => { this.method = method; this.url = url; this.headers = {}; };
        this.setRequestHeader = (name, value) => { this.headers[name] = value; };
        this.send = body => {
          const success = this.onload;
          requests.push({ url: this.url, method: this.method, headers: this.headers, body, xhr: this, response: { resolve: async response => {
            this.status = response.status === undefined ? 200 : response.status;
            this.responseText = JSON.stringify(await response.json());
            if (success) success();
          } } });
        };
        this.abort = () => { this.aborted = true; if (this.onabort) this.onabort(); };
      } },
    navigator: {},
    setTimeout: schedule,
    clearTimeout(id) { timers.delete(id); },
    DoorbellCallFlow: require("../panel/call-flow.js"),
    DoorbellPanelRuntime: { panelStateUrl() { return "/state"; }, applySemanticUi() {},
      establishSession(cb) { cb({ ok: true }); } },
    DoorbellPanelVideo: { create() { return options.videoDriver || { stop() {} }; } },
    DoorbellPlayback: { proxyMp4Url() { return ""; }, start() { return { stop() {} }; } },
    fetch(url, options = {}) {
      const response = deferred(); requests.push({ url, body: options.body, response }); return response.promise;
    }
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../panel/runtime.js"), "utf8"), context);
  Object.assign(context.DoorbellPanelRuntime, {
    requestWithDeadline: context.window.DoorbellPanelRuntime.requestWithDeadline,
    createRequestLane: context.window.DoorbellPanelRuntime.createRequestLane
  });
  vm.runInContext(source, context);
  context.recordEmergency = state => emergencyUpdates.push(state);
  vm.runInContext('LANG="en"; I18N={}; panelCsrf="0123456789abcdef0123456789abcdef"; emergencyOverlay={update:recordEmergency}; ua={}; registered=true;', context);
  function run(code) { return vm.runInContext(code, context); }
  function activate(door, call, revision) {
    run(`selected={id:${JSON.stringify(door)}, call_id:${JSON.stringify(call)}, stage_revision:${revision}, extension:"8001"};
      selectionRevision++; activeLifecycle={door:selected.id,callId:selected.call_id,stageRevision:${revision},owner:"mine",ended:false};
      session={terminated:0,isEnded(){return false},terminate(){this.terminated++}}; sessionConfirmed=true;`);
    return run("session");
  }
  function respond(state) {
    for (const request of requests.splice(0)) {
      const body = request.url === "/state" ? state : { webrtc: { ws_url: "ws://localhost" }, doors: {} };
      request.response.resolve({ ok: true, status: 200, json: async () => body });
    }
  }
  return { run, activate, respond, requests, timers, elements, listeners, emergencyUpdates, advance, context };
}
module.exports = { runtime };
