"use strict";
// Admin panel-identity management (/api/panels/*) and protocol v3 device state helpers.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

const id = "0123456789abcdef0123456789abcdef";
const rows = L.panelRecords({ ok: true, revision: "r1", panels: [
  { panel_id: id, door_scope: ["d_front", "bad door"], grants: ["view", "call.answer", "root"],
    revoked: false, credential_ref: "secret:panel.aaaa", provisioning_status: "configured",
    last_activity_ms: 1756300000000 },
  { panel_id: "not-a-panel", door_scope: [], grants: [] },
  { panel_id: "f".repeat(32), revoked: true }
] });
assert.strictEqual(rows.length, 2, "invalid panel ids are dropped");
assert.deepStrictEqual(rows[0].door_scope, ["d_front"], "invalid door ids are dropped");
assert.deepStrictEqual(rows[0].grants, ["view", "call.answer"], "unknown grants are dropped");
assert.strictEqual(rows[0].last_activity_ms, 1756300000000);
assert.strictEqual(rows[1].revoked, true);
assert.strictEqual(rows[1].provisioning_status, "provisioning_required");
assert.deepStrictEqual(L.panelRecords(null), []);

assert.deepStrictEqual(L.panelCreateBody("r1", "secret:panel.0011223344556677",
  ["d_front", "d_front", "x y"], ["view", "door.open", "admin"]),
  { expected_revision: "r1", credential_ref: "secret:panel.0011223344556677",
    door_scope: ["d_front"], grants: ["view", "door.open"] });
assert.strictEqual(L.panelCreateBody("", "secret:panel.x", [], []), null, "revision is required");
assert.strictEqual(L.panelCreateBody("r1", "panel.x", [], []), null, "only secret: references");
assert.strictEqual(L.panelCredentialRef("00112233445566778899"), "secret:panel.0011223344556677");
assert.strictEqual(L.panelCredentialRef("abc"), "");

assert.strictEqual(L.membershipState({ membership: "rekey_required" }), "rekey_required");
assert.strictEqual(L.membershipState({ mesh_state: "protocol_upgrade_required" }),
                   "protocol_upgrade_required");
assert.strictEqual(L.membershipState({ membership: "<script>" }), "unknown");
assert.strictEqual(L.fingerprintText("ab".repeat(32)), Array(33).join("AB:").slice(0, -1));
assert.strictEqual(L.fingerprintText("zz"), "");
assert.strictEqual(L.newPasswordAcceptable("1234567"), false);
assert.strictEqual(L.newPasswordAcceptable("12345678"), true);
assert.strictEqual(L.peerLabel({}), "?", "a peer without an id cannot break the dashboard");
assert.strictEqual(L.peerLabel({ id: "abcdef0123" }), "abcdef01");
assert.strictEqual(L.peerLabel({ id: "abcdef0123", name: "Hall" }), "Hall");

const source = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "../admin/index.html"), "utf8");
assert(!/p\.id\.slice\(/.test(source), "peer ids are never sliced unguarded");
assert(/panels: renderPanels/.test(source), "the Panels tab is wired");
assert(html.includes('data-tab="panels"') && html.includes('id="tab-panels"'));
for (const action of ["list", "create", "update", "revoke", "rotate"])
  assert(source.includes('"/api/panels/list"') && (action === "list" ||
    source.includes('panelAction("' + action + '"')), "panel action " + action + " is wired");
assert(source.includes('"/api/pairing/rotate"') && source.includes('"/api/pairing/rebuild"'));
assert(!/mode: "cors"/.test(source), "media metadata is fetched same-origin");
console.log("admin panel management and v3 device state: PASS");
