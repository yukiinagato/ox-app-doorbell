"use strict";
const assert = require("assert");
const C = require("../panel/call-flow.js");

assert.strictEqual(C.flowMode("ring_then_purpose"), "ring_then_purpose");
assert.strictEqual(C.flowMode({ mode: "ring_then_purpose" }), "ring_then_purpose");
assert.strictEqual(C.flowMode("unknown"), "purpose_first");
assert.strictEqual(C.pressForm("d front", "a+b", "delivery"),
                   "door=d%20front&purpose=delivery");
assert.strictEqual(C.cancelForm("front", "call-2", "tok"),
                   "door=front&call_id=call-2");
assert.throws(() => C.cancelForm("front", "", "tok"), /call_id/);
assert.throws(() => C.purposeForm("front", "old", "", "tok"), /purpose/);
assert.strictEqual(C.recoveryForm("front", "call-2", false, "tok"),
                   "door=front&call_id=call-2&restored=0");
assert.strictEqual(C.recoveryForm("front", "call-2", true, "tok"),
                   "door=front&call_id=call-2&restored=1");
assert.throws(() => C.recoveryForm("front", "", true, "tok"), /call_id/);
const dialogId = "0123456789abcdef0123456789abcdef";
assert.strictEqual(C.lifecycleForm("front", "call-2", 3, "answered", dialogId),
                   "door=front&call_id=call-2&stage_revision=3&state=answered&dialog_id=" + dialogId);
assert.strictEqual(C.lifecycleForm("front", "call-2", 3, "ended", dialogId, "remote_hangup"),
                   "door=front&call_id=call-2&stage_revision=3&state=ended&dialog_id=" +
                   dialogId + "&reason=remote_hangup");
assert.throws(() => C.lifecycleForm("front", "call-2", -1, "answered", dialogId),
              /stage_revision/);
assert.throws(() => C.lifecycleForm("front", "call-2", 0, "monitor", dialogId),
              /lifecycle state/);
assert.deepStrictEqual(C.mergeState({ call_id: "new", stage_revision: 3 },
                                    { call_id: "new", stage_revision: 2, call_state: "ringing" }),
                       { accepted: false, reason: "stage_revision" });
assert.deepStrictEqual(C.mergeState({ call_id: "new", stage_revision: 1 },
                                    { call_id: "old", stage_revision: 9 }),
                       { accepted: false, reason: "call_id" });
const merged = C.mergeState({ call_id: "", stage_revision: 1 },
                            { call_id: "c1", stage_revision: 2, call_state: "cancelled" });
assert.strictEqual(merged.accepted, true);
assert.strictEqual(merged.call_id, "c1");
assert.strictEqual(merged.call_state, "cancelled");
assert.strictEqual(C.residentDisposition("in_call", false), "answered_elsewhere");
assert.strictEqual(C.residentDisposition("answered", true), "keep");
assert.strictEqual(C.residentDisposition("ended", true), "end");
assert.strictEqual(C.residentDisposition("cancelled", false), "cancelled");
assert.strictEqual(C.residentDisposition("cancelled", true), "cancelled");
assert.strictEqual(C.residentDisposition("", false, true), "cancelled");
assert.strictEqual(C.residentDisposition("", true, true), "end");
assert.strictEqual(C.residentDisposition("", false, false), "keep");
assert.strictEqual(C.deadlineDelay(61000, 1000), 60000);
assert.strictEqual(C.deadlineDelay(999, 1000), 1);
assert.strictEqual(C.deadlineDelay(0, 1000), 0);

console.log("call flow tests: ok");
