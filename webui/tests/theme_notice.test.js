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
// The ink rule is "whichever token reads better", crossing at Y = 0.1791, not at mid luminance.
// The same vectors core/tests/test_color.cpp pins, so the preview cannot drift from the fleet.
assert.strictEqual(L.autoInk("#BBBBB4"), "dark", "the reported light-grey photograph");
assert.strictEqual(L.autoInk("#404040"), "light", "a true mid-dark still wants light ink");
assert.strictEqual(L.autoInk("#808080"), "dark", "mid grey is past the crossover");
assert.strictEqual(L.autoInk("#767676"), "dark", "just above the crossover");
assert.strictEqual(L.autoInk("#757575"), "light", "just below it");
for (const sample of ["#9BD748", "#101418", "#BBBBB4", "#404040", "#808080", "#767676",
                      "#757575", "#E8E2D5", "#2A2118", "#FFFFFF", "#000000"]) {
  const dark = L.autoInk(sample) === "dark";
  const chosen = L.contrast(dark ? "#000000" : "#FFFFFF", sample);
  const other = L.contrast(dark ? "#FFFFFF" : "#000000", sample);
  assert.ok(chosen >= other, "autoInk must pick the better ink for " + sample);
}
// core states the rule the same way, so a shell reading either source gets one answer.
assert.ok(colorSource.includes("const double dark_ink = contrastRatioLuminance(0.0, y);"),
  "db::color::autoInk must compare the two ink ratios, not split at mid luminance");
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
assert.strictEqual(published.unsampled, false);
assert.strictEqual(published.reason, "");

// A configured background core could not sample must never read as the flat theme colour: the
// published ink came from #101418, not from the photograph actually on screen.
const unsampled = L.themeAutoModel({ display: { theme: {
  auto_background: { color: "#101418", source: "image_unsampled", reason: "too_large" },
  auto_accent: { call_button: "#AA5522", call_button_ink: "light" }
} } }, "");
assert.strictEqual(unsampled.source, "image_unsampled");
assert.strictEqual(unsampled.unsampled, true);
assert.strictEqual(unsampled.reason, "too_large");
// Core's accent is not preferred here, because it was derived from the flat colour.
assert.notStrictEqual(unsampled.callButton, "#AA5522");
assert.strictEqual(unsampled.callButton, L.autoAccent("#101418", "#FFFFFF"));
for (const reason of ["decode_failed", "missing"]) {
  const model = L.themeAutoModel({ display: { theme: {
    auto_background: { color: "#101418", source: "image_unsampled", reason: reason } } } }, "");
  assert.strictEqual(model.reason, reason);
}
// An unknown source is treated as the flat colour, which is what an older core reports.
assert.strictEqual(L.themeAutoModel({ display: { theme: {
  auto_background: { color: "#101418", source: "color" } } } }, "").unsampled, false);
assert.strictEqual(L.themeAutoModel({ display: { theme: {
  auto_background: { color: "#101418", source: "nonsense" } } } }, "").source, "color");

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

// ---- a live door with no configuration entry is still listed and still addressable ------------
// The regression: a cluster founded by a door station had no doors.* entries at all, so the tab
// listed nothing and every door-keyed surface had nothing to target.
const doorStatus = { doors: {
  d_front: { label: "Front door", configured: true },
  d_annex: { label: "annex-panel", configured: false }
} };
const rows = L.doorRows({ doors: { d_front: { label: { ja: "正面玄関" } } } }, doorStatus);
assert.deepStrictEqual(rows, [
  { id: "d_front", configured: true, label: "正面玄関" },
  { id: "d_annex", configured: false, label: "annex-panel" }
]);
// A configured door with no label of its own falls back to what core reports, then to its id.
assert.strictEqual(L.doorRows({ doors: { d_x: {} } }, { doors: { d_x: { label: "front-panel",
  configured: true } } })[0].label, "front-panel");
assert.strictEqual(L.doorRows({ doors: { d_x: {} } }, {})[0].label, "d_x");
// A door reported as configured is never listed twice, whichever side it came from.
assert.strictEqual(L.doorRows({ doors: { d_front: {} } }, doorStatus).length, 2);
assert.deepStrictEqual(L.doorRows({}, {}), []);
// An unconfigured door still resolves an announcement and an unlock model rather than throwing.
assert.strictEqual(L.effectiveNoticeModel("d_annex", { doors: {} }, Date.now()).active, false);
assert.strictEqual(L.doorUnlockModel("d_annex", { doors: {} }, doorStatus).mode, "auto");
const adminDoorsSource = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
assert.ok(adminDoorsSource.includes("admin.door_unconfigured"),
  "the doors tab must mark a door that has no configuration entry");
