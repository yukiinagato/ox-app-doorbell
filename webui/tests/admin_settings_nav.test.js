"use strict";
// Settings master-detail navigation (routing, view selection, search) and the pairing
// confirmation-code contract.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

const tabs = L.settingsTabs();
const html = fs.readFileSync(path.join(__dirname, "../admin/index.html"), "utf8");
const source = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
const tabMatch = source.match(/var TABS = \{([\s\S]*?)\};/);
const renderTabs = [...tabMatch[1].matchAll(/(\w+):\s*render/g)].map(m => m[1]);
assert.deepStrictEqual([...tabs].sort(), [...renderTabs].sort(), "every tab is in exactly one group");
assert.strictEqual(new Set(tabs).size, tabs.length);
for (const tab of tabs) {
  assert(html.includes('data-tab="' + tab + '"'), "nav button for " + tab);
  assert(html.includes('id="tab-' + tab + '"'), "section for " + tab);
}

assert.deepStrictEqual(L.settingsRoute("#/system"), { valid: true, tab: "system" });
assert.deepStrictEqual(L.settingsRoute("#/"), { valid: true, tab: "" });
assert.deepStrictEqual(L.settingsRoute(""), { valid: true, tab: "" });
assert.deepStrictEqual(L.settingsRoute("#/nope"), { valid: false, tab: "" });
assert.deepStrictEqual(L.settingsRoute("#k=secret"), { valid: false, tab: "" });
assert.deepStrictEqual(L.settingsRoute("#/system/../x"), { valid: false, tab: "" });
assert.strictEqual(L.settingsHash("pair"), "#/pair");
assert.strictEqual(L.settingsHash("bogus"), "#/");
for (const tab of tabs) assert.strictEqual(L.settingsRoute(L.settingsHash(tab)).tab, tab);

assert.strictEqual(L.settingsView(1280, ""), "split");
assert.strictEqual(L.settingsView(L.SETTINGS_SPLIT_MIN_PX, "system"), "split");
assert.strictEqual(L.settingsView(L.SETTINGS_SPLIT_MIN_PX - 1, ""), "list");
assert.strictEqual(L.settingsView(375, "system"), "detail");

const items = [{ tab: "theme", label: "Theme and display", group: "Appearance" },
               { tab: "system", label: "System", group: "System" },
               { tab: "doors", label: "ドア", group: "ドアと端末" }];
assert.deepStrictEqual(L.filterSettings(items, ""), ["theme", "system", "doors"]);
assert.deepStrictEqual(L.filterSettings(items, "  DISPLAY "), ["theme"]);
assert.deepStrictEqual(L.filterSettings(items, "appear theme"), ["theme"], "all terms must match");
assert.deepStrictEqual(L.filterSettings(items, "ﾄﾞｱ"), ["doors"], "width-folded (NFKC) match");
assert.deepStrictEqual(L.filterSettings(items, "zzz"), []);

// Pairing (protocol v3): an invite carries the 8-digit code shown on the new device.
assert.deepStrictEqual(L.pairInvitePayload("dev1", "1234 5678"),
  { ok: true, body: { id: "dev1", code: "12345678" } });
assert.strictEqual(L.pairInvitePayload("dev1", "1234").err, "confirm_code_required");
assert.strictEqual(L.pairInvitePayload("", "12345678").ok, false);
assert.strictEqual(L.pairConfirmCodeText("12345678"), "1234 5678");
assert.strictEqual(L.pairConfirmCodeText("123"), "");
const model = L.pairPanelModel({ state: "unpaired", self: { confirm_code: "87654321" },
  upgrade_rejoin_required: true, upgrade_rejoin_reason: "legacy_pairing",
  pending: { devices: [{ id: "a", pk_conflict: true }, { id: "b" }] },
  security: { psk_id: "k3", prev_psk_id: "k2", prev_psk_until_ms: 5, legacy_peers: ["x", 4],
              rekey_required: ["y"], identity_pk: "AB".repeat(32) } }, {});
assert.strictEqual(model.confirmCode, "8765 4321");
assert.strictEqual(model.upgradeRejoin, true);
assert.strictEqual(model.upgradeReason, "legacy_pairing");
assert.deepStrictEqual(model.rows.map(r => r.pkConflict), [true, false]);
assert.deepStrictEqual(model.security.legacyPeers, ["x"]);
assert.strictEqual(model.security.identityPk, "ab".repeat(32));
for (const code of ["confirm_code_mismatch", "confirm_code_required", "pk_conflict", "not_upgrade_pending"])
  assert.strictEqual(L.pairErrKey(code), "pair.err." + code);
assert(source.includes('pairPost("/api/pairing/invite", invite.body'), "invite sends {id, code}");
assert(!/mockPairInvite\(MOCK_PAIR\.devices\[i\]\.id, false\)/.test(source), "bulk add never auto-invites");

// Responsive contract.
const css = fs.readFileSync(path.join(__dirname, "../admin/layout.css"), "utf8");
assert(html.includes('<link rel="stylesheet" href="layout.css">'));
assert(css.includes("(max-width: 899.98px)") && css.includes("prefers-reduced-motion") &&
       css.includes("prefers-color-scheme: light") && css.includes("safe-area-inset-bottom"));
assert(/--tap:44px/.test(css), "touch targets are 44 px");
for (const page of ["door", "monitor", "call"]) {
  const p = fs.readFileSync(path.join(__dirname, "../panel/" + page + ".html"), "utf8");
  assert(p.includes('<link rel="stylesheet" href="/panel/panel.css">'), page + " loads panel.css");
  assert(p.includes("viewport-fit=cover"), page + " reaches the safe areas");
}
console.log("admin settings navigation, pairing codes and responsive contract: PASS");
