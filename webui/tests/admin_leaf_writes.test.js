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

// ---- Visitor flow: leaves for the top-level keys, one whole object per step, one batch ----
{
  const page = { kind: "page", title: { en: "Hello" }, body: { en: "Text" },
    options: [{ id: "o_call", label: { en: "Call" }, style: "primary", to: "c_any" }] };
  const cfg = { ui: { languages: ["en"] }, visit_purposes: { p_visit: { label: { en: "Visit" } } },
    visitor_flow: { enabled: true, start: "s_home", idle_s: 45, require_call: true,
      steps: { s_home: page, c_any: { kind: "call" }, e_old: { kind: "end" } } },
    doors: { d_front: { label: { en: "Front" } } } };
  const stepKey = /^visitor_flow\.steps\.[^.]+$/;
  const noKeyBelowStep = list => { for (const op of list) assert(!/^visitor_flow\.steps\.[^.]+\./.test(op.key), op.key + " is below a step"); };

  // Editing one step rewrites that step whole; dropped members travel as remove_fields.
  let draft = L.flowDraftFromConfig(cfg);
  draft.steps.s_home.title = { en: "Welcome" };
  delete draft.steps.s_home.body;
  draft.steps.c_any.purpose = "p_visit";
  draft.idle_s = 60;
  delete draft.steps.e_old;
  draft.door_starts.d_front = "s_home";
  let plan = L.flowEntries(cfg, draft);
  list = ops(cfg, plan.entries, plan.dels);
  noKeyBelowStep(list);
  assert.deepStrictEqual(byKey(list), byKey([
    { op: "set", key: "visitor_flow.idle_s", value: 60 },
    { op: "set", key: "visitor_flow.steps.s_home", value: draft.steps.s_home, remove_fields: ["body"] },
    { op: "set", key: "visitor_flow.steps.c_any", value: { kind: "call", purpose: "p_visit" } },
    { op: "delete", key: "visitor_flow.steps.e_old" },
    { op: "set", key: "doors.d_front.visitor_flow.start", value: "s_home" }]));

  // Changing a step's kind drops the members the new kind does not carry.
  draft = L.flowDraftFromConfig(cfg);
  draft.steps.s_home = { kind: "call" };
  plan = L.flowEntries(cfg, draft);
  list = ops(cfg, plan.entries, plan.dels);
  const rewritten = list.filter(op => stepKey.test(op.key));
  assert.strictEqual(rewritten.length, 1);
  assert.deepStrictEqual(rewritten[0].value, { kind: "call" });
  assert.deepStrictEqual(rewritten[0].remove_fields.slice().sort(), ["body", "options", "title"]);

  // Nothing changed, nothing written. A new step is a plain whole object.
  draft = L.flowDraftFromConfig(cfg);
  assert.deepStrictEqual(L.flowEntries(cfg, draft), { entries: [], dels: [] });
  draft.steps.s_new = { kind: "end", return_s: 5 };
  plan = L.flowEntries(cfg, draft);
  assert.deepStrictEqual(ops(cfg, plan.entries, plan.dels), [{ op: "set", key: "visitor_flow.steps.s_new", value: { kind: "end", return_s: 5 } }]);

  // Customizing the built-in wizard (nothing stored) writes every leaf and every step, no container.
  const bare = { doors: {} };
  const tpl = { enabled: true, start: "s_home", idle_s: 45, require_call: true,
    steps: { s_home: page, c_any: { kind: "call" } } };
  draft = L.flowDraftFromTemplate(tpl, bare);
  plan = L.flowEntries(bare, draft);
  list = ops(bare, plan.entries, plan.dels);
  noKeyBelowStep(list);
  assert.deepStrictEqual(list.map(op => op.key), ["visitor_flow.enabled", "visitor_flow.start", "visitor_flow.idle_s",
    "visitor_flow.require_call", "visitor_flow.steps.s_home", "visitor_flow.steps.c_any"]);
  assert(!list.some(op => op.remove_fields), "a new step has nothing to remove");

  // Replacing a flow with a template deletes the steps that go away, in the same batch.
  draft = L.flowDraftFromTemplate(tpl, cfg);
  plan = L.flowEntries(cfg, draft);
  assert.deepStrictEqual(plan.dels, ["visitor_flow.steps.e_old"]);

  // Reset to the built-in wizard is one delete of visitor_flow.
  assert.deepStrictEqual(ops(cfg, [], ["visitor_flow"]), [{ op: "delete", key: "visitor_flow" }]);

  // A step kept after a revision conflict is still committed whole, with the current members dropped.
  const changes = L.configIntents(cfg, L.configBatchOps([{ key: "visitor_flow.steps.c_any", value: { kind: "call", purpose: "p_visit" } }]), true);
  const concurrent = JSON.parse(JSON.stringify(cfg));
  concurrent.visitor_flow.steps.c_any = { kind: "call" };
  const merged = L.configRebase(changes, concurrent);
  assert.strictEqual(merged.conflicts.length, 0);
  assert.deepStrictEqual(L.configIntentOps(merged.changes), [{ op: "set", key: "visitor_flow.steps.c_any", value: { kind: "call", purpose: "p_visit" } }]);
  concurrent.visitor_flow.steps.c_any = { kind: "call", on_unanswered: "s_home" };
  const changed = L.configRebase(changes, concurrent);
  assert.strictEqual(changed.conflicts.length, 1, "a concurrent edit of the same step is reviewed, not overwritten");
}