assert.ok(/L\.doorRows\(S\.cfg, S\.status\)/.test(adminDoorsSource),
  "the doors tab must render live doors, not only configured ones");

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
  "theme.background_source_color", "theme.background_unsampled",
  "theme.unsampled_too_large", "theme.unsampled_decode_failed", "theme.unsampled_missing",
  "notice.target", "notice.target_global", "notice.scope_global", "notice.presets_title",
  "notice.preset_add", "notice.presets_full", "notice.preset_invalid",
  "unlock.title", "unlock.auto", "unlock.show", "unlock.hide", "unlock.not_configured",
  "unlock.command", "purpose.enabled", "purpose.disabled", "admin.door_unconfigured",
  "theme.backdrop", "theme.backdrop_enabled", "theme.backdrop_hint", "theme.backdrop_invalid",
  "theme.backdrop_weak", "theme.backdrop_source_default", "theme.backdrop_source_admin",
  "theme.backdrop_source_device"
].concat(L.INK_REGIONS.map((region) => "theme.region_" + region));
for (const language of ["ja", "en", "zh"]) {
  const catalog = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));
  for (const key of referenced)
    assert.ok(Object.prototype.hasOwnProperty.call(catalog, key),
      language + " is missing " + key);
  assert.ok(catalog["theme.low_contrast"].includes("{ratio}"),
    language + " theme.low_contrast needs {ratio}");
  assert.ok(catalog["theme.background_unsampled"].includes("{reason}"),
    language + " theme.background_unsampled needs {reason}");
}

// ---- the darkening layer over the background image -----------------------------------------
// Defaults first: on, black, and strong enough for a bright photograph.
const plain = L.backdropModel({}, "");
assert.strictEqual(plain.enabled, true);
assert.strictEqual(plain.color, "#000000");
assert.strictEqual(plain.opacity, 62);
assert.strictEqual(plain.source, "default");

const clusterCfg = { display: { theme: { backdrop: { opacity: 40, color: "#101418" } } } };
const cluster = L.backdropModel(clusterCfg, "");
assert.strictEqual(cluster.opacity, 40);
assert.strictEqual(cluster.color, "#101418");
assert.strictEqual(cluster.enabled, true, "an unset leaf keeps the built-in default");
assert.strictEqual(cluster.source, "admin");

// Each leaf resolves on its own, so a device darkens further without restating the colour.
const deviceCfg = {
  display: { theme: { backdrop: { opacity: 40, color: "#101418" } } },
  devices: { d1: { local: { theme: { backdrop: { opacity: 80 } } } } }
};
const device = L.backdropModel(deviceCfg, "d1");
assert.strictEqual(device.opacity, 80);
assert.strictEqual(device.color, "#101418");
assert.strictEqual(device.source, "device");
assert.deepStrictEqual(device.overridden, { enabled: false, color: false, opacity: true });
// A device with no override of its own still reports the cluster's answer.
assert.strictEqual(L.backdropModel(deviceCfg, "d2").opacity, 40);
assert.strictEqual(L.backdropModel(deviceCfg, "d2").source, "admin");

// Out-of-range or malformed stored values fall back rather than reaching a shell.
const junk = { display: { theme: { backdrop: { opacity: 250, color: "black", enabled: "yes" } } } };
assert.strictEqual(L.backdropModel(junk, "").opacity, 62);
assert.strictEqual(L.backdropModel(junk, "").color, "#000000");
assert.strictEqual(L.backdropModel(junk, "").enabled, true);

// What core publishes is read straight through, including the source it decided.
const publishedBackdrop = L.backdropStatusModel({
  display: { theme: { backdrop: { enabled: false, color: "#0a0a0a", opacity: 55,
                                  source: "device" } } } });
assert.strictEqual(publishedBackdrop.enabled, false);
assert.strictEqual(publishedBackdrop.color, "#0A0A0A");
assert.strictEqual(publishedBackdrop.opacity, 55);
assert.strictEqual(publishedBackdrop.source, "device");
assert.strictEqual(L.backdropStatusModel({}).source, "default");

// The write rides in the theme object, and a blank strength is reported instead of defaulted.
const writtenBackdrop = L.themeColorEntries("", { call_button_auto: true, ink_override: {},
                                          backdrop: { enabled: true, color: "#0a0a0a",
                                                      opacity: "55" } }, {});
assert.strictEqual(writtenBackdrop.entries.length, 1);
assert.strictEqual(writtenBackdrop.entries[0].key, "display.theme");
assert.deepStrictEqual(writtenBackdrop.entries[0].value.backdrop,
                       { enabled: true, color: "#0A0A0A", opacity: 55 });
assert.throws(() => L.themeColorEntries("", { backdrop: { opacity: "" } }, {}));
assert.throws(() => L.themeColorEntries("", { backdrop: { opacity: 101 } }, {}));
// Clearing a device override removes the key rather than pinning today's cluster value.
const clearedBackdrop = L.themeColorEntries("d1", { call_button_auto: true,
                                                   ink_override: {}, backdrop: null },
                                                 { backdrop: { opacity: 80 } });
assert.ok(!clearedBackdrop.entries.length || !clearedBackdrop.entries[0].value.backdrop);

console.log("theme and notice tests: ok");
