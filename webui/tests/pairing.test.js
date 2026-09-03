"use strict";
const assert = require("assert");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");

const catalogs = {};
for (const language of ["ja", "en", "zh"])
  catalogs[language] = JSON.parse(fs.readFileSync(
    path.join(__dirname, "../locale/" + language + ".json"), "utf8"));

function assertKey(key) {
  for (const language of ["ja", "en", "zh"])
    assert.ok(Object.prototype.hasOwnProperty.call(catalogs[language], key),
              language + " missing " + key);
}

// Keys the panel resolves at run time, which the literal t("…") scan in admin_logic cannot see.
for (const code of L.PAIR_ERR_CODES) assertKey("pair.err." + code);
assertKey("pair.err.unknown");
assertKey("pair.err_detail");

// The document's error table must be reachable from a raw core code.
for (const code of ["bad_pin", "expired", "no_token", "host_unpaired", "connect_failed", "timeout",
                    "closed", "join_in_progress", "already_paired", "decrypt_failed", "bad_payload",
                    "bad_challenge", "local_persist_failed", "persist_failed", "host_zero_psk",
                    "no_ack", "bad_qr"])
  assert.strictEqual(L.pairErrKey(code), "pair.err." + code);
assert.strictEqual(L.pairErrKey("some_new_core_code"), "pair.err.unknown");
assert.strictEqual(L.pairErrKey(""), "pair.err.unknown");
assert.strictEqual(L.pairErrKey(undefined), "pair.err.unknown");

// The admin must not fall back to the old, colliding admin.pair_* pairing keys. The video
// playback override keys share the prefix and are unrelated.
const adminSource = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
const adminHtml = fs.readFileSync(path.join(__dirname, "../admin/index.html"), "utf8");
for (const source of [adminSource, adminHtml])
  for (const match of source.matchAll(/admin\.(pair_[a-z_]+|join_pin|join_hint|add_device)/g))
    assert.ok(/^pair_override_|^pair_secure_failed$/.test(match[1].replace("admin.", "")),
              "stale pairing key still referenced: admin." + match[1]);

assert.deepStrictEqual(L.pairClock(0), { m: 0, s: "00" });
assert.deepStrictEqual(L.pairClock(9), { m: 0, s: "09" });
assert.deepStrictEqual(L.pairClock(65), { m: 1, s: "05" });
assert.deepStrictEqual(L.pairClock(600), { m: 10, s: "00" });
assert.deepStrictEqual(L.pairClock(-5), { m: 0, s: "00" });

assert.strictEqual(L.pairDeviceLabel({ name: "kitchen", id: "abcdef0123" }), "kitchen");
assert.strictEqual(L.pairDeviceLabel({ model: "Nexus 7", id: "abcdef0123" }), "Nexus 7 abcdef");
assert.strictEqual(L.pairDeviceLabel({ id: "abcdef0123" }), "abcdef");
assert.strictEqual(L.pairDeviceDetail({ role: "indoor_panel", model: "Nexus 7",
                                        platform: "android", sw: "0.1.0" }),
                   "indoor_panel · Nexus 7 · android · v0.1.0");

assert.deepStrictEqual(L.pairJoinPayload("10.0.1.5:47172", "418205"),
                       { ok: true, body: { host: "10.0.1.5:47172", pin: "418205" } });
assert.strictEqual(L.pairJoinPayload("", "418205").field, "host");
assert.strictEqual(L.pairJoinPayload("10.0.1.5:47172", "4182").field, "pin");
assert.deepStrictEqual(L.pairJoinPayload(" 10.0.1.5:47172 ", "418 205").body,
                       { host: "10.0.1.5:47172", pin: "418205" });

const qrText = "doorbell-pair:10.0.1.5:47172|" + "ab".repeat(16) + "|" + "cd".repeat(32);
assert.deepStrictEqual(L.pairQrParse(qrText),
                       { addr: "10.0.1.5:47172", id: "ab".repeat(16), pk: "cd".repeat(32) });
