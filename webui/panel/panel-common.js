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

  return { esc: esc, qs: qs, normalizeLang: normalizeLang, format: format,
           createCatalog: createCatalog, setText: setText,
           applyEmergencyText: applyEmergencyText, newestHlc: newestHlc };
});
