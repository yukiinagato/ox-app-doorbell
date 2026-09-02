"use strict";
// Batch 2 rounds 2/4/7 on the web side: appearance, the automatic theme, announcement targets
// and presets, the unlock toggle, and advisory contrast.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

// ---- the ink regions must be exactly the ones core publishes -------------------------------
const nodeSource = fs.readFileSync(
  path.join(__dirname, "../../core/src/node/node.cpp"), "utf8");
const regionBlock = nodeSource.split("const char* const kInkRegions[] = {")[1].split("};")[0];
const coreRegions = [...regionBlock.matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
assert.deepStrictEqual(L.INK_REGIONS, coreRegions,
  "AdminLogic.INK_REGIONS must mirror kInkRegions in core/src/node/node.cpp");

// ---- the colour maths must agree with db::color, or the preview would lie -------------------
const colorSource = fs.readFileSync(
  path.join(__dirname, "../../core/src/util/color.cpp"), "utf8");
assert.ok(colorSource.includes("kMinButtonContrast = 3.0"));
assert.ok(colorSource.includes("kMinTextContrast = 4.5"));
// The same fixed vector core/tests/test_color.cpp pins.
assert.strictEqual(L.autoAccent("#9BD748", "#FFFFFF"), "#8144D6");
assert.strictEqual(L.autoInk("#9BD748"), "dark");
assert.strictEqual(L.autoInk("#101418"), "light");
assert.strictEqual(L.autoInk("#FFFFFF"), "dark");
assert.strictEqual(L.autoInk("#000000"), "light");
assert.strictEqual(L.autoAccent("#101418", "#FFFFFF"), "#7F5E3D");
for (const background of ["#9BD748", "#FFFFFF", "#101418", "#000000", "#E8E2D5"]) {
  const button = L.autoAccent(background, "#FFFFFF");
  assert.ok(L.contrast(button, background) >= 3, "button separation for " + background);
  assert.ok(L.contrast("#FFFFFF", button) >= 4.5, "white on button for " + background);
}
// An unparseable background cannot crash the preview.
assert.ok(L.colorOk(L.autoAccent("nonsense", "#FFFFFF")));

// ---- the theme model prefers what core published, and falls back to a local computation ----
const publishedStatus = {
  display: { theme: { auto_background: { color: "#12202C", source: "image" },
                      auto_accent: { call_button: "#AA5522", call_button_ink: "light" },
                      ink_override: { clock: "#FF8800" } } }
};
const published = L.themeAutoModel(publishedStatus, "");
assert.strictEqual(published.callButton, "#AA5522", "core's answer wins when it has one");
assert.strictEqual(published.source, "image");
assert.deepStrictEqual(published.inkOverride, { clock: "#FF8800" });
// While the operator is still editing a colour, the preview computes it locally instead.
const previewing = L.themeAutoModel(publishedStatus, "#9BD748");
assert.strictEqual(previewing.callButton, "#8144D6");
assert.strictEqual(previewing.ink, "dark");
assert.strictEqual(previewing.callButtonInk, L.autoInk(previewing.callButton));
assert.strictEqual(L.themeAutoModel({}, "").callButton, L.autoAccent("#101418", "#FFFFFF"));

// ---- theme colour overrides ------------------------------------------------------------------
const auto = L.themeColorEntries("", { call_button_auto: true, ink_override: {} },
                                 { bg_color: "#101418" });
assert.deepStrictEqual(auto.entries, [{ key: "display.theme", value: { bg_color: "#101418" } }]);
const custom = L.themeColorEntries("", {
  call_button_auto: false, call_button_bg: "#1155AA",
  ink_override: { clock: "#FF8800", nonsense: "#FF8800", date: "orange" }
}, { bg_color: "#101418" });
assert.deepStrictEqual(custom.entries[0].value, {
  bg_color: "#101418", call_button_bg: "#1155AA", ink_override: { clock: "#FF8800" }
}, "unknown regions and malformed colours are dropped before the write");
// Returning to automatic deletes the override rather than storing a matching colour.
const cleared = L.themeColorEntries("", { call_button_auto: true, ink_override: {} },
                                    { call_button_bg: "#1155AA", ink_override: { clock: "#F00" } });
assert.deepStrictEqual(cleared.entries, []);
assert.deepStrictEqual(cleared.dels, ["display.theme"]);
// Core's computed fields are never written back.
const roundTrip = L.themeColorEntries("dev1", { call_button_auto: false,
                                                call_button_bg: "#1155AA", ink_override: {} },
                                      { auto_ink: { clock: "dark" },
                                        auto_accent: { call_button: "#000000" },
                                        auto_background: { color: "#101418" },
                                        call_button_ink: "light" });
assert.deepStrictEqual(roundTrip.entries, [
  { key: "devices.dev1.local.theme", value: { call_button_bg: "#1155AA" } }
]);

// ---- appearance --------------------------------------------------------------------------------
assert.deepStrictEqual(L.appearanceEntries("", { mode: "auto_schedule", dark_from: "19:00",
                                                 light_from: "06:30" }), [
  { key: "display.appearance", value: "auto_schedule" },
  { key: "display.appearance_schedule", value: { dark_from: "19:00", light_from: "06:30" } }
]);
// A per-device override writes only the mode; the schedule stays a cluster setting.
assert.deepStrictEqual(L.appearanceEntries("dev1", { mode: "dark", dark_from: "19:00",
                                                     light_from: "06:30" }), [
  { key: "devices.dev1.local.display.appearance", value: "dark" }
]);
assert.strictEqual(L.appearanceEntries("", { mode: "sepia" })[0].value, "auto_system");
const appearance = L.appearanceModel(
  { display: { appearance: { effective: "dark", follow_system: false } } },
  { display: { appearance: "auto_schedule",
               appearance_schedule: { dark_from: "20:00", light_from: "07:00" } } }, "");
assert.strictEqual(appearance.configured, "auto_schedule");
assert.strictEqual(appearance.effective, "dark");
assert.strictEqual(appearance.darkFrom, "20:00");
// A device override wins over the cluster default in the form, as it does in core.
const perDevice = L.appearanceModel({}, {
  display: { appearance: "dark" },
  devices: { dev1: { local: { display: { appearance: "light" } } } }
}, "dev1");
assert.strictEqual(perDevice.configured, "light");

// ---- announcement presets ----------------------------------------------------------------------
assert.deepStrictEqual(
  L.noticePresetEntries([{ id: "np_a", text: " hello " }]),
  [{ key: "notice.presets", value: [{ id: "np_a", text: "hello" }] }]);
assert.throws(() => L.noticePresetEntries("nope"), /notice.presets/);
assert.throws(() => L.noticePresetEntries(
  Array.from({ length: 9 }, (_, i) => ({ id: "np_" + i, text: "x" }))), /notice.presets_max/);
assert.throws(() => L.noticePresetEntries([{ id: "bad id", text: "x" }]), /notice.preset_id/);
assert.throws(() => L.noticePresetEntries([{ id: "np_a", text: "x" },
                                           { id: "np_a", text: "y" }]), /notice.preset_id/);
assert.throws(() => L.noticePresetEntries([{ id: "np_a", text: "" }]), /notice.preset_text/);
assert.throws(() => L.noticePresetEntries([{ id: "np_a", text: "x".repeat(201) }]),
              /notice.preset_text/);
assert.strictEqual(L.NOTICE_PRESET_MAX, 8);
// The list a dialog renders skips malformed entries instead of showing blanks.
assert.deepStrictEqual(L.noticePresetList({ notice: { presets: [
  { id: "np_a", text: "one" }, { id: "bad id", text: "two" }, { id: "np_c", text: "" }, null
] } }), [{ id: "np_a", text: "one" }]);
assert.deepStrictEqual(L.noticePresetList({}), []);

// ---- door-specific announcements override the cluster-wide one --------------------------------
const now = Date.UTC(2026, 8, 2, 12, 0, 0);
const cfg = {
  doors: { d_front: { notice: { text: "Side gate", expires_ms: 0 } }, d_back: {} },
  notice: { global: { text: "House message", expires_ms: 0 } }
};
assert.strictEqual(L.effectiveNoticeModel("d_front", cfg, now).text, "Side gate");
assert.strictEqual(L.effectiveNoticeModel("d_front", cfg, now).scope, "door");
assert.strictEqual(L.effectiveNoticeModel("d_back", cfg, now).text, "House message");
assert.strictEqual(L.effectiveNoticeModel("d_back", cfg, now).scope, "global");
assert.strictEqual(L.effectiveNoticeModel("d_back", { doors: {} }, now).scope, "none");
assert.strictEqual(L.effectiveNoticeModel("d_back", { doors: {} }, now).active, false);

// ---- the unlock control ------------------------------------------------------------------------
const unlockStatus = { doors: { d_front: { unlock: { configured: true, command: "unlock",
                                                     show_button: true } },
                                d_back: { unlock: { configured: false, command: "",
                                                    show_button: false } } } };
const auto1 = L.doorUnlockModel("d_front", { doors: { d_front: {} } }, unlockStatus);
assert.strictEqual(auto1.mode, "auto");
assert.strictEqual(auto1.configured, true);
assert.strictEqual(auto1.showButton, true);
assert.strictEqual(auto1.command, "unlock");
const forced = L.doorUnlockModel("d_back",
  { doors: { d_back: { unlock: { show_button: true } } } }, unlockStatus);
assert.strictEqual(forced.mode, "show");
assert.strictEqual(forced.configured, false, "an administrator may show a control that does nothing");
assert.deepStrictEqual(L.doorUnlockEntries("d_front", "show", {}),
  { entries: [{ key: "doors.d_front.unlock", value: { show_button: true } }], dels: [] });
assert.deepStrictEqual(L.doorUnlockEntries("d_front", "hide", {}),
  { entries: [{ key: "doors.d_front.unlock", value: { show_button: false } }], dels: [] });
// Back to automatic removes the key rather than storing the value core would have chosen.
assert.deepStrictEqual(L.doorUnlockEntries("d_front", "auto", { show_button: true }),
  { entries: [], dels: ["doors.d_front.unlock"] });
assert.deepStrictEqual(
  L.doorUnlockEntries("d_front", "auto", { show_button: true, command: "gate" }),
  { entries: [{ key: "doors.d_front.unlock", value: { command: "gate" } }], dels: [] });

// ---- advisory warnings ---------------------------------------------------------------------------
assert.deepStrictEqual(L.writeWarnings({ ok: true }), []);
assert.deepStrictEqual(L.writeWarnings({ ok: true, warnings: [
  { key: "display.theme.call_button_bg", property: "call_button_bg", contrast: 2.4,
    message_key: "theme.low_contrast" }, "junk", null
] }), [{ key: "display.theme.call_button_bg", property: "call_button_bg", contrast: 2.4,
         message_key: "theme.low_contrast" }]);
assert.strictEqual(L.writeWarnings({ ok: true, warnings: [{}] })[0].message_key,
                   "theme.low_contrast");

// ---- the page must talk to the new endpoints, and the mock must answer them --------------------
const adminSource = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
assert.ok(adminSource.includes('"/api/notice"'), "the announcement dialog needs the global route");
assert.ok(/api\\\/doors\\\/\[\^\\\/\]\+\\\/open/.test(adminSource),
  "the mock must answer the unlock trigger");
assert.ok(adminSource.includes("data-purpose-enabled"), "the purposes tab needs a toggle");
assert.ok(adminSource.includes("data-ink-row"), "the theme tab needs per-region ink controls");
assert.ok(adminSource.includes("thAppearance"), "the theme tab needs the appearance control");

// ---- every string these surfaces reference must exist in all three catalogs --------------------
const referenced = [
  "theme.low_contrast", "theme.appearance", "theme.appearance_auto_system",
  "theme.appearance_auto_schedule", "theme.appearance_light", "theme.appearance_dark",
  "theme.dark_from", "theme.light_from", "theme.now", "theme.mode_light", "theme.mode_dark",
  "theme.auto", "theme.custom",
  "theme.call_button", "theme.ink", "theme.ink_region", "theme.background_source_image",
  "theme.background_source_color",
  "notice.target", "notice.target_global", "notice.scope_global", "notice.presets_title",
  "notice.preset_add", "notice.presets_full", "notice.preset_invalid",
  "unlock.title", "unlock.auto", "unlock.show", "unlock.hide", "unlock.not_configured",
  "unlock.command", "purpose.enabled", "purpose.disabled"
].concat(L.INK_REGIONS.map((region) => "theme.region_" + region));
for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  for (const key of referenced)
    assert.ok(Object.prototype.hasOwnProperty.call(catalog, key),
      language + " is missing " + key);
  assert.ok(catalog["theme.low_contrast"].includes("{ratio}"),
    language + " theme.low_contrast needs {ratio}");
}

console.log("theme and notice tests: ok");