assert.strictEqual(L.pairQrParse("https://example.invalid"), null);
assert.strictEqual(L.pairQrParse("doorbell-pair:10.0.1.5:47172|abc|short"), null);
assert.strictEqual(L.pairQrTextValid("  " + qrText + "  "), true);

/* ---- snapshot to view model ---- */

function snapshot(extra) {
  return Object.assign({
    state: "ready", paired: true, persistence_ready: true, is_founder: true,
    psk_source: "secure_store", psk_ref: "secret:mesh.psk", role: "door_station",
    self: { id: "a".repeat(32), addr: "10.0.1.5:47172", name: "front", role: "door_station",
            model: "Pixel 4a", platform: "android", sw: "0.1.0" },
    pair_qr: qrText,
    home: { member_count: 2, connected_count: 1 },
    token: { active: false, expires_s: 0, attempts_left: 0, host: "10.0.1.5:47172" },
    pending: { pairing_mode: false, pairing_mode_left_s: 0, auto_added_count: 0, devices: [] }
  }, extra || {});
}

for (const state of ["unpaired", "joining", "persist_error", "revoked"]) {
  const model = L.pairPanelModel(snapshot({ state: state, paired: false }), {});
  assert.strictEqual(model.state, state);
  assert.strictEqual(model.onboarding, true, state + " must show the onboarding view");
}
const ready = L.pairPanelModel(snapshot(), {});
assert.strictEqual(ready.onboarding, false);
assert.strictEqual(ready.memberCount, 2);
assert.strictEqual(ready.connectedCount, 1);
assert.strictEqual(ready.isFounder, true);
assert.strictEqual(ready.qrText, qrText);
assert.strictEqual(ready.self.addr, "10.0.1.5:47172");

// An empty snapshot (core answered before the mesh existed) must not look paired.
assert.strictEqual(L.pairPanelModel({}, {}).state, "unpaired");
assert.strictEqual(L.pairPanelModel({}, {}).onboarding, true);

// The PIN is readable only while the token is live, and the address comes from the token, never
// from the browser's own location.
const noToken = L.pairPanelModel(snapshot({
  token: { active: false, expires_s: 0, attempts_left: 0, host: "10.0.1.5:47172", pin: "418205" }
}), {});
assert.strictEqual(noToken.token.active, false);
assert.strictEqual(noToken.token.pin, "");
const withToken = L.pairPanelModel(snapshot({
  token: { active: true, expires_s: 185, attempts_left: 2, host: "10.0.1.9:47172", pin: "418205" }
}), {});
assert.strictEqual(withToken.token.pin, "418205");
assert.strictEqual(withToken.token.host, "10.0.1.9:47172");
assert.strictEqual(withToken.token.expires_s, 185);
assert.strictEqual(withToken.token.attemptsLeft, 2);

const bulk = L.pairPanelModel(snapshot({
  pending: { pairing_mode: true, pairing_mode_left_s: 542, auto_added_count: 3, devices: [] }
}), {});
assert.strictEqual(bulk.pairingMode.active, true);
assert.strictEqual(bulk.pairingMode.left_s, 542);
assert.strictEqual(bulk.pairingMode.addedCount, 3);

/* ---- per-row lifecycle ---- */

const pendingDevice = {
  id: "b".repeat(32), addr: "10.0.1.7:47172", name: "newpad", role: "indoor_panel",
  model: "Nexus 7", platform: "android", sw: "0.1.0", age_s: 4,
  invite_state: "none", attempts: 0, last_error: ""
};
const idle = L.pairRowModel(pendingDevice, undefined);
assert.strictEqual(idle.state, "idle");
assert.strictEqual(idle.label, "newpad");
assert.strictEqual(idle.age_s, 4);
assert.strictEqual(L.pairRowModel(pendingDevice, { state: "adding" }).state, "adding");
assert.strictEqual(
  L.pairRowModel(Object.assign({}, pendingDevice, { invite_state: "sent" })).state, "adding");
assert.strictEqual(
  L.pairRowModel(Object.assign({}, pendingDevice, { invite_state: "acked" })).state, "adding");
