"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const V = require("../panel/visitor-flow.js");

const suite = JSON.parse(fs.readFileSync(path.join(__dirname, "../../tools/conformance/fixtures/visitor-flow-v1.json"), "utf8"));
const flows = {};
for (const c of suite.resolve) flows[c.name] = c.expect;

let checked = 0;
for (const c of suite.walk) {
  const walker = V.create(flows[c.flow], c.lang || "ja");
  if (c.start) assert.deepStrictEqual(walker.snapshot(), c.start, c.name + ": start");
  c.steps.forEach((entry, index) => {
    const event = Object.assign({}, entry.event);
    if (event.flow_changed) event.flow_changed = flows[event.flow_changed];
    const calls = walker.apply(event);
    assert.deepStrictEqual(calls, entry.calls || [], `${c.name}[${index}]: calls`);
    assert.deepStrictEqual(walker.snapshot(), entry.expect, `${c.name}[${index}]: snapshot`);
    checked++;
  });
}
assert.strictEqual(suite.walk.length, 21, "every fixture walk case must run");
assert.ok(checked >= 40, "the walk cases must exercise their steps");

// Text lookup and plain-text body.
assert.strictEqual(V.textIn({ ja: "あ", en: "a" }, "en"), "a");
assert.strictEqual(V.textIn({ ja: "あ", en: "" }, "en"), "あ");
assert.strictEqual(V.textIn({ zh: "z" }, "en"), "z");
assert.strictEqual(V.textIn(null, "en"), null);
assert.deepStrictEqual(V.paragraphs("a\nb\n\nc\n\n\nd"), [["a", "b"], ["c"], ["d"]]);
assert.deepStrictEqual(V.paragraphs(""), []);

// Asynchronous API used by the door page: tap, call Core, report the result.
{
  const doc = { enabled: true, start: "s", idle_s: 20, steps: {
    s: { kind: "page", options: [{ id: "o", semantic_id: "purpose.button", label: { ja: "x" }, to: "n" }] },
    n: { kind: "notify", purpose: "p", to: "e" },
    e: { kind: "end", return_s: 5 } } };
  const w = V.create(doc, "ja");
  assert.strictEqual(w.idleSeconds(), 20);
  assert.strictEqual(w.tap("missing").act, "none");
  const act = w.tap("o");
  assert.deepStrictEqual(act, { act: "notify", step: "n", purpose: "p" });
  assert.strictEqual(w.notifyResult(true, "n").act, "end");
  assert.strictEqual(w.returnSeconds(), 5);
  w.done();
  assert.strictEqual(w.snapshot().mode, "page");
  w.tap("o");
  assert.deepStrictEqual(w.notifyResult(false, "n"), { act: "press", purpose: "p" });
  w.pressResult(false);
  assert.strictEqual(w.snapshot().notice, V.PRESS_FAILED_NOTICE);
  assert.strictEqual(w.snapshot().mode, "page");
}

// A disabled or unusable document leaves the classic screen; null is rejected.
assert.strictEqual(V.create({ enabled: false, reason: "disabled" }, "ja").snapshot().mode, "legacy");
assert.strictEqual(V.create({ enabled: true, start: "x", steps: {} }, "ja").snapshot().mode, "legacy");
assert.throws(() => V.create(null, "ja"), /object/);

// An unknown step kind degrades to a direct call.
{
  const doc = { enabled: true, start: "s", steps: {
    s: { kind: "page", options: [{ id: "o", semantic_id: "call.primary", label: { ja: "x" }, style: "primary", to: "q" }] },
    q: { kind: "teleport" } } };
  const w = V.create(doc, "ja");
  assert.deepStrictEqual(w.apply({ tap: "o" }), [{ press: "" }]);
  assert.strictEqual(w.snapshot().mode, "calling");
}
console.log("visitor_flow OK (" + checked + " walk steps)");