// The editor saves with the plain batch: whole steps, no remove_fields, no containers; a draft is
// refused when the flow changed under it.
{
  const cfg = { visitor_flow: { start: "s", steps: { s: { kind: "page", body: { en: "b" }, options: [{ id: "o", to: "c" }] }, c: { kind: "call" } } },
    doors: { d: { visitor_flow: { start: "s" } } } };
  const draft = L.flowDraftFromConfig(cfg);
  delete draft.steps.s.body;
  draft.steps.n = { kind: "end" };
  const plan = L.flowEntries(cfg, draft);
  assert.deepStrictEqual(L.flowBatchOps(plan), [
    { op: "set", key: "visitor_flow.steps.s", value: { kind: "page", options: [{ id: "o", to: "c" }] } },
    { op: "set", key: "visitor_flow.steps.n", value: { kind: "end" } }]);
  const changed = JSON.parse(JSON.stringify(cfg));
  assert.strictEqual(L.flowSignature(cfg), L.flowSignature(changed));
  changed.visitor_flow.steps.c.purpose = "p";
  assert.notStrictEqual(L.flowSignature(cfg), L.flowSignature(changed));
  changed.visitor_flow = cfg.visitor_flow; changed.doors.d.visitor_flow.start = "other";
  assert.notStrictEqual(L.flowSignature(cfg), L.flowSignature(changed));
}

// Stale-draft protection: the editor opened with one signature; a snapshot that differs in the flow
// or a per-door start is refused before anything is sent, an unrelated change is not.
{
  const opened = { visitor_flow: { start: "s", steps: { s: { kind: "page", options: [{ id: "o", to: "c" }] }, c: { kind: "call" } } },
    doors: { d: { visitor_flow: { start: "s" } } }, ui: { languages: ["en"] } };
  const baseline = L.flowSignature(opened);
  assert.strictEqual(L.flowDraftStale(baseline, JSON.parse(JSON.stringify(opened))), false);
  const unrelated = JSON.parse(JSON.stringify(opened)); unrelated.ui.languages = ["en", "ja"];
  assert.strictEqual(L.flowDraftStale(baseline, unrelated), false, "a change outside the flow does not block a save");
  for (const edit of [(c) => { c.visitor_flow.idle_s = 61; }, (c) => { c.visitor_flow.steps.c.order = 1; },
      (c) => { delete c.visitor_flow.steps.c; }, (c) => { c.doors.d.visitor_flow.start = "x"; }, (c) => { delete c.visitor_flow; }]) {
    const moved = JSON.parse(JSON.stringify(opened)); edit(moved);
    assert.strictEqual(L.flowDraftStale(baseline, moved), true);
  }
  // Refusals that are not flow errors: the conflict journal and a moved configuration.
  assert.strictEqual(L.flowSaveFailureKey("unresolved_config_conflict"), "flow_editor.conflict_blocked");
  assert.strictEqual(L.flowSaveFailureKey("config_conflict"), "admin.partition_changed");
  assert.strictEqual(L.flowSaveFailureKey("stale_config_resolution"), "admin.partition_changed");
  assert.strictEqual(L.flowSaveFailureKey("visitor_flow.text_too_long: s.title.en"), "");
  assert.strictEqual(L.flowParseError("unresolved_config_conflict"), null, "a conflict is not shown as a flow error");
}

