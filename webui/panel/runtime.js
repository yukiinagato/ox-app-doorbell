/* Shared panel runtime: SOS fallback rendering and optional Web Push. ES5 parse-safe. */
(function (root, factory) {
  var api = factory(root);
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.DoorbellPanelRuntime = api;
})(typeof window !== "undefined" ? window : {}, function (root) {
  "use strict";

  function isObj(v) { return !!v && typeof v === "object" && !(v instanceof Array); }
  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  // Cancellation retires this transport only; a write may already have reached Core.
  function requestWithDeadline(options, complete) {
    options = options || {};
    var deadline = options.deadline_ms === undefined ? 3000 : options.deadline_ms;
    if (typeof deadline !== "number" || !isFinite(deadline) || deadline <= 0 ||
        Math.floor(deadline) !== deadline || deadline > 2147483647)
      throw new RangeError("deadline_ms must be a positive bounded integer");
    var method = String(options.method || "GET").toUpperCase(), generation = options.generation;
    var writing = method !== "GET" && method !== "HEAD";
    var xhr = null, timer = null, settled = false;
    var handle = { generation: generation,
      pending: function () { return !settled; },
      cancel: function () { return finish("aborted", null, 0, true); } };
    function finish(kind, data, status, abort) {
      if (settled) return false;
      settled = true;
      if (timer !== null) { root.clearTimeout(timer); timer = null; }
      if (xhr) {
        xhr.onload = xhr.onerror = xhr.ontimeout = xhr.onabort = xhr.onreadystatechange = null;
        if (abort) { try { xhr.abort(); } catch (ignored) {} }
      }
      if (complete) complete({ ok: kind === "success", kind: kind, status: status || 0,
        error_code: data && typeof data.error_code === "string" ? data.error_code : "",
        data: data, generation: generation,
        outcome_unknown: writing && (kind === "timeout" || kind === "network" ||
          kind === "aborted" || kind === "parse_error") });
      return true;
    }
    function received() {
      if (settled) return;
      var status = xhr.status === 1223 ? 204 : xhr.status;
      if (!status) { finish("network", null, 0); return; }
      var data = null, invalid = false;
      try {
        if (xhr.responseText) data = JSON.parse(xhr.responseText);
        else if (status !== 204 && method !== "HEAD") invalid = true;
      } catch (ignored) { invalid = true; }
      if (status < 200 || status >= 300) { finish("http", data, status); return; }
      if (invalid) { finish("parse_error", null, status); return; }
      if (data && (data.ok === false || typeof data.error_code === "string" && data.error_code))
        finish("business", data, status);
      else finish("success", data, status);
    }
    try {
      if (!root.XMLHttpRequest || !root.setTimeout || !root.clearTimeout) {
        finish("network", null, 0); return handle;
      }
      xhr = new root.XMLHttpRequest();
      xhr.open(method, options.url, true);
      // Old WebViews may reject the native timeout property; the watchdog still bounds waiting.
      try { xhr.timeout = deadline; } catch (ignored) {}
      var headers = options.headers || {};
      for (var name in headers) if (own(headers, name)) xhr.setRequestHeader(name, headers[name]);
      xhr.onload = received;
      xhr.onreadystatechange = function () {
        if (xhr.readyState === 4 && xhr.status) received();
      };
      xhr.onerror = function () { finish("network", null, 0); };
      xhr.ontimeout = function () { finish("timeout", null, 0, true); };
      xhr.onabort = function () { finish("aborted", null, 0); };
      timer = root.setTimeout(function () { finish("timeout", null, 0, true); }, deadline);
      xhr.send(options.body === undefined ? null : options.body);
    } catch (error) {
      if (settled) throw error;
      finish("network", null, 0, true);
    }
    return handle;
  }

  // Each owner keeps one lane. Retiring an old handle cannot release a successor's gate.
  function createRequestLane() {
    var active = null, generation = 0;
    return {
      pending: function () { return active !== null; },
      cancel: function () {
        var retired = active;
        active = null;
        if (retired && retired.handle) retired.handle.cancel();
      },
      start: function (options, complete) {
        if (active) return null;
        options = options || {};
        var entry = { generation: ++generation, handle: null }, request = {}, key;
        for (key in options) if (own(options, key)) request[key] = options[key];
        request.generation = entry.generation;
        active = entry;
        try {
          entry.handle = requestWithDeadline(request, function (result) {
            if (active === entry) active = null;
            if (complete) complete(result);
          });
        } catch (error) { if (active === entry) active = null; throw error; }
        return entry.handle;
      }
    };
  }

  var UI_PROPERTIES = ["scale", "font_scale", "foreground", "background",
                       "accent", "border", "radius"];

  function colorOk(v) { return /^#[0-9a-f]{6}$/i.test(String(v || "")); }
  function luminance(hex) {
    if (!colorOk(hex)) return 0;
    var rgb = [1, 3, 5].map(function (i) {
      var c = parseInt(hex.substr(i, 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
  }
  function contrast(a, b) {
    var x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }
  function uiElementValue(elements, semanticId) {
    if (!isObj(elements)) return undefined;
    if (own(elements, semanticId)) return elements[semanticId];
    var cur = elements, parts = semanticId.split(".");
    for (var i = 0; i < parts.length; i++) {
      if (!isObj(cur) || !own(cur, parts[i])) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }

  // Build a constrained style model without accepting CSS, selectors, coordinates, or unknown
  // fields. The same validation runs before a style is cached as last-known-good or applied.
  function semanticUiModel(webUi) {
    var manifest = webUi && webUi.manifest, overrides = webUi && webUi.elements;
    if (!isObj(manifest) || manifest.schema_version !== 1 || !isObj(manifest.viewport) ||
        !isObj(manifest.elements))
      return { ok: false, error: "invalid ui_manifest", elements: {} };
    if (["logical", "dp", "pt", "effective_px"].indexOf(manifest.units) < 0)
      return { ok: false, error: "unsupported ui_manifest units", elements: {} };
    var vp = manifest.viewport, minScale = Number(vp.scale_min), maxScale = Number(vp.scale_max);
    var minimumTouch = Math.max(44, Number(vp.minimum_touch) || 0);
    if (!(minScale > 0) || !(maxScale >= minScale) || !(minimumTouch >= 44))
      return { ok: false, error: "invalid ui_manifest viewport", elements: {} };

    var result = {}, ids = Object.keys(manifest.elements);
    if (!ids.length || ids.length > 64)
      return { ok: false, error: "invalid ui_manifest elements", elements: {} };
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i], desc = manifest.elements[id];
      if (!/^[A-Za-z0-9_.-]+$/.test(id) || !isObj(desc) ||
          !(desc.properties instanceof Array) || !isObj(desc.defaults) ||
          typeof desc.safety_critical !== "boolean")
        return { ok: false, error: "invalid ui_manifest element " + id, elements: {} };
      var allowed = {}, style = {}, overridden = {}, p;
      for (var pi = 0; pi < desc.properties.length; pi++) {
        p = desc.properties[pi];
        if (UI_PROPERTIES.indexOf(p) < 0 || allowed[p] || !own(desc.defaults, p))
          return { ok: false, error: "invalid ui_manifest property " + id, elements: {} };
        allowed[p] = true;
        style[p] = desc.defaults[p];
      }
      for (p in desc.defaults) if (own(desc.defaults, p) && !allowed[p])
        return { ok: false, error: "undeclared ui_manifest default " + id, elements: {} };
      var proposed = uiElementValue(overrides, id);
      if (proposed !== undefined && !isObj(proposed))
        return { ok: false, error: id + " override must be an object", elements: {} };
      if (isObj(proposed)) for (p in proposed) if (own(proposed, p)) {
        if (!allowed[p])
          return { ok: false, error: id + " uses unsupported property " + p, elements: {} };
        style[p] = proposed[p];
        overridden[p] = true;
      }
      for (p in style) if (own(style, p)) {
        var value = style[p];
        if (p === "scale" || p === "font_scale") {
          if (typeof value !== "number" || !isFinite(value) || value < minScale || value > maxScale)
            return { ok: false, error: id + "." + p + " is outside the viewport limit", elements: {} };
          if (desc.safety_critical && value < 1)
            return { ok: false, error: id + " safety controls cannot shrink", elements: {} };
        } else if (p === "radius") {
          if (typeof value !== "number" || !isFinite(value) || value < 0 || value > minimumTouch)
            return { ok: false, error: id + ".radius is invalid", elements: {} };
        } else if (!colorOk(value)) {
          return { ok: false, error: id + "." + p + " requires #RRGGBB", elements: {} };
        }
      }
      if (style.foreground && style.background && contrast(style.foreground, style.background) < 4.5)
        return { ok: false, error: id + " text contrast is below 4.5:1", elements: {} };
      if (style.accent && style.background && contrast(style.accent, style.background) < 3)
        return { ok: false, error: id + " accent contrast is below 3:1", elements: {} };
      if (style.border && style.background && contrast(style.border, style.background) < 3)
        return { ok: false, error: id + " border contrast is below 3:1", elements: {} };
      result[id] = { style: style, overridden: overridden, safety_critical: desc.safety_critical };
    }
    return { ok: true, error: "", elements: result, minimum_touch: minimumTouch,
             device_id: String((webUi && webUi.device_id) || "") };
  }

  var uiReportState = {};
  var uiReportBackoffMs = [1000, 2000, 5000, 10000, 30000];
  function attemptSemanticUiReport(state) {
    if (!root.XMLHttpRequest || !state.pending || state.inflight) return;
    var signature = state.pending;
    state.inflight = signature;
    var xhr = new root.XMLHttpRequest(), settled = false;
    function finish(ok) {
      if (settled) return;
      settled = true;
      state.inflight = "";
      if (ok) {
        state.acked = signature;
        state.attempts = 0;
        if (state.pending !== signature) attemptSemanticUiReport(state);
        return;
      }
      state.attempts = Math.min((state.attempts || 0) + 1, uiReportBackoffMs.length);
      if (state.timer || !root.setTimeout) return;
      var delay = uiReportBackoffMs[Math.max(0, state.attempts - 1)];
      state.timer = root.setTimeout(function () {
        state.timer = null;
        attemptSemanticUiReport(state);
      }, delay);
    }
    try {
      xhr.open("POST", "/api/panel/ui-report", true);
      xhr.setRequestHeader("Content-Type", "application/json");
      if (panelCsrf) xhr.setRequestHeader("X-Doorbell-CSRF", panelCsrf);
      xhr.onload = function () { finish(xhr.status >= 200 && xhr.status < 300); };
      xhr.onerror = function () { finish(false); };
      xhr.ontimeout = function () { finish(false); };
      xhr.send(signature);
    } catch (e) { finish(false); }
  }
  function sendSemanticUiReport(report) {
    if (!root.XMLHttpRequest) return;
    var signature = JSON.stringify(report);
    var state = uiReportState[report.page] ||
                (uiReportState[report.page] = { acked: "", pending: "", inflight: "",
                                                attempts: 0, timer: null });
    if (state.acked === signature) return;
    state.pending = signature;
    if (!state.timer) attemptSemanticUiReport(state);
  }

  function storageKey(deviceId, page) {
    return "doorbell.semantic-ui.v2." + String(deviceId || "unknown") + "." + page;
  }
  function applySemanticUi(state, options) {
    options = options || {};
    var page = /^(door|monitor|call)$/.test(options.page) ? options.page : "monitor";
    var webUi = state && state.web_ui;
    if (!webUi) return { available: false, applied: false, rejected: false };
    var model = semanticUiModel(webUi), rejected = !model.ok, lkgUsed = false;
    var lkgPersisted = false, storage = root.localStorage;
    var key = storageKey(webUi.device_id, page);
    if (!model.ok && storage) {
      try {
        var cached = JSON.parse(storage.getItem(key) || "null");
        if (cached && isObj(cached.elements)) {
          var lkg = semanticUiModel({ manifest: webUi.manifest, elements: cached.elements,
                                      device_id: webUi.device_id });
          if (lkg.ok) { model = lkg; lkgUsed = true; }
        }
      } catch (e) { /* Invalid cache is ignored and never applied. */ }
    }
    if (!model.ok) {
      var defaults = semanticUiModel({ manifest: webUi.manifest, elements: {},
                                       device_id: webUi.device_id });
      if (defaults.ok) model = defaults;
    }

    var appliedIds = [], doc = root.document;
    if (model.ok && doc && doc.querySelectorAll) {
      var nodes = doc.querySelectorAll("[data-semantic-id]");
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i], id = el.getAttribute("data-semantic-id"), entry = model.elements[id];
        if (!entry) continue;
        var style = entry.style, computed = root.getComputedStyle ? root.getComputedStyle(el) : null;
        var baseFont = Number(el.getAttribute("data-db-base-font-size"));
        if (!(baseFont > 0)) {
          baseFont = computed ? parseFloat(computed.fontSize) : 16;
          if (!(baseFont > 0)) baseFont = 16;
          el.setAttribute("data-db-base-font-size", String(baseFont));
        }
        if (!el.hasAttribute("data-db-base-transform"))
          el.setAttribute("data-db-base-transform", (computed && computed.transform !== "none") ?
                          computed.transform : "");
        // Manifest defaults describe the element; the page stylesheet already draws them in the
        // current light or dark appearance. Only what an administrator overrode is painted. A
        // color override paints the whole validated color set, because its contrast was checked
        // against the manifest colors and not against the page's.
        var set = entry.overridden || {};
        var colors = !!(set.foreground || set.background || set.accent || set.border);
        el.style.fontSize = set.font_scale ? (baseFont * style.font_scale) + "px" : "";
        el.style.color = colors && style.foreground ? style.foreground : "";
        el.style.backgroundColor = colors && style.background ? style.background : "";
        el.style.outlineColor = colors && style.accent ? style.accent : "";
        if (el.style.setProperty) {
          if (colors && style.accent) el.style.setProperty("--db-semantic-accent", style.accent);
          else if (el.style.removeProperty) el.style.removeProperty("--db-semantic-accent");
        }
        if (colors && style.border) {
          el.style.borderColor = style.border;
          if (!computed || parseFloat(computed.borderWidth) === 0) el.style.borderWidth = "2px";
          el.style.borderStyle = "solid";
        } else {
          el.style.borderColor = ""; el.style.borderWidth = ""; el.style.borderStyle = "";
        }
        el.style.borderRadius = set.radius ? style.radius + "px" : "";
        var scale = style.scale === undefined ? 1 : style.scale;
        var baseTransform = el.getAttribute("data-db-base-transform") || "";
        el.style.transform = baseTransform + (scale === 1 ? "" : " scale(" + scale + ")");
        el.style.transformOrigin = "center";
        var tag = String(el.tagName || "").toUpperCase();
        if (entry.safety_critical || /^(BUTTON|A|INPUT)$/.test(tag)) {
          // The floor never lowers a larger minimum the stylesheet asks for (visitor targets).
          var floor = model.minimum_touch / scale;
          el.style.minWidth = ""; el.style.minHeight = "";
          var sized = root.getComputedStyle ? root.getComputedStyle(el) : null;
          if (!sized || !(parseFloat(sized.minWidth) >= floor)) el.style.minWidth = floor + "px";
          if (!sized || !(parseFloat(sized.minHeight) >= floor)) el.style.minHeight = floor + "px";
        }
        if (appliedIds.indexOf(id) < 0) appliedIds.push(id);
      }

      // A full-screen SOS presentation is not a control and must not be transformed like one.
      // It consumes the same constrained sos.trigger palette and typography as the always-visible
      // hold button. Rule-projected colors temporarily take precedence; these values remain the
      // safe raw-SOS/default palette and are restored when a rule TTL expires.
      var presentations = doc.querySelectorAll("[data-semantic-presentation-id]");
      for (var j = 0; j < presentations.length; j++) {
        var presentationEl = presentations[j];
        var presentationId = presentationEl.getAttribute("data-semantic-presentation-id");
        var presentationEntry = model.elements[presentationId];
        if (!presentationEntry) continue;
        var presentationStyle = presentationEntry.style;
        if (presentationStyle.foreground)
          presentationEl.setAttribute("data-db-sos-foreground", presentationStyle.foreground);
        if (presentationStyle.background)
          presentationEl.setAttribute("data-db-sos-background", presentationStyle.background);
        if (presentationStyle.accent)
          presentationEl.setAttribute("data-db-sos-accent", presentationStyle.accent);
        if (presentationEl.getAttribute("data-db-sos-mode") !== "rule") {
          if (presentationStyle.foreground) presentationEl.style.color = presentationStyle.foreground;
          if (presentationStyle.background)
            presentationEl.style.backgroundColor = presentationStyle.background;
          var headings = presentationEl.getElementsByTagName("h2");
          if (headings.length && presentationStyle.accent)
            headings[0].style.color = presentationStyle.accent;
        }
        var inners = presentationEl.getElementsByClassName ?
          presentationEl.getElementsByClassName("dbEmergencyInner") : [];
        if (inners.length) {
          var inner = inners[0], innerScale = presentationStyle.scale === undefined ?
            1 : presentationStyle.scale;
          inner.style.transform = innerScale === 1 ? "" : "scale(" + innerScale + ")";
          inner.style.transformOrigin = "center top";
          if (presentationStyle.border) {
            inner.style.border = "2px solid " + presentationStyle.border;
            inner.style.padding = "12px";
          }
          if (presentationStyle.radius !== undefined)
            inner.style.borderRadius = presentationStyle.radius + "px";
          var fontScale = presentationStyle.font_scale === undefined ?
            1 : presentationStyle.font_scale;
          var sosHeadings = inner.getElementsByTagName("h2"), sosParagraphs = inner.getElementsByTagName("p");
          if (sosHeadings.length) sosHeadings[0].style.fontSize = (64 * fontScale) + "px";
          for (var spi = 0; spi < sosParagraphs.length; spi++)
            sosParagraphs[spi].style.fontSize = (26 * fontScale) + "px";
        }
        if (appliedIds.indexOf(presentationId) < 0) appliedIds.push(presentationId);
      }
    }

    if (model.ok && !rejected && storage) {
      var effective = {};
      for (var id in model.elements) if (own(model.elements, id)) {
        var kept = {}, source = model.elements[id];
        for (var prop in source.overridden) if (own(source.overridden, prop)) kept[prop] = source.style[prop];
        effective[id] = kept;
      }
      try {
        storage.setItem(key, JSON.stringify({ schema_version: 1, elements: effective }));
        lkgPersisted = true;
      } catch (e2) { lkgPersisted = false; }
    }
    var report = { schema_version: 1, page: page, device_id: String(webUi.device_id || ""),
                   applied: !!model.ok, rejected: rejected, lkg_used: lkgUsed,
                   lkg_persisted: lkgPersisted, last_error: rejected ?
                     String((semanticUiModel(webUi).error || "invalid semantic UI")).slice(0, 256) : "",
                   elements: appliedIds.sort() };
    sendSemanticUiReport(report);
    return report;
  }

  // SOS confirmation: tapping the compact SOS control only opens a dialog; the alert is sent
  // after its slide control has been dragged end to end. There is no press-and-hold anywhere,
  // because an accidental touch can also be a long one.
  var SOS_CONFIRM_TIMEOUT_MS = 10000, SOS_SLIDE_ARM = 0.9;
  // Fraction of the track travelled, 0..1. travel is the track width minus the thumb width.
  function sosSlideProgress(startX, currentX, travel) {
    travel = Number(travel);
    if (!(travel > 0)) return 0;
    var moved = (Number(currentX) - Number(startX)) / travel;
    return isFinite(moved) ? Math.max(0, Math.min(1, moved)) : 0;
  }
  function sosSlideArmed(progress) { return Number(progress) >= SOS_SLIDE_ARM; }
  // emergency.trigger.countdown_s from panel state: whole seconds 0..10. Anything else, or a
  // Core that does not publish it yet, falls back to the configured default of 3.
  function sosCountdownSeconds(state) {
    var trigger = state && isObj(state.emergency) ? state.emergency.trigger : null;
    var value = isObj(trigger) ? trigger.countdown_s : undefined;
    return typeof value === "number" && value >= 0 && value <= 10 && Math.floor(value) === value ? value : 3;
  }

  function orderedHlc(value) {
    value = typeof value === "string" ? value : "";
    return /^[0-9a-f]{12}-[0-9a-f]{4}-[0-9a-f]{1,8}$/.test(value) ? value : "";
  }

  function withEventHlc(state, value) {
    value = orderedHlc(value);
    if (value) state.event_hlc = value;
    return state;
  }

  function emergencyState(state) {
    state = state || {};
    var e = state.emergency;
    var alert = state.device_alert;

    // Evaluate an enabled replicated SOS before the rule projection. A stale or negative
    // decoration must never hide an active safety state.
    if (e === true || (isObj(e) && e.active === true && e.web_active_page_alerts !== false) ||
        state.emergency_active === true) {
      return withEventHlc({ known: true, active: true, source: "state",
                            device: (isObj(e) && e.device) || "",
                            wall_ms: (isObj(e) && Number(e.wall_ms)) || 0 },
                          isObj(e) && (e.hlc || e.event_hlc));
    }
    if (isObj(alert) && typeof alert.active === "boolean") {
      return withEventHlc({ known: true, active: alert.active, source: "device_alert",
                            device: alert.device || "", wall_ms: Number(alert.wall_ms) || 0 },
                          alert.event_hlc || alert.hlc);
    }
    if (isObj(e) && e.web_active_page_alerts === false) {
      return withEventHlc({ known: true, active: false, source: "web_disabled",
                            device: e.device || "", wall_ms: Number(e.wall_ms) || 0 },
                          e.hlc || e.event_hlc);
    }
    if (typeof e === "boolean") return { known: true, active: e, source: "state" };
    if (isObj(e) && typeof e.active === "boolean") {
      return withEventHlc({ known: true, active: e.active, source: "state",
                            device: e.device || "", wall_ms: Number(e.wall_ms) || 0 },
                          e.hlc || e.event_hlc);
    }
    if (typeof state.emergency_active === "boolean")
      return { known: true, active: state.emergency_active, source: "legacy_state" };
    var events = state.events || [], newest = null;
    for (var i = 0; i < events.length; i++) {
      var ev = events[i] || {};
      if (ev.type !== "emergency" && ev.type !== "emergency_cancel") continue;
      if (!newest || (Number(ev.wall_ms) || 0) > (Number(newest.wall_ms) || 0)) newest = ev;
    }
    if (newest) return withEventHlc({ known: true, active: newest.type === "emergency",
                                      source: "events", device: newest.device || "",
                                      wall_ms: Number(newest.wall_ms) || 0 }, newest.hlc);
    return { known: false, active: false, source: "none" };
  }

  function emergencyPresentation(state, current) {
    state = state || {};
    var emergency = state.emergency, alert = state.device_alert;
    var rawEnabled = emergency === true || (isObj(emergency) && emergency.active === true &&
                     emergency.web_active_page_alerts !== false) ||
                     state.emergency_active === true;
    var source = isObj(alert) && alert.active === true && isObj(alert.presentation) ?
                 alert.presentation : {};
    var volume = Number(source.volume);
    if (!isFinite(volume)) volume = 100;
    volume = Math.max(0, Math.min(100, volume));
    var ttl = Number(source.ttl_s);
    if (!isFinite(ttl)) ttl = 0;
    ttl = Math.max(0, Math.min(86400, ttl));
    var sound = typeof source.sound === "string" ? source.sound.slice(0, 128) : "";
    var background = colorOk(source.background) ? source.background : "#8F1010";
    var foreground = colorOk(source.foreground) ? source.foreground : "#FFFFFF";
    var accent = colorOk(source.accent) ? source.accent : "#FFD166";
    if (contrast(foreground, background) < 4.5) {
      background = "#8F1010";
      foreground = "#FFFFFF";
    }
    if (contrast(accent, background) < 3) accent = "#FFD166";
    var key = (isObj(alert) && (alert.event_hlc || alert.wall_ms)) ||
              (isObj(emergency) && (emergency.hlc || emergency.wall_ms)) ||
              ((current && current.wall_ms) || 0);
    var customColors = own(source, "background") || own(source, "foreground") ||
                       own(source, "accent");
    return { visual: rawEnabled || source.visual !== false, sound: sound, volume: volume,
             sticky: source.sticky === true, ttl_s: ttl, background: background,
             foreground: foreground, accent: accent, raw_active: rawEnabled,
             custom_colors: customColors,
             key: String(key || "emergency") };
  }

  function activePage(state, fallback) {
    if (emergencyState(state).active) return "emergency";
    var p = state && state.active_page;
    if (isObj(p)) p = p.page || p.id;
    p = String(p || "");
    return /^(door|monitor|call)$/.test(p) ? p : (fallback || "monitor");
  }

  function panelUrl(page, token, mock, door) {
    page = /^(door|monitor|call)$/.test(page) ? page : "monitor";
    var query = [];
    if (door) query.push("door=" + encodeURIComponent(door));
    if (mock) query.push("mock=1");
    var group = webGroup();
    if (group !== "all") query.push("group=" + encodeURIComponent(group));
    return "/panel/" + page + (query.length ? "?" + query.join("&") : "") +
           (token ? "#k=" + encodeURIComponent(token) : "");
  }

  function webGroup() {
    var search = String((root.location && root.location.search) || "");
    var match = search.match(/[?&]group=([^&]*)/), group = "";
    if (match) {
      try { group = decodeURIComponent(match[1].replace(/\+/g, "%20")); } catch (e) { group = ""; }
    }
    var storage = root.localStorage;
    if (!group && storage) {
      try { group = storage.getItem("doorbell.web-push-group.v1") || ""; } catch (e2) { group = ""; }
    }
    if (!/^[A-Za-z0-9_.:-]{1,64}$/.test(group)) group = "all";
    if (match && storage) {
      try { storage.setItem("doorbell.web-push-group.v1", group); } catch (e3) {}
    }
    return group;
  }

  function panelStateUrl() {
    var group = webGroup();
    return "/api/panel/state" + (group === "all" ? "" : "?group=" + encodeURIComponent(group));
  }

  function pushTargetsGroup(payload, group) {
    payload = payload || {};
    group = group || webGroup();
    var groups = payload.web_subscription_groups;
    if (groups === undefined) groups = payload.web_profiles;
    if (groups === undefined || groups === null) return true; // Legacy all-Web delivery.
    if (typeof groups === "string") return groups === "all" || groups === group;
    if (!(groups instanceof Array)) return false;
    for (var i = 0; i < groups.length; i++)
      if (groups[i] === "all" || groups[i] === group) return true;
    return false;
  }

  function locationCredential() {
    var loc = root.location || {}, source = String(loc.hash || "");
    var match = source.match(/(?:^#|[&#])k=([^&]*)/);
    if (!match) match = String(loc.search || "").match(/[?&]k=([^&]*)/); // upgrade bridge
    return match ? decodeURIComponent(match[1].replace(/\+/g, "%20")) : "";
  }

  function stripCredentialLocation() {
    if (!(root.history && root.history.replaceState && root.location)) return;
    var search = String(root.location.search || "")
      .replace(/([?&])k=[^&]*&?/g, "$1").replace(/[?&]$/, "");
    var hash = String(root.location.hash || "")
      .replace(/([#&])k=[^&]*&?/g, "$1").replace(/[#&]$/, "");
    root.history.replaceState(null, "", root.location.pathname + search + hash);
  }

  // Core requires X-Doorbell-CSRF on every mutation of a cookie-backed panel session. The token
  // is learned from /api/panel/session (POST on sign-in, GET for an existing session) and is
  // shared by every page helper so no mutation path can forget it.
  var panelCsrf = "";
  function rememberPanelCsrf(token) {
    panelCsrf = /^[0-9a-f]{32}$/i.test(String(token || "")) ? String(token) : "";
    return panelCsrf;
  }
  function panelCsrfToken() { return panelCsrf; }

  function parseJson(text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (ignored) { return null; }
  }

  function rawPanelRequest(method, path, body, headers, cb) {
    var xhr;
    try {
      xhr = new root.XMLHttpRequest();
      xhr.open(method, path, true);
      for (var name in headers) if (own(headers, name)) xhr.setRequestHeader(name, headers[name]);
    } catch (error) { cb(0, null); return; }
    var done = false;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4 || done) return;
      done = true;
      cb(xhr.status, parseJson(xhr.responseText));
    };
    try { xhr.send(body === undefined ? null : body); }
    catch (sendError) { if (!done) { done = true; cb(0, null); } }
  }

  function refreshPanelCsrf(cb) {
    rawPanelRequest("GET", "/api/panel/session", null, {}, function (status, json) {
      rememberPanelCsrf(status === 200 && json ? json.csrf_token : "");
      cb(panelCsrf);
    });
  }

  // panelRequest(method, path, body, cb): body is a form string, a JSON-able object, or null.
  // A mutation is sent with the session CSRF token. A 403 is retried once with a fresh token:
  // Core rejects a missing or stale token before the mutation executes, so the retry cannot
  // duplicate an effect.
  function panelRequest(method, path, body, cb) {
    method = String(method || "GET").toUpperCase();
    cb = cb || function () {};
    var headers = {}, payload = null;
    if (typeof body === "string") {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      payload = body;
    } else if (body !== null && body !== undefined) {
      headers["Content-Type"] = "application/json";
      payload = JSON.stringify(body);
    }
    if (method === "GET" || method === "HEAD") {
      rawPanelRequest(method, path, payload, headers, cb);
      return;
    }
    function send(retried) {
      var sendHeaders = {};
      for (var name in headers) if (own(headers, name)) sendHeaders[name] = headers[name];
      if (panelCsrf) sendHeaders["X-Doorbell-CSRF"] = panelCsrf;
      rawPanelRequest(method, path, payload, sendHeaders, function (status, json) {
        if (status === 403 && !retried) {
          refreshPanelCsrf(function (token) {
            if (token) send(true); else cb(status, json);
          });
          return;
        }
        cb(status, json);
      });
    }
    if (panelCsrf) send(false);
    else refreshPanelCsrf(function () { send(true); });
  }

  function establishSession(cb, explicitCredential) {
    var credential = explicitCredential || locationCredential();
    if (!credential) {
      refreshPanelCsrf(function () { cb({ ok: true, existing: true }); });
      return;
    }
    rawPanelRequest("POST", "/api/panel/session", JSON.stringify({ credential: credential }),
      { "Content-Type": "application/json" }, function (status, json) {
        var ok = status === 200;
        if (ok) {
          stripCredentialLocation();
          rememberPanelCsrf(json && json.csrf_token);
        }
        cb({ ok: ok, status: status, credential: ok ? credential : "" });
      });
  }

  function createSosOperationController(onChange) {
    var state = { phase: "idle", busy: false, error_code: "", status: 0 };
    var intent = null, csrf = "", action = "prepare", request = null, generation = 0;
    var storageKey = "doorbell.sos.operation.v2";
    try {
      var saved = root.sessionStorage && root.sessionStorage.getItem(storageKey);
      var remembered = saved && saved.length <= 1024 ? JSON.parse(saved) : null;
      if (remembered && remembered.schema_version === 2 && remembered.action === "sos_start" &&
          /^[a-f0-9]{32}$/.test(remembered.operation_id || "") &&
          /^[a-f0-9]{32}$/.test(remembered.authority_node || "")) {
        intent = { operation_id: remembered.operation_id, authority_node: remembered.authority_node };
        action = "query";
        state.phase = "unknown";
      }
    } catch (ignored) {}
    function remember() {
      // An operation ID is not authority. Core still checks the live session on every lookup.
      try {
        if (!root.sessionStorage) return;
        if (intent) root.sessionStorage.setItem(storageKey, JSON.stringify({ schema_version: 2,
          action: "sos_start", operation_id: intent.operation_id, authority_node: intent.authority_node }));
        else root.sessionStorage.removeItem(storageKey);
      } catch (ignored) {}
    }
    function snapshot() {
      return { phase: state.phase, busy: state.busy, error_code: state.error_code,
        status: state.status, operation_id: intent ? intent.operation_id : "",
        authority_node: intent ? intent.authority_node : "", action: action };
    }
    function publish(phase, result) {
      state = { phase: phase, busy: phase === "preparing" || phase === "sending" || phase === "querying",
        error_code: result && result.error_code || "", status: result && result.status || 0 };
      remember();
      if (onChange) onChange(snapshot());
    }
    function send(method, url, body, done) {
      var mine = ++generation;
      var handle = requestWithDeadline({ method: method, url: url, deadline_ms: 4000,
        headers: { "Content-Type": "application/json", "X-Doorbell-CSRF": csrf },
        body: body === null ? undefined : JSON.stringify(body) }, function (result) {
        if (mine !== generation) return;
        request = null;
        done(result);
      });
      if (mine === generation && handle.pending()) request = handle;
    }
    function refused(result) {
      return result.status === 400 || result.status === 401 || result.status === 403 ||
        result.error_code === "config_conflict" || result.error_code === "idempotency_conflict";
    }
    function fail(result, querying) {
      if (result.status === 401 || result.status === 403) csrf = "";
      // After an ambiguous execute, a denied or failed query cannot prove the SOS never ran.
      publish(result.error_code === "not_started" && !querying ? "not_started"
        : !querying && refused(result) ? "rejected" : "unknown", result);
    }
    function withCsrf(done, querying) {
      if (csrf) { done(); return; }
      send("GET", "/api/panel/session", null, function (result) {
        if (!result.ok || !result.data || !/^[a-f0-9]{32}$/.test(result.data.csrf_token || "")) {
          fail(result, querying); return;
        }
        csrf = result.data.csrf_token;
        done();
      });
    }
    function validRecord(data) {
      return data && data.schema_version === 2 && data.ok === true &&
        /^[a-f0-9]{32}$/.test(data.operation_id || "") &&
        /^[a-f0-9]{32}$/.test(data.authority_node || "") &&
        (!intent || data.operation_id === intent.operation_id && data.authority_node === intent.authority_node);
    }
    function applyResult(result, querying) {
      if (!result.ok || !validRecord(result.data)) { fail(result, querying); return; }
      var execution = result.data.execution_state;
      action = "query";
      if (execution === "prepared") {
        action = "execute";
        publish("not_started", result);
      } else if (execution === "accepted" || execution === "dispatching" || execution === "dispatched" || execution === "actuator_ack") {
        publish("accepted", result);
      } else if (execution === "rejected_not_started" || execution === "expired_not_started" || execution === "failed_before_dispatch") {
        action = "prepare";
        publish("not_started", result);
      } else publish("unknown", result);
    }
    function execute() {
      publish("sending");
      action = "query";
      withCsrf(function () {
        send("POST", "/api/operations/" + intent.operation_id + "/execute", {
          schema_version: 2, action: "sos_start", parameters: {},
          operation_id: intent.operation_id, authority_node: intent.authority_node
        }, function (result) { applyResult(result, false); });
      }, false);
    }
    function prepare() {
      intent = null;
      action = "prepare";
      publish("preparing");
      withCsrf(function () {
        send("POST", "/api/operations/prepare", { schema_version: 2, action: "sos_start", parameters: {} }, function (result) {
          var data = result.data;
          if (!result.ok || !validRecord(data) || data.execution_state !== "prepared") {
            fail(result, false); return;
          }
          intent = { operation_id: data.operation_id, authority_node: data.authority_node };
          execute();
        });
      }, false);
    }
    function query() {
      publish("querying");
      withCsrf(function () {
        send("GET", "/api/operations/" + intent.operation_id + "?authority_node=" +
          intent.authority_node + "&action=sos_start", null,
          function (result) { applyResult(result, true); });
      }, true);
    }
    return {
      state: snapshot,
      start: function () {
        if (state.busy) return false;
        if (!intent || action === "prepare") prepare();
        else if (action === "execute") execute();
        else query();
        return true;
      },
      retire: function () { if (request) request.cancel(); },
      clearAccepted: function () {
        if (state.busy || state.phase !== "accepted") return;
        intent = null; action = "prepare"; publish("idle");
      }
    };
  }

  function installEmergencyOverlay(options) {
    options = options || {};
    var doc = root.document, overlay = null, title = null, detail = null;
    var trigger = null, triggerLabel = null, sosWhen = null;
    var confirmBox = null, confirmScrim = null, confirmTitle = null, confirmText = null;
    var slideTrack = null, slideThumb = null, slideLabel = null, confirmCancel = null, confirmSend = null;
    var confirmTimer = null, confirmOpen = false, slide = null, confirmReturnFocus = null;
    var countdownBox = null, countdownText = null, countdownCancel = null;
    var countdownSeconds = 3, countdownLeft = 0, countdownTimer = null;
    var current = { known: false, active: false, source: "none" };
    var expiryTimer = null, expiryKey = "", expired = {}, alarm = null;
    var operationBox = null, operationText = null, operationReason = null, operationHelp = null;
    var operationAction = null, operation = null;
    if (doc && doc.body) {
      var style = doc.createElement("style");
      style.type = "text/css";
      style.appendChild(doc.createTextNode(
        ".dbEmergencyOverlay{display:none;position:fixed;left:0;top:0;width:100%;height:100%;" +
        "z-index:2147483646;background:#8f1010;color:#fff;text-align:center;}" +
        ".dbEmergencyOverlay .dbEmergencyInner{position:absolute;left:5%;right:5%;top:18%;}" +
        ".dbEmergencyOverlay h2{font-size:64px;line-height:1.2;margin:0 0 24px;}" +
        ".dbEmergencyOverlay p{font-size:26px;line-height:1.5;margin:8px;}" +
        ".dbEmergencyOverlay .dbSosWhen{font-size:22px;opacity:.9;margin:16px 0 0;}" +
        ".dbSosTrigger{position:fixed;right:18px;bottom:18px;z-index:2147483645;" +
        "min-width:64px;min-height:44px;padding:8px 14px;border:2px solid #ff8e8e;border-radius:10px;" +
        "background:transparent;color:#ff8e8e;font-weight:bold;line-height:1.1;}" +
        ".dbSosTrigger .dbSosLabel{font-size:16px;}" +
        ".dbSosTrigger:disabled{opacity:.6;}" +
        ".dbSosScrim{display:none;position:fixed;left:0;top:0;right:0;bottom:0;z-index:2147483640;" +
        "background:rgba(0,0,0,.6);}" +
        ".dbSosConfirm{display:none;position:fixed;left:0;right:0;bottom:0;z-index:2147483641;" +
        "padding:20px 16px 16px;border-radius:20px 20px 0 0;background:#1a2027;color:#e8edf2;" +
        "text-align:left;-webkit-box-sizing:border-box;box-sizing:border-box;}" +
        ".dbSosConfirm h2{font-size:22px;line-height:1.25;margin:0 0 8px;}" +
        ".dbSosConfirm p{font-size:16px;line-height:1.4;margin:0 0 16px;}" +
        ".dbSosSlide{position:relative;height:64px;margin:0 0 12px;border-radius:32px;overflow:hidden;" +
        "background:#3a1512;border:2px solid #b3261e;-webkit-user-select:none;user-select:none;" +
        "touch-action:none;}" +
        ".dbSosSlideLabel{position:absolute;left:68px;right:16px;top:0;line-height:60px;text-align:center;" +
        "font-size:17px;font-weight:bold;color:#ffb4ab;white-space:nowrap;overflow:hidden;" +
        "text-overflow:ellipsis;}" +
        ".dbSosThumb{position:absolute;left:0;top:0;width:60px;height:60px;border-radius:30px;" +
        "background:#b3261e;color:#fff;text-align:center;line-height:60px;font-size:26px;font-weight:bold;}" +
        ".dbSosConfirm button{display:block;width:100%;min-height:48px;margin:8px 0 0;padding:10px 16px;" +
        "font-size:17px;border-radius:12px;}" +
        ".dbSosConfirm .dbSosSend{background:transparent;border:2px solid #ff8e8e;color:#ff8e8e;" +
        "font-weight:bold;}" +
        "@media (min-width:900px){.dbSosConfirm{left:50%;right:auto;bottom:auto;top:30%;width:440px;" +
        "margin-left:-220px;border-radius:20px;}}" +
        ".dbSosCountdown{display:none;position:fixed;left:0;top:0;width:100%;height:100%;" +
        "z-index:2147483644;background:#8f1010;color:#fff;text-align:center;}" +
        ".dbSosCountdown .dbSosCountdownInner{position:absolute;left:5%;right:5%;top:22%;}" +
        ".dbSosCountdown p{font-size:32px;font-weight:bold;line-height:1.3;margin:0 0 32px;}" +
        ".dbSosCountdown button{min-width:240px;min-height:88px;padding:16px 32px;font-size:28px;" +
        "font-weight:bold;border:0;border-radius:18px;background:#fff;color:#8f1010;}" +
        ".dbSosOperation{display:none;position:fixed;right:18px;bottom:118px;z-index:2147483647;" +
        "width:320px;max-width:90%;max-height:60%;overflow:auto;padding:16px;box-sizing:border-box;" +
        "border:2px solid #8f1010;border-radius:12px;background:#fff;color:#20242a;text-align:left;}" +
        ".dbSosOperation p{font-size:16px;line-height:1.4;margin:0 0 10px;}" +
        ".dbSosOperation .dbSosOperationHelp{font-size:13px;}" +
        ".dbSosOperation button{min-height:44px;width:100%;padding:8px;border:0;border-radius:8px;" +
        "font-size:16px;background:#8f1010;color:#fff;}"));
      (doc.head || doc.body).appendChild(style);
      overlay = doc.createElement("div");
      overlay.className = "dbEmergencyOverlay";
      overlay.setAttribute("data-semantic-presentation-id", "sos.trigger");
      overlay.setAttribute("data-db-sos-mode", "semantic");
      overlay.setAttribute("role", "alert");
      overlay.setAttribute("aria-live", "assertive");
      overlay.innerHTML = "<div class='dbEmergencyInner'><h2></h2><p></p><p></p></div>";
      title = overlay.getElementsByTagName("h2")[0];
      detail = overlay.getElementsByTagName("p")[0];
      var clearInstruction = overlay.getElementsByTagName("p")[1];
      title.appendChild(doc.createTextNode(options.title || "SOS"));
      detail.appendChild(doc.createTextNode(options.detail || ""));
      clearInstruction.appendChild(doc.createTextNode(options.clearInstruction || ""));
      // Source and time of the active SOS (UI guidelines: SOS overlay).
      sosWhen = doc.createElement("div");
      sosWhen.className = "dbSosWhen";
      (overlay.firstChild || overlay).appendChild(sosWhen);
      doc.body.appendChild(overlay);

      trigger = doc.createElement("button");
      trigger.type = "button";
      trigger.className = "dbSosTrigger";
      trigger.setAttribute("data-semantic-id", "sos.trigger");
      trigger.setAttribute("aria-label", options.triggerLabel || "SOS");
      trigger.setAttribute("aria-haspopup", "dialog");
      if (options.triggerIcon) trigger.appendChild(options.triggerIcon);
      triggerLabel = doc.createElement("span");
      triggerLabel.className = "dbSosLabel";
      triggerLabel.appendChild(doc.createTextNode(options.triggerLabel || "SOS"));
      trigger.appendChild(triggerLabel);
      doc.body.appendChild(trigger);

      confirmScrim = doc.createElement("div");
      confirmScrim.className = "dbSosScrim";
      confirmBox = doc.createElement("div");
      confirmBox.className = "dbSosConfirm";
      confirmBox.setAttribute("role", "dialog");
      confirmBox.setAttribute("aria-modal", "true");
      confirmTitle = doc.createElement("h2");
      confirmText = doc.createElement("p");
      slideTrack = doc.createElement("div");
      slideTrack.className = "dbSosSlide";
      slideLabel = doc.createElement("span");
      slideLabel.className = "dbSosSlideLabel";
      slideThumb = doc.createElement("div");
      slideThumb.className = "dbSosThumb";
      slideThumb.setAttribute("aria-hidden", "true");
      slideThumb.appendChild(doc.createTextNode("\u203A"));
      slideTrack.appendChild(slideLabel);
      slideTrack.appendChild(slideThumb);
      confirmCancel = doc.createElement("button");
      confirmCancel.type = "button";
      confirmCancel.className = "dbSosCancel";
      // For keyboards and screen readers, where a drag is not possible. Never the default focus.
      confirmSend = doc.createElement("button");
      confirmSend.type = "button";
      confirmSend.className = "dbSosSend";
      confirmBox.appendChild(confirmTitle);
      confirmBox.appendChild(confirmText);
      confirmBox.appendChild(slideTrack);
      confirmBox.appendChild(confirmCancel);
      confirmBox.appendChild(confirmSend);
      doc.body.appendChild(confirmScrim);
      doc.body.appendChild(confirmBox);

      // The cancellable countdown after the slide: one large Cancel, nothing is sent before zero.
      countdownBox = doc.createElement("div");
      countdownBox.className = "dbSosCountdown";
      countdownBox.setAttribute("role", "alertdialog");
      countdownBox.setAttribute("aria-modal", "true");
      var countdownInner = doc.createElement("div");
      countdownInner.className = "dbSosCountdownInner";
      countdownText = doc.createElement("p");
      countdownText.setAttribute("aria-live", "assertive");
      countdownCancel = doc.createElement("button");
      countdownCancel.type = "button";
      countdownCancel.className = "dbSosCountdownCancel";
      countdownCancel.setAttribute("data-semantic-id", "sos.cancel");
      countdownInner.appendChild(countdownText);
      countdownInner.appendChild(countdownCancel);
      countdownBox.appendChild(countdownInner);
      doc.body.appendChild(countdownBox);
      operationBox = doc.createElement("div");
      operationBox.className = "dbSosOperation";
      operationBox.setAttribute("role", "status");
      operationBox.setAttribute("aria-live", "polite");
      operationText = doc.createElement("p");
      operationReason = doc.createElement("p");
      operationHelp = doc.createElement("p");
      operationHelp.className = "dbSosOperationHelp";
      operationAction = doc.createElement("button");
      operationAction.type = "button";
      operationAction.className = "dbSosOperationAction";
      operationBox.appendChild(operationText);
      operationBox.appendChild(operationReason);
      operationBox.appendChild(operationHelp);
      operationBox.appendChild(operationAction);
      doc.body.appendChild(operationBox);
    }

    function semanticColor(name, fallback) {
      if (!overlay) return fallback;
      return overlay.getAttribute("data-db-sos-" + name) || fallback;
    }
    function paintPalette(presentation, rawFallback) {
      if (!overlay) return;
      var useRule = !rawFallback && presentation.custom_colors;
      overlay.setAttribute("data-db-sos-mode", useRule ? "rule" : "semantic");
      overlay.style.backgroundColor = useRule ? presentation.background :
        semanticColor("background", "#8F1010");
      overlay.style.color = useRule ? presentation.foreground :
        semanticColor("foreground", "#FFFFFF");
      if (title) title.style.color = useRule ? presentation.accent :
        semanticColor("accent", "#FFD166");
    }

    function stopAlarm() {
      if (!alarm) return;
      try { alarm.oscillator.stop(); } catch (e) {}
      try { alarm.oscillator.disconnect(); alarm.gain.disconnect(); } catch (e2) {}
      alarm = null;
    }
    function startAlarm(presentation) {
      var signature = presentation.key + "|" + presentation.sound + "|" + presentation.volume;
      if (alarm && alarm.signature === signature) return;
      stopAlarm();
      if (!presentation.sound || presentation.volume <= 0 || !root.AudioContext) return;
      try {
        var context = installEmergencyOverlay.audioContext ||
          (installEmergencyOverlay.audioContext = new root.AudioContext());
        if (context.resume) context.resume();
        var oscillator = context.createOscillator(), gain = context.createGain();
        oscillator.type = "square";
        oscillator.frequency.value = 880;
        gain.gain.value = Math.min(0.25, presentation.volume / 400);
        oscillator.connect(gain); gain.connect(context.destination); oscillator.start();
        alarm = { oscillator: oscillator, gain: gain, signature: signature };
      } catch (e) { alarm = null; }
    }
    function paint(next, presentation) {
      var wasActive = current.active;
      current = next || current;
      if (wasActive && current.known && !current.active && operation) operation.clearAccepted();
      presentation = presentation || { visual: true, sound: "", volume: 0,
                                        sticky: true, ttl_s: 0, key: "emergency" };
      var isExpired = !!expired[presentation.key];
      var shouldExpire = !!(current.active && !isExpired && !presentation.sticky &&
                            presentation.ttl_s > 0 && root.setTimeout);
      // Polling repeats the same rule projection every few seconds. Keep the original deadline
      // for that event instead of restarting its TTL on every identical state response.
      if (expiryTimer && (!shouldExpire || expiryKey !== presentation.key)) {
        root.clearTimeout(expiryTimer);
        expiryTimer = null;
        expiryKey = "";
      }
      var rawFallback = !!(current.active && presentation.raw_active && isExpired);
      current.presented = !!(current.active && (rawFallback || (presentation.visual && !isExpired)));
      current.presentation = presentation;
      if (overlay) {
        overlay.style.display = current.presented ? "block" : "none";
        paintPalette(presentation, rawFallback);
        if (sosWhen) {
          var parts = [];
          if (current.device) parts.push(String(current.device));
          if (current.wall_ms > 0) {
            var at = new Date(current.wall_ms);
            parts.push((at.getHours() < 10 ? "0" : "") + at.getHours() + ":" +
                       (at.getMinutes() < 10 ? "0" : "") + at.getMinutes());
          }
          sosWhen.textContent = current.active ? parts.join(" \u00B7 ") : "";
        }
      }
      if (trigger) trigger.disabled = current.active || !!(operation && operation.state().busy);
      if (current.active) { closeConfirm(); stopCountdown(); }
      if (current.active && !isExpired) startAlarm(presentation); else stopAlarm();
      if (shouldExpire && !expiryTimer) {
        expiryKey = presentation.key;
        expiryTimer = root.setTimeout(function () {
          expiryTimer = null;
          expiryKey = "";
          expired[presentation.key] = true;
          current.presented = !!presentation.raw_active;
          if (overlay) {
            overlay.style.display = current.presented ? "block" : "none";
            if (current.presented) paintPalette(presentation, true);
          }
          stopAlarm();
          if (options.onChange) options.onChange(current);
        }, presentation.ttl_s * 1000);
      }
      if (!current.active) { expired = {}; stopAlarm(); }
      if (options.onChange) options.onChange(current);
      return current;
    }
    function update(state) {
      if (state && isObj(state.emergency) && state.emergency.trigger !== undefined)
        countdownSeconds = sosCountdownSeconds(state);
      var next = emergencyState(state);
      // A poll from an older/lagging node may not know SOS state yet. Unknown must not erase a
      // push alarm; only explicit active:false or emergency_cancel may clear the safety overlay.
      if (!next.known && current.known) return current;
      // A newly delivered Push can outrun a lagging peer's panel projection. Only an equal/newer
      // HLC may replace ordered SOS state; an empty HLC is rolling-upgrade uncertainty, not clear.
      if (current.event_hlc &&
          (!next.event_hlc || next.event_hlc < current.event_hlc)) return current;
      // With raw Web handling disabled, a matching Web-Push-only rule has no in_app projection.
      // Keep that accepted Push until its own TTL or an explicit clear instead of allowing the
      // next raw-state poll to erase it merely because the administrator disabled raw fallback.
      if (current.active && current.source === "push" && next.source === "web_disabled" &&
          isObj(state && state.emergency) && state.emergency.active === true) return current;
      return paint(next, emergencyPresentation(state, next));
    }
    function onPush(payload) {
      payload = payload || {};
      var kind = payload.kind || payload.type;
      if (kind !== "emergency" && kind !== "emergency_cancel") return current;
      // A Service Worker is shared by every same-origin panel. The server filters the Push
      // subscription, and this second gate prevents that Push from decorating tabs that poll a
      // different Web subscription group.
      if (!pushTargetsGroup(payload)) return current;
      var next = { known: true, active: kind === "emergency" && payload.active !== false,
                   source: "push", device: payload.device || "",
                   wall_ms: Number(payload.wall_ms) || 0 };
      var pushHlc = orderedHlc(payload.event_hlc);
      if (pushHlc) next.event_hlc = pushHlc;
      if (current.event_hlc &&
          (!next.event_hlc || next.event_hlc < current.event_hlc ||
           (next.event_hlc === current.event_hlc && next.active !== current.active)))
        return current;
      return paint(next, emergencyPresentation({ device_alert: {
        active: next.active, event_hlc: payload.event_hlc, wall_ms: next.wall_ms,
        presentation: payload.presentation || {}
      } }, next));
    }

    function text(element, value) {
      if (!element) return;
      while (element.firstChild) element.removeChild(element.firstChild);
      element.appendChild(doc.createTextNode(value));
    }
    function translate(key, values) { return options.translate ? options.translate(key, values) : key; }
    function renderOperation(result) {
      var notifyResult = !!result;
      if (!result && operation) result = operation.state();
      if (!result) return;
      if (trigger) trigger.disabled = current.active || result.busy;
      if (operationBox) {
        operationBox.style.display = result.phase === "idle" ? "none" : "block";
        operationBox.setAttribute("data-operation-state", result.phase);
        text(operationText, translate("emergency.sos_" +
          (result.phase === "unknown" && !result.operation_id ? "prepare_unknown" : result.phase)));
        var reason = result.error_code === "auth_required" || result.status === 401 ? "auth_required"
          : result.error_code === "permission_denied" || result.status === 403 ? "permission_denied"
          : result.error_code === "invalid_request" || result.status === 400 ? "invalid"
          : result.error_code === "authority_unavailable" || result.status === 501 ? "unavailable" : "";
        operationReason.style.display = reason ? "block" : "none";
        text(operationReason, reason ? translate("emergency.sos_" + reason) : "");
        text(operationHelp, translate("emergency.sos_alternative"));
        text(operationAction, translate("emergency.sos_" + (result.action === "query" ? "query"
          : result.action === "execute" ? "send_same" : "retry")));
        operationAction.disabled = result.busy;
      }
      if (notifyResult && options.onTriggerResult)
        options.onTriggerResult(result.phase === "accepted", result.status, result);
    }
    operation = createSosOperationController(renderOperation);
    renderOperation(operation.state());
    function postEmergency() {
      if (current.active) return;
      operation.start();
    }
    if (operationAction && operationAction.addEventListener)
      operationAction.addEventListener("click", function () { operation.start(); }, false);
    if (root.addEventListener) root.addEventListener("pagehide", function () {
      closeConfirm(); stopCountdown(); operation.retire();
    }, false);

    function renderCountdown() {
      text(countdownText, translate("sos.countdown", { n: countdownLeft }));
      text(countdownCancel, translate("sos.cancel_countdown"));
    }
    function countdownRunning() { return countdownLeft > 0; }
    function stopCountdown() {
      if (countdownTimer !== null && root.clearTimeout) root.clearTimeout(countdownTimer);
      countdownTimer = null; countdownLeft = 0;
      if (countdownBox) countdownBox.style.display = "none";
    }
    function tickCountdown() {
      countdownTimer = null;
      if (!countdownRunning()) return;
      countdownLeft--;
      if (countdownLeft > 0) {
        renderCountdown();
        countdownTimer = root.setTimeout(tickCountdown, 1000);
        return;
      }
      stopCountdown();
      postEmergency();
    }
    // Zero seconds, or no timer to count with, sends at once.
    function startCountdown() {
      if (current.active || countdownRunning()) return;
      if (!(countdownSeconds > 0) || !countdownBox || !root.setTimeout) { postEmergency(); return; }
      countdownLeft = countdownSeconds;
      renderCountdown();
      countdownBox.style.display = "block";
      if (countdownCancel.focus) { try { countdownCancel.focus(); } catch (e) {} }
      countdownTimer = root.setTimeout(tickCountdown, 1000);
    }

    function renderConfirmText() {
      text(confirmTitle, translate("sos.confirm_title"));
      text(confirmText, translate("sos.hint"));
      text(slideLabel, translate("sos.slide_hint"));
      text(confirmCancel, translate("sos.abort"));
      text(confirmSend, translate("sos.send"));
    }
    function paintSlide(progress) {
      if (!slideThumb || !slideTrack) return;
      var travel = slideTravel();
      slideThumb.style.left = Math.round(progress * travel) + "px";
      if (slideLabel) slideLabel.style.opacity = String(1 - progress);
    }
    function slideTravel() {
      var track = slideTrack && slideTrack.clientWidth, thumb = slideThumb && slideThumb.offsetWidth;
      return Math.max(0, (Number(track) || 0) - (Number(thumb) || 0));
    }
    // Any input inside the dialog restarts the 10 s auto-close.
    function armConfirmTimeout() {
      if (confirmTimer !== null && root.clearTimeout) root.clearTimeout(confirmTimer);
      confirmTimer = confirmOpen && root.setTimeout ?
        root.setTimeout(function () { confirmTimer = null; closeConfirm(); }, SOS_CONFIRM_TIMEOUT_MS) : null;
    }
    function openConfirm() {
      if (!confirmBox || confirmOpen || current.active || (trigger && trigger.disabled) ||
          operation.state().busy || countdownRunning()) return false;
      confirmOpen = true; slide = null;
      renderConfirmText();
      confirmReturnFocus = trigger;
      confirmScrim.style.display = "block";
      confirmBox.style.display = "block";
      paintSlide(0);
      armConfirmTimeout();
      if (confirmCancel.focus) { try { confirmCancel.focus(); } catch (e) {} }
      return true;
    }
    function closeConfirm() {
      if (!confirmOpen) return;
      confirmOpen = false; slide = null;
      if (confirmTimer !== null && root.clearTimeout) root.clearTimeout(confirmTimer);
      confirmTimer = null;
      confirmScrim.style.display = "none";
      confirmBox.style.display = "none";
      if (confirmReturnFocus && confirmReturnFocus.focus) { try { confirmReturnFocus.focus(); } catch (e) {} }
    }
    function sendConfirmed() {
      if (!confirmOpen) return false;
      closeConfirm();
      startCountdown();
      return true;
    }
    function pointX(ev) {
      var t = ev && ((ev.touches && ev.touches[0]) || (ev.changedTouches && ev.changedTouches[0]));
      return Number(t ? t.clientX : ev && ev.clientX) || 0;
    }
    function slideStart(ev) {
      if (!confirmOpen || slide) return;
      slide = { x: pointX(ev), progress: 0 };
      armConfirmTimeout();
      if (ev && ev.preventDefault) ev.preventDefault();
    }
    function slideMove(ev) {
      if (!slide) return;
      slide.progress = sosSlideProgress(slide.x, pointX(ev), slideTravel());
      paintSlide(slide.progress);
      armConfirmTimeout();
      if (ev && ev.preventDefault) ev.preventDefault();
    }
    // Released at the end: send. Released early or cancelled: spring back.
    function slideEnd(ev, cancelled) {
      if (!slide) return;
      var armed = !cancelled && sosSlideArmed(slide.progress);
      slide = null;
      if (armed) sendConfirmed(); else paintSlide(0);
    }
    function slideCancel(ev) { slideEnd(ev, true); }
    function listen(target, names, handler) {
      if (!target || !target.addEventListener) return;
      for (var i = 0; i < names.length; i++) target.addEventListener(names[i], handler, false);
    }
    if (trigger && trigger.addEventListener) {
      trigger.addEventListener("click", function (ev) {
        if (ev && ev.preventDefault) ev.preventDefault();
        openConfirm();
      }, false);
    }
    // Touch events come first so iOS 5 Safari works; the mouse listeners sit on the document so a
    // drag that leaves the track still ends.
    listen(slideTrack, ["touchstart", "mousedown"], slideStart);
    listen(slideTrack, ["touchmove"], slideMove);
    listen(slideTrack, ["touchend"], slideEnd);
    listen(slideTrack, ["touchcancel"], slideCancel);
    listen(doc, ["mousemove"], slideMove);
    listen(doc, ["mouseup"], slideEnd);
    listen(confirmCancel, ["click"], function () { closeConfirm(); });
    listen(confirmSend, ["click"], function () { sendConfirmed(); });
    listen(confirmScrim, ["click"], function () { closeConfirm(); });
    listen(countdownCancel, ["click"], function () {
      stopCountdown();
      if (trigger && trigger.focus) { try { trigger.focus(); } catch (e) {} }
    });
    listen(confirmBox, ["keydown"], function (ev) {
      armConfirmTimeout();
      if (ev && (ev.key === "Escape" || ev.keyCode === 27)) closeConfirm();
    });
    if (root.navigator && root.navigator.serviceWorker &&
        root.navigator.serviceWorker.addEventListener) {
      root.navigator.serviceWorker.addEventListener("message", function (ev) {
        var data = ev && ev.data;
        if (data && data.t === "doorbell-push") onPush(data.payload);
      });
    }
    return { update: update, onPush: onPush, state: function () { return current; },
             trigger: function () { return trigger; },
             confirm: { open: openConfirm, close: closeConfirm, send: sendConfirmed,
                        isOpen: function () { return confirmOpen; },
                        slideStart: slideStart, slideMove: slideMove, slideEnd: slideEnd },
             countdown: { running: countdownRunning, remaining: function () { return countdownLeft; },
                          cancel: stopCountdown, seconds: function () { return countdownSeconds; } },
             operationState: operation.state,
             refreshText: function () {
               renderOperation();
               if (confirmOpen) renderConfirmText();
               if (countdownRunning()) renderCountdown();
             } };
  }

  function base64Key(s) {
    s = String(s || "").replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var raw = root.atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  function pushCapability() {
    if (!root.isSecureContext)
      return { available: false, reason: "secure_context_required",
               message_key: "panel.push_unavailable" };
    if (!(root.navigator && root.navigator.serviceWorker && root.PushManager && root.Notification &&
          root.navigator.serviceWorker.getRegistration && root.fetch && root.Uint8Array && root.atob))
      return { available: false, reason: "push_unsupported",
               message_key: "panel.push_unavailable" };
    return { available: true, reason: "", message_key: "" };
  }

  function status(cb, v) { if (cb) cb(v); return v; }
  function pushStatus(messageKey, value) {
    value = value || {};
    value.message_key = messageKey;
    // One-release compatibility for callers that still inspect message. It is a catalog key,
    // never display text; UI clients must resolve message_key through their selected catalog.
    value.message = messageKey;
    return value;
  }
  function pushFailure(messageKey, error, unavailable) {
    return { message_key: messageKey, error: String(error || ""),
             unavailable: !!unavailable };
  }
  function responseJson(resp) {
    return resp.json().catch(function () { return {}; }).then(function (j) {
      return { response: resp, json: j || {} };
    });
  }
  function apiUnavailable(resp) { return resp.status === 404 || resp.status === 501; }

  function mutationHeaders() {
    var headers = { "Content-Type": "application/json" };
    if (panelCsrf) headers["X-Doorbell-CSRF"] = panelCsrf;
    return headers;
  }

  // The service worker re-enrolls a rotated subscription on its own (pushsubscriptionchange), so
  // it needs the page and group this browser last registered.
  function rememberPushEnrollment(page, group) {
    var sw = root.navigator && root.navigator.serviceWorker;
    if (!sw || !sw.ready || typeof sw.ready.then !== "function") return;
    sw.ready.then(function (reg) {
      var target = reg && (reg.active || reg.waiting || reg.installing);
      if (target && target.postMessage)
        target.postMessage({ t: "doorbell-push-enrollment", page: page, group: group });
    }).catch(function () {});
  }

  function registerPushSubscription(sub, page) {
    var payload = { subscription: sub.toJSON ? sub.toJSON() : sub,
                    page: page || (root.location && root.location.pathname) || "/panel/monitor",
                    group: webGroup() };
    return root.fetch("/api/panel/push-subscription", {
      method: "POST", credentials: "same-origin",
      headers: mutationHeaders(), body: JSON.stringify(payload)
    }).then(responseJson).then(function (result) {
      if (!result.response.ok || result.json.ok !== true) {
        if (apiUnavailable(result.response))
          throw pushFailure("panel.push_unavailable", "push_subscription_api_unavailable", true);
        throw pushFailure("panel.push_failed",
          result.json.err || ("subscription: HTTP " + result.response.status), false);
      }
      rememberPushEnrollment(payload.page, payload.group);
      return sub;
    });
  }

  function pushSubscriptionState(cb) {
    var cap = pushCapability();
    if (!cap.available) return Promise.resolve(status(cb,
      pushStatus(cap.message_key, { ok: false, unavailable: true, subscribed: false,
                                    error: cap.reason })));
    return root.navigator.serviceWorker.getRegistration("/panel/").then(function (reg) {
      if (!reg) return status(cb,
        pushStatus("panel.push_disabled", { ok: true, subscribed: false }));
      return reg.pushManager.getSubscription().then(function (sub) {
        if (!sub) return status(cb,
          pushStatus("panel.push_disabled", { ok: true, subscribed: false }));
        // Reconcile the durable server record on every page/group state check. A browser can keep
        // the same endpoint while navigating to a different validated ?group= value.
        return registerPushSubscription(sub).then(function () {
          return status(cb, pushStatus("panel.push_enabled", { ok: true, subscribed: true }));
        });
      });
    }).catch(function (err) {
      return status(cb, pushStatus(err && err.message_key || "panel.push_failed",
        { ok: false, unavailable: !!(err && err.unavailable), subscribed: false,
          error: err && (err.error || err.message) || "push_state_failed" }));
    });
  }

  function subscribePush(token, page, cb) {
    var cap = pushCapability();
    var newlyCreated = null;
    if (!cap.available) return Promise.resolve(status(cb,
      pushStatus(cap.message_key, { ok: false, unavailable: true, error: cap.reason })));
    status(cb, pushStatus("panel.push_enabling", { ok: false, pending: true }));
    return root.Notification.requestPermission().then(function (permission) {
      if (permission !== "granted")
        throw pushFailure("panel.push_failed", "notification_permission_" + permission, false);
      return Promise.all([
        root.navigator.serviceWorker.register("/panel/sw.js", { scope: "/panel/" }),
        root.fetch("/api/panel/push-vapid-public-key",
                   { cache: "no-store", credentials: "same-origin" }).then(responseJson)
      ]);
    }).then(function (all) {
      var keyResult = all[1];
      if (!keyResult.response.ok || keyResult.json.ok !== true) {
        if (apiUnavailable(keyResult.response))
          throw pushFailure("panel.push_unavailable", "vapid_api_unavailable", true);
        throw pushFailure("panel.push_failed",
          keyResult.json.err || ("VAPID key: HTTP " + keyResult.response.status), false);
      }
      var key = keyResult.json.public_key || keyResult.json.vapid_public_key;
      if (!key) throw pushFailure("panel.push_failed", "vapid_public_key_missing", false);
      return root.navigator.serviceWorker.ready.then(function (reg) {
        return reg.pushManager.getSubscription().then(function (sub) {
          if (sub) return sub;
          return reg.pushManager.subscribe({ userVisibleOnly: true,
                                              applicationServerKey: base64Key(key) })
            .then(function (created) { newlyCreated = created; return created; });
        });
      });
    }).then(function (sub) {
      return registerPushSubscription(sub, page);
    }).then(function () {
      return status(cb, pushStatus("panel.push_enabled", { ok: true, subscribed: true }));
    }).catch(function (err) {
      function failed() {
        return status(cb, pushStatus(err && err.message_key || "panel.push_failed",
          { ok: false, unavailable: !!(err && err.unavailable),
            error: err && (err.error || err.message) || "push_setup_failed" }));
      }
      // A browser subscription is not enabled until Core has durably registered it. Roll back
      // only a subscription created by this attempt; preserve a pre-existing subscription so a
      // transient server failure can be retried without invalidating a known registration.
      if (!newlyCreated || typeof newlyCreated.unsubscribe !== "function") return failed();
      return Promise.resolve().then(function () { return newlyCreated.unsubscribe(); })
        .catch(function () { return false; }).then(failed);
    });
  }

  function unsubscribePush(token, cb) {
    var cap = pushCapability();
    if (!cap.available) return Promise.resolve(status(cb,
      pushStatus(cap.message_key, { ok: false, unavailable: true, error: cap.reason })));
    status(cb, pushStatus("panel.push_disabling",
      { ok: false, pending: true, subscribed: true }));
    return root.navigator.serviceWorker.ready.then(function (reg) {
      return reg.pushManager.getSubscription();
    }).then(function (sub) {
      if (!sub) return status(cb,
        pushStatus("panel.push_disabled", { ok: true, subscribed: false }));
      return root.fetch("/api/panel/push-subscription", {
        method: "DELETE", credentials: "same-origin",
        headers: mutationHeaders(),
        body: JSON.stringify({ endpoint: sub.endpoint })
      }).then(responseJson).then(function (result) {
        if (!result.response.ok || result.json.ok !== true) {
          if (apiUnavailable(result.response))
            throw pushFailure("panel.push_unavailable", "push_subscription_api_unavailable", true);
          throw pushFailure("panel.push_failed",
            result.json.err || ("subscription: HTTP " + result.response.status), false);
        }
        return sub.unsubscribe().then(function () {
          return status(cb,
            pushStatus("panel.push_disabled", { ok: true, subscribed: false }));
        });
      });
    }).catch(function (err) {
      return status(cb, pushStatus(err && err.message_key || "panel.push_failed",
        { ok: false, unavailable: !!(err && err.unavailable),
          error: err && (err.error || err.message) || "push_disable_failed" }));
    });
  }

  return { emergencyState: emergencyState, activePage: activePage, panelUrl: panelUrl,
           requestWithDeadline: requestWithDeadline, createRequestLane: createRequestLane,
           webGroup: webGroup, panelStateUrl: panelStateUrl,
           establishSession: establishSession, panelRequest: panelRequest,
           panelCsrfToken: panelCsrfToken, refreshPanelCsrf: refreshPanelCsrf,
           installEmergencyOverlay: installEmergencyOverlay, pushCapability: pushCapability,
           pushSubscriptionState: pushSubscriptionState, subscribePush: subscribePush,
           unsubscribePush: unsubscribePush,
           base64Key: base64Key, emergencyPresentation: emergencyPresentation,
           pushTargetsGroup: pushTargetsGroup,
           semanticUiModel: semanticUiModel,
           applySemanticUi: applySemanticUi,
           sosSlideProgress: sosSlideProgress, sosSlideArmed: sosSlideArmed,
           sosCountdownSeconds: sosCountdownSeconds,
           SOS_CONFIRM_TIMEOUT_MS: SOS_CONFIRM_TIMEOUT_MS };
});
