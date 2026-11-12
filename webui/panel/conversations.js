(function(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DoorbellConversations = api;
})(typeof window !== "undefined" ? window : this, function() {
  "use strict";
  function create(options) {
    const sessions = new Map(), pending = new Set(), attempted = new Set();
    let snapshot = null, focus = "", closed = false, epoch = 0;
    const key = door => door ? door.id + ":" + (door.call_id || "") : "";
    const actor = () => snapshot && snapshot.conversation_actor || "";
    const member = door => door && door.conversation &&
      (door.conversation.participants || []).find(item => item.device === actor());
    const request = (door, action) => Object.freeze({ door: door.id, call_id: door.call_id,
      stage_revision: Number(door.stage_revision) || 0, expected_version: Number(door.conversation && door.conversation.version) || 0,
      action });
    function audible() {
      for (const [id, entry] of sessions) {
        const door = snapshot && snapshot.doors.find(item => key(item) === id);
        const mine = member(door);
        entry.media.setHeld(id !== focus || !mine || mine.state === "held");
      }
    }
    async function action(door, verb, frozen) {
      if (closed || !door || !door.call_id) return false;
      const body = frozen || request(door, verb);
      const target = key(door);
      if (pending.has(target)) return false;
      const generation = epoch;
      pending.add(target);
      if (verb === "answer" || verb === "join" || verb === "takeover" || verb === "resume") focus = target;
      audible();
      try {
        const result = await options.send(body);
        return !!result && result.ok === true;
      } finally { if (generation === epoch) { pending.delete(target); if (options.changed) options.changed(); } }
    }
    function select(door) {
      const next = key(door);
      if (next === focus) return;
      focus = next;
      audible();
      if (snapshot) for (const old of snapshot.doors) {
        const me = member(old);
        if (key(old) !== next && me && (me.state === "connected" || me.state === "dialing"))
          action(old, me.state === "connected" ? "hold" : "leave").catch(options.error);
      }
    }
    async function connect(door, mine) {
      const target = key(door), generation = mine.leg, identityEpoch = epoch;
      const attemptKey = target + ":" + generation;
      if (attempted.has(attemptKey)) return;
      attempted.add(attemptKey);
      try {
        const grant = await options.authorize(request(door, "media"));
        const latest = snapshot && snapshot.doors.find(item => key(item) === target);
        if (closed || identityEpoch !== epoch || !grant || grant.ok !== true || !member(latest) || member(latest).leg !== generation) return;
        const media = options.media(latest, grant, {
          ended: () => {
            const entry = sessions.get(target);
            if (!entry || entry.generation !== generation) return;
            sessions.delete(target);
            const current = snapshot && snapshot.doors.find(item => key(item) === target);
            if (current && member(current) && member(current).leg === generation)
              action(current, "leave").catch(options.error);
            if (options.changed) options.changed();
          }
        });
        const previous = sessions.get(target);
        if (previous) previous.media.close();
        sessions.set(target, { generation, media });
        audible();
      } catch (error) {
        if (options.error) options.error(error);
        const current = snapshot && snapshot.doors.find(item => key(item) === target);
        if (identityEpoch === epoch && current && member(current) && member(current).leg === generation)
          action(current, "leave").catch(options.error);
      }
    }
    function update(value) {
      if (snapshot && snapshot.conversation_actor !== value.conversation_actor) {
        ++epoch;
        for (const entry of sessions.values()) entry.media.close();
        sessions.clear(); pending.clear(); attempted.clear();
      }
      snapshot = value;
      for (const [id, entry] of sessions) {
        const door = snapshot.doors.find(item => key(item) === id);
        const mine = member(door);
        if (!mine || mine.leg !== entry.generation) {
          sessions.delete(id);
          entry.media.close();
        }
      }
      for (const door of snapshot.doors) {
        const mine = member(door);
        if (mine && mine.state === "dialing" && !sessions.has(key(door))) connect(door, mine);
      }
      audible();
      if (options.changed) options.changed();
    }
    function heartbeat() {
      if (!snapshot || closed) return;
      for (const door of snapshot.doors) {
        const mine = member(door);
        if (mine && (mine.state === "waiting" || mine.state === "held" || sessions.has(key(door)))) options.send(Object.assign({}, request(door, "heartbeat"), { leg: mine.leg || "" })).catch(options.error);
      }
    }
    function close() {
      closed = true;
      ++epoch;
      for (const entry of sessions.values()) entry.media.close();
      sessions.clear();
      if (snapshot) for (const door of snapshot.doors) if (member(door))
        options.send(request(door, "leave"), true).catch(options.error);
    }
    return { update, action, select, heartbeat, close, member, request,
      active: door => sessions.has(key(door)), pending: door => pending.has(key(door)) };
  }
  return { create };
});
