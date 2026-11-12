"use strict";
// UI-guideline helpers (size classes, Core color roles, door tile state, history by day) and the
// structural contracts of the redesigned panel screens.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const read = name => fs.readFileSync(path.join(__dirname, "../panel/" + name), "utf8");
const root = {};
vm.runInContext(read("panel-common.js"), vm.createContext({ window: root }));
const C = root.DoorbellPanelCommon;

assert.strictEqual(C.sizeClass(375), "compact");
assert.strictEqual(C.sizeClass(599), "compact");
assert.strictEqual(C.sizeClass(600), "medium");
assert.strictEqual(C.sizeClass(899), "medium");
assert.strictEqual(C.sizeClass(900), "expanded");
assert.strictEqual(C.sizeClass(1920), "expanded");

const theme = { auto_background: { color: "#F0F0F0" }, auto_ink: { status_line: "#111111", hint: "#555555" },
  ink_override: { status_line: "#000000", hint: "red" }, call_button_bg: "#0055aa",
  call_button_ink: "#ffffff" };
assert.deepStrictEqual(JSON.parse(JSON.stringify(C.colorRoles(theme))), { surface: "#f0f0f0", on_surface: "#000000",
  muted: "#555555", accent: "#0055aa", on_accent: "#ffffff" },
  "overrides win, invalid colors fall back, and nothing else is invented");
assert.deepStrictEqual(JSON.parse(JSON.stringify(C.colorRoles({ call_button_bg: "url(x)" }))), {});
// What Core actually publishes: automatic ink is a token, the accent a color.
assert.deepStrictEqual(JSON.parse(JSON.stringify(C.colorRoles({ auto_background: { color: "#101418" },
  auto_ink: { status_line: "light", hint: "light" }, ink_override: {}, call_button_bg: "#FFD166", call_button_ink: "dark" }))),
  { surface: "#101418", on_surface: "#ffffff", accent: "#ffd166", on_accent: "#101418" });
assert.deepStrictEqual(JSON.parse(JSON.stringify(C.colorRoles(null))), {});
const props = {};
const doc = { documentElement: { style: { setProperty: (k, v) => { props[k] = v; } } } };
assert.deepStrictEqual(Array.from(C.applyColorRoles(theme, doc)).sort(),
  ["accent", "muted", "on_accent", "on_surface", "surface"]);
assert.strictEqual(props["--on-surface"], "#000000");
assert.strictEqual(props["--surface"], "#f0f0f0");

// Core's surface and ink belong to the wallpaper: without one only the accent is applied, and a
// wallpaper that goes away takes its ink with it.
{
  const set = {}, attrs = {};
  const page = { documentElement: { style: { setProperty: (k, v) => { set[k] = v; }, removeProperty: k => { delete set[k]; } },
    setAttribute: (k, v) => { attrs[k] = v; }, removeAttribute: k => { delete attrs[k]; } },
    body: { style: {}, className: "monitorPage", attrs: {}, getAttribute(k) { return this.attrs[k] || null; },
      setAttribute(k, v) { this.attrs[k] = v; } } };
  const hash = "ab".repeat(32);
  assert.strictEqual(C.wallpaper(theme), null);
  assert.strictEqual(C.wallpaper({ bg_image: "../etc/passwd" }), null, "only an asset hash is ever fetched");
  assert.deepStrictEqual(JSON.parse(JSON.stringify(C.wallpaper({ bg_image: hash, backdrop: { enabled: true, color: "#102030", opacity: 40 } }))),
    { url: "/asset/" + hash, scrim: "rgba(16,32,48,0.4)", color: "#102030", opacity: 0.4 });
  // Ink is chosen for what is actually shown: a light wallpaper under Core's default 62% black
  // scrim is dark, so text is light even though Core's bare-wallpaper ink says dark.
  const bright = { bg_image: hash, auto_background: { color: "#4D8556" }, auto_ink: { status_line: "dark", hint: "dark" },
    ink_override: {}, backdrop: { enabled: true, color: "#000000", opacity: 62 } };
  assert.deepStrictEqual(JSON.parse(JSON.stringify(C.scrimmedRoles(bright))), { surface: "#1d3321", on_surface: "#ffffff" });
  assert.strictEqual(C.scrimmedRoles(Object.assign({}, bright, { backdrop: { enabled: false } })).on_surface, "#101418");
  assert.strictEqual(C.scrimmedRoles(Object.assign({}, bright, { ink_override: { status_line: "#FFEE00" } })).on_surface, "#ffee00",
    "an administrator's ink still wins");
  assert.strictEqual(C.wallpaper({ bg_image: hash, backdrop: { enabled: false, opacity: 80 } }).scrim, "rgba(0,0,0,0)");
  assert.strictEqual(C.wallpaper({ bg_image: hash }).scrim, "rgba(0,0,0,0.62)", "Core's default scrim");
  C.applyHomeTheme(theme, page);
  assert.deepStrictEqual(Object.keys(set).sort(), ["--accent", "--on-accent"]);
  assert.strictEqual(page.body.style.backgroundImage, "");
  assert.strictEqual(page.body.className, "monitorPage");
  C.applyHomeTheme(Object.assign({ bg_image: hash }, theme), page);
  assert.strictEqual(set["--surface"], "#5b5b5b", "the surface role is the wallpaper color under the scrim");
  assert.strictEqual(set["--on-surface"], "#000000");
  assert.strictEqual(attrs["data-core-roles"], "1");
  assert.strictEqual(page.body.style.backgroundImage,
    "linear-gradient(rgba(0,0,0,0.62),rgba(0,0,0,0.62)), url(/asset/" + hash + ")");
  assert.strictEqual(page.body.className, "monitorPage has-wallpaper");
  C.applyHomeTheme(theme, page);
  assert.deepStrictEqual(Object.keys(set).sort(), ["--accent", "--on-accent"]);
  assert.strictEqual("data-core-roles" in attrs, false);
  assert.strictEqual(page.body.className, "monitorPage");
  assert.deepStrictEqual(Array.from(C.applyColorRoles(theme, page, { ink: false })).sort(), ["accent", "on_accent"]);
}

