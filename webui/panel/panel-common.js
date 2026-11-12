/* Helpers shared by the door, monitor and call panel pages. ES5 parse-safe: the door page still
 * runs on iOS 5 Safari. Pages load runtime.js first and pass DoorbellPanelRuntime.panelRequest in. */
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
      triggers[0].setAttribute("aria-label", t("sos.accessibility_start"));
      if (spans.length) setText(spans[0], t("emergency.button"));
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

  // Core publishes automatic ink as a token ("light" or "dark"); an administrator's override is
  // a color.
  function inkColor(value) {
    return value === "light" ? "#ffffff" : value === "dark" ? "#101418" : hexColor(value);
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
    var onSurface = inkColor(override.status_line) || inkColor(ink.status_line);
    if (onSurface) roles.on_surface = onSurface;
    // An explicit hint color becomes the muted role; an ink token leaves it to the stylesheet,
    // which derives muted text from the surface and ink.
    var muted = hexColor(override.hint) || hexColor(ink.hint);
    if (muted) roles.muted = muted;
    var accent = hexColor(theme.call_button_bg);
    if (accent) roles.accent = accent;
    var onAccent = inkColor(theme.call_button_ink);
    if (onAccent) roles.on_accent = onAccent;
    return roles;
  }

  // options.ink === false keeps the system surface and text colors and applies the accent only:
  // Core's surface and ink belong to the wallpaper and are used on the home surfaces that draw it.
  var INK_ROLES = { surface: true, on_surface: true, muted: true };
  function applyColorRoles(theme, doc, options) {
    doc = doc || root.document;
    var el = doc && doc.documentElement, roles = colorRoles(theme), applied = [];
    var ink = !options || options.ink !== false;
    if (!el || !el.style || !el.style.setProperty) return applied;
    for (var name in roles) if (Object.prototype.hasOwnProperty.call(roles, name)) {
      if (!ink && INK_ROLES[name]) continue;
      el.style.setProperty("--" + name.replace(/_/g, "-"), roles[name]);
      applied.push(name);
    }
    if (!ink && el.style.removeProperty)
      for (var dropped in INK_ROLES) el.style.removeProperty("--" + dropped.replace(/_/g, "-"));
    // Secondary surfaces are then derived from Core's surface and ink (panel.css).
    if (el.setAttribute) {
      if (ink && roles.surface && roles.on_surface) el.setAttribute("data-core-roles", "1");
      else if (el.removeAttribute) el.removeAttribute("data-core-roles");
    }
    return applied;
  }

  // The wallpaper of a home surface: display.theme.bg_image (an asset hash served at
  // /asset/<sha256>) under Core's backdrop scrim. Returns null when there is none to draw.
  function wallpaper(theme) {
    theme = theme && typeof theme === "object" ? theme : {};
    var hash = String(theme.bg_image || "");
    if (!/^[0-9a-f]{64}$/.test(hash)) return null;
    var backdrop = theme.backdrop && typeof theme.backdrop === "object" ? theme.backdrop : {};
    var color = hexColor(backdrop.color) || "#000000", opacity = Number(backdrop.opacity);
    if (!(opacity >= 0 && opacity <= 100)) opacity = 62;
    if (backdrop.enabled === false) opacity = 0;
    var scrim = "rgba(" + parseInt(color.substr(1, 2), 16) + "," + parseInt(color.substr(3, 2), 16) + "," +
      parseInt(color.substr(5, 2), 16) + "," + (Math.round(opacity) / 100) + ")";
    return { url: "/asset/" + hash, scrim: scrim, color: color, opacity: Math.round(opacity) / 100 };
  }

  function channel(hex, at) { return parseInt(hex.substr(at, 2), 16); }
  function luminance(hex) {
    var sum = 0, weights = [0.2126, 0.7152, 0.0722];
    for (var i = 0; i < 3; i++) {
      var c = channel(hex, 1 + i * 2) / 255;
      sum += weights[i] * (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
    }
    return sum;
  }
  // What the page actually shows behind its text: Core's sampled wallpaper color under the
  // backdrop scrim, and the ink that reads on it. Core's automatic ink is chosen for the bare
  // wallpaper, so under a scrim it is re-derived the same way (dark ink from luminance 0.1791 up);
  // an administrator's explicit ink color still wins.
  function scrimmedRoles(theme) {
    var paper = wallpaper(theme), roles = colorRoles(theme);
    if (!paper || !roles.surface) return roles;
    var mixed = "#";
    for (var i = 0; i < 3; i++) {
      var value = Math.round(channel(roles.surface, 1 + i * 2) * (1 - paper.opacity) +
                             channel(paper.color, 1 + i * 2) * paper.opacity);
      mixed += (value < 16 ? "0" : "") + value.toString(16);
    }
    roles.surface = mixed;
    var override = (theme.ink_override && hexColor(theme.ink_override.status_line)) || "";
    roles.on_surface = override || (luminance(mixed) >= 0.1791 ? "#101418" : "#ffffff");
    return roles;
  }

  // Draws (or removes) the wallpaper behind a home page and applies Core's colors to match:
  // surface and ink with a wallpaper, the accent alone without one.
  function applyHomeTheme(theme, doc) {
    doc = doc || root.document;
    var body = doc && doc.body, paper = wallpaper(theme), root_el = doc && doc.documentElement;
    applyColorRoles(theme, doc, { ink: !!paper });
    if (paper && root_el && root_el.style && root_el.style.setProperty) {
      var shown = scrimmedRoles(theme);
      if (shown.surface) root_el.style.setProperty("--surface", shown.surface);
      if (shown.on_surface) root_el.style.setProperty("--on-surface", shown.on_surface);
    }
    if (!body || !body.style) return paper;
    var image = paper ? "linear-gradient(" + paper.scrim + "," + paper.scrim + "), url(" + paper.url + ")" : "";
    if (body.getAttribute && body.getAttribute("data-wallpaper") === image) return paper;
    body.style.backgroundImage = image;
    if (body.setAttribute) body.setAttribute("data-wallpaper", image);
    if (body.className !== undefined)
      body.className = String(body.className).replace(/(^|\s)has-wallpaper(?!\S)/g, "") + (paper ? " has-wallpaper" : "");
    return paper;
  }

  // "light" or "dark" when Core fixes the appearance (display.appearance with follow_system
  // false), otherwise "" so the page follows the system setting.
  function appearanceTheme(display) {
    var a = display && typeof display === "object" ? display.appearance : null;
    if (!a || typeof a !== "object" || a.follow_system !== false) return "";
    return a.effective === "light" || a.effective === "dark" ? a.effective : "";
  }

  function applyAppearance(display, doc) {
    doc = doc || root.document;
    var el = doc && doc.documentElement, theme = appearanceTheme(display);
    if (!el || !el.setAttribute) return theme;
    if (theme) el.setAttribute("data-theme", theme);
    else if (el.removeAttribute) el.removeAttribute("data-theme");
    return theme;
  }

  // A Tabler icon from the generated sprite served beside the panel pages. Decorative: panel.css
  // shows it only where external <use> references work, and every control keeps its text label.
  var ICON_SPRITE = "/panel/icons/tabler-sprite.svg";
  var SVG_NS = "http://www.w3.org/2000/svg";
  function iconName(name) { return /^[a-z0-9-]+$/.test(String(name || "")) ? String(name) : ""; }
  function icon(name, doc) {
    doc = doc || root.document;
    name = iconName(name);
    if (!name || !doc || !doc.createElementNS) return null;
    var svg = doc.createElementNS(SVG_NS, "svg"), use = doc.createElementNS(SVG_NS, "use");
    svg.setAttribute("class", "ic");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    use.setAttribute("href", ICON_SPRITE + "#i-" + name);
    svg.appendChild(use);
    return svg;
  }
  function iconMarkup(name) {
    name = iconName(name);
    return name ? "<svg class='ic' aria-hidden='true' focusable='false'><use href='" + ICON_SPRITE +
      "#i-" + name + "'></use></svg>" : "";
  }
  // Replaces a control's content with an optional icon and a text label.
  function setLabel(element, text, iconId) {
    if (!element) return;
    while (element.firstChild) element.removeChild(element.firstChild);
    var doc = element.ownerDocument || root.document;
    var glyph = iconId ? icon(iconId, doc) : null;
    if (glyph) element.appendChild(glyph);
    if (doc && doc.createElement && doc.createTextNode) {
      var span = doc.createElement("span");
      span.className = "lbl";
      span.appendChild(doc.createTextNode(String(text === null || text === undefined ? "" : text)));
      element.appendChild(span);
    } else setText(element, text);
  }

  // ---- Live picture zoom and pan (docs/en/ui-guidelines.md, "Live view / monitor") ----

  var ZOOM_MAX = 4, ZOOM_DOUBLE_TAP = 2;

  // The picture aspect-fitted inside the stage: it fills the width or the height, whichever is
  // reached first, and is never stretched. An unknown picture size counts as filling the stage.
  function fitRect(stageW, stageH, pictureW, pictureH) {
    stageW = Math.max(0, Number(stageW) || 0); stageH = Math.max(0, Number(stageH) || 0);
    pictureW = Number(pictureW); pictureH = Number(pictureH);
    if (!(pictureW > 0) || !(pictureH > 0) || !stageW || !stageH) return { w: stageW, h: stageH };
    var scale = Math.min(stageW / pictureW, stageH / pictureH);
    return { w: pictureW * scale, h: pictureH * scale };
  }

  // Scale limited to 1..ZOOM_MAX and the offset clamped per axis against the stage, which is the
  // clip rectangle: where the zoomed picture is larger than the stage its edges may not come
  // inside the stage edges; where it is not, it stays centred. fitW and fitH are the picture's
  // size at 1x (fitRect); left out, the picture is taken to fill the stage.
  function clampZoom(view, stageW, stageH, fitW, fitH) {
    view = view || {};
    stageW = Number(stageW) || 0; stageH = Number(stageH) || 0;
    fitW = fitW === undefined ? stageW : Number(fitW) || 0;
    fitH = fitH === undefined ? stageH : Number(fitH) || 0;
    var scale = Number(view.scale);
    if (!isFinite(scale) || scale < 1) scale = 1;
    if (scale > ZOOM_MAX) scale = ZOOM_MAX;
    var maxX = Math.max(0, (fitW * scale - stageW) / 2);
    var maxY = Math.max(0, (fitH * scale - stageH) / 2);
    var x = Number(view.x), y = Number(view.y);
    if (!isFinite(x)) x = 0;
    if (!isFinite(y)) y = 0;
    return { scale: scale, x: Math.max(-maxX, Math.min(maxX, x)) || 0,
             y: Math.max(-maxY, Math.min(maxY, y)) || 0 };
  }

  // Zooms by factor while the picture point under (px, py) stays put where the clamp allows it.
  // px and py are measured from the centre of the stage.
  function zoomAt(view, factor, px, py, stageW, stageH, fitW, fitH) {
    var from = clampZoom(view, stageW, stageH, fitW, fitH);
    var to = clampZoom({ scale: from.scale * (Number(factor) || 1) }, stageW, stageH, fitW, fitH).scale;
    var ratio = to / from.scale;
    px = Number(px) || 0; py = Number(py) || 0;
    return clampZoom({ scale: to, x: px - (px - from.x) * ratio, y: py - (py - from.y) * ratio },
                     stageW, stageH, fitW, fitH);
  }

  function panBy(view, dx, dy, stageW, stageH, fitW, fitH) {
    var from = clampZoom(view, stageW, stageH, fitW, fitH);
    return clampZoom({ scale: from.scale, x: from.x + (Number(dx) || 0), y: from.y + (Number(dy) || 0) },
                     stageW, stageH, fitW, fitH);
  }

  // Double tap: fit <-> 2x around the tapped point.
  function toggleZoom(view, px, py, stageW, stageH, fitW, fitH) {
    var from = clampZoom(view, stageW, stageH, fitW, fitH);
    if (from.scale > 1.01) return { scale: 1, x: 0, y: 0 };
    return zoomAt(from, ZOOM_DOUBLE_TAP, px, py, stageW, stageH, fitW, fitH);
  }

  // The part of the stage the zoomed picture covers, per axis. At 1x this is the fitted
  // rectangle; zoomed, it grows into the letterbox bars until it covers the stage.
  function visibleSize(view, stageW, stageH, fitW, fitH) {
    var v = clampZoom(view, stageW, stageH, fitW, fitH);
    return { w: Math.min(Number(stageW) || 0, fitW * v.scale), h: Math.min(Number(stageH) || 0, fitH * v.scale) };
  }

  // Pinch, drag, double tap, wheel and mouse drag on a live picture. box is the stage: it takes
  // whatever space the layout leaves and clips (overflow hidden). layers are the <img>/<video>
  // elements; each fills the stage with the picture aspect-fitted inside it and receives the
  // transform, so a zoomed picture grows into the letterbox bars until it covers the stage. Gestures are handled on
  // the picture only, so the page keeps scrolling at 1x and the action buttons are untouched.
  function attachZoom(box, layers) {
    var view = { scale: 1, x: 0, y: 0 }, noop = function () {};
    if (!box || !box.addEventListener) return { reset: noop, refit: noop, view: function () { return view; } };
    var touches = null, drag = null, lastTap = null, pointers = {}, pointerCount = 0, pinch = null;
    function size() {
      var r = box.getBoundingClientRect ? box.getBoundingClientRect() : null;
      var w = r ? r.width : box.clientWidth || 0, h = r ? r.height : box.clientHeight || 0;
      var natural = pictureSize(), fit = fitRect(w, h, natural.w, natural.h);
      return { w: w, h: h, fw: fit.w, fh: fit.h, left: r ? r.left : 0, top: r ? r.top : 0 };
    }
    // The picture actually on screen: the visible layer that has decoded a frame.
    function pictureSize() {
      for (var i = 0; i < layers.length; i++) {
        var el = layers[i];
        if (!el || (el.style && el.style.display === "none")) continue;
        var w = el.videoWidth || el.naturalWidth || 0, h = el.videoHeight || el.naturalHeight || 0;
        if (w > 0 && h > 0) return { w: w, h: h };
      }
      return { w: 0, h: 0 };
    }
    // Browsers without object-fit (old Safari) would stretch a layer that fills the stage, so
    // there each layer is given the fitted rectangle itself, centred.
    var needsFit = !(box.style && "objectFit" in box.style);
    function fitLayers() {
      if (!needsFit) return;
      var r = box.getBoundingClientRect ? box.getBoundingClientRect() : null;
      var w = r ? r.width : box.clientWidth || 0, h = r ? r.height : box.clientHeight || 0;
      for (var i = 0; i < layers.length; i++) {
        var el = layers[i];
        if (!el || !el.style) continue;
        var fit = fitRect(w, h, el.videoWidth || el.naturalWidth, el.videoHeight || el.naturalHeight);
        el.style.width = Math.round(fit.w) + "px"; el.style.height = Math.round(fit.h) + "px";
        el.style.left = Math.round((w - fit.w) / 2) + "px"; el.style.top = Math.round((h - fit.h) / 2) + "px";
      }
    }
    function local(clientX, clientY, s) {
      return { x: clientX - s.left - s.w / 2, y: clientY - s.top - s.h / 2 };
    }
    function paint() {
      var zoomed = view.scale > 1.001;
      var value = zoomed ? "translate(" + view.x + "px," + view.y + "px) scale(" + view.scale + ")" : "";
      for (var i = 0; i < layers.length; i++) if (layers[i] && layers[i].style) {
        layers[i].style.webkitTransform = value;
        layers[i].style.transform = value;
      }
      // Only a zoomed picture takes one-finger drags away from page scrolling.
      box.style.touchAction = zoomed ? "none" : "";
      box.className = box.className.replace(/(^|\s)is-zoomed(?!\S)/g, "") + (zoomed ? " is-zoomed" : "");
    }
    function set(next) { view = next; paint(); }
    function reset() { touches = drag = pinch = lastTap = null; fitLayers(); set({ scale: 1, x: 0, y: 0 }); }
    // A new frame size (first frame, another stream, a rotated source) refits and reclamps.
    function refit() { fitLayers(); var s = size(); set(clampZoom(view, s.w, s.h, s.fw, s.fh)); }
    for (var li = 0; li < layers.length; li++) if (layers[li] && layers[li].addEventListener) {
      layers[li].addEventListener("load", refit, false);
      layers[li].addEventListener("loadedmetadata", refit, false);
      layers[li].addEventListener("resize", refit, false);
    }
    function stop(event) { if (event.cancelable !== false && event.preventDefault) event.preventDefault(); }
    function tap(clientX, clientY) {
      var now = new Date().getTime(), s = size();
      if (lastTap && now - lastTap.at < 320 && Math.abs(clientX - lastTap.x) < 30 &&
          Math.abs(clientY - lastTap.y) < 30) {
        var p = local(clientX, clientY, s);
        lastTap = null;
        set(toggleZoom(view, p.x, p.y, s.w, s.h, s.fw, s.fh));
        return true;
      }
      lastTap = { at: now, x: clientX, y: clientY };
      return false;
    }
    function pinchStart(a, b) {
      return { distance: Math.max(1, Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))),
               cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2 };
    }
    function pinchMove(a, b) {
      var next = pinchStart(a, b), s = size(), p = local(next.cx, next.cy, s);
      var moved = panBy(view, next.cx - pinch.cx, next.cy - pinch.cy, s.w, s.h, s.fw, s.fh);
      set(zoomAt(moved, next.distance / pinch.distance, p.x, p.y, s.w, s.h, s.fw, s.fh));
      pinch = next;
    }

    // Touch events: decided per gesture, so a one-finger swipe at 1x still scrolls the page.
    function touchPoint(t) { return { x: t.clientX, y: t.clientY }; }
    function onTouchStart(event) {
      var list = event.touches || [];
      if (list.length === 2) {
        stop(event);
        pinch = pinchStart(touchPoint(list[0]), touchPoint(list[1]));
        drag = null; touches = { moved: true };
      } else if (list.length === 1) {
        touches = { moved: false, x: list[0].clientX, y: list[0].clientY };
        drag = view.scale > 1.001 ? { x: list[0].clientX, y: list[0].clientY } : null;
        if (drag) stop(event);
      }
    }
    function onTouchMove(event) {
      var list = event.touches || [], s;
      if (list.length === 2 && pinch) {
        stop(event);
        pinchMove(touchPoint(list[0]), touchPoint(list[1]));
      } else if (list.length === 1 && drag) {
        stop(event);
        s = size();
        set(panBy(view, list[0].clientX - drag.x, list[0].clientY - drag.y, s.w, s.h, s.fw, s.fh));
        drag = { x: list[0].clientX, y: list[0].clientY };
        if (touches) touches.moved = true;
      } else if (list.length === 1 && touches &&
                 (Math.abs(list[0].clientX - touches.x) > 10 || Math.abs(list[0].clientY - touches.y) > 10)) {
        touches.moved = true;
      }
    }
    function onTouchEnd(event) {
      var list = event.touches || [], ended = event.changedTouches && event.changedTouches[0];
      if (list.length < 2) pinch = null;
      if (list.length === 1) drag = view.scale > 1.001 ? touchPoint(list[0]) : null;
      if (list.length === 0) {
        drag = null;
        if (touches && !touches.moved && ended && tap(ended.clientX, ended.clientY)) stop(event);
        touches = null;
      }
    }

    // Pointer Events for mouse and pen, and for touch where touch events do not exist.
    var touchEvents = "ontouchstart" in box || ("ontouchstart" in root);
    function usesPointer(event) { return !(touchEvents && event.pointerType === "touch"); }
    function onPointerDown(event) {
      if (!usesPointer(event) || (event.button !== undefined && event.button > 0)) return;
      if (!pointers[event.pointerId]) pointerCount++;
      pointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      if (pointerCount === 2) { pinch = pointerPinch(); drag = null; stop(event); }
      else if (view.scale > 1.001) {
        drag = { x: event.clientX, y: event.clientY, id: event.pointerId };
        if (box.setPointerCapture) { try { box.setPointerCapture(event.pointerId); } catch (e) {} }
        stop(event);
      }
    }
    function pointerPinch() {
      var pts = [];
      for (var id in pointers) if (Object.prototype.hasOwnProperty.call(pointers, id)) pts.push(pointers[id]);
      return pts.length >= 2 ? pinchStart(pts[0], pts[1]) : null;
    }
    function onPointerMove(event) {
      if (!usesPointer(event) || !pointers[event.pointerId]) return;
      pointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      var s;
      if (pointerCount >= 2 && pinch) {
        var pts = [];
        for (var id in pointers) if (Object.prototype.hasOwnProperty.call(pointers, id)) pts.push(pointers[id]);
        stop(event);
        pinchMove(pts[0], pts[1]);
      } else if (drag && drag.id === event.pointerId) {
        stop(event);
        s = size();
        set(panBy(view, event.clientX - drag.x, event.clientY - drag.y, s.w, s.h, s.fw, s.fh));
        drag.x = event.clientX; drag.y = event.clientY;
      }
    }
    function onPointerUp(event) {
      if (!pointers[event.pointerId]) return;
      delete pointers[event.pointerId];
      pointerCount = Math.max(0, pointerCount - 1);
      if (pointerCount < 2) pinch = null;
      if (drag && drag.id === event.pointerId) drag = null;
    }
    // Plain mouse events where Pointer Events do not exist.
    function onMouseDown(event) {
      if (event.button > 0 || view.scale <= 1.001) return;
      drag = { x: event.clientX, y: event.clientY, mouse: true };
      stop(event);
    }
    function onMouseMove(event) {
      if (!drag || !drag.mouse) return;
      var s = size();
      set(panBy(view, event.clientX - drag.x, event.clientY - drag.y, s.w, s.h, s.fw, s.fh));
      drag.x = event.clientX; drag.y = event.clientY;
    }
    function onMouseUp() { if (drag && drag.mouse) drag = null; }
    function onWheel(event) {
      var s = size(), p = local(event.clientX, event.clientY, s);
      var delta = event.deltaY !== undefined ? event.deltaY : -(event.wheelDelta || 0);
      if (!delta) return;
      var next = zoomAt(view, delta < 0 ? 1.2 : 1 / 1.2, p.x, p.y, s.w, s.h, s.fw, s.fh);
      // At the limit the wheel is left to the page so scrolling is never trapped.
      if (next.scale === view.scale) return;
      stop(event);
      set(next);
    }
    function onDoubleClick(event) {
      var s = size(), p = local(event.clientX, event.clientY, s);
      stop(event);
      set(toggleZoom(view, p.x, p.y, s.w, s.h, s.fw, s.fh));
    }

    var active = { passive: false };
    try { box.addEventListener("touchstart", onTouchStart, active); }
    catch (e) { active = false; box.addEventListener("touchstart", onTouchStart, false); }
    box.addEventListener("touchmove", onTouchMove, active);
    box.addEventListener("touchend", onTouchEnd, active);
    box.addEventListener("touchcancel", function () { touches = drag = pinch = null; }, false);
    if (root.PointerEvent) {
      box.addEventListener("pointerdown", onPointerDown, false);
      box.addEventListener("pointermove", onPointerMove, false);
      box.addEventListener("pointerup", onPointerUp, false);
      box.addEventListener("pointercancel", onPointerUp, false);
    } else {
      box.addEventListener("mousedown", onMouseDown, false);
      if (root.addEventListener) {
        root.addEventListener("mousemove", onMouseMove, false);
        root.addEventListener("mouseup", onMouseUp, false);
      }
    }
    box.addEventListener("wheel", onWheel, active);
    box.addEventListener("dblclick", onDoubleClick, false);
    if (root.addEventListener) root.addEventListener("resize", refit, false);
    fitLayers();
    return { reset: reset, refit: refit, view: function () { return view; } };
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

  // Columns and rows for n 16:9 tiles filling a width x height area (expanded dashboards): the
  // layout that gives each tile the largest video. Each tile also carries a footer of footerPx.
  function tileGrid(n, width, height, gapPx, footerPx) {
    n = Math.max(1, Math.floor(Number(n) || 1));
    width = Math.max(1, Number(width) || 1); height = Math.max(1, Number(height) || 1);
    gapPx = Math.max(0, Number(gapPx) || 0); footerPx = Math.max(0, Number(footerPx) || 0);
    var best = { cols: 1, rows: n, video: 0 };
    for (var cols = 1; cols <= n; cols++) {
      var rows = Math.ceil(n / cols);
      var cellW = (width - gapPx * (cols - 1)) / cols;
      var cellH = (height - gapPx * (rows - 1)) / rows - footerPx;
      if (cellW <= 0 || cellH <= 0) continue;
      var videoW = Math.min(cellW, cellH * 16 / 9);
      if (videoW > best.video + 0.5) best = { cols: cols, rows: rows, video: videoW };
    }
    return { cols: best.cols, rows: best.rows };
  }

  // Placeholder text key for a video area, or "" when a picture is showing. hasFrame reports a
  // frame actually on screen: playback keeps the MJPEG picture visible while it retries H.264
  // ("fallback"), and that picture must not be covered by "Connecting".
  function videoPlaceholder(doorState, playbackState, hasFrame) {
    if (doorState === "offline") return "dash.tile_offline";
    if (hasFrame || playbackState === "playing") return "";
    if (playbackState === "failed") return "ring.no_video";
    return "video.connecting";
  }

  // True when an <img> or <video> in a video area is showing a decoded picture.
  function mediaHasFrame(img, video) {
    var imgOk = !!img && img.naturalWidth > 0 && !!(img.getAttribute && img.getAttribute("src")) &&
      img.style.display !== "none" && img.style.visibility !== "hidden";
    var videoOk = !!video && video.style.display !== "none" && (video.readyState || 0) >= 2;
    return imgOk || videoOk;
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
           doorTileState: doorTileState, groupByDay: groupByDay, tileGrid: tileGrid,
           videoPlaceholder: videoPlaceholder, mediaHasFrame: mediaHasFrame,
           appearanceTheme: appearanceTheme, applyAppearance: applyAppearance,
           wallpaper: wallpaper, applyHomeTheme: applyHomeTheme, scrimmedRoles: scrimmedRoles,
           icon: icon, iconMarkup: iconMarkup, setLabel: setLabel,
           ZOOM_MAX: ZOOM_MAX, clampZoom: clampZoom, zoomAt: zoomAt, panBy: panBy,
           toggleZoom: toggleZoom, fitRect: fitRect, visibleSize: visibleSize, attachZoom: attachZoom };
});
