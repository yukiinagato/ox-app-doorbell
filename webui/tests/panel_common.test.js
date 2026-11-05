"use strict";
// Regression tests for the shared panel request lane, escaping, and the door/monitor page
// contracts (CSRF on every mutation, DOM-built purpose buttons, bounded "mark seen").
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const panelDir = path.join(__dirname, "../panel");
const read = name => fs.readFileSync(path.join(panelDir, name), "utf8");
const CSRF = "0123456789abcdef0123456789abcdef", FRESH = "fedcba9876543210fedcba9876543210";

function runtimeContext() {
  const requests = [];
  function XMLHttpRequest() {
    this.headers = {};
    this.open = (method, url) => { this.method = method; this.url = url; };
    this.setRequestHeader = (name, value) => { this.headers[name] = value; };
    this.send = body => { this.body = body; requests.push(this); };
    this.respond = (status, data) => {
      this.status = status; this.responseText = JSON.stringify(data); this.readyState = 4;
      if (this.onreadystatechange) this.onreadystatechange();
    };
  }
  const root = { XMLHttpRequest, setTimeout, clearTimeout,
    location: { search: "", hash: "#k=secret", pathname: "/panel/door" },
    history: { replaceState() {} } };
  const context = vm.createContext({ window: root, console });
  vm.runInContext(read("runtime.js"), context);
  vm.runInContext(read("panel-common.js"), context);
  return { R: root.DoorbellPanelRuntime, C: root.DoorbellPanelCommon, requests, root };
}

// 1. Every mutation carries the session CSRF token; a stale token is refreshed once.
{
  const { R, requests } = runtimeContext();
  let session = null;
  R.establishSession(result => { session = result; });
  requests[0].respond(200, { ok: true, csrf_token: CSRF });
  assert.strictEqual(session.ok, true);
  assert.strictEqual(R.panelCsrfToken(), CSRF, "sign-in response provides the CSRF token");

  let status = 0;
  R.panelRequest("POST", "/api/panel/press", "door=front", s => { status = s; });
  const press = requests[1];
  assert.strictEqual(press.headers["X-Doorbell-CSRF"], CSRF, "press carries CSRF");
  assert.strictEqual(press.headers["Content-Type"], "application/x-www-form-urlencoded");
  press.respond(403, { ok: false, error_code: "permission_denied" });
  const refresh = requests[2];
  assert.strictEqual(refresh.method, "GET");
  assert.strictEqual(refresh.url, "/api/panel/session");
  refresh.respond(200, { ok: true, csrf_token: FRESH });
  const retry = requests[3];
  assert.strictEqual(retry.url, "/api/panel/press");
  assert.strictEqual(retry.headers["X-Doorbell-CSRF"], FRESH, "retry uses the refreshed token");
  retry.respond(403, { ok: false });
  assert.strictEqual(status, 403, "a second 403 is reported, not retried forever");
  assert.strictEqual(requests.length, 4);

  R.panelRequest("GET", "/api/panel/state", null, () => {});
  assert.strictEqual(requests[4].headers["X-Doorbell-CSRF"], undefined, "reads carry no token");

  R.panelRequest("POST", "/api/call-log/seen", { up_to_hlc: "x" }, () => {});
  assert.strictEqual(requests[5].headers["Content-Type"], "application/json");
  assert.strictEqual(requests[5].body, JSON.stringify({ up_to_hlc: "x" }));
  assert.strictEqual(requests[5].headers["X-Doorbell-CSRF"], FRESH);
}

// 2. Without a token yet, the lane fetches one before the first mutation.
{
  const { R, requests } = runtimeContext();
  R.panelRequest("POST", "/api/panel/cancel", "door=front", () => {});
  assert.strictEqual(requests[0].url, "/api/panel/session");
  requests[0].respond(200, { ok: true, csrf_token: CSRF });
  assert.strictEqual(requests[1].url, "/api/panel/cancel");
  assert.strictEqual(requests[1].headers["X-Doorbell-CSRF"], CSRF);
}

// 3. Escaping is safe inside quoted attributes, and the newest displayed HLC bounds "seen".
{
  const { C } = runtimeContext();
  assert.strictEqual(C.esc(`x' autofocus onfocus='alert(1)"<>&\``),
    "x&#39; autofocus onfocus=&#39;alert(1)&quot;&lt;&gt;&amp;&#96;");
  assert.strictEqual(C.newestHlc([{ hlc: "00000000000a-0000-1" }, { hlc: "00000000000c-0000-1" },
    { hlc: "00000000000b-0000-1" }, {}]), "00000000000c-0000-1");
  assert.strictEqual(C.newestHlc([]), "", "nothing displayed means nothing is marked");
}

// 4. Page contracts: no page-local XHR transport, every mutation goes through the shared lane,
// purpose buttons are built with DOM APIs, monitors never mark seen on open, no mock paths.
for (const page of ["door.html", "monitor.html"]) {
  const html = read(page);
  assert(html.includes('<script src="/panel/panel-common.js"></script>'), page + " loads helpers");
  assert(!/new XMLHttpRequest/.test(html), page + " must not build its own XHR");
  assert(!/\bxhr\(/.test(html), page + " must not call a page-local xhr()");
  assert(!/MOCK|mock=1/.test(html), page + " must not ship mock paths");
  const posts = [...html.matchAll(/"POST",\s*"(\/api\/[^"]+)"/g)];
  assert(posts.length > 0, page + " has mutations");
  for (const m of posts) {
    const before = html.slice(Math.max(0, m.index - 40), m.index);
    assert(/R\.panelRequest\($/.test(before.trim()) || /R\.panelRequest\(\s*$/.test(before),
      page + " mutation " + m[1] + " must use DoorbellPanelRuntime.panelRequest");
  }
}
{
  const door = read("door.html");
  assert(!/data-purpose='/.test(door), "purpose ids are never concatenated into markup");
  assert(door.includes('b.setAttribute("data-purpose", items[i].id)'));
  assert(door.includes('"/api/panel/visitor-lang"'), "door page reports the visitor's language");
  const monitor = read("monitor.html");
  assert(!monitor.includes("markedSeenOnOpen"), "opening a monitor must not mark calls seen");
  assert(monitor.includes("C.newestHlc(displayedRows())"), "marking is bounded by displayed rows");
  assert(!/"up_to_hlc="/.test(monitor), "an empty up_to_hlc would clear the whole log");
  assert(!/stream_mjpeg \|\|/.test(monitor), "peer MJPEG origins are never fetched directly");
  const call = read("call.html");
  assert(!/MOCK|mockSessionActive/.test(call), "call page ships no mock path");
}

console.log("panel common, CSRF lane and page contracts: PASS");
