"use strict";
const assert = require("assert");
const fs = require("fs");
const vm = require("vm");

const listeners = {};
const notifications = [];
const messages = [];
const opened = [];
const timers = [];
const cacheValues = {};
let closed = 0;
let focused = 0;
let clientList = [{
  url: "https://panel.local/panel/call",
  postMessage: function (value) { messages.push(value); },
  focus: function () { focused++; return Promise.resolve(); }
}];

const self = {
  location: { search: "", origin: "https://panel.local" },
  registration: {
    showNotification: function (title, options) {
      for (let i = 0; i < notifications.length; i++)
        if (!notifications[i].closed && notifications[i].options.tag === options.tag)
          notifications[i].replaced = true;
      const notification = { title: title, options: options, data: options.data, closed: false,
        close: function () { if (!this.closed) { this.closed = true; closed++; } } };
      notifications.push(notification);
      return Promise.resolve();
    },
    getNotifications: function (filter) {
      return Promise.resolve(notifications.filter(function (notification) {
        return !notification.closed && !notification.replaced &&
               (!filter || !filter.tag || notification.options.tag === filter.tag);
      }));
    }
  },
  clients: {
    matchAll: function () { return Promise.resolve(clientList); },
    openWindow: function (url) { opened.push(url); return Promise.resolve(); }
  },
  caches: {
    open: function () { return Promise.resolve({
      match: function (key) {
        return Promise.resolve(cacheValues[key] ? {
          json: function () { return Promise.resolve(cacheValues[key]); }
        } : null);
      },
      put: function (key, response) {
        return response.json().then(function (value) { cacheValues[key] = value; });
      }
    }); }
  },
  addEventListener: function (name, fn) { listeners[name] = fn; }
};
function FakeResponse(body) {
  this.json = function () { return Promise.resolve(JSON.parse(body)); };
}
vm.runInNewContext(fs.readFileSync("webui/panel/sw.js", "utf8"),
                   { self: self, URL: URL, Promise: Promise, decodeURIComponent: decodeURIComponent,
                     encodeURIComponent: encodeURIComponent,
                     Response: FakeResponse,
                     setTimeout: function (fn) { timers.push(fn); return timers.length; },
                     isFinite: isFinite });

async function settle() {
  for (let i = 0; i < 4; i++)
    await new Promise(function (resolve) { setImmediate(resolve); });
}

async function run() {
  let waiting;
  listeners.push({
    data: { json: function () {
      return { kind: "emergency", title: "SOS", url: "https://evil.invalid/panel/call" };
    } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.strictEqual(notifications.length, 1);
  assert.strictEqual(notifications[0].title, "SOS");
  assert.strictEqual(notifications[0].options.body, "");
  assert.strictEqual(notifications[0].options.requireInteraction, true);
  assert.strictEqual(notifications[0].options.data.url,
                     "https://panel.local/panel/monitor");
  assert.strictEqual(messages.length, 1);

  listeners.push({
    data: { json: function () {
      return { kind: "press", title: "Door", url: "https://panel.local/panel/call.html?door=front" };
    } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.strictEqual(notifications[1].options.data.url,
                     "https://panel.local/panel/call?door=front");

  listeners.push({
    data: { json: function () {
      return { kind: "emergency", title: "Quiet SOS", presentation: {
        sound: "siren1", volume: 0, sticky: false, ttl_s: 1
      }, event_id: "node:3", event_hlc: "000000000003-0000-a" };
    } },
    waitUntil: function (p) { waiting = p; }
  });
  await settle();
  assert.strictEqual(timers.length, 1);
  timers.shift()();
  await waiting;
  assert.strictEqual(notifications[2].options.requireInteraction, false);
  assert.strictEqual(notifications[2].options.silent, true);
  assert.strictEqual(closed, 1);

  listeners.notificationclick({
    notification: { data: notifications[0].options.data, close: function () {} },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.strictEqual(focused, 1);
  assert.strictEqual(opened.length, 0);
  assert.strictEqual(messages.length, 4);

  clientList = [];
  listeners.notificationclick({
    notification: { data: notifications[0].options.data, close: function () {} },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.deepStrictEqual(opened, ["https://panel.local/panel/monitor"]);

  // A clear notification's TTL cannot close a newer active SOS that reused the same tag.
  listeners.push({
    data: { json: function () { return {
      kind: "emergency_cancel", active: false, tag: "doorbell-emergency",
      event_id: "node:4", event_hlc: "000000000004-0000-a",
      presentation: { sticky: false, ttl_s: 10 }
    }; } },
    waitUntil: function (p) { waiting = p; }
  });
  await settle();
  const clearWaiting = waiting;
  assert.strictEqual(timers.length, 1);
  listeners.push({
    data: { json: function () { return {
      kind: "emergency", active: true, tag: "doorbell-emergency",
      event_id: "node:5", event_hlc: "000000000005-0000-a"
    }; } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  const activeNotification = notifications[notifications.length - 1];
  timers.shift()();
  await clearWaiting;
  assert.strictEqual(activeNotification.closed, false);
  assert.strictEqual(closed, 1);

  // Push-provider reordering cannot reopen an SOS older than the persisted clear/current HLC.
  const beforeStale = notifications.length;
  listeners.push({
    data: { json: function () { return {
      kind: "emergency", active: true, tag: "doorbell-emergency",
      event_id: "node:2", event_hlc: "000000000002-0000-a"
    }; } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.strictEqual(notifications.length, beforeStale);
  listeners.push({
    data: { json: function () { return {
      kind: "emergency_cancel", active: false, tag: "doorbell-emergency",
      event_id: "node:6", event_hlc: "000000000006-0000-a", presentation: { ttl_s: 0 }
    }; } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  const afterNewClear = notifications.length;
  listeners.push({
    data: { json: function () { return {
      kind: "emergency", active: true, tag: "doorbell-emergency",
      event_id: "node:5", event_hlc: "000000000005-0000-a"
    }; } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  assert.strictEqual(notifications.length, afterNewClear);
  assert.strictEqual(Object.values(cacheValues)[0].hlc, "000000000006-0000-a");
  assert.strictEqual(Object.values(cacheValues)[0].active, false);

  listeners.push({
    data: { json: function () { return {}; } },
    waitUntil: function (p) { waiting = p; }
  });
  await waiting;
  const lastNotification = notifications[notifications.length - 1];
  assert.strictEqual(lastNotification.title, "");
  assert.strictEqual(lastNotification.options.body, "");
  console.log("service worker tests: ok");
}

run().catch(function (err) {
  console.error(err);
  process.exitCode = 1;
});
