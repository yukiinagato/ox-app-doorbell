"use strict";
const assert = require("assert");
const { create } = require("../panel/conversations.js");
const turn = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; return { promise: new Promise(ok => { resolve = ok; }), resolve: value => resolve(value) }; }
function door(id, state, version = 1, leg = id + "-leg", device = "resident") {
  return { id, call_id: id + "-call", stage_revision: 0,
    conversation: { version, owner: device, participants: [{ device, state, leg, established: state !== "dialing" }] } };
}
async function run() {
  const requests = [], media = [];
  const client = create({ send: async request => { requests.push(request); return { ok: true }; },
    authorize: async () => ({ ok: true, mode: "signed-mode", auth: "test-only" }),
    media: (d, grant, callbacks) => {
      const item = { id: d.id, held: true, closed: false, callbacks,
        setHeld(value) { this.held = value; }, close() { this.closed = true; } };
      media.push(item); return item;
    }, error: error => { throw error; } });
  const a = door("front", "dialing"), b = door("side", "dialing");
  client.select(a);
  client.update({ conversation_actor: "resident", doors: [a, b] });
  await turn();
  assert.equal(media.length, 2);
  assert.equal(media[0].held, false);
  assert.equal(media[1].held, true, "a later door cannot acquire the selected audio output");
  const connectedA = door("front", "connected", 2), connectedB = door("side", "connected", 2);
  client.update({ conversation_actor: "resident", doors: [connectedA, connectedB] });
  client.select(connectedB);
  await turn();
  assert.equal(media[0].held, true);
  assert.equal(media[1].held, false);
  assert(requests.some(r => r.action === "hold" && r.door === "front" && r.call_id === "front-call"));
  const frozen = client.request(connectedA, "takeover");
  client.update({ conversation_actor: "resident", doors: [door("front", "connected", 3), connectedB] });
  await client.action(connectedA, "takeover", frozen);
  assert.equal(requests.at(-1).expected_version, 2, "activation cannot retarget a frozen takeover to a newer owner");
  const old = media[0];
  client.update({ conversation_actor: "resident", doors: [door("front", "dialing", 4, "replacement"), connectedB] });
  await turn();
  const count = requests.length;
  old.callbacks.ended();
  await turn();
  assert.equal(requests.length, count, "a losing SIP generation cannot leave the replacement conversation");
  assert(old.closed);
  client.close();
  assert(media.every(item => item.closed));
  assert(requests.some(r => r.action === "leave" && r.door === "side"));

  const authorization = deferred(); let opened = 0;
  const late = create({ send: async () => ({ ok: true }), authorize: () => authorization.promise,
    media: () => { opened++; return { setHeld() {}, close() {} }; }, error: () => {} });
  late.update({ conversation_actor: "resident", doors: [a] });
  late.update({ conversation_actor: "another-resident", doors: [a] });
  authorization.resolve({ ok: true, auth: "test-only", mode: "old" });
  await turn();
  assert.equal(opened, 0, "a delayed grant cannot cross browser identity changes");
  late.close();
  console.log("conversation controller: selection/holding/generation/frozen actions/identity change PASS");
}
run().catch(error => { console.error(error); process.exitCode = 1; });
