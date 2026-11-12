"use strict";
// Admin commits changed fields at their own leaf keys. Core lets a leaf entry replace the same
// member of a parent object entry whichever is newer, so a field saved inside an object patch
// could be hidden by a leaf a native shell wrote on another replica. These tests pin the op shape
// of the save paths that share objects with the native shells.
const assert = require("assert");
const L = require("../admin/app.js");

const DEV = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
function ops(base, entries, dels) {
  return L.configIntentOps(L.configIntents(base, L.configBatchOps(entries, dels), true));
}
function byKey(list) {
  const out = {};
  for (const op of list) out[op.key] = op;
  return out;
}
// No op may set a key that currently holds an object: that would store a whole-object entry.
function assertLeavesOnly(base, list, label) {
  const keys = list.map(op => op.key);
  assert.strictEqual(new Set(keys).size, keys.length, label + ": duplicate keys");
  for (const op of list) {
    assert(!op.remove_fields, label + ": " + op.key + " uses an object patch");
    if (op.op !== "set") continue;
    const current = L.configAt(base, op.key);
    assert(current === undefined || current === null || typeof current !== "object" || Array.isArray(current),
      label + ": " + op.key + " overwrites an object");
  }
  for (const key of keys) for (const other of keys)
    assert(other === key || other.indexOf(key + ".") !== 0, label + ": " + key + " overlaps " + other);
}

// ---- Device camera and motion (the kiosk and the Swift shell write these leaves) ----
const device = { name: "front", role: "door_station", door: "d_front",
  local: { ui_lang: "ja", video: { playback: "low_latency", rotation: "auto" },
           recovery: { helper_mode: "auto" },
           camera: { device_hint: "", mjpeg_fps: 8, mjpeg_quality: 60, resolution: "640x480",
                     codec: "auto", h264_resolution: "640x360", h264_fps: 30,
                     h264_bitrate_kbps: 700, future_field: 1 },
           motion: { enabled: true, wake_screen: false, sensitivity: 40, min_interval_s: 30 } } };
let base = { devices: { [DEV]: device } };
const form = { name: "front", role: "door_station", door: "d_front", ui_lang: "ja",
  video_playback: "low_latency", video_rotation: "auto", helper_mode: "auto", cam_hint: "",
  cam_fps: 15, cam_quality: 60, cam_resolution: "640x480", cam_codec: "auto",
  cam_h264_resolution: "640x360", cam_h264_fps: 30, cam_h264_bitrate: 700,
  motion_enabled: false, motion_sensitivity: 40, motion_interval: 30 };
let list = ops(base, L.deviceEntries(DEV, form, device));
assertLeavesOnly(base, list, "device");
assert.deepStrictEqual(list, [
  { op: "set", key: "devices." + DEV + ".local.camera.mjpeg_fps", value: 15 },
  { op: "set", key: "devices." + DEV + ".local.motion.enabled", value: false }]);

// A device with no camera settings yet still gets them as one new object: nothing exists there
// for a leaf to collide with.
const bare = { devices: { [DEV]: { name: "front", role: "door_station", door: "d_front" } } };
list = ops(bare, L.deviceEntries(DEV, form, bare.devices[DEV]));
assert.strictEqual(typeof byKey(list)["devices." + DEV + ".local.camera"].value, "object");

// ---- Theme: colours, ink, backdrop, glass, background image ----
const theme = { bg_color: "#12202c", call_button_bg: "#7F5E3D", ink_override: { clock: "#FFFFFF", date: "#EEEEEE" },
                backdrop: { enabled: true, color: "#000000", opacity: 55 }, glass: { blur_radius: 32 } };
base = { display: { theme: theme } };
let themed = L.themeEntries("", { bg_color: "#101418", bg_image: "ab".repeat(32) }, theme);
let color = L.themeColorEntries("", { call_button_auto: true, ink_override: { clock: "#FFFFFF" },
  backdrop: { enabled: true, color: "#000000", opacity: 70 }, glass: { blur_radius: 20 } },
  themed.entries.filter(e => e.key === "display.theme")[0].value);
list = ops(base, color.entries.concat(themed.entries.filter(e => e.key !== "display.theme")),
           themed.dels.concat(color.dels));
