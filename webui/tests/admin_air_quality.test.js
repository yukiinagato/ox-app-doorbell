"use strict";
// PM2.5 sensors on the Devices tab: the writes must be ones Core's airQualityConfigValid accepts,
// and the view model must offer only sensors that are not registered yet.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

function seq(values) {
  let i = 0;
  return () => values[i++ % values.length];
}

// ---- names follow Core's 1..40 character limit, counted in code points --------------------
assert.strictEqual(L.airSensorName("  Entrance "), "Entrance");
assert.strictEqual(L.airSensorName(""), null);
assert.strictEqual(L.airSensorName("   "), null);
assert.strictEqual(L.airSensorName("a".repeat(40)), "a".repeat(40));
assert.strictEqual(L.airSensorName("a".repeat(41)), null);
assert.strictEqual(L.airSensorName("😀".repeat(40)), "😀".repeat(40),
  "a surrogate pair is one character, as Core counts UTF-8 code points");

// ---- ids are s_<8 hex> and never collide with an existing sensor --------------------------
const zero = L.airSensorId({}, () => 0);
assert.strictEqual(zero, "s_00000000");
assert.ok(/^s_[0-9a-f]{8}$/.test(L.airSensorId({})));
assert.ok(/^[A-Za-z0-9_-]{1,32}$/.test(L.airSensorId({})), "the id matches Core's id rule");
assert.strictEqual(L.airSensorId({ s_00000000: {} }, seq([0, 0, 0, 0, 0, 0, 0, 0, 0.99])),
  "s_f0000000", "a taken id is drawn again");

// ---- adding writes one full definition with the chosen host and discovered address --------
const cfg = {
  air_sensors: {
    s_aaaaaaaa: { name: "Entrance", host: "dev1", address: "AA-11", kind: "mops_vida_pm25",
                  enabled: true },
    s_gone: null
  },
  devices: {
    dev1: { name: "Door", local: { air_quality: { show: true, sensor: "s_aaaaaaaa", host: true } } },
    dev2: { name: "Living", local: { air_quality: { show: true, sensor: "s_bbbbbbbb" } } },
    dev3: { name: "Hall" }
  }
};
const plan = L.airSensorAddPlan(cfg, "dev2", "BB-22", " Garden ", () => 0.5);
assert.strictEqual(plan.id, "s_88888888");
assert.deepStrictEqual(plan.entries, [{ key: "air_sensors.s_88888888", value: {
  name: "Garden", host: "dev2", address: "BB-22", kind: "mops_vida_pm25", enabled: true } }]);
assert.throws(() => L.airSensorAddPlan(cfg, "dev2", "BB-22", ""), /air_name_invalid/);
assert.throws(() => L.airSensorAddPlan(cfg, "dev1", "AA-11", "Again"), /air_address_taken/);
assert.doesNotThrow(() => L.airSensorAddPlan(cfg, "dev2", "AA-11", "Other host"),
  "a BLE identifier is host-local, so the same text through another device is a new sensor");
assert.throws(() => L.airSensorAddPlan(cfg, "", "CC", "x"), /air_address_invalid/);
assert.throws(() => L.airSensorAddPlan(cfg, "dev2", "x".repeat(65), "x"), /air_address_invalid/);
const full = { air_sensors: {} };
for (let i = 0; i < L.AIR_SENSOR_MAX; i++)
  full.air_sensors["s_" + i] = { name: "n" + i, host: "h", address: "a" + i };
assert.throws(() => L.airSensorAddPlan(full, "h", "new", "x"), /air_too_many/,
  "Core holds at most 16 sensors");

// ---- removing deletes the definition and clears the devices that showed it ----------------
assert.deepStrictEqual(L.airSensorRemoveEntries(cfg, "s_aaaaaaaa"), [
  { key: "air_sensors.s_aaaaaaaa", value: null },
  { key: "devices.dev1.local.air_quality.sensor", value: null }]);
assert.deepStrictEqual(L.airSensorRemoveEntries(cfg, "s_unused"),
  [{ key: "air_sensors.s_unused", value: null }]);

// ---- per-device switches write single leaves -----------------------------------------------
assert.deepStrictEqual(L.airDeviceEntries("dev3", "host", true),
  [{ key: "devices.dev3.local.air_quality.host", value: true }]);
assert.deepStrictEqual(L.airDeviceEntries("dev3", "show", false),
  [{ key: "devices.dev3.local.air_quality.show", value: false }]);
assert.deepStrictEqual(L.airDeviceEntries("dev3", "sensor", "s_aaaaaaaa"),
  [{ key: "devices.dev3.local.air_quality.sensor", value: "s_aaaaaaaa" }]);
assert.deepStrictEqual(L.airDeviceEntries("dev3", "sensor", ""),
  [{ key: "devices.dev3.local.air_quality.sensor", value: null }], "(none) clears the choice");
assert.throws(() => L.airDeviceEntries("dev3", "sensor", "bad id"), /air_sensor_invalid/);
assert.throws(() => L.airDeviceEntries("dev3", "volume", 1), /air_field_invalid/);
assert.throws(() => L.airDeviceEntries("", "show", true), /air_device_required/);
// Every write passes the admin's own batch guard.
assert.doesNotThrow(() => L.configBatchOps(
  plan.entries.concat(L.airDeviceEntries("dev3", "show", true)), []));

assert.deepStrictEqual(L.airDeviceSettings(cfg, "dev1"),
  { show: true, host: true, sensor: "s_aaaaaaaa" });
