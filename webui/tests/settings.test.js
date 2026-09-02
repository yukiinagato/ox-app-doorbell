"use strict";
// Batch 2 admin surfaces: the time card, volumes, door announcements, SOS, and battery.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

// ---- the zone list must be exactly what core can resolve --------------------------------
// A zone offered in the select that core rejects would be a setting the operator cannot save,
// and a zone core knows but the UI hides would be unreachable.
const tzSource = fs.readFileSync(
  path.join(__dirname, "../../core/src/util/tz.cpp"), "utf8");
const tableBody = tzSource.split("const Zone kZones[] = {")[1].split("\n};")[0];
const coreZones = [...tableBody.matchAll(/\{"([^"]+)",/g)].map((m) => m[1]);
assert.ok(coreZones.length > 60, "core zone table looks truncated");
assert.deepStrictEqual(L.TIME_ZONES, coreZones,
  "AdminLogic.TIME_ZONES must mirror core/src/util/tz.cpp");

const groups = L.timeZoneGroups();
assert.deepStrictEqual(groups[0], { region: "UTC", zones: ["UTC"] });
for (const region of ["Asia", "Europe", "America", "Australia", "Pacific"])
  assert.ok(groups.some((g) => g.region === region), "missing region " + region);
assert.strictEqual(groups.reduce((n, g) => n + g.zones.length, 0), L.TIME_ZONES.length);
assert.strictEqual(L.timeZoneLabel("America/Argentina/Buenos_Aires"), "Argentina/Buenos Aires");
assert.strictEqual(L.timeZoneLabel("UTC"), "UTC");

// ---- NTP server parsing mirrors the core validator ---------------------------------------
assert.deepStrictEqual(L.ntpServerList("ntp.nict.jp\ntime.google.com"),
  ["ntp.nict.jp", "time.google.com"]);
assert.deepStrictEqual(L.ntpServerList("  10.0.1.5:1123  "), ["10.0.1.5:1123"]);
assert.deepStrictEqual(L.ntpServerList("[fd00::1]:123"), ["[fd00::1]:123"]);
assert.strictEqual(L.ntpServerList(""), null, "an empty list is refused, as core refuses it");
assert.strictEqual(L.ntpServerList("a\nb\nc\nd\ne"), null, "at most four servers");
assert.strictEqual(L.ntpServerList("http://ntp.example.org"), null);
assert.strictEqual(L.ntpServerList("ntp.example.org:0"), null);
assert.strictEqual(L.ntpServerList("ntp.example.org:99999"), null);
assert.strictEqual(L.ntpServerList("bad host"), null);

// ---- the time form writes only the keys core owns from the form --------------------------
const timeEntries = L.timeEntries({
  zone: "Europe/Berlin", ntp_enabled: true,
  servers: "ntp.nict.jp\n", interval_s: "3600"
});
assert.deepStrictEqual(timeEntries, [
  { key: "time.zone", value: "Europe/Berlin" },
  { key: "time.ntp.enabled", value: true },
  { key: "time.ntp.servers", value: ["ntp.nict.jp"] },
  { key: "time.ntp.interval_s", value: 3600 }
]);
// integrations.tz_offset_min is derived by core; writing it from the form would fight core.
assert.ok(!timeEntries.some((e) => e.key === "integrations.tz_offset_min"));
for (const bad of [
  { zone: "Mars/Olympus", servers: "a", interval_s: 900 },
  { zone: "Asia/Tokyo", servers: "", interval_s: 900 },
  { zone: "Asia/Tokyo", servers: "a", interval_s: 59 },
  { zone: "Asia/Tokyo", servers: "a", interval_s: 86401 }
]) assert.throws(() => L.timeEntries(bad), "should refuse " + JSON.stringify(bad));

// ---- the status card reads core's reported source, never the toggle ----------------------
const offModel = L.timeStatusModel({ time: { zone: "Asia/Tokyo", source: "system" } });
assert.strictEqual(offModel.source, "system");
assert.strictEqual(offModel.degraded, false);
const degraded = L.timeStatusModel({
  time: { zone: "Asia/Tokyo", enabled: true, source: "system", err: "no_response",
          measured_offset_ms: 1200 }
});
assert.strictEqual(degraded.source, "system");
assert.strictEqual(degraded.degraded, true, "enabled but unsynced must read as degraded");
assert.strictEqual(degraded.errorKey, "time.err_no_response");
assert.strictEqual(degraded.measuredOffsetMs, 1200);
const healthy = L.timeStatusModel({
  time: { zone: "Europe/Paris", zone_known: true, enabled: true, source: "ntp",
          offset_ms: -350, rtt_ms: 21, server: "ntp.nict.jp", last_sync_ms: 5,
          local: { iso: "2026-09-02T14:30:00+02:00" } }
});
assert.strictEqual(healthy.degraded, false);
assert.strictEqual(healthy.offsetMs, -350);
assert.strictEqual(healthy.localIso, "2026-09-02T14:30:00+02:00");
assert.strictEqual(L.timeStatusModel({}).source, "system");
assert.strictEqual(L.timeStatusModel({ time: { zone: "Nowhere", zone_known: false } }).zoneKnown,
  false);

// ---- volumes ------------------------------------------------------------------------------
assert.deepStrictEqual(L.volumeEntries({ call: 45, sos: 100, idle: 0 }), [
  { key: "audio.volume.call", value: 45 },
  { key: "audio.volume.sos", value: 100 },
  { key: "audio.volume.idle", value: 0 }
]);
// Out-of-range input is clamped rather than sent for core to reject.
assert.deepStrictEqual(L.volumeEntries({ call: 500, sos: -20, idle: "x" }), [
  { key: "audio.volume.call", value: 100 },
  { key: "audio.volume.sos", value: 0 },
  { key: "audio.volume.idle", value: 60 }
]);

const overrides = L.deviceVolumeEntries("dev1", { inherit: false, call: 10, sos: 20, idle: 30 });
assert.deepStrictEqual(overrides.dels, []);
assert.deepStrictEqual(overrides.entries.map((e) => e.key), [
  "devices.dev1.local.audio.volume.call",
  "devices.dev1.local.audio.volume.sos",
  "devices.dev1.local.audio.volume.idle"
]);
// Inheriting again deletes the leaves; writing nulls would leave an unresolvable override.
const inherited = L.deviceVolumeEntries("dev1", { inherit: true });
assert.deepStrictEqual(inherited.entries, []);
assert.deepStrictEqual(inherited.dels, [
  "devices.dev1.local.audio.volume.call",
  "devices.dev1.local.audio.volume.sos",
  "devices.dev1.local.audio.volume.idle"
]);

// The resolution order must match db_core_audio_json exactly.
assert.deepStrictEqual(L.effectiveVolumes({}, "dev1"), {
  device: "dev1", call: 80, sos: 100, idle: 60, source: "default",
  sources: { call: "default", sos: "default", idle: "default" }
});
assert.deepStrictEqual(L.effectiveVolumes({ emergency: { alarm_volume: 42 } }, "dev1").sos, 42,
  "the legacy alarm volume is the SOS fallback");
const mixed = L.effectiveVolumes({
  audio: { volume: { call: 55 } },
  devices: { dev1: { local: { audio: { volume: { idle: 5 } } } } }
}, "dev1");
assert.strictEqual(mixed.call, 55);
assert.strictEqual(mixed.idle, 5);
assert.strictEqual(mixed.sources.call, "cluster");
assert.strictEqual(mixed.sources.idle, "device");
assert.strictEqual(mixed.sources.sos, "default");
assert.strictEqual(mixed.source, "device");
// An out-of-range stored value is ignored rather than shown as the effective level.
assert.strictEqual(L.effectiveVolumes({ audio: { volume: { call: 900 } } }, "dev1").call, 80);
assert.strictEqual(L.effectiveVolumes({ audio: { volume: { call: 900 } } }, "dev1").source,
  "default");

// ---- announcements -------------------------------------------------------------------------
const now = Date.UTC(2026, 8, 2, 12, 0, 0);
assert.strictEqual(L.noticeExpiryMs("until_cleared", now, 540), 0);
assert.strictEqual(L.noticeExpiryMs("1h", now, 540), now + 3600000);
assert.strictEqual(L.noticeExpiryMs("custom", now, 540, 4), now + 4 * 3600000);
assert.strictEqual(L.noticeExpiryMs("custom", now, 540, 0), -1);
assert.strictEqual(L.noticeExpiryMs("custom", now, 540, 100000), -1);
assert.strictEqual(L.noticeExpiryMs("nonsense", now, 540), -1);
// "End of today" is midnight in the cluster's zone, not UTC midnight.
const endOfToday = L.noticeExpiryMs("today", now, 540);
assert.strictEqual(new Date(endOfToday + 540 * 60000).toISOString(), "2026-09-03T00:00:00.000Z");
assert.strictEqual(L.noticeExpiryMs("today", now, 0), Date.UTC(2026, 8, 3, 0, 0, 0));

assert.deepStrictEqual(L.noticePayload({ text: "  side gate  ", expiry: "until_cleared" }, now,
  540), { body: { text: "side gate", expires_ms: 0 } });
assert.deepStrictEqual(L.noticePayload({ text: "   ", expiry: "1h" }, now, 540),
  { error: "notice.empty" });
const tooLong = L.noticePayload({ text: "x".repeat(201), expiry: "1h" }, now, 540);
assert.strictEqual(tooLong.error, "notice.too_long");
assert.strictEqual(tooLong.n, 201);
// Exactly at the limit is accepted, and the limit counts code points, not UTF-16 units.
assert.ok(L.noticePayload({ text: "あ".repeat(200), expiry: "1h" }, now, 540).body);
assert.strictEqual(L.countCharacters("あい"), 2);
assert.strictEqual(L.countCharacters("👪"), 1, "an astral character counts once");
assert.strictEqual(L.noticePayload({ text: "hi", expiry: "custom", custom_hours: 0 }, now, 540)
  .error, "notice.expiry_custom");

const doors = {
  d_front: { notice: { text: "Side gate", from_device: "abc", created_ms: 1,
                       expires_ms: now + 1000 } },
  d_back: { notice: { text: "Expired", expires_ms: now - 1000 } },
  d_side: { notice: { text: "Forever", expires_ms: 0 } },
  d_none: {}
};
assert.strictEqual(L.noticeModel("d_front", doors, now).active, true);
assert.strictEqual(L.noticeModel("d_front", doors, now).expired, false);
assert.strictEqual(L.noticeModel("d_front", doors, now).from, "abc");
assert.strictEqual(L.noticeModel("d_back", doors, now).expired, true);
assert.strictEqual(L.noticeModel("d_side", doors, now).expired, false,
  "0 means until cleared and never expires");
assert.strictEqual(L.noticeModel("d_none", doors, now).active, false);
assert.strictEqual(L.noticeModel("d_missing", doors, now).active, false);

// ---- SOS -------------------------------------------------------------------------------------
const sos = L.sosEntries({ mode: "slide", countdown_s: 3, button_on_roles: ["indoor_panel"],
                           cancel_requires_pin: true, alarm_sound: "siren1",
                           alarm_volume: 90 }, { alarm_volume: 100 });
assert.deepStrictEqual(sos, [
  { key: "emergency.trigger.mode", value: "slide" },
  { key: "emergency.trigger.countdown_s", value: 3 },
  { key: "emergency.button_on_roles", value: ["indoor_panel"] },
  { key: "emergency.cancel_requires_pin", value: true },
  { key: "emergency.alarm_sound", value: "siren1" },
  { key: "emergency.alarm_volume", value: 90 }
]);
const clamped = L.sosEntries({ mode: "nonsense", countdown_s: 99, alarm_volume: 500 }, {});
assert.strictEqual(clamped[0].value, "slide", "an unknown mode falls back to slide");
assert.strictEqual(clamped[1].value, 10, "the countdown is capped at ten seconds");
assert.strictEqual(clamped[5].value, 100);
assert.strictEqual(L.sosEntries({ mode: "hold", countdown_s: -5 }, {})[0].value, "hold",
  "hold stays selectable so an older configuration round-trips");
assert.strictEqual(L.sosEntries({ mode: "hold", countdown_s: -5 }, {})[1].value, 0);

// ---- battery ----------------------------------------------------------------------------------
assert.deepStrictEqual(L.powerModel(undefined),
  { known: false, hasBattery: false, pct: -1, charging: false, mains: false, text: "" });
const battery = L.powerModel({ battery_pct: 82, charging: true, mains: true });
assert.strictEqual(battery.known, true);
assert.strictEqual(battery.hasBattery, true);
assert.strictEqual(battery.text, "82%");
assert.strictEqual(battery.charging, true);
// -1 means "no battery": the UI must show nothing rather than a zero-percent indicator.
const mainsOnly = L.powerModel({ battery_pct: -1, charging: false, mains: true });
assert.strictEqual(mainsOnly.known, true);
assert.strictEqual(mainsOnly.hasBattery, false);
assert.strictEqual(mainsOnly.text, "");
assert.strictEqual(L.powerModel({ battery_pct: 250 }).pct, 100);

// ---- every string these surfaces reference must exist in all three catalogs ------------------
const referenced = [
  "time.title", "time.zone", "time.zone_hint", "time.ntp_enabled", "time.ntp_hint",
  "time.servers", "time.servers_hint", "time.interval_s", "time.sync_now", "time.status",
  "time.source", "time.source_system", "time.source_ntp", "time.offset", "time.last_sync",
  "time.server", "time.rtt", "time.never", "time.local_now", "time.sync_started",
  "time.sync_failed", "time.err_no_response", "time.err_bad_server", "time.err_bad_reply",
  "time.err_implausible", "time.ntp_off", "time.invalid_zone", "time.invalid_servers",
  "time.invalid_interval",
  "volume.title", "volume.call", "volume.sos", "volume.idle", "volume.preview", "volume.hint",
  "volume.device_title", "volume.inherit", "volume.cluster_default",
  "notice.title", "notice.text", "notice.expiry", "notice.expiry_1h", "notice.expiry_today",
  "notice.expiry_until_cleared", "notice.expiry_custom", "notice.expiry_hours",
  "notice.publish", "notice.clear", "notice.none", "notice.active", "notice.from",
  "notice.expires_at", "notice.preview", "notice.empty", "notice.too_long", "notice.saved",
  "notice.cleared", "notice.failed",
  "sos.title", "sos.trigger_mode", "sos.mode_slide", "sos.mode_hold", "sos.countdown_s",
  "sos.button_on_roles", "sos.cancel_requires_pin", "sos.alarm_sound", "sos.alarm_volume",
  "sos.slide_hint", "sos.countdown", "sos.hint",
  "power.title", "power.charging", "power.mains", "power.no_battery", "power.unknown"
].concat(L.NOTICE_PRESET_KEYS);
for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  for (const key of referenced)
    assert.ok(Object.prototype.hasOwnProperty.call(catalog, key),
      language + " is missing " + key);
}
// The placeholders the UI substitutes must survive translation.
for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  assert.ok(catalog["notice.too_long"].includes("{n}"), language + " notice.too_long needs {n}");
  assert.ok(catalog["sos.countdown"].includes("{n}"), language + " sos.countdown needs {n}");
  assert.ok(catalog["volume.cluster_default"].includes("{value}"),
    language + " volume.cluster_default needs {value}");
}