assert.strictEqual(C.doorTileState({ calling: true, call_state: "ringing" }), "ringing");
assert.strictEqual(C.doorTileState({ call_state: "purpose_pending" }), "ringing");
assert.strictEqual(C.doorTileState({ calling: true, call_state: "in_call" }), "in_call");
assert.strictEqual(C.doorTileState({ call_state: "answered" }), "in_call");
assert.strictEqual(C.doorTileState({ online: false }), "offline");
assert.strictEqual(C.doorTileState({ online: false, calling: true }), "ringing", "a ringing door is never hidden as offline");
assert.strictEqual(C.doorTileState({}), "idle");

const now = new Date(2026, 10, 6, 12, 0, 0).getTime();
const groups = C.groupByDay([
  { id: "a", ts: new Date(2026, 10, 5, 23, 59).getTime() },
  { id: "b", ts: new Date(2026, 10, 6, 9, 0).getTime() },
  { id: "c", ts: new Date(2026, 10, 1, 8, 0).getTime() },
  { id: "d", ts: new Date(2026, 10, 6, 11, 0).getTime() }], now);
assert.deepStrictEqual(Array.from(groups, g => g.kind), ["today", "yesterday", "date"]);
assert.deepStrictEqual(Array.from(groups[0].rows, r => r.id), ["d", "b"], "newest first within a day");
assert.strictEqual(C.groupByDay([], now).length, 0);

// Screen contracts.
const monitor = read("monitor.html");
const actions = monitor.slice(monitor.indexOf('<div id="callActions">'), monitor.indexOf("</div>", monitor.indexOf('<div id="callActions">')));
const order = ["answerBtn", "replyBtn", "monitorClose"].map(id => actions.indexOf('id="' + id + '"'));
assert(order.every(i => i > 0) && order[0] < order[1] && order[1] < order[2],
  "incoming call actions: Answer, Reply, Ignore");
assert(/id="answerBtn" class="positive"/.test(monitor), "Answer uses the positive role");
assert(monitor.includes('id="replySheet" role="dialog"') && monitor.includes("hidden>"),
  "quick replies live in a sheet that starts closed");
assert(monitor.includes('C.setLabel($("monitorClose"), t("ring.ignore"), "bell-off")'), "Ignore is labelled Ignore");
assert(monitor.includes('id="dashTabs" role="tablist"') && monitor.includes("C.groupByDay("));
assert((monitor.match(/role="tab" /g) || []).length === 2 && (monitor.match(/role="tabpanel"/g) || []).length === 2 &&
  monitor.includes('aria-controls="doorsPane"') && monitor.includes('aria-controls="historyPane"'),
  "Doors and History are a real tab list with labelled panels");
assert(monitor.includes('id="sheetScrim" hidden'), "the reply sheet has a scrim that starts closed");
// The home (Doors) view shows no call history: History is its own tab at every width, carries the
// unread badge, and the Doors view has one notice that opens it.
{
  const doorsPane = monitor.slice(monitor.indexOf('<section id="doorsPane"'), monitor.indexOf('<section id="historyPane"'));
  assert(doorsPane.includes('id="missedNotice" class="notice" type="button" hidden') && !/evCard|evBody|hlist/.test(doorsPane),
    "the Doors view holds the tiles and the missed-call notice, never the history list");
  assert(monitor.includes('$("missedNotice").onclick = function () { selectPane("history");'), "the notice opens History");
  assert(monitor.includes('badge.id = "tabHistoryBadge"') && monitor.includes("paintMissed(unread)"),
    "the History tab carries the unread missed-call badge");
  const sheet = read("panel.css");
  assert(sheet.includes('#dashBody[data-pane="doors"] #historyPane, #dashBody[data-pane="history"] #doorsPane { display:none; }'));
  assert(!/#dashTabs\s*\{[^}]*display:none/.test(sheet) && !/#historyPane\s*\{[^}]*(float|sticky)/.test(sheet) &&
    !/#dashBody\[data-pane\] #historyPane/.test(sheet),
    "no width shows History beside the tiles or hides the tab list");
}
assert(monitor.includes('C.sizeClass(window.innerWidth) === "expanded" ? "dashHeader" : "dashTabs"'),
  "SOS is docked in a fixed zone, never floating");
