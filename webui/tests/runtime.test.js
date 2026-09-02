"use strict";
const assert = require("assert");
const runtimePath = require.resolve("../panel/runtime.js");
const R = require(runtimePath);

assert.deepStrictEqual(R.emergencyState({ emergency: { active: true } }),
  { known: true, active: true, source: "state", device: "", wall_ms: 0 });
assert.deepStrictEqual(R.emergencyState({ device_alert: { active: true, device: "front" } }),
  { known: true, active: true, source: "device_alert", device: "front", wall_ms: 0 });
assert.deepStrictEqual(R.emergencyState({ emergency: {
  active: true, web_active_page_alerts: false
} }), { known: true, active: false, source: "web_disabled", device: "", wall_ms: 0 });
assert.strictEqual(R.emergencyState({
  device_alert: { active: true }, emergency: { active: true, web_active_page_alerts: false }
}).active, true);
assert.deepStrictEqual(R.emergencyState({
  device_alert: { active: false, device: "stale" },
  emergency: { active: true, web_active_page_alerts: true, device: "front" }
}), { known: true, active: true, source: "state", device: "front", wall_ms: 0 });
assert.strictEqual(R.emergencyState({ events: [
  { type: "emergency", wall_ms: 10 }, { type: "emergency_cancel", wall_ms: 20 }
]}).active, false);
assert.strictEqual(R.emergencyState({ events: [
  { type: "emergency_cancel", wall_ms: 10 }, { type: "emergency", wall_ms: 20 }
]}).active, true);
assert.deepStrictEqual(R.emergencyPresentation({
  emergency: { active: true, web_active_page_alerts: true, hlc: "10-0-a" },
  device_alert: { active: true, presentation: {
    visual: false, sound: "siren1", volume: 70, sticky: false, ttl_s: 12
  } }
}), { visual: true, sound: "siren1", volume: 70, sticky: false, ttl_s: 12,
      background: "#8F1010", foreground: "#FFFFFF", accent: "#FFD166",
      raw_active: true, custom_colors: false, key: "10-0-a" });
assert.deepStrictEqual(R.emergencyPresentation({ device_alert: {
  active: true, presentation: {
    background: "#101418", foreground: "#FFFFFF", accent: "#4DA3FF"
  }
} }), { visual: true, sound: "", volume: 100, sticky: false, ttl_s: 0,
  background: "#101418", foreground: "#FFFFFF", accent: "#4DA3FF",
  raw_active: false, custom_colors: true, key: "emergency" });
assert.strictEqual(R.emergencyPresentation({
  emergency: { active: true, web_active_page_alerts: false },
  device_alert: { active: true, event_hlc: "11-0-a", presentation: { visual: false } }
}).visual, false);
assert.strictEqual(R.activePage({ emergency: true, active_page: "call" }, "door"), "emergency");
assert.strictEqual(R.activePage({ device_alert: { active: true }, active_page: "call" }, "door"),
                   "emergency");
assert.strictEqual(R.activePage({ active_page: { page: "call" } }, "door"), "call");
assert.strictEqual(R.activePage({ active_page: "javascript:bad" }, "door"), "door");
assert.strictEqual(R.panelUrl("call", "a b", false, "front/1"),
                   "/panel/call?door=front%2F1#k=a%20b");
