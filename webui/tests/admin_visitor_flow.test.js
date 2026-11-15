"use strict";
// The Admin flow editor's pure model: validation mirrors Core's write rules, the simulator's
// resolved document agrees with Core's resolver on the shared fixture, drafts round-trip.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const L = require("../admin/app.js");
const V = require("../panel/visitor-flow.js");

const suite = JSON.parse(fs.readFileSync(path.join(__dirname, "../../tools/conformance/fixtures/visitor-flow-v1.json"), "utf8"));

// The draft resolved on the client is what Core's resolver produces for configured flows, as far
// as the walker can see: the same steps, options, semantic ids and labels.
let compared = 0;
for (const c of suite.resolve) {
  const flow = (c.config || {}).visitor_flow;
  // Flows Core had to repair (issues) cannot be saved by the editor, which validates first.
  if (!flow || !flow.steps || c.expect.source !== "config" || c.expect.enabled !== true ||
      (c.expect.issues || []).length) continue;
  const draft = L.flowDraftFromConfig(c.config);
  if (!draft) continue;
  const mine = L.flowResolve(draft, c.config, c.door);
  assert.strictEqual(mine.start, c.expect.start, c.name + ": start");
  for (const id of Object.keys(c.expect.steps)) {
    if (id.indexOf("__") === 0) continue; // synthesized by Core while repairing
    const want = c.expect.steps[id], got = mine.steps[id];
    assert(got, c.name + ": step " + id);
    assert.strictEqual(got.kind, want.kind, c.name + ": kind of " + id);
    if (want.kind !== "page") continue;
    const brief = (page) => page.options.map((o) => [o.id, o.semantic_id, V.textIn(o.label, "en"), o.to]);
    assert.deepStrictEqual(brief(got), brief(want), c.name + ": options of " + id);
    compared++;
  }
}
assert(compared >= 3, "at least a few configured flows were compared (" + compared + ")");

// Walking the draft with the shared walker reaches the terminal actions.
{
  const cfg = { ui: { languages: ["en"] }, visit_purposes: { p_d: { label: { en: "Delivery" }, icon: "x" } } };
  const draft = L.flowDraftFromTemplate({ enabled: true, start: "s", idle_s: 30, require_call: true, steps: {
    s: { kind: "page", title: { en: "Hi" }, options: [{ id: "o1", purpose: "p_d", to: "n" }, { id: "o2", label: { en: "Ring" }, style: "primary", to: "c" }] },
    n: { kind: "notify", message: { en: "Left it" }, purpose: "p_d", to: "e" }, e: { kind: "end", return_s: 5 }, c: { kind: "call" } } }, cfg);
  const walker = V.create(L.flowResolve(draft, cfg), "en");
  assert.deepStrictEqual(walker.snapshot().options.map((o) => [o.id, o.semantic_id, o.label]), [["o1", "purpose.button", "Delivery"], ["o2", "call.primary", "Ring"]]);
  assert.deepStrictEqual(walker.apply({ tap: "o1" }), [{ notify: "n" }]);
  assert.strictEqual(walker.snapshot().mode, "end");
}

// Validation: Core's rules, as the editor shows them next to the field.
function codes(draft, cfg) {
  const v = L.flowValidate(draft, cfg || {});
  return v.errors.map((e) => e.code + (e.step ? ":" + e.step : "") + (e.option ? "." + e.option : "") + (e.field ? "@" + e.field : "")).sort();
}
const cfg = { ui: { languages: ["en", "ja"] }, visit_purposes: { p: { label: { en: "P" } } }, assets: { [("ab").repeat(32)]: { type: "image/png" } },
  media_sources: { cam: { name: "Parcel cam", streams: { snapshot: { url: "http://cam/snap" } } }, nosnap: { streams: {} } } };
const good = () => ({ enabled: true, start: "s", idle_s: 45, require_call: true, door_starts: {}, steps: {
  s: { kind: "page", options: [{ id: "o", label: { en: "Call" }, style: "primary", to: "c" }, { id: "p", purpose: "p", to: "p2" }] },
  c: { kind: "call" }, p2: { kind: "page", title: { en: "T" }, options: [{ id: "o", label: { en: "Leave" }, to: "n" }] },
  n: { kind: "notify", message: { en: "m" }, to: "e", snapshot: { source: "media_source", id: "cam" } }, e: { kind: "end" } } });
assert.deepStrictEqual(codes(good(), cfg), []);