assert.deepStrictEqual(L.airDeviceSettings(cfg, "dev3"), { show: false, host: false, sensor: "" });
assert.deepStrictEqual(L.airDeviceSettings(cfg, "nobody"), { show: false, host: false, sensor: "" });

// ---- support comes from the features a shell advertises -------------------------------------
const status = { features: { air_quality_display_v1: true, ble_air_sensor_v1: true } };
assert.deepStrictEqual(L.airDeviceSupport({ id: "dev1", self: true }, status),
  { display: true, host: true }, "the local device reports features at the top level");
assert.deepStrictEqual(L.airDeviceSupport(
  { id: "dev2", caps: { features: { air_quality_display_v1: true } } }, status),
  { display: true, host: false });
assert.deepStrictEqual(L.airDeviceSupport(
  { id: "dev2", features: { ble_air_sensor_v1: true } }, status), { display: false, host: true });
assert.deepStrictEqual(L.airDeviceSupport(null, status), { display: false, host: false },
  "an unknown device advertises nothing");

// ---- levels mirror core/src/sensors/mops_vida.cpp levelFor ----------------------------------
assert.strictEqual(L.airLevel("moderate", 3), "moderate", "Core's level wins when it is known");
assert.strictEqual(L.airLevel("", 9), "good");
assert.strictEqual(L.airLevel("", 10), "moderate");
assert.strictEqual(L.airLevel("", 55), "sensitive");
assert.strictEqual(L.airLevel("", 125), "unhealthy");
assert.strictEqual(L.airLevel("", 225), "very_unhealthy");
assert.strictEqual(L.airLevel("", 226), "hazardous");
assert.strictEqual(L.airLevel("unknown", -1), "");
const levelSource = fs.readFileSync(
  path.join(__dirname, "../../core/src/sensors/mops_vida.cpp"), "utf8");
for (const bound of ["pm25 <= 9", "pm25 <= 35", "pm25 <= 55", "pm25 <= 125", "pm25 <= 225"])
  assert.ok(levelSource.includes(bound), "Core level bound changed: " + bound);

// ---- the section model ----------------------------------------------------------------------
const model = L.airSectionModel({
  air_quality: {
    sensors: [
      { id: "s_aaaaaaaa", name: "Entrance", host: "dev1", address: "AA-11", enabled: true,
        host_alive: true, level: "moderate",
        reading: { pm25: 12, at_ms: 1763100000000, battery_pct: 80, charging: true,
                   link: "connected" } },
      { id: "s_orphan", name: "Not in config", host: "dev1", address: "ZZ", host_alive: true }],
    hosts: [
      { device: "dev1", ble: "ready", discovered: [
        { address: "AA-11", name: "MOPS", rssi: -50, seen_ms: 1 },
        { address: "CC-33", name: "MOPS", rssi: -80, seen_ms: 2 },
        { address: "DD-44", name: "", rssi: -40, seen_ms: 3 },
        { address: "DD-44", name: "dup", rssi: -40 },
        { address: "" }] },
      { device: "dev2", ble: "sideways", discovered: [] },
      { device: "dev2", ble: "ready", discovered: [{ address: "EE" }] }]
  }
}, cfg);
assert.strictEqual(model.sensors.length, 1, "only configured sensors are listed");
assert.deepStrictEqual(model.sensors[0], {
  id: "s_aaaaaaaa", name: "Entrance", host: "dev1", address: "AA-11", enabled: true,
  hostAlive: true, link: "connected", pm25: 12, level: "moderate", atMs: 1763100000000,
  battery: 80, charging: true });
assert.deepStrictEqual(model.hosts.map((h) => h.device), ["dev1", "dev2"]);
assert.deepStrictEqual(model.hosts[0].discovered.map((f) => f.address), ["DD-44", "CC-33"],
  "registered addresses are not offered again; strongest signal first; duplicates dropped");
assert.strictEqual(model.hosts[1].ble, "unknown", "an unknown Bluetooth state is shown as unknown");
assert.strictEqual(model.full, false);

const waiting = L.airSectionModel({}, { air_sensors: { s_1: { name: "B", host: "h", address: "x" },
                                                      s_2: { name: "A", host: "h", address: "y",
                                                             enabled: false } } });
assert.deepStrictEqual(waiting.sensors.map((s) => s.id), ["s_2", "s_1"], "sorted by name");
assert.strictEqual(waiting.sensors[0].enabled, false);
assert.strictEqual(waiting.sensors[1].pm25, null, "no reading yet");
assert.strictEqual(waiting.sensors[1].hostAlive, false);
assert.strictEqual(waiting.sensors[1].battery, null);
assert.deepStrictEqual(waiting.hosts, []);
assert.strictEqual(L.airSectionModel({}, full).full, true);

// ---- every string the card uses exists in the generated locales ------------------------------
const source = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
const used = new Set([...source.matchAll(/t\("((?:admin\.air_|air\.)[a-z0-9_]+)"/g)].map((m) => m[1]));
for (const level of ["good", "moderate", "sensitive", "unhealthy", "very_unhealthy", "hazardous"])
  assert.ok(used.has("air.level_" + level), "level " + level + " has no label");
for (const ble of ["ready", "off", "unauthorized", "unsupported", "unknown"])
  assert.ok(used.has("admin.air_ble_" + ble), "Bluetooth state " + ble + " has no label");
assert.ok(used.size > 20, "the string scan found too little");
for (const lang of ["en", "ja", "zh"]) {
  const locale = JSON.parse(fs.readFileSync(path.join(__dirname, "../locale/" + lang + ".json"), "utf8"));
  for (const key of used) assert.ok(locale[key], lang + " lacks " + key);
}

console.log("admin_air_quality ok");