// Core's refusal names the step and option; the editor shows it next to that field.
{
  const pe = (text, detail) => {
    const i = L.flowParseError(text, detail);
    return i && [i.code, i.step, i.option, i.field, i.lang, i.door].join("|");
  };
  assert.strictEqual(pe("visitor_flow.unknown_target: s_x.o"), "unknown_target|s_x|o|||");
  assert.strictEqual(pe("visitor_flow.unknown_target: s_x"), "unknown_target|s_x||||");
  assert.strictEqual(pe("visitor_flow.missing_start"), "missing_start|||||");
  assert.strictEqual(pe("visitor_flow.text_too_long: s_home.title.ja", { lang: "ja", limit: 60, value: 70 }), "text_too_long|s_home||title|ja|");
  assert.strictEqual(pe("visitor_flow.too_many_paragraphs: s_home.body.zh-CN"), "too_many_paragraphs|s_home||body|zh-CN|");
  assert.strictEqual(pe("visitor_flow.text_too_long: s_parcel.o_3.label.en"), "text_too_long|s_parcel|o_3|label|en|");
  assert.strictEqual(pe("visitor_flow.text_required: s_parcel.o_3.label"), "text_required|s_parcel|o_3|label||");
  assert.strictEqual(pe("visitor_flow.text_required: n_1.message"), "text_required|n_1||message||");
  assert.strictEqual(pe("visitor_flow.text_too_long: n_1.message.en"), "text_too_long|n_1||message|en|");
  assert.strictEqual(pe("visitor_flow.unknown_asset: s_home.images[1]"), "unknown_asset|s_home||image.1||");
  assert.strictEqual(pe("visitor_flow.text_too_long: s_home.images[0].alt.en"), "text_too_long|s_home||image.0.alt|en|");
  assert.strictEqual(pe("visitor_flow.unknown_field: s_home.images[0]"), "unknown_field|s_home||image.0||");
  assert.strictEqual(pe("visitor_flow.unknown_start: start"), "unknown_start|start||||");
  assert.strictEqual(pe("visitor_flow.start_not_page: doors.d_front.start"), "start_not_page||||" + "|d_front");
  assert.strictEqual(pe("visitor_flow.no_reachable_call: start"), "no_reachable_call|start||||");
  assert.strictEqual(pe("visitor_flow.bad_idle_s", { min: 15, max: 300 }), "bad_idle_s|||idle_s||");
  assert.deepStrictEqual(L.flowParseError("visitor_flow.bad_idle_s", { min: 15, max: 300 }).detail, { min: 15, max: 300 });
  assert.strictEqual(L.flowParseError("visitor_flow.brand_new_code: s_x").key, "flow_error.brand_new_code", "an unknown code keeps its code");
  assert.strictEqual(L.flowParseError("config_conflict"), null);

  // Placeholders come from detail; {lang} is the display name.
  const issue = L.flowParseError("visitor_flow.text_too_long: s.title.ja", { lang: "ja", limit: 60, value: 71 });
  assert.strictEqual(L.flowFillMessage("Text is too long ({lang}: limit {limit}, now {value})", issue, "Japanese"), "Text is too long (Japanese: limit 60, now 71)");
  assert.strictEqual(L.flowFillMessage("Set {min}-{max}", L.flowParseError("visitor_flow.bad_idle_s", { min: 15, max: 300 })), "Set 15-300");
  assert.strictEqual(L.flowFillMessage("limit {limit}", { detail: {} }), "limit {limit}", "a missing number stays visible");

  // Editing the control a refusal named dismisses it; other controls do not.
  const draft = { steps: { s: { kind: "page", options: [{ id: "a" }, { id: "b" }] }, n: { kind: "notify" } } };
  const touches = (text, fp) => L.flowIssueTouches(L.flowParseError(text), draft, fp);
  assert.strictEqual(touches("visitor_flow.text_too_long: s.title.ja", "steps.s.title.ja"), true);
  assert.strictEqual(touches("visitor_flow.text_too_long: s.title.ja", "steps.s.title.en"), false);
  assert.strictEqual(touches("visitor_flow.text_too_long: s.b.label.en", "steps.s.options.1.label.en"), true);
  assert.strictEqual(touches("visitor_flow.text_too_long: s.b.label.en", "steps.s.options.0.label.en"), false);
  assert.strictEqual(touches("visitor_flow.unknown_target: s.b", "steps.s.options.1.to"), true);
  assert.strictEqual(touches("visitor_flow.unknown_target: s.b", "steps.s.options.0.to"), false);
  assert.strictEqual(touches("visitor_flow.unknown_asset: s.images[1]", "steps.s.images.1.asset"), true);
  assert.strictEqual(touches("visitor_flow.unknown_asset: s.images[1]", "steps.s.images.0.asset"), false);
  assert.strictEqual(touches("visitor_flow.no_options: s", "steps.s.title.en"), true);
  assert.strictEqual(touches("visitor_flow.no_options: s", "steps.n.message.en"), false);
  assert.strictEqual(touches("visitor_flow.unknown_start: start", "start"), true);
  assert.strictEqual(touches("visitor_flow.unknown_start: doors.d1.start", "door_starts.d1"), true);
  assert.strictEqual(touches("visitor_flow.bad_idle_s", "idle_s"), true);
}
console.log("admin leaf-key commits: PASS");