let d = good(); d.steps.s.options[0].to = "gone";
assert.deepStrictEqual(codes(d, cfg), ["no_reachable_call:start", "unknown_target:s.o"], "the only call was behind the broken option");
d = good(); d.steps.s.options[1].style = "primary";
assert.deepStrictEqual(codes(d, cfg), ["multiple_primary:s"]);
d = good(); d.steps.s.options = [];
assert.deepStrictEqual(codes(d, cfg).filter((x) => x.indexOf("no_options") === 0), ["no_options:s"]);
d = good(); d.steps.s.options[0].label = {};
assert.deepStrictEqual(codes(d, cfg), ["option_needs_label:s.o"]);
d = good(); d.steps.s.options[1].purpose = "deleted";
assert.deepStrictEqual(codes(d, cfg), ["unknown_purpose:s.p"]);
d = good(); d.steps.p2.title = { en: "x".repeat(61) };
assert.deepStrictEqual(codes(d, cfg), ["bad_text:p2@title"]);
d = good(); d.steps.p2.body = { en: "a\n\nb\n\nc\n\nd\n\ne\n\nf\n\ng\n\nh\n\ni" };
assert.deepStrictEqual(codes(d, cfg), ["bad_text:p2@body"]);
d = good(); d.steps.n.to = "c";
assert.deepStrictEqual(codes(d, cfg), ["bad_target_kind:n"]);
d = good(); d.steps.n.snapshot = { source: "media_source", id: "nosnap" };
assert.deepStrictEqual(codes(d, cfg), ["unknown_camera:n"]);
d = good(); d.steps.n.snapshot = { source: "door_station" };
assert.deepStrictEqual(codes(d, cfg), []);
d = good(); d.steps.p2.images = [{ asset: "00".repeat(32), place: "above" }];
assert.deepStrictEqual(codes(d, cfg), ["unknown_asset:p2@image.0"]);
d = good(); d.start = "";
assert.deepStrictEqual(codes(d, cfg), ["missing_start"]);
d = good(); d.start = "c";
assert.deepStrictEqual(codes(d, cfg), ["bad_target_kind:start"]);
d = good(); d.steps.c.on_unanswered = "e";
assert.deepStrictEqual(codes(d, cfg), ["bad_target_kind:c"]);
d = good(); d.steps.p2.options[0] = { id: "o", label: { en: "Back" }, to: "s" };
assert(codes(d, cfg).some((x) => x.indexOf("cycle:") === 0), "a page cycle is refused");
d = good(); d.steps.c.on_unanswered = "s";
assert.deepStrictEqual(codes(d, cfg), [], "an unanswered branch back to a page is not a cycle");

// require_call: an error while on, a warning while off.
d = good(); d.steps.s.options = [{ id: "p", purpose: "p", to: "n" }]; delete d.steps.p2; delete d.steps.c;
assert.deepStrictEqual(codes(d, cfg), ["no_reachable_call:start"]);
d.require_call = false;
assert.deepStrictEqual(codes(d, cfg), []);
assert.deepStrictEqual(L.flowValidate(d, cfg).warnings.map((w) => w.code), ["no_call"]);
// A crowded page with text is a warning, not an error.
d = good(); d.steps.s.body = { en: "text" };
for (let i = 0; i < 4; i++) d.steps.s.options.push({ id: "x" + i, label: { en: "x" }, to: "c" });
assert.deepStrictEqual(codes(d, cfg), []);
assert.deepStrictEqual(L.flowValidate(d, cfg).warnings.map((w) => w.code), ["crowded_page"]);

// Limits and ids.
d = good();
for (let i = 0; i < 33; i++) d.steps["x" + i] = { kind: "call" };
assert(codes(d, cfg).includes("too_many_steps"));
assert(L.flowIdValid("s_home-1") && !L.flowIdValid("__call") && !L.flowIdValid("a.b") && !L.flowIdValid("x".repeat(33)));
d = good();
for (let i = 0; i < 13; i++) d.steps.s.options.push({ id: "y" + i, label: { en: "y" }, to: "c" });
assert(codes(d, cfg).some((x) => x.indexOf("too_many_options") === 0));

// Where things are listed and who points where.
d = good();
assert.deepStrictEqual(L.flowStepOrder(d), ["s", "c", "p2", "n", "e"]);
assert.deepStrictEqual(L.flowReferrers(d, "c"), ["s"]);
assert.deepStrictEqual(L.flowReferrers(d, "s"), ["start"]);
assert.deepStrictEqual(L.flowCameras(cfg), [{ id: "cam", name: "Parcel cam" }]);
assert.strictEqual(L.flowDraftFromConfig({ visitor_flow: { enabled: true } }), null, "no steps: the built-in wizard is in use");
const stored = L.flowDraftFromConfig({ visitor_flow: { start: "s", steps: good().steps }, doors: { d1: { visitor_flow: { start: "s" } } } });
assert.strictEqual(stored.enabled, true);
assert.strictEqual(stored.idle_s, 45);
assert.deepStrictEqual(stored.door_starts, { d1: "s" });
console.log("admin visitor flow: PASS");