assert.strictEqual(R.pushTargetsGroup({ web_subscription_groups: ["guards"] }, "guards"), true);
assert.strictEqual(R.pushTargetsGroup({ web_subscription_groups: ["guards"] }, "residents"), false);
assert.strictEqual(R.pushTargetsGroup({ web_subscription_groups: "all" }, "residents"), true);
assert.strictEqual(R.pushTargetsGroup({ kind: "emergency" }, "residents"), true);
const uiManifest = {
  schema_version: 1, units: "effective_px",
  viewport: { minimum_touch: 44, scale_min: 0.75, scale_max: 2 },
  elements: {
    "call.primary": {
      properties: ["scale", "font_scale", "foreground", "background", "accent", "border", "radius"],
      safety_critical: false,
      defaults: { scale: 1, font_scale: 1, foreground: "#E8EDF2", background: "#1A2027",
                  accent: "#4DA3FF", border: "#4DA3FF", radius: 12 }
    },
    "cancel.call": {
      properties: ["scale", "font_scale", "foreground", "background"],
      safety_critical: true,
      defaults: { scale: 1, font_scale: 1, foreground: "#FFFFFF", background: "#8D2932" }
    }
  }
};
assert.strictEqual(R.semanticUiModel({ manifest: uiManifest, elements: {
  call: { primary: { scale: 1.25, radius: 8 } }
} }).elements["call.primary"].style.scale, 1.25);
assert.strictEqual(R.semanticUiModel({ manifest: uiManifest, elements: {
  "call.primary": { foreground: "#1A2027" }
} }).ok, false); // Partial overrides are checked against the effective default background.
assert.strictEqual(R.semanticUiModel({ manifest: uiManifest, elements: {
  "cancel.call": { font_scale: 0.9 }
} }).ok, false);
assert.strictEqual(R.semanticUiModel({ manifest: uiManifest, elements: {
  "call.primary": { position: "absolute" }
} }).ok, false);
const overlay = R.installEmergencyOverlay({});
overlay.onPush({ kind: "emergency", active: true, wall_ms: 20 });
assert.strictEqual(overlay.update({}).active, true); // unknown rolling-upgrade poll is not a cancel
assert.strictEqual(overlay.update({ emergency: { active: true } }).active, true);
assert.strictEqual(overlay.update({ emergency: { active: false } }).active, false);

let holdTimer = null, holdDelay = 0, holdFires = 0, holdCancels = 0;
const hold = R.sosHoldController(function () { holdFires++; }, function (fn, delay) {
  holdTimer = fn; holdDelay = delay; return 7;
}, function (id) { assert.strictEqual(id, 7); holdCancels++; holdTimer = null; });
assert.strictEqual(hold.duration_ms, 2000);
assert.strictEqual(hold.start(), true);
assert.strictEqual(hold.start(), false); // Repeated touch/mouse events do not shorten the hold.
assert.strictEqual(holdDelay, 2000);
hold.cancel();
assert.strictEqual(holdFires, 0);
assert.strictEqual(holdCancels, 1);
assert.strictEqual(hold.start(), true);
const completeHold = holdTimer;
completeHold();
assert.strictEqual(holdFires, 1);
assert.strictEqual(hold.holding(), false);

// A failed semantic-UI report is retried with backoff; only a 2xx acknowledgement is deduplicated.
let uiReportSends = 0, uiReportRetry = null;
global.window = {
  XMLHttpRequest: function () {
    this.open = function () {};
    this.setRequestHeader = function () {};
    this.send = function () {
      uiReportSends++;
      this.status = uiReportSends === 1 ? 503 : 204;
      this.onload();
    };
  },
  setTimeout: function (fn) { uiReportRetry = fn; return 1; },
  clearTimeout: function () { uiReportRetry = null; }
};
delete require.cache[runtimePath];
const ReportRuntime = require(runtimePath);
const reportState = { web_ui: { device_id: "web-node", manifest: uiManifest, elements: {} } };
ReportRuntime.applySemanticUi(reportState, { page: "monitor" });
ReportRuntime.applySemanticUi(reportState, { page: "monitor" });
assert.strictEqual(uiReportSends, 1);
assert(uiReportRetry);
uiReportRetry();
assert.strictEqual(uiReportSends, 2);
ReportRuntime.applySemanticUi(reportState, { page: "monitor" });
assert.strictEqual(uiReportSends, 2);
delete global.window;

function response(status, body) {
  return { ok: status >= 200 && status < 300, status: status,
           json: function () { return Promise.resolve(body || {}); } };
}

