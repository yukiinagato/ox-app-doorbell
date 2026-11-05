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
assert.deepStrictEqual(JSON.parse(JSON.stringify(C.colorRoles(null))), {});
const props = {};
const doc = { documentElement: { style: { setProperty: (k, v) => { props[k] = v; } } } };
assert.deepStrictEqual(Array.from(C.applyColorRoles(theme, doc)).sort(),
  ["accent", "muted", "on_accent", "on_surface", "surface"]);
assert.strictEqual(props["--on-surface"], "#000000");
assert.strictEqual(props["--surface"], "#f0f0f0");

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
assert(monitor.includes('C.setText($("monitorClose"), t("ring.ignore"))'), "Ignore is labelled Ignore");
assert(monitor.includes('id="dashTabs" role="tablist"') && monitor.includes("C.groupByDay("));
assert(monitor.includes("C.doorTileState(") && monitor.includes("openLive("), "tiles show state and open live view");
const door = read("door.html");
assert(door.includes('zone.insertBefore(list, zone.firstChild)'), "a single door's Call is in the action zone");
assert(door.includes('"purposeBtn" + (items[i].skip ? " skip" : "")'));
const css = read("panel.css");
for (const role of ["--surface", "--on-surface", "--accent", "--positive", "--negative", "--warning", "--muted"])
  assert(css.includes(role + ":"), "color role " + role + " has a default");
assert(css.includes("--tap-visitor:72px") && css.includes("min-width: 900px") && css.includes("max-width: 599.98px"));
assert(css.includes("prefers-reduced-motion"));
assert(read("call.html").includes('<body class="callPage">'));
console.log("panel layout helpers and screen contracts: PASS");