// ---- the admin page must reference the new endpoints and the mock must answer them -----------
const adminSource = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
assert.ok(adminSource.includes('"/api/time/sync"'), "the time card must call POST /api/time/sync");
assert.ok(adminSource.includes('"/api/doors/" + encodeURIComponent(door) + "/notice"'),
  "the announcement editor must call the notice endpoint with an encoded door id");
assert.ok(/if \(p === "\/api\/time\/sync"\)/.test(adminSource),
  "the mock must answer /api/time/sync so the panel works standalone");
assert.ok(/api\\\/doors\\\/\[\^\\\/\]\+\\\/notice/.test(adminSource),
  "the mock must answer the notice endpoint");

console.log("settings tests: ok");

// ---- the incoming-call return countdown ---------------------------------------------------
// An indoor panel counts down in the call-screen title and returns home at zero. The value is a
// cluster default with a per-device override, resolved the same way core resolves it.
assert.strictEqual(L.CALL_RETURN_DEFAULT, 60);
assert.strictEqual(L.CALL_RETURN_MIN, 5);
assert.strictEqual(L.CALL_RETURN_MAX, 600);
assert.deepStrictEqual(L.callReturnSeconds({}, "dev1"), { seconds: 60, source: "default" });
assert.deepStrictEqual(L.callReturnSeconds({ call: { indoor: { return_s: 45 } } }, "dev1"),
  { seconds: 45, source: "cluster" });
