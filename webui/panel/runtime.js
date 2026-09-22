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
      var allowed = {}, style = {}, p;
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
      result[id] = { style: style, safety_critical: desc.safety_critical };
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
    return "doorbell.semantic-ui.v1." + String(deviceId || "unknown") + "." + page;
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
        if (style.font_scale !== undefined) el.style.fontSize = (baseFont * style.font_scale) + "px";
        if (style.foreground) el.style.color = style.foreground;
        if (style.background) el.style.backgroundColor = style.background;
        if (style.accent) {
          el.style.outlineColor = style.accent;
          if (el.style.setProperty) el.style.setProperty("--db-semantic-accent", style.accent);
        }
        if (style.border) {
          el.style.borderColor = style.border;
          if (!computed || parseFloat(computed.borderWidth) === 0) el.style.borderWidth = "2px";
          el.style.borderStyle = "solid";
        }
        if (style.radius !== undefined) el.style.borderRadius = style.radius + "px";
        var scale = style.scale === undefined ? 1 : style.scale;
        var baseTransform = el.getAttribute("data-db-base-transform") || "";
        el.style.transform = baseTransform + (scale === 1 ? "" : " scale(" + scale + ")");
        el.style.transformOrigin = "center";
        var tag = String(el.tagName || "").toUpperCase();
        if (entry.safety_critical || /^(BUTTON|A|INPUT)$/.test(tag)) {
          el.style.minWidth = (model.minimum_touch / scale) + "px";
          el.style.minHeight = (model.minimum_touch / scale) + "px";
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
      for (var id in model.elements) if (own(model.elements, id)) effective[id] = model.elements[id].style;
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

  var SOS_HOLD_MS = 2000;
  function sosHoldController(fire, schedule, cancel, delayMs) {
    var timer = null, holding = false;
    delayMs = Number(delayMs) || SOS_HOLD_MS;
    function stop() {
      holding = false;
      if (timer !== null && cancel) cancel(timer);
      timer = null;
    }
    function start() {
      if (holding || !schedule) return false;
      holding = true;
      timer = schedule(function () {
        timer = null;
        if (!holding) return;
        holding = false;
        fire();
      }, delayMs);
      return true;
    }
    return { start: start, cancel: stop, holding: function () { return holding; },
             duration_ms: delayMs };
  }

  // Replicated SOS state is the active-page safety authority while the administrator switch is
  // enabled. A rule-projected device_alert may add presentation detail, but cannot suppress that
  // state. When the switch is disabled, only an explicit Web alert or Push is presented.
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

  function establishSession(cb, explicitCredential) {
    var credential = explicitCredential || locationCredential();
    if (!credential) { cb({ ok: true, existing: true }); return; }
    var xhr = new root.XMLHttpRequest();
    xhr.open("POST", "/api/panel/session", true);
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      var ok = xhr.status === 200;
      if (ok) stripCredentialLocation();
      cb({ ok: ok, status: xhr.status, credential: ok ? credential : "" });
    };
    xhr.send(JSON.stringify({ credential: credential }));
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
    var trigger = null, triggerLabel = null, triggerHint = null;
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
        ".dbSosTrigger{position:fixed;right:18px;bottom:18px;z-index:2147483645;" +
        "min-width:88px;min-height:88px;padding:10px;border:2px solid #fff;border-radius:44px;" +
        "background:#8f1010;color:#fff;font-weight:bold;line-height:1.1;touch-action:none;}" +
        ".dbSosTrigger .dbSosLabel{display:block;font-size:24px;}" +
        ".dbSosTrigger .dbSosHint{display:block;margin-top:5px;font-size:11px;font-weight:normal;}" +
        ".dbSosTrigger.dbSosHolding{outline:5px solid #ffd166;outline-offset:3px;}" +
        ".dbSosTrigger:disabled{opacity:.6;}" +
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
      doc.body.appendChild(overlay);

      trigger = doc.createElement("button");
      trigger.type = "button";
      trigger.className = "dbSosTrigger";
      trigger.setAttribute("data-semantic-id", "sos.trigger");
      trigger.setAttribute("aria-label", options.triggerLabel || "SOS");
      trigger.innerHTML = "<span class='dbSosLabel'></span><span class='dbSosHint'></span>";
      triggerLabel = trigger.getElementsByTagName("span")[0];
      triggerHint = trigger.getElementsByTagName("span")[1];
      triggerLabel.appendChild(doc.createTextNode(options.triggerLabel || "SOS"));
      triggerHint.appendChild(doc.createTextNode(options.triggerHint || "Hold 2s"));
      doc.body.appendChild(trigger);
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
      }
      if (trigger) trigger.disabled = current.active || !!(operation && operation.state().busy);
      if (current.active && triggerHold) cancelTriggerHold();
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
    function translate(key) { return options.translate ? options.translate(key) : key; }
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
      if (trigger) trigger.className = "dbSosTrigger";
      operation.start();
    }
    if (operationAction && operationAction.addEventListener)
      operationAction.addEventListener("click", function () { operation.start(); }, false);
    if (root.addEventListener) root.addEventListener("pagehide", function () {
      cancelTriggerHold(); operation.retire();
    }, false);
    var triggerHold = sosHoldController(postEmergency, root.setTimeout, root.clearTimeout,
                                        SOS_HOLD_MS);
    function cancelTriggerHold() {
      triggerHold.cancel();
      if (trigger) trigger.className = "dbSosTrigger";
    }
    function startTriggerHold(ev) {
      if (!trigger || trigger.disabled || current.active || operation.state().busy) return;
      if (ev && ev.preventDefault) ev.preventDefault();
      if (triggerHold.start()) trigger.className = "dbSosTrigger dbSosHolding";
    }
    if (trigger && trigger.addEventListener) {
      ["mousedown", "touchstart"].forEach(function (name) {
        trigger.addEventListener(name, startTriggerHold, false);
      });
      ["mouseup", "mouseleave", "touchend", "touchcancel"].forEach(function (name) {
        trigger.addEventListener(name, cancelTriggerHold, false);
      });
      trigger.addEventListener("keydown", function (ev) {
        if (ev && (ev.key === " " || ev.key === "Enter" || ev.keyCode === 32 || ev.keyCode === 13))
          startTriggerHold(ev);
      }, false);
      trigger.addEventListener("keyup", cancelTriggerHold, false);
      trigger.addEventListener("click", function (ev) {
        if (ev) ev.preventDefault();
        // Assistive technology activates native buttons with a zero-detail click.
        if (ev && ev.detail === 0) { cancelTriggerHold(); postEmergency(); }
      }, false);
    }
    if (root.navigator && root.navigator.serviceWorker &&
        root.navigator.serviceWorker.addEventListener) {
      root.navigator.serviceWorker.addEventListener("message", function (ev) {
        var data = ev && ev.data;
        if (data && data.t === "doorbell-push") onPush(data.payload);
      });
    }
    return { update: update, onPush: onPush, state: function () { return current; },
             trigger: function () { return trigger; }, hold: triggerHold,
             operationState: operation.state, refreshText: function () { renderOperation(); } };
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

  function registerPushSubscription(sub, page) {
    var payload = { subscription: sub.toJSON ? sub.toJSON() : sub,
                    page: page || (root.location && root.location.pathname) || "/panel/monitor",
                    group: webGroup() };
    return root.fetch("/api/panel/push-subscription", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload)
    }).then(responseJson).then(function (result) {
      if (!result.response.ok || result.json.ok !== true) {
        if (apiUnavailable(result.response))
          throw pushFailure("panel.push_unavailable", "push_subscription_api_unavailable", true);
        throw pushFailure("panel.push_failed",
          result.json.err || ("subscription: HTTP " + result.response.status), false);
      }
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
        headers: { "Content-Type": "application/json" },
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
           establishSession: establishSession,
           installEmergencyOverlay: installEmergencyOverlay, pushCapability: pushCapability,
           pushSubscriptionState: pushSubscriptionState, subscribePush: subscribePush,
           unsubscribePush: unsubscribePush,
           base64Key: base64Key, emergencyPresentation: emergencyPresentation,
           pushTargetsGroup: pushTargetsGroup,
           semanticUiModel: semanticUiModel,
           applySemanticUi: applySemanticUi,
           sosHoldController: sosHoldController, SOS_HOLD_MS: SOS_HOLD_MS };
});