async function pushTests() {
  let subscription = null;
  let scheduledExpiry = null;
  let expirySchedules = 0;
  const requests = [];
  const reg = { pushManager: {
    getSubscription: function () { return Promise.resolve(subscription); },
    subscribe: function (options) {
      assert.strictEqual(options.userVisibleOnly, true);
      subscription = {
        endpoint: "https://push.invalid/sub/1",
        toJSON: function () {
          return { endpoint: this.endpoint, keys: { p256dh: "abc", auth: "def" } };
        },
        unsubscribe: function () { subscription = null; return Promise.resolve(true); }
      };
      return Promise.resolve(subscription);
    }
  } };
  const serviceWorker = {
    ready: Promise.resolve(reg), addEventListener: function () {},
    getRegistration: function (scope) {
      assert.strictEqual(scope, "/panel/"); return Promise.resolve(reg);
    },
    register: function (path, options) {
      assert.strictEqual(path, "/panel/sw.js");
      assert.deepStrictEqual(options, { scope: "/panel/" });
      return Promise.resolve(reg);
    }
  };
  global.window = {
    isSecureContext: true, PushManager: function () {}, Uint8Array: Uint8Array,
    location: { pathname: "/panel/monitor", search: "?group=guards" },
    atob: function (value) { return Buffer.from(value, "base64").toString("binary"); },
    Notification: { requestPermission: function () { return Promise.resolve("granted"); } },
    setTimeout: function (fn) { expirySchedules++; scheduledExpiry = fn; return expirySchedules; },
    clearTimeout: function () { scheduledExpiry = null; },
    navigator: { serviceWorker: serviceWorker },
    fetch: function (url, options) {
      requests.push({ url: url, options: options || {} });
      if (url.indexOf("push-vapid-public-key") >= 0)
        return Promise.resolve(response(200, { ok: true, public_key: "AQ" }));
      return Promise.resolve(response(200, { ok: true }));
    }
  };
  delete require.cache[runtimePath];
  const W = require(runtimePath);
  const groupedOverlay = W.installEmergencyOverlay({});
  groupedOverlay.onPush({ kind: "emergency", active: true,
    web_subscription_groups: ["residents"] });
  assert.strictEqual(groupedOverlay.state().active, false);
  groupedOverlay.onPush({ kind: "emergency", active: true,
    web_subscription_groups: ["guards"] });
  assert.strictEqual(groupedOverlay.state().active, true);
  groupedOverlay.update({ emergency: { active: true, web_active_page_alerts: false } });
  assert.strictEqual(groupedOverlay.state().active, true);
  assert.strictEqual(groupedOverlay.state().source, "push");
  groupedOverlay.update({ emergency: { active: false, web_active_page_alerts: false } });
  assert.strictEqual(groupedOverlay.state().active, false);
  const orderedOverlay = W.installEmergencyOverlay({});
  orderedOverlay.onPush({ kind: "emergency", active: true,
    event_hlc: "000000000002-0000-b" });
  orderedOverlay.update({ emergency: { active: false, hlc: "" } });
  assert.strictEqual(orderedOverlay.state().active, true);
  orderedOverlay.update({ emergency: { active: false, hlc: "000000000001-0000-a" } });
  assert.strictEqual(orderedOverlay.state().active, true);
  orderedOverlay.update({ emergency: { active: false, hlc: "000000000003-0000-a" } });
  assert.strictEqual(orderedOverlay.state().active, false);
  orderedOverlay.onPush({ kind: "emergency", active: true,
    event_hlc: "000000000002-0000-b" });
  assert.strictEqual(orderedOverlay.state().active, false);
  const rawOverlay = W.installEmergencyOverlay({});
  rawOverlay.update({ emergency: { active: true, web_active_page_alerts: true, hlc: "raw-1" },
    device_alert: { active: true, presentation: { sticky: false, ttl_s: 1, sound: "tone" } } });
  assert(scheduledExpiry);
  const originalExpiry = scheduledExpiry;
  rawOverlay.update({ emergency: { active: true, web_active_page_alerts: true, hlc: "raw-1" },
    device_alert: { active: true, presentation: { sticky: false, ttl_s: 1, sound: "tone" } } });
  assert.strictEqual(expirySchedules, 1); // Polling cannot extend a rule event's TTL.
  assert.strictEqual(scheduledExpiry, originalExpiry);
  scheduledExpiry();
  assert.strictEqual(rawOverlay.state().active, true);
  assert.strictEqual(rawOverlay.state().presented, true); // TTL expires decoration, not raw SOS.
  assert.deepStrictEqual(await W.pushSubscriptionState(),
                         { ok: true, subscribed: false,
                           message_key: "panel.push_disabled",
                           message: "panel.push_disabled" });
  const enabled = await W.subscribePush("tok", "/panel/monitor");
  assert.strictEqual(enabled.ok, true);
  assert.strictEqual(enabled.subscribed, true);
  assert.strictEqual(requests.some(function (r) { return /[?&]k=/.test(r.url); }), false);
  const post = requests.find(function (r) {
    return r.url.indexOf("push-subscription") >= 0 && r.options.method === "POST";
  });
  assert(post);
  assert.deepStrictEqual(JSON.parse(post.options.body), {
    subscription: { endpoint: "https://push.invalid/sub/1", keys: { p256dh: "abc", auth: "def" } },
    page: "/panel/monitor", group: "guards"
  });
  assert.strictEqual(W.panelStateUrl(), "/api/panel/state?group=guards");
  assert.strictEqual((await W.pushSubscriptionState()).subscribed, true);
  global.window.location.search = "?group=residents";
  assert.strictEqual((await W.pushSubscriptionState()).subscribed, true);
  const registrationPosts = requests.filter(function (r) {
    return r.url.indexOf("push-subscription") >= 0 && r.options.method === "POST";
  });
  assert.strictEqual(JSON.parse(registrationPosts[registrationPosts.length - 1].options.body).group,
                     "residents");
  assert.strictEqual(W.panelStateUrl(), "/api/panel/state?group=residents");
  const disabled = await W.unsubscribePush("tok");
  assert.strictEqual(disabled.ok, true);
  assert.strictEqual(disabled.subscribed, false);
  const del = requests.find(function (r) {
    return r.url.indexOf("push-subscription") >= 0 && r.options.method === "DELETE";
  });
  assert.deepStrictEqual(JSON.parse(del.options.body), { endpoint: "https://push.invalid/sub/1" });

  global.window.fetch = function (url) {
    if (url.indexOf("push-vapid-public-key") >= 0)
      return Promise.resolve(response(501, { ok: false, err: "not implemented" }));
    return Promise.resolve(response(200, { ok: true }));
  };
  const unavailable = await W.subscribePush("tok", "/panel/monitor");
  assert.strictEqual(unavailable.ok, false);
  assert.strictEqual(unavailable.unavailable, true);
  assert.strictEqual(unavailable.message_key, "panel.push_unavailable");
  assert.strictEqual(unavailable.message, unavailable.message_key);
  global.window.fetch = function (url) {
    if (url.indexOf("push-vapid-public-key") >= 0)
      return Promise.resolve(response(200, { public_key: "AQ" }));
    return Promise.resolve(response(200, {}));
  };
  const malformed = await W.subscribePush("tok", "/panel/monitor");
  assert.strictEqual(malformed.ok, false);
  assert.strictEqual(malformed.unavailable, false);

  global.window.fetch = function (url) {
    if (url.indexOf("push-vapid-public-key") >= 0)
      return Promise.resolve(response(200, { ok: true, public_key: "AQ" }));
    return Promise.resolve(response(500, { ok: false, err: "temporary_backend_failure" }));
  };
  const registrationFailed = await W.subscribePush("tok", "/panel/monitor");
  assert.strictEqual(registrationFailed.ok, false);
  assert.strictEqual(subscription, null);
  assert.strictEqual((await W.pushSubscriptionState()).subscribed, false);

  global.window.fetch = function (url) {
    if (url.indexOf("push-vapid-public-key") >= 0)
      return Promise.resolve(response(200, { ok: true, public_key: "AQ" }));
    return Promise.resolve(response(200, { ok: true }));
  };
  assert.strictEqual((await W.subscribePush("tok", "/panel/monitor")).ok, true);
  assert(subscription);
  global.window.fetch = function (url) {
    if (url.indexOf("push-vapid-public-key") >= 0)
      return Promise.resolve(response(200, { ok: true, public_key: "AQ" }));
    return Promise.resolve(response(500, { ok: false, err: "temporary_backend_failure" }));
  };
  assert.strictEqual((await W.subscribePush("tok", "/panel/monitor")).ok, false);
  assert(subscription); // A pre-existing subscription remains available for retry.
  delete global.window;
}

pushTests().then(function () {
  console.log("panel runtime tests: ok");
}).catch(function (err) {
  console.error(err);
  process.exitCode = 1;
});
