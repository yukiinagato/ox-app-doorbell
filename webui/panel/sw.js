/* Doorbell Web Push service worker. Authentication uses the same-origin HttpOnly panel session. */
"use strict";

function payloadOf(event) {
  if (!event.data) return {};
  try { return event.data.json() || {}; } catch (e) {}
  try { return { body: event.data.text() }; } catch (e2) { return {}; }
}

function safePanelUrl(raw) {
  var fallback = "/panel/monitor";
  try {
    var u = new URL(raw || fallback, self.location.origin);
    if (u.origin !== self.location.origin || u.pathname.indexOf("/panel/") !== 0)
      u = new URL(fallback, self.location.origin);
    // One-release compatibility for payloads produced before embedded panel routes were
    // standardized on extensionless paths.
    u.pathname = u.pathname.replace(/^\/panel\/(door|monitor|call)\.html$/, "/panel/$1");
    return u.href;
  } catch (e) {
    return fallback;
  }
}

var emergencyOrderMemory = {};
var pushOrdering = Promise.resolve();
var ORDER_CACHE = "doorbell-push-order-v1";

function pushTag(p) {
  var tag = typeof p.tag === "string" ? p.tag : "";
  if (!tag) tag = p.kind ? "doorbell-" + String(p.kind) : "doorbell";
  return tag.slice(0, 128);
}

function pushEventKey(p) {
  if (typeof p.event_id === "string" && p.event_id) return "id:" + p.event_id;
  if (typeof p.event_hlc === "string" && p.event_hlc) return "hlc:" + p.event_hlc;
  if (typeof p.origin === "string" && p.origin && Number(p.seq) > 0)
    return "seq:" + p.origin + ":" + String(p.seq);
  return "";
}

function orderedHlc(value) {
  value = typeof value === "string" ? value : "";
  return /^[0-9a-f]{12}-[0-9a-f]{4}-[0-9a-f]{1,8}$/.test(value) ? value : "";
}

function orderCacheKey(tag) {
  return "/panel/.doorbell-push-order-v1?tag=" + encodeURIComponent(tag);
}

function readEmergencyOrder(tag) {
  if (emergencyOrderMemory[tag]) return Promise.resolve(emergencyOrderMemory[tag]);
  if (!(self.caches && self.caches.open)) return Promise.resolve(null);
  return self.caches.open(ORDER_CACHE).then(function (cache) {
    return cache.match(orderCacheKey(tag));
  }).then(function (response) {
    return response ? response.json() : null;
  }).then(function (value) {
    if (!value || typeof value.hlc !== "string" || typeof value.active !== "boolean") return null;
    value = { hlc: value.hlc.slice(0, 128), active: value.active };
    emergencyOrderMemory[tag] = value;
    return value;
  }).catch(function () { return null; });
}

function writeEmergencyOrder(tag, value) {
  emergencyOrderMemory[tag] = value;
  if (!(self.caches && self.caches.open)) return Promise.resolve();
  return self.caches.open(ORDER_CACHE).then(function (cache) {
    return cache.put(orderCacheKey(tag), new Response(JSON.stringify(value), {
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" }
    }));
  }).catch(function () {});
}

function acceptOrderedPush(p) {
  if (p.kind !== "emergency" && p.kind !== "emergency_cancel") return Promise.resolve(true);
  var tag = pushTag(p);
  var hlc = orderedHlc(p.event_hlc);
  var active = p.kind === "emergency" && p.active !== false;
  return readEmergencyOrder(tag).then(function (last) {
    if (last && last.hlc && (!hlc || hlc < last.hlc ||
        (hlc === last.hlc && active !== last.active))) return false;
    if (!hlc) return true;
    return writeEmergencyOrder(tag, { hlc: hlc, active: active }).then(function () { return true; });
  });
}

function notificationMatchesEvent(notification, p) {
  var expected = pushEventKey(p);
  if (!expected) return false;
  var data = notification && notification.data;
  return pushEventKey(data && data.payload ? data.payload : {}) === expected;
}

function startPush(p) {
  var presentation = p.presentation && typeof p.presentation === "object" ? p.presentation : {};
  var sticky = presentation.sticky === true ||
               (presentation.sticky === undefined && p.kind === "emergency");
  var ttl = Number(presentation.ttl_s);
  if (!isFinite(ttl) || ttl < 0) ttl = 0;
  ttl = Math.min(86400, ttl);
  var volume = Number(presentation.volume);
  if (!isFinite(volume)) volume = 100;
  volume = Math.max(0, Math.min(100, volume));
  var requestedSound = typeof presentation.sound === "string" && presentation.sound.length > 0;
  var options = { body: typeof p.body === "string" ? p.body : "",
                  tag: pushTag(p),
                  renotify: true, requireInteraction: sticky,
                  silent: volume <= 0 || !requestedSound,
                  data: { payload: p, url: safePanelUrl(p.url) } };
  var shown = self.registration.showNotification(typeof p.title === "string" ? p.title : "", options);
  var expire = Promise.resolve();
  if (!sticky && ttl > 0) {
    expire = shown.then(function () {
      return new Promise(function (resolve) {
        setTimeout(function () {
          self.registration.getNotifications({ tag: options.tag }).then(function (notifications) {
            for (var i = 0; i < notifications.length; i++)
              if (notificationMatchesEvent(notifications[i], p)) notifications[i].close();
            resolve();
          }, resolve);
        }, ttl * 1000);
      });
    });
  }
  return Promise.all([
    shown, expire,
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
      for (var i = 0; i < list.length; i++)
        list[i].postMessage({ t: "doorbell-push", payload: p });
    })
  ]);
}

self.addEventListener("push", function (event) {
  var p = payloadOf(event);
  var started = pushOrdering.then(function () {
    return acceptOrderedPush(p);
  }).then(function (accepted) {
    return accepted ? { wait: startPush(p) } : null;
  });
  // Serialize only ordering and notification creation. A non-sticky notification's TTL must not
  // delay a newer SOS while its waitUntil promise keeps the worker alive.
  pushOrdering = started.then(function () {}, function () {});
  event.waitUntil(started.then(function (result) { return result ? result.wait : null; }));
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();
  var data = event.notification.data || {}, p = data.payload || {}, target = safePanelUrl(data.url);
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true })
    .then(function (list) {
      // Prefer the page the resident already has open. It receives the payload and can render
      // SOS immediately; opening /panel/monitor is only the no-active-page fallback.
      for (var i = 0; i < list.length; i++) {
        if (list[i].url.indexOf("/panel/") < 0) continue;
        list[i].postMessage({ t: "doorbell-push", payload: p });
        if (list[i].focus) return list[i].focus();
      }
      return self.clients.openWindow ? self.clients.openWindow(target) : null;
    }));
});