const failedRow = L.pairRowModel(
  Object.assign({}, pendingDevice, { invite_state: "failed", last_error: "no_ack" }));
assert.strictEqual(failedRow.state, "failed");
assert.strictEqual(failedRow.errKey, "pair.err.no_ack");
assert.strictEqual(failedRow.errCode, "no_ack");

// The click shows progress before the next snapshot, a failure reported by core outranks it,
// and "Added" wins over everything.
assert.strictEqual(L.pairRowModel(pendingDevice, { state: "added" }).state, "added");
assert.strictEqual(
  L.pairRowModel(Object.assign({}, pendingDevice, { invite_state: "sent" }),
                 { state: "failed", err: "connect_failed" }).errKey, "pair.err.connect_failed");
const overridden = L.pairRowModel(
  Object.assign({}, pendingDevice, { invite_state: "failed", last_error: "no_ack" }),
  { state: "adding" });
assert.strictEqual(overridden.state, "failed");
assert.strictEqual(overridden.errKey, "pair.err.no_ack");
assert.strictEqual(overridden.errCode, "no_ack");

const now = 1_700_000_000_000;
const adding = { [pendingDevice.id]: { state: "adding", at: now, label: "newpad" } };
// Still pending: keep waiting.
assert.strictEqual(
  L.pairMergeRows(adding, snapshot({ pending: { devices: [pendingDevice] } }), [], now + 3000)
    [pendingDevice.id].state, "adding");
// Left the pending list and showed up as a peer: that is device_joined.
const joined = L.pairMergeRows(adding, snapshot(), [pendingDevice.id], now + 4000);
assert.strictEqual(joined[pendingDevice.id].state, "added");
assert.strictEqual(joined[pendingDevice.id].label, "newpad");
// The confirmation lingers, then the row disappears.
assert.ok(L.pairMergeRows(joined, snapshot(), [pendingDevice.id], now + 5000)[pendingDevice.id]);
assert.strictEqual(
  L.pairMergeRows(joined, snapshot(), [pendingDevice.id],
                  now + 4000 + L.PAIR_ROW_LINGER_MS + 1)[pendingDevice.id], undefined);
// Gone from pending and never seen as a peer: that add failed, it did not silently succeed.
const lost = L.pairMergeRows(adding, snapshot(), [], now + L.PAIR_ROW_LINGER_MS + 1);
assert.strictEqual(lost[pendingDevice.id].state, "failed");
assert.strictEqual(lost[pendingDevice.id].err, "no_ack");

// A finished row is still rendered after it left the pending list.
const finishedRows = L.pairPanelModel(snapshot(), joined).rows;
assert.strictEqual(finishedRows.length, 1);
assert.strictEqual(finishedRows[0].state, "added");
assert.strictEqual(finishedRows[0].gone, true);
assert.strictEqual(finishedRows[0].id, pendingDevice.id);
// A pending device is listed once, with its local state applied.
const mixed = L.pairPanelModel(snapshot({ pending: { devices: [pendingDevice] } }), adding);
assert.strictEqual(mixed.rows.length, 1);
assert.strictEqual(mixed.rows[0].state, "adding");

/* ---- QR encoding ---- */

function fingerprint(text) {
  const m = L.qrModules(text);
  return { version: m.version, size: m.size,
           sha: crypto.createHash("sha256").update(m.modules.join("")).digest("hex").slice(0, 16) };
}
// Frozen vectors: each was decoded back to its exact text with core's db_core_qr_decode (quirc).
assert.deepStrictEqual(fingerprint(qrText), { version: 8, size: 49, sha: "a57919dee70284f7" });
assert.deepStrictEqual(fingerprint("HELLO"), { version: 1, size: 21, sha: "32fbc389880456d5" });
assert.deepStrictEqual(
  fingerprint("doorbell-pair:192.168.0.2:47172|" + "0f".repeat(16) + "|" + "9e".repeat(32)),
  { version: 8, size: 49, sha: "f13ab83fa9ec6a57" });