assert(monitor.includes("C.doorTileState(") && monitor.includes("openLive("), "tiles show state and open live view");
const door = read("door.html");
assert(door.includes('zone.insertBefore(list, $("cancelCall"))'), "a single door's Call is in the action zone");
assert(door.includes("actions.insertBefore(emergencyOverlay.trigger(), actions.firstChild)"),
  "SOS is docked at the leading edge of the visitor action zone");
for (const lang of ["ja", "en", "zh"])
  assert(door.includes('data-lang="' + lang + '" lang="' + lang + '"'), "visitor language " + lang + " is a text button");
assert(!/<select/.test(door) && !/<a\b|settings|\/admin/i.test(door),
  "the visitor screen has no route to settings");
assert(door.includes('"purposeBtn" + (items[i].skip ? " skip" : "")'));
const css = read("panel.css");
for (const role of ["--surface", "--on-surface", "--accent", "--positive", "--negative", "--warning", "--muted"])
  assert(css.includes(role + ":"), "color role " + role + " has a default");
assert(css.includes("--tap-visitor:72px") && css.includes("min-width: 900px") && css.includes("max-width: 599.98px"));
assert(css.includes("prefers-reduced-motion"));
const call = read("call.html");
assert(call.includes('<body class="callPage">'));
assert(call.includes('id="doorTabs" role="tablist"') && call.includes('button.setAttribute("role", "tab")'),
  "the door switcher is a tab list");
{
  const zone = call.slice(call.indexOf('<div id="controls">'), call.indexOf('id="sheetScrim"'));
  const ids = ["callBtn", "replyBtn", "ignoreBtn", "micBtn", "unlockBtn", "sendVideo", 'id="status"', "adminNote"]
    .map(id => zone.indexOf(id));
  assert(ids.every((at, i) => at > 0 && (i === 0 || at > ids[i - 1])),
    "call actions: Answer/End, Reply, Ignore, then Mic, Unlock, video, status and the administrator note");
  assert(call.includes('t(selectedRinging() ? "ring.answer_unavailable" : "panel.calling_unavailable")') &&
    call.includes('t("panel.admin_note", { detail: t(setupKey) })'),
    "residents get a plain status; setup detail is a separate administrator note");
}
for (const page of [door, monitor, call]) {
  assert(!/<style/.test(page), "pages take every rule from panel.css");
  assert(page.includes('<meta name="color-scheme" content="light dark">'));
}
assert(css.includes("prefers-color-scheme: dark") && css.includes(':root[data-theme="dark"]') &&
  css.includes("accent-color:var(--accent)") && css.includes("safe-area-inset-bottom") && css.includes("100dvh"));