assertLeavesOnly(base, list, "theme");
assert.deepStrictEqual(byKey(list), byKey([
  { op: "set", key: "display.theme.bg_color", value: "#101418" },
  { op: "delete", key: "display.theme.call_button_bg" },
  { op: "delete", key: "display.theme.ink_override.date" },
  { op: "set", key: "display.theme.backdrop.opacity", value: 70 },
  { op: "set", key: "display.theme.glass.blur_radius", value: 20 },
  { op: "set", key: "display.theme.bg_image", value: "ab".repeat(32) }]));

// A per-device theme behaves the same under its own key.
base = { devices: { [DEV]: { local: { theme: { bg_color: "#1c1030", backdrop: { opacity: 40 } } } } } };
color = L.themeColorEntries(DEV, { call_button_auto: true, ink_override: {},
  backdrop: { opacity: 60 } }, base.devices[DEV].local.theme);
list = ops(base, color.entries, color.dels);
assertLeavesOnly(base, list, "device theme");
assert.deepStrictEqual(list, [{ op: "set", key: "devices." + DEV + ".local.theme.backdrop.opacity", value: 60 }]);

// ---- Screensaver, appearance schedule, door unlock ----
base = { display: { appearance: "auto_schedule", appearance_schedule: { dark_from: "19:00", light_from: "06:30" },
                    screensaver: { enabled: true, mode: "dim", schedule: "always", from: "22:00", to: "06:00",
                                   after_s: 120, brightness: 10 } },
         doors: { d_front: { label: { en: "Front" }, unlock: { command: "unlock", show_button: true } } } };
let saver = L.screensaverEntries("", { override: true, enabled: true, mode: "clock", schedule: "always",
  from: "22:00", to: "06:00", after_s: 300, brightness: 10 });
list = ops(base, saver.entries.concat(L.appearanceEntries("", { mode: "auto_schedule", dark_from: "20:00",
  light_from: "06:30" })), saver.dels);
assertLeavesOnly(base, list, "display");
assert.deepStrictEqual(byKey(list), byKey([
  { op: "set", key: "display.screensaver.mode", value: "clock" },
  { op: "set", key: "display.screensaver.after_s", value: 300 },
  { op: "set", key: "display.appearance_schedule.dark_from", value: "20:00" }]));
let unlock = L.doorUnlockEntries("d_front", "hide", base.doors.d_front.unlock, "gate");
list = ops(base, unlock.entries, unlock.dels);
assertLeavesOnly(base, list, "unlock");
assert.deepStrictEqual(byKey(list), byKey([
  { op: "set", key: "doors.d_front.unlock.command", value: "gate" },
  { op: "set", key: "doors.d_front.unlock.show_button", value: false }]));
unlock = L.doorUnlockEntries("d_front", "auto", base.doors.d_front.unlock);
assert.deepStrictEqual(ops(base, unlock.entries, unlock.dels),
  [{ op: "delete", key: "doors.d_front.unlock.show_button" }]);

// ---- Lists the shells also edit: doors, purposes, quick replies, recipients, rules, SIP ----
base = { doors: { d_front: { label: { en: "Front", ja: "玄関" }, building: "b_main" } },
         visit_purposes: { p_visit: { label: { en: "Visit" }, icon: "x", order: 1 } },
         quick_replies: { qr_away: { label: { en: "Away" }, speak: true, order: 1, audio: { en: "aa", ja: "bb" } } },
         households: { h_ox: { label: { en: "Owner" }, telegram_chat_ids: [1], sip_extensions: ["201"] } },
         trigger_rules: { r1: { enabled: true, when: { type: "button", doors: ["d_front"] },
                                actions: [{ type: "ha_event" }] } },
         sip: { accounts: { [DEV]: { user: "door", pass_ref: "secret:sip.x" } } },
         quiet_hours: { "default": { windows: [{ from: "23:00", to: "07:00" }], suppress: ["chime"], never_suppress: [] } },
         emergency: { trigger: { mode: "slide", countdown_s: 3 }, button_on_roles: ["indoor_panel"] } };
list = ops(base, L.doorEntries("d_front", { en: "Front door", ja: "玄関", zh: "", building: "b_main" }, base.doors.d_front));
assertLeavesOnly(base, list, "door");
assert.deepStrictEqual(list, [{ op: "set", key: "doors.d_front.label.en", value: "Front door" }]);
list = ops(base, L.quickReplyEntries("qr_away", { en: "Away", ja: "", zh: "", speak: false, order: 1,
  audio: { en: "cc", ja: "" } }, base.quick_replies.qr_away));
