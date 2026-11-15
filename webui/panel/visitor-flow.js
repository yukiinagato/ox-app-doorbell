/* Visitor-flow walker shared by the door page and Admin's simulator. ES5, no DOM.
 * Port of tools/conformance/visitor_flow.py: docs/en/visitor-flow-contract.md section 5.
 * The model only reads a resolved document; it never invents text. */
(function (root, factory) {
  var api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DoorbellVisitorFlow = api;
})(typeof window !== "undefined" ? window : {}, function () {
  "use strict";
  var MAX_STEPS = 34;
  var DEFAULT_IDLE_S = 45, DEFAULT_RETURN_S = 8;
  var NO_ANSWER_NOTICE = "calling.no_answer";
  var PRESS_FAILED_NOTICE = "flow.call_failed";

  function isObj(v) { return !!v && typeof v === "object" && !(v instanceof Array); }
  function nonEmpty(v) { return typeof v === "string" && v !== ""; }

  // The language, then Japanese, then any value the map carries.
  function textIn(labels, lang) {
    if (!isObj(labels)) return null;
    var keys = [lang, "ja"], i, k;
    for (i = 0; i < keys.length; i++) if (nonEmpty(labels[keys[i]])) return labels[keys[i]];
    for (k in labels) if (Object.prototype.hasOwnProperty.call(labels, k) && nonEmpty(labels[k]))
      return labels[k];
    return null;
  }

  // Plain text only: a blank line starts a paragraph, a single newline is a line break.
  function paragraphs(body) {
    if (!nonEmpty(body)) return [];
    var parts = String(body).replace(/\r\n?/g, "\n").split(/\n{2,}/), out = [], i;
    for (i = 0; i < parts.length; i++) if (parts[i] !== "") out.push(parts[i].split("\n"));
    return out;
  }

  // Option icons: the purpose id, then a known emoji from the purpose data, name a vendored Tabler
  // icon (webui/icons). Emoji are never rendered; anything unknown is the person icon.
  var ICON_BY_PURPOSE = { visit: "home", visitor: "home", delivery: "package", parcel: "package",
    mail: "mail", post: "mail", sales: "briefcase", collection: "briefcase", work: "tool",
    utility: "tool", repair: "tool", construction: "tool", other: "dots" };
  var ICON_BY_GLYPH = { "\uD83C\uDFE0": "home", "\uD83C\uDFE1": "home", "\uD83D\uDCE6": "package",
    "\u2709": "mail", "\uD83D\uDCE7": "mail", "\uD83D\uDCEE": "mail", "\uD83D\uDCBC": "briefcase",
    "\uD83D\uDECD": "briefcase", "\uD83D\uDD27": "tool", "\uD83D\uDD28": "tool", "\uD83D\uDEE0": "tool",
    "\u2753": "dots", "\u2754": "dots", "\u270D": "pencil", "\uD83D\uDC64": "user" };
  function iconFor(purposeId, glyph) {
    var g = typeof glyph === "string" ? glyph.replace(/\uFE0F/g, "") : "";
    if (g !== "" && Object.prototype.hasOwnProperty.call(ICON_BY_GLYPH, g)) return ICON_BY_GLYPH[g];
    var p = typeof purposeId === "string" ? purposeId.toLowerCase().replace(/^p_/, "") : "";
    if (p !== "" && Object.prototype.hasOwnProperty.call(ICON_BY_PURPOSE, p)) return ICON_BY_PURPOSE[p];
    return "user";
  }

  function FlowWalker(flow, lang) {
    this.lang = lang || "ja";
    this.flow = {};
    this.mode = "legacy";
    this.stack = [];
    this.activeStep = null;
    this.notice = null;
    this.reply = false;
    this._load(flow);
    this._home();
  }
  var P = FlowWalker.prototype;

  P._load = function (flow) {
    if (!isObj(flow)) throw new Error("a resolved flow must be an object");
    var steps = flow.steps, n = 0, k;
    if (steps !== undefined && !isObj(steps)) throw new Error("resolved steps must be an object");
    if (steps) for (k in steps) if (Object.prototype.hasOwnProperty.call(steps, k)) n++;
    if (n > MAX_STEPS) throw new Error("too many steps");
    this.flow = flow;
  };
  P._enabled = function () {
    return this.flow.enabled === true && this._kind(this.flow.start) === "page";
  };
  P.step = function (id) {
    var steps = this.flow.steps;
    var s = isObj(steps) && typeof id === "string" &&
            Object.prototype.hasOwnProperty.call(steps, id) ? steps[id] : null;
    return isObj(s) ? s : {};
  };
  P._kind = function (id) {
    var kind = this.step(id).kind;
    return typeof kind === "string" ? kind : "";
  };
  P._home = function () {
    this.activeStep = null;
    if (this._enabled()) { this.mode = "page"; this.stack = [this.flow.start]; }
    else { this.mode = "legacy"; this.stack = []; }
  };
  P._purpose = function (id) {
    var p = this.step(id).purpose;
    return typeof p === "string" ? p : "";
  };

  // ---- what is on screen ----
  P.pageId = function () {
    if (this.mode === "page") return this.stack[this.stack.length - 1];
    if (this.mode === "end") return this.activeStep;
    return null;
  };
  P.options = function () {
    if (this.mode !== "page") return [];
    var list = this.step(this.pageId()).options, out = [], i;
    if (!(list instanceof Array)) return out;
    for (i = 0; i < list.length; i++) if (isObj(list[i])) out.push(list[i]);
    return out;
  };
  P.snapshot = function () {
    var page = this.pageId(), step = this.step(page), options = [], i, list = this.options();
    for (i = 0; i < list.length; i++)
      options.push({ id: list[i].id === undefined ? null : list[i].id,
                     semantic_id: list[i].semantic_id === undefined ? null : list[i].semantic_id,
                     label: textIn(list[i].label, this.lang) });
    return {
      mode: this.mode,
      page: page === undefined ? null : page,
      title: page ? textIn(step.title, this.lang) : null,
      options: options,
      back: this.mode === "page" && this.stack.length > 1,
      done: this.mode === "end",
      notice: this.notice,
      reply: this.reply
    };
  };
  P.idleSeconds = function () {
    var n = Number(this.flow.idle_s);
    return n >= 1 ? n : DEFAULT_IDLE_S;
  };
  P.returnSeconds = function () {
    var n = Number(this.step(this.activeStep).return_s);
    return this.mode === "end" && n >= 1 ? n : DEFAULT_RETURN_S;
  };
  P.setLang = function (lang) { this.lang = lang || "ja"; };
  P.setReply = function (on) { this.reply = !!on; };

  // ---- input. tap() returns the next action; the caller performs it and reports back. ----
  // {act:"none"|"page"|"end"} changed nothing external; {act:"press",purpose} and
  // {act:"notify",step,purpose} ask the caller to call Core, then report pressResult() or
  // notifyResult().
  P.tap = function (optionId) {
    if (this.mode !== "page") return { act: "none" };
    var options = this.options(), chosen = null, i;
    for (i = 0; i < options.length; i++) if (options[i].id === optionId) chosen = options[i];
    if (!chosen) return { act: "none" };
    this.notice = null;
    var target = chosen.to, kind = this._kind(target);
    if (kind === "page") {
      var at = this.stack.indexOf(target);
      if (at >= 0) this.stack.length = at + 1; else this.stack.push(target);
      return { act: "page" };
    }
    if (kind === "call") {
      this.activeStep = target;
      return { act: "press", purpose: this._purpose(target) };
    }
    if (kind === "notify") return { act: "notify", step: target, purpose: this._purpose(target) };
    if (kind === "end") { this.mode = "end"; this.activeStep = target; return { act: "end" }; }
    this.activeStep = null;
    return { act: "press", purpose: "" };
  };
  P.notifyResult = function (ok, step) {
    var after = this.step(step).to;
    if (ok !== true || this._kind(after) !== "end") {
      this.activeStep = null;
      return { act: "press", purpose: this._purpose(step) };
    }
    this.mode = "end";
    this.activeStep = after;
    return { act: "end" };
  };
  P.pressResult = function (ok) {
    if (ok) this.mode = "calling"; else this.notice = PRESS_FAILED_NOTICE;
  };
  // A call this screen did not start (already ringing on load).
  P.adoptCall = function () {
    if (this.mode === "legacy") return;
    this.mode = "calling";
  };
  P.back = function () {
    if (this.mode === "page" && this.stack.length > 1) { this.stack.pop(); this.notice = null; }
  };
  P.idleTimeout = function () {
    if (this.mode === "page") { this.stack = this.stack.slice(0, 1); this.notice = null; }
  };
  P.done = function () { if (this.mode === "end") this._home(); };
  P.callEnded = function (reason) {
    if (this.mode !== "calling") return;
    var unanswered = this.step(this.activeStep).on_unanswered;
    this._home();
    if (reason !== "timeout" || this.mode !== "page") return;
    if (this._kind(unanswered) === "page") {
      if (unanswered !== this.stack[0]) this.stack.push(unanswered);
    } else this.notice = NO_ANSWER_NOTICE;
  };
  P.replace = function (flow) {
    var previousMode = this.mode, previous = this.stack.slice(), i;
    this._load(flow);
    if (!this._enabled()) { if (previousMode !== "calling") this._home(); return; }
    if (previousMode === "calling") return;
    if (previousMode === "end" && this._kind(this.activeStep) === "end") return;
    var keep = previousMode === "page" && previous[0] === this.flow.start;
    for (i = 0; keep && i < previous.length; i++) if (this._kind(previous[i]) !== "page") keep = false;
    this._home();
    if (keep) this.stack = previous;
  };

  // Replays one conformance event (see the fixture's walk cases) and returns the Core calls.
  P.apply = function (event) {
    var calls = [], act;
    if (event.reply !== undefined) { this.setReply(event.reply); return calls; }
    if (event.lang !== undefined) { this.setLang(String(event.lang)); return calls; }
    if (event.flow_changed !== undefined) { this.replace(event.flow_changed); return calls; }
    if (event.tap !== undefined) {
      act = this.tap(event.tap);
      if (act.act === "notify") {
        var result = event.notify_result || { ok: true };
        calls.push({ notify: act.step });
        act = this.notifyResult(result.ok === true, act.step);
      }
      if (act.act === "press") {
        calls.push({ press: act.purpose });
        this.pressResult(event.press_result !== "failed");
      }
      return calls;
    }
    if (event.back) { this.back(); return calls; }
    if (event.idle_timeout) { this.idleTimeout(); return calls; }
    if (event.done || event.end_timeout) { this.done(); return calls; }
    if (event.call_ended !== undefined) { this.callEnded(String(event.call_ended)); return calls; }
    throw new Error("unknown walk event");
  };

  return { create: function (flow, lang) { return new FlowWalker(flow, lang); },
           textIn: textIn, paragraphs: paragraphs, iconFor: iconFor,
           NO_ANSWER_NOTICE: NO_ANSWER_NOTICE, PRESS_FAILED_NOTICE: PRESS_FAILED_NOTICE };
});