assert.strictEqual(L.qrModules(""), null);
assert.strictEqual(L.qrModules(null), null);

for (const text of [qrText, "a", "x".repeat(300), "こんにちは QR"]) {
  const m = L.qrModules(text);
  assert.strictEqual(m.size, m.version * 4 + 17);
  assert.strictEqual(m.modules.length, m.size * m.size);
  for (const value of m.modules) assert.ok(value === 0 || value === 1);
  const at = (x, y) => m.modules[y * m.size + x];
  // Finder patterns in all three corners, each with its light separator.
  for (const [ox, oy] of [[0, 0], [m.size - 7, 0], [0, m.size - 7]]) {
    for (let d = 0; d < 7; d++) {
      assert.strictEqual(at(ox + d, oy), 1);
      assert.strictEqual(at(ox + d, oy + 6), 1);
      assert.strictEqual(at(ox, oy + d), 1);
      assert.strictEqual(at(ox + 6, oy + d), 1);
    }
    assert.strictEqual(at(ox + 3, oy + 3), 1);
    assert.strictEqual(at(ox + 1, oy + 1), 0);
  }
  // Timing patterns and the always-dark module.
  for (let i = 8; i < m.size - 8; i++) {
    assert.strictEqual(at(i, 6), i % 2 === 0 ? 1 : 0);
    assert.strictEqual(at(6, i), i % 2 === 0 ? 1 : 0);
  }
  assert.strictEqual(at(8, m.size - 8), 1);
}

// A payload longer than any version can hold is refused rather than mis-encoded.
assert.strictEqual(L.qrModules("z".repeat(3000)), null);

console.log("pairing tests: ok");

// ---- the pairing QR payload is core's, not the page's -------------------------------------
// A device with the app installed must open a scanned code straight into the join flow, so the
// format is defined once in core and the page renders whatever core published.
{
  const snapshot = {
    state: "ready", paired: true, persistence_ready: true, is_founder: true,
    self: { id: "a".repeat(32), addr: "10.0.1.10:47172", name: "front", role: "door_station" },
    home: { member_count: 2, connected_count: 2 },
    token: { active: true, pin: "123456", host: "10.0.1.10:47172", expires_s: 90,
             attempts_left: 3,
             uri: "doorbell://pair?host=10.0.1.10%3A47172&pin=123456&exp=1772000000" +
                  "&cluster=%E4%BA%AC%E9%98%AA%E3%83%8F%E3%82%A6%E3%82%B9" },
    pending: { pairing_mode: false, pairing_mode_left_s: 0, auto_added_count: 0, devices: [] }
  };
  const model = L.pairPanelModel(snapshot, { now: Date.now() });
  assert.strictEqual(model.token.uri, snapshot.token.uri,
    "the card renders core's uri verbatim");
  // The printed host and PIN stay, for someone scanning with a plain camera app.
  assert.strictEqual(model.token.host, "10.0.1.10:47172");
  assert.strictEqual(model.token.pin, "123456");

  // An expired or absent token carries no code to render.
  const inactive = L.pairPanelModel(
    Object.assign({}, snapshot, { token: { active: false, uri: snapshot.token.uri } }),
    { now: Date.now() });
  assert.strictEqual(inactive.token.uri, "");
  const legacy = L.pairPanelModel(
    Object.assign({}, snapshot, { token: { active: true, pin: "123456", expires_s: 90 } }),
    { now: Date.now() });
  assert.strictEqual(legacy.token.uri, "", "an older core that sends no uri renders no code");

  // The page must not assemble the URI itself.
  const source = fs.readFileSync(path.join(__dirname, "../admin/app.js"), "utf8");
  assert.ok(/drawPairQr\(\$\("#pairCodeQr"\), m\.token\.uri\)/.test(source),
    "the PIN card must draw core's uri");
  const assembled = source.match(/"doorbell:\/\/pair\?host="/g) || [];
  assert.strictEqual(assembled.length, 1,
    "only the mock may build a doorbell://pair URI; the live path uses core's");
}

console.log("pairing uri tests: ok");