assertLeavesOnly(base, list, "quick reply");
assert.deepStrictEqual(byKey(list), byKey([
  { op: "set", key: "quick_replies.qr_away.speak", value: false },
  { op: "set", key: "quick_replies.qr_away.audio.en", value: "cc" },
  { op: "delete", key: "quick_replies.qr_away.audio.ja" }]));
list = ops(base, [{ key: "visit_purposes.p_visit.enabled", value: false }]);
assert.deepStrictEqual(list, [{ op: "set", key: "visit_purposes.p_visit.enabled", value: false }]);
list = ops(base, [{ key: "trigger_rules.r1", value: { enabled: false, when: { type: "button", doors: ["d_front"] },
                                                        actions: [{ type: "ha_event" }] } }]);
assertLeavesOnly(base, list, "rule");
assert.deepStrictEqual(list, [{ op: "set", key: "trigger_rules.r1.enabled", value: false }]);
list = ops(base, L.sipAccountEntries(DEV, "door-front", "", base.sip.accounts[DEV]));
assert.deepStrictEqual(list, [{ op: "set", key: "sip.accounts." + DEV + ".user", value: "door-front" }]);
list = ops(base, L.quietEntries({ windows: [{ from: "22:00", to: "07:00", _existing_index: 0 }], suppress: ["chime"],
  never_suppress: [] }, base.quiet_hours["default"]));
assertLeavesOnly(base, list, "quiet hours");
assert.deepStrictEqual(list, [{ op: "set", key: "quiet_hours.default.windows", value: [{ from: "22:00", to: "07:00" }] }]);
list = ops(base, L.sosEntries({ mode: "hold", countdown_s: 3, button_on_roles: ["indoor_panel"],
  cancel_requires_pin: true, alarm_sound: "siren1", alarm_volume: 100 }, base.emergency));
assertLeavesOnly(base, list, "sos");
assert.strictEqual(byKey(list)["emergency.trigger.mode"].value, "hold");

// ---- A change kept after a revision conflict is still committed as a leaf ----
base = { display: { theme: { bg_color: "#12202c", backdrop: { opacity: 55 } } } };
let changes = L.configIntents(base, L.configBatchOps([{ key: "display.theme",
  value: { bg_color: "#101418", backdrop: { opacity: 70 } } }]), true);
let rebased = L.configRebase(changes, { display: { theme: { bg_color: "#12202c", backdrop: { opacity: 55 }, glass: { blur_radius: 9 } } } });
assert.strictEqual(rebased.conflicts.length, 0);
assert.deepStrictEqual(L.configIntentOps(rebased.changes), [
  { op: "set", key: "display.theme.bg_color", value: "#101418" },
  { op: "set", key: "display.theme.backdrop.opacity", value: 70 }]);

// ---- Exceptions that must stay one value ----
// Field names with dots cannot be dot-path keys: translation overrides remain an object patch.
base = { i18n_overrides: { en: { "idle.touch_to_call": "Touch" } } };
let texts = L.i18nEntries(base.i18n_overrides, { en: { "calling.title": "Ringing" } });
assert.deepStrictEqual(L.configIntentOps(L.configIntents(base, L.configBatchOps(texts.entries, texts.dels))),
  [{ op: "set", key: "i18n_overrides.en", value: { "calling.title": "Ringing" } }]);
// Clearing one translation removes that field from the same patch instead of failing.
base = { i18n_overrides: { en: { "idle.touch_to_call": "Touch", "calling.title": "Ringing", plain: "p" } } };
texts = L.i18nEntries(base.i18n_overrides, { en: { "calling.title": "", plain: "q", "incall.end": "Stop" } });
assert.deepStrictEqual(ops(base, texts.entries, texts.dels),
  [{ op: "set", key: "i18n_overrides.en", value: { plain: "q", "incall.end": "Stop" }, remove_fields: ["calling.title"] }]);
// Semantic UI elements are validated and stored one element per key.
const element = "devices." + DEV + ".local.ui.elements.call.primary";
base = { devices: { [DEV]: { local: { ui: { elements: { call: { primary: { scale: 1.2, radius: 10 } } } } } } } };
assert.deepStrictEqual(ops(base, [{ key: element, value: { scale: 1.5 } }]),
  [{ op: "set", key: element, value: { scale: 1.5 }, remove_fields: ["radius"] }]);
// A new entity is created as one object; replacing a scalar or array is one value.
assert.deepStrictEqual(ops({}, [{ key: "households.h_new", value: { label: { en: "New" } } }]),
  [{ op: "set", key: "households.h_new", value: { label: { en: "New" } } }]);
console.log("admin leaf-key commits: PASS");
