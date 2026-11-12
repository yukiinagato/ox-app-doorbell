"use strict";
// Role colours used as text or outlines must reach 4.5:1 on the surfaces they sit on, in dark,
// light and Retro (docs/en/ui-guidelines.md, Tokens > Color). The palettes are read from the
// custom properties in layout.css, so a token change that breaks legibility fails here.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

const css = fs.readFileSync(path.join(__dirname, "../admin/layout.css"), "utf8");
function palette(selector, from) {
  const start = css.indexOf(selector + " {", from || 0);
  assert(start >= 0, "token block " + selector);
  const out = {};
  for (const m of css.slice(start, css.indexOf("}", start)).matchAll(/--([a-z0-9-]+):(#[0-9a-fA-F]{6})\b/g))
    out[m[1]] = m[2];
  return out;
}
const media = css.indexOf("@media (prefers-color-scheme: light)");
const palettes = {
  dark: palette(":root"),
  light: palette(':root[data-theme="light"]:not([data-ui="retro"])'),
  "light (system)": palette(':root:not([data-theme="dark"]):not([data-ui="retro"])', media),
  retro: palette(':root[data-ui="retro"]')
};
assert.deepStrictEqual(palettes["light (system)"], palettes.light,
  "the system-driven and Core-fixed light palettes are the same");

// Text roles and the surfaces each one is drawn on.
const TEXT = {
  fg: ["bg", "card", "card2", "field", "chip"],
  dim: ["bg", "card", "card2", "field"],
  ok: ["card", "card2"],
  warn: ["card", "card2"],
  err: ["card", "card2", "field"],
  "negative-text": ["card", "card2"],
  "acc-text": ["bg", "card", "card2"]
};
// Fills and the text drawn on them: primary and destructive buttons, the SOS card, the toast.
const FILLS = [["on-acc", "acc"], ["on-negative", "negative"], ["negative", "on-negative"], ["bg", "fg"]];

for (const [name, colors] of Object.entries(palettes)) {
  for (const [role, surfaces] of Object.entries(TEXT)) for (const surface of surfaces) {
    // Retro never draws text on its desktop colour: every region there is a gray panel.
    if (name === "retro" && surface === "bg") continue;
    assert(L.colorOk(colors[role]) && L.colorOk(colors[surface]), name + ": --" + role + " and --" + surface);
    const ratio = L.contrast(colors[role], colors[surface]);
    assert(ratio >= 4.5, name + ": --" + role + " on --" + surface + " is " + ratio.toFixed(2) + ":1");
  }
  for (const [ink, fill] of FILLS) {
    if (name === "retro" && ink === "bg") continue;
    const ratio = L.contrast(colors[ink], colors[fill]);
    assert(ratio >= 4.5, name + ": --" + ink + " on --" + fill + " is " + ratio.toFixed(2) + ":1");
  }
}

// Destructive outlined buttons and the danger zone use the text variant on a known surface.
assert(/\.btn2\.danger, \.btn\.danger \{ color:var\(--negative-text\); border-color:var\(--negative-text\);\s+background:var\(--card\); \}/.test(css),
  "destructive outlined buttons use the text variant of the negative role");
for (const line of css.split("\n")) {
  if (!/(^|[ ;{])color:var\(--negative\)/.test(line)) continue;
  assert(/\.alertcard \.btn/.test(line), "the fill variant is text only on its own inverse: " + line.trim());
}
// Muted rows change colour instead of opacity, which would take them below the minimum.
assert(!/\.offline[^{]*\{[^}]*opacity/.test(css), "offline rows are not faded with opacity");
console.log("admin role-colour contrast (dark, light, retro): PASS");
