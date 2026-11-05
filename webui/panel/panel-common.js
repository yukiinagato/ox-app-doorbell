/* Helpers shared by the door and monitor panel pages. ES5 parse-safe: the door page still runs
 * on iOS 5 Safari. Pages load runtime.js first and pass DoorbellPanelRuntime.panelRequest in. */
(function (root, factory) {
  var api = factory(root);
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DoorbellPanelCommon = api;
})(typeof window !== "undefined" ? window : {}, function (root) {
  "use strict";

  var ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
                  "`": "&#96;" };

  // Safe in element content and in quoted attribute values alike.
  function esc(value) {
    return String(value === null || value === undefined ? "" : value)
      .replace(/[&<>"'`]/g, function (c) { return ESCAPES[c]; });
  }

  function qs(name, search) {
    var source = search === undefined ? String((root.location && root.location.search) || "") :
      String(search || "");
    var match = source.match(new RegExp("[?&]" + name + "=([^&]*)"));
    if (!match) return "";
    try { return decodeURIComponent(match[1].replace(/\+/g, "%20")); } catch (e) { return ""; }
  }

  function normalizeLang(value) {
    value = String(value || "").toLowerCase().split("-")[0];
    return value === "ja" || value === "en" || value === "zh" ? value : "";
  }

  function format(template, values) {
    var value = String(template);
    values = values || {};
    for (var name in values) if (Object.prototype.hasOwnProperty.call(values, name))
      value = value.split("{" + name + "}").join(String(values[name]));
    return value;
  }

  // One catalog per page. load(lang, cb) coalesces concurrent requests for the same language and
  // only the newest request may install a catalog. A missing catalog falls back to English.
  function createCatalog(request, onInstalled) {
    var state = { lang: "", catalog: {}, loading: "", waiters: [], serial: 0 };
    function flush() {
      var waiters = state.waiters;
      state.waiters = [];
      for (var i = 0; i < waiters.length; i++) waiters[i]();
    }
    function install(lang, catalog) {
      state.lang = lang;
      state.catalog = catalog || {};
      state.loading = "";
      if (root.document && root.document.documentElement)
        root.document.documentElement.setAttribute("lang", lang);
      if (onInstalled) onInstalled(lang);
      flush();
    }
    function load(requested, cb) {
      var lang = normalizeLang(requested) || "ja";
      if (cb) state.waiters.push(cb);
      if (state.lang === lang && !state.loading) { flush(); return; }
      if (state.loading === lang) return;
      state.loading = lang;
      var serial = ++state.serial;
      request("GET", "/locale/" + lang + ".json", null, function (status, catalog) {
        if (serial !== state.serial) return;
        if (status === 200 && catalog) { install(lang, catalog); return; }
        state.loading = "";
        if (lang !== "en") { load("en"); return; }
        install("en", {});
      });
    }
    function t(key, values) {
      return format(typeof state.catalog[key] === "string" ? state.catalog[key] : key, values);
    }
    return { load: load, t: t, lang: function () { return state.lang; },
             has: function (key) { return typeof state.catalog[key] === "string"; } };
  }

  function setText(element, value) {
    if (!element) return;
    if ("textContent" in element) element.textContent = value;
    else element.innerText = value;
  }

  // Re-labels the SOS overlay and trigger installed by DoorbellPanelRuntime after a language
  // change. Text is assigned, never parsed as markup.
  function applyEmergencyText(overlay, t, doc) {
    doc = doc || root.document;
    if (overlay && overlay.refreshText) overlay.refreshText();
    if (!doc || !doc.getElementsByClassName) return;
    var overlays = doc.getElementsByClassName("dbEmergencyOverlay");
    if (overlays.length) {
      var headings = overlays[0].getElementsByTagName("h2");
      var paragraphs = overlays[0].getElementsByTagName("p");
      if (headings.length) setText(headings[0], t("emergency.title"));
      if (paragraphs.length) setText(paragraphs[0], t("emergency.active_detail"));
      if (paragraphs.length > 1) setText(paragraphs[1], t("emergency.clear_instruction"));
    }
    var triggers = doc.getElementsByClassName("dbSosTrigger");
    if (triggers.length) {
      var spans = triggers[0].getElementsByTagName("span");
      triggers[0].setAttribute("aria-label", t("emergency.button"));
      if (spans.length) setText(spans[0], t("emergency.button"));
      if (spans.length > 1) setText(spans[1], t("emergency.hold_hint", { sec: "2" }));
    }
  }

  // The newest ordered HLC among rows, so "mark as seen" covers exactly what was displayed.
  function newestHlc(rows) {
    var newest = "";
    for (var i = 0; rows && i < rows.length; i++) {
      var value = rows[i] && (rows[i].updated_hlc || rows[i].hlc);
      if (typeof value === "string" && value.length <= 128 && value > newest) newest = value;
    }
    return newest;
  }

  // ---- UI guideline helpers (docs/en/ui-guidelines.md) ----

  // Size class from the window width: compact < 600 <= medium < 900 <= expanded.
  function sizeClass(width) {
    width = Number(width) || 0;
    return width >= 900 ? "expanded" : width >= 600 ? "medium" : "compact";
  }

  function hexColor(value) {
    return /^#[0-9a-fA-F]{6}$/.test(String(value || "")) ? String(value).toLowerCase() : "";
  }

  // Semantic color roles from Core's theme regions (display.theme). Only validated colors are
  // returned; a role Core does not provide keeps the page default. Per-element semantic UI
  // overrides are applied separately and still win.
  function colorRoles(theme) {
    theme = theme && typeof theme === "object" ? theme : {};
    var roles = {}, bg = theme.auto_background, ink = theme.auto_ink || {},
        override = theme.ink_override || {};
    var surface = hexColor(bg && bg.color);
    if (surface) roles.surface = surface;
    var onSurface = hexColor(override.status_line) || hexColor(ink.status_line);
    if (onSurface) roles.on_surface = onSurface;
    var muted = hexColor(override.hint) || hexColor(ink.hint);
    if (muted) roles.muted = muted;
    var accent = hexColor(theme.call_button_bg);
    if (accent) roles.accent = accent;
    var onAccent = hexColor(theme.call_button_ink);
    if (onAccent) roles.on_accent = onAccent;
    return roles;
  }

  function applyColorRoles(theme, doc) {
    doc = doc || root.document;
    var el = doc && doc.documentElement, roles = colorRoles(theme), applied = [];
    if (!el || !el.style || !el.style.setProperty) return applied;
    for (var name in roles) if (Object.prototype.hasOwnProperty.call(roles, name)) {
      el.style.setProperty("--" + name.replace(/_/g, "-"), roles[name]);
      applied.push(name);
    }
    return applied;
  }

  // Door tile state chip: ringing, in_call, offline or idle.
  function doorTileState(door) {
    door = door || {};
    var s = String(door.call_state || "");
    if (s === "answered" || s === "in_call") return "in_call";
    if (door.calling || s === "ringing" || s === "purpose_pending") return "ringing";
    if (door.online === false) return "offline";
    return "idle";
  }

  function dayKey(ms) {
    var d = new Date(Number(ms) || 0);
    return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate();
  }

  // History grouped by local calendar day, newest first. kind is "today", "yesterday" or
  // "date" (label it with the ms of the first row).
  function groupByDay(rows, nowMs) {
    var today = dayKey(nowMs), yesterday = dayKey(Number(nowMs) - 86400000), groups = [], byKey = {};
    var sorted = (rows || []).slice().sort(function (a, b) {
      return (Number(b && b.ts) || 0) - (Number(a && a.ts) || 0); });
    for (var i = 0; i < sorted.length; i++) {
      var row = sorted[i] || {}, key = dayKey(row.ts);
      if (!byKey[key]) {
        byKey[key] = { key: key, ms: Number(row.ts) || 0, rows: [],
          kind: key === today ? "today" : key === yesterday ? "yesterday" : "date" };
        groups.push(byKey[key]);
      }
      byKey[key].rows.push(row);
    }
    return groups;
  }

  return { esc: esc, qs: qs, normalizeLang: normalizeLang, format: format,
           createCatalog: createCatalog, setText: setText,
           applyEmergencyText: applyEmergencyText, newestHlc: newestHlc,
           sizeClass: sizeClass, colorRoles: colorRoles, applyColorRoles: applyColorRoles,
           doorTileState: doorTileState, groupByDay: groupByDay };
});