// Everything outside "@supports (display:grid)" must parse on iOS 5 Safari: a plain value always
// precedes a var() for the same property.
{
  const plain = css.replace(/\/\*[\s\S]*?\*\//g, "");
  let depth = 0, modern = 0, i = 0, legacy = "";
  while (i < plain.length) {
    if (!modern && plain.startsWith("@supports", i)) { modern = depth + 1; }
    const ch = plain[i];
    if (ch === "{") depth++;
    if (ch === "}") { depth--; if (modern && depth < modern) { modern = 0; i++; continue; } }
    if (!modern) legacy += ch;
    i++;
  }
  for (const block of legacy.match(/\{[^{}]*\}/g) || []) {
    const seen = {};
    for (const decl of block.slice(1, -1).split(";")) {
      const at = decl.indexOf(":");
      if (at < 0) continue;
      const prop = decl.slice(0, at).trim(), value = decl.slice(at + 1).trim();
      if (prop.startsWith("--")) continue;
      if (/var\(|calc\(|clamp\(|env\(|\d(vh|vw|dvh)\b/.test(value))
        assert(seen[prop] || /callPage|#call(Shell|Header)|#controls|#doorTabs|#primaryRow|#secondaryRow|#videoBox|#status|#adminNote|#videoToggle|#backLink|#notices|#conversation/.test(legacyRuleFor(block)),
          "iOS 5 needs a plain fallback before: " + prop + ":" + value);
      else seen[prop] = true;
    }
  }
  function legacyRuleFor(block) {
    const at = legacy.indexOf(block);
    return legacy.slice(legacy.lastIndexOf("}", at) + 1, at);
  }
}

// SOS: a compact outlined control docked in a fixed zone, with no hold hint and no red fill.
for (const [name, page] of [["door.html", door], ["monitor.html", monitor], ["call.html", call]])
  assert(!/hold_hint|triggerHint|dbSosHolding/.test(page) && /triggerIcon: (C|DoorbellPanelCommon)\.icon\("alert-triangle"\)/.test(page),
    name + " installs the compact SOS control");
assert(/body \.dbSosTrigger \{ background:transparent;/.test(css) && !/dbSosHint/.test(css) &&
  css.includes("body #dashTabs .dbSosTrigger, body #dashHeader .dbSosTrigger, body #callActions .dbSosTrigger, body #controls .dbSosTrigger {\n  position:static;"),
  "the docked SOS control is outlined and never floats");
{
  const rt = read("runtime.js");
  assert(!/sosHoldController|SOS_HOLD_MS|Hold 2s/.test(rt), "no press-and-hold remains");
  assert(rt.includes('trigger.setAttribute("data-semantic-id", "sos.trigger")') && rt.includes("if (confirmCancel.focus)"),
    "the compact control keeps its semantic id and Cancel takes the default focus");
}

for (const page of [door, monitor])
  assert(page.includes("C.applyHomeTheme(state.display.theme)") && page.includes("C.applyAppearance(state.display)"),
    "home surfaces follow Core's appearance and draw its wallpaper");
assert(call.includes("applyColorRoles(st.display.theme, document, { ink: false })"),
  "the call screen takes Core's accent only");
assert(call.includes("unlock.show_button === true &&\n    unlock.permitted !== false"), "Unlock follows Core's availability");

// Contrast (ui-guidelines, Tokens > Color): a role color used as text or as an outline reaches
// 4.5:1 on every surface it sits on, in light and in dark, and so does text on a role fill. The
// plain fallbacks iOS 5 uses are the dark palette, so the dark figures cover it.
{
  const tokensIn = block => {
    const found = {};
    for (const m of block.matchAll(/--([a-z0-9-]+):(#[0-9a-fA-F]{6})\b/g)) found[m[1]] = m[2].toLowerCase();
    return found;
  };
  const lightTokens = tokensIn(css.slice(css.indexOf(":root {"), css.indexOf("@media (prefers-color-scheme: dark)")));
  const mediaDark = tokensIn(css.slice(css.indexOf("@media (prefers-color-scheme: dark)"), css.indexOf(':root[data-theme="dark"]')));
  const forcedDark = tokensIn(css.slice(css.indexOf(':root[data-theme="dark"]'), css.indexOf(':root[data-theme="light"]')));
  assert.deepStrictEqual(mediaDark, forcedDark, "system dark and Core-fixed dark are the same palette");
  const darkTokens = Object.assign({}, lightTokens, forcedDark);
  const channels = hex => [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16));
  const luminance = hex => {
    const [r, g, b] = channels(hex).map(c => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
  const surfaces = ["surface", "surface-2", "surface-3"];
  // Text and outline roles (the outlined SOS trigger and missed-call text use negative-text).
  const onSurfaces = ["on-surface", "muted", "negative-text", "positive-text", "accent-text"];
  const fills = [["on-accent", "accent"], ["on-positive", "positive"], ["on-negative", "negative"],
    ["on-warning", "warning"], ["negative", "on-negative"]];
  for (const [name, palette] of [["light", lightTokens], ["dark", darkTokens]]) {
    for (const ink of onSurfaces) for (const surface of surfaces) {
      const ratio = contrast(palette[ink], palette[surface]);
      assert(ratio >= 4.5, name + ": --" + ink + " on --" + surface + " is " + ratio.toFixed(2) + ":1");
    }
    for (const [ink, fill] of fills) {
      const ratio = contrast(palette[ink], palette[fill]);
      assert(ratio >= 4.5, name + ": --" + ink + " on --" + fill + " is " + ratio.toFixed(2) + ":1");
    }
    assert(contrast(palette.focus, palette.surface) >= 3, name + ": the focus ring is visible");
  }
  // iOS 5 fallbacks: each plain color written before a var() is the dark value of that token.
  // The SOS overlay keeps its own darker red, which only raises the contrast of white text on it.
  const expand = hex => (hex.length === 4 ? "#" + hex.slice(1).replace(/./g, "$&$&") : hex).toLowerCase();
  let checked = 0;
  for (const m of css.matchAll(/([a-z-]+):([^;{}]*?)(#[0-9a-fA-F]{3,6})\b([^;{}]*?);\s*\1:[^;{}]*?var\(--([a-z0-9-]+)\)/g)) {
    const token = m[5], plain = expand(m[3]);
    if (!darkTokens[token]) continue;
    checked++;
    if (token === "negative" && plain === "#8f1010") {
      assert(contrast(plain, "#ffffff") >= contrast(darkTokens.negative, "#ffffff"));
      continue;
    }
    assert.strictEqual(plain, darkTokens[token], "plain fallback for --" + token + " in: " + m[0].slice(0, 80));
  }
  assert(checked > 100, "the fallback scan found the legacy rules");
  // Under Core's wallpaper roles, role text collapses to the ink Core's contrast rule picked.
  const coreRoles = css.slice(css.indexOf(":root[data-core-roles]"), css.indexOf("/* ================================================================ Base"));
  for (const role of ["--muted", "--negative-text", "--positive-text", "--accent-text"])
    assert(coreRoles.includes(role + ":var(--on-surface)"), role + " follows Core's ink on a wallpaper");
  // The SOS trigger is outlined in the text-contrast variant of the negative role, never the fill.
  assert(/body \.dbSosTrigger \{ background:transparent; color:#ff8e8e; color:var\(--negative-text\);\s*border-color:#ff8e8e; border-color:var\(--negative-text\); \}/.test(css));
}

// Appearance: Core's fixed appearance wins; follow_system leaves it to the system setting.
assert.strictEqual(C.appearanceTheme({ appearance: { effective: "dark", follow_system: false } }), "dark");
assert.strictEqual(C.appearanceTheme({ appearance: { effective: "light", follow_system: false } }), "light");
assert.strictEqual(C.appearanceTheme({ appearance: { effective: "dark", follow_system: true } }), "");
assert.strictEqual(C.appearanceTheme({ appearance: { effective: "sepia", follow_system: false } }), "");
assert.strictEqual(C.appearanceTheme(null), "");
{
  const attrs = {};
  const page = { documentElement: { setAttribute: (k, v) => { attrs[k] = v; }, removeAttribute: k => { delete attrs[k]; } } };
  C.applyAppearance({ appearance: { effective: "dark", follow_system: false } }, page);
  assert.strictEqual(attrs["data-theme"], "dark");
  C.applyAppearance({ appearance: { effective: "dark", follow_system: true } }, page);
  assert.strictEqual("data-theme" in attrs, false, "following the system clears the fixed theme");
}

// Icons come from the Tabler sprite that tools/gen_icons.py writes beside the pages.
const sprite = read("icons/tabler-sprite.svg");
for (const name of ["door", "history", "phone", "message-reply", "x", "bell", "bell-off", "lock-open", "alert-triangle",
  "microphone", "microphone-off", "check", "phone-off", "chevron-right"])
  assert(sprite.includes('id="i-' + name + '"'), "icon " + name + " exists in the sprite");
assert.strictEqual(C.iconMarkup("x\"><script>"), "", "icon names are validated, never interpolated raw");
assert(C.iconMarkup("phone").includes("/panel/icons/tabler-sprite.svg#i-phone"));

// Helper results come from another realm, so they are compared by value.
const same = (actual, expected, message) =>
  assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected, message);
// Live picture zoom. The stage is the clip rectangle and takes whatever the layout leaves; the
// picture is aspect-fitted inside it; pan is clamped per axis against the stage.
assert.strictEqual(C.ZOOM_MAX >= 4, true);
same(C.fitRect(400, 300, 1600, 900), { w: 400, h: 225 }, "16:9 in a 4:3 stage fills the width");
same(C.fitRect(400, 300, 640, 480), { w: 400, h: 300 }, "4:3 in a 4:3 stage fills it");
same(C.fitRect(400, 300, 360, 640), { w: 168.75, h: 300 }, "a portrait picture fills the height");
same(C.fitRect(400, 300, 0, 0), { w: 400, h: 300 }, "an unknown picture counts as filling the stage");
same(C.clampZoom({ scale: 0.3, x: 50, y: -50 }, 400, 300, 400, 225), { scale: 1, x: 0, y: 0 });
same(C.clampZoom({ scale: NaN, x: NaN }, 400, 300, 400, 225), { scale: 1, x: 0, y: 0 });
// 16:9 picture (400x225 at 1x) in a 400x300 stage.
same(C.clampZoom({ scale: 1.2, x: 999, y: 999 }, 400, 300, 400, 225), { scale: 1.2, x: 40, y: 0 },
  "wider than the stage: pans to its edge; still shorter than the stage: stays centred");
same(C.clampZoom({ scale: 2, x: -999, y: 999 }, 400, 300, 400, 225), { scale: 2, x: -200, y: 75 },
  "larger than the stage on both axes: neither edge comes inside the stage");
same(C.clampZoom({ scale: 9, x: 9999, y: -9999 }, 400, 300, 400, 225), { scale: 4, x: 600, y: -300 });
// Portrait picture (168.75x300 at 1x) in the same stage.
same(C.clampZoom({ scale: 2, x: 500, y: 500 }, 400, 300, 168.75, 300), { scale: 2, x: 0, y: 150 },
  "at 2x it is still narrower than the stage, so it stays centred horizontally");
same(C.clampZoom({ scale: 4, x: 500, y: 500 }, 400, 300, 168.75, 300), { scale: 4, x: 137.5, y: 450 });
same(C.clampZoom({ scale: 2, x: 250, y: 120 }, 400, 200), { scale: 2, x: 200, y: 100 },
  "without a picture size the picture fills the stage");
// Zoomed, the picture grows into the letterbox bars: more of the stage is used than at 1x.
same(C.visibleSize({ scale: 1 }, 400, 300, 400, 225), { w: 400, h: 225 });
same(C.visibleSize({ scale: 1.2 }, 400, 300, 400, 225), { w: 400, h: 270 }, "taller than the fitted 1x rectangle");
same(C.visibleSize({ scale: 2 }, 400, 300, 400, 225), { w: 400, h: 300 }, "the whole stage, not the fitted rectangle");
same(C.visibleSize({ scale: 2 }, 400, 300, 168.75, 300), { w: 337.5, h: 300 });
{
  // Zooming keeps the point under the fingers in place while the clamp allows it.
  const before = { scale: 2, x: 20, y: -10 }, px = 60, py = 30;
  const after = C.zoomAt(before, 1.5, px, py, 400, 300, 400, 225);
  assert.strictEqual(after.scale, 3);
  assert(Math.abs((px - before.x) / before.scale - (px - after.x) / after.scale) < 1e-9);
  assert(Math.abs((py - before.y) / before.scale - (py - after.y) / after.scale) < 1e-9);
  assert.strictEqual(C.zoomAt({ scale: 3 }, 10, 0, 0, 400, 300, 400, 225).scale, 4, "pinch stops at the maximum");
  same(C.zoomAt({ scale: 1.2, x: 30, y: 0 }, 0.1, 100, 50, 400, 300, 400, 225), { scale: 1, x: 0, y: 0 },
    "pinching out returns to the fitted picture");
  const corner = JSON.parse(JSON.stringify(C.zoomAt({ scale: 1 }, 4, 200, 150, 400, 300, 400, 225)));
  same(corner, { scale: 4, x: -600, y: -300 }, "zooming into a corner stops at the stage edge");
  same(C.panBy(corner, -500, -500, 400, 300, 400, 225), corner, "panning never reveals empty space");
  same(C.panBy({ scale: 1 }, 40, 40, 400, 300, 400, 225), { scale: 1, x: 0, y: 0 }, "a fitted picture does not pan");
  same(C.panBy({ scale: 1.2 }, 30, 30, 400, 300, 400, 225), { scale: 1.2, x: 30, y: 0 }, "pan only on the axis that overflows");
  same(C.toggleZoom({ scale: 1 }, 0, 0, 400, 300, 400, 225), { scale: 2, x: 0, y: 0 });
  same(C.toggleZoom({ scale: 1 }, 100, 50, 400, 300, 400, 225), { scale: 2, x: -100, y: -50 });
  same(C.toggleZoom({ scale: 2.5, x: 40, y: 0 }, 10, 10, 400, 300, 400, 225), { scale: 1, x: 0, y: 0 });
}
{
  // The gesture helper against a 400x300 stage showing a 16:9 picture (fitted 400x225).
  const handlers = {}, layerHandlers = {};
  const layer = { style: {}, naturalWidth: 1280, naturalHeight: 720, addEventListener: (name, fn) => { layerHandlers[name] = fn; } };
  const box = { style: { objectFit: "" }, className: "stage", addEventListener: (name, fn) => { handlers[name] = fn; },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 300 }) };
  const zoom = C.attachZoom(box, [layer]);
  let prevented = 0;
  const event = extra => Object.assign({ preventDefault() { prevented++; } }, extra);
  handlers.wheel(event({ clientX: 200, clientY: 150, deltaY: 100 }));
  assert.strictEqual(prevented, 0, "a wheel that cannot zoom further is left to page scrolling");
  assert.strictEqual(box.style.touchAction || "", "", "a fitted picture leaves touches to the page");
  handlers.wheel(event({ clientX: 200, clientY: 150, deltaY: -100 }));
  assert.strictEqual(prevented, 1);
  assert(zoom.view().scale > 1 && box.style.touchAction === "none" && /is-zoomed/.test(box.className));
  assert(/scale\(1\.2\)/.test(layer.style.transform) && layer.style.webkitTransform === layer.style.transform);
  assert.strictEqual(layer.style.width, undefined, "with object-fit the layer keeps filling the stage");
  handlers.touchstart(event({ touches: [{ clientX: 100, clientY: 100 }] }));
  handlers.touchmove(event({ touches: [{ clientX: 1000, clientY: 1000 }] }));
  same(zoom.view(), { scale: 1.2, x: 40, y: 0 }, "at 1.2x only the horizontal axis overflows the stage");
  handlers.touchend(event({ touches: [], changedTouches: [{ clientX: 1000, clientY: 1000 }] }));
  handlers.dblclick(event({ clientX: 200, clientY: 150 }));
  assert.strictEqual(zoom.view().scale, 1, "double click on a zoomed picture fits it again");
  handlers.dblclick(event({ clientX: 300, clientY: 200 }));
  same(zoom.view(), { scale: 2, x: -100, y: -50 });
  handlers.touchstart(event({ touches: [{ clientX: 100, clientY: 100 }] }));
  handlers.touchmove(event({ touches: [{ clientX: 1000, clientY: 1000 }] }));
  same(zoom.view(), { scale: 2, x: 200, y: 75 }, "a drag stops where the picture edge meets the stage edge");
  handlers.touchend(event({ touches: [], changedTouches: [{ clientX: 1000, clientY: 1000 }] }));
  // A new frame size (a portrait source) reclamps against the same stage.
  layer.naturalWidth = 360; layer.naturalHeight = 640;
  layerHandlers.load();
  same(zoom.view(), { scale: 2, x: 0, y: 75 }, "the portrait picture is narrower than the stage at 2x: centred");
  handlers.touchstart(event({ touches: [{ clientX: 150, clientY: 150 }, { clientX: 250, clientY: 150 }] }));
  handlers.touchmove(event({ touches: [{ clientX: 0, clientY: 150 }, { clientX: 400, clientY: 150 }] }));
  assert.strictEqual(zoom.view().scale, 4, "a pinch stops at 4x");
  zoom.reset();
  same(zoom.view(), { scale: 1, x: 0, y: 0 });
  assert.strictEqual(layer.style.transform, "");
  assert.strictEqual(box.style.touchAction, "");
  assert.strictEqual(box.className, "stage");
  const before = prevented;
  handlers.touchstart(event({ touches: [{ clientX: 100, clientY: 100 }] }));
  handlers.touchmove(event({ touches: [{ clientX: 100, clientY: 40 }] }));
  assert.strictEqual(prevented, before, "one finger on a fitted picture still scrolls the page");
  assert.strictEqual(C.attachZoom(null, []).view().scale, 1, "a missing stage is tolerated");
  // Without object-fit (old Safari) the layer is given the fitted rectangle, centred in the stage.
  const oldLayer = { style: {}, naturalWidth: 640, naturalHeight: 480, addEventListener() {} };
  const oldBox = { style: {}, className: "stage", addEventListener() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 225 }) };
  C.attachZoom(oldBox, [oldLayer]);
  same([oldLayer.style.width, oldLayer.style.height, oldLayer.style.left, oldLayer.style.top], ["300px", "225px", "50px", "0px"]);
}
// Rotation: a station may deliver the raw sensor frame and report 0/90/180/270. The picture is
// turned before it is fitted, so a quarter-turned landscape frame fills the stage height.
{
  for (const [input, expected] of [[0, 0], [90, 90], [180, 180], [270, 270], [360, 0], [-90, 270], [450, 90],
    ["270", 270], [91, 90], [null, 0], [undefined, 0], ["sideways", 0]])
    assert.strictEqual(C.normalizeRotation(input), expected, "rotation " + input);
  // A 640x360 frame in a 400x300 stage.
  same(C.fitRect(400, 300, 640, 360, 0), { w: 400, h: 225 });
  same(C.fitRect(400, 300, 640, 360, 180), { w: 400, h: 225 }, "a half turn keeps the shape");
  same(C.fitRect(400, 300, 640, 360, 90), { w: 168.75, h: 300 }, "a quarter turn is upright portrait: it fills the height");
  same(C.fitRect(400, 300, 640, 360, 270), { w: 168.75, h: 300 });
  same(C.fitRect(300, 500, 640, 360, 270), { w: 281.25, h: 500 }, "in a portrait stage the turned picture nearly fills it");
  for (const rotation of [0, 90, 180, 270]) {
    const handlers = {}, layerHandlers = {};
    const layer = { style: {}, naturalWidth: 640, naturalHeight: 360, addEventListener: (name, fn) => { layerHandlers[name] = fn; } };
    const box = { style: { objectFit: "" }, className: "stage", addEventListener: (name, fn) => { handlers[name] = fn; },
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 300 }) };
    const zoom = C.attachZoom(box, [layer]);
    zoom.setRotation(rotation);
    assert.strictEqual(zoom.rotation(), rotation);
    const quarter = rotation === 90 || rotation === 270;
    assert.strictEqual(layer.style.transform || "", rotation ? "rotate(" + rotation + "deg)" : "", "turned at 1x: " + rotation);
    assert.strictEqual(layer.style.webkitTransform || "", layer.style.transform || "");
    if (quarter) {
      // The layer is laid out sideways (stage height wide, stage width tall), centred, so that
      // once turned it covers the stage and object-fit fits the upright picture.
      same([layer.style.width, layer.style.height, layer.style.left, layer.style.top], ["300px", "400px", "50px", "-50px"]);
    } else {
      assert(!layer.style.width && !layer.style.left, "0 and 180 keep the layer filling the stage");
    }
    const event = extra => Object.assign({ preventDefault() {} }, extra);
    handlers.dblclick(event({ clientX: 200, clientY: 150 }));
    assert.strictEqual(layer.style.transform, "translate(0px,0px) scale(2)" + (rotation ? " rotate(" + rotation + "deg)" : ""),
      "zoom and pan act on the upright picture");
    handlers.touchstart(event({ touches: [{ clientX: 100, clientY: 100 }] }));
    handlers.touchmove(event({ touches: [{ clientX: 1000, clientY: 1000 }] }));
    // Upright fit is 400x225 (0, 180) or 168.75x300 (90, 270): at 2x the turned picture is
    // still narrower than the stage, so it only pans vertically.
    same(zoom.view(), quarter ? { scale: 2, x: 0, y: 150 } : { scale: 2, x: 200, y: 75 }, "clamp for rotation " + rotation);
    handlers.touchend(event({ touches: [], changedTouches: [{ clientX: 1000, clientY: 1000 }] }));
    zoom.reset();
    assert.strictEqual(layer.style.transform, rotation ? "rotate(" + rotation + "deg)" : "", "reset keeps the turn");
    zoom.setRotation(0);
    assert.strictEqual(layer.style.transform, "");
    assert(!layer.style.width && !layer.style.left, "back to filling the stage");
  }
  // Without object-fit the layer gets the raw frame's fitted box: 300x168.75 on its side.
  const oldLayer = { style: {}, naturalWidth: 640, naturalHeight: 360, addEventListener() {} };
  const oldBox = { style: {}, className: "stage", addEventListener() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 400, height: 300 }) };
  C.attachZoom(oldBox, [oldLayer]).setRotation(270);
  same([oldLayer.style.width, oldLayer.style.height, oldLayer.style.left, oldLayer.style.top], ["300px", "169px", "50px", "66px"]);
  // The rotation comes from the station's video-meta through the panel's own media route.
  const asked = [];
  let got = null;
  C.loadRotation("/media/peer/n1/video-meta", (method, url, body, done) => { asked.push(method + " " + url); done(200, { rotation: 270 }); }, r => { got = r; });
  assert.deepStrictEqual(asked, ["GET /media/peer/n1/video-meta"]);
  assert.strictEqual(got, 270);
  C.loadRotation("/video-meta", (m, u, b, done) => done(403, null), r => { got = r; });
  assert.strictEqual(got, 0, "a refused or missing answer means upright");
  C.loadRotation("", () => { throw new Error("no request without a media URL"); }, r => { got = r; });
  assert.strictEqual(got, 0);
  // Still tiles are fixed 16:9 boxes, turned by class.
  const tile = { className: "" };
  C.setTileRotation(tile, 270); assert.strictEqual(tile.className, " rot270");
  C.setTileRotation(tile, 90); assert.strictEqual(tile.className, " rot90");
  C.setTileRotation(tile, 0); assert.strictEqual(tile.className, "");
  for (const turn of [90, 180, 270])
    assert(new RegExp("\\.ratio > \\.rot" + turn + "[ ,][^}]*\\{[^}]*rotate\\(" + turn + "deg\\)").test(css) ||
      css.includes(".ratio > .rot" + turn + " { -webkit-transform:rotate(" + turn + "deg); transform:rotate(" + turn + "deg); }"));
  assert(css.includes(".ratio > .rot90, .ratio > .rot270 { width:56.25%; height:177.7778%; left:21.875%; top:-38.8889%; }"),
    "a quarter-turned still is laid out sideways inside the 16:9 tile");
  assert(monitor.includes('C.loadRotation(DoorbellPlayback.peerMediaUrl(d, "meta", window.location), R.panelRequest,') &&
    monitor.includes("callZoom.setRotation(doorRotation[calling.id] || 0)") && call.includes("liveZoom.setRotation(rotation)"),
    "both pages turn their live pictures as the station reports");
}

// The stage takes the space the layout leaves: no fixed aspect ratio on the live picture.
assert(call.includes('<div id="videoBox" class="stage"') && monitor.includes('<div class="stage" id="callPicture">'));
assert(/#videoBox \{ flex:1 1 0; min-height:140px;/.test(css) && /#callView \.callMedia \.stage \{ flex:1 1 auto;/.test(css) &&
  !/#videoBox[^{]*\{[^}]*(max-width:calc|aspect-ratio)/.test(css) && !/\.callMedia \.(stage|ratio)[^{]*\{[^}]*max-width:calc/.test(css),
  "the live stage is not sized to a 16:9 picture");
assert(/\.stage > img, \.stage > video \{[^}]*object-fit:contain/.test(css));
for (const [name, source] of [["monitor.html", monitor], ["call.html", call]])
  assert(source.includes("attachZoom(") && /[zZ]oom\.reset\(\)/.test(source), name + " zooms its live picture and resets it");
console.log("panel layout helpers and screen contracts: PASS");