assert.deepStrictEqual(L.callReturnSeconds({
  call: { indoor: { return_s: 45 } },
  devices: { dev1: { local: { call: { return_s: 20 } } } }
}, "dev1"), { seconds: 20, source: "device" });
// A device without an override of its own still follows the cluster.
assert.strictEqual(L.callReturnSeconds({
  call: { indoor: { return_s: 45 } },
  devices: { dev1: { local: { call: { return_s: 20 } } } }
}, "dev2").source, "cluster");
// An out-of-range stored value is clamped rather than shown as-is.
assert.strictEqual(L.callReturnSeconds({ call: { indoor: { return_s: 5000 } } }, "d").seconds,
  600);
assert.strictEqual(L.callReturnSeconds({ call: { indoor: { return_s: 1 } } }, "d").seconds, 5);

assert.deepStrictEqual(L.callReturnEntries(45), [{ key: "call.indoor.return_s", value: 45 }]);
assert.deepStrictEqual(L.callReturnEntries("45"), [{ key: "call.indoor.return_s", value: 45 }]);
for (const bad of [4, 601, "", "abc"])
  assert.throws(() => L.callReturnEntries(bad), "should refuse " + bad);

assert.deepStrictEqual(L.deviceCallReturnEntries("dev1", { inherit: false, seconds: 20 }),
  { entries: [{ key: "devices.dev1.local.call.return_s", value: 20 }], dels: [] });
// Inheriting deletes the leaf instead of copying the cluster value into the device.
assert.deepStrictEqual(L.deviceCallReturnEntries("dev1", { inherit: true }),
  { entries: [], dels: ["devices.dev1.local.call.return_s"] });
assert.throws(() => L.deviceCallReturnEntries("dev1", { inherit: false, seconds: 601 }));

for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  for (const key of ["call.return_title", "call.return_s", "call.return_hint",
                     "call.return_device_hint", "call.return_inherit", "call.return_invalid"])
    assert.ok(Object.prototype.hasOwnProperty.call(catalog, key),
      language + " is missing " + key);
}

console.log("call return tests: ok");
