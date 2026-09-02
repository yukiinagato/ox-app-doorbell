


var AdminLogic = (function () {
  "use strict";

  function isObj(v) { return v !== null && typeof v === "object" && !(v instanceof Array); }
  function num(v, def) { var n = parseFloat(v); return isNaN(n) ? def : n; }

  function runtimeHealthRows(runtime) {
    runtime = isObj(runtime) ? runtime : {};
    function at(path) {
      var cur = runtime, parts = path.split(".");
      for (var i = 0; i < parts.length; i++) {
        if (!isObj(cur) || !Object.prototype.hasOwnProperty.call(cur, parts[i])) return undefined;
        cur = cur[parts[i]];
      }
      return cur;
    }
    function first(paths) {
      for (var i = 0; i < paths.length; i++) {
        var value = at(paths[i]);
        if (value !== undefined && value !== null && value !== "") return value;
      }
      return undefined;
    }
    var rows = [];
    var safe = first(["safe_mode.active", "safe_mode", "process_recovery.safe_mode",
                      "windows.safe_mode", "ios_compat.safe_mode"]);
    if (safe === true) rows.push({ key: "safe_mode", value: "active", severity: "err" });
    else if (safe === false) rows.push({ key: "safe_mode", value: "off", severity: "ok" });
    var helper = first(["recovery_helper.effective", "recovery.effective.mode",
                        "helper_effective", "effective_mode", "helper_mode"]);
    if (helper !== undefined) {
      helper = String(helper);
      rows.push({ key: "helper", value: helper,
        severity: /(unavailable|degraded|mismatch|invalid)/.test(helper) ? "err" : "ok" });
    }
    var playback = at("media_playback"), codec;
    if (isObj(playback) && playback.state) {
      var playbackParts = [String(playback.state)];
      if (playback.transport && playback.transport !== "none")
        playbackParts.push(String(playback.transport));
      if (playback.compositor && playback.compositor !== "none")
        playbackParts.push(String(playback.compositor));
      if (playback.displayed_frames !== undefined || playback.decoded_frames !== undefined)
        playbackParts.push("frames=" + String(playback.displayed_frames || 0) + "/" +
          String(playback.decoded_frames || 0));
      if (playback.dropped_frames)
        playbackParts.push("drop=" + String(playback.dropped_frames));
      codec = playbackParts.join(" / ");
    } else {
      codec = first(["codec_health", "windows.h264_playback", "components.media",
                     "media_source.state", "camera.state", "avc_encode.state"]);
    }
    if (codec !== undefined) {
      codec = String(codec);
      rows.push({ key: "codec", value: codec,
        severity: /(failed|error|unavailable|uncertified|degraded|disabled)/.test(codec) ?
          "warn" : "ok" });
    }
    var lastExit = first(["last_exit_reason", "process_recovery.last_exit_reason"]);
    if (lastExit !== undefined)
      rows.push({ key: "last_exit", value: String(lastExit), severity: "" });
    var alert = first(["device_alert.result", "emergency_presentation.result"]);
    if (alert !== undefined) {
      alert = String(alert);
      rows.push({ key: "alert", value: alert,
        severity: /(rejected|denied|unsupported|failed|unavailable)/.test(alert) ? "warn" : "ok" });
    }
    var generation = first(["generation"]), heartbeat = first(["heartbeat_ms"]);
    if (generation !== undefined || heartbeat !== undefined)
      rows.push({ key: "heartbeat", value: "g" + String(generation === undefined ? "?" : generation) +
        (heartbeat === undefined ? "" : " @" + String(heartbeat)), severity: "" });
    return rows;
  }


  function parseList(s) {
    if (!s) return [];
    var parts = String(s).split(/[,、，\s]+/), out = [];
    for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i]);
    return out;
  }


  function parseChatIds(s) {
    var l = parseList(s), out = [];
    for (var i = 0; i < l.length; i++)
      out.push(/^-?\d+$/.test(l[i]) ? parseInt(l[i], 10) : l[i]);
    return out;
  }


  function labelObj(ja, en, zh) {
    var o = {};
    if (ja) o.ja = ja;
    if (en) o.en = en;
    if (zh) o.zh = zh;
    return o;
  }

  function editableClone(existing) {
    return isObj(existing) ? cloneJson(existing) : {};
  }

  function mergedLabel(existing, f) {
    var out = isObj(existing) ? cloneJson(existing) : {};
    ["ja", "en", "zh"].forEach(function (lang) {
      if (f[lang]) out[lang] = f[lang];
      else delete out[lang];
    });
    return out;
  }

  function hasOwnKeys(value) {
    for (var key in value) if (own(value, key)) return true;
    return false;
  }


  function labelOf(entity, lang, fallback) {
    var l = entity && entity.label;
    if (isObj(l)) {
      if (l[lang]) return l[lang];
      if (l.ja) return l.ja;
      for (var k in l) if (l[k]) return l[k];
    }
    return fallback || "";
  }


  function buildingEntries(id, f, existing) {
    var value = editableClone(existing);
    value.label = mergedLabel(value.label, f);
    return [{ key: "buildings." + id, value: value }];
  }

  function doorEntries(id, f, existing) {
    var v = editableClone(existing);
    v.label = mergedLabel(v.label, f);
    if (f.building) v.building = f.building;
    else delete v.building;
    return [{ key: "doors." + id, value: v }];
  }


  function audioObj(map) {
    var o = {}, n = 0;
    for (var k in map) if (map[k]) { o[k] = map[k]; n++; }
    return n ? o : null;
  }

  function quickReplyEntries(id, f, existing) {
    var v = editableClone(existing);
    v.label = mergedLabel(v.label, f);
    v.speak = !!f.speak;
    v.order = num(f.order, 1);
    if (isObj(f.audio)) {
      var au = isObj(v.audio) ? cloneJson(v.audio) : {};
      for (var lang in f.audio) if (own(f.audio, lang)) {
        if (f.audio[lang]) au[lang] = f.audio[lang];
        else delete au[lang];
      }
      if (hasOwnKeys(au)) v.audio = au;
      else delete v.audio;
    }
    return [{ key: "quick_replies." + id, value: v }];
  }



  function reorderEntries(sortedIds, qrs) {
    var out = [];
    for (var i = 0; i < sortedIds.length; i++) {
      var id = sortedIds[i], cur = (qrs && qrs[id]) || {};
      var v = editableClone(cur);
      v.order = i + 1;
      out.push({ key: "quick_replies." + id, value: v });
    }
    return out;
  }

  function householdEntries(id, f, existing) {
    var value = editableClone(existing);
    value.label = mergedLabel(value.label, f);
    value.telegram_chat_ids = parseChatIds(f.chat_ids);
    value.sip_extensions = parseList(f.sip_ext);
    return [{ key: "households." + id, value: value }];
  }



  function deviceEntries(id, f, existing) {
    var base = "devices." + id, e = [];
    e.push({ key: base + ".name", value: String(f.name || "") });
    e.push({ key: base + ".role", value: f.role || "door_station" });
    e.push({ key: base + ".door", value: f.door || "" });
    e.push({ key: base + ".local.ui_lang", value: f.ui_lang || "ja" });
    e.push({ key: base + ".local.video.playback",
             value: f.video_playback || "low_latency" });
    e.push({ key: base + ".local.video.rotation",
             value: f.video_rotation || "auto" });
    e.push({ key: base + ".local.recovery.helper_mode",
             value: /^(off|auto|on)$/.test(f.helper_mode) ? f.helper_mode : "auto" });
    var local = isObj(existing) && isObj(existing.local) ? existing.local : {};
    var camera = editableClone(local.camera);
    camera.device_hint = f.cam_hint || "";
    camera.mjpeg_fps = num(f.cam_fps, 8);
    camera.mjpeg_quality = num(f.cam_quality, 60);
    camera.resolution = f.cam_resolution || "640x480";
    camera.codec = f.cam_codec || "auto";
    camera.h264_resolution = f.cam_h264_resolution || "640x360";
    camera.h264_fps = num(f.cam_h264_fps, 30);
    camera.h264_bitrate_kbps = num(f.cam_h264_bitrate, 700);
    e.push({ key: base + ".local.camera", value: camera });
    var motion = editableClone(local.motion);
    motion.enabled = !!f.motion_enabled;
    motion.sensitivity = num(f.motion_sensitivity, 40);
    motion.min_interval_s = num(f.motion_interval, 30);
    e.push({ key: base + ".local.motion", value: motion });

    if (isObj(f.caps_override)) e.push({ key: base + ".caps_override", value: f.caps_override });
    return e;
  }

  function defaultPlaybackProfile() {
    return { strategies: [
      { id: "h264_low_latency", enabled: true, startup_timeout_ms: 5000, stall_timeout_ms: 3000 },
      { id: "h264_hls", enabled: false, startup_timeout_ms: 5000, stall_timeout_ms: 5000 },
      { id: "mjpeg", enabled: true, startup_timeout_ms: 5000, stall_timeout_ms: 3000 }
    ] };
  }

  function normalizePlaybackProfile(profile) {
    var src = profile && profile.strategies instanceof Array ? profile.strategies : [];
    var defs = defaultPlaybackProfile().strategies, byId = {}, out = [], i, s;
    for (i = 0; i < defs.length; i++) byId[defs[i].id] = defs[i];
    for (i = 0; i < src.length; i++) {
      s = src[i] || {};
      if (!byId[s.id] || out.some(function (x) { return x.id === s.id; })) continue;
      out.push({ id: s.id, enabled: s.enabled !== false,
        startup_timeout_ms: num(s.startup_timeout_ms, byId[s.id].startup_timeout_ms),
        stall_timeout_ms: num(s.stall_timeout_ms, byId[s.id].stall_timeout_ms) });
    }
    for (i = 0; i < defs.length; i++) {
      s = defs[i];
      if (!out.some(function (x) { return x.id === s.id; }))
        out.push({ id: s.id, enabled: false, startup_timeout_ms: s.startup_timeout_ms,
                   stall_timeout_ms: s.stall_timeout_ms });
    }
    return { strategies: out };
  }

  function playbackProfileEntries(viewer, source, profile, existing) {
    var key = viewer && source ? "video_playback.pairs." + viewer + "." + source
                               : "video_playback.global";
    var value = editableClone(existing);
    var edited = normalizePlaybackProfile(profile).strategies;
    var previous = value.strategies instanceof Array ? value.strategies : [];
    var known = {}, merged = [], i, j;
    for (i = 0; i < edited.length; i++) known[edited[i].id] = true;
    for (i = 0; i < edited.length; i++) {
      var before = null;
      for (j = 0; j < previous.length; j++) {
        if (isObj(previous[j]) && previous[j].id === edited[i].id) {
          before = previous[j];
          break;
        }
      }
      var strategy = editableClone(before);
      strategy.id = edited[i].id;
      strategy.enabled = edited[i].enabled;
      strategy.startup_timeout_ms = edited[i].startup_timeout_ms;
      strategy.stall_timeout_ms = edited[i].stall_timeout_ms;
      merged.push(strategy);
    }
    var ordered = [], nextKnown = 0;
    for (i = 0; i < previous.length; i++) {
      var old = previous[i];
      if (isObj(old) && own(known, old.id)) {
        if (nextKnown < merged.length) ordered.push(merged[nextKnown++]);
      } else {
        ordered.push(cloneJson(old));
      }
    }
    while (nextKnown < merged.length) ordered.push(merged[nextKnown++]);
    value.strategies = ordered;
    return [{ key: key, value: value }];
  }

  /* ---- Per-device semantic UI overrides ----
     ui_manifest is a read-only runtime capability. Configuration may write only properties
     allowed by that manifest under devices.<id>.local.ui.elements.<semantic_id>. */
  var UI_PROPERTIES = ["scale", "font_scale", "foreground", "background",
                       "accent", "border", "radius"];

  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function unknownKeys(o, allowed, label, errors) {
    if (!isObj(o)) return;
    for (var k in o) if (own(o, k) && allowed.indexOf(k) < 0)
      errors.push(label + ": unsupported field " + k);
  }

  function elementDesc(properties, safety) {
    return {
      properties: properties.slice(),
      safety_critical: !!safety,
      defaults: {
        scale: 1, font_scale: 1, foreground: "#e8edf2", background: "#1a2027",
        accent: "#4da3ff", border: "#4da3ff", radius: 12
      }
    };
  }
  function defaultUiManifest(role) {
    var all = ["scale", "font_scale", "foreground", "background", "accent", "border", "radius"];
    var e = {}, safety = { "cancel.call": true, "call.end": true, "sos.trigger": true,
                           "sos.cancel": true, "maintenance.exit": true };
    var ids = ["call.primary", "cancel.call", "call.end", "purpose.button", "sos.trigger",
               "sos.cancel", "ring.title", "ring.action", "reply.button", "monitor.close",
               "status.offline", "maintenance.exit"];
    for (var i = 0; i < ids.length; i++) e[ids[i]] = elementDesc(all, !!safety[ids[i]]);
    return { schema_version: 1, units: "logical",
             viewport: { minimum_touch: 44, scale_min: 0.75, scale_max: 2.0 }, elements: e };
  }

  function validateUiManifest(manifest) {
    var errors = [];
    if (!isObj(manifest) || manifest.schema_version !== 1) errors.push("ui_manifest.schema_version must be 1");
    if (!isObj(manifest) || ["logical", "dp", "pt", "effective_px"].indexOf(manifest.units) < 0)
      errors.push("ui_manifest.units must be logical, dp, pt, or effective_px");
    unknownKeys(manifest, ["schema_version", "units", "viewport", "elements"],
                "ui_manifest", errors);
    var vp = manifest && manifest.viewport, els = manifest && manifest.elements;
    unknownKeys(vp, ["minimum_touch", "scale_min", "scale_max"],
                "ui_manifest.viewport", errors);
    if (!isObj(vp) || !isFinite(Number(vp.minimum_touch)) ||
        !isFinite(Number(vp.scale_min)) || !isFinite(Number(vp.scale_max)) ||
        !(Number(vp.minimum_touch) >= 1) || !(Number(vp.scale_min) > 0) ||
        !(Number(vp.scale_max) >= Number(vp.scale_min)))
      errors.push("ui_manifest.viewport is invalid");
    if (!isObj(els)) errors.push("ui_manifest.elements is required");
    if (isObj(els)) for (var id in els) {
      if (!own(els, id)) continue;
      var d = els[id], seen = {};
      if (!/^[A-Za-z0-9_.-]+$/.test(id)) errors.push("invalid semantic ID: " + id);
      if (!isObj(d) || !(d.properties instanceof Array)) {
        errors.push(id + ".properties is required"); continue;
      }
      unknownKeys(d, ["properties", "safety_critical", "defaults"], id, errors);
      for (var i = 0; i < d.properties.length; i++) {
        var p = d.properties[i];
        if (UI_PROPERTIES.indexOf(p) < 0) errors.push(id + ": unsupported property " + p);
        else if (seen[p]) errors.push(id + ": duplicate property " + p);
        seen[p] = true;
      }
      if (typeof d.safety_critical !== "boolean") errors.push(id + ".safety_critical is required");
      if (!isObj(d.defaults)) errors.push(id + ".defaults is required");
      else {
        for (var dp = 0; dp < d.properties.length; dp++)
          if (!own(d.defaults, d.properties[dp]))
            errors.push(id + ".defaults requires " + d.properties[dp]);
        for (var dk in d.defaults) if (own(d.defaults, dk) && !seen[dk])
          errors.push(id + ".defaults has undeclared property " + dk);
      }
    }
    // Contrast among a manifest's own defaults is reported the same way an operator's colour is:
    // a shell that ships a hard-to-read default should be told, not refused outright.
    var warnings = [];
    if (!errors.length) for (var elementId in els) {
      if (!own(els, elementId)) continue;
      var checked = validateUiElementValue(manifest, elementId, els[elementId].defaults);
      if (!checked.ok) errors = errors.concat(checked.errors);
      if (checked.warnings) warnings = warnings.concat(checked.warnings);
    }
    return { ok: errors.length === 0, errors: errors, warnings: warnings };
  }

  function colorOk(v) { return /^#[0-9a-f]{6}$/i.test(String(v || "")); }
  function luminance(hex) {
    if (!colorOk(hex)) return 0;
    var a = [1, 3, 5].map(function (i) {
      var c = parseInt(hex.substr(i, 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function contrast(a, b) {
    var x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }

  function validateUiElementValue(manifest, id, value) {
    var errors = [];
    var desc = manifest && manifest.elements && manifest.elements[id];
    if (!desc) return { ok: false, errors: ["element is absent from ui_manifest: " + id] };
    if (!isObj(value)) return { ok: false, errors: [id + " override must be an object"] };
    var vp = manifest.viewport || {}, min = Number(vp.scale_min), max = Number(vp.scale_max);
    for (var k in value) {
      if (!own(value, k)) continue;
      if (desc.properties.indexOf(k) < 0) { errors.push(id + ": " + k + " is not allowed"); continue; }
      if (k === "scale" || k === "font_scale") {
        var n = Number(value[k]);
        if (typeof value[k] !== "number" || !isFinite(n) || !(n >= min && n <= max))
          errors.push(id + "." + k + " must be a number from " + min + " to " + max);
        if (desc.safety_critical && (k === "scale" || k === "font_scale") && n < 1)
          errors.push(id + ": safety-critical scale/font_scale cannot be less than 1");
      } else if (k === "radius") {
        var r = Number(value[k]);
        if (typeof value[k] !== "number" || !isFinite(r) || !(r >= 0 && r <= Number(vp.minimum_touch)))
          errors.push(id + ".radius must be a number from 0 to " + vp.minimum_touch + " logical units");
      } else if (typeof value[k] !== "string" || !colorOk(value[k]))
        errors.push(id + "." + k + " must be #RRGGBB");
    }
    var effective = {}, defaultValues = desc.defaults || {};
    for (var defaultKey in defaultValues)
      if (own(defaultValues, defaultKey)) effective[defaultKey] = defaultValues[defaultKey];
    for (var overrideKey in value)
      if (own(value, overrideKey)) effective[overrideKey] = value[overrideKey];
    // Contrast is measured, never enforced. A custom colour is the operator's choice: the server
    // saves it and reports the ratio, and so does this form.
    var warnings = [];
    function measure(property, floor) {
      if (!effective[property] || !effective.background) return;
      var ratio = contrast(effective[property], effective.background);
      if (ratio >= floor) return;
      warnings.push({ key: id, property: property,
                      contrast: Math.round(ratio * 10) / 10,
                      message_key: "theme.low_contrast" });
    }
    measure("foreground", 4.5);
    measure("accent", 3);
    measure("border", 3);
    return { ok: errors.length === 0, errors: errors, warnings: warnings };
  }

  function validateUiElementOverride(manifest, id, value) {
    var mv = validateUiManifest(manifest);
    return mv.ok ? validateUiElementValue(manifest, id, value) : mv;
  }

  function uiPreviewModel(manifest, values) {
    var mv = validateUiManifest(manifest);
    if (!mv.ok) throw new Error(mv.errors[0]);
    var out = [];
    var ids = Object.keys(manifest.elements).sort();
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i], desc = manifest.elements[id];
      var style = cloneJson(desc.defaults), override = values && values[id];
      if (override !== undefined) {
        var checked = validateUiElementValue(manifest, id, override);
        if (!checked.ok) throw new Error(checked.errors[0]);
        for (var key in override) if (own(override, key)) style[key] = override[key];
      }
      out.push({ id: id, safety_critical: desc.safety_critical, style: style });
    }
    return { units: manifest.units, minimum_touch: manifest.viewport.minimum_touch,
             elements: out };
  }

  function uiElementValue(elements, semanticId) {
    if (!isObj(elements)) return undefined;
    if (own(elements, semanticId)) return elements[semanticId];
    var cur = elements, segs = semanticId.split(".");
    for (var i = 0; i < segs.length; i++) {
      if (!isObj(cur) || !own(cur, segs[i])) return undefined;
      cur = cur[segs[i]];
    }
    return cur;
  }

  function uiElementChanges(nodeId, manifest, values) {
    var entries = [], dels = [], base = "devices." + nodeId + ".local.ui.elements.";
    for (var id in values) {
      if (!own(values, id)) continue;
      if (!own(manifest.elements, id)) throw new Error("element is absent from ui_manifest: " + id);
      var value = values[id], n = 0;
      if (isObj(value)) for (var k in value) if (own(value, k)) n++;
      if (!n) dels.push(base + id);
      else {
        var checked = validateUiElementOverride(manifest, id, value);
        if (!checked.ok) throw new Error(checked.errors[0]);
        entries.push({ key: base + id, value: value });
      }
    }
    return { entries: entries, dels: dels };
  }

  function configBatchOps(entries, dels) {
    var ops = [], seen = {}, i, key;
    entries = entries || []; dels = dels || [];
    for (i = 0; i < entries.length; i++) {
      key = String((entries[i] && entries[i].key) || "");
      if (!key || seen[key]) throw new Error("duplicate or empty config key: " + key);
      validateUiConfigMutation(key, entries[i].value, false);
      seen[key] = true;
      ops.push({ op: "set", key: key, value: entries[i].value });
    }
    for (i = 0; i < dels.length; i++) {
      key = String(dels[i] || "");
      if (!key || seen[key]) throw new Error("duplicate or empty config key: " + key);
      validateUiConfigMutation(key, undefined, true);
      seen[key] = true;
      ops.push({ op: "delete", key: key });
    }
    return ops;
  }

  // Write semantic UI overrides only as whole element objects. Raw import/editor paths may not
  // create legacy styles, writable manifests, or scalar leaves that bypass server validation.
  function validateUiConfigMutation(key, value, deleting) {
    if (!/^devices\.[^.]+\.local\.ui(?:\.|$)/.test(key)) return;
    var marker = ".local.ui.elements.", at = key.indexOf(marker);
    var semantic = at >= 0 ? key.slice(at + marker.length) : "";
    if (at < 0 || !/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/.test(semantic))
      throw new Error("semantic UI writes are restricted to devices.<id>.local.ui.elements.<semantic_id>");
    if (deleting) return;
    if (!isObj(value)) throw new Error("semantic UI element override must be an object");
    for (var k in value) if (own(value, k) && UI_PROPERTIES.indexOf(k) < 0)
      throw new Error("unsupported semantic UI property: " + k);
  }

  // ---- Trigger rules (lossless whole-value merge) ----
  var RULE_ACTION_TYPES = ["sip_call", "telegram", "ha_event", "chime", "device_alert"];
  var ALERT_CHANNELS = ["in_app", "system_notification", "web_push"];

  function cloneJson(v) {
    if (v === undefined) return undefined;
    return JSON.parse(JSON.stringify(v));
  }

  function sameJson(a, b) {
    if (a === b) return true;
    if (a === null || b === null || typeof a !== typeof b) return false;
    if (a instanceof Array || b instanceof Array) {
      if (!(a instanceof Array) || !(b instanceof Array) || a.length !== b.length) return false;
      for (var i = 0; i < a.length; i++) if (!sameJson(a[i], b[i])) return false;
      return true;
    }
    if (isObj(a) && isObj(b)) {
      var ak = [], bk = [], k;
      for (k in a) if (own(a, k)) ak.push(k);
      for (k in b) if (own(b, k)) bk.push(k);
      if (ak.length !== bk.length) return false;
      for (i = 0; i < ak.length; i++) {
        k = ak[i];
        if (!own(b, k) || !sameJson(a[k], b[k])) return false;
      }
      return true;
    }
    return false;
  }

  function normalizeRuleEditor(rule) {
    rule = isObj(rule) ? rule : {};
    var when = isObj(rule.when) ? rule.when : {};
    var schedule = isObj(rule.schedule) ? rule.schedule : null;
    return {
      enabled: rule.enabled !== false,
      whenType: typeof when.type === "string" && when.type ? when.type : "button",
      doors: when.doors instanceof Array ? cloneJson(when.doors) : [],
      devices: when.devices === "all" ? "all" :
               (when.devices instanceof Array ? cloneJson(when.devices) : "all"),
      always: !schedule || schedule.always === true || !(schedule.windows instanceof Array),
      windows: schedule && schedule.windows instanceof Array ? cloneJson(schedule.windows) : [],
      actions: rule.actions instanceof Array ? cloneJson(rule.actions) : []
    };
  }

  function mergeRuleEditor(original, editor) {
    var hasOriginal = isObj(original);
    var out = hasOriginal ? cloneJson(original) : {};
    var before = normalizeRuleEditor(hasOriginal ? original : {});
    editor = editor || {};

    var enabled = own(editor, "enabled") ? editor.enabled !== false : before.enabled;
    if (!hasOriginal || enabled !== before.enabled) out.enabled = enabled;

    var whenType = own(editor, "whenType") && editor.whenType ? editor.whenType :
                   (before.whenType || "button");
    var when = isObj(out.when) ? out.when : {};
    if (!hasOriginal || whenType !== before.whenType || !isObj(out.when)) when.type = whenType;
    if (whenType === "device_offline") {
      var editorDevices = own(editor, "devices") ? editor.devices : before.devices;
      var devices = editorDevices === "all" ? "all" :
                    (editorDevices instanceof Array ? cloneJson(editorDevices) : "all");
      if (!hasOriginal || !sameJson(devices, before.devices)) when.devices = devices;
    } else if (whenType === "button" || whenType === "motion") {
      var doors = own(editor, "doors") && editor.doors instanceof Array ? cloneJson(editor.doors) :
                  cloneJson(before.doors);
      if (!hasOriginal || !sameJson(doors, before.doors)) {
        if (doors.length) when.doors = doors;
        else delete when.doors;
      }
    }
    out.when = when;

    var always = own(editor, "always") ? editor.always !== false : before.always;
    var windows = own(editor, "windows") && editor.windows instanceof Array ?
                  cloneJson(editor.windows) : cloneJson(before.windows);
    if (!hasOriginal || always !== before.always || (!always && !sameJson(windows, before.windows))) {
      var schedule = isObj(out.schedule) ? out.schedule : {};
      if (always) {
        schedule.always = true;
        delete schedule.windows;
      } else {
        delete schedule.always;
        schedule.windows = windows;
      }
      out.schedule = schedule;
    }

    var actions = own(editor, "actions") && editor.actions instanceof Array ?
                  cloneJson(editor.actions) : cloneJson(before.actions);
    if (!hasOriginal || !sameJson(actions, before.actions)) out.actions = actions;
    return out;
  }

  function ruleEntries(id, f, original) {
    return [{ key: "trigger_rules." + id, value: mergeRuleEditor(original, f) }];
  }

  function selector(value) {
    if (value === "all") return { specified: true, all: true, values: [] };
    if (typeof value === "string" && value) return { specified: true, all: false, values: [value] };
    if (value instanceof Array) {
      if (value.indexOf("all") >= 0) return { specified: true, all: true, values: [] };
      return { specified: true, all: false, values: value.slice() };
    }
    return { specified: false, all: false, values: [] };
  }

  function selectorMatches(value, candidate) {
    var s = selector(value);
    return !s.specified || s.all || s.values.indexOf(candidate) >= 0;
  }

  function effectiveAlertChannels(action) {
    return action && action.channels instanceof Array ? action.channels.slice() : ["in_app"];
  }

  function peerAlertChannelState(peer, channel) {
    peer = isObj(peer) ? peer : {};
    var caps = isObj(peer.caps) ? peer.caps :
               (isObj(peer.capabilities) ? peer.capabilities : {});
    var declared = caps.device_alert_channels instanceof Array ?
                   caps.device_alert_channels : null;
    var supportRoot = isObj(caps.device_alert_channel_support) ?
                      caps.device_alert_channel_support : {};
    var support = isObj(supportRoot.channels) && isObj(supportRoot.channels[channel]) ?
                  supportRoot.channels[channel] : null;
    if (support) {
      var status = String(support.status || "");
      if (support.supported === false || status === "unsupported")
        return { status: "unsupported", permission: support.permission || "not_applicable" };
      if (support.available === false || status === "unavailable" ||
          support.permission === "denied" || support.permission === "required")
        return { status: "unavailable", permission: support.permission || "unknown" };
      if (support.supported === true || support.available === true || status === "available")
        return { status: "supported", permission: support.permission || "unknown" };
    }
    if (declared)
      return { status: declared.indexOf(channel) >= 0 ? "supported" : "unsupported",
               permission: "unknown" };
    return { status: "unknown", permission: "unknown" };
  }

  function validateAlertPresentation(presentation) {
    var p = isObj(presentation) ? presentation : {};
    var colors = {
      background: own(p, "background") ? p.background : "#8F1010",
      foreground: own(p, "foreground") ? p.foreground : "#FFFFFF",
      accent: own(p, "accent") ? p.accent : "#FFD166"
    };
    var errors = [];
    for (var name in colors) if (own(colors, name) && !colorOk(colors[name]))
      errors.push(name + " requires #RRGGBB");
    if (!errors.length && contrast(colors.foreground, colors.background) < 4.5)
      errors.push("SOS text contrast must be at least 4.5:1");
    if (!errors.length && contrast(colors.accent, colors.background) < 3)
      errors.push("SOS accent contrast must be at least 3:1");
    return { ok: errors.length === 0, errors: errors, colors: colors };
  }

  function subscriptionRecords(config) {
    var records = config && config.web_push && config.web_push.subscriptions;
    var out = [], k;
    if (records instanceof Array) return records.slice();
    if (isObj(records)) for (k in records) if (own(records, k) && isObj(records[k])) out.push(records[k]);
    return out;
  }

  function sosDryRunPreview(rule, status, config) {
    rule = isObj(rule) ? rule : {};
    status = isObj(status) ? status : {};
    config = isObj(config) ? config : {};
    var whenType = rule.when && rule.when.type;
    var preview = { is_sos: whenType === "emergency_on" || whenType === "emergency_off",
      trigger: whenType || "", actions: [], target_devices: [], target_roles: [],
      target_web_subscription_groups: [], offline_devices: [], channels: [],
      unsupported_device_channels: [], unavailable_device_channels: [],
      unknown_device_channels: [], local_recipients: 0, capable_local_recipients: 0,
      web_push_recipients: null, recipients_known: true };
    if (!preview.is_sos) return preview;

    var peers = status.peers instanceof Array ? status.peers.slice() : [];
    if (status.node && status.node.id) {
      var hasSelf = false;
      for (var spi = 0; spi < peers.length; spi++)
        if (peers[spi] && peers[spi].id === status.node.id) hasSelf = true;
      if (!hasSelf) peers.push({ id: status.node.id, role: status.node.role, status: "alive",
                                self: true, caps: status.node.caps || {} });
    }
    var records = subscriptionRecords(config);
    var pushStatus = isObj(status.web_push) ? status.web_push : {};
    var seenDevices = {}, seenRoles = {}, seenGroups = {}, seenChannels = {}, seenOffline = {};
    var localRecipients = {}, capableLocalRecipients = {}, webCount = 0, webKnown = true;
    var unsupportedChannels = {}, unavailableChannels = {}, unknownChannels = {};
    var actions = rule.actions instanceof Array ? rule.actions : [];
    for (var ai = 0; ai < actions.length; ai++) {
      var action = actions[ai];
      if (!isObj(action) || action.type !== "device_alert") continue;
      var hasTargetsObject = isObj(action.targets);
      var targets = hasTargetsObject ? action.targets : action;
      var devices = selector(targets.devices), roles = selector(targets.roles);
      var groupValue = own(targets, "web_subscription_groups") ?
                       targets.web_subscription_groups : targets.web_profiles;
      var groups = selector(groupValue);
      var channels = effectiveAlertChannels(action);
      var actionPreview = { index: ai, devices: cloneJson(targets.devices),
        roles: cloneJson(targets.roles), web_subscription_groups: cloneJson(groupValue),
        channels: channels.slice(), matched_devices: [], offline_devices: [],
        device_channel_results: [], web_push_recipients: null };
      if (devices.all) seenDevices.all = true;
      for (var di = 0; di < devices.values.length; di++) seenDevices[devices.values[di]] = true;
      if (roles.all) seenRoles.all = true;
      for (var ri = 0; ri < roles.values.length; ri++) seenRoles[roles.values[ri]] = true;
      if (groups.all || (!hasTargetsObject && !groups.specified)) seenGroups.all = true;
      for (var gi = 0; gi < groups.values.length; gi++) seenGroups[groups.values[gi]] = true;
      for (var ci = 0; ci < channels.length; ci++) seenChannels[channels[ci]] = true;

      var hasLocalSelector = devices.specified || roles.specified;
      var legacyAllLocal = !hasTargetsObject && !hasLocalSelector;
      for (var pi = 0; pi < peers.length; pi++) {
        var peer = peers[pi] || {}, id = String(peer.id || ""), role = String(peer.role || "");
        if (!id) continue;
        var matches = legacyAllLocal ||
                      (devices.specified && selectorMatches(targets.devices, id)) ||
                      (roles.specified && selectorMatches(targets.roles, role));
        if (!matches) continue;
        actionPreview.matched_devices.push(id);
        var requestedLocal = [];
        if (channels.indexOf("in_app") >= 0) requestedLocal.push("in_app");
        if (channels.indexOf("system_notification") >= 0)
          requestedLocal.push("system_notification");
        if (requestedLocal.length)
          localRecipients[id] = true;
        var hasCapableChannel = false;
        for (var lci = 0; lci < requestedLocal.length; lci++) {
          var localChannel = requestedLocal[lci];
          var channelState = peerAlertChannelState(peer, localChannel);
          var channelKey = id + ":" + localChannel;
          actionPreview.device_channel_results.push({ device_id: id, channel: localChannel,
            status: channelState.status, permission: channelState.permission });
          if (channelState.status === "supported") hasCapableChannel = true;
          else if (channelState.status === "unsupported") unsupportedChannels[channelKey] = true;
          else if (channelState.status === "unavailable") unavailableChannels[channelKey] = true;
          else { unknownChannels[channelKey] = true; hasCapableChannel = true; }
        }
        if (hasCapableChannel) capableLocalRecipients[id] = true;
        if (peer.status !== "alive") {
          actionPreview.offline_devices.push(id);
          seenOffline[id] = true;
        }
      }
      for (di = 0; di < devices.values.length; di++) {
        var wanted = devices.values[di], found = false;
        for (pi = 0; pi < peers.length; pi++) if (peers[pi] && peers[pi].id === wanted) found = true;
        if (!found) { actionPreview.offline_devices.push(wanted); seenOffline[wanted] = true; }
      }

      if (channels.indexOf("web_push") >= 0) {
        var legacyAllWeb = !hasTargetsObject && !groups.specified;
        if (records.length) {
          var matched = 0;
          for (var si = 0; si < records.length; si++) {
            var group = records[si].group || "all";
            if (legacyAllWeb || groups.all || groups.values.indexOf(group) >= 0) matched++;
          }
          actionPreview.web_push_recipients = matched;
          webCount += matched;
        } else if (typeof pushStatus.subscriptions === "number") {
          if (legacyAllWeb || groups.all) {
            actionPreview.web_push_recipients = pushStatus.subscriptions;
            webCount += pushStatus.subscriptions;
          } else if (!groups.specified) {
            actionPreview.web_push_recipients = 0;
          } else {
            actionPreview.web_push_recipients = pushStatus.subscriptions === 0 ? 0 : null;
            if (pushStatus.subscriptions > 0) webKnown = false;
          }
        } else {
          webKnown = false;
        }
      }
      preview.actions.push(actionPreview);
    }
    for (var dk in localRecipients) if (own(localRecipients, dk)) preview.local_recipients++;
    for (dk in capableLocalRecipients) if (own(capableLocalRecipients, dk))
      preview.capable_local_recipients++;
    preview.web_push_recipients = webKnown ? webCount : null;
    preview.recipients_known = webKnown;
    function keysWithoutAll(o) {
      var a = [];
      if (o.all) a.push("all");
      for (var k in o) if (own(o, k) && k !== "all") a.push(k);
      return a;
    }
    preview.target_devices = keysWithoutAll(seenDevices);
    preview.target_roles = keysWithoutAll(seenRoles);
    preview.target_web_subscription_groups = keysWithoutAll(seenGroups);
    preview.offline_devices = keysWithoutAll(seenOffline);
    preview.unsupported_device_channels = keysWithoutAll(unsupportedChannels);
    preview.unavailable_device_channels = keysWithoutAll(unavailableChannels);
    preview.unknown_device_channels = keysWithoutAll(unknownChannels);
    preview.channels = keysWithoutAll(seenChannels);
    return preview;
  }

  function sosRuleWarnings(rule, status, config) {
    var preview = sosDryRunPreview(rule, status, config), warnings = [];
    if (!preview.is_sos) return warnings;
    var actions = rule && rule.actions instanceof Array ? rule.actions : [];
    var alertActions = [], channels = {}, visuallyOrAudiblyPresented = false;
    for (var i = 0; i < actions.length; i++) if (actions[i] && actions[i].type === "device_alert") {
      var action = actions[i], ch = effectiveAlertChannels(action), p = isObj(action.presentation) ?
                   action.presentation : {};
      alertActions.push(action);
      for (var j = 0; j < ch.length; j++) channels[ch[j]] = true;
      var defaultSound = preview.trigger === "emergency_on" && !own(p, "sound");
      var audible = (defaultSound || !!p.sound) && Number(own(p, "volume") ? p.volume : 100) > 0;
      var visual = own(p, "visual") ? p.visual !== false : true;
      if ((ch.indexOf("in_app") >= 0 && (visual || audible)) ||
          ch.indexOf("system_notification") >= 0 || ch.indexOf("web_push") >= 0)
        visuallyOrAudiblyPresented = true;
    }
    if (!alertActions.length) warnings.push({ code: "no_device_alert" });
    var totalKnown = preview.local_recipients + (preview.web_push_recipients || 0);
    if (preview.recipients_known && totalKnown === 0)
      warnings.push({ code: "zero_recipients" });
    if (!preview.channels.length || !visuallyOrAudiblyPresented)
      warnings.push({ code: "all_channels_silent" });
    if (channels.web_push) {
      var push = status && isObj(status.web_push) ? status.web_push : {};
      if (push.subscriptions === 0 || preview.web_push_recipients === 0)
        warnings.push({ code: "no_web_push_subscriptions" });
      if (push.delivery_backend !== true)
        warnings.push({ code: "web_push_backend_unavailable" });
    }
    if (preview.offline_devices.length)
      warnings.push({ code: "offline_devices", devices: preview.offline_devices.slice() });
    if (preview.unsupported_device_channels.length)
      warnings.push({ code: "unsupported_device_channels",
                      channels: preview.unsupported_device_channels.slice() });
    if (preview.unavailable_device_channels.length)
      warnings.push({ code: "unavailable_device_channels",
                      channels: preview.unavailable_device_channels.slice() });
    if (preview.unknown_device_channels.length)
      warnings.push({ code: "unknown_device_channels",
                      channels: preview.unknown_device_channels.slice() });
    return warnings;
  }

  function callFlowMode(value) {
    if (isObj(value)) value = value.mode;
    return value === "ring_then_purpose" ? value : "purpose_first";
  }

  function featureMapForPeer(peer, status) {
    if (peer && peer.self && status && isObj(status.features)) return status.features;
    if (peer && isObj(peer.features)) return peer.features;
    if (peer && isObj(peer.capabilities) && isObj(peer.capabilities.features))
      return peer.capabilities.features;
    if (peer && isObj(peer.caps) && isObj(peer.caps.features)) return peer.caps.features;
    return {};
  }

  function callFlowCompatibility(value, status) {
    var mode = callFlowMode(value), peers = status && status.peers instanceof Array ?
                status.peers.slice() : [];
    if (!peers.length && status && status.node && status.node.id)
      peers.push({ id: status.node.id, name: status.node.name, role: status.node.role,
                   self: true, status: "alive" });
    var out = { mode: mode, total: peers.length, supported: [], unsupported: [] };
    for (var i = 0; i < peers.length; i++) {
      var peer = peers[i] || {}, id = peer.id || peer.name || "unknown";
      if (featureMapForPeer(peer, status).call_flow_v2 === true) out.supported.push(id);
      else out.unsupported.push(id);
    }
    out.warning = mode === "ring_then_purpose" && out.unsupported.length > 0;
    out.unknown_fleet = mode === "ring_then_purpose" && out.total === 0;
    return out;
  }


  function mqttEntries(f) {
    var e = [{ key: "integrations.mqtt.host", value: String(f.host || "") },
             { key: "integrations.mqtt.port", value: num(f.port, 1883) },
             { key: "integrations.mqtt.user", value: String(f.user || "") }];
    if (f.pass_ref) e.push({ key: "integrations.mqtt.pass_ref", value: String(f.pass_ref) });
    return e;
  }

  function telegramEntries(f) {
    var e = [{ key: "integrations.telegram.poll_updates", value: !!f.poll_updates }];
    if (f.bot_token_ref)
      e.push({ key: "integrations.telegram.bot_token_ref", value: String(f.bot_token_ref) });
    return e;
  }

  function webPushEntries(f) {
    return [
      { key: "integrations.web_push.sender_url", value: String(f.sender_url || "") },
      { key: "integrations.web_push.vapid_public_key",
        value: String(f.vapid_public_key || "") },
      { key: "integrations.web_push.vapid_subject", value: String(f.vapid_subject || "") },
      { key: "integrations.web_push.vapid_private_key_ref",
        value: String(f.vapid_private_key_ref || "") },
      { key: "integrations.web_push.sender_secret_ref",
        value: String(f.sender_secret_ref || "") }
    ];
  }

  function sipEntries(f) {
    return [{ key: "sip.server", value: String(f.server || "") },
            { key: "sip.port", value: num(f.port, 5060) },
            { key: "sip.transport", value: f.transport || "udp" }];
  }

  function secretWrite(secretRef, value) {
    return value ? { secret_ref: secretRef, value: String(value) } : null;
  }

  function localSecretProvisionPlan(secretRef, value) {
    var write = secretWrite(secretRef, value);
    return { entries: [], secrets: write ? [write] : [], retire_secret_refs: [] };
  }

  function panelProvisionPayload(secretRef, token) {
    return { secret_ref: String(secretRef || ""), token: String(token || "") };
  }

  function canEditSipSecret(targetNodeId, servingNodeId) {
    return !!targetNodeId && targetNodeId === servingNodeId;
  }

  var secretRefCounter = 0;
  function freshSecretRef(scope) {
    var bytes = null, token = "";
    try {
      var cryptoApi = typeof crypto !== "undefined" ? crypto : null;
      if (cryptoApi && cryptoApi.getRandomValues) {
        bytes = new Uint8Array(12);
        cryptoApi.getRandomValues(bytes);
      }
    } catch (e) { bytes = null; }
    if (bytes) {
      for (var i = 0; i < bytes.length; i++) token += (bytes[i] + 256).toString(16).slice(-2);
    } else {
      secretRefCounter++;
      token = Date.now().toString(16) + secretRefCounter.toString(16) +
              Math.floor(Math.random() * 0x100000000).toString(16);
    }
    return "secret:" + safeId(scope) + "." + token;
  }

  function mqttPlan(f, existing) {
    existing = existing || {};
    var value = f.pass || existing.pass || "";
    var oldRef = existing.pass_ref || "";
    var ref = value ? freshSecretRef("mqtt") : oldRef;
    return { entries: mqttEntries({ host: f.host, port: f.port, user: f.user,
                                    pass_ref: value ? ref : existing.pass_ref }),
             secrets: value ? [secretWrite(ref, value)] : [],
             retire_secret_refs: value && oldRef && oldRef !== ref ? [oldRef] : [] };
  }

  function telegramPlan(f, existing) {
    existing = existing || {};
    var value = f.bot_token || existing.bot_token || "";
    var oldRef = existing.bot_token_ref || "";
    var ref = value ? freshSecretRef("telegram.bot") : oldRef;
    return { entries: telegramEntries({ poll_updates: f.poll_updates,
                                        bot_token_ref: value ? ref : existing.bot_token_ref }),
             secrets: value ? [secretWrite(ref, value)] : [],
             retire_secret_refs: value && oldRef && oldRef !== ref ? [oldRef] : [] };
  }

  function webPushPlan(f, existing) {
    existing = existing || {};
    var privateValue = String(f.vapid_private_key || "");
    var oldPrivateRef = String(existing.vapid_private_key_ref || "");
    var privateRef = privateValue ? freshSecretRef("webpush.vapid_private") : oldPrivateRef;
    var bearerEnabled = !!f.sender_bearer_enabled;
    var bearerValue = bearerEnabled ? String(f.sender_secret || "") : "";
    var oldBearerRef = String(existing.sender_secret_ref || "");
    var bearerRef = bearerEnabled ?
      (bearerValue ? freshSecretRef("webpush.sender") : oldBearerRef) : "";
    var secrets = [];
    var retire = [];
    if (privateValue) {
      secrets.push(secretWrite(privateRef, privateValue));
      if (oldPrivateRef && oldPrivateRef !== privateRef) retire.push(oldPrivateRef);
    }
    if (bearerValue) {
      secrets.push(secretWrite(bearerRef, bearerValue));
      if (oldBearerRef && oldBearerRef !== bearerRef) retire.push(oldBearerRef);
    } else if (!bearerEnabled && oldBearerRef) {
      retire.push(oldBearerRef);
    }
    return {
      entries: webPushEntries({
        sender_url: f.sender_url,
        vapid_public_key: f.vapid_public_key,
        vapid_subject: f.vapid_subject,
        vapid_private_key_ref: privateRef,
        sender_secret_ref: bearerRef
      }),
      secrets: secrets,
      retire_secret_refs: retire
    };
  }

  // SIP accounts are whole values, so clone unknown fields and replace only edited credentials.
  function sipAccountEntries(nodeId, user, pass, existing) {
    var v = {}, k;
    existing = existing || {};
    for (k in existing) if (k !== "pass") v[k] = existing[k];
    v.user = String(user || "");
    if (pass || existing.pass) v.pass_ref = existing.pass_ref || "secret:sip." + safeId(nodeId);
    return [{ key: "sip.accounts." + nodeId, value: v }];
  }

  function sipAccountPlan(nodeId, user, pass, existing) {
    existing = existing || {};
    var value = pass || existing.pass || "";
    var entries = sipAccountEntries(nodeId, user, value, existing);
    var oldRef = existing.pass_ref || "", ref = oldRef;
    if (value) {
      ref = freshSecretRef("sip." + safeId(nodeId));
      entries[0].value.pass_ref = ref;
    }
    return { entries: entries, secrets: value ? [secretWrite(ref, value)] : [],
             retire_secret_refs: value && oldRef && oldRef !== ref ? [oldRef] : [] };
  }

  function mergeSecretPlans(entries, plans) {
    var merged = { entries: (entries || []).slice(), secrets: [], retire_secret_refs: [] };
    (plans || []).forEach(function (plan) {
      if (!plan) return;
      merged.entries = merged.entries.concat(plan.entries || []);
      merged.secrets = merged.secrets.concat(plan.secrets || []);
      merged.retire_secret_refs = merged.retire_secret_refs.concat(plan.retire_secret_refs || []);
    });
    return merged;
  }


  /* ---------------- Batch 2: time, volumes, announcements, SOS, battery ---------------- */

  /* The zones core can actually resolve. Core rejects anything outside its bundled table, so a
   * zone offered here that core does not know would be a select the operator cannot save.
   * webui/tests/settings.test.js checks this list against core/src/util/tz.cpp. */
  var TIME_ZONES = [
    "UTC", "Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Macau",
    "Asia/Taipei", "Asia/Manila", "Asia/Singapore", "Asia/Kuala_Lumpur", "Asia/Vladivostok",
    "Asia/Bangkok", "Asia/Jakarta", "Asia/Ho_Chi_Minh", "Asia/Yangon", "Asia/Dhaka",
    "Asia/Kathmandu", "Asia/Kolkata", "Asia/Colombo", "Asia/Karachi", "Asia/Tashkent",
    "Asia/Almaty", "Asia/Dubai", "Asia/Baku", "Asia/Tehran", "Asia/Baghdad", "Asia/Qatar",
    "Asia/Riyadh", "Asia/Jerusalem", "Europe/London", "Europe/Dublin", "Europe/Lisbon",
    "Europe/Madrid", "Europe/Paris", "Europe/Brussels", "Europe/Amsterdam", "Europe/Berlin",
    "Europe/Zurich", "Europe/Vienna", "Europe/Rome", "Europe/Prague", "Europe/Warsaw",
    "Europe/Budapest", "Europe/Stockholm", "Europe/Oslo", "Europe/Copenhagen", "Europe/Helsinki",
    "Europe/Athens", "Europe/Bucharest", "Europe/Sofia", "Europe/Kyiv", "Europe/Riga",
    "Europe/Tallinn", "Europe/Vilnius", "Europe/Istanbul", "Europe/Minsk", "Europe/Moscow",
    "America/St_Johns", "America/Halifax", "America/New_York", "America/Toronto",
    "America/Panama", "America/Bogota", "America/Lima", "America/Chicago", "America/Winnipeg",
    "America/Mexico_City", "America/Denver", "America/Edmonton", "America/Phoenix",
    "America/Los_Angeles", "America/Vancouver", "America/Anchorage", "America/Caracas",
    "America/Santiago", "America/Sao_Paulo", "America/Montevideo",
    "America/Argentina/Buenos_Aires", "Australia/Perth", "Australia/Darwin",
    "Australia/Adelaide", "Australia/Brisbane", "Australia/Sydney", "Australia/Melbourne",
    "Australia/Hobart", "Pacific/Port_Moresby", "Pacific/Guam", "Pacific/Auckland",
    "Pacific/Fiji", "Pacific/Honolulu", "Africa/Accra", "Africa/Casablanca", "Africa/Lagos",
    "Africa/Johannesburg", "Africa/Nairobi", "Atlantic/Reykjavik", "Atlantic/Azores"
  ];

  /* Region -> zones, in table order, for a grouped <select>. */
  function timeZoneGroups() {
    var groups = [], index = {};
    for (var i = 0; i < TIME_ZONES.length; i++) {
      var id = TIME_ZONES[i], slash = id.indexOf("/");
      var region = slash < 0 ? id : id.slice(0, slash);
      if (index[region] === undefined) {
        index[region] = groups.length;
        groups.push({ region: region, zones: [] });
      }
      groups[index[region]].zones.push(id);
    }
    return groups;
  }

  function timeZoneLabel(id) {
    var slash = String(id == null ? "" : id).indexOf("/");
    return slash < 0 ? String(id) : String(id).slice(slash + 1).replace(/_/g, " ");
  }

  /* Parse the server textarea: one "host" or "host:port" per line, at most four. Returns null
   * when an entry cannot be a server, so the form can refuse instead of core rejecting it. */
  function ntpServerList(text) {
    var raw = String(text == null ? "" : text).split(/[\r\n,]+/), out = [];
    for (var i = 0; i < raw.length; i++) {
      var entry = raw[i].replace(/^\s+|\s+$/g, "");
      if (!entry) continue;
      if (out.length >= 4) return null;
      if (!/^\[[0-9a-fA-F:]+\](:[0-9]{1,5})?$/.test(entry) &&
          !/^[A-Za-z0-9._:-]+$/.test(entry)) return null;
      var colon = entry.lastIndexOf(":");
      if (entry.charAt(0) !== "[" && colon > 0 && entry.indexOf(":") === colon) {
        var port = entry.slice(colon + 1);
        if (!/^[0-9]{1,5}$/.test(port) || +port < 1 || +port > 65535) return null;
      }
      out.push(entry);
    }
    return out.length ? out : null;
  }

  /* Core owns integrations.tz_offset_min once a zone is set, so the form never writes it. */
  function timeEntries(f) {
    var servers = ntpServerList(f.servers);
    if (TIME_ZONES.indexOf(String(f.zone)) < 0) throw new Error("zone");
    if (!servers) throw new Error("servers");
    var interval = Math.round(num(f.interval_s, 900));
    if (interval < 60 || interval > 86400) throw new Error("interval_s");
    return [{ key: "time.zone", value: String(f.zone) },
            { key: "time.ntp.enabled", value: !!f.ntp_enabled },
            { key: "time.ntp.servers", value: servers },
            { key: "time.ntp.interval_s", value: interval }];
  }

  /* What the time card renders. source is reported by core and is never inferred from enabled:
   * an enabled but unreachable time service is still running on the device clock. */
  function timeStatusModel(status) {
    var time = isObj(status) && isObj(status.time) ? status.time : {};
    var source = time.source === "ntp" ? "ntp" : "system";
    var errors = { no_response: "time.err_no_response", bad_server: "time.err_bad_server",
                   bad_reply: "time.err_bad_reply", implausible: "time.err_implausible" };
    return {
      zone: typeof time.zone === "string" ? time.zone : "",
      zoneKnown: time.zone_known !== false,
      enabled: time.enabled === true,
      source: source,
      degraded: time.enabled === true && source !== "ntp",
      offsetMs: num(time.offset_ms, 0),
      measuredOffsetMs: num(time.measured_offset_ms, 0),
      lastSyncMs: num(time.last_sync_ms, 0),
      rttMs: num(time.rtt_ms, 0),
      server: typeof time.server === "string" ? time.server : "",
      intervalS: num(time.interval_s, 900),
      syncing: time.syncing === true,
      errorKey: typeof time.err === "string" && errors[time.err] ? errors[time.err] : "",
      localIso: isObj(time.local) && typeof time.local.iso === "string" ? time.local.iso : ""
    };
  }

  var VOLUME_LEVELS = ["call", "sos", "idle"];
  var VOLUME_DEFAULTS = { call: 80, sos: 100, idle: 60 };

  function volumeLevel(container, level) {
    if (!isObj(container)) return undefined;
    var value = container[level];
    if (typeof value !== "number" || value < 0 || value > 100) return undefined;
    return Math.round(value);
  }

  function clampVolume(value, fallback) {
    var n = Math.round(num(value, fallback));
    if (!(n >= 0)) n = 0;
    if (n > 100) n = 100;
    return n;
  }

  function volumeEntries(f) {
    var entries = [];
    for (var i = 0; i < VOLUME_LEVELS.length; i++) {
      var level = VOLUME_LEVELS[i];
      entries.push({ key: "audio.volume." + level,
                     value: clampVolume(f[level], VOLUME_DEFAULTS[level]) });
    }
    return entries;
  }

  /* Inheriting again deletes the leaf keys rather than writing nulls, which is what core's
   * device-override resolution expects. */
  function deviceVolumeEntries(id, f) {
    var entries = [], dels = [], i, level;
    if (f.inherit) {
      for (i = 0; i < VOLUME_LEVELS.length; i++)
        dels.push("devices." + id + ".local.audio.volume." + VOLUME_LEVELS[i]);
      return { entries: entries, dels: dels };
    }
    for (i = 0; i < VOLUME_LEVELS.length; i++) {
      level = VOLUME_LEVELS[i];
      entries.push({ key: "devices." + id + ".local.audio.volume." + level,
                     value: clampVolume(f[level], VOLUME_DEFAULTS[level]) });
    }
    return { entries: entries, dels: dels };
  }

  /* Mirrors db_core_audio_json: device override, then cluster default, then the built-in level,
   * with emergency.alarm_volume as the extra fallback for SOS. */
  function effectiveVolumes(cfg, deviceId) {
    cfg = isObj(cfg) ? cfg : {};
    var device = isObj(cfg.devices) ? cfg.devices[deviceId] : null;
    var local = isObj(device) && isObj(device.local) ? device.local : {};
    var deviceVolume = isObj(local.audio) ? local.audio.volume : null;
    var clusterVolume = isObj(cfg.audio) ? cfg.audio.volume : null;
    var alarm = isObj(cfg.emergency) ? volumeLevel(cfg.emergency, "alarm_volume") : undefined;
    var out = { device: String(deviceId || ""), sources: {}, source: "default" };
    var strongest = "default";
    for (var i = 0; i < VOLUME_LEVELS.length; i++) {
      var level = VOLUME_LEVELS[i];
      var fallback = level === "sos" && alarm !== undefined ? alarm : VOLUME_DEFAULTS[level];
      var value = volumeLevel(deviceVolume, level), source = "device";
      if (value === undefined) { value = volumeLevel(clusterVolume, level); source = "cluster"; }
      if (value === undefined) { value = fallback; source = "default"; }
      out[level] = value;
      out.sources[level] = source;
      if (source === "device") strongest = "device";
      else if (source === "cluster" && strongest !== "device") strongest = "cluster";
    }
    out.source = strongest;
    return out;
  }

  var NOTICE_MAX_CHARS = 200;
  var NOTICE_PRESET_KEYS = ["notice.preset_absent", "notice.preset_delivery",
                            "notice.preset_construction"];
  var NOTICE_EXPIRY_PRESETS = ["1h", "today", "until_cleared", "custom"];

  /* Absolute deadline for one expiry preset. 0 means "until cleared". "today" is the end of the
   * local day at the cluster's offset, which is the boundary the operator has in mind. */
  function noticeExpiryMs(preset, nowMs, offsetMin, customHours) {
    var now = num(nowMs, 0);
    if (preset === "until_cleared") return 0;
    if (preset === "1h") return now + 3600000;
    if (preset === "custom") {
      var hours = num(customHours, 0);
      if (!(hours > 0) || hours > 8760) return -1;
      return now + Math.round(hours * 3600000);
    }
    if (preset === "today") {
      var offset = num(offsetMin, 0) * 60000;
      var local = now + offset;
      var dayStart = Math.floor(local / 86400000) * 86400000;
      return dayStart + 86400000 - offset;
    }
    return -1;
  }

  /* The POST body for /api/doors/<id>/notice, or {error:"..."} for a message the form refuses. */
  function noticePayload(f, nowMs, offsetMin) {
    var text = String(f.text == null ? "" : f.text).replace(/^\s+|\s+$/g, "");
    var length = countCharacters(text);
    if (!length) return { error: "notice.empty" };
    if (length > NOTICE_MAX_CHARS) return { error: "notice.too_long", n: length };
    var expires = noticeExpiryMs(f.expiry, nowMs, offsetMin, f.custom_hours);
    if (expires < 0) return { error: "notice.expiry_custom" };
    return { body: { text: text, expires_ms: expires } };
  }

  /* Unicode code points, so a Japanese announcement is counted the way core counts it. */
  function countCharacters(text) {
    var s = String(text == null ? "" : text), count = 0;
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) i++;
      count++;
    }
    return count;
  }

  /* What the door row and the editor render for one door's announcement. */
  function noticeModel(door, doorsCfg, nowMs) {
    var entry = isObj(doorsCfg) ? doorsCfg[door] : null;
    var notice = isObj(entry) && isObj(entry.notice) ? entry.notice : null;
    if (!notice || typeof notice.text !== "string" || !notice.text)
      return { active: false, text: "", expiresMs: 0, from: "", createdMs: 0, expired: false };
    var expires = num(notice.expires_ms, 0);
    return {
      active: true,
      text: notice.text,
      from: typeof notice.from_device === "string" ? notice.from_device : "",
      createdMs: num(notice.created_ms, 0),
      expiresMs: expires,
      expired: expires > 0 && num(nowMs, 0) >= expires
    };
  }

  var SOS_TRIGGER_MODES = ["slide", "hold"];

  function sosEntries(f, existingEmergency) {
    var mode = SOS_TRIGGER_MODES.indexOf(String(f.mode)) >= 0 ? String(f.mode) : "slide";
    var countdown = Math.round(num(f.countdown_s, 3));
    if (countdown < 0) countdown = 0;
    if (countdown > 10) countdown = 10;
    var volume = clampVolume(f.alarm_volume,
      volumeLevel(editableClone(existingEmergency), "alarm_volume") === undefined ? 100 :
        volumeLevel(editableClone(existingEmergency), "alarm_volume"));
    var roles = f.button_on_roles instanceof Array ? f.button_on_roles.slice() : [];
    return [{ key: "emergency.trigger.mode", value: mode },
            { key: "emergency.trigger.countdown_s", value: countdown },
            { key: "emergency.button_on_roles", value: roles },
            { key: "emergency.cancel_requires_pin", value: f.cancel_requires_pin !== false },
            { key: "emergency.alarm_sound", value: String(f.alarm_sound || "siren1") },
            { key: "emergency.alarm_volume", value: volume }];
  }

  /* Battery for the version line and the dashboard column. A device that does not report power
   * has no row at all, which is not the same as a battery at zero. */
  function powerModel(power) {
    if (!isObj(power)) return { known: false, hasBattery: false, pct: -1,
                                charging: false, mains: false, text: "" };
    var pct = Math.round(num(power.battery_pct, -1));
    var hasBattery = pct >= 0;
    if (pct > 100) pct = 100;
    return {
      known: true,
      hasBattery: hasBattery,
      pct: pct,
      charging: power.charging === true,
      mains: power.mains === true,
      text: hasBattery ? pct + "%" : ""
    };
  }


  /* ---------------- Batch 2 round 2/4: appearance, auto theme, notices, unlock ------------- */

  /* The semantic text regions core publishes an automatic ink decision for. Mirrors kInkRegions
   * in core/src/node/node.cpp; webui/tests/settings.test.js checks the two lists match. */
  var INK_REGIONS = ["clock", "date", "status_line", "hint", "tile_label", "footer", "notice"];
  var APPEARANCE_MODES = ["auto_system", "auto_schedule", "light", "dark"];

  function rgbOf(hex) {
    if (!colorOk(hex)) return null;
    return { r: parseInt(hex.substr(1, 2), 16), g: parseInt(hex.substr(3, 2), 16),
             b: parseInt(hex.substr(5, 2), 16) };
  }
  function hexOf(rgb) {
    function pair(v) {
      var n = Math.max(0, Math.min(255, Math.round(v)));
      return (n < 16 ? "0" : "") + n.toString(16).toUpperCase();
    }
    return "#" + pair(rgb.r) + pair(rgb.g) + pair(rgb.b);
  }

  function toHsl(rgb) {
    var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b), delta = max - min;
    var l = (max + min) / 2;
    if (delta <= 0) return { h: 0, s: 0, l: l };
    var s = l > 0.5 ? delta / (2 - max - min) : delta / (max + min);
    var h;
    if (max === r) h = 60 * (((g - b) / delta + 6) % 6);
    else if (max === g) h = 60 * ((b - r) / delta + 2);
    else h = 60 * ((r - g) / delta + 4);
    return { h: h, s: s, l: l };
  }

  function fromHsl(hsl) {
    var h = (((hsl.h % 360) + 360) % 360) / 360;
    var s = Math.max(0, Math.min(1, hsl.s)), l = Math.max(0, Math.min(1, hsl.l));
    if (s <= 0) { var grey = Math.round(l * 255); return { r: grey, g: grey, b: grey }; }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    function channel(t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }
    return { r: Math.round(channel(h + 1 / 3) * 255), g: Math.round(channel(h) * 255),
             b: Math.round(channel(h - 1 / 3) * 255) };
  }

  /* Y >= 0.5 means the background is light, so the ink on it must be dark. */
  function autoInk(background) { return luminance(background) >= 0.5 ? "dark" : "light"; }

  /* Mirrors db::color::autoAccent so the Theme tab can preview a background the operator has
   * not saved yet. Core recomputes and republishes the same value once the write lands. */
  function autoAccent(background, text) {
    var bg = rgbOf(background);
    if (!bg) return "#7F5E3D";
    var textHex = colorOk(text) ? text : "#FFFFFF";
    var backgroundY = luminance(background), textY = luminance(textHex);
    var base = toHsl(bg);
    var hue = (base.h + 180) % 360, saturation = Math.max(base.s, 0.35);
    function ratio(a, b) { return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05); }
    function satisfies(candidate) {
      var y = luminance(candidate);
      return ratio(y, backgroundY) >= 3 && ratio(textY, y) >= 4.5;
    }
    function score(candidate) {
      var y = luminance(candidate);
      return Math.min(ratio(y, backgroundY), Math.max(ratio(1, y), ratio(0, y)));
    }
    var darkFirst = backgroundY >= 0.5, best = hexOf(fromHsl({ h: hue, s: saturation, l: base.l }));
    var bestScore = -1;
    for (var pass = 0; pass < 2; pass++) {
      var downward = (pass === 0) === darkFirst;
      for (var step = 1; step <= 100; step++) {
        var l = base.l + (downward ? -0.01 : 0.01) * step;
        if (l < 0 || l > 1) break;
        var candidate = hexOf(fromHsl({ h: hue, s: saturation, l: l }));
        if (satisfies(candidate)) return candidate;
        var candidateScore = score(candidate);
        if (candidateScore > bestScore) { bestScore = candidateScore; best = candidate; }
      }
    }
    return best;
  }

  /* What the Theme tab renders: core's published decision when it has one, otherwise the same
   * decision computed locally from the background the form currently shows. */
  function themeAutoModel(status, backgroundHex) {
    var theme = isObj(status) && isObj(status.display) && isObj(status.display.theme)
      ? status.display.theme : {};
    var published = isObj(theme.auto_accent) ? theme.auto_accent : {};
    var background = colorOk(backgroundHex) ? backgroundHex :
      (isObj(theme.auto_background) && colorOk(theme.auto_background.color)
        ? theme.auto_background.color : "#101418");
    var usePublished = !colorOk(backgroundHex) && colorOk(published.call_button);
    var button = usePublished ? published.call_button : autoAccent(background, "#FFFFFF");
    return {
      background: background,
      source: isObj(theme.auto_background) && theme.auto_background.source === "image"
        ? "image" : "color",
      ink: autoInk(background),
      callButton: button,
      callButtonInk: autoInk(button),
      inkOverride: isObj(theme.ink_override) ? theme.ink_override : {}
    };
  }

  /* Appearance. The schedule is only meaningful for auto_schedule, but it is stored either way
   * so switching modes back and forth does not lose the times. */
  function appearanceEntries(scope, f) {
    var mode = APPEARANCE_MODES.indexOf(String(f.mode)) >= 0 ? String(f.mode) : "auto_system";
    var base = scope ? "devices." + scope + ".local.display" : "display";
    var entries = [{ key: base + ".appearance", value: mode }];
    if (f.dark_from && f.light_from && !scope)
      entries.push({ key: "display.appearance_schedule",
                     value: { dark_from: String(f.dark_from), light_from: String(f.light_from) } });
    return entries;
  }

  function appearanceModel(status, cfg, scope) {
    var display = isObj(status) && isObj(status.display) ? status.display : {};
    var reported = isObj(display.appearance) ? display.appearance : {};
    var base = isObj(cfg) && isObj(cfg.display) ? cfg.display : {};
    var device = scope && isObj(cfg) && isObj(cfg.devices) && isObj(cfg.devices[scope]) &&
      isObj(cfg.devices[scope].local) && isObj(cfg.devices[scope].local.display)
      ? cfg.devices[scope].local.display : {};
    var configured = scope && typeof device.appearance === "string" ? device.appearance :
      (typeof base.appearance === "string" ? base.appearance : "auto_system");
    if (APPEARANCE_MODES.indexOf(configured) < 0) configured = "auto_system";
    var schedule = isObj(base.appearance_schedule) ? base.appearance_schedule : {};
    return {
      configured: configured,
      effective: reported.effective === "dark" ? "dark" : "light",
      followSystem: reported.follow_system === true,
      darkFrom: typeof schedule.dark_from === "string" ? schedule.dark_from : "19:00",
      lightFrom: typeof schedule.light_from === "string" ? schedule.light_from : "06:30"
    };
  }

  /* Ink and call-button overrides live in the same theme object as the background, so they are
   * written through one entry. An empty value deletes the override and returns the region to
   * automatic rather than storing a colour that happens to match. */
  function themeColorEntries(scope, f, existing) {
    var key = themeKey(scope), value = editableClone(existing);
    if (f.call_button_auto || !colorOk(f.call_button_bg)) delete value.call_button_bg;
    else value.call_button_bg = f.call_button_bg;
    var ink = {};
    var proposed = isObj(f.ink_override) ? f.ink_override : {};
    for (var i = 0; i < INK_REGIONS.length; i++) {
      var region = INK_REGIONS[i];
      if (colorOk(proposed[region])) ink[region] = proposed[region];
    }
    if (hasOwnKeys(ink)) value.ink_override = ink;
    else delete value.ink_override;
    // Never write back what core computed; those fields are read-only.
    delete value.auto_ink;
    delete value.auto_accent;
    delete value.auto_background;
    delete value.call_button_ink;
    if (!hasOwnKeys(value)) return { entries: [], dels: [key] };
    return { entries: [{ key: key, value: value }], dels: [] };
  }

  var NOTICE_PRESET_MAX = 8;

  /* notice.presets is an ordinary array an administrator edits; the dialogs render whatever is
   * there. Rejects the same shapes core rejects so the form fails before the round trip. */
  function noticePresetEntries(presets) {
    if (!(presets instanceof Array)) throw new Error("notice.presets");
    if (presets.length > NOTICE_PRESET_MAX) throw new Error("notice.presets_max");
    var seen = {}, out = [];
    for (var i = 0; i < presets.length; i++) {
      var id = String((presets[i] || {}).id || "");
      var text = String((presets[i] || {}).text == null ? "" : presets[i].text)
        .replace(/^\s+|\s+$/g, "");
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(id)) throw new Error("notice.preset_id");
      if (own(seen, id)) throw new Error("notice.preset_id");
      seen[id] = true;
      var length = countCharacters(text);
      if (!length || length > NOTICE_MAX_CHARS) throw new Error("notice.preset_text");
      out.push({ id: id, text: text });
    }
    return [{ key: "notice.presets", value: out }];
  }

  function noticePresetList(cfg) {
    var presets = isObj(cfg) && isObj(cfg.notice) && cfg.notice.presets instanceof Array
      ? cfg.notice.presets : [];
    var out = [];
    for (var i = 0; i < presets.length && out.length < NOTICE_PRESET_MAX; i++) {
      var entry = presets[i];
      if (!isObj(entry)) continue;
      var id = String(entry.id || ""), text = String(entry.text == null ? "" : entry.text);
      if (!/^[A-Za-z0-9_-]{1,32}$/.test(id) || !text) continue;
      out.push({ id: id, text: text });
    }
    return out;
  }

  /* The announcement a door actually shows: its own if it has one, otherwise the cluster-wide
   * message. Mirrors the resolution core reports in status.doors.<id>.notice. */
  function effectiveNoticeModel(door, cfg, nowMs) {
    var doors = isObj(cfg) ? cfg.doors : null;
    var specific = noticeModel(door, doors, nowMs);
    if (specific.active) { specific.scope = "door"; return specific; }
    var global = isObj(cfg) && isObj(cfg.notice) ? cfg.notice.global : null;
    var wrapped = noticeModel("global", { global: { notice: global } }, nowMs);
    wrapped.scope = wrapped.active ? "global" : "none";
    return wrapped;
  }

  /* Every door the administrator can act on: the configured ones, then any door a live door
   * station is serving that has no entry yet. Core reports the second kind with
   * configured:false so an installation predating door seeding still shows its tiles. */
  function doorRows(cfg, status) {
    var configured = isObj(cfg) && isObj(cfg.doors) ? cfg.doors : {};
    var reported = isObj(status) && isObj(status.doors) ? status.doors : {};
    var rows = [], seen = {}, id;
    for (id in configured) {
      if (!own(configured, id)) continue;
      seen[id] = true;
      rows.push({ id: id, configured: true,
                  label: labelOfDoor(configured[id], id, reported[id]) });
    }
    for (id in reported) {
      if (!own(reported, id) || seen[id]) continue;
      if (reported[id] && reported[id].configured === true) continue;
      rows.push({ id: id, configured: false,
                  label: typeof reported[id].label === "string" && reported[id].label
                    ? reported[id].label : id });
    }
    return rows;
  }

  function labelOfDoor(entry, id, reported) {
    var label = labelOf(entry, "ja", "");
    if (label) return label;
    if (isObj(reported) && typeof reported.label === "string" && reported.label)
      return reported.label;
    return id;
  }

  /* doors.<id>.unlock.show_button is a three-way choice: leave it to core (show the control when
   * an unlock action exists), always show it, or always hide it. */
  function doorUnlockEntries(door, mode, existing) {
    var key = "doors." + door + ".unlock";
    var value = editableClone(existing);
    if (mode === "show") value.show_button = true;
    else if (mode === "hide") value.show_button = false;
    else delete value.show_button;
    if (!hasOwnKeys(value)) return { entries: [], dels: [key] };
    return { entries: [{ key: key, value: value }], dels: [] };
  }

  function doorUnlockModel(door, cfg, status) {
    var configured = isObj(cfg) && isObj(cfg.doors) && isObj(cfg.doors[door]) &&
      isObj(cfg.doors[door].unlock) ? cfg.doors[door].unlock : {};
    var reported = isObj(status) && isObj(status.doors) && isObj(status.doors[door]) &&
      isObj(status.doors[door].unlock) ? status.doors[door].unlock : {};
    var mode = configured.show_button === true ? "show" :
               (configured.show_button === false ? "hide" : "auto");
    return {
      mode: mode,
      configured: reported.configured === true,
      showButton: reported.show_button === true,
      command: typeof reported.command === "string" ? reported.command : ""
    };
  }

  /* Readability findings that came back with a successful write. */
  function writeWarnings(result) {
    var list = isObj(result) && result.warnings instanceof Array ? result.warnings : [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (!isObj(item)) continue;
      out.push({
        key: String(item.key || ""),
        property: String(item.property || ""),
        contrast: num(item.contrast, 0),
        message_key: typeof item.message_key === "string" ? item.message_key :
          "theme.low_contrast"
      });
    }
    return out;
  }

  function tzEntries(min) {
    return [{ key: "integrations.tz_offset_min", value: num(min, 540) }];
  }

  function quietEntries(f, existing) {
    var value = editableClone(existing);
    var previous = value.windows instanceof Array ? value.windows : [];
    var ws = [];
    for (var i = 0; i < (f.windows || []).length; i++) {
      var w = f.windows[i];
      if (!w.from || !w.to) continue;
      var previousIndex = own(w, "_existing_index") ? num(w._existing_index, -1) : i;
      var windowValue = previousIndex >= 0 && isObj(previous[previousIndex]) ?
        cloneJson(previous[previousIndex]) : {};
      windowValue.from = w.from;
      windowValue.to = w.to;
      ws.push(windowValue);
    }
    value.windows = ws;
    value.suppress = cloneJson(f.suppress || []);
    value.never_suppress = cloneJson(f.never_suppress || []);
    return [{ key: "quiet_hours.default", value: value }];
  }

  function webSosEntries(enabled) {
    return [{ key: "emergency.web_active_page_alerts", value: enabled !== false }];
  }


  var ASSET_MAX_BYTES = 3 * 1024 * 1024;
  var ASSET_TYPES = ["image/jpeg", "image/png", "audio/mpeg", "audio/wav"];


  function assetTypeOf(name, declared) {
    if (declared && ASSET_TYPES.indexOf(declared) >= 0) return declared;
    var n = String(name || "").toLowerCase();
    if (/\.jpe?g$/.test(n)) return "image/jpeg";
    if (/\.png$/.test(n)) return "image/png";
    if (/\.mp3$/.test(n)) return "audio/mpeg";
    if (/\.wav$/.test(n)) return "audio/wav";
    return "";
  }


  function assetRefHash(v) {
    return (typeof v === "string" && v.indexOf("asset:") === 0) ? v.slice(6) : "";
  }


  //   display.theme.bg_image / devices.*.local.theme.bg_image / quick_replies.*.audio.* /

  function assetRefs(cfg) {
    var out = {};
    function add(h, where) {
      if (!h || typeof h !== "string") return;
      if (!out[h]) out[h] = [];
      out[h].push(where);
    }
    add(((cfg.display || {}).theme || {}).bg_image, "display.theme");
    var devs = cfg.devices || {};
    for (var did in devs) {
      add((((devs[did] || {}).local || {}).theme || {}).bg_image,
          "devices." + String(did).slice(0, 8));
    }
    var qrs = cfg.quick_replies || {};
    for (var qid in qrs) {
      var au = qrs[qid].audio || {};
      for (var lg in au) add(au[lg], "quick_replies." + qid + " (" + lg + ")");
    }
    var ui = cfg.ui || {};
    ["ringtone", "launch_sound", "call_sound", "button_sound", "update_sound"].forEach(
      function (key) { add(assetRefHash(ui[key]), "ui." + key); });
    var rs = cfg.trigger_rules || {};
    for (var rid in rs) {
      var acts = rs[rid].actions || [];
      for (var i = 0; i < acts.length; i++)
        add(assetRefHash(acts[i].sound), "trigger_rules." + rid);
    }
    add(assetRefHash((cfg.emergency || {}).alarm_sound), "emergency.alarm_sound");
    return out;
  }

  function fmtBytes(n) {
    var v = parseFloat(n);
    if (isNaN(v)) return "-";
    if (v < 1024) return v + " B";
    if (v < 1024 * 1024) return (v / 1024).toFixed(1) + " KB";
    return (v / 1048576).toFixed(2) + " MB";
  }





  function themeKey(scope) {
    return scope ? "devices." + scope + ".local.theme" : "display.theme";
  }


  function themeEntries(scope, f, existing) {
    var key = themeKey(scope), v = editableClone(existing);
    if (!scope || f.color_on) v.bg_color = f.bg_color || "#101418";
    else delete v.bg_color;
    if (!scope || f.image_on) v.bg_image = f.bg_image || null;
    else delete v.bg_image;
    if (!hasOwnKeys(v)) return { entries: [], dels: [key] };
    return { entries: [{ key: key, value: v }], dels: [] };
  }


  function purposeEntries(id, f, existing) {
    var value = editableClone(existing);
    value.label = mergedLabel(value.label, f);
    value.icon = String(f.icon || "");
    value.order = num(f.order, 1);
    return [{ key: "visit_purposes." + id, value: value }];
  }

  function purposeReorderEntries(sortedIds, cur) {
    var out = [];
    for (var i = 0; i < sortedIds.length; i++) {
      var id = sortedIds[i], c = (cur && cur[id]) || {};
      var value = editableClone(c);
      value.order = i + 1;
      out.push({ key: "visit_purposes." + id, value: value });
    }
    return out;
  }

  function uiEntries(f) {
    var langs = (f.languages && f.languages.length) ? f.languages : ["ja"];
    return [{ key: "ui.languages", value: langs },
            { key: "ui.visitor_lang_revert_s", value: num(f.revert_s, 60) }];
  }



  function placeholders(s) {
    var out = [], m, re = /\{(\w+)\}/g, str = String(s == null ? "" : s);
    while ((m = re.exec(str)) !== null) if (out.indexOf(m[1]) < 0) out.push(m[1]);
    out.sort();
    return out;
  }


  function placeholderDiff(def, val) {
    var a = placeholders(def), b = placeholders(val), miss = [], extra = [], i;
    for (i = 0; i < a.length; i++) if (b.indexOf(a[i]) < 0) miss.push("{" + a[i] + "}");
    for (i = 0; i < b.length; i++) if (a.indexOf(b[i]) < 0) extra.push("{" + b[i] + "}");
    if (!miss.length && !extra.length) return "";
    return (miss.length ? "missing " + miss.join(" ") : "") +
           (miss.length && extra.length ? " / " : "") +
           (extra.length ? "extra " + extra.join(" ") : "");
  }






  function i18nEntries(cur, changes) {
    var entries = [], dels = [];
    for (var lang in changes) {
      var base = (cur && isObj(cur[lang])) ? cur[lang] : {};
      var next = {}, n = 0, k;
      for (k in base) if (base[k] !== undefined) { next[k] = base[k]; n++; }
      var ch = changes[lang];
      for (k in ch) {
        if (ch[k]) {
          if (next[k] === undefined) n++;
          next[k] = ch[k];
        } else if (next[k] !== undefined) {
          delete next[k];
          n--;
        }
      }
      if (n > 0) entries.push({ key: "i18n_overrides." + lang, value: next });
      else if (cur && cur[lang] !== undefined) dels.push("i18n_overrides." + lang);
    }
    return { entries: entries, dels: dels };
  }



  function flattenConfig(cfg) {
    var out = [];
    var ENTITY2 = { buildings: 1, doors: 1, households: 1, quick_replies: 1,
                    trigger_rules: 1, quiet_hours: 1 };
    function push(key, v) { if (v !== undefined) out.push({ key: key, value: v }); }
    function flattenUiElements(base, node, path) {
      if (!isObj(node)) { push(base + path, node); return; }
      var keys = [], hasScalar = false;
      for (var ek in node) if (own(node, ek)) {
        keys.push(ek);
        if (!isObj(node[ek])) hasScalar = true;
      }
      if (!keys.length) return;
      // Materialization expands dots in semantic IDs into nested objects. The first object with
      // scalar properties is one element override and is validated by the batch allow-list.
      if (hasScalar) { push(base + path, node); return; }
      for (var ei = 0; ei < keys.length; ei++)
        flattenUiElements(base, node[keys[ei]], path ? path + "." + keys[ei] : keys[ei]);
    }
    for (var k in cfg) {
      var v = cfg[k];
      if (!isObj(v)) { push(k, v); continue; }
      if (ENTITY2[k]) {
        for (var id in v) push(k + "." + id, v[id]);
      } else if (k === "devices") {
        for (var did in v) {
          var d = v[did], b = "devices." + did;
          for (var f in d) {
            if (f === "local" && isObj(d.local)) {
              for (var g in d.local) {
                if (g === "ui" && isObj(d.local.ui)) {
                  for (var ug in d.local.ui) {
                    if (ug === "elements" && isObj(d.local.ui.elements))
                      flattenUiElements(b + ".local.ui.elements.", d.local.ui.elements, "");
                    else push(b + ".local.ui." + ug, d.local.ui[ug]);
                  }
                } else push(b + ".local." + g, d.local[g]);
              }
            } else push(b + "." + f, d[f]);
          }
        }
      } else if (k === "sip") {
        for (var sf in v) {
          if (sf === "accounts" && isObj(v.accounts)) {
            for (var aid in v.accounts) push("sip.accounts." + aid, v.accounts[aid]);
          } else push("sip." + sf, v[sf]);
        }
      } else if (k === "integrations") {
        for (var inf in v) {
          if (isObj(v[inf])) {
            for (var ig in v[inf]) push("integrations." + inf + "." + ig, v[inf][ig]);
          } else push("integrations." + inf, v[inf]);
        }
      } else {
        for (var of in v) push(k + "." + of, v[of]);
      }
    }
    return out;
  }


  function applyKey(cfg, key, valueJson) {
    var v;
    try { v = JSON.parse(valueJson); } catch (e) { v = valueJson; }
    var segs = String(key).split(".");
    var node = cfg;
    for (var i = 0; i < segs.length - 1; i++) {
      if (!segs[i]) return;
      if (!isObj(node[segs[i]])) node[segs[i]] = {};
      node = node[segs[i]];
    }
    node[segs[segs.length - 1]] = v;
  }

  function deleteKey(cfg, key) {
    var segs = String(key).split(".");
    var node = cfg;
    for (var i = 0; i < segs.length - 1; i++) {
      node = node[segs[i]];
      if (!isObj(node)) return;
    }
    delete node[segs[segs.length - 1]];
  }


  function newId(prefix, obj) {
    var i = 1;
    while (obj && obj[prefix + i] !== undefined) i++;
    return prefix + i;
  }


  function safeId(s) {
    return String(s || "").replace(/[^A-Za-z0-9_]/g, "_");
  }

  /* ---------------- Pairing (WP-W) ----------------
   * Pure view models for the "Add device" tab. The UI renders what these return and never
   * infers pairing state from `paired` / `persistence_ready`; `pairing.state` is authoritative.
   */

  // Error codes the core can report on a pairing route or event. Anything else falls back to
  // pair.err.unknown, so a raw code is never the primary message.
  var PAIR_ERR_CODES = ["bad_pin", "expired", "no_token", "host_unpaired", "connect_failed",
    "timeout", "closed", "join_in_progress", "already_paired", "decrypt_failed", "bad_payload",
    "bad_challenge", "local_persist_failed", "persist_failed", "host_zero_psk", "no_ack",
    "bad_qr", "no_mesh", "pairing_unavailable"];

  var PAIR_STATES = ["unpaired", "joining", "persist_error", "ready", "revoked"];

  function pairErrKey(code) {
    var c = String(code == null ? "" : code);
    return PAIR_ERR_CODES.indexOf(c) >= 0 ? "pair.err." + c : "pair.err.unknown";
  }

  // {m, s} for pair.code_expires_in / pair.add_all_on, seconds always two digits.
  function pairClock(seconds) {
    var n = Math.max(0, Math.round(num(seconds, 0)));
    return { m: Math.floor(n / 60), s: ("0" + (n % 60)).slice(-2) };
  }

  function pairDeviceLabel(d) {
    d = isObj(d) ? d : {};
    if (d.name) return String(d.name);
    var model = d.model ? String(d.model) : "";
    var id6 = String(d.id || "").slice(0, 6);
    return model ? (id6 ? model + " " + id6 : model) : (id6 || "?");
  }

  function pairDeviceDetail(d) {
    d = isObj(d) ? d : {};
    var parts = [];
    if (d.role) parts.push(String(d.role));
    if (d.model) parts.push(String(d.model));
    if (d.platform && d.platform !== d.model) parts.push(String(d.platform));
    if (d.sw) parts.push("v" + String(d.sw));
    return parts.join(" · ");
  }

  // How long a finished row keeps its result visible, and how long a row that left the pending
  // list may wait for its device to show up as a peer before the add counts as failed.
  var PAIR_ROW_LINGER_MS = 15000;

  // Carry the per-row UI state across the 2 s snapshot poll. There is no SSE yet, so a row that
  // was being added and has left `pending` is confirmed by the device appearing in status.peers:
  // that peer diff is this panel's device_joined.
  function pairMergeRows(prevRows, snapshot, peerIds, nowMs) {
    prevRows = isObj(prevRows) ? prevRows : {};
    var devices = ((isObj(snapshot) ? snapshot.pending : null) || {}).devices;
    devices = devices instanceof Array ? devices : [];
    var pending = {}, peers = {}, out = {}, i, id, st;
    for (i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].id) pending[devices[i].id] = true;
    peerIds = peerIds instanceof Array ? peerIds : [];
    for (i = 0; i < peerIds.length; i++) peers[peerIds[i]] = true;
    for (id in prevRows) {
      if (!own(prevRows, id)) continue;
      st = prevRows[id];
      if (!isObj(st)) continue;
      if (own(pending, id)) { out[id] = st; continue; }
      if (st.state === "adding" && own(peers, id)) {
        out[id] = { state: "added", at: nowMs, label: st.label };
        continue;
      }
      if (nowMs - num(st.at, 0) < PAIR_ROW_LINGER_MS) { out[id] = st; continue; }
      if (st.state === "adding")
        out[id] = { state: "failed", err: "no_ack", at: nowMs, label: st.label };
    }
    return out;
  }

  // One nearby row: core's invite_state is authoritative, the local state covers the click
  // before the next snapshot arrives and the "Added" confirmation after the row leaves pending.
  function pairRowModel(device, local) {
    device = isObj(device) ? device : {};
    local = isObj(local) ? local : {};
    var state = "idle", errKey = "";
    if (device.invite_state === "sent" || device.invite_state === "acked") state = "adding";
    if (local.state === "adding") state = "adding";
    if (local.state === "failed") { state = "failed"; errKey = pairErrKey(local.err); }
    // A failure reported by core outranks the optimistic state of the click that caused it.
    if (device.invite_state === "failed") { state = "failed"; errKey = pairErrKey(device.last_error); }
    if (local.state === "added") { state = "added"; errKey = ""; }
    return {
      id: String(device.id || local.id || ""),
      label: device.id ? pairDeviceLabel(device) : String(local.label || ""),
      detail: pairDeviceDetail(device),
      age_s: Math.max(0, Math.round(num(device.age_s, 0))),
      state: state,
      errKey: errKey,
      errCode: state === "failed" ? String(device.invite_state === "failed" ?
        (device.last_error || "") : (local.err || "")) : "",
      gone: !device.id
    };
  }

  // The whole tab in one object: which view to draw and everything both views need.
  function pairPanelModel(snapshot, rows) {
    snapshot = isObj(snapshot) ? snapshot : {};
    rows = isObj(rows) ? rows : {};
    var state = String(snapshot.state || "");
    if (PAIR_STATES.indexOf(state) < 0) state = snapshot.paired === true ? "ready" : "unpaired";
    var self = isObj(snapshot.self) ? snapshot.self : {};
    var home = isObj(snapshot.home) ? snapshot.home : {};
    var token = isObj(snapshot.token) ? snapshot.token : {};
    var pending = isObj(snapshot.pending) ? snapshot.pending : {};
    var devices = pending.devices instanceof Array ? pending.devices : [];
    var list = [], i, id, seen = {};
    for (i = 0; i < devices.length; i++) {
      if (!devices[i] || !devices[i].id) continue;
      seen[devices[i].id] = true;
      list.push(pairRowModel(devices[i], rows[devices[i].id]));
    }
    for (id in rows) {
      if (!own(rows, id) || own(seen, id) || !isObj(rows[id])) continue;
      if (rows[id].state === "added" || rows[id].state === "failed")
        list.push(pairRowModel({}, {
          id: id, state: rows[id].state, err: rows[id].err, label: rows[id].label
        }));
    }
    var tokenActive = token.active === true;
    return {
      state: state,
      onboarding: state !== "ready",
      isFounder: snapshot.is_founder === true,
      self: {
        name: String(self.name || ""), model: String(self.model || ""),
        addr: String(self.addr || ""), role: String(self.role || snapshot.role || "")
      },
      qrText: String(snapshot.pair_qr || ""),
      memberCount: Math.max(0, Math.round(num(home.member_count, 0))),
      connectedCount: Math.max(0, Math.round(num(home.connected_count, 0))),
      token: {
        active: tokenActive,
        pin: tokenActive ? String(token.pin || "") : "",
        host: String(token.host || self.addr || ""),
        expires_s: tokenActive ? Math.max(0, Math.round(num(token.expires_s, 0))) : 0,
        attemptsLeft: tokenActive ? Math.max(0, Math.round(num(token.attempts_left, 0))) : 0
      },
      pairingMode: {
        active: pending.pairing_mode === true,
        left_s: Math.max(0, Math.round(num(pending.pairing_mode_left_s, 0))),
        addedCount: Math.max(0, Math.round(num(pending.auto_added_count, 0)))
      },
      rows: list
    };
  }

  // The join form on an unpaired host: address plus a six-digit Pairing PIN.
  function pairJoinPayload(host, pin) {
    var h = String(host == null ? "" : host).replace(/^\s+|\s+$/g, "");
    var p = String(pin == null ? "" : pin).replace(/[^0-9]/g, "");
    if (!h) return { ok: false, field: "host" };
    if (p.length !== 6) return { ok: false, field: "pin" };
    return { ok: true, body: { host: h, pin: p } };
  }

  // A "doorbell-pair:<addr>|<id>|<pk>" payload, pasted or read from the camera.
  function pairQrParse(text) {
    var s = String(text == null ? "" : text).replace(/^\s+|\s+$/g, "");
    if (s.indexOf("doorbell-pair:") !== 0) return null;
    var body = s.slice("doorbell-pair:".length).split("|");
    if (body.length !== 3 || !body[0] || !/^[0-9a-fA-F]{64}$/.test(body[2])) return null;
    return { addr: body[0], id: body[1], pk: body[2] };
  }

  function pairQrTextValid(text) { return !!pairQrParse(text); }

  /* ---- QR encoding (ISO/IEC 18004 byte mode, ECC level M) ----
   * The panel draws `pairing.pair_qr` itself: the admin page is static and must not fetch a
   * generator, and core's db_core_qr_encode is not reachable from the browser.
   */
  var QR_ECC_PER_BLOCK_M = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28,
    28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
  var QR_BLOCKS_M = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17,
    18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];

  function qrRawDataModules(ver) {
    var result = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      var numAlign = Math.floor(ver / 7) + 2;
      result -= (25 * numAlign - 10) * numAlign - 55;
      if (ver >= 7) result -= 36;
    }
    return result;
  }

  function qrDataCodewords(ver) {
    return Math.floor(qrRawDataModules(ver) / 8) - QR_ECC_PER_BLOCK_M[ver] * QR_BLOCKS_M[ver];
  }

  function qrAlignPositions(ver) {
    if (ver === 1) return [];
    var numAlign = Math.floor(ver / 7) + 2;
    var step = Math.floor((ver * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
    var out = [], i, pos;
    for (i = 0; i < numAlign; i++) out.push(0);
    out[0] = 6;
    for (i = numAlign - 1, pos = ver * 4 + 10; i >= 1; i--, pos -= step) out[i] = pos;
    return out;
  }

  function qrGfMul(x, y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = ((z << 1) ^ ((z >>> 7) * 0x11D)) & 0xFF;
      z = (z ^ (((y >>> i) & 1) * x)) & 0xFF;
    }
    return z;
  }

  function qrRsDivisor(degree) {
    var result = [], i, j, root = 1;
    for (i = 0; i < degree; i++) result.push(0);
    result[degree - 1] = 1;
    for (i = 0; i < degree; i++) {
      for (j = 0; j < degree; j++) {
        result[j] = qrGfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = qrGfMul(root, 0x02);
    }
    return result;
  }

  function qrRsRemainder(data, start, len, divisor) {
    var degree = divisor.length, result = [], i, j, factor;
    for (i = 0; i < degree; i++) result.push(0);
    for (i = 0; i < len; i++) {
      factor = data[start + i] ^ result[0];
      result.shift();
      result.push(0);
      for (j = 0; j < degree; j++) result[j] ^= qrGfMul(divisor[j], factor);
    }
    return result;
  }

  function qrUtf8Bytes(s) {
    var esc = encodeURIComponent(String(s == null ? "" : s)), out = [], i;
    for (i = 0; i < esc.length; i++) {
      if (esc.charAt(i) === "%") { out.push(parseInt(esc.substr(i + 1, 2), 16)); i += 2; }
      else out.push(esc.charCodeAt(i));
    }
    return out;
  }

  function qrPenalty(mods, size) {
    var penalty = 0, dark = 0, x, y, run, color, idx;
    function at(px, py) { return mods[py * size + px]; }
    for (y = 0; y < size; y++) {
      run = 1; color = at(0, y);
      for (x = 1; x < size; x++) {
        if (at(x, y) === color) { run++; continue; }
        if (run >= 5) penalty += 3 + (run - 5);
        color = at(x, y); run = 1;
      }
      if (run >= 5) penalty += 3 + (run - 5);
    }
    for (x = 0; x < size; x++) {
      run = 1; color = at(x, 0);
      for (y = 1; y < size; y++) {
        if (at(x, y) === color) { run++; continue; }
        if (run >= 5) penalty += 3 + (run - 5);
        color = at(x, y); run = 1;
      }
      if (run >= 5) penalty += 3 + (run - 5);
    }
    for (y = 0; y + 1 < size; y++)
      for (x = 0; x + 1 < size; x++) {
        color = at(x, y);
        if (at(x + 1, y) === color && at(x, y + 1) === color && at(x + 1, y + 1) === color)
          penalty += 3;
      }
    var finder = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
    function matches(px, py, dx, dy) {
      for (var k = 0; k < 11; k++) {
        var qx = px + dx * k, qy = py + dy * k;
        if (qx < 0 || qy < 0 || qx >= size || qy >= size) return false;
        if (at(qx, qy) !== finder[k]) return false;
      }
      return true;
    }
    for (y = 0; y < size; y++)
      for (x = 0; x < size; x++) {
        if (matches(x, y, 1, 0)) penalty += 40;
        if (matches(x, y, 0, 1)) penalty += 40;
        if (matches(x, y, -1, 0)) penalty += 40;
        if (matches(x, y, 0, -1)) penalty += 40;
      }
    for (idx = 0; idx < size * size; idx++) if (mods[idx]) dark++;
    penalty += Math.floor(Math.abs(dark * 20 - size * size * 10) / (size * size)) * 10;
    return penalty;
  }

  // Returns {size, modules:[0|1]} row major, or null when the text cannot be encoded.
  function qrModules(text) {
    var data = qrUtf8Bytes(text);
    if (!data.length) return null;
    var ver, cap = 0, ccBits, i, j, k;
    for (ver = 1; ver <= 40; ver++) {
      cap = qrDataCodewords(ver);
      ccBits = ver < 10 ? 8 : 16;
      if (4 + ccBits + data.length * 8 <= cap * 8) break;
    }
    if (ver > 40) return null;
    ccBits = ver < 10 ? 8 : 16;

    var bits = [];
    function push(val, n) { for (var b = n - 1; b >= 0; b--) bits.push((val >>> b) & 1); }
    push(4, 4);
    push(data.length, ccBits);
    for (i = 0; i < data.length; i++) push(data[i], 8);
    push(0, Math.min(4, cap * 8 - bits.length));
    while (bits.length % 8 !== 0) bits.push(0);
    var dat = [], byteVal;
    for (i = 0; i < bits.length; i += 8) {
      byteVal = 0;
      for (j = 0; j < 8; j++) byteVal = (byteVal << 1) | bits[i + j];
      dat.push(byteVal);
    }
    for (var pad = 0xEC; dat.length < cap; pad = pad ^ 0xEC ^ 0x11) dat.push(pad);

    var numBlocks = QR_BLOCKS_M[ver], eccLen = QR_ECC_PER_BLOCK_M[ver];
    var rawCodewords = Math.floor(qrRawDataModules(ver) / 8);
    var numShort = numBlocks - rawCodewords % numBlocks;
    var shortLen = Math.floor(rawCodewords / numBlocks) - eccLen;
    var div = qrRsDivisor(eccLen), coded = [], off = 0, ecc, datLen;
    for (i = 0; i < rawCodewords; i++) coded.push(0);
    for (i = 0; i < numBlocks; i++) {
      datLen = shortLen + (i < numShort ? 0 : 1);
      ecc = qrRsRemainder(dat, off, datLen, div);
      for (j = 0, k = i; j < datLen; j++, k += numBlocks) {
        if (j === shortLen) k -= numShort;
        coded[k] = dat[off + j];
      }
      for (j = 0, k = cap + i; j < eccLen; j++, k += numBlocks) coded[k] = ecc[j];
      off += datLen;
    }

    var size = ver * 4 + 17, mods = [], fn = [];
    for (i = 0; i < size * size; i++) { mods.push(0); fn.push(0); }
    function set(x, y, dark, isFn) {
      if (x < 0 || y < 0 || x >= size || y >= size) return;
      mods[y * size + x] = dark ? 1 : 0;
      if (isFn) fn[y * size + x] = 1;
    }
    for (i = 0; i < size; i++) {
      set(6, i, i % 2 === 0, 1);
      set(i, 6, i % 2 === 0, 1);
    }
    function finderAt(cx, cy) {
      for (var dy = -4; dy <= 4; dy++)
        for (var dx = -4; dx <= 4; dx++) {
          var dist = Math.max(Math.abs(dx), Math.abs(dy));
          set(cx + dx, cy + dy, dist !== 2 && dist !== 4, 1);
        }
    }
    finderAt(3, 3);
    finderAt(size - 4, 3);
    finderAt(3, size - 4);
    var ap = qrAlignPositions(ver), n = ap.length, dx, dy;
    for (i = 0; i < n; i++)
      for (j = 0; j < n; j++) {
        if ((i === 0 && j === 0) || (i === 0 && j === n - 1) || (i === n - 1 && j === 0)) continue;
        for (dy = -2; dy <= 2; dy++)
          for (dx = -2; dx <= 2; dx++)
            set(ap[i] + dx, ap[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1, 1);
      }
    if (ver >= 7) {
      var rem = ver;
      for (i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
      var vbits = (ver << 12) | rem;
      for (i = 0; i < 18; i++) {
        var vbit = (vbits >> i) & 1;
        set(size - 11 + i % 3, Math.floor(i / 3), vbit, 1);
        set(Math.floor(i / 3), size - 11 + i % 3, vbit, 1);
      }
    }
    function drawFormat(mask) {
      var fdata = (0 << 3) | mask, frem = fdata, fi;
      for (fi = 0; fi < 10; fi++) frem = (frem << 1) ^ ((frem >> 9) * 0x537);
      var fbits = ((fdata << 10) | frem) ^ 0x5412;
      for (fi = 0; fi <= 5; fi++) set(8, fi, (fbits >> fi) & 1, 1);
      set(8, 7, (fbits >> 6) & 1, 1);
      set(8, 8, (fbits >> 7) & 1, 1);
      set(7, 8, (fbits >> 8) & 1, 1);
      for (fi = 9; fi < 15; fi++) set(14 - fi, 8, (fbits >> fi) & 1, 1);
      for (fi = 0; fi < 8; fi++) set(size - 1 - fi, 8, (fbits >> fi) & 1, 1);
      for (fi = 8; fi < 15; fi++) set(8, size - 15 + fi, (fbits >> fi) & 1, 1);
      set(8, size - 8, 1, 1);
    }
    drawFormat(0);

    var bitIndex = 0, right, vert, x, y, upward;
    for (right = size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (vert = 0; vert < size; vert++)
        for (j = 0; j < 2; j++) {
          x = right - j;
          upward = ((right + 1) & 2) === 0;
          y = upward ? size - 1 - vert : vert;
          if (fn[y * size + x] || bitIndex >= coded.length * 8) continue;
          mods[y * size + x] = (coded[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1;
          bitIndex++;
        }
    }

    var best = null, bestPenalty = -1, mask, cand, idx, invert, score;
    var baseMods = mods.slice(0);
    for (mask = 0; mask < 8; mask++) {
      mods = baseMods.slice(0);
      for (y = 0; y < size; y++)
        for (x = 0; x < size; x++) {
          idx = y * size + x;
          if (fn[idx]) continue;
          switch (mask) {
            case 0: invert = (x + y) % 2 === 0; break;
            case 1: invert = y % 2 === 0; break;
            case 2: invert = x % 3 === 0; break;
            case 3: invert = (x + y) % 3 === 0; break;
            case 4: invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
            case 5: invert = (x * y) % 2 + (x * y) % 3 === 0; break;
            case 6: invert = ((x * y) % 2 + (x * y) % 3) % 2 === 0; break;
            default: invert = ((x + y) % 2 + (x * y) % 3) % 2 === 0; break;
          }
          if (invert) mods[idx] = mods[idx] ? 0 : 1;
        }
      drawFormat(mask);
      cand = mods.slice(0);
      score = qrPenalty(cand, size);
      if (bestPenalty < 0 || score < bestPenalty) { bestPenalty = score; best = cand; }
    }
    return { size: size, modules: best, version: ver };
  }

  return {
    parseList: parseList, parseChatIds: parseChatIds, labelObj: labelObj, labelOf: labelOf,
    buildingEntries: buildingEntries, doorEntries: doorEntries,
    quickReplyEntries: quickReplyEntries, reorderEntries: reorderEntries,
    householdEntries: householdEntries, deviceEntries: deviceEntries, ruleEntries: ruleEntries,
    RULE_ACTION_TYPES: RULE_ACTION_TYPES, ALERT_CHANNELS: ALERT_CHANNELS,
    normalizeRuleEditor: normalizeRuleEditor, mergeRuleEditor: mergeRuleEditor,
    effectiveAlertChannels: effectiveAlertChannels,
    validateAlertPresentation: validateAlertPresentation,
    sosDryRunPreview: sosDryRunPreview, sosRuleWarnings: sosRuleWarnings,
    callFlowMode: callFlowMode, callFlowCompatibility: callFlowCompatibility,
    defaultPlaybackProfile: defaultPlaybackProfile,
    normalizePlaybackProfile: normalizePlaybackProfile,
    playbackProfileEntries: playbackProfileEntries,
    UI_PROPERTIES: UI_PROPERTIES, defaultUiManifest: defaultUiManifest,
    validateUiManifest: validateUiManifest, validateUiElementOverride: validateUiElementOverride,
    uiElementValue: uiElementValue, uiElementChanges: uiElementChanges,
    uiPreviewModel: uiPreviewModel,
    colorOk: colorOk, contrast: contrast, isPlainObject: isObj, configBatchOps: configBatchOps,
    mqttEntries: mqttEntries, telegramEntries: telegramEntries, sipEntries: sipEntries,
    webPushEntries: webPushEntries,
    mqttPlan: mqttPlan, telegramPlan: telegramPlan, webPushPlan: webPushPlan,
    localSecretProvisionPlan: localSecretProvisionPlan,
    panelProvisionPayload: panelProvisionPayload,
    canEditSipSecret: canEditSipSecret,
    sipAccountEntries: sipAccountEntries,
    sipAccountPlan: sipAccountPlan, mergeSecretPlans: mergeSecretPlans,
    tzEntries: tzEntries, quietEntries: quietEntries,
    TIME_ZONES: TIME_ZONES, timeZoneGroups: timeZoneGroups, timeZoneLabel: timeZoneLabel,
    ntpServerList: ntpServerList, timeEntries: timeEntries, timeStatusModel: timeStatusModel,
    VOLUME_LEVELS: VOLUME_LEVELS, VOLUME_DEFAULTS: VOLUME_DEFAULTS,
    volumeEntries: volumeEntries, deviceVolumeEntries: deviceVolumeEntries,
    effectiveVolumes: effectiveVolumes,
    NOTICE_MAX_CHARS: NOTICE_MAX_CHARS, NOTICE_PRESET_KEYS: NOTICE_PRESET_KEYS,
    NOTICE_EXPIRY_PRESETS: NOTICE_EXPIRY_PRESETS, noticeExpiryMs: noticeExpiryMs,
    noticePayload: noticePayload, noticeModel: noticeModel, countCharacters: countCharacters,
    SOS_TRIGGER_MODES: SOS_TRIGGER_MODES, sosEntries: sosEntries, powerModel: powerModel,
    INK_REGIONS: INK_REGIONS, APPEARANCE_MODES: APPEARANCE_MODES,
    autoInk: autoInk, autoAccent: autoAccent, themeAutoModel: themeAutoModel,
    appearanceEntries: appearanceEntries, appearanceModel: appearanceModel,
    themeColorEntries: themeColorEntries,
    NOTICE_PRESET_MAX: NOTICE_PRESET_MAX, noticePresetEntries: noticePresetEntries,
    noticePresetList: noticePresetList, effectiveNoticeModel: effectiveNoticeModel,
    doorUnlockEntries: doorUnlockEntries, doorUnlockModel: doorUnlockModel,
    doorRows: doorRows,
    writeWarnings: writeWarnings,
    webSosEntries: webSosEntries, runtimeHealthRows: runtimeHealthRows,
    flattenConfig: flattenConfig, applyKey: applyKey, deleteKey: deleteKey,
    newId: newId, safeId: safeId,

    ASSET_MAX_BYTES: ASSET_MAX_BYTES, ASSET_TYPES: ASSET_TYPES,
    assetTypeOf: assetTypeOf, assetRefHash: assetRefHash, assetRefs: assetRefs,
    fmtBytes: fmtBytes, audioObj: audioObj,
    themeKey: themeKey, themeEntries: themeEntries,
    purposeEntries: purposeEntries, purposeReorderEntries: purposeReorderEntries,
    uiEntries: uiEntries,
    placeholders: placeholders, placeholderDiff: placeholderDiff, i18nEntries: i18nEntries,

    PAIR_ERR_CODES: PAIR_ERR_CODES, PAIR_STATES: PAIR_STATES,
    PAIR_ROW_LINGER_MS: PAIR_ROW_LINGER_MS,
    pairErrKey: pairErrKey, pairClock: pairClock, pairDeviceLabel: pairDeviceLabel,
    pairDeviceDetail: pairDeviceDetail, pairMergeRows: pairMergeRows,
    pairRowModel: pairRowModel, pairPanelModel: pairPanelModel,
    pairJoinPayload: pairJoinPayload, pairQrParse: pairQrParse,
    pairQrTextValid: pairQrTextValid,
    qrModules: qrModules
  };
})();

if (typeof module !== "undefined" && module.exports) module.exports = AdminLogic;

/* ================================================================ 2. UI */
if (typeof document !== "undefined") (function () {
  "use strict";
  var L = AdminLogic;

  function qs(name) {
    var m = new RegExp("[?&]" + name + "=([^&]*)").exec(window.location.search);
    return m ? decodeURIComponent(m[1]) : "";
  }
  var MOCK = qs("mock") === "1";
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  var LANG = qs("lang") || lsGet("db_admin_lang") || "ja";

  var I18N = {};
  function t(k, def) { return I18N[k] || def || k; }
  function fmt(s, vars) {
    return s.replace(/\{(\w+)\}/g, function (m, n) { return vars[n] !== undefined ? vars[n] : m; });
  }

  function icon(n) { return "<svg class='ic'><use href='#i-" + n + "'/></svg>"; }


  function copyText(text, btn) {
    function flash(ok) {
      if (!btn) return;
      var orig = btn.getAttribute("data-orig") || btn.innerHTML;
      btn.setAttribute("data-orig", orig);
      btn.textContent = ok ? t("admin.copied") : t("admin.copy_failed");
      setTimeout(function () { btn.innerHTML = orig; }, 1200);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { flash(true); },
                                               function () { fallback(); });
    } else { fallback(); }
    function fallback() {
      try {
        var ta = document.createElement("textarea");
        ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        var ok = document.execCommand("copy");
        document.body.removeChild(ta); flash(ok);
      } catch (e) { flash(false); }
    }
  }
  function $(s) { return document.querySelector(s); }
  function $all(s, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(s));
  }
  function show(el, on) { el.classList[on ? "remove" : "add"]("hidden"); }
  function msg(s) {
    var m = $("#msg");
    m.textContent = s;
    m.style.opacity = 1;
    setTimeout(function () { m.style.opacity = 0; }, 2400);
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  // AdminLogic's own isObj is scoped to its module, so the UI needs its own copy.
  function isObj(v) { return v !== null && typeof v === "object" && !(v instanceof Array); }

  /* Mock data uses the same rendering functions as live data. */
  var MOCK_ID1 = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
  var MOCK_ID2 = "0f1e2d3c4b5a69788766554433221100";

  /* The pairing mock is a small state machine so the whole flow -- unpaired host, add, join,
   * invite failure, PIN expiry, bulk add -- can be exercised without hardware. */
  var MOCK_PAIR = {
    state: qs("pair") || "ready",
    founder: true,
    tokenPin: "",
    tokenUntil: 0,
    tokenAttempts: 3,
    modeUntil: 0,
    autoAdded: 0,
    devices: [
      { id: "newpad01aa22bb33cc44dd55ee66ff7788", name: "newpad", role: "indoor_panel",
        addr: "10.10.38.55:47172", model: "Nexus 7", platform: "android", sw: "0.1.0",
        seen: 0, invite_state: "none", attempts: 0, last_error: "", fate: "join", due: 0 },
      { id: "oldbell99887766554433221100aabbcc", name: "", role: "door_station",
        addr: "10.10.38.56:47172", model: "iPad 1", platform: "ios", sw: "0.1.0",
        seen: 0, invite_state: "none", attempts: 0, last_error: "", fate: "fail", due: 0 }]
  };

  function mockPairInvite(id, manual) {
    for (var i = 0; i < MOCK_PAIR.devices.length; i++) {
      var d = MOCK_PAIR.devices[i];
      if (d.id !== id || d.invite_state === "sent") continue;
      d.invite_state = "sent";
      d.attempts = manual ? 1 : 0;
      d.last_error = "";
      d.due = new Date().getTime() + (d.fate === "join" ? 3000 : 6000);
      return true;
    }
    return false;
  }

  function mockPairTick() {
    var now = new Date().getTime(), keep = [], i, d;
    for (i = 0; i < MOCK_PAIR.devices.length; i++) {
      d = MOCK_PAIR.devices[i];
      if (!d.seen) d.seen = now;
      if (d.invite_state === "sent" && d.due && now >= d.due) {
        if (d.fate === "join") {
          MOCK_STATUS.peers.push({ id: d.id, name: d.name || d.model, role: d.role,
                                   status: "alive", sw: d.sw, addrs: [d.addr] });
          if (now < MOCK_PAIR.modeUntil) MOCK_PAIR.autoAdded++;
          continue;
        }
        d.invite_state = "failed";
        d.last_error = "no_ack";
        d.attempts = 3;
      }
      keep.push(d);
    }
    MOCK_PAIR.devices = keep;
    if (now < MOCK_PAIR.modeUntil)
      for (i = 0; i < MOCK_PAIR.devices.length; i++) mockPairInvite(MOCK_PAIR.devices[i].id, false);
  }

  function mockPairSnapshot() {
    mockPairTick();
    var now = new Date().getTime(), devices = [], i, d;
    var active = MOCK_PAIR.tokenUntil > now;
    for (i = 0; i < MOCK_PAIR.devices.length; i++) {
      d = MOCK_PAIR.devices[i];
      devices.push({ id: d.id, addr: d.addr, name: d.name, role: d.role, model: d.model,
                     platform: d.platform, sw: d.sw,
                     age_s: Math.round((now - d.seen) / 1000), invite_state: d.invite_state,
                     attempts: d.attempts, last_error: d.last_error });
    }
    var paired = MOCK_PAIR.state === "ready" || MOCK_PAIR.state === "persist_error";
    return {
      state: MOCK_PAIR.state,
      paired: paired,
      persistence_ready: MOCK_PAIR.state !== "persist_error",
      is_founder: MOCK_PAIR.founder,
      psk_source: paired ? "secure_store" : "none",
      psk_ref: paired ? "secret:mesh.psk" : null,
      role: "door_station",
      self: { id: MOCK_ID1, addr: "10.10.38.9:47172", name: "front-panel", role: "door_station",
              pk: "de".repeat(32), model: "Pixel 4a", platform: "android", sw: "0.1.0" },
      pair_qr: "doorbell-pair:10.10.38.9:47172|" + MOCK_ID1 + "|" + "de".repeat(32),
      home: { member_count: MOCK_STATUS.peers.length,
              connected_count: MOCK_STATUS.peers.length - 1 },
      token: { active: active, expires_s: active ? Math.round((MOCK_PAIR.tokenUntil - now) / 1000) : 0,
               attempts_left: active ? MOCK_PAIR.tokenAttempts : 0,
               host: "10.10.38.9:47172", pin: active ? MOCK_PAIR.tokenPin : undefined },
      pending: { pairing_mode: MOCK_PAIR.modeUntil > now,
                 pairing_mode_left_s: Math.max(0, Math.round((MOCK_PAIR.modeUntil - now) / 1000)),
                 auto_added_count: MOCK_PAIR.autoAdded,
                 devices: paired ? devices : [] }
    };
  }

  function mockPairMintToken() {
    MOCK_PAIR.tokenPin = String(100000 + Math.floor(Math.random() * 899999));
    MOCK_PAIR.tokenUntil = new Date().getTime() + 90000;
    MOCK_PAIR.tokenAttempts = 3;
  }

  var MOCK_IMG = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff";
  var MOCK_WAV = "99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa";
  var MOCK_CFG = {
    schema_version: 1,
    buildings: { b_main: { label: { en: "Main House" } },
                 b_annex: { label: { en: "Annex" } } },
    doors: { d_front: { building: "b_main", label: { en: "Front door" },
                        notice: { text: "Deliveries to the side gate today",
                                  from_device: MOCK_ID2, created_ms: Date.now() - 600000,
                                  expires_ms: Date.now() + 3600000 } },
             d_back: { building: "b_main", label: { en: "Back door" } } },
    devices: (function () {
      var d = {};
      d[MOCK_ID1] = { name: "front-panel", role: "door_station", door: "d_front",
                      local: { ui_lang: "ja",
                               camera: { device_hint: "", mjpeg_fps: 8, mjpeg_quality: 60,
                                         resolution: "640x480", codec: "auto",
                                         h264_resolution: "640x360", h264_fps: 30,
                                         h264_bitrate_kbps: 700 },
                               theme: { bg_color: "#1c1030" },
                               motion: { enabled: true, sensitivity: 40, min_interval_s: 30 } } };
      d[MOCK_ID2] = { name: "living", role: "indoor_panel",
                      local: { audio: { volume: { call: 40, sos: 100, idle: 25 } } } };
      return d;
    })(),
    households: { h_ox: { label: { en: "Owner" }, telegram_chat_ids: [123456789],
                          sip_extensions: ["201"] } },
    quick_replies: {
      qr_away: { label: { en: "Nobody is home" }, speak: true,
                 order: 1, audio: { en: MOCK_WAV } },
      qr_no: { label: { en: "No, thank you" }, speak: true, order: 2 },
      qr_wait: { label: { en: "Please wait" }, speak: true, order: 3 } },
    visit_purposes: {
      p_visit: { label: { en: "Visit" }, icon: "🏠", order: 1 },
      p_disabled: { label: { en: "Sales" }, icon: "💼", order: 9, enabled: false },
      p_delivery: { label: { en: "Delivery" }, icon: "📦", order: 2 },
      p_mail: { label: { en: "Mail" }, icon: "✉️", order: 3 },
      p_sales: { label: { en: "Sales" }, icon: "💼", order: 4 },
      p_work: { label: { en: "Utility" }, icon: "🔧", order: 5 },
      p_other: { label: { en: "Other" }, icon: "❓", order: 6 } },
    ui: { languages: ["ja", "en", "zh"], visitor_lang_revert_s: 60,
          launch_sound: "title_display", call_sound: "outdoor_call_alert",
          call_sound_loop: false, button_sound: "button_click",
          update_sound: "indoor_update", ringtone: "school_chime" },
    i18n_overrides: { en: { "idle.touch_to_call": "Touch to call" } },
    display: { theme: { bg_color: "#12202c", bg_image: MOCK_IMG }, brightness: 70,
               appearance: "auto_schedule",
               appearance_schedule: { dark_from: "19:00", light_from: "06:30" },
               screensaver_after_s: 120, pixel_shift_s: 300 },
    assets: (function () {
      var a = {};
      a[MOCK_IMG] = { size: 812345, type: "image/jpeg", origin: MOCK_ID1, label: "front-door.jpg" };
      a[MOCK_WAV] = { size: 48210, type: "audio/wav", origin: MOCK_ID1, label: "nobody-home.wav" };
      return a;
    })(),
    trigger_rules: {
      r1: { enabled: true, when: { type: "button", doors: ["d_front", "d_back"] },
            schedule: { always: true },
            actions: [{ type: "sip_call", target_extension: "600" },
                      { type: "telegram", households: ["h_ox"], with_snapshot: true },
                      { type: "ha_event" }, { type: "chime", sound: "ding1" }] },
      r3: { enabled: true, when: { type: "motion", doors: ["d_front"] },
            schedule: { windows: [{ days: ["mon", "tue", "wed", "thu", "fri"],
                                    from: "22:00", to: "06:00" }] },
            actions: [{ type: "telegram", households: ["h_ox"], with_snapshot: true }] },
      r4: { enabled: false, when: { type: "device_offline", devices: "all" },
            actions: [{ type: "telegram", households: ["h_ox"] }] },
      r_sos_default_on: { enabled: true, when: { type: "emergency_on" },
        actions: [{ type: "device_alert", targets: { roles: "all", web_profiles: "all" },
          channels: ["in_app", "system_notification", "web_push"], never_suppress: true,
          presentation: { visual: true, sticky: true, ttl_s: 0 } },
          { type: "telegram", never_suppress: true, households: "all" }] },
      r_sos_default_off: { enabled: true, when: { type: "emergency_off" },
        actions: [{ type: "device_alert", targets: { roles: "all", web_profiles: "all" },
          channels: ["in_app", "system_notification", "web_push"], never_suppress: true,
          presentation: { visual: true, sticky: false, ttl_s: 10 } },
          { type: "telegram", never_suppress: true, households: "all" }] } },
    quiet_hours: { "default": { windows: [{ from: "23:00", to: "07:00" }],
                                suppress: ["chime"],
                                never_suppress: ["sip_call", "telegram", "ha_event"] } },
    integrations: { mqtt: { host: "10.0.1.5", port: 1883, user: "doorbell" },
                    telegram: { poll_updates: true }, tz_offset_min: 540 },
    sip: { server: "10.0.1.5", port: 5060, transport: "udp",
           accounts: (function () {
             var a = {}; a[MOCK_ID1] = { user: "door-front" }; return a;
           })() },
    panel: { token_refs: ["secret:panel.access.mock"] },
    time: { zone: "Asia/Tokyo",
            ntp: { enabled: true, servers: ["ntp.nict.jp", "time.google.com"],
                   interval_s: 900 } },
    notice: { presets: [{ id: "np_absent", text: "不在です。荷物は玄関前へお願いします" },
                        { id: "np_back_door", text: "裏口へお回りください" },
                        { id: "np_construction", text: "工事中です。足元にご注意ください" }] },
    audio: { volume: { call: 80, sos: 100, idle: 60 } },
    emergency: { web_active_page_alerts: true, button_on_roles: ["indoor_panel"],
                 cancel_requires_pin: true, alarm_sound: "siren1", alarm_volume: 100,
                 trigger: { mode: "slide", countdown_s: 3 } },
    reply: { display_ttl_s: 30 }
  };
  var MOCK_STATUS = {
    node: { id: MOCK_ID1, name: "front-panel", role: "door_station", version: "0.1.0",
            power: { battery_pct: -1, charging: false, mains: true },
            local_addrs: ["10.10.38.147", "240b:250:a0c4:5710:daa2:5eff:fe65:ff19",
                          "fd40:174a:3820:10:daa2:5eff:fe65:ff19"] },
    self: { id: MOCK_ID1, name: "front-panel", role: "door_station", version: "0.1.0",
            power: { battery_pct: -1, charging: false, mains: true } },
    time: { zone: "Asia/Tokyo", zone_known: true, source: "ntp", enabled: true, ok: true,
            offset_ms: 412, measured_offset_ms: 412, last_sync_ms: Date.now() - 120000,
            rtt_ms: 18, server: "ntp.nict.jp", interval_s: 900, offset_min: 540,
            syncing: false,
            local: { iso: "2026-09-02T21:30:00+09:00", date: "2026-09-02", hh: 21, mm: 30,
                     ss: 0, weekday: "wed", weekday_num: 3, offset_min: 540, dst: false,
                     known: true, wall_ms: Date.now(), tz: "Asia/Tokyo" } },
    display: { brightness: 70,
               appearance: { configured: "auto_schedule", effective: "dark",
                             follow_system: false,
                             schedule: { dark_from: "19:00", light_from: "06:30" } },
               theme: { bg_color: "#12202c",
                        auto_background: { color: "#12202c", source: "color" },
                        auto_ink: { clock: "light", date: "light", status_line: "light",
                                    hint: "light", tile_label: "light", footer: "light",
                                    notice: "light" },
                        auto_accent: { call_button: "#7F5E3D", call_button_ink: "light" },
                        ink_override: {},
                        call_button_bg: "#7F5E3D", call_button_ink: "light" } },
    doors: {
      d_front: { label: "Front door", configured: true, notice: null,
                 unlock: { configured: true, command: "unlock", show_button: true,
                           source: "default" } },
      d_back: { label: "Back door", configured: true, notice: null,
                unlock: { configured: false, command: "", show_button: false,
                          source: "default" } },
      // A door a live station serves that configuration has never heard of: the tile still
      // renders and is still addressable, and naming it is the doors tab's job.
      d_annex: { label: "annex-panel", configured: false, notice: null,
                 unlock: { configured: false, command: "", show_button: false,
                           source: "default" } } },
    notice: { global_active: false },
    call: { state: "idle", mic_muted: false },
    ui_manifest: L.defaultUiManifest("door_station"),
    features: { call_flow_v2: true, emergency_rules_v1: true, device_alert_v1: true },
    emergency: { active: false, device: "", wall_ms: 0 },
    web_push: { subscriptions: 0, configured: false, delivery_backend: false },
    sip: { registered: false, state: "idle", call: "idle" },
    leaders: { telegram: MOCK_ID1, mqtt_bridge: MOCK_ID1 },
    bridge: { mqtt: "connected", telegram: "active" },
    assets: { cached: 1, total: 2 },
    peers: [
      { id: MOCK_ID1, name: "front-panel", role: "door_station", status: "alive", self: true,
        sw: "0.1.0", addrs: ["10.0.1.10:47172"], door: "d_front", door_label: "Front door",
        power: { battery_pct: -1, charging: false, mains: true } },
      { id: MOCK_ID2, name: "living", role: "indoor_panel", status: "dead", sw: "0.1.0",
        features: { call_flow_v2: true }, addrs: [],
        power: { battery_pct: 82, charging: true, mains: true } }]
  };
  var MOCK_EVENTS = [
    { type: "press", door: "d_front", device: MOCK_ID1, wall_ms: Date.now() - 60000, payload: "{}" },
    { type: "reply", door: "d_front", device: MOCK_ID2, wall_ms: Date.now() - 50000,
      payload: "{\"text\":\"I will be right there\"}" },
    { type: "motion", door: "d_front", device: MOCK_ID1, wall_ms: Date.now() - 30000,
      payload: "{\"changed_pct\":12}" },
    { type: "offline", door: "", device: MOCK_ID2, wall_ms: Date.now() - 10000, payload: "{}" }];

  function mockHash(seed) {
    var h = "";
    for (var i = 0; i < 8; i++) {
      var x = 0, s = seed + "#" + i;
      for (var j = 0; j < s.length; j++) x = ((x << 5) - x + s.charCodeAt(j)) | 0;
      h += ("00000000" + (x >>> 0).toString(16)).slice(-8);
    }
    return h;
  }

  /* Core recomputes the effective unlock visibility from configuration; the mock does the same
     so the standalone panel shows what a real node would. */
  function mockRefreshDoorStatus() {
    var doors = MOCK_STATUS.doors || {};
    for (var id in doors) {
      var configured = doors[id].unlock ? doors[id].unlock.configured === true : false;
      var override = ((MOCK_CFG.doors || {})[id] || {}).unlock;
      var forced = override && typeof override.show_button === "boolean"
        ? override.show_button : null;
      doors[id].unlock = { configured: configured,
                           command: configured ? "unlock" : "",
                           show_button: forced === null ? configured : forced,
                           source: forced === null ? "default" : "admin" };
      // Core reports a door as configured once an entry exists, however it came to exist.
      doors[id].configured = !!((MOCK_CFG.doors || {})[id]);
      var notice = ((MOCK_CFG.doors || {})[id] || {}).notice ||
                   ((MOCK_CFG.notice || {}).global || null);
      doors[id].notice = notice || null;
    }
  }

  function mockApi(method, path, body, cb) {
    var p = path.split("?")[0];
    function ok(j) { setTimeout(function () { cb(200, j); }, 0); }
    if (method === "GET") {
      if (p === "/api/status") return ok(MOCK_STATUS);
      if (p === "/api/config") return ok(MOCK_CFG);
      if (p === "/api/events") return ok({ events: MOCK_EVENTS });
      if (p === "/api/logs") return ok({ logs: ["I mock: this is a mock log entry"] });
      if (p === "/api/pairing") return ok(mockPairSnapshot());
      return setTimeout(function () { cb(404, null); }, 0);
    }
    if (method === "DELETE" && p.indexOf("/api/assets/") === 0) {
      L.deleteKey(MOCK_CFG, "assets." + p.slice("/api/assets/".length));
      MOCK_STATUS.assets = { cached: 0, total: 0 };
      for (var dh in (MOCK_CFG.assets || {})) MOCK_STATUS.assets.total++;
      MOCK_STATUS.assets.cached = MOCK_STATUS.assets.total;
      return ok({ ok: true });
    }

    if (p === "/api/assets") {
      var hash = mockHash((body && body.label) + ":" + (body && body.size));
      MOCK_CFG.assets = MOCK_CFG.assets || {};
      MOCK_CFG.assets[hash] = { size: (body && body.size) || 0, type: (body && body.type) || "",
                                origin: MOCK_ID1, label: (body && body.label) || "" };
      MOCK_STATUS.assets = { cached: 0, total: 0 };
      for (var k in MOCK_CFG.assets) MOCK_STATUS.assets.total++;
      MOCK_STATUS.assets.cached = MOCK_STATUS.assets.total - 1;
      return ok({ ok: true, hash: hash });
    }
    if (p === "/api/login") return ok({ ok: true });
    if (p === "/api/time/sync") {
      if (!((MOCK_CFG.time || {}).ntp || {}).enabled)
        return setTimeout(function () { cb(409, { ok: false, err: "ntp_disabled" }); }, 0);
      MOCK_STATUS.time = JSON.parse(JSON.stringify(MOCK_STATUS.time));
      MOCK_STATUS.time.last_sync_ms = new Date().getTime();
      MOCK_STATUS.time.offset_ms = 250 + Math.floor(Math.random() * 200);
      MOCK_STATUS.time.measured_offset_ms = MOCK_STATUS.time.offset_ms;
      MOCK_STATUS.time.rtt_ms = 12 + Math.floor(Math.random() * 30);
      MOCK_STATUS.time.source = "ntp";
      MOCK_STATUS.time.ok = true;
      return ok({ ok: true, started: true });
    }
    if (p === "/api/notice") {
      MOCK_CFG.notice = MOCK_CFG.notice || {};
      if (method === "DELETE") {
        delete MOCK_CFG.notice.global;
        MOCK_STATUS.notice = { global_active: false };
        return ok({ ok: true });
      }
      var globalText = String((body && body.text) || "");
      if (!globalText || L.countCharacters(globalText) > L.NOTICE_MAX_CHARS)
        return setTimeout(function () { cb(400, { ok: false, err: "rejected" }); }, 0);
      var globalExpires = (body && body.expires_ms) || 0;
      if (!globalExpires && body && body.ttl_s)
        globalExpires = new Date().getTime() + body.ttl_s * 1000;
      MOCK_CFG.notice.global = { text: globalText, from_device: MOCK_ID1,
                                 created_ms: new Date().getTime(),
                                 expires_ms: globalExpires };
      MOCK_STATUS.notice = { global_active: true };
      return ok({ ok: true });
    }
    if (/^\/api\/doors\/[^\/]+\/open$/.test(p)) {
      var openDoor = decodeURIComponent(p.split("/")[3]);
      var openEntry = (MOCK_STATUS.doors || {})[openDoor];
      if (!openEntry) return setTimeout(function () { cb(404, { ok: false, err: "unknown_door" }); }, 0);
      if (!openEntry.unlock || !openEntry.unlock.configured)
        return setTimeout(function () {
          cb(409, { ok: false, err: "unlock_not_configured" });
        }, 0);
      return ok({ ok: true });
    }
    if (/^\/api\/doors\/[^\/]+\/notice$/.test(p)) {
      var noticeDoor = decodeURIComponent(p.split("/")[3]);
      // A door served by a live station is addressable even before it has a config entry; the
      // first write creates one, exactly as core does.
      if (!(MOCK_CFG.doors || {})[noticeDoor] && (MOCK_STATUS.doors || {})[noticeDoor]) {
        MOCK_CFG.doors = MOCK_CFG.doors || {};
        MOCK_CFG.doors[noticeDoor] = { label: { ja: MOCK_STATUS.doors[noticeDoor].label } };
      }
      var doorEntry = (MOCK_CFG.doors || {})[noticeDoor];
      if (!doorEntry) return setTimeout(function () { cb(400, { ok: false, err: "rejected" }); }, 0);
      if (method === "DELETE") { delete doorEntry.notice; return ok({ ok: true }); }
      var noticeText = String((body && body.text) || "");
      if (!noticeText || L.countCharacters(noticeText) > L.NOTICE_MAX_CHARS)
        return setTimeout(function () { cb(400, { ok: false, err: "rejected" }); }, 0);
      var expires = (body && body.expires_ms) || 0;
      if (!expires && body && body.ttl_s) expires = new Date().getTime() + body.ttl_s * 1000;
      doorEntry.notice = { text: noticeText, from_device: MOCK_ID1,
                           created_ms: new Date().getTime(), expires_ms: expires };
      return ok({ ok: true });
    }
    if (p === "/api/secrets") return ok({ ok: true });
    if (p === "/api/emergency") {
      MOCK_STATUS.emergency = { active: !!(body && body.active), device: MOCK_ID1,
                                wall_ms: new Date().getTime() };
      return ok({ ok: true });
    }
    if (p === "/api/config/batch") {
      var ops = (body && body.ops) || [], nextCfg, oi;
      try { nextCfg = JSON.parse(JSON.stringify(MOCK_CFG)); }
      catch (cloneErr) { return setTimeout(function () { cb(500, { ok: false, err: "clone" }); }, 0); }
      for (oi = 0; oi < ops.length; oi++) {
        if (!ops[oi].key || (ops[oi].op !== "set" && ops[oi].op !== "delete"))
          return setTimeout(function () { cb(400, { ok: false, err: "bad op" }); }, 0);
        if (ops[oi].op === "set") L.applyKey(nextCfg, ops[oi].key, JSON.stringify(ops[oi].value));
        else L.deleteKey(nextCfg, ops[oi].key);
      }
      MOCK_CFG = nextCfg;
      mockRefreshDoorStatus();
      // Mirror the server's advisory contrast reporting so the inline warning path is exercised
      // without a real node.
      var mockWarnings = [];
      function mockMeasure(colour, against, key, property, floor) {
        if (typeof colour !== "string" || !L.colorOk(colour) || !L.colorOk(against)) return;
        var ratio = L.contrast(colour, against);
        if (ratio >= floor) return;
        mockWarnings.push({ key: key, property: property,
                            contrast: Math.round(ratio * 10) / 10,
                            message_key: "theme.low_contrast" });
      }
      for (oi = 0; oi < ops.length; oi++) {
        if (ops[oi].op !== "set") continue;
        var key = String(ops[oi].key || "");
        var against = ((MOCK_CFG.display || {}).theme || {}).bg_color || "#101418";
        // The Theme tab writes the whole theme object, so the colours are inspected in place.
        if (/(^display|\.local)\.theme$/.test(key) && L.isPlainObject(ops[oi].value)) {
          var themeValue = ops[oi].value;
          if (L.colorOk(themeValue.bg_color)) against = themeValue.bg_color;
          mockMeasure(themeValue.call_button_bg, against, key + ".call_button_bg",
                      "call_button_bg", 3);
          for (var region in (themeValue.ink_override || {}))
            mockMeasure(themeValue.ink_override[region], against,
                        key + ".ink_override." + region, region, 4.5);
          continue;
        }
        if (key.indexOf("call_button_bg") >= 0)
          mockMeasure(ops[oi].value, against, key, "call_button_bg", 3);
        else if (key.indexOf("ink_override.") >= 0)
          mockMeasure(ops[oi].value, against, key, key.split(".").pop(), 4.5);
      }
      var batchResult = { ok: true, n: ops.length, revision: "mock-" + Date.now() };
      if (mockWarnings.length) batchResult.warnings = mockWarnings;
      return ok(batchResult);
    }
    if (p === "/api/config") { L.applyKey(MOCK_CFG, body.key, body.value); return ok({ ok: true }); }
    if (p === "/api/config/delete") { L.deleteKey(MOCK_CFG, body.key); return ok({ ok: true }); }
    if (p === "/api/config/import") {
      var n = 0, es = (body && body.entries) || [];
      for (var i = 0; i < es.length; i++)
        if (es[i].key) { L.applyKey(MOCK_CFG, es[i].key, JSON.stringify(es[i].value)); n++; }
      return ok({ ok: true, n: n });
    }
    if (p === "/api/join-token" || p === "/api/pairing/start") {
      if (MOCK_PAIR.state !== "ready")
        return setTimeout(function () { cb(409, { ok: false, err: "host_unpaired" }); }, 0);
      mockPairMintToken();
      // Only the explicit bulk-add button opens the auto-invite window; minting a PIN does not.
      if (p === "/api/pairing/start") {
        MOCK_PAIR.modeUntil = new Date().getTime() + 600000;
        MOCK_PAIR.autoAdded = 0;
      }
      return ok({ ok: true, host: "10.10.38.9:47172", pin: MOCK_PAIR.tokenPin, expires_s: 90 });
    }
    if (p === "/api/pairing/mode") {
      if (MOCK_PAIR.state !== "ready")
        return setTimeout(function () { cb(409, { ok: false, err: "host_unpaired" }); }, 0);
      MOCK_PAIR.modeUntil = new Date().getTime() + 600000;
      MOCK_PAIR.autoAdded = 0;
      return ok({ ok: true, seconds: 600 });
    }
    if (p === "/api/pairing/stop") { MOCK_PAIR.modeUntil = 0; return ok({ ok: true }); }
    if (p === "/api/pairing/found") {
      if (MOCK_PAIR.state === "ready")
        return setTimeout(function () { cb(409, { ok: false, err: "already_paired" }); }, 0);
      MOCK_PAIR.state = "ready";
      MOCK_PAIR.founder = true;
      return ok({ ok: true });
    }
    if (p === "/api/pairing/join") {
      if (MOCK_PAIR.state === "ready")
        return setTimeout(function () { cb(409, { ok: false, err: "already_paired" }); }, 0);
      if (!body || body.pin !== "424242")
        return setTimeout(function () { cb(200, { ok: false, err: "bad_pin" }); }, 0);
      MOCK_PAIR.state = "joining";
      MOCK_PAIR.founder = false;
      setTimeout(function () { MOCK_PAIR.state = "ready"; }, 2500);
      return ok({ ok: true, pending: true });
    }
    if (p === "/api/pairing/retry-persist") {
      MOCK_PAIR.state = "ready";
      return ok({ ok: true });
    }
    if (p === "/api/pairing/unpair") {
      MOCK_PAIR.state = "unpaired";
      MOCK_PAIR.founder = false;
      MOCK_PAIR.tokenUntil = 0;
      MOCK_PAIR.modeUntil = 0;
      return ok({ ok: true });
    }
    if (p === "/api/pairing/deny") {
      if (!body || !body.id) return setTimeout(function () { cb(400, { ok: false, err: "no_id" }); }, 0);
      MOCK_PAIR.devices = MOCK_PAIR.devices.filter(function (d) { return d.id !== body.id; });
      return ok({ ok: true });
    }
    if (p === "/api/pairing/scan" || p === "/api/pairing/invite-direct") {
      var parsed = L.pairQrParse((body && (body.text || body.qr)) || "");
      if (!parsed) return setTimeout(function () { cb(400, { ok: false, err: "bad_qr" }); }, 0);
      MOCK_PAIR.devices.push({ id: parsed.id, name: "", role: "indoor_panel", addr: parsed.addr,
        model: "scanned", platform: "web", sw: "0.1.0", seen: new Date().getTime(),
        invite_state: "none", attempts: 0, last_error: "", fate: "join", due: 0 });
      mockPairInvite(parsed.id, true);
      return ok({ ok: true });
    }
    if (p === "/api/pairing/invite") {
      if (!body || !body.id) return setTimeout(function () { cb(400, { ok: false, err: "no_id" }); }, 0);
      if (!mockPairInvite(body.id, true))
        return setTimeout(function () { cb(400, { ok: false, err: "unknown_device" }); }, 0);
      return ok({ ok: true });
    }
    if (p === "/api/test/telegram") return ok({ ok: true });
    if (p === "/api/panel-token/rotate") {
      var tok = "mock" + Math.random().toString(16).slice(2, 10);
      MOCK_CFG.panel = { token_refs: ["secret:panel.access.mock"],
                         token_generation: "0123456789abcdef0123456789abcdef" };
      return ok({ ok: true, token: tok });
    }
    if (p === "/api/panel-token/provision") return ok({ ok: true });
    return setTimeout(function () { cb(404, null); }, 0);
  }

  /* ---------------- API ---------------- */
  function api(method, path, body, cb) {
    if (MOCK && path.indexOf("/locale/") !== 0) return mockApi(method, path, body, cb);
    var x = new XMLHttpRequest();
    x.open(method, path, true);
    x.setRequestHeader("X-Requested-With", "doorbell-admin");
    if (body) x.setRequestHeader("Content-Type", "application/json");
    x.onreadystatechange = function () {
      if (x.readyState !== 4) return;
      if (x.status === 401) { show($("#app"), false); show($("#login"), true); return; }
      var j = null;
      try { j = JSON.parse(x.responseText); } catch (e) {}
      cb(x.status, j);
    };
    x.send(body ? JSON.stringify(body) : null);
  }

  // Commit every set/delete in one request and preserve values as JSON. The server validates
  // before an all-or-nothing commit; never fall back to legacy sequential partial writes.
  function postEntries(entries, dels, cb) {
    var ops;
    try { ops = L.configBatchOps(entries, dels); }
    catch (e) { cb(false, { err: e.message }); return; }
    if (!ops.length) { cb(true, { ok: true, n: 0 }); return; }
    api("POST", "/api/config/batch", { ops: ops }, function (st, j) {
      if (st === 200 && j && j.ok === true) { cb(true, j); return; }
      cb(false, { unavailable: st === 404 || st === 501, status: st,
                  err: (j && j.err) || ("HTTP " + st) });
    });
  }

  function postSecrets(writes, cb) {
    writes = writes || [];
    var i = 0, written = [];
    function next() {
      if (i >= writes.length) { cb(true, { ok: true, written: written }); return; }
      var write = writes[i++];
      api("POST", "/api/secrets", write, function (st, j) {
        if (st === 200 && j && j.ok === true) {
          written.push(write.secret_ref); next(); return;
        }
        cb(false, { status: st, err: (j && j.err) || ("HTTP " + st), written: written });
      });
    }
    next();
  }

  function deleteSecrets(refs, cb) {
    refs = refs || [];
    var i = 0, failed = [];
    function next() {
      if (i >= refs.length) { cb(failed.length === 0, failed); return; }
      var ref = refs[i++];
      api("DELETE", "/api/secrets", { secret_ref: ref }, function (st, j) {
        if (!(st === 200 && j && j.ok === true)) failed.push(ref);
        next();
      });
    }
    next();
  }

  function showSaveResult(ok, result, cleanupFailed) {
    var text = t("admin.save_failed");
    if (ok) text = t("admin.saved");
    else if (result && result.unavailable)
      text = t("admin.atomic_batch_unavailable");
    else if (result && result.err) text += ": " + result.err;
    if (cleanupFailed && cleanupFailed.length)
      text += " (" + t("admin.secret_cleanup_deferred")
        .replace("{n}", String(cleanupFailed.length)) + ")";
    msg(text);
    refreshConfig(function () { renderTab(); });
  }

  function savePlanAndRefresh(plan) {
    postSecrets(plan.secrets, function (secretsOk, secretResult) {
      if (!secretsOk) {
        deleteSecrets(secretResult.written || [], function (_, failed) {
          showSaveResult(false, secretResult, failed);
        });
        return;
      }
      postEntries(plan.entries, plan.dels || null, function (ok, result) {
        // New material is written under a fresh ref. A failed config transaction therefore leaves
        // the live account on its old credential; only the unreferenced staged value is removed.
        var cleanup = ok ? (plan.retire_secret_refs || []) : (secretResult.written || []);
        deleteSecrets(cleanup, function (_, failed) { showSaveResult(ok, result, failed); });
      });
    });
  }


  // A readability warning is not a failure: the value is saved and the measured ratio is what
  // the operator needs to see. Rendered next to the save result rather than swallowing it.
  function warningText(warnings) {
    var parts = [];
    for (var i = 0; i < warnings.length && i < 3; i++)
      parts.push(fmt(t(warnings[i].message_key), { ratio: warnings[i].contrast }));
    return parts.join(" / ");
  }

  function saveAndRefresh(entries, dels, done) {
    postEntries(entries, dels, function (ok, result) {
      var text = t("admin.save_failed");
      if (ok) {
        text = t("admin.saved");
        var warnings = L.writeWarnings(result);
        if (warnings.length) text += " — " + warningText(warnings);
      } else if (result && result.unavailable)
        text = t("admin.atomic_batch_unavailable");
      else if (result && result.err) text += ": " + result.err;
      msg(text);
      refreshConfig(function () { renderTab(); if (done) done(ok); });
    });
  }



  var S = { cfg: {}, status: {}, events: [], tab: "dash", locales: {}, panelToken: "" };

  function cfgObj(k) { return (S.cfg && S.cfg[k]) || {}; }
  function doorLabel(id) { return L.labelOf(cfgObj("doors")[id], LANG, id); }
  function deviceName(id) {
    var d = cfgObj("devices")[id];
    return (d && d.name) || (id ? id.slice(0, 8) : "");
  }
  function householdLabel(id) { return L.labelOf(cfgObj("households")[id], LANG, id); }
  function peerOf(id) {
    var ps = S.status.peers || [];
    for (var i = 0; i < ps.length; i++) if (ps[i].id === id) return ps[i];
    return null;
  }

  function refreshConfig(cb) {
    api("GET", "/api/config", null, function (st, j) {
      if (st === 200 && j) S.cfg = j;
      if (cb) cb();
    });
  }
  function refreshStatus(cb) {
    api("GET", "/api/status", null, function (st, j) {
      if (st === 200 && j) S.status = j;
      if (cb) cb();
    });
  }
  function refreshEvents(cb) {
    api("GET", "/api/events?limit=100", null, function (st, j) {
      if (st === 200 && j) S.events = j.events || [];
      if (cb) cb();
    });
  }



  var PURPOSE_ICONS = ["🏠", "📦", "✉️", "💼", "🔧", "❓", "🚚", "🍽️", "🧹"];

  // fields: [{id,label,type,value,options,ph,hint}]
  //   type: text|password|number|time|select|check|multicheck|textarea|static|icon|audio


  function fieldHtml(f) {
    var lab = "<label class='flab'>" + esc(f.label) + "</label>";
    var v = f.value === undefined || f.value === null ? "" : f.value;
    if (f.type === "check")
      return "<div class='frow frow-check'><label><input type='checkbox' data-f='" + esc(f.id) +
             "'" + (f.value ? " checked" : "") + "> " + esc(f.label) + "</label></div>";
    if (f.type === "select") {
      var o = "";
      for (var i = 0; i < (f.options || []).length; i++) {
        var op = f.options[i];
        o += "<option value='" + esc(op.v) + "'" + (op.v === f.value ? " selected" : "") + ">" +
             esc(op.label) + "</option>";
      }
      return "<div class='frow'>" + lab + "<select data-f='" + esc(f.id) + "'>" + o +
             "</select></div>";
    }
    if (f.type === "multicheck") {
      var c = "";
      for (var k = 0; k < (f.options || []).length; k++) {
        var mo = f.options[k];
        var on = (f.value || []).indexOf(mo.v) >= 0;
        c += "<label class='mc'><input type='checkbox' data-mc='" + esc(f.id) + "' value='" +
             esc(mo.v) + "'" + (on ? " checked" : "") + "> " + esc(mo.label) + "</label>";
      }
      return "<div class='frow'>" + lab + "<div class='mcwrap'>" + c + "</div></div>";
    }
    if (f.type === "audio") {
      var ao = "";
      for (var ai = 0; ai < (f.options || []).length; ai++) {
        var aop = f.options[ai];
        ao += "<option value='" + esc(aop.v) + "'" + (aop.v === f.value ? " selected" : "") +
              ">" + esc(aop.label) + "</option>";
      }
      return "<div class='frow'>" + lab + "<select data-f='" + esc(f.id) + "'>" + ao +
             "</select> <button class='btn2' data-audioplay='" + esc(f.id) + "'>▶ " +
             esc(t("admin.audio_play")) + "</button></div>";
    }
    if (f.type === "icon") {
      var ib = "";
      for (var ii = 0; ii < PURPOSE_ICONS.length; ii++)
        ib += "<button class='btn2' data-iconpick='" + esc(f.id) + "' data-icon='" +
              esc(PURPOSE_ICONS[ii]) + "'>" + esc(PURPOSE_ICONS[ii]) + "</button>";
      return "<div class='frow'>" + lab + "<input type='text' data-f='" + esc(f.id) +
             "' value='" + esc(v) + "' maxlength='4' style='width:90px'>" +
             "<div class='iconpick'>" + ib + "</div></div>";
    }
    if (f.type === "textarea")
      return "<div class='frow'>" + lab + "<textarea data-f='" + esc(f.id) +
             "' style='min-height:80px'>" + esc(v) + "</textarea></div>";
    if (f.type === "static")
      return "<div class='frow'>" + lab + "<div class='dim'>" + esc(v) + "</div></div>";
    return "<div class='frow'>" + lab + "<input type='" + (f.type || "text") + "' data-f='" +
           esc(f.id) + "' value='" + esc(v) + "'" +
           (f.ph ? " placeholder='" + esc(f.ph) + "'" : "") + ">" +
           (f.hint ? "<div class='dim fhint'>" + esc(f.hint) + "</div>" : "") + "</div>";
  }

  function collectFields(root, fields) {
    var out = {};
    for (var i = 0; i < fields.length; i++) {
      var f = fields[i];
      if (f.type === "static") continue;
      if (f.type === "check") {
        var cb = root.querySelector("[data-f='" + f.id + "']");
        out[f.id] = cb ? cb.checked : false;
      } else if (f.type === "multicheck") {
        var vals = [];
        $all("[data-mc='" + f.id + "']", root).forEach(function (el) {
          if (el.checked) vals.push(el.value);
        });
        out[f.id] = vals;
      } else if (f.type === "number") {
        var ne = root.querySelector("[data-f='" + f.id + "']");
        out[f.id] = ne ? ne.value : "";
      } else {
        var el2 = root.querySelector("[data-f='" + f.id + "']");
        out[f.id] = el2 ? el2.value : "";
      }
    }
    return out;
  }

  function openModal(title, bodyHtml, onSave) {
    var m = $("#modal");
    m.innerHTML =
      "<div class='mbox card'><h2>" + esc(title) + "</h2><div class='mbody'>" + bodyHtml +
      "</div><div class='mbtns'>" +
      "<button class='btn' id='mSave'>" + esc(t("admin.save")) + "</button>" +
      "<button class='btn ghost' id='mCancel'>" + esc(t("admin.cancel")) +
      "</button></div></div>";
    show(m, true);
    $("#mCancel").onclick = function () { show(m, false); };
    $("#mSave").onclick = function () {
      var err = onSave(m);
      if (err) { msg(err); return; }
      show(m, false);
    };
    return m;
  }

  function openForm(title, fields, onSave) {
    var html = "";
    for (var i = 0; i < fields.length; i++) html += fieldHtml(fields[i]);
    return openModal(title, html, function (m) {
      return onSave(collectFields(m, fields));
    });
  }


  var audioEl = null;
  function playAsset(hash, gainScale) {
    if (!hash) { msg(t("admin.audio_none")); return; }
    if (MOCK) { msg(fmt(t("admin.mock_audio_play"), { value: hash.slice(0, 12) + "…" })); return; }
    if (!audioEl) audioEl = new Audio();
    audioEl.pause();
    audioEl.src = "/asset/" + hash;
    audioEl.volume = gainScale === undefined ? 1 : gainScale;
    audioEl.play();
  }

  var ringtoneCtx = null;
  // gain is 0..1 so a volume preview rehearses the configured level in this browser.
  function playPresetRingtone(name, gainScale) {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { msg(t("admin.audio_preview_unsupported")); return; }
    if (!ringtoneCtx) ringtoneCtx = new AC();
    var seq = name === "classic" ? [[659, 0, .55], [523, .72, .55], [784, 1.42, .55]] :
              name === "ding2" ? [[659, 0, .38], [988, .58, .57]] :
              [[880, 0, .42], [1175, .50, .70]];
    var peak = 0.22 * (gainScale === undefined ? 1 : gainScale);
    if (peak < 0.0002) return;
    var now = ringtoneCtx.currentTime + .03;
    seq.forEach(function (s) {
      var osc = ringtoneCtx.createOscillator(), gain = ringtoneCtx.createGain();
      osc.frequency.value = s[0];
      gain.gain.setValueAtTime(0.0001, now + s[1]);
      gain.gain.exponentialRampToValueAtTime(peak, now + s[1] + .02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + s[1] + s[2]);
      osc.connect(gain); gain.connect(ringtoneCtx.destination);
      osc.start(now + s[1]); osc.stop(now + s[1] + s[2] + .02);
    });
  }
  // volume is the configured 0..100 level, or undefined to play at the browser's own level.
  function playRingtone(value, volume) {
    var scale = volume === undefined ? 1 : Math.max(0, Math.min(100, volume)) / 100;
    if (!value) { msg(t("admin.audio_none")); return; }
    if (value.indexOf("asset:") === 0) { playAsset(value.slice(6), scale); return; }
    if (BUILTIN_AUDIO[value]) {
      if (MOCK) { msg(fmt(t("admin.mock_audio_play"), { value: value })); return; }
      if (!audioEl) audioEl = new Audio();
      audioEl.pause();
      audioEl.src = "/audio/" + BUILTIN_AUDIO[value];
      audioEl.currentTime = 0;
      audioEl.volume = scale;
      audioEl.play();
      return;
    }
    playPresetRingtone(value, scale);
  }


  function bindIconPick(root) {
    $all("[data-iconpick]", root).forEach(function (b) {
      b.onclick = function () {
        var inp = root.querySelector("[data-f='" + b.getAttribute("data-iconpick") + "']");
        if (inp) inp.value = b.getAttribute("data-icon");
      };
    });
  }
  function bindAudioPlay(root) {
    $all("[data-audioplay]", root).forEach(function (b) {
      b.onclick = function () {
        var sel = root.querySelector("[data-f='" + b.getAttribute("data-audioplay") + "']");
        playAsset(sel ? sel.value : "");
      };
    });
  }

  function confirmDelete(name, doIt) {
    if (window.confirm(fmt(t("admin.confirm_delete"), { name: name })))
      doIt();
  }


  function doorOptions(withEmpty) {
    var o = withEmpty ? [{ v: "", label: "—" }] : [];
    var ds = cfgObj("doors");
    for (var id in ds) o.push({ v: id, label: doorLabel(id) + " (" + id + ")" });
    return o;
  }
  function buildingOptions() {
    var o = [{ v: "", label: "—" }];
    var bs = cfgObj("buildings");
    for (var id in bs) o.push({ v: id, label: L.labelOf(bs[id], LANG, id) + " (" + id + ")" });
    return o;
  }
  function deviceOptions() {
    var o = [];
    var ds = cfgObj("devices");
    for (var id in ds)
      o.push({ v: id, label: deviceName(id) + " (" + id.slice(0, 8) + ")" });
    return o;
  }
  function householdOptions() {
    var o = [];
    var hs = cfgObj("households");
    for (var id in hs) o.push({ v: id, label: householdLabel(id) + " (" + id + ")" });
    return o;
  }

  var LANG_NAME_KEYS = { ja: "language.name_ja", en: "language.name_en",
                         zh: "language.name_zh", ko: "language.name_ko",
                         pt: "language.name_pt", es: "language.name_es",
                         vi: "language.name_vi" };
  function langName(l) {
    return LANG_NAME_KEYS[l] ? t(LANG_NAME_KEYS[l]) + " (" + l + ")" : l;
  }
  function uiLangs() {
    var ls = (cfgObj("ui") || {}).languages;
    return (ls instanceof Array && ls.length) ? ls : ["ja"];
  }


  function assetIds(kind) {
    var as = cfgObj("assets"), ids = [];
    for (var h in as) {
      var ty = as[h].type || "";
      if (kind === "image" && ty.indexOf("image/") !== 0) continue;
      if (kind === "audio" && ty.indexOf("audio/") !== 0) continue;
      ids.push(h);
    }
    ids.sort(function (a, b) {
      var la = as[a].label || a, lb = as[b].label || b;
      return la < lb ? -1 : (la > lb ? 1 : (a < b ? -1 : 1));
    });
    return ids;
  }
  function assetLabel(hash) {
    var a = cfgObj("assets")[hash];
    return (a && a.label) || (hash ? hash.slice(0, 12) + "…" : "");
  }
  function assetOptions(kind, emptyLabel) {
    var o = [{ v: "", label: emptyLabel }];
    assetIds(kind).forEach(function (h) {
      o.push({ v: h, label: assetLabel(h) + " (" + h.slice(0, 8) + ")" });
    });
    return o;
  }

  var RINGTONE_PRESETS = [
    { v: "ding1", label: "Ding Dong" },
    { v: "ding2", label: "Double Chime" },
    { v: "classic", label: "Classic Bell" },
    { v: "school_chime", label: t("sound.school_chime") }
  ];
  var SOUND_PRESETS = [
    { v: "outdoor_call_alert", label: t("sound.outdoor_call_alert") },
    { v: "button_click", label: t("sound.button_click") },
    { v: "school_chime", label: t("sound.school_chime") },
    { v: "indoor_update", label: t("sound.indoor_update") },
    { v: "title_display", label: t("sound.title_display") }
  ];
  var BUILTIN_AUDIO = {
    outdoor_call_alert: "outdoor_call_alert.mp3",
    button_click: "button_click.mp3",
    school_chime: "school_chime.mp3",
    indoor_update: "indoor_update.mp3",
    title_display: "title_display.mp3"
  };
  function soundOptions(includeNone) {
    var o = includeNone ? [{ v: "", label: t("sound.none") }] : [];
    o = o.concat(SOUND_PRESETS);
    assetIds("audio").forEach(function (h) {
      o.push({ v: "asset:" + h, label: "♫ " + assetLabel(h) + " (" + h.slice(0, 8) + ")" });
    });
    return o;
  }
  function ringtoneOptions() {
    var o = RINGTONE_PRESETS.slice();
    assetIds("audio").forEach(function (h) {
      o.push({ v: "asset:" + h, label: "♫ " + assetLabel(h) + " (" + h.slice(0, 8) + ")" });
    });
    return o;
  }

  var DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  function dayLabel(d) { return t("day." + d); }

  function fmtTime(ms) {
    if (!ms) return "-";
    var d = new Date(ms);
    function p(n) { return n < 10 ? "0" + n : n; }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " +
           p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }




  function renderDash() {
    var j = S.status;
    var emergency = j.emergency && j.emergency.active === true;
    if ($("#adminEmergency")) show($("#adminEmergency"), emergency);
    if ($("#adminEmergencyCancel")) $("#adminEmergencyCancel").onclick = function () {
      if (!window.confirm(t("admin.sos_clear_confirm"))) return;
      api("POST", "/api/emergency", { active: false }, function (st, result) {
        if (st === 200 && result && result.ok) {
          msg(t("admin.sos_cleared")); refreshStatus(renderDash);
        } else msg(t("admin.sos_clear_failed"));
      });
    };
    var rows = "";
    var peers = j.peers || [];
    for (var i = 0; i < peers.length; i++) {
      var p = peers[i];
      var stCls = p.status === "alive" ? "ok" : (p.status === "suspect" ? "warn" : "err");
      var duties = [];
      if (j.leaders) for (var d in j.leaders) if (j.leaders[d] === p.id) duties.push(d);
      var power = L.powerModel(p.power);
      var powerCell = !power.known ? "<span class='dim'>" + esc(t("power.unknown")) + "</span>" :
        (!power.hasBattery ? "<span class='dim'>" + esc(t("power.no_battery")) + "</span>" :
          "<span class='" + (power.pct <= 15 && !power.charging ? "err" : "") + "'>" +
          esc(power.text) + "</span>" +
          (power.charging ? " <span class='tag ok'>" + esc(t("power.charging")) + "</span>" : ""));
      rows += "<tr><td>" + esc(p.name || p.id.slice(0, 8)) +
              (p.self ? " <span class='tag'>self</span>" : "") + "</td><td>" +
              esc(p.role || "") + "</td><td class='" + stCls + "'>" + esc(p.status) +
              "</td><td>" + esc(duties.join(",")) + "</td><td>" + esc(p.sw || "") +
              "</td><td>" + powerCell +
              "</td><td class='dim'>" + esc((p.addrs || []).join(" ")) + "</td></tr>";
    }
    $("#peersTbl tbody").innerHTML = rows;
    var br = j.bridge || {};
    $("#bridgeInfo").textContent =
      "MQTT: " + (br.mqtt || "-") + " / Telegram: " + (br.telegram || "-") +
      (j.sip ? " / SIP: " + j.sip.state : "");

    var la = (j.node && j.node.local_addrs) || [];
    var laEl = $("#localAddrs");
    if (laEl) {
      if (la.length) {
        laEl.innerHTML = icon("info-box") + " " + t("admin.local_addrs") + ": " +
          la.map(function (a) { return esc(a); }).join("　");
      } else { laEl.textContent = ""; }
    }



    var grid = $("#liveGrid"), want = {};
    for (var li = 0; li < peers.length; li++) {
      var pp = peers[li];
      if (pp.stream && pp.status === "alive") want[pp.id] = pp;
    }
    var cards = $all("[data-node]", grid);
    for (var ci = 0; ci < cards.length; ci++) {
      var id = cards[ci].getAttribute("data-node");
      if (!want[id]) {
        stopLiveStream(id);
        grid.removeChild(cards[ci]);
      } else {
        var wantedMp4 = DoorbellPlayback.proxyMp4Url(want[id].door || "", "",
                                                      want[id].stream_mp4, window.location);
        var wantedKey = want[id].stream + "|" + wantedMp4 + "|" +
                        JSON.stringify(want[id].playback_profile || {});
        if (cards[ci].getAttribute("data-playback-key") === wantedKey) {
          delete want[id];
        } else {
          stopLiveStream(id);
          grid.removeChild(cards[ci]);
        }
      }
    }
    for (var nid in want) {
      var p2 = want[nid], card = document.createElement("div");
      card.className = "card";
      card.setAttribute("data-node", nid);
      var sameOriginMp4 = DoorbellPlayback.proxyMp4Url(p2.door || "", "", p2.stream_mp4,
                                                        window.location);
      card.setAttribute("data-playback-key", p2.stream + "|" + sameOriginMp4 + "|" +
                        JSON.stringify(p2.playback_profile || {}));
      card.innerHTML = "<div class='dim' style='margin-bottom:6px'>" +
        esc(p2.door_label || p2.name || nid.slice(0, 8)) + "</div>";
      var mediaCss = "width:100%; border-radius:6px; background:#000; min-height:160px";
      var v = document.createElement("video");
      v.muted = true;
      v.autoplay = true;
      v.setAttribute("muted", "");
      v.setAttribute("playsinline", "");
      v.style.cssText = mediaCss;
      var img = document.createElement("img");
      img.alt = "live";
      img.style.cssText = mediaCss;
      card.appendChild(img);
      card.appendChild(v);
      liveStreams[nid] = DoorbellPlayback.start({ profile: p2.playback_profile,
        mp4: sameOriginMp4, mjpeg: p2.stream, mjpegMode: "image", video: v, img: img });
      grid.appendChild(card);
    }
  }

  /* ---- Admin dashboard live grid ---- */
  var liveStreams = {};    // node_id → {stop}

  function stopLiveStream(id) {
    if (liveStreams[id]) { try { liveStreams[id].stop(); } catch (e) {} delete liveStreams[id]; }
  }


  function editBuilding(id) {
    var isNew = !id;
    var cur = isNew ? {} : cfgObj("buildings")[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "bid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("b", cfgObj("buildings")) : id },
      { id: "ja", label: t("admin.label_ja"), value: lb.ja },
      { id: "en", label: t("admin.label_en"), value: lb.en },
      { id: "zh", label: t("admin.label_zh"), value: lb.zh }];
    openForm(t("admin.buildings"), fields, function (v) {
      var bid = isNew ? L.safeId(v.bid) : id;
      if (!bid) return "ID?";
      saveAndRefresh(L.buildingEntries(bid, v, cur), null);
    });
  }

  function editDoor(id) {
    var isNew = !id;
    var cur = isNew ? {} : cfgObj("doors")[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "did", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("d", cfgObj("doors")) : id },
      { id: "ja", label: t("admin.label_ja"), value: lb.ja },
      { id: "en", label: t("admin.label_en"), value: lb.en },
      { id: "zh", label: t("admin.label_zh"), value: lb.zh },
      { id: "building", label: t("admin.building_assign"), type: "select",
        value: cur.building || "", options: buildingOptions() }];
    openForm(t("admin.door_list"), fields, function (v) {
      var did = isNew ? L.safeId(v.did) : id;
      if (!did) return "ID?";
      saveAndRefresh(L.doorEntries(did, v, cur), null);
    });
  }



  /* ---- announcement presets, the unlock toggle, and the announcement target ---- */

  function collectNoticePresets(root) {
    var rows = $all("[data-preset-row]", root), out = [];
    for (var i = 0; i < rows.length; i++) {
      var input = rows[i].querySelector("[data-preset-text]");
      if (!input) continue;
      var text = input.value.replace(/^\s+|\s+$/g, "");
      if (!text) continue;
      out.push({ id: input.getAttribute("data-preset-id"), text: text });
    }
    return out;
  }

  function saveNoticePresets(root) {
    var entries;
    try { entries = L.noticePresetEntries(collectNoticePresets(root)); }
    catch (e) {
      msg(t(e.message === "notice.presets_max" ? "notice.presets_full" :
            "notice.preset_invalid"));
      return;
    }
    saveAndRefresh(entries, null);
  }

  function addNoticePreset() {
    var presets = L.noticePresetList(S.cfg);
    if (presets.length >= L.NOTICE_PRESET_MAX) { msg(t("notice.presets_full")); return; }
    openForm(t("notice.preset_add"),
             [{ id: "text", label: t("notice.text"), type: "textarea" }], function (v) {
      var text = String(v.text || "").replace(/^\s+|\s+$/g, "");
      if (!text) return t("notice.empty");
      if (L.countCharacters(text) > L.NOTICE_MAX_CHARS)
        return fmt(t("notice.too_long"), { n: L.countCharacters(text) });
      presets.push({ id: L.newId("np", presetIdMap(presets)), text: text });
      var entries;
      try { entries = L.noticePresetEntries(presets); }
      catch (e) { return t("notice.preset_invalid"); }
      saveAndRefresh(entries, null);
      return "";
    });
  }

  function presetIdMap(presets) {
    var map = {};
    for (var i = 0; i < presets.length; i++) map[presets[i].id] = true;
    return map;
  }

  function deleteNoticePreset(id) {
    var presets = L.noticePresetList(S.cfg).filter(function (p) { return p.id !== id; });
    saveAndRefresh(L.noticePresetEntries(presets), null);
  }

  function editDoorUnlock(door) {
    var model = L.doorUnlockModel(door, S.cfg, S.status);
    var current = ((cfgObj("doors")[door] || {}).unlock) || {};
    var fields = [
      { id: "mode", label: t("unlock.title"), type: "select", value: model.mode,
        options: [{ v: "auto", label: t("unlock.auto") },
                  { v: "show", label: t("unlock.show") },
                  { v: "hide", label: t("unlock.hide") }] },
      { id: "state", label: t("unlock.command"), type: "static",
        value: model.configured ? model.command : t("unlock.not_configured") }];
    openForm(doorLabel(door), fields, function (v) {
      var plan = L.doorUnlockEntries(door, v.mode, current);
      saveAndRefresh(plan.entries, plan.dels);
    });
  }

  /* Announcements are not written through the config batch: core stamps the author and the
     creation time itself, so the editor posts to /api/doors/<id>/notice. */
  function editDoorNotice(door) {
    var model = L.noticeModel(door, cfgObj("doors"), new Date().getTime());
    // The presets come from configuration, so the web editor and the indoor dialog offer the
    // same list and an administrator can change it in one place.
    var presetList = L.noticePresetList(S.cfg);
    var presets = "";
    for (var pi = 0; pi < presetList.length; pi++)
      presets += "<button class='btn2 small' data-notice-preset='" +
        esc(presetList[pi].text) + "'>" + esc(presetList[pi].text) + "</button> ";
    var expirySelected = model.active && !model.expiresMs ? "until_cleared" : "1h";
    var body = "<div class='frow'><label class='flab'>" + esc(t("notice.target")) + "</label>" +
      "<select id='noticeTarget'><option value='" + esc(door) + "'>" + esc(doorLabel(door)) +
      "</option><option value='*'>" + esc(t("notice.target_global")) + "</option></select></div>" +
      "<div class='frow'><label class='flab'>" + esc(t("notice.text")) + "</label>" +
      "<textarea id='noticeText' maxlength='400' style='min-height:80px'>" +
      esc(model.text) + "</textarea>" +
      "<div class='dim fhint'><span id='noticeCount'>0</span> / " + L.NOTICE_MAX_CHARS +
      "</div></div><div class='frow'>" + presets + "</div>" +
      "<div class='frow'><label class='flab'>" + esc(t("notice.expiry")) + "</label>" +
      "<select id='noticeExpiry'>" +
      "<option value='1h'" + (expirySelected === "1h" ? " selected" : "") + ">" +
      esc(t("notice.expiry_1h")) + "</option>" +
      "<option value='today'>" + esc(t("notice.expiry_today")) + "</option>" +
      "<option value='until_cleared'" +
      (expirySelected === "until_cleared" ? " selected" : "") + ">" +
      esc(t("notice.expiry_until_cleared")) + "</option>" +
      "<option value='custom'>" + esc(t("notice.expiry_custom")) + "</option></select></div>" +
      "<div class='frow' id='noticeCustomRow' style='display:none'><label class='flab'>" +
      esc(t("notice.expiry_hours")) + "</label>" +
      "<input type='number' id='noticeHours' min='1' max='8760' value='4'></div>" +
      "<h3 style='margin-top:12px'>" + esc(t("notice.preview")) + "</h3>" +
      "<div id='noticePreview' style='padding:10px 14px;border-radius:8px;" +
      "background:#101418;border:1px solid var(--line);white-space:pre-wrap'></div>";

    var modal = openModal(t("notice.title"), body, function (m) {
      var offsetMin = L.timeStatusModel(S.status).zone ?
        ((S.status.time || {}).offset_min || 0) : 0;
      var plan = L.noticePayload({ text: m.querySelector("#noticeText").value,
                                   expiry: m.querySelector("#noticeExpiry").value,
                                   custom_hours: m.querySelector("#noticeHours").value },
                                 new Date().getTime(), offsetMin);
      if (plan.error) return plan.n === undefined ? t(plan.error) :
        fmt(t(plan.error), { n: plan.n });
      var target = m.querySelector("#noticeTarget").value;
      var path = target === "*" ? "/api/notice"
                                : "/api/doors/" + encodeURIComponent(target) + "/notice";
      api("POST", path, plan.body,
          function (st, result) {
            if (st === 200 && result && result.ok) {
              msg(t("notice.saved"));
              refreshConfig(function () { renderTab(); });
            } else msg(t("notice.failed"));
          });
      return "";
    });
    var root = modal || document.querySelector("#modal");
    var text = root.querySelector("#noticeText");
    var count = root.querySelector("#noticeCount");
    var preview = root.querySelector("#noticePreview");
    var expiry = root.querySelector("#noticeExpiry");
    function sync() {
      var length = L.countCharacters(text.value);
      count.textContent = length;
      count.className = length > L.NOTICE_MAX_CHARS ? "err" : "";
      preview.textContent = text.value || t("notice.none");
      root.querySelector("#noticeCustomRow").style.display =
        expiry.value === "custom" ? "" : "none";
    }
    text.oninput = sync;
    expiry.onchange = sync;
    $all("[data-notice-preset]", root).forEach(function (button) {
      button.onclick = function () {
        text.value = button.getAttribute("data-notice-preset");
        sync();
      };
    });
    sync();
  }

  function clearDoorNotice(door) {
    api("DELETE",
        door === "*" ? "/api/notice" : "/api/doors/" + encodeURIComponent(door) + "/notice",
        null,
        function (st, result) {
          if (st === 200 && result && result.ok) {
            msg(t("notice.cleared"));
            refreshConfig(function () { renderTab(); });
          } else msg(t("notice.failed"));
        });
  }

  function renderDoors() {
    var el = $("#tab-doors");
    var bs = cfgObj("buildings"), ds = cfgObj("doors");
    var h = "<div class='card'><div class='chead'><h2>" + esc(t("admin.buildings")) +
            "</h2><button class='btn small' data-act='addB'>+ " +
            esc(t("admin.add_building")) + "</button></div><table><thead><tr>" +
            "<th>ID</th><th>ja</th><th>en</th><th>zh</th><th></th></tr></thead><tbody>";
    for (var b in bs) {
      var lb = bs[b].label || {};
      h += "<tr><td class='dim'>" + esc(b) + "</td><td>" + esc(lb.ja || "") + "</td><td>" +
           esc(lb.en || "") + "</td><td>" + esc(lb.zh || "") + "</td><td class='ops'>" +
           "<button class='btn2' data-act='editB' data-id='" + esc(b) + "'>" +
           esc(t("admin.edit")) + "</button> <button class='btn2 danger' data-act='delB' data-id='" +
           esc(b) + "'>" + esc(t("admin.delete")) + "</button></td></tr>";
    }
    h += "</tbody></table></div>";
    h += "<div class='card'><div class='chead'><h2>" + esc(t("admin.door_list")) +
         "</h2><button class='btn small' data-act='addD'>+ " +
         esc(t("admin.add_door")) + "</button></div><table><thead><tr>" +
         "<th>ID</th><th>" + esc(t("admin.label_ja")) + "</th><th>" +
         esc(t("admin.building_assign")) + "</th><th>" + esc(t("notice.title")) +
         "</th><th>" + esc(t("unlock.title")) + "</th><th></th></tr></thead><tbody>";
    L.doorRows(S.cfg, S.status).forEach(function (row) {
      var d = row.id;
      var noticeModel = L.effectiveNoticeModel(d, S.cfg, new Date().getTime());
      var unlockModel = L.doorUnlockModel(d, S.cfg, S.status);
      h += "<tr" + (row.configured ? "" : " class='offline'") + "><td class='dim'>" + esc(d) +
           "</td><td>" + esc(row.label) +
           (row.configured ? "" : " <span class='tag warn'>" +
             esc(t("admin.door_unconfigured")) + "</span>") + "</td><td>" +
           esc((ds[d] && ds[d].building) ?
             L.labelOf(bs[ds[d].building], LANG, ds[d].building) : "—") +
           "</td><td>" + (noticeModel.active ?
             "<span class='tag ok'>" +
             esc(noticeModel.scope === "global" ? t("notice.scope_global") : t("notice.active")) +
             "</span> " + esc(noticeModel.text) +
             (noticeModel.expiresMs ? "<div class='dim fhint'>" +
               esc(t("notice.expires_at")) + ": " + esc(fmtTime(noticeModel.expiresMs)) +
               "</div>" : "") :
             "<span class='dim'>" + esc(t("notice.none")) + "</span>") +
           "</td><td>" +
           (unlockModel.showButton ? "<span class='tag ok'>" + esc(t("unlock.show")) + "</span>"
                                   : "<span class='dim'>" + esc(t("unlock.hide")) + "</span>") +
           (unlockModel.configured ? "" : "<div class='dim fhint'>" +
             esc(t("unlock.not_configured")) + "</div>") +
           "</td><td class='ops'><button class='btn2' data-act='editD' data-id='" + esc(d) +
           "'>" + esc(t("admin.edit")) +
           "</button> <button class='btn2' data-act='notice' data-id='" + esc(d) + "'>" +
           esc(t("notice.title")) + "</button>" +
           " <button class='btn2' data-act='unlock' data-id='" + esc(d) + "'>" +
           esc(t("unlock.title")) + "</button>" +
           (noticeModel.active && noticeModel.scope === "door" ?
             " <button class='btn2 danger' data-act='noticeClear' data-id='" +
             esc(d) + "'>" + esc(t("notice.clear")) + "</button>" : "") +
           (row.configured ? " <button class='btn2 danger' data-act='delD' data-id='" + esc(d) +
             "'>" + esc(t("admin.delete")) + "</button>" : "") + "</td></tr>";
    });
    h += "</tbody></table></div>";

    // Announcement presets: the same list the indoor dialog and the editor below render.
    var presets = L.noticePresetList(S.cfg);
    h += "<div class='card'><div class='chead'><h2>" + esc(t("notice.presets_title")) +
         "</h2><button class='btn small' data-act='addPreset'>+ " +
         esc(t("notice.preset_add")) + "</button></div><div id='noticePresetRows'>";
    for (var pi = 0; pi < presets.length; pi++)
      h += "<div class='frow' data-preset-row><input type='text' data-preset-text value='" +
           esc(presets[pi].text) + "' maxlength='400' style='flex:1'" +
           " data-preset-id='" + esc(presets[pi].id) + "'>" +
           " <button class='btn2 danger' data-act='delPreset' data-id='" + esc(presets[pi].id) +
           "'>" + esc(t("admin.delete")) + "</button></div>";
    if (!presets.length)
      h += "<div class='dim fhint'>" + esc(t("notice.none")) + "</div>";
    h += "</div><button class='btn small' data-act='savePresets' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";

    el.innerHTML = h;
    bindActs(el, {
      addPreset: function () { addNoticePreset(); },
      delPreset: function (id) { deleteNoticePreset(id); },
      savePresets: function () { saveNoticePresets(el); },
      unlock: function (id) { editDoorUnlock(id); },
      addB: function () { editBuilding(null); },
      editB: function (id) { editBuilding(id); },
      delB: function (id) {
        confirmDelete(id, function () { saveAndRefresh(null, ["buildings." + id]); });
      },
      addD: function () { editDoor(null); },
      editD: function (id) { editDoor(id); },
      notice: function (id) { editDoorNotice(id); },
      noticeClear: function (id) { clearDoorNotice(id); },
      delD: function (id) {
        confirmDelete(doorLabel(id), function () { saveAndRefresh(null, ["doors." + id]); });
      }
    });
  }


  function bindActs(root, handlers) {
    $all("[data-act]", root).forEach(function (b) {
      var act = b.getAttribute("data-act");
      if (handlers[act])
        b.onclick = function () { handlers[act](b.getAttribute("data-id")); };
    });
  }


  function editDevice(id) {
    var d = cfgObj("devices")[id] || {};
    var lo = d.local || {}, cam = lo.camera || {}, mo = lo.motion || {}, video = lo.video || {},
      recovery = lo.recovery || {};
    var fields = [
      { id: "nid", label: "ID", type: "static", value: id },
      { id: "name", label: t("admin.dev_name"), value: d.name },
      { id: "role", label: t("admin.dev_role"), type: "select",
        value: d.role || "door_station",
        options: [{ v: "door_station", label: t("admin.role_door") },
                  { v: "indoor_panel", label: t("admin.role_indoor") }] },
      { id: "door", label: t("admin.door_assign"), type: "select",
        value: d.door || "", options: doorOptions(true) },
      { id: "ui_lang", label: t("admin.ui_lang"), type: "select",
        value: lo.ui_lang || "ja",
        options: [{ v: "ja", label: t("language.name_ja") },
                  { v: "en", label: t("language.name_en") },
                  { v: "zh", label: t("language.name_zh") }] },
      { id: "helper_mode", label: t("admin.helper_mode"), type: "select",
        value: recovery.helper_mode || "auto",
        options: [{ v: "auto", label: t("admin.helper_auto") },
                  { v: "on", label: t("admin.helper_on") },
                  { v: "off", label: t("admin.helper_off") }] },
      { id: "video_playback", label: t("admin.video_playback"),
        type: "select", value: video.playback || "low_latency",
        options: [
          { v: "low_latency", label: t("admin.video_low_latency") },
          { v: "hls", label: t("admin.video_hls") },
          { v: "mjpeg", label: "MJPEG" }
        ] },
      { id: "video_rotation", label: t("admin.video_rotation"),
        type: "select", value: video.rotation === undefined ? "auto" : String(video.rotation),
        options: [
          { v: "auto", label: t("admin.rotation_auto") },
          { v: "0", label: "0°" }, { v: "90", label: "90°" },
          { v: "180", label: "180°" }, { v: "270", label: "270°" }
        ] },
      { id: "cam_fps", label: t("admin.cam_fps"), type: "number",
        value: cam.mjpeg_fps !== undefined ? cam.mjpeg_fps : 8 },
      { id: "cam_quality", label: t("admin.cam_quality"), type: "number",
        value: cam.mjpeg_quality !== undefined ? cam.mjpeg_quality : 60 },
      { id: "cam_resolution", label: t("admin.cam_resolution"),
        value: cam.resolution || "640x480", ph: "640x480" },
      { id: "cam_hint", label: t("admin.cam_hint"), value: cam.device_hint },

      { id: "cam_codec", label: t("admin.cam_codec"), type: "select",
        value: cam.codec || "auto",
        options: [{ v: "auto", label: t("admin.codec_auto") },
                  { v: "mjpeg", label: "MJPEG" },
                  { v: "h264", label: "H.264" }] },
      { id: "cam_h264_resolution", label: t("admin.cam_h264_resolution"),
        value: cam.h264_resolution || "640x360", ph: "640x360" },
      { id: "cam_h264_fps", label: t("admin.cam_h264_fps"),
        type: "number", value: cam.h264_fps !== undefined ? cam.h264_fps : 30 },
      { id: "cam_h264_bitrate", label: t("admin.cam_h264_bitrate"),
        type: "number",
        value: cam.h264_bitrate_kbps !== undefined ? cam.h264_bitrate_kbps : 700 },
      { id: "motion_enabled", label: t("admin.motion"), type: "check",
        value: mo.enabled !== false },
      { id: "motion_sensitivity", label: t("admin.motion_sensitivity"), type: "number",
        value: mo.sensitivity !== undefined ? mo.sensitivity : 40 },
      { id: "motion_interval", label: t("admin.motion_interval"),
        type: "number", value: mo.min_interval_s !== undefined ? mo.min_interval_s : 30 },
      { id: "caps_override", label: t("admin.caps_override"),
        type: "textarea", value: d.caps_override ? JSON.stringify(d.caps_override) : "" }];
    openForm(t("admin.devices"), fields, function (v) {
      var caps = null;
      var ct = (v.caps_override || "").replace(/^\s+|\s+$/g, "");
      if (ct) {
        try { caps = JSON.parse(ct); } catch (e) { return "caps_override: JSON?"; }
        if (caps === null || typeof caps !== "object") return "caps_override: JSON?";
      }
      v.caps_override = caps;
      saveAndRefresh(L.deviceEntries(id, v, d), null);
    });
  }

  function editDeviceUi(id, surface) {
    var d = cfgObj("devices")[id] || {}, lo = d.local || {}, ui = lo.ui || {};
    var peer = peerOf(id) || {}, selfId = (S.status.node || {}).id || "";
    var self = id === selfId, web = surface === "web";
    if (web && !self) { msg("Web UI manifest is available only on this node"); return; }
    var peerFeatures = isObj(peer.features) ? peer.features :
      (isObj(peer.caps) && isObj(peer.caps.features) ? peer.caps.features : {});
    if (!web && !self && peerFeatures.ui_manifest_v1 !== true) {
      msg("ui_manifest unavailable: the target has not measured ui_manifest_v1"); return;
    }
    var advertised = web ? ((S.status.web_ui || {}).manifest || null) :
      (self ? S.status.ui_manifest : peer.ui_manifest);
    var runtimeManifest = advertised && typeof advertised === "object" &&
      !(advertised instanceof Array) && Object.keys(advertised).length ? advertised : null;
    if (!runtimeManifest) {
      msg(t("admin.ui_manifest_unreported")); return;
    }
    var source = !self && peer.cached_contract ? "last-valid cached runtime status" :
                 "runtime status";
    var manifest = runtimeManifest;
    var mv = L.validateUiManifest(manifest);
    if (!mv.ok) { msg("ui_manifest unavailable/invalid: " + mv.errors[0]); return; }
    var elements = ui.elements || {}, legacy = ui.style || {}, lp = legacy.palette || {};
    var runtime = self ? (S.status.runtime || {}) : (peer.runtime || {});
    var applyReport = web ? (runtime.web_ui_style || null) :
      (runtime.ui_style || runtime.semantic_ui || null);
    function legacyValue(prop) {
      if (prop === "scale" || prop === "font_scale") return legacy.text_scale || 1;
      if (prop === "foreground") return lp.text || "#e8edf2";
      if (prop === "background") return lp.surface || lp.background || "#1a2027";
      if (prop === "accent" || prop === "border") return lp.accent || "#4da3ff";
      if (prop === "radius") return 12;
      return "#e8edf2";
    }
    var h = "<div class='dim fhint' style='margin-bottom:10px'>manifest: " + esc(source) +
      " · schema " + esc(manifest.schema_version) + " · units " + esc(manifest.units) +
      " · minimum touch " + esc(manifest.viewport.minimum_touch) +
      ". " + esc(t("admin.ui_manifest_readonly")) +
      (legacy && Object.keys(legacy).length ? " " + esc(t("admin.ui_legacy_hint")) : "") +
      (!self && peer.cached_contract ? " <span class='warn'>" +
        esc(t("admin.ui_offline_queued")) +
        "</span>" : "") +
      "</div><div class='scrollx'><table><thead><tr><th>Element</th><th>Property</th>" +
      "<th>Override</th><th>Value</th></tr></thead><tbody>";
    var ids = Object.keys(manifest.elements).sort();
    ids.forEach(function (semanticId) {
      var desc = manifest.elements[semanticId], cur = L.uiElementValue(elements, semanticId);
      cur = cur && typeof cur === "object" ? cur : {};
      for (var pi = 0; pi < desc.properties.length; pi++) {
        var prop = desc.properties[pi], on = cur[prop] !== undefined;
        var value = on ? cur[prop] : (desc.defaults[prop] !== undefined ?
          desc.defaults[prop] : legacyValue(prop));
        var numeric = prop === "scale" || prop === "font_scale" || prop === "radius";
        h += "<tr data-ui-row data-element='" + esc(semanticId) + "' data-property='" + esc(prop) +
          "' data-had='" + (L.uiElementValue(elements, semanticId) !== undefined ? "1" : "0") + "'><td>" +
          (pi === 0 ? "<span class='mono'>" + esc(semanticId) + "</span>" +
            (desc.safety_critical ? " <span class='tag err'>safety</span>" : "") : "") +
          "</td><td>" + esc(prop) + "</td><td><input type='checkbox' data-ui-on" +
          (on ? " checked" : "") + "></td><td><input data-ui-value type='" +
          (numeric ? "number" : "color") + "' value='" + esc(value) + "'" +
          (numeric ? " min='0' step='0.05' style='width:110px'" : "") + "></td></tr>";
      }
    });
    h += "</tbody></table></div><h3 style='margin-top:16px'>" +
      esc(t("admin.theme_preview")) +
      "</h3><div class='dim fhint'>Logical preview; the target viewport and minimum touch " +
      "constraint remain authoritative.</div><div data-ui-preview " +
      "style='display:flex;gap:12px;align-items:center;flex-wrap:wrap;padding:16px;" +
      "margin-top:8px;background:#101418;border:1px solid var(--line)'></div>" +
      "<div data-ui-preview-error class='warn' role='alert'></div>" +
      "<div class='dim fhint' style='margin-top:10px'>" +
      esc(web ? t("admin.web_ui_apply_report") :
        t("admin.native_ui_apply_report")) + ": " +
      esc(applyReport ? JSON.stringify(applyReport) :
        (web ? "unavailable until a panel applies it" :
          "unavailable until the client reports it")) +
      "</div>";

    function collectUiValues(modal) {
      var values = {}, had = {};
      $all("[data-ui-row]", modal).forEach(function (row) {
        var semanticId = row.getAttribute("data-element"), prop = row.getAttribute("data-property");
        if (!values[semanticId]) values[semanticId] = {};
        had[semanticId] = had[semanticId] || row.getAttribute("data-had") === "1";
        if (!row.querySelector("[data-ui-on]").checked) return;
        var raw = row.querySelector("[data-ui-value]").value;
        values[semanticId][prop] = (prop === "scale" || prop === "font_scale" || prop === "radius") ?
          parseFloat(raw) : raw;
      });
      for (var semanticId in values) {
        var count = 0; for (var prop in values[semanticId]) count++;
        if (!count && !had[semanticId]) delete values[semanticId];
      }
      return values;
    }

    function renderUiPreview(modal) {
      var root = modal.querySelector("[data-ui-preview]");
      var error = modal.querySelector("[data-ui-preview-error]");
      if (!root || !error) return;
      var model;
      try { model = L.uiPreviewModel(manifest, collectUiValues(modal)); }
      catch (e) { error.textContent = e.message; return; }
      error.textContent = "";
      root.innerHTML = "";
      for (var i = 0; i < model.elements.length; i++) {
        var item = model.elements[i], style = item.style || {};
        var sample = document.createElement("div");
        sample.textContent = item.id;
        sample.title = item.safety_critical ? "safety-critical" : item.id;
        sample.style.display = "inline-flex";
        sample.style.alignItems = "center";
        sample.style.justifyContent = "center";
        sample.style.boxSizing = "border-box";
        sample.style.padding = "8px 12px";
        sample.style.minWidth = model.minimum_touch + "px";
        sample.style.minHeight = model.minimum_touch + "px";
        sample.style.fontSize = (14 * Number(style.font_scale || 1)) + "px";
        sample.style.color = style.foreground || "#e8edf2";
        sample.style.backgroundColor = style.background || "#1a2027";
        sample.style.border = "2px solid " + (style.border || style.accent || "#4da3ff");
        sample.style.borderRadius = Number(style.radius || 0) + "px";
        sample.style.transform = "scale(" + Number(style.scale || 1) + ")";
        sample.style.transformOrigin = "center";
        root.appendChild(sample);
      }
    }

    var modal = openModal(deviceName(id) + " — " +
      (web ? t("admin.web_ui") : t("admin.native_ui")), h,
      function (modal) {
      var values = collectUiValues(modal);
      var changes;
      try { changes = L.uiElementChanges(id, manifest, values); }
      catch (e) { return e.message; }
      if (!changes.entries.length && !changes.dels.length) {
        msg(t("admin.no_changes")); return "";
      }
      saveAndRefresh(changes.entries, changes.dels);
      return "";
      });
    $all("[data-ui-on], [data-ui-value]", modal).forEach(function (input) {
      input.addEventListener("input", function () { renderUiPreview(modal); });
      input.addEventListener("change", function () { renderUiPreview(modal); });
    });
    renderUiPreview(modal);
  }

  var pbReceiver = "", pbSource = "";
  /* Resolved at render time: I18N is fetched after this script runs. */
  function pbLabel(id) {
    if (id === "h264_low_latency") return t("admin.video_low_latency");
    if (id === "h264_hls") return t("admin.video_hls");
    return id === "mjpeg" ? "MJPEG" : id;
  }

  function playbackRowsHtml(profile, tbodyId) {
    var p = L.normalizePlaybackProfile(profile), h = "";
    for (var i = 0; i < p.strategies.length; i++) {
      var s = p.strategies[i];
      h += "<tr draggable='true' data-pb-row data-id='" + esc(s.id) + "'>" +
           "<td class='ops'><button class='btn2 small' data-pb-up>↑</button> " +
           "<button class='btn2 small' data-pb-down>↓</button></td>" +
           "<td><label><input type='checkbox' data-pb-enabled" +
           (s.enabled ? " checked" : "") + "> " + esc(pbLabel(s.id)) +
           (s.id === "h264_hls" ? " <span class='dim'>(iPad1 App)</span>" : "") +
           "</label></td><td><input type='number' min='100' max='60000' step='100' " +
           "data-pb-start value='" + esc(s.startup_timeout_ms) + "' style='width:100px'> ms</td>" +
           "<td><input type='number' min='1000' max='60000' step='500' data-pb-stall value='" +
           esc(s.stall_timeout_ms) + "' style='width:100px'> ms</td></tr>";
    }
    return "<table><thead><tr><th>" + esc(t("admin.order")) + "</th><th>" +
           esc(t("admin.playback_strategy")) + "</th><th>" +
           esc(t("admin.first_frame_timeout")) + "</th><th>" +
           esc(t("admin.stall_timeout")) + "</th>" +
           "</tr></thead><tbody id='" + tbodyId + "'>" + h + "</tbody></table>" +
           "<div class='dim fhint'>" + esc(t("admin.playback_fallback_hint")) +
           " <span id='" + tbodyId + "Estimate'>0</span> ms</div>";
  }

  function collectPlaybackRows(id) {
    var rows = $all("[data-pb-row]", $("#" + id)), out = [], enabled = 0;
    for (var i = 0; i < rows.length; i++) {
      var start = parseInt(rows[i].querySelector("[data-pb-start]").value, 10);
      var stall = parseInt(rows[i].querySelector("[data-pb-stall]").value, 10);
      var on = rows[i].querySelector("[data-pb-enabled]").checked;
      if (!(start >= 100 && start <= 60000) || !(stall >= 1000 && stall <= 60000)) {
        window.alert(t("admin.playback_timeout_range"));
        return null;
      }
      enabled += on ? 1 : 0;
      out.push({ id: rows[i].getAttribute("data-id"), enabled: on,
                 startup_timeout_ms: start, stall_timeout_ms: stall });
    }
    if (!enabled) { window.alert(t("admin.playback_one_required")); return null; }
    return { strategies: out };
  }

  function updatePlaybackEstimate(id) {
    var rows = $all("[data-pb-row]", $("#" + id)), ms = 0;
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].querySelector("[data-pb-enabled]").checked) continue;
      if (rows[i].getAttribute("data-id") === "mjpeg") break;
      ms += parseInt(rows[i].querySelector("[data-pb-start]").value, 10) || 0;
    }
    var out = $("#" + id + "Estimate"); if (out) out.textContent = String(ms);
  }

  function bindPlaybackRows(id) {
    var body = $("#" + id), dragged = null;
    if (!body) return;
    $all("[data-pb-row]", body).forEach(function (row) {
      row.ondragstart = function (e) {
        dragged = row;
        if (e && e.dataTransfer) {
          e.dataTransfer.effectAllowed = "move";
          e.dataTransfer.setData("text/plain", row.getAttribute("data-id"));
        }
      };
      row.ondragover = function (e) { if (e.preventDefault) e.preventDefault(); };
      row.ondrop = function (e) {
        if (e.preventDefault) e.preventDefault();
        if (dragged && dragged !== row) body.insertBefore(dragged, row);
        updatePlaybackEstimate(id);
      };
      row.querySelector("[data-pb-up]").onclick = function () {
        if (row.previousSibling) body.insertBefore(row, row.previousSibling);
        updatePlaybackEstimate(id);
      };
      row.querySelector("[data-pb-down]").onclick = function () {
        if (row.nextSibling) body.insertBefore(row.nextSibling, row);
        updatePlaybackEstimate(id);
      };
      row.querySelector("[data-pb-enabled]").onchange = function () { updatePlaybackEstimate(id); };
      row.querySelector("[data-pb-start]").oninput = function () { updatePlaybackEstimate(id); };
    });
    updatePlaybackEstimate(id);
  }


  // "80 / 100 / 60" plus a marker when this device overrides the cluster default.
  function volumeSummary(id) {
    var effective = L.effectiveVolumes(S.cfg, id);
    var levels = [];
    for (var i = 0; i < L.VOLUME_LEVELS.length; i++)
      levels.push(effective[L.VOLUME_LEVELS[i]]);
    return levels.join(" / ") + (effective.source === "device" ? " *" : "");
  }

  function editDeviceVolume(id) {
    var effective = L.effectiveVolumes(S.cfg, id);
    var cluster = L.effectiveVolumes({ audio: S.cfg.audio, emergency: S.cfg.emergency }, "");
    var inherits = effective.source !== "device";
    var body = "<div class='dim fhint' style='margin-bottom:10px'>" +
      esc(deviceName(id)) + "</div>" +
      "<label class='frow-check'><input type='checkbox' id='volInherit'" +
      (inherits ? " checked" : "") + "> " + esc(t("volume.inherit")) + "</label>" +
      "<div id='volRows'>" + volumeRowsHtml("devvol", effective, cluster) + "</div>";
    var modal = openModal(t("volume.device_title"), body, function (m) {
      var inherit = m.querySelector("#volInherit").checked;
      var values = collectVolumeRows(m, "devvol");
      values.inherit = inherit;
      var plan = L.deviceVolumeEntries(id, values);
      saveAndRefresh(plan.entries, plan.dels);
    });
    var root = modal || document.querySelector("#modal");
    bindVolumeRows(root, "devvol");
    var inheritBox = root.querySelector("#volInherit");
    var rows = root.querySelector("#volRows");
    function syncDisabled() {
      $all("[data-vol],[data-vol-preview]", rows).forEach(function (control) {
        control.disabled = inheritBox.checked;
      });
      rows.style.opacity = inheritBox.checked ? "0.5" : "1";
    }
    inheritBox.onchange = syncDisabled;
    syncDisabled();
  }

  function renderDevices() {
    var el = $("#tab-devices");
    var ds = cfgObj("devices");
    var ids = [];
    for (var id in ds) ids.push(id);

    (S.status.peers || []).forEach(function (p) {
      if (ids.indexOf(p.id) < 0) ids.push(p.id);
    });
    var h = "<div class='card'><table><thead><tr><th>" + esc(t("admin.dev_name")) +
            "</th><th>ID</th><th>" + esc(t("admin.dev_role")) + "</th><th>" +
            esc(t("admin.door_assign")) + "</th><th>" +
            esc(t("admin.online")) + "</th><th>" +
            esc(t("volume.title")) + "</th><th>" +
            esc(t("admin.runtime_health")) +
            "</th><th></th></tr></thead><tbody>";
    var selfId = (S.status.node || {}).id || "";
    ids.forEach(function (nid) {
      var d = ds[nid] || {};
      var p = peerOf(nid);
      var alive = p && p.status === "alive";
      var stCls = alive ? "ok" : (p && p.status === "suspect" ? "warn" : "err");
      var stTxt = p ? p.status : t("admin.offline");
      var runtime = nid === selfId ? (S.status.runtime || {}) : ((p && p.runtime) || {});
      var health = L.runtimeHealthRows(runtime), healthHtml = "";
      var healthLabels = {
        safe_mode: t("admin.runtime_safe_mode"),
        helper: t("admin.runtime_helper"),
        codec: t("admin.runtime_codec"),
        last_exit: t("admin.runtime_last_exit"),
        alert: t("admin.runtime_alert"),
        heartbeat: t("admin.runtime_heartbeat")
      };
      for (var hi = 0; hi < health.length; hi++)
        healthHtml += "<div class='" + esc(health[hi].severity || "dim") + "'><span class='dim'>" +
          esc(healthLabels[health[hi].key] || health[hi].key) + ":</span> " +
          esc(health[hi].value) + "</div>";
      if (!healthHtml) healthHtml = "<span class='warn'>" +
        esc(t("admin.runtime_unreported")) + "</span>";
      h += "<tr class='" + (alive ? "" : "offline") + "'><td>" + esc(d.name || "") +
           (p && p.self ? " <span class='tag'>self</span>" : "") + "</td><td class='dim'>" +
           esc(nid.slice(0, 8)) + "</td><td>" +
           esc(d.role === "indoor_panel" ? t("admin.role_indoor") :
               (d.role ? t("admin.role_door") : "")) + "</td><td>" +
           esc(d.door ? doorLabel(d.door) : "—") + "</td><td class='" + stCls + "'>" +
           esc(stTxt) + "</td><td class='dim mono'>" + esc(volumeSummary(nid)) +
           "</td><td>" + healthHtml +
           "</td><td class='ops'><button class='btn2' data-act='edit' data-id='" +
           esc(nid) + "'>" + esc(t("admin.edit")) + "</button> " +
           "<button class='btn2' data-act='vol' data-id='" + esc(nid) + "'>" +
           esc(t("volume.title")) + "</button> " +
           "<button class='btn2' data-act='ui' data-id='" + esc(nid) + "'>" +
           esc(t("admin.native_ui")) + "</button>" +
           (nid === ((S.status.node || {}).id || "") ?
             " <button class='btn2' data-act='webui' data-id='" + esc(nid) + "'>" +
             esc(t("admin.web_ui")) + "</button>" : "") + "</td></tr>";
    });
    h += "</tbody></table></div>";

    var vp = cfgObj("video_playback"), globalProfile = L.normalizePlaybackProfile(vp.global);
    var indoors = [], outdoors = [];
    for (var did in ds) {
      if (ds[did].role === "indoor_panel") indoors.push(did);
      if (ds[did].role === "door_station") outdoors.push(did);
    }
    if (indoors.indexOf(pbReceiver) < 0) pbReceiver = "";
    if (outdoors.indexOf(pbSource) < 0) pbSource = "";
    h += "<div class='card'><h2>" + esc(t("admin.video_playback_policy")) +
         "</h2><h3>" + esc(t("admin.global")) + "</h3>" +
         playbackRowsHtml(globalProfile, "pbGlobalRows") +
         "<button class='btn small' id='pbGlobalSave'>" + esc(t("admin.save")) +
         "</button><hr style='border:0;border-top:1px solid var(--line);margin:18px 0'>" +
         "<h3>" + esc(t("admin.playback_pair_override")) +
         "</h3><div style='display:flex;gap:8px;flex-wrap:wrap'>" +
         "<select id='pbReceiver'><option value=''>" + esc(t("admin.choose_indoor")) + "</option>";
    indoors.forEach(function (id) { h += "<option value='" + esc(id) + "'" +
      (pbReceiver === id ? " selected" : "") + ">" + esc(deviceName(id)) + "</option>"; });
    h += "</select><select id='pbSource'><option value=''>" + esc(t("admin.choose_door_station")) + "</option>";
    outdoors.forEach(function (id) { h += "<option value='" + esc(id) + "'" +
      (pbSource === id ? " selected" : "") + ">" + esc(deviceName(id)) + "</option>"; });
    h += "</select><button class='btn2 small' id='pbPairLoad'>" +
         esc(t("admin.load_or_add")) + "</button></div>";
    if (pbReceiver && pbSource) {
      var pairs = vp.pairs || {}, pair = (pairs[pbReceiver] || {})[pbSource];
      h += "<div style='margin-top:12px'><div class='dim fhint'>" +
           esc(t(pair ? "admin.pair_override_active" : "admin.pair_override_inherited")) + "</div>" +
           playbackRowsHtml(pair || globalProfile, "pbPairRows") +
           "<button class='btn small' id='pbPairSave'>" + esc(t("admin.save_pair_override")) +
           "</button> " + (pair ? "<button class='btn2 danger small' id='pbPairDelete'>" +
           esc(t("admin.delete_pair_override")) + "</button>" : "") +
           "</div>";
    }
    h += "</div>";
    el.innerHTML = h;
    bindActs(el, { edit: function (id) { editDevice(id); },
                  vol: function (id) { editDeviceVolume(id); },
                  ui: function (id) { editDeviceUi(id, "native"); },
                  webui: function (id) { editDeviceUi(id, "web"); } });
    bindPlaybackRows("pbGlobalRows");
    if ($("#pbPairRows")) bindPlaybackRows("pbPairRows");
    $("#pbGlobalSave").onclick = function () {
      var p = collectPlaybackRows("pbGlobalRows");
      if (p) saveAndRefresh(L.playbackProfileEntries("", "", p, vp.global), null);
    };
    $("#pbPairLoad").onclick = function () {
      pbReceiver = $("#pbReceiver").value; pbSource = $("#pbSource").value;
      if (!pbReceiver || !pbSource) { window.alert(t("admin.choose_playback_pair")); return; }
      renderDevices();
    };
    if ($("#pbPairSave")) $("#pbPairSave").onclick = function () {
      var p = collectPlaybackRows("pbPairRows");
      var pair = (((vp.pairs || {})[pbReceiver] || {})[pbSource]) || {};
      if (p) saveAndRefresh(L.playbackProfileEntries(pbReceiver, pbSource, p, pair), null);
    };
    if ($("#pbPairDelete")) $("#pbPairDelete").onclick = function () {
      saveAndRefresh(null, ["video_playback.pairs." + pbReceiver + "." + pbSource]);
    };
  }


  function whenLabel(type) {
    if (type === "motion") return t("admin.when_motion");
    if (type === "device_offline") return t("admin.when_offline");
    if (type === "emergency_on") return t("admin.when_emergency_on");
    if (type === "emergency_off") return t("admin.when_emergency_off");
    return t("admin.when_button");
  }
  function actionLabel(a) {
    if (a.type === "sip_call")
      return t("admin.act_sip") + " → " + (a.target_extension || "600");
    if (a.type === "telegram") {
      var hs = a.households === "all" ? t("admin.all") :
               (a.households instanceof Array ? a.households : []).map(householdLabel).join(",");
      return t("admin.act_telegram") + " → " + (hs || "?") +
             (a.with_snapshot ? " 📷" : "");
    }
    if (a.type === "chime") return t("admin.act_chime") + " (" + (a.sound || "ding1") + ")";
    if (a.type === "device_alert") {
      var channels = L.effectiveAlertChannels(a).join(", ");
      return t("admin.act_device_alert") + " (" + channels + ")";
    }
    if (a.type === "ha_event") return t("admin.act_ha");
    return t("admin.unknown_action") + ": " + (a.type || "?");
  }
  function scheduleLabel(sc) {
    if (!sc || sc.always) return t("admin.always");
    var ws = sc.windows || [];
    var parts = [];
    for (var i = 0; i < ws.length; i++) {
      var w = ws[i];
      var days = (w.days || DAYS).map(dayLabel).join("");
      parts.push(days + " " + (w.from || "") + "-" + (w.to || ""));
    }
    return parts.join(" / ") || t("admin.always");
  }

  function selectorText(value) {
    if (value === "all") return "all";
    if (value instanceof Array) return value.join(", ");
    return typeof value === "string" ? value : "";
  }

  function selectorInput(label, field, value, hint) {
    return "<div style='min-width:180px;flex:1'><label class='flab'>" + esc(label) +
           "</label><input type='text' data-ra='" + field + "' value='" +
           esc(selectorText(value)) + "' placeholder='all' style='width:100%'>" +
           (hint ? "<div class='dim fhint'>" + esc(hint) + "</div>" : "") + "</div>";
  }

  function alertPresentationDefaults(a) {
    var p = a && a.presentation && typeof a.presentation === "object" ? a.presentation : {};
    return { visual: p.visual !== false, sound: p.sound || "",
      volume: p.volume === undefined ? 100 : p.volume,
      sticky: p.sticky === true,
      ttl_s: p.ttl_s === undefined ? 0 : p.ttl_s,
      background: L.colorOk(p.background) ? p.background : "#8F1010",
      foreground: L.colorOk(p.foreground) ? p.foreground : "#FFFFFF",
      accent: L.colorOk(p.accent) ? p.accent : "#FFD166" };
  }

  // Action row HTML. Unknown action types are intentionally read-only and losslessly preserved.
  function actionRowHtml(idx, a) {
    if (L.RULE_ACTION_TYPES.indexOf(a.type) < 0) {
      return "<div class='arow' data-arow='" + idx + "' data-readonly='1'>" +
             "<span class='tag warn'>" + esc(t("admin.unknown_action")) +
             ": " + esc(a.type || "?") + "</span><span class='mono dim'>" +
             esc(JSON.stringify(a)) + "</span></div>";
    }
    var typeOpts = [["sip_call", t("admin.act_sip")],
                    ["telegram", t("admin.act_telegram")],
                    ["ha_event", t("admin.act_ha")],
                    ["chime", t("admin.act_chime")],
                    ["device_alert", t("admin.act_device_alert")]];
    var sel = "<select data-ra='type' data-idx='" + idx + "'>";
    for (var i = 0; i < typeOpts.length; i++)
      sel += "<option value='" + typeOpts[i][0] + "'" +
             (a.type === typeOpts[i][0] ? " selected" : "") + ">" + esc(typeOpts[i][1]) +
             "</option>";
    sel += "</select>";
    var params = "";
    if (a.type === "sip_call") {
      params = "<input type='text' data-ra='target_extension' data-idx='" + idx + "' value='" +
               esc(a.target_extension || "600") + "' placeholder='600' style='width:90px'>";
    } else if (a.type === "telegram") {
      var hs = householdOptions();
      (a.households instanceof Array ? a.households : []).forEach(function (id) {
        if (!hs.some(function (o) { return o.v === id; })) hs.push({ v: id, label: id });
      });
      params = "<span class='mcwrap'><label class='mc'><input type='checkbox' " +
               "data-ra='households_all'" + (a.households === "all" ? " checked" : "") +
               "> " + esc(t("admin.all")) + "</label>";
      for (var k = 0; k < hs.length; k++)
        params += "<label class='mc'><input type='checkbox' data-ra='households' data-idx='" +
                  idx + "' value='" + esc(hs[k].v) + "'" +
                  ((a.households || []).indexOf(hs[k].v) >= 0 ? " checked" : "") + "> " +
                  esc(hs[k].label) + "</label>";
      params += "</span><label class='mc'><input type='checkbox' data-ra='with_snapshot' data-idx='" +
                idx + "'" + (a.with_snapshot ? " checked" : "") + "> " +
                esc(t("admin.with_snapshot")) + "</label>";
    } else if (a.type === "chime") {
      var devs = deviceOptions();
      (a.devices instanceof Array ? a.devices : []).forEach(function (id) {
        if (!devs.some(function (o) { return o.v === id; })) devs.push({ v: id, label: id });
      });
      params = "<span class='mcwrap'>";
      for (var m = 0; m < devs.length; m++)
        params += "<label class='mc'><input type='checkbox' data-ra='devices' data-idx='" + idx +
                  "' value='" + esc(devs[m].v) + "'" +
                  ((a.devices instanceof Array ? a.devices : []).indexOf(devs[m].v) >= 0 ?
                   " checked" : "") + "> " + esc(devs[m].label) + "</label>";
      params += "</span><div class='dim fhint'>" + esc(t("admin.unchecked_all")) + "</div>";
      var ro = ringtoneOptions();
      if (a.sound && !ro.some(function (o) { return o.v === a.sound; }))
        ro.push({ v: a.sound, label: a.sound });
      params += " <select data-ra='sound' data-idx='" + idx + "'>";
      for (var ri = 0; ri < ro.length; ri++)
        params += "<option value='" + esc(ro[ri].v) + "'" +
                  (ro[ri].v === (a.sound || "ding1") ? " selected" : "") + ">" +
                  esc(ro[ri].label) + "</option>";
      params += "</select> <button class='btn2' data-ringplay='" + idx + "'>▶ " +
                esc(t("admin.audio_play")) + "</button>";
    } else if (a.type === "device_alert") {
      var targets = a.targets && typeof a.targets === "object" ? a.targets : {};
      var groups = Object.prototype.hasOwnProperty.call(targets, "web_subscription_groups") ?
                   targets.web_subscription_groups : targets.web_profiles;
      params = "<div style='display:flex;gap:8px;flex-wrap:wrap;flex-basis:100%'>" +
        selectorInput(t("admin.alert_target_devices"), "target_devices",
                      targets.devices, t("admin.list_or_all")) +
        selectorInput(t("admin.alert_target_roles"), "target_roles",
                      targets.roles, t("admin.list_or_all")) +
        selectorInput(t("admin.alert_target_web_groups"),
                      "target_web_groups", groups,
                      t("admin.list_or_all")) + "</div>";
      var channels = L.effectiveAlertChannels(a);
      params += "<div class='mcwrap' style='flex-basis:100%'>";
      [["in_app", t("admin.channel_in_app")],
       ["system_notification", t("admin.channel_system_notification")],
       ["web_push", t("admin.channel_web_push")]].forEach(function (ch) {
        params += "<label class='mc'><input type='checkbox' data-ra='channel' value='" + ch[0] +
                  "'" + (channels.indexOf(ch[0]) >= 0 ? " checked" : "") + "> " +
                  esc(ch[1]) + "</label>";
      });
      params += "<label class='mc'><input type='checkbox' data-ra='never_suppress'" +
                (a.never_suppress === true ? " checked" : "") + "> " +
                esc(t("admin.never_suppress")) + "</label></div>";
      var p = alertPresentationDefaults(a), sounds = soundOptions(true);
      if (p.sound && !sounds.some(function (o) { return o.v === p.sound; }))
        sounds.push({ v: p.sound, label: p.sound });
      params += "<div style='display:flex;gap:8px;align-items:end;flex-wrap:wrap;flex-basis:100%'>" +
                "<label class='mc'><input type='checkbox' data-ra='visual'" +
                (p.visual ? " checked" : "") + "> " + esc(t("admin.alert_visual")) +
                "</label><label class='mc'><input type='checkbox' data-ra='sticky'" +
                (p.sticky ? " checked" : "") + "> " + esc(t("admin.alert_sticky")) +
                "</label><div><label class='flab'>" + esc(t("admin.alert_sound")) +
                "</label><select data-ra='alert_sound'>";
      for (var si = 0; si < sounds.length; si++)
        params += "<option value='" + esc(sounds[si].v) + "'" +
                  (sounds[si].v === p.sound ? " selected" : "") + ">" +
                  esc(sounds[si].label) + "</option>";
      params += "</select></div><div><label class='flab'>" +
                esc(t("admin.alert_volume")) +
                "</label><input type='number' min='0' max='100' data-ra='volume' value='" +
                esc(p.volume) + "' style='width:100px'></div><div><label class='flab'>" +
                esc(t("admin.alert_ttl")) +
                "</label><input type='number' min='0' data-ra='ttl_s' value='" +
                esc(p.ttl_s) + "' style='width:100px'></div>" +
                "<div><label class='flab'>" +
                esc(t("admin.alert_background")) +
                "</label><input type='color' data-ra='alert_background' value='" +
                esc(p.background) + "'></div><div><label class='flab'>" +
                esc(t("admin.alert_foreground")) +
                "</label><input type='color' data-ra='alert_foreground' value='" +
                esc(p.foreground) + "'></div><div><label class='flab'>" +
                esc(t("admin.alert_accent")) +
                "</label><input type='color' data-ra='alert_accent' value='" +
                esc(p.accent) + "'></div></div>";
    }
    return "<div class='arow' data-arow='" + idx + "'>" + sel + " " + params +
           " <button class='btn2 danger' data-ra='del' data-idx='" + idx + "'>×</button></div>";
  }

  function windowRowHtml(idx, w) {
    var days = w.days && w.days.length ? w.days : DAYS.slice();
    var h = "<div class='arow' data-wrow='" + idx + "'>";
    for (var i = 0; i < DAYS.length; i++)
      h += "<label class='mc'><input type='checkbox' data-rw='day' data-idx='" + idx +
           "' value='" + DAYS[i] + "'" + (days.indexOf(DAYS[i]) >= 0 ? " checked" : "") + ">" +
           esc(dayLabel(DAYS[i])) + "</label>";
    h += " <input type='time' data-rw='from' data-idx='" + idx + "' value='" + esc(w.from || "") +
         "'> – <input type='time' data-rw='to' data-idx='" + idx + "' value='" + esc(w.to || "") +
         "'> <button class='btn2 danger' data-rw='del' data-idx='" + idx + "'>×</button></div>";
    return h;
  }

  function sosWarningText(w) {
    if (w.code === "no_device_alert")
      return t("admin.sos_warn_no_device_alert");
    if (w.code === "zero_recipients")
      return t("admin.sos_warn_zero_recipients");
    if (w.code === "all_channels_silent")
      return t("admin.sos_warn_silent");
    if (w.code === "no_web_push_subscriptions")
      return t("admin.sos_warn_no_push_subscriptions");
    if (w.code === "web_push_backend_unavailable")
      return t("admin.sos_warn_push_backend");
    if (w.code === "offline_devices")
      return t("admin.sos_warn_offline") + ": " +
             (w.devices || []).join(", ");
    if (w.code === "unsupported_device_channels")
      return t("admin.sos_warn_unsupported_channels") +
             ": " + (w.channels || []).join(", ");
    if (w.code === "unavailable_device_channels")
      return t("admin.sos_warn_unavailable_channels") +
             ": " + (w.channels || []).join(", ");
    if (w.code === "unknown_device_channels")
      return t("admin.sos_warn_unknown_channels") +
             ": " + (w.channels || []).join(", ");
    return w.code;
  }

  function sosPreviewHtml(rule) {
    var preview = L.sosDryRunPreview(rule, S.status, S.cfg);
    if (!preview.is_sos) return "";
    var warnings = L.sosRuleWarnings(rule, S.status, S.cfg), h =
      "<div class='card' role='status' style='margin-top:12px;border-color:var(--warn)'>" +
      "<h2>" + esc(t("admin.sos_dry_run")) + "</h2>" +
      "<div class='dim fhint'>" + esc(t("admin.sos_targets")) + ": " +
      esc(t("admin.alert_target_devices")) + " [" +
      esc(preview.target_devices.join(", ") || "default/all") + "]; " +
      esc(t("admin.alert_target_roles")) + " [" +
      esc(preview.target_roles.join(", ") || "default/all") + "]; " +
      esc(t("admin.alert_target_web_groups")) + " [" +
      esc(preview.target_web_subscription_groups.join(", ") || "default/all") + "]</div>" +
      "<div class='dim fhint'>" + esc(t("admin.alert_channels")) + ": " +
      esc(preview.channels.join(", ") || "none") + " · " +
      esc(t("admin.sos_local_recipients")) + ": " +
      preview.local_recipients + " (" + preview.capable_local_recipients + " " +
      esc(t("admin.sos_capable_recipients")) + ") · Web Push: " +
      (preview.web_push_recipients === null ? "?" : preview.web_push_recipients) + "</div>";
    for (var i = 0; i < warnings.length; i++)
      h += "<div class='warn' style='font-weight:600;margin-top:6px'>⚠ " +
           esc(sosWarningText(warnings[i])) + "</div>";
    if (!warnings.length)
      h += "<div class='ok' style='margin-top:6px'>" +
           esc(t("admin.sos_dry_run_ok")) +
           "</div>";
    return h + "<div class='dim fhint'>" +
      esc(t("admin.sos_warning_nonblocking")) +
      "</div></div>";
  }

  function editRule(id) {
    var isNew = !id;
    var rid = isNew ? L.newId("r", cfgObj("trigger_rules")) : id;
    var cur = isNew ?
      { enabled: true, when: { type: "button" }, schedule: { always: true },
        actions: [{ type: "chime" }] } :
      JSON.parse(JSON.stringify(cfgObj("trigger_rules")[id] || {}));
    var st = L.normalizeRuleEditor(cur);

    function bodyHtml() {
      var h = "<div class='frow frow-check'><label><input type='checkbox' id='rEnabled'" +
              (st.enabled ? " checked" : "") + "> " + esc(t("admin.enabled")) +
              "</label></div>";

      h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_when")) +
           "</label><select id='rWhen'>";
      var whenOptions = [["button", t("admin.when_button")],
       ["motion", t("admin.when_motion")],
       ["device_offline", t("admin.when_offline")],
       ["emergency_on", t("admin.when_emergency_on")],
       ["emergency_off", t("admin.when_emergency_off")]];
      if (!whenOptions.some(function (o) { return o[0] === st.whenType; }))
        whenOptions.push([st.whenType, t("admin.unknown_trigger") + ": " + st.whenType]);
      whenOptions.forEach(function (o) {
        h += "<option value='" + esc(o[0]) + "'" + (st.whenType === o[0] ? " selected" : "") + ">" +
             esc(o[1]) + "</option>";
      });
      h += "</select></div>";
      if (st.whenType === "device_offline") {
        h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_devices")) +
             "</label><div class='mcwrap'><label class='mc'><input type='checkbox' id='rDevAll'" +
             (st.devices === "all" ? " checked" : "") + "> " + esc(t("admin.all")) +
             "</label>";
        var ruleDevices = deviceOptions();
        (st.devices instanceof Array ? st.devices : []).forEach(function (id) {
          if (!ruleDevices.some(function (o) { return o.v === id; }))
            ruleDevices.push({ v: id, label: id });
        });
        ruleDevices.forEach(function (o) {
          h += "<label class='mc'><input type='checkbox' data-rdev='1' value='" + esc(o.v) + "'" +
               (st.devices instanceof Array && st.devices.indexOf(o.v) >= 0 ? " checked" : "") +
               "> " + esc(o.label) + "</label>";
        });
        h += "</div></div>";
      } else if (st.whenType === "button" || st.whenType === "motion") {
        h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_doors")) +
             "</label><div class='mcwrap'>";
        var ruleDoors = doorOptions(false);
        st.doors.forEach(function (id) {
          if (!ruleDoors.some(function (o) { return o.v === id; }))
            ruleDoors.push({ v: id, label: id });
        });
        ruleDoors.forEach(function (o) {
          h += "<label class='mc'><input type='checkbox' data-rdoor='1' value='" + esc(o.v) + "'" +
               (st.doors.indexOf(o.v) >= 0 ? " checked" : "") + "> " + esc(o.label) + "</label>";
        });
        h += "</div><div class='dim fhint'>" + esc(t("admin.unchecked_all")) + "</div></div>";
      }

      h += "<div class='frow'><label class='flab'>" + esc(t("admin.schedule")) +
           "</label><label class='mc'><input type='radio' name='rSched' value='always'" +
           (st.always ? " checked" : "") + "> " + esc(t("admin.always")) +
           "</label><label class='mc'><input type='radio' name='rSched' value='windows'" +
           (!st.always ? " checked" : "") + "> " + esc(t("admin.windows")) + "</label></div>";
      if (!st.always) {
        h += "<div id='rWins'>";
        for (var i = 0; i < st.windows.length; i++) h += windowRowHtml(i, st.windows[i]);
        h += "</div><button class='btn2' id='rAddWin'>+ " +
             esc(t("admin.add_window")) + "</button>";
      }

      h += "<div class='frow'><label class='flab'>" + esc(t("admin.actions")) +
           "</label></div><div id='rActs'>";
      for (var j = 0; j < st.actions.length; j++) h += actionRowHtml(j, st.actions[j]);
      h += "</div><button class='btn2' id='rAddAct'>+ " +
           esc(t("admin.add_action")) + "</button>";
      h += sosPreviewHtml(L.mergeRuleEditor(cur, st));
      return h;
    }


    function collectState(m) {
      st.enabled = $("#rEnabled") ? $("#rEnabled").checked : st.enabled;
      var wSel = $("#rWhen");
      if (wSel) st.whenType = wSel.value;
      if (st.whenType === "device_offline") {
        var all = $("#rDevAll") && $("#rDevAll").checked;
        var devs = [];
        $all("[data-rdev]", m).forEach(function (el) { if (el.checked) devs.push(el.value); });
        st.devices = all || !devs.length ? "all" : devs;
      } else if (st.whenType === "button" || st.whenType === "motion") {
        var doors = [];
        $all("[data-rdoor]", m).forEach(function (el) { if (el.checked) doors.push(el.value); });
        st.doors = doors;
      }
      var sc = m.querySelector("input[name='rSched']:checked");
      if (sc) st.always = sc.value === "always";
      // windows
      var wins = [];
      $all("[data-wrow]", m).forEach(function (row) {
        var idx = parseInt(row.getAttribute("data-wrow"), 10);
        var days = [];
        $all("[data-rw='day'][data-idx='" + idx + "']", row).forEach(function (el) {
          if (el.checked) days.push(el.value);
        });
        var from = row.querySelector("[data-rw='from']"), to = row.querySelector("[data-rw='to']");
        var oldWindow = st.windows[idx] || {}, nextWindow = JSON.parse(JSON.stringify(oldWindow));
        nextWindow.days = days;
        nextWindow.from = from ? from.value : "";
        nextWindow.to = to ? to.value : "";
        wins.push(nextWindow);
      });
      if ($all("[data-wrow]", m).length) st.windows = wins;
      // actions
      var acts = [];
      $all("[data-arow]", m).forEach(function (row) {
        var idx = parseInt(row.getAttribute("data-arow"), 10);
        var oldAction = st.actions[idx] || {}, a = JSON.parse(JSON.stringify(oldAction));
        if (row.getAttribute("data-readonly") === "1") { acts.push(a); return; }
        var typeEl = row.querySelector("[data-ra='type']");
        var nextType = typeEl ? typeEl.value : (a.type || "chime");
        var typeChanged = nextType !== a.type;
        a.type = nextType;
        if (typeChanged) {
          if (nextType === "device_alert") {
            a.targets = { devices: "all", roles: "all", web_subscription_groups: "all" };
            a.channels = ["in_app", "system_notification", "web_push"];
            a.never_suppress = true;
            a.presentation = { visual: true,
              sticky: st.whenType === "emergency_on",
              ttl_s: st.whenType === "emergency_on" ? 0 : 10 };
          }
          acts.push(a); return;
        }
        if (a.type === "sip_call") {
          var te = row.querySelector("[data-ra='target_extension']");
          var target = te ? te.value : "600";
          if (target !== (oldAction.target_extension || "600")) a.target_extension = target;
        } else if (a.type === "telegram") {
          var selectedHouseholds = [];
          $all("[data-ra='households']", row).forEach(function (el) {
            if (el.checked) selectedHouseholds.push(el.value);
          });
          var allHouseholds = row.querySelector("[data-ra='households_all']");
          var nextHouseholds = allHouseholds && allHouseholds.checked ? "all" : selectedHouseholds;
          if (JSON.stringify(nextHouseholds) !== JSON.stringify(oldAction.households || []))
            a.households = nextHouseholds;
          var ws2 = row.querySelector("[data-ra='with_snapshot']");
          var withSnapshot = ws2 ? ws2.checked : false;
          if (withSnapshot !== (oldAction.with_snapshot === true)) a.with_snapshot = withSnapshot;
        } else if (a.type === "chime") {
          var selectedDevices = [];
          $all("[data-ra='devices']", row).forEach(function (el) {
            if (el.checked) selectedDevices.push(el.value);
          });
          if (JSON.stringify(selectedDevices) !== JSON.stringify(oldAction.devices || [])) {
            if (selectedDevices.length) a.devices = selectedDevices;
            else delete a.devices;
          }
          var se = row.querySelector("[data-ra='sound']");
          var sound = se ? se.value : "ding1";
          if (sound !== (oldAction.sound || "ding1")) a.sound = sound;
        } else if (a.type === "device_alert") {
          var oldTargets = oldAction.targets && typeof oldAction.targets === "object" ?
                           oldAction.targets : {};
          var nextTargets = JSON.parse(JSON.stringify(oldTargets)), targetsChanged = false;
          function collectSelector(field, key, oldValue) {
            var input = row.querySelector("[data-ra='" + field + "']");
            if (!input || input.value.trim() === selectorText(oldValue)) return;
            var raw = input.value.trim();
            nextTargets[key] = raw === "all" ? "all" : L.parseList(raw);
            targetsChanged = true;
          }
          collectSelector("target_devices", "devices", oldTargets.devices);
          collectSelector("target_roles", "roles", oldTargets.roles);
          var oldGroups = Object.prototype.hasOwnProperty.call(oldTargets,
                            "web_subscription_groups") ? oldTargets.web_subscription_groups :
                            oldTargets.web_profiles;
          collectSelector("target_web_groups", "web_subscription_groups", oldGroups);
          if (targetsChanged) a.targets = nextTargets;

          var selectedChannels = [];
          $all("[data-ra='channel']", row).forEach(function (el) {
            if (el.checked) selectedChannels.push(el.value);
          });
          if (JSON.stringify(selectedChannels) !==
              JSON.stringify(L.effectiveAlertChannels(oldAction))) a.channels = selectedChannels;
          var ns = row.querySelector("[data-ra='never_suppress']"), neverSuppress = !!(ns && ns.checked);
          if (neverSuppress !== (oldAction.never_suppress === true)) a.never_suppress = neverSuppress;

          var oldPresentation = oldAction.presentation && typeof oldAction.presentation === "object" ?
                                oldAction.presentation : {};
          var nextPresentation = JSON.parse(JSON.stringify(oldPresentation)), presentationChanged = false;
          var defaults = alertPresentationDefaults(oldAction);
          var visualEl = row.querySelector("[data-ra='visual']"), visual = !!(visualEl && visualEl.checked);
          var stickyEl = row.querySelector("[data-ra='sticky']"), sticky = !!(stickyEl && stickyEl.checked);
          var soundEl = row.querySelector("[data-ra='alert_sound']"), alertSound = soundEl ? soundEl.value : "";
          var volumeEl = row.querySelector("[data-ra='volume']"), volume = Math.max(0, Math.min(100,
                       parseInt(volumeEl ? volumeEl.value : defaults.volume, 10) || 0));
          var ttlEl = row.querySelector("[data-ra='ttl_s']"), ttl = Math.max(0,
                    parseInt(ttlEl ? ttlEl.value : defaults.ttl_s, 10) || 0);
          var backgroundEl = row.querySelector("[data-ra='alert_background']");
          var background = backgroundEl ? backgroundEl.value.toUpperCase() : defaults.background;
          var foregroundEl = row.querySelector("[data-ra='alert_foreground']");
          var foreground = foregroundEl ? foregroundEl.value.toUpperCase() : defaults.foreground;
          var accentEl = row.querySelector("[data-ra='alert_accent']");
          var accent = accentEl ? accentEl.value.toUpperCase() : defaults.accent;
          if (visual !== defaults.visual) { nextPresentation.visual = visual; presentationChanged = true; }
          if (sticky !== defaults.sticky) { nextPresentation.sticky = sticky; presentationChanged = true; }
          if (alertSound !== defaults.sound) { nextPresentation.sound = alertSound; presentationChanged = true; }
          if (volume !== Number(defaults.volume)) { nextPresentation.volume = volume; presentationChanged = true; }
          if (ttl !== Number(defaults.ttl_s)) { nextPresentation.ttl_s = ttl; presentationChanged = true; }
          if (background !== String(defaults.background).toUpperCase()) {
            nextPresentation.background = background; presentationChanged = true;
          }
          if (foreground !== String(defaults.foreground).toUpperCase()) {
            nextPresentation.foreground = foreground; presentationChanged = true;
          }
          if (accent !== String(defaults.accent).toUpperCase()) {
            nextPresentation.accent = accent; presentationChanged = true;
          }
          if (presentationChanged) a.presentation = nextPresentation;
        }
        acts.push(a);
      });
      st.actions = acts;
    }

    function rerender(m) {
      m.querySelector(".mbody").innerHTML = bodyHtml();
      bindDynamic(m);
    }

    function bindDynamic(m) {
      var wSel = $("#rWhen");
      if (wSel) wSel.onchange = function () { collectState(m); rerender(m); };
      $all("input[name='rSched']", m).forEach(function (r) {
        r.onchange = function () { collectState(m); rerender(m); };
      });
      var aw = $("#rAddWin");
      if (aw) aw.onclick = function () {
        collectState(m);
        st.windows.push({ days: DAYS.slice(), from: "22:00", to: "06:00" });
        rerender(m);
      };
      var aa = $("#rAddAct");
      if (aa) aa.onclick = function () {
        collectState(m);
        st.actions.push(st.whenType === "emergency_on" || st.whenType === "emergency_off" ?
          { type: "device_alert",
            targets: { devices: "all", roles: "all", web_subscription_groups: "all" },
            channels: ["in_app", "system_notification", "web_push"], never_suppress: true,
            presentation: { visual: true, sticky: st.whenType === "emergency_on",
                            ttl_s: st.whenType === "emergency_on" ? 0 : 10 } } :
          { type: "chime" });
        rerender(m);
      };
      $all("[data-ra='type']", m).forEach(function (sel) {
        sel.onchange = function () { collectState(m); rerender(m); };
      });
      $all("[data-ra='del']", m).forEach(function (b) {
        b.onclick = function () {
          collectState(m);
          st.actions.splice(parseInt(b.getAttribute("data-idx"), 10), 1);
          rerender(m);
        };
      });
      $all("[data-ringplay]", m).forEach(function (b) {
        b.onclick = function () {
          var row = b.parentNode;
          while (row && !row.getAttribute("data-arow")) row = row.parentNode;
          var sel = row && row.querySelector("[data-ra='sound']");
          playRingtone(sel ? sel.value : "ding1");
        };
      });
      $all("[data-rw='del']", m).forEach(function (b) {
        b.onclick = function () {
          collectState(m);
          st.windows.splice(parseInt(b.getAttribute("data-idx"), 10), 1);
          rerender(m);
        };
      });
      if (st.whenType === "emergency_on" || st.whenType === "emergency_off") {
        $all("[data-arow] input,[data-arow] select", m).forEach(function (field) {
          if (field.getAttribute("data-ra") === "type") return;
          field.onchange = function () { collectState(m); rerender(m); };
        });
      }
    }

    var m = openModal(t("admin.rules") + " — " + rid, bodyHtml(), function (mm) {
      collectState(mm);
      for (var ai = 0; ai < st.actions.length; ai++) {
        if (!st.actions[ai] || st.actions[ai].type !== "device_alert") continue;
        var validation = L.validateAlertPresentation(st.actions[ai].presentation);
        if (!validation.ok) return validation.errors[0];
      }
      saveAndRefresh(L.ruleEntries(rid, st, cur), null);
    });
    bindDynamic(m);
  }

  function renderRules() {
    var el = $("#tab-rules");
    var rs = cfgObj("trigger_rules");
    var configuredFlow = L.callFlowMode(cfgObj("ui").call_flow);
    var flowSupport = L.callFlowCompatibility(configuredFlow, S.status);
    var h = "<div class='card'><h2>" + esc(t("admin.call_flow")) +
            "</h2><div style='display:flex;gap:8px;align-items:center;flex-wrap:wrap'>" +
            "<select id='callFlowMode'><option value='purpose_first'" +
            (configuredFlow === "purpose_first" ? " selected" : "") + ">purpose_first</option>" +
            "<option value='ring_then_purpose'" +
            (configuredFlow === "ring_then_purpose" ? " selected" : "") +
            ">ring_then_purpose</option></select><button class='btn small' id='callFlowSave'>" +
            esc(t("admin.save")) + "</button></div><div class='dim fhint'>" +
            esc(t("admin.call_flow_purpose_first")) +
            "</div>";
    if (flowSupport.warning || flowSupport.unknown_fleet) {
      var unsupported = flowSupport.unsupported.join(", ") || "capability data unavailable";
      h += "<div class='warn' role='alert' style='font-weight:600;margin-top:8px'>⚠ " +
           esc(t("admin.call_flow_mixed_warning")) +
           " " + esc(unsupported) + "</div>";
    } else if (configuredFlow === "ring_then_purpose") {
      h += "<div class='ok fhint'>" +
           esc(t("admin.call_flow_supported")) +
           "</div>";
    }
    h += "</div><div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_rule")) + "</button></div>";
    for (var id in rs) {
      var r = rs[id];
      var when = r.when || {};
      var target = "";
      if (when.type === "device_offline") {
        target = when.devices === "all" || !when.devices ? t("admin.all") :
                 (when.devices || []).map(deviceName).join(", ");
      } else {
        target = (when.doors && when.doors.length) ?
                 when.doors.map(doorLabel).join(", ") : t("admin.all");
      }
      var acts = (r.actions || []).map(actionLabel);
      h += "<div class='card rule" + (r.enabled === false ? " offline" : "") + "'>" +
           "<div class='chead'><h2>" + esc(whenLabel(when.type)) + ": " + esc(target) +
           " <span class='dim'>(" + esc(id) + ")</span></h2>" +
           "<label class='mc'><input type='checkbox' data-act='toggle' data-id='" + esc(id) +
           "'" + (r.enabled !== false ? " checked" : "") + "> " +
           esc(t("admin.enabled")) + "</label></div>" +
           "<div class='dim' style='margin:4px 0'>" + esc(t("admin.schedule")) +
           ": " + esc(scheduleLabel(r.schedule)) + "</div><div>";
      for (var i = 0; i < acts.length; i++) h += "<span class='chip'>" + esc(acts[i]) + "</span>";
      if (when.type === "emergency_on" || when.type === "emergency_off") {
        var sosWarnings = L.sosRuleWarnings(r, S.status, S.cfg);
        var sosPreview = L.sosDryRunPreview(r, S.status, S.cfg);
        h += "<div class='dim fhint'>" + esc(t("admin.sos_dry_run")) +
             ": " + esc(t("admin.sos_local_recipients")) + " " +
             sosPreview.local_recipients + " · Web Push " +
             (sosPreview.web_push_recipients === null ? "?" : sosPreview.web_push_recipients) +
             "</div>";
        for (var wi = 0; wi < sosWarnings.length; wi++)
          h += "<div class='warn fhint'>⚠ " + esc(sosWarningText(sosWarnings[wi])) + "</div>";
      }
      h += "</div><div class='ops' style='margin-top:8px'><button class='btn2' data-act='edit' data-id='" +
           esc(id) + "'>" + esc(t("admin.edit")) +
           "</button> <button class='btn2 danger' data-act='del' data-id='" + esc(id) + "'>" +
           esc(t("admin.delete")) + "</button></div></div>";
    }
    el.innerHTML = h;
    bindActs(el, {
      add: function () { editRule(null); },
      edit: function (id) { editRule(id); },
      del: function (id) {
        confirmDelete(id, function () { saveAndRefresh(null, ["trigger_rules." + id]); });
      }
    });
    $("#callFlowSave").onclick = function () {
      var mode = L.callFlowMode($("#callFlowMode").value);
      saveAndRefresh([{ key: "ui.call_flow", value: mode }], null);
    };
    $("#callFlowMode").onchange = function () {
      var selected = L.callFlowCompatibility($("#callFlowMode").value, S.status);
      if (selected.warning || selected.unknown_fleet) {
        msg(t("admin.call_flow_mixed_warning"));
      }
    };

    $all("[data-act='toggle']", el).forEach(function (cb) {
      cb.onchange = function () {
        var id = cb.getAttribute("data-id");
        var r = JSON.parse(JSON.stringify(cfgObj("trigger_rules")[id] || {}));
        r.enabled = cb.checked;
        saveAndRefresh([{ key: "trigger_rules." + id, value: r }], null);
      };
    });
  }


  function sortedQrIds() {
    var qrs = cfgObj("quick_replies");
    var ids = [];
    for (var id in qrs) ids.push(id);
    ids.sort(function (a, b) {
      var oa = qrs[a].order || 1000, ob = qrs[b].order || 1000;
      return oa !== ob ? oa - ob : (a < b ? -1 : 1);
    });
    return ids;
  }

  function editQuickReply(id) {
    var isNew = !id;
    var qrs = cfgObj("quick_replies");
    var cur = isNew ? {} : qrs[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "qid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("qr_", qrs) : id },
      { id: "ja", label: t("admin.label_ja"), value: lb.ja },
      { id: "en", label: t("admin.label_en"), value: lb.en },
      { id: "zh", label: t("admin.label_zh"), value: lb.zh },
      { id: "speak", label: t("admin.qr_speak"), type: "check",
        value: cur.speak !== false }];

    var au = cur.audio || {};
    var opts = assetOptions("audio", t("admin.audio_none"));
    var langs = uiLangs();
    langs.forEach(function (lg) {
      fields.push({ id: "audio_" + lg, label: t("admin.audio") + " — " + langName(lg), type: "audio",
                    value: au[lg] || "", options: opts });
    });
    var m = openForm(t("admin.quick_replies"), fields, function (v) {
      var qid = isNew ? L.safeId(v.qid) : id;
      if (!qid) return "ID?";
      v.order = isNew ? sortedQrIds().length + 1 : (cur.order || 1);

      var next = {};
      for (var k in au) next[k] = au[k];
      langs.forEach(function (lg) { next[lg] = v["audio_" + lg] || ""; });
      v.audio = next;
      saveAndRefresh(L.quickReplyEntries(qid, v, cur), null);
    });
    bindAudioPlay(m);
  }

  function renderQuickReplies() {
    var el = $("#tab-qr");
    var qrs = cfgObj("quick_replies");
    var ids = sortedQrIds();
    var h = "<div class='card'><div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_reply")) + "</button></div><table><thead><tr><th>#</th><th>" +
            esc(t("admin.label_ja")) + "</th><th>" + esc(t("admin.qr_speak")) +

            "</th><th>" + esc(t("admin.audio")) + "</th><th></th></tr></thead><tbody>";
    ids.forEach(function (id, i) {
      var q = qrs[id], au = q.audio || {}, chips = "";
      for (var lg in au) {
        if (!au[lg]) continue;
        chips += "<span class='chip'>" + esc(lg + ": " + assetLabel(au[lg])) +
                 " <button class='btn2' data-act='play' data-id='" + esc(au[lg]) +
                 "'>▶</button></span>";
      }
      h += "<tr><td class='dim'>" + (i + 1) + "</td><td>" + esc(L.labelOf(q, LANG, id)) +
           "</td><td>" + (q.speak !== false ? "🔊" : "—") + "</td><td>" +
           (chips || "<span class='dim'>TTS</span>") + "</td><td class='ops'>" +
           "<button class='btn2' data-act='up' data-id='" + esc(id) + "'>↑</button>" +
           "<button class='btn2' data-act='down' data-id='" + esc(id) + "'>↓</button> " +
           "<button class='btn2' data-act='edit' data-id='" + esc(id) + "'>" +
           esc(t("admin.edit")) + "</button> <button class='btn2 danger' data-act='del' data-id='" +
           esc(id) + "'>" + esc(t("admin.delete")) + "</button></td></tr>";
    });
    h += "</tbody></table></div>";
    el.innerHTML = h;
    function move(id, dir) {
      var order = sortedQrIds();
      var i = order.indexOf(id), j = i + dir;
      if (i < 0 || j < 0 || j >= order.length) return;
      order[i] = order[j];
      order[j] = id;
      saveAndRefresh(L.reorderEntries(order, cfgObj("quick_replies")), null);
    }
    bindActs(el, {
      add: function () { editQuickReply(null); },
      edit: function (id) { editQuickReply(id); },
      del: function (id) {
        confirmDelete(L.labelOf(qrs[id], LANG, id),
                      function () { saveAndRefresh(null, ["quick_replies." + id]); });
      },
      up: function (id) { move(id, -1); },
      down: function (id) { move(id, 1); },
      play: function (hash) { playAsset(hash); }
    });
  }


  function editHousehold(id) {
    var isNew = !id;
    var hs = cfgObj("households");
    var cur = isNew ? {} : hs[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "hid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("h", hs) : id },
      { id: "ja", label: t("admin.label_ja"), value: lb.ja },
      { id: "en", label: t("admin.label_en"), value: lb.en },
      { id: "zh", label: t("admin.label_zh"), value: lb.zh },
      { id: "chat_ids", label: t("admin.tg_chat_ids"),
        value: (cur.telegram_chat_ids || []).join(", "), ph: "123456789, -100200300" },
      { id: "sip_ext", label: t("admin.sip_extensions"),
        value: (cur.sip_extensions || []).join(", "), ph: "201, 202" }];
    openForm(t("admin.households"), fields, function (v) {
      var hid = isNew ? L.safeId(v.hid) : id;
      if (!hid) return "ID?";
      saveAndRefresh(L.householdEntries(hid, v, cur), null);
    });
  }

  function renderHouseholds() {
    var el = $("#tab-households");
    var hs = cfgObj("households");
    var h = "<div class='card'><div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_household")) + "</button></div><table><thead><tr><th>" +
            esc(t("admin.households")) + "</th><th>Telegram</th><th>SIP</th><th></th></tr>" +
            "</thead><tbody>";
    for (var id in hs) {
      var hh = hs[id];
      h += "<tr><td>" + esc(householdLabel(id)) + " <span class='dim'>(" + esc(id) +
           ")</span></td><td class='dim'>" + esc((hh.telegram_chat_ids || []).join(", ")) +
           "</td><td class='dim'>" + esc((hh.sip_extensions || []).join(", ")) +
           "</td><td class='ops'><button class='btn2' data-act='edit' data-id='" + esc(id) + "'>" +
           esc(t("admin.edit")) + "</button> <button class='btn2 danger' data-act='del' data-id='" +
           esc(id) + "'>" + esc(t("admin.delete")) + "</button></td></tr>";
    }
    h += "</tbody></table></div>";
    el.innerHTML = h;
    bindActs(el, {
      add: function () { editHousehold(null); },
      edit: function (id) { editHousehold(id); },
      del: function (id) {
        confirmDelete(householdLabel(id),
                      function () { saveAndRefresh(null, ["households." + id]); });
      }
    });
  }


  function renderIntegrations() {
    var el = $("#tab-integrations");
    var integ = cfgObj("integrations");
    var mqtt = integ.mqtt || {}, tg = integ.telegram || {}, push = integ.web_push || {};
    var pushStatus = S.status && S.status.web_push ? S.status.web_push : {};
    var sip = cfgObj("sip");
    var qh = (cfgObj("quiet_hours") || {})["default"] || {};
    var h = "";

    // MQTT
    h += "<div class='card'><h2>MQTT (Home Assistant)</h2>" +
         "<div class='grid2'>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.host")) +
         "</label><input id='mqHost' value='" + esc(mqtt.host || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.port")) +
         "</label><input id='mqPort' type='number' value='" + esc(mqtt.port || 1883) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.user")) +
         "</label><input id='mqUser' value='" + esc(mqtt.user || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.pass")) +
         "</label><input id='mqPass' type='password' placeholder='" +
         esc(t("admin.secret_unchanged")) + "'></div></div>" +
         "<button class='btn small' id='mqSave'>" + esc(t("admin.save")) + "</button>" +
         (mqtt.pass_ref ? " <button class='btn2' id='mqProvision' disabled>" +
          esc(t("admin.provision_this_node")) + "</button>" : "") + "</div>";

    // Telegram
    h += "<div class='card'><h2>Telegram</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.bot_token")) +
         "</label><input id='tgToken' type='password' placeholder='" +
         (tg.bot_token_ref ? "******** " + esc(t("admin.configured")) : "123456:ABC-…") + "'></div>" +
         "<div class='frow frow-check'><label><input type='checkbox' id='tgPoll'" +
         (tg.poll_updates ? " checked" : "") + "> " + esc(t("admin.poll_updates")) +
         "</label></div>" +
         "<button class='btn small' id='tgSave'>" + esc(t("admin.save")) + "</button> " +
         (tg.bot_token_ref ? "<button class='btn2' id='tgProvision' disabled>" +
          esc(t("admin.provision_this_node")) + "</button> " : "") +
         "<span style='display:inline-block; width:16px'></span>" +
         "<input id='tgTestChat' placeholder='" + esc(t("admin.telegram_test_chat")) +
         "' style='width:200px'> " +
         "<button class='btn2' id='tgTest'>" + esc(t("admin.test_send")) +
         "</button></div>";

    h += "<div class='card'><h2>" + esc(t("admin.web_push_backend")) + "</h2>" +
         "<div class='grid2'>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.web_push_sender_url")) +
         "</label><input id='wpSenderUrl' type='url' value='" +
         esc(push.sender_url || "") + "' placeholder='https://push.example/send'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.web_push_subject")) +
         "</label><input id='wpSubject' value='" + esc(push.vapid_subject || "") +
         "' placeholder='mailto:doorbell@example.com'></div></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.web_push_public_key")) +
         "</label><input id='wpPublicKey' value='" + esc(push.vapid_public_key || "") +
         "' autocomplete='off'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.web_push_private_key")) +
         "</label><input id='wpPrivate' type='password' autocomplete='new-password' placeholder='" +
         (push.vapid_private_key_ref ? esc(t("admin.secret_configured")) : "") + "'> " +
         (push.vapid_private_key_ref ? "<button class='btn2' id='wpPrivateProvision' disabled>" +
          esc(t("admin.provision_this_node")) + "</button>" : "") + "</div>" +
         "<div class='frow frow-check'><label><input type='checkbox' id='wpBearerEnabled'" +
         (push.sender_secret_ref ? " checked" : "") + "> " +
         esc(t("admin.web_push_use_sender_bearer")) + "</label></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.web_push_sender_bearer")) +
         "</label><input id='wpBearer' type='password' autocomplete='new-password' placeholder='" +
         (push.sender_secret_ref ? esc(t("admin.secret_configured")) : "") + "'> " +
         (push.sender_secret_ref ? "<button class='btn2' id='wpBearerProvision' disabled>" +
          esc(t("admin.provision_this_node")) + "</button>" : "") + "</div>" +
         "<div class='dim' id='wpStatus'>" + esc(t("admin.web_push_status")) + ": " +
         esc(t(pushStatus.configured ? "admin.enabled" : "admin.disabled")) + " · " +
         esc(t("admin.web_push_local_secret")) + ": " +
         esc(t(pushStatus.local_secret_ready ? "admin.ready" : "admin.not_ready")) + " · " +
         esc(t("admin.web_push_delivery_backend")) + ": " +
         esc(t(pushStatus.delivery_backend ? "admin.ready" : "admin.not_ready")) + " · " +
         esc(t("admin.leader")) + ": " + esc(pushStatus.leader || "—") +
         (pushStatus.warning_code ? " · " + esc(pushStatus.warning_code) : "") + "</div>" +
         "<button class='btn small' id='wpSave' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";

    // SIP
    h += "<div class='card'><h2>SIP</h2><div class='grid2'>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.host")) +
         "</label><input id='sipServer' value='" + esc(sip.server || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.port")) +
         "</label><input id='sipPort' type='number' value='" + esc(sip.port || 5060) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.transport")) +
         "</label><select id='sipTransport'>";
    ["udp", "tcp", "tls"].forEach(function (tr) {
      h += "<option value='" + tr + "'" + ((sip.transport || "udp") === tr ? " selected" : "") +
           ">" + tr + "</option>";
    });
    h += "</select></div></div>" +
         "<h3 class='dim' style='margin:10px 0 4px'>" +
         esc(t("admin.sip_accounts")) + "</h3>" +
         "<table><thead><tr><th>" + esc(t("admin.devices")) + "</th><th>" +
         esc(t("admin.user")) + "</th><th>" + esc(t("admin.pass")) +
         "</th></tr></thead><tbody>";
    var accounts = sip.accounts || {};
    var servingNodeId = S.status && S.status.node ? String(S.status.node.id || "") : "";
    var devIds = [];
    for (var did in cfgObj("devices")) devIds.push(did);
    for (var aid in accounts) if (devIds.indexOf(aid) < 0) devIds.push(aid);
    devIds.forEach(function (nid) {
      var a = accounts[nid] || {};
      var localSecret = L.canEditSipSecret(nid, servingNodeId);
      h += "<tr><td>" + esc(deviceName(nid)) + " <span class='dim'>(" + esc(nid.slice(0, 8)) +
           ")</span></td><td><input data-sipacct-user='" + esc(nid) + "' value='" +
           esc(a.user || "") + "'></td><td>" + (localSecret ?
           "<input type='password' data-sipacct-pass='" + esc(nid) + "' placeholder='" +
           (a.pass_ref ? esc(t("admin.secret_unchanged")) : "") + "'>" +
           (a.pass_ref ? " <button class='btn2' data-sipacct-provision='" + esc(nid) +
            "' disabled>" + esc(t("admin.provision_this_node")) +
            "</button>" : "") :
           "<span class='dim'>" + esc(t("admin.secret_on_target_only")) + "</span>") + "</td></tr>";
    });
    h += "</tbody></table><button class='btn small' id='sipSave' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";


    h += "<div class='card'><h2>" + esc(t("admin.quiet_hours")) + " / TZ</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.tz_offset")) +
         "</label><input id='tzMin' type='number' value='" +
         esc(integ.tz_offset_min !== undefined ? integ.tz_offset_min : 540) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.windows")) +
         "</label><div id='qhWins'>";
    (qh.windows || []).forEach(function (w, i) {
      h += "<div class='arow' data-qhrow='" + i + "'><input type='time' data-qh='from' value='" +
           esc(w.from || "") + "'> – <input type='time' data-qh='to' value='" + esc(w.to || "") +
           "'> <button class='btn2 danger' data-qh='del'>×</button></div>";
    });
    h += "</div><button class='btn2' id='qhAdd'>+ " + esc(t("admin.add_window")) +
         "</button></div>";
    var ACT_TYPES = [["sip_call", t("admin.act_sip")],
                     ["telegram", t("admin.act_telegram")],
                     ["ha_event", t("admin.act_ha")],
                     ["chime", t("admin.act_chime")]];
    h += "<div class='frow'><label class='flab'>" + esc(t("admin.suppress")) +
         "</label><div class='mcwrap'>";
    ACT_TYPES.forEach(function (a) {
      h += "<label class='mc'><input type='checkbox' data-qhsup='" + a[0] + "'" +
           ((qh.suppress || []).indexOf(a[0]) >= 0 ? " checked" : "") + "> " + esc(a[1]) +
           "</label>";
    });
    h += "</div></div><div class='frow'><label class='flab'>" +
         esc(t("admin.never_suppress")) + "</label><div class='mcwrap'>";
    ACT_TYPES.forEach(function (a) {
      h += "<label class='mc'><input type='checkbox' data-qhnev='" + a[0] + "'" +
           ((qh.never_suppress || []).indexOf(a[0]) >= 0 ? " checked" : "") + "> " + esc(a[1]) +
           "</label>";
    });
    h += "</div></div><button class='btn small' id='qhSave'>" + esc(t("admin.save")) +
         "</button></div>";

    el.innerHTML = h;

    $("#mqSave").onclick = function () {
      savePlanAndRefresh(L.mqttPlan({ host: $("#mqHost").value, port: $("#mqPort").value,
                                      user: $("#mqUser").value, pass: $("#mqPass").value }, mqtt));
    };
    $("#tgSave").onclick = function () {
      savePlanAndRefresh(L.telegramPlan({ bot_token: $("#tgToken").value,
                                          poll_updates: $("#tgPoll").checked }, tg));
    };
    function bindLocalProvision(buttonId, inputId, secretRef) {
      var button = $(buttonId), input = $(inputId);
      if (!button || !input || !secretRef) return;
      input.oninput = function () { button.disabled = !input.value; };
      button.onclick = function () {
        if (!input.value) return;
        savePlanAndRefresh(L.localSecretProvisionPlan(secretRef, input.value));
      };
    }
    bindLocalProvision("#mqProvision", "#mqPass", mqtt.pass_ref);
    bindLocalProvision("#tgProvision", "#tgToken", tg.bot_token_ref);
    bindLocalProvision("#wpPrivateProvision", "#wpPrivate", push.vapid_private_key_ref);
    bindLocalProvision("#wpBearerProvision", "#wpBearer", push.sender_secret_ref);
    function updateWebPushBearerState() {
      var enabled = $("#wpBearerEnabled").checked;
      $("#wpBearer").disabled = !enabled;
      var provision = $("#wpBearerProvision");
      if (provision) provision.disabled = !enabled || !$("#wpBearer").value;
    }
    $("#wpBearerEnabled").onchange = updateWebPushBearerState;
    updateWebPushBearerState();
    $("#wpSave").onclick = function () {
      var privateValue = $("#wpPrivate").value;
      var bearerEnabled = $("#wpBearerEnabled").checked;
      var bearerValue = $("#wpBearer").value;
      if (!privateValue && !push.vapid_private_key_ref) {
        msg(t("admin.web_push_private_required"));
        return;
      }
      if (bearerEnabled && !bearerValue && !push.sender_secret_ref) {
        msg(t("admin.web_push_bearer_required"));
        return;
      }
      savePlanAndRefresh(L.webPushPlan({
        sender_url: $("#wpSenderUrl").value,
        vapid_public_key: $("#wpPublicKey").value,
        vapid_subject: $("#wpSubject").value,
        vapid_private_key: privateValue,
        sender_bearer_enabled: bearerEnabled,
        sender_secret: bearerValue
      }, push));
    };
    $("#tgTest").onclick = function () {
      api("POST", "/api/test/telegram", { chat_id: $("#tgTestChat").value }, function (st, j) {
        if (st === 200 && j && j.ok) { msg(t("admin.test_sent")); return; }
        var err = j && j.err;
        var key = err === "not_leader" ? "admin.err_not_leader" :
                  err === "no_token" ? "admin.err_no_token" :
                  err === "no_chat" ? "admin.err_no_chat" : "admin.save_failed";
        msg(t(key, err || "NG"));
      });
    };
    $("#sipSave").onclick = function () {
      var entries = L.sipEntries({ server: $("#sipServer").value, port: $("#sipPort").value,
                                   transport: $("#sipTransport").value });
      var plans = [];
      devIds.forEach(function (nid) {
        var u = el.querySelector("[data-sipacct-user='" + nid + "']");
        var p = el.querySelector("[data-sipacct-pass='" + nid + "']");
        var existing = accounts[nid] || {};
        if (!u) return;
        if (!u.value && !(p && p.value) && !existing.user) return;
        plans.push(L.sipAccountPlan(nid, u.value, p ? p.value : "", existing));
      });
      savePlanAndRefresh(L.mergeSecretPlans(entries, plans));
    };
    $all("[data-sipacct-provision]", el).forEach(function (button) {
      var nid = button.getAttribute("data-sipacct-provision");
      var input = el.querySelector("[data-sipacct-pass='" + nid + "']");
      var existing = accounts[nid] || {};
      if (!input || !existing.pass_ref) return;
      input.oninput = function () { button.disabled = !input.value; };
      button.onclick = function () {
        if (!input.value) return;
        savePlanAndRefresh(L.localSecretProvisionPlan(existing.pass_ref, input.value));
      };
    });
    $("#qhAdd").onclick = function () {
      var row = document.createElement("div");
      row.className = "arow";
      row.setAttribute("data-qhrow", "x");
      row.innerHTML = "<input type='time' data-qh='from' value='23:00'> – " +
                      "<input type='time' data-qh='to' value='07:00'> " +
                      "<button class='btn2 danger' data-qh='del'>×</button>";
      $("#qhWins").appendChild(row);
      row.querySelector("[data-qh='del']").onclick = function () {
        row.parentNode.removeChild(row);
      };
    };
    $all("[data-qh='del']", el).forEach(function (b) {
      b.onclick = function () {
        var r = b.parentNode;
        r.parentNode.removeChild(r);
      };
    });
    $("#qhSave").onclick = function () {
      var wins = [];
      $all("[data-qhrow]", el).forEach(function (row) {
        var f = row.querySelector("[data-qh='from']"), to = row.querySelector("[data-qh='to']");
        var originalIndex = parseInt(row.getAttribute("data-qhrow"), 10);
        wins.push({ from: f ? f.value : "", to: to ? to.value : "",
                    _existing_index: isNaN(originalIndex) ? -1 : originalIndex });
      });
      var sup = [], nev = [];
      $all("[data-qhsup]", el).forEach(function (c) {
        if (c.checked) sup.push(c.getAttribute("data-qhsup"));
      });
      $all("[data-qhnev]", el).forEach(function (c) {
        if (c.checked) nev.push(c.getAttribute("data-qhnev"));
      });
      var entries = L.tzEntries($("#tzMin").value).concat(
        L.quietEntries({ windows: wins, suppress: sup, never_suppress: nev }, qh));
      saveAndRefresh(entries, null);
    };
  }


  var evFilter = "";
  function renderEvents() {
    var el = $("#tab-events");
    var types = ["", "press", "motion", "reply", "answered", "missed", "offline", "online",
                 "config_changed", "dtmf_action"];
    var h = "<div class='card'><div class='chead'><h2></h2><select id='evFilter'>";
    types.forEach(function (ty) {
      h += "<option value='" + ty + "'" + (evFilter === ty ? " selected" : "") + ">" +
           (ty || esc(t("admin.filter_type"))) + "</option>";
    });
    h += "</select></div><table><thead><tr><th>" + esc(t("panel.event_time")) +
         "</th><th>" + esc(t("panel.event_type")) + "</th><th>" +
         esc(t("admin.door_or_device")) + "</th><th>" + esc(t("admin.details")) +
         "</th></tr></thead><tbody>";
    var evs = S.events || [];
    for (var i = 0; i < evs.length; i++) {
      var e = evs[i];
      if (evFilter && e.type !== evFilter) continue;
      h += "<tr><td class='dim'>" + fmtTime(e.wall_ms) + "</td><td>" + esc(e.type) + "</td><td>" +
           esc(e.door ? doorLabel(e.door) : deviceName(e.device)) + "</td><td class='dim'>" +
           esc(e.payload || "") + "</td></tr>";
    }
    h += "</tbody></table></div>";
    el.innerHTML = h;
    $("#evFilter").onchange = function () {
      evFilter = this.value;
      renderEvents();
    };
  }



  /* ---- Batch 2 shared UI pieces: volume sliders, the time card, announcements ---- */

  /* One 0-100 slider per level with a live number and a preview button. The preview plays in
     this browser, not on the remote device, so it is a rehearsal of the level rather than proof
     that the target hardware is that loud. */
  function volumeLabel(level) {
    if (level === "call") return t("volume.call");
    if (level === "sos") return t("volume.sos");
    return t("volume.idle");
  }

  function volumeRowsHtml(prefix, values, inheritedFrom) {
    var h = "";
    for (var i = 0; i < L.VOLUME_LEVELS.length; i++) {
      var level = L.VOLUME_LEVELS[i];
      var value = values[level] === undefined ? L.VOLUME_DEFAULTS[level] : values[level];
      h += "<div class='frow' data-vol-row='" + esc(prefix) + "' data-vol-level='" + esc(level) +
           "'><label class='flab'>" + esc(volumeLabel(level)) + "</label>" +
           "<div style='display:flex;gap:10px;align-items:center'>" +
           "<input type='range' min='0' max='100' step='1' data-vol='" + esc(prefix + "-" + level) +
           "' value='" + esc(value) + "' style='flex:1;min-width:140px'>" +
           "<output data-vol-out='" + esc(prefix + "-" + level) + "' class='mono' " +
           "style='min-width:3.5em;text-align:right'>" + esc(value) + "</output>" +
           "<button class='btn2 small' data-vol-preview='" + esc(prefix + "-" + level) +
           "' data-vol-sound='" + esc(level) + "'>" + esc(t("volume.preview")) + "</button></div>" +
           (inheritedFrom ? "<div class='dim fhint'>" +
             esc(fmt(t("volume.cluster_default"), { value: inheritedFrom[level] })) + "</div>" : "") +
           "</div>";
    }
    return h;
  }

  function bindVolumeRows(root, prefix) {
    for (var i = 0; i < L.VOLUME_LEVELS.length; i++) {
      (function (level) {
        var id = prefix + "-" + level;
        var slider = root.querySelector("[data-vol='" + id + "']");
        var out = root.querySelector("[data-vol-out='" + id + "']");
        var preview = root.querySelector("[data-vol-preview='" + id + "']");
        if (slider && out) slider.oninput = function () { out.textContent = slider.value; };
        if (preview) preview.onclick = function () {
          var cfgUi = cfgObj("ui"), emergency = cfgObj("emergency");
          var sound = level === "sos" ? (emergency.alarm_sound || "siren1") :
                      level === "call" ? (cfgUi.ringtone || "school_chime") :
                                         (cfgUi.button_sound || "button_click");
          playRingtone(sound, slider ? +slider.value : 100);
        };
      })(L.VOLUME_LEVELS[i]);
    }
  }

  function collectVolumeRows(root, prefix) {
    var out = {};
    for (var i = 0; i < L.VOLUME_LEVELS.length; i++) {
      var level = L.VOLUME_LEVELS[i];
      var slider = root.querySelector("[data-vol='" + prefix + "-" + level + "']");
      out[level] = slider ? +slider.value : L.VOLUME_DEFAULTS[level];
    }
    return out;
  }

  function timeZoneOptionsHtml(selected) {
    var groups = L.timeZoneGroups(), h = "";
    for (var g = 0; g < groups.length; g++) {
      h += "<optgroup label='" + esc(groups[g].region) + "'>";
      for (var z = 0; z < groups[g].zones.length; z++) {
        var id = groups[g].zones[z];
        h += "<option value='" + esc(id) + "'" + (id === selected ? " selected" : "") + ">" +
             esc(L.timeZoneLabel(id)) + "</option>";
      }
      h += "</optgroup>";
    }
    if (selected && L.TIME_ZONES.indexOf(selected) < 0)
      h = "<option value='" + esc(selected) + "' selected>" + esc(selected) + "</option>" + h;
    return h;
  }

  /* The status block is rendered from core's reported source, never inferred from the toggle. */
  function timeStatusHtml() {
    var model = L.timeStatusModel(S.status);
    var rows = [
      [t("time.source"), t(model.source === "ntp" ? "time.source_ntp" : "time.source_system"),
       model.degraded ? "warn" : "ok"],
      [t("time.local_now"), model.localIso || "-", "dim"],
      [t("time.offset"), (model.offsetMs > 0 ? "+" : "") + model.offsetMs + " ms", "dim"],
      [t("time.last_sync"), model.lastSyncMs ? fmtTime(model.lastSyncMs) : t("time.never"), "dim"],
      [t("time.server"), model.server || "-", "dim"],
      [t("time.rtt"), model.rttMs ? model.rttMs + " ms" : "-", "dim"]];
    var h = "";
    for (var i = 0; i < rows.length; i++)
      h += "<div><span class='dim'>" + esc(rows[i][0]) + ":</span> <span class='" +
           esc(rows[i][2]) + "'>" + esc(rows[i][1]) + "</span></div>";
    if (model.errorKey)
      h += "<div class='warn'>" + esc(t(model.errorKey)) + "</div>";
    if (!model.zoneKnown && model.zone)
      h += "<div class='warn'>" + esc(model.zone) + "</div>";
    return h;
  }

  function renderSystem() {
    var el = $("#tab-system");
    var tok = S.panelToken || "";
    var panelCfg = cfgObj("panel");
    var panelRefs = panelCfg.token_refs instanceof Array ? panelCfg.token_refs.filter(function (ref) {
      return typeof ref === "string" && ref.indexOf("secret:") === 0;
    }) : [];
    var base = window.location.protocol + "//" + window.location.host;
    var h = "";

    var timeCfg = cfgObj("time");
    var timeNtp = isObj(timeCfg.ntp) ? timeCfg.ntp : {};
    var timeModel = L.timeStatusModel(S.status);
    var serverText = (timeNtp.servers instanceof Array ? timeNtp.servers : []).join("\n");
    h += "<div class='card'><h2>" + esc(t("time.title")) + "</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("time.zone")) + "</label>" +
         "<select id='timeZone'>" +
         timeZoneOptionsHtml(timeCfg.zone || timeModel.zone || "Asia/Tokyo") + "</select>" +
         "<div class='dim fhint'>" + esc(t("time.zone_hint")) + "</div></div>" +
         "<label class='frow-check'><input type='checkbox' id='timeNtpEnabled'" +
         (timeNtp.enabled === true ? " checked" : "") + "> " + esc(t("time.ntp_enabled")) +
         "</label><div class='dim fhint'>" + esc(t("time.ntp_hint")) + "</div>" +
         "<div class='frow'><label class='flab'>" + esc(t("time.servers")) + "</label>" +
         "<textarea id='timeServers' style='min-height:74px'>" + esc(serverText) + "</textarea>" +
         "<div class='dim fhint'>" + esc(t("time.servers_hint")) + "</div></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("time.interval_s")) + "</label>" +
         "<input type='number' id='timeInterval' min='60' max='86400' value='" +
         esc(timeNtp.interval_s === undefined ? 900 : timeNtp.interval_s) + "'></div>" +
         "<div style='display:flex;gap:8px;flex-wrap:wrap;margin-top:8px'>" +
         "<button class='btn small' id='timeSave'>" + esc(t("admin.save")) + "</button>" +
         "<button class='btn2 small' id='timeSyncNow'>" + esc(t("time.sync_now")) +
         "</button></div>" +
         "<h3 style='margin-top:14px'>" + esc(t("time.status")) + "</h3>" +
         "<div id='timeStatusBlock' class='fhint'>" + timeStatusHtml() + "</div></div>";

    var clusterVolumes = L.effectiveVolumes(S.cfg, "");
    h += "<div class='card'><h2>" + esc(t("volume.title")) + "</h2>" +
         "<div class='dim fhint' style='margin-bottom:10px'>" + esc(t("volume.hint")) + "</div>" +
         volumeRowsHtml("sysvol", clusterVolumes, null) +
         "<button class='btn small' id='volSave' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";

    var emergencyCfg = cfgObj("emergency");
    var trigger = isObj(emergencyCfg.trigger) ? emergencyCfg.trigger : {};
    var sosRoles = emergencyCfg.button_on_roles instanceof Array ?
      emergencyCfg.button_on_roles : ["indoor_panel"];
    h += "<div class='card'><h2>" + esc(t("sos.title")) + "</h2>" +
         "<div class='dim fhint' style='margin-bottom:10px'>" + esc(t("sos.hint")) + "</div>" +
         "<div class='frow'><label class='flab'>" + esc(t("sos.trigger_mode")) + "</label>" +
         "<select id='sosMode'><option value='slide'" +
         (trigger.mode === "hold" ? "" : " selected") + ">" + esc(t("sos.mode_slide")) +
         "</option><option value='hold'" + (trigger.mode === "hold" ? " selected" : "") + ">" +
         esc(t("sos.mode_hold")) + "</option></select></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("sos.countdown_s")) + "</label>" +
         "<input type='number' id='sosCountdown' min='0' max='10' value='" +
         esc(trigger.countdown_s === undefined ? 3 : trigger.countdown_s) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("sos.button_on_roles")) +
         "</label><div class='mcwrap'>" +
         "<label class='mc'><input type='checkbox' data-sos-role='indoor_panel'" +
         (sosRoles.indexOf("indoor_panel") >= 0 ? " checked" : "") + "> " +
         esc(t("admin.role_indoor")) + "</label>" +
         "<label class='mc'><input type='checkbox' data-sos-role='door_station'" +
         (sosRoles.indexOf("door_station") >= 0 ? " checked" : "") + "> " +
         esc(t("admin.role_door")) + "</label></div></div>" +
         "<label class='frow-check'><input type='checkbox' id='sosCancelPin'" +
         (emergencyCfg.cancel_requires_pin !== false ? " checked" : "") + "> " +
         esc(t("sos.cancel_requires_pin")) + "</label>" +
         "<div class='frow'><label class='flab'>" + esc(t("sos.alarm_sound")) + "</label>" +
         "<div style='display:flex;gap:8px;align-items:center'><select id='sosSound'>";
    ringtoneOptions().forEach(function (option) {
      h += "<option value='" + esc(option.v) + "'" +
        ((emergencyCfg.alarm_sound || "siren1") === option.v ? " selected" : "") + ">" +
        esc(option.label) + "</option>";
    });
    h += "</select><button class='btn2 small' id='sosSoundPlay'>▶ " +
         esc(t("admin.audio_play")) + "</button></div></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("sos.alarm_volume")) + "</label>" +
         "<div style='display:flex;gap:10px;align-items:center'>" +
         "<input type='range' min='0' max='100' step='1' id='sosVolume' value='" +
         esc(emergencyCfg.alarm_volume === undefined ? 100 : emergencyCfg.alarm_volume) +
         "' style='flex:1;min-width:140px'>" +
         "<output id='sosVolumeOut' class='mono' style='min-width:3.5em;text-align:right'>" +
         esc(emergencyCfg.alarm_volume === undefined ? 100 : emergencyCfg.alarm_volume) +
         "</output></div></div>" +
         "<button class='btn small' id='sosSave' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";

    var webSosEnabled = emergencyCfg.web_active_page_alerts !== false;
    h += "<div class='card'><h2>" +
         esc(t("admin.web_sos_title")) + "</h2>" +
         "<label class='frow-check'><input type='checkbox' id='webSosEnabled'" +
         (webSosEnabled ? " checked" : "") + "> " +
         esc(t("admin.web_sos_enabled")) +
         "</label><div class='warn fhint'>" +
         esc(t("admin.web_sos_warning")) +
         "</div><button class='btn small' id='webSosSave' style='margin-top:8px'>" +
         esc(t("admin.save")) + "</button></div>";

    h += "<div class='card'><h2>" + esc(t("admin.export")) + " / " +
         esc(t("admin.import")) + "</h2>" +
         "<button class='btn small' id='sysExport'>" + icon("download") + " " + esc(t("admin.export")) +
         "</button><div class='dim fhint' style='margin:10px 0 4px'>" +
         esc(t("admin.import_hint")) + "</div>" +
         "<textarea id='sysImport' style='min-height:110px' placeholder='{ \"doors\": … }'></textarea>" +
         "<button class='btn small' id='sysImportBtn' style='margin-top:8px'>" +
         esc(t("admin.import")) + "</button></div>";

    h += "<div class='card'><h2>" + esc(t("admin.panel_token")) + "</h2>" +
         "<div class='mono' id='panelTok'>" + esc(tok || "—") + "</div>";
    if (tok)
      h += "<div class='dim fhint'><a href='" + esc(base + "/panel/door#k=" + tok) +
           "' target='_blank'>/panel/door#k=…</a> · <a href='" +
           esc(base + "/panel/monitor#k=" + tok) + "' target='_blank'>/panel/monitor#k=…</a></div>";
    h += "<button class='btn2' id='tokRotate' style='margin-top:8px'>" +
         esc(t("admin.rotate")) + "</button>";
    if (panelRefs.length) {
      h += "<div class='frow' style='margin-top:10px'><select id='panelProvisionRef'>";
      panelRefs.forEach(function (ref) {
        h += "<option value='" + esc(ref) + "'>" + esc(ref) + "</option>";
      });
      h += "</select><input id='panelProvisionToken' type='password' autocomplete='off' " +
           "spellcheck='false' placeholder='********'><button class='btn2' " +
           "id='panelProvision' disabled>" +
           esc(t("admin.provision_this_node")) + "</button></div>";
    }
    h += "</div>";

    h += "<div class='card'><h2>" + esc(t("pair.tab")) + "</h2>" +
         "<button class='btn small' id='pairOpen'>" + esc(t("pair.open_panel")) +
         "</button></div>";

    h += "<div class='card'><h2>" + esc(t("admin.raw_config")) + "</h2>" +
         "<textarea id='cfgView' readonly></textarea>" +
         "<div style='display:flex; gap:8px; margin-top:10px'>" +
         "<input id='cfgKey' type='text' placeholder='doors.d_front.label' style='flex:1'>" +
         "<input id='cfgVal' type='text' placeholder='" +
         esc(t("admin.config_value_placeholder")) + "' style='flex:2'>" +
         "<button class='btn' id='cfgSet'>" + esc(t("admin.write")) + "</button></div></div>";

    h += "<div class='card'><h2>" + esc(t("admin.logs")) + "</h2>" +
         "<button class='btn2' id='logBtn'>" + icon("reload") + "</button> " +
         "<button class='btn2' id='logCopy'>" + icon("copy") + " " + esc(t("admin.copy")) + "</button>" +
         "<pre id='logOut' class='mono' " +
         "style='white-space:pre-wrap; font-size:11px; margin-top:8px'></pre></div>";
    el.innerHTML = h;

    bindVolumeRows(el, "sysvol");
    $("#timeSave").onclick = function () {
      var entries;
      try {
        entries = L.timeEntries({ zone: $("#timeZone").value,
                                  ntp_enabled: $("#timeNtpEnabled").checked,
                                  servers: $("#timeServers").value,
                                  interval_s: $("#timeInterval").value });
      } catch (e) {
        msg(t(e.message === "servers" ? "time.invalid_servers" :
              (e.message === "interval_s" ? "time.invalid_interval" : "time.invalid_zone")));
        return;
      }
      saveAndRefresh(entries, null);
    };
    $("#timeSyncNow").onclick = function () {
      api("POST", "/api/time/sync", {}, function (st, result) {
        if (st === 200 && result && result.ok) {
          msg(t("time.sync_started"));
          // The exchange is asynchronous; re-read status rather than assuming it finished.
          setTimeout(function () {
            refreshStatus(function () {
              if ($("#timeStatusBlock")) $("#timeStatusBlock").innerHTML = timeStatusHtml();
            });
          }, 1200);
        } else {
          msg(t(result && result.err === "ntp_disabled" ? "time.ntp_off" :
                "time.sync_failed"));
        }
      });
    };
    $("#volSave").onclick = function () {
      saveAndRefresh(L.volumeEntries(collectVolumeRows(el, "sysvol")), null);
    };
    $("#sosVolume").oninput = function () {
      $("#sosVolumeOut").textContent = $("#sosVolume").value;
    };
    $("#sosSoundPlay").onclick = function () {
      playRingtone($("#sosSound").value, +$("#sosVolume").value);
    };
    $("#sosSave").onclick = function () {
      var roles = [];
      $all("[data-sos-role]", el).forEach(function (box) {
        if (box.checked) roles.push(box.getAttribute("data-sos-role"));
      });
      saveAndRefresh(L.sosEntries({ mode: $("#sosMode").value,
                                    countdown_s: $("#sosCountdown").value,
                                    button_on_roles: roles,
                                    cancel_requires_pin: $("#sosCancelPin").checked,
                                    alarm_sound: $("#sosSound").value,
                                    alarm_volume: $("#sosVolume").value },
                                  cfgObj("emergency")), null);
    };

    $("#cfgView").value = JSON.stringify(S.cfg, null, 2);
    $("#webSosSave").onclick = function () {
      saveAndRefresh(L.webSosEntries($("#webSosEnabled").checked), null);
    };
    $("#sysExport").onclick = function () {
      var blob = new Blob([JSON.stringify(S.cfg, null, 2)], { type: "application/json" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "doorbell-config.json";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    };
    $("#sysImportBtn").onclick = function () {
      var txt = $("#sysImport").value.replace(/^\s+|\s+$/g, "");
      if (!txt) return;
      var parsed;
      try { parsed = JSON.parse(txt); } catch (e) { msg("JSON?"); return; }
      var entries;
      if (parsed instanceof Array) entries = parsed;
      else if (parsed && parsed.entries instanceof Array) entries = parsed.entries;
      else entries = L.flattenConfig(parsed);
      postEntries(entries, null, function (ok, j) {
        if (ok) {
          msg(fmt(t("admin.imported"), { n: j.n || entries.length }));
          refreshConfig(function () { renderTab(); });
        } else if (j && j.unavailable)
          msg(t("admin.atomic_batch_unavailable"));
        else msg(t("admin.save_failed") + ((j && j.err) ? ": " + j.err : ""));
      });
    };
    $("#tokRotate").onclick = function () {
      if (!window.confirm(t("admin.rotate_confirm")))
        return;
      api("POST", "/api/panel-token/rotate", {}, function (st, j) {
        if (st === 200 && j && j.ok) {
          S.panelToken = j.token || "";
          msg(t("admin.saved"));
          refreshConfig(function () { renderTab(); });
        } else msg(t("admin.save_failed"));
      });
    };
    if ($("#panelProvision")) {
      $("#panelProvisionToken").oninput = function () {
        $("#panelProvision").disabled = !this.value;
      };
      $("#panelProvision").onclick = function () {
        var input = $("#panelProvisionToken");
        if (!input.value) return;
        api("POST", "/api/panel-token/provision",
            L.panelProvisionPayload($("#panelProvisionRef").value, input.value),
            function (st, j) {
          if (st === 200 && j && j.ok) {
            input.value = "";
            $("#panelProvision").disabled = true;
            msg(t("admin.saved"));
          } else msg(t("admin.save_failed"));
        });
      };
    }
    if ($("#pairOpen")) $("#pairOpen").onclick = function () { switchTab("pair"); };
    $("#cfgSet").onclick = function () {
      var key = $("#cfgKey").value.replace(/^\s+|\s+$/g, "");
      var val = $("#cfgVal").value.replace(/^\s+|\s+$/g, "");
      if (!key || !val) return;
      var jsonValue;
      try { jsonValue = JSON.parse(val); } catch (e) { msg(t("admin.valid_json_required")); return; }
      postEntries([{ key: key, value: jsonValue }], null, function (ok, result) {
        msg(ok ? "OK" : ((result && result.unavailable) ?
          t("admin.atomic_batch_unavailable") : "NG" +
          ((result && result.err) ? " (" + result.err + ")" : "")));
        refreshConfig(function () { renderTab(); });
      });
    };
    $("#logBtn").onclick = function () {
      api("GET", "/api/logs", null, function (st, j) {
        if (st === 200 && j) $("#logOut").textContent = (j.logs || []).join("\n");
      });
    };
    $("#logCopy").onclick = function () {
      copyText($("#logOut").textContent || "", $("#logCopy"));
    };
    $("#logBtn").onclick();
  }


  /* ---------------- Add device (§5.0 onboarding + §5.1 panel) ----------------
   * `pairing.state` from GET /api/pairing decides which view is drawn. The snapshot is polled
   * every two seconds while the tab is open; peers from /api/status stand in for device_joined
   * until the admin API gains an event stream.
   */

  var PAIR = { snap: null, rows: {}, form: {}, poll: 0, tick: 0, scan: null, err: "",
               joinErr: "", hadToken: false, created: false };

  function pairPeerIds() {
    var ps = S.status.peers || [], out = [], i;
    for (i = 0; i < ps.length; i++) if (ps[i] && ps[i].id) out.push(ps[i].id);
    return out;
  }

  function refreshPairing(cb) {
    api("GET", "/api/pairing", null, function (st, j) {
      if (st === 200 && j) {
        PAIR.snap = j;
        PAIR.rows = L.pairMergeRows(PAIR.rows, j, pairPeerIds(), new Date().getTime());
        if (j.token && j.token.active) PAIR.hadToken = true;
        if (j.state === "unpaired") { PAIR.hadToken = false; PAIR.created = false; }
      }
      if (S.tab === "pair") renderPair();
      if (cb) cb();
    });
  }

  function pairFail(st, j) {
    PAIR.err = L.pairErrKey((j && j.err) || (st === 0 ? "connect_failed" : ""));
  }

  function pairPost(path, body, done) {
    api("POST", path, body, function (st, j) {
      var ok = st === 200 && (!j || j.ok !== false);
      if (ok) PAIR.err = "";
      else pairFail(st, j);
      if (done) done(ok, j);
      refreshPairing();
    });
  }

  function drawPairQr(canvas, text) {
    var m = L.qrModules(text);
    if (!m || !canvas || !canvas.getContext) return false;
    var quiet = 4, scale = Math.max(3, Math.ceil(248 / (m.size + quiet * 2)));
    var px = (m.size + quiet * 2) * scale, x, y;
    canvas.width = px;
    canvas.height = px;
    canvas.style.width = "100%";
    canvas.style.maxWidth = px + "px";
    var ctx = canvas.getContext("2d");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, px, px);
    ctx.fillStyle = "#000000";
    for (y = 0; y < m.size; y++)
      for (x = 0; x < m.size; x++)
        if (m.modules[y * m.size + x])
          ctx.fillRect((x + quiet) * scale, (y + quiet) * scale, scale, scale);
    return true;
  }

  function pairErrHtml() {
    if (!PAIR.err) return "";
    return "<div class='card'><div class='err'>" + esc(t(PAIR.err)) + "</div></div>";
  }

  function pairSelfLine(m) {
    var parts = [];
    if (m.self.name) parts.push(m.self.name);
    if (m.self.model) parts.push(m.self.model);
    if (m.self.role) parts.push(m.self.role);
    if (m.self.addr) parts.push(m.self.addr);
    return parts.join(" · ");
  }

  function pairQrCardHtml(m) {
    return "<div class='qrbox'>" +
           (m.qrText ? "<canvas id='pairQr'></canvas>" :
             "<div class='qrph dim'>" + esc(t("pair.qr_pending")) + "</div>") +
           "<div class='dim fhint'>" + esc(t("pair.qr_caption")) + "</div></div>";
  }

  function pairOnboardingHtml(m) {
    var h = "<div class='card'><h2>" + esc(t("pair.title_unpaired")) + "</h2>" +
            "<div class='dim fhint mono'>" + esc(pairSelfLine(m)) + "</div>";
    if (m.state === "persist_error") {
      h += "<div class='err' style='margin-top:10px'>" +
           esc(t("pair.persist_error_title")) + "</div><div class='dim fhint'>" +
           esc(t("pair.persist_error_body")) + "</div>" +
           "<button class='btn small' style='margin-top:10px' data-pair='retry'>" +
           esc(t("pair.retry")) + "</button></div>";
      return h + pairErrHtml();
    }
    if (m.state === "revoked") {
      h += "<div class='err' style='margin-top:10px'>" + esc(t("pair.revoked")) + "</div>" +
           "<button class='btn small' style='margin-top:10px' data-pair='unpair'>" +
           esc(t("pair.clear_title")) + "</button></div>";
      return h + pairErrHtml();
    }
    if (m.state === "joining") {
      h += "<div style='margin-top:12px'><span class='spin'></span>" +
           esc(t("pair.joining")) + "</div></div>";
      return h + pairErrHtml();
    }
    h += "<div style='margin-top:12px'><span class='spin'></span>" +
         esc(t("pair.searching")) + "</div><div class='dim fhint'>" +
         esc(t("pair.searching_hint")) + "</div>" + pairQrCardHtml(m) + "</div>";
    h += "<div class='card'><h2>" + esc(t("pair.create_home")) + "</h2>" +
         "<div class='dim fhint' style='margin-bottom:10px'>" +
         esc(t("pair.create_home_confirm")) + "</div>" +
         "<button class='btn small' data-pair='found'>" +
         esc(t("pair.create_home")) + "</button></div>";
    h += "<div class='card'><h2>" + esc(t("pair.join_with_code")) + "</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("pair.address_label")) + "</label>" +
         "<input id='pairJoinHost' type='text' autocomplete='off' spellcheck='false' " +
         "placeholder='" + esc(t("pair.address_example")) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("pair.code_label")) + "</label>" +
         "<input id='pairJoinPin' type='text' inputmode='numeric' autocomplete='off' " +
         "maxlength='6'></div>" +
         "<button class='btn small' data-pair='join'>" + esc(t("pair.join_submit")) + "</button>" +
         (PAIR.joinErr ? "<div class='err fhint'>" + esc(t(PAIR.joinErr)) + "</div>" : "") +
         "</div>";
    return h + pairErrHtml();
  }

  function pairRowHtml(r) {
    var right, note = "", meta = [];
    if (r.state === "adding") {
      right = "<span class='dim'><span class='spin'></span>" + esc(t("pair.adding")) + "</span>";
    } else if (r.state === "added") {
      right = "<span class='ok'>" + esc(t("pair.added")) + " ✓</span>";
    } else if (r.state === "failed") {
      right = "<button class='btn small' data-pair='add' data-id='" + esc(r.id) + "'>" +
              esc(t("pair.add")) + "</button>";
      note = "<div class='err fhint'>" + esc(t("pair.add_failed")) + " — " + esc(t(r.errKey)) +
             (r.errCode ? " <span class='dim'>" +
               esc(fmt(t("pair.err_detail"), { code: r.errCode })) + "</span>" : "") + "</div>";
    } else {
      right = "<button class='btn small' data-pair='add' data-id='" + esc(r.id) + "'>" +
              esc(t("pair.add")) + "</button> " +
              "<button class='btn2 small' data-pair='deny' data-id='" + esc(r.id) + "'>" +
              esc(t("pair.deny")) + "</button>";
    }
    if (r.detail) meta.push(esc(r.detail));
    if (!r.gone) meta.push(esc(fmt(t("pair.nearby_waiting_since"), { s: r.age_s })));
    return "<div class='pairrow'><div class='pairwho'><div>" + esc(r.label) + "</div>" +
           "<div class='dim fhint'>" + meta.join(" · ") + "</div>" + note + "</div>" +
           "<div class='ops'>" + right + "</div></div>";
  }

  function pairCodeCardHtml(m) {
    var h = "<div class='card'><h2>" + esc(t("pair.add_with_code")) + "</h2>";
    if (!m.token.active) {
      if (PAIR.hadToken)
        h += "<div class='warn' style='margin-bottom:8px'>" +
             esc(t("pair.code_expired")) + "</div>";
      return h + "<button class='btn small' data-pair='code'>" +
             esc(t(PAIR.hadToken ? "pair.new_code" : "pair.add_with_code")) +
             "</button></div>";
    }
    var left = L.pairClock(m.token.expires_s);
    h += "<div class='frow'><label class='flab'>" + esc(t("pair.address_label")) + "</label>" +
         "<div class='pairaddr'><span class='mono' id='pairHost'>" + esc(m.token.host) +
         "</span><button class='btn2 small' data-pair='copyhost'>" + esc(t("pair.copy")) +
         "</button></div></div>" +
         "<div class='pin' id='pairPin'>" + esc(m.token.pin) + "</div>" +
         "<div style='text-align:center'><button class='btn2 small' data-pair='copypin'>" +
         esc(t("pair.copy")) + "</button></div>" +
         "<div style='text-align:center; margin-top:8px'><span id='pairCodeLeft'>" +
         esc(fmt(t("pair.code_expires_in"), left)) + "</span> · <span class='dim'>" +
         esc(fmt(t("pair.code_attempts_left"), { n: m.token.attemptsLeft })) + "</span></div>" +
         "<div class='dim fhint' style='margin-top:8px'>" +
         esc(t("pair.code_instructions")) + "</div>" +
         "<button class='btn2 small' style='margin-top:10px' data-pair='code'>" +
         esc(t("pair.new_code")) + "</button>";
    return h + "</div>";
  }

  function pairAddAllCardHtml(m) {
    var h = "<div class='card'><h2>" + esc(t("pair.add_all")) + "</h2>";
    if (m.pairingMode.active) {
      var left = L.pairClock(m.pairingMode.left_s);
      h += "<div class='warn' id='pairModeOn'>" + esc(fmt(t("pair.add_all_on"),
             { m: left.m, s: left.s, n: m.pairingMode.addedCount })) + "</div>" +
           "<button class='btn small' style='margin-top:10px' data-pair='stopall'>" +
           esc(t("pair.add_all_stop")) + "</button>";
    } else {
      h += "<div class='warn fhint' style='margin-bottom:10px'>" +
           esc(t("pair.add_all_warning")) + "</div>" +
           "<button class='btn2 small' data-pair='addall'>" + esc(t("pair.add_all")) +
           "</button>";
    }
    return h + "</div>";
  }

  function pairScanCardHtml() {
    var h = "<div class='card'><h2>" + esc(t("pair.scan_qr")) + "</h2>";
    if (pairScanSupported())
      h += "<div class='dim fhint' style='margin-bottom:10px'>" + esc(t("pair.scan_hint")) +
           "</div><button class='btn small' style='margin-bottom:12px' data-pair='scan'>" +
           esc(t("pair.scan_qr")) + "</button>";
    else
      h += "<div class='warn fhint' style='margin-bottom:10px'>" +
           esc(t("pair.scan_unavailable_http")) + "</div>";
    h += "<div class='frow'><label class='flab'>" + esc(t("pair.scan_paste")) + "</label>" +
         "<input id='pairPaste' type='text' autocomplete='off' spellcheck='false' " +
         "placeholder='doorbell-pair:…'></div>" +
         "<button class='btn2 small' data-pair='paste'>" + esc(t("pair.add")) + "</button>";
    return h + "</div>";
  }

  function pairPanelHtml(m) {
    var h = "<div class='card'><h2>" + esc(t("pair.tab")) + "</h2><div>" +
            esc(fmt(t("pair.membership"), { n: m.memberCount })) + " · <span class='dim'>" +
            esc(fmt(t("pair.membership_connected"), { n: m.connectedCount })) + "</span>" +
            (m.isFounder ? " <span class='tag'>" + esc(t("pair.created_badge")) + "</span>" : "") +
            "</div>";
    if (PAIR.created)
      h += "<div class='ok' style='margin-top:10px'>" + esc(t("pair.created")) + " ✓</div>" +
           "<div class='dim fhint'>" + esc(t("pair.created_next")) + "</div>";
    h += "</div>";

    h += "<div class='card'><h2>" + esc(t("pair.nearby_title")) + "</h2>";
    if (!m.rows.length)
      h += "<div class='dim' style='padding:4px 0'><span class='spin'></span>" +
           esc(t("pair.nearby_none")) + "</div>";
    for (var i = 0; i < m.rows.length; i++) h += pairRowHtml(m.rows[i]);
    h += "</div>";

    h += pairCodeCardHtml(m) + pairAddAllCardHtml(m) + pairScanCardHtml();
    h += "<div class='card'><h2>" + esc(t("pair.clear_title")) + "</h2>" +
         "<div class='dim fhint' style='margin-bottom:10px'>" + esc(t("pair.clear_confirm")) +
         "</div><button class='btn2 small danger' data-pair='unpair'>" +
         esc(t("pair.clear_title")) + "</button></div>";
    return h + pairErrHtml();
  }

  function pairBind(root) {
    $all("[data-pair]", root).forEach(function (b) {
      b.onclick = function () { pairAct(b.getAttribute("data-pair"), b.getAttribute("data-id"), b); };
    });
    var host = $("#pairJoinHost"), pin = $("#pairJoinPin"), paste = $("#pairPaste");
    if (host) {
      host.value = PAIR.form.host || "";
      host.oninput = function () { PAIR.form.host = host.value; };
    }
    if (pin) {
      pin.value = PAIR.form.pin || "";
      pin.oninput = function () { PAIR.form.pin = pin.value; };
    }
    if (paste) {
      paste.value = PAIR.form.paste || "";
      paste.oninput = function () { PAIR.form.paste = paste.value; };
    }
  }

  function renderPair() {
    var el = $("#tab-pair");
    if (!el) return;
    if (!PAIR.snap) {
      el.innerHTML = "<div class='card'><div class='dim'><span class='spin'></span>" +
                     esc(t("pair.searching")) + "</div></div>";
      return;
    }
    var m = L.pairPanelModel(PAIR.snap, PAIR.rows);
    var active = document.activeElement, focusId = active && active.id ? active.id : "";
    var caret = focusId && active.setSelectionRange ? active.selectionStart : -1;
    el.innerHTML = m.onboarding ? pairOnboardingHtml(m) : pairPanelHtml(m);
    pairBind(el);
    if (m.qrText && $("#pairQr")) drawPairQr($("#pairQr"), m.qrText);
    var again = focusId ? $("#" + focusId) : null;
    if (again) {
      again.focus();
      if (caret >= 0 && again.setSelectionRange) {
        try { again.setSelectionRange(caret, caret); } catch (e) {}
      }
    }
  }

  function pairAct(act, id, btn) {
    var m = L.pairPanelModel(PAIR.snap || {}, PAIR.rows);
    if (act === "add") {
      PAIR.rows[id] = { state: "adding", at: new Date().getTime(),
                        label: L.pairDeviceLabel(pairPendingOf(id)) };
      renderPair();
      pairPost("/api/pairing/invite", { id: id }, function (ok, j) {
        if (ok) return;
        PAIR.rows[id] = { state: "failed", err: (j && j.err) || "", at: new Date().getTime(),
                          label: (PAIR.rows[id] || {}).label || "" };
        PAIR.err = "";
      });
      return;
    }
    if (act === "deny") {
      if (!window.confirm(t("pair.deny_confirm"))) return;
      pairPost("/api/pairing/deny", { id: id }, function (ok) {
        if (ok) delete PAIR.rows[id];
      });
      return;
    }
    if (act === "code") {
      pairPost("/api/join-token", {}, function (ok) { if (ok) PAIR.hadToken = true; });
      return;
    }
    if (act === "addall") {
      if (!window.confirm(t("pair.add_all_warning"))) return;
      pairPost("/api/pairing/start", { seconds: 600 });
      return;
    }
    if (act === "stopall") { pairPost("/api/pairing/stop", {}); return; }
    if (act === "retry") { pairPost("/api/pairing/retry-persist", {}); return; }
    if (act === "unpair") {
      if (!window.confirm(t("pair.clear_confirm"))) return;
      pairPost("/api/pairing/unpair", {}, function (ok) {
        if (ok) { PAIR.rows = {}; PAIR.hadToken = false; PAIR.created = false; }
      });
      return;
    }
    if (act === "found") {
      if (!window.confirm(t("pair.create_home_confirm"))) return;
      pairPost("/api/pairing/found", {}, function (ok) {
        if (!ok) return;
        PAIR.created = true;
        pairPost("/api/join-token", {}, function (minted) { if (minted) PAIR.hadToken = true; });
      });
      return;
    }
    if (act === "join") {
      var plan = L.pairJoinPayload(PAIR.form.host, PAIR.form.pin);
      if (!plan.ok) {
        PAIR.joinErr = plan.field === "pin" ? "pair.err.bad_pin" : "pair.err.connect_failed";
        renderPair();
        return;
      }
      PAIR.joinErr = "";
      pairPost("/api/pairing/join", plan.body, function (ok, j) {
        // The join card owns this error; the shared banner would only repeat it.
        if (!ok) { PAIR.joinErr = L.pairErrKey(j && j.err); PAIR.err = ""; }
      });
      return;
    }
    if (act === "paste") {
      var text = (PAIR.form.paste || "").replace(/^\s+|\s+$/g, "");
      if (!L.pairQrTextValid(text)) { PAIR.err = "pair.err.bad_qr"; renderPair(); return; }
      pairScanSubmit(text);
      return;
    }
    if (act === "copyhost") { copyText(m.token.host, btn); return; }
    if (act === "copypin") { copyText(m.token.pin, btn); return; }
    if (act === "scan") { pairScanOpen(); return; }
    if (act === "scanstop") { pairScanClose(); return; }
  }

  function pairPendingOf(id) {
    var devs = ((PAIR.snap || {}).pending || {}).devices || [];
    for (var i = 0; i < devs.length; i++) if (devs[i] && devs[i].id === id) return devs[i];
    return {};
  }

  function pairScanSubmit(text) {
    var parsed = L.pairQrParse(text);
    if (parsed && parsed.id)
      PAIR.rows[parsed.id] = { state: "adding", at: new Date().getTime(), label: parsed.addr };
    PAIR.form.paste = "";
    pairPost("/api/pairing/scan", { text: text }, function (ok, j) {
      if (ok || !parsed || !parsed.id) return;
      // The row carries the failure, so the shared banner stays quiet.
      PAIR.err = "";
      PAIR.rows[parsed.id] = { state: "failed", err: (j && j.err) || "",
                               at: new Date().getTime(), label: parsed.addr };
    });
  }

  /* The camera path needs a secure context; on a plain-http LAN the paste field is the fallback. */
  function pairScanSupported() {
    return !!(window.isSecureContext && navigator.mediaDevices &&
              navigator.mediaDevices.getUserMedia && window.BarcodeDetector);
  }

  function pairScanClose() {
    var s = PAIR.scan;
    PAIR.scan = null;
    if (!s) return;
    if (s.timer) clearInterval(s.timer);
    if (s.stream) {
      var tracks = s.stream.getTracks ? s.stream.getTracks() : [];
      for (var i = 0; i < tracks.length; i++) tracks[i].stop();
    }
    if (s.box && s.box.parentNode) s.box.parentNode.removeChild(s.box);
  }

  function pairScanOpen() {
    if (PAIR.scan) return;
    var box = document.createElement("div");
    box.className = "pairscan";
    box.innerHTML = "<video id='pairScanVideo' autoplay playsinline muted></video>" +
      "<div class='pairscanframe'></div>" +
      "<div class='pairscanbar'><span id='pairScanMsg'>" + esc(t("pair.scan_hint")) +
      "</span><button class='btn small' data-pair='scanstop'>" + esc(t("pair.scan_cancel")) +
      "</button></div>";
    document.body.appendChild(box);
    PAIR.scan = { box: box, stream: null, timer: 0 };
    pairBind(box);
    var video = $("#pairScanVideo");
    navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } }).then(
      function (stream) {
        if (!PAIR.scan) {
          var ts = stream.getTracks ? stream.getTracks() : [];
          for (var i = 0; i < ts.length; i++) ts[i].stop();
          return;
        }
        PAIR.scan.stream = stream;
        video.srcObject = stream;
        var detector = new window.BarcodeDetector({ formats: ["qr_code"] });
        var busy = false;
        PAIR.scan.timer = setInterval(function () {
          if (busy || !PAIR.scan) return;
          busy = true;
          detector.detect(video).then(function (codes) {
            busy = false;
            for (var i = 0; i < codes.length; i++) {
              if (!L.pairQrTextValid(codes[i].rawValue)) continue;
              var text = codes[i].rawValue;
              pairScanClose();
              msg(t("pair.scanning"));
              pairScanSubmit(text);
              return;
            }
          }, function () { busy = false; });
        }, 300);
      },
      function () {
        var el = $("#pairScanMsg");
        if (el) el.textContent = t("pair.scan_denied");
      });
  }

  function pairTick() {
    if (S.tab !== "pair" || !PAIR.snap) return;
    var m = L.pairPanelModel(PAIR.snap, PAIR.rows);
    var left = $("#pairCodeLeft");
    if (left && m.token.active) {
      PAIR.snap.token.expires_s = Math.max(0, m.token.expires_s - 1);
      left.textContent = fmt(t("pair.code_expires_in"), L.pairClock(PAIR.snap.token.expires_s));
    }
    var on = $("#pairModeOn");
    if (on && m.pairingMode.active) {
      PAIR.snap.pending.pairing_mode_left_s = Math.max(0, m.pairingMode.left_s - 1);
      var c = L.pairClock(PAIR.snap.pending.pairing_mode_left_s);
      on.textContent = fmt(t("pair.add_all_on"),
        { m: c.m, s: c.s, n: m.pairingMode.addedCount });
    }
  }

  function pairTabEnter() {
    renderPair();
    refreshPairing();
    // Peers come along for the ride: a pending device that has left the list and turned into a
    // peer is the confirmation the row shows as "Added".
    if (!PAIR.poll) PAIR.poll = setInterval(function () {
      if (S.tab === "pair") refreshStatus(refreshPairing);
    }, 2000);
    if (!PAIR.tick) PAIR.tick = setInterval(pairTick, 1000);
  }

  function pairTabLeave() {
    pairScanClose();
    if (PAIR.poll) { clearInterval(PAIR.poll); PAIR.poll = 0; }
    if (PAIR.tick) { clearInterval(PAIR.tick); PAIR.tick = 0; }
  }


  function sortedPurposeIds() {
    var ps = cfgObj("visit_purposes"), ids = [];
    for (var id in ps) ids.push(id);
    ids.sort(function (a, b) {
      var oa = ps[a].order || 1000, ob = ps[b].order || 1000;
      return oa !== ob ? oa - ob : (a < b ? -1 : 1);
    });
    return ids;
  }

  function editPurpose(id) {
    var isNew = !id;
    var ps = cfgObj("visit_purposes");
    var cur = isNew ? {} : ps[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "pid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("p_", ps) : id },
      { id: "icon", label: t("admin.purpose_icon"), type: "icon", value: cur.icon || "" },
      { id: "ja", label: t("admin.label_ja"), value: lb.ja },
      { id: "en", label: t("admin.label_en"), value: lb.en },
      { id: "zh", label: t("admin.label_zh"), value: lb.zh }];
    var m = openForm(t("admin.purposes"), fields, function (v) {
      var pid = isNew ? L.safeId(v.pid) : id;
      if (!pid) return "ID?";
      if (!v.ja && !v.en && !v.zh) return t("admin.label_ja") + "?";
      v.order = isNew ? sortedPurposeIds().length + 1 : (cur.order || 1);
      saveAndRefresh(L.purposeEntries(pid, v, cur), null);
    });
    bindIconPick(m);
  }

  function renderPurposes() {
    var el = $("#tab-purposes");
    var ps = cfgObj("visit_purposes"), ids = sortedPurposeIds();
    var ui = cfgObj("ui");
    var h = "<div class='card'><div class='chead'><h2>" + esc(t("admin.purposes")) +
            "</h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add")) + "</button></div>" +
            "<div class='dim fhint' style='margin-bottom:8px'>" +
            esc(t("admin.purpose_hint")) + "</div>" +
            "<table><thead><tr><th>#</th><th></th><th>ja</th><th>en</th><th>zh</th>" +
            "<th>ID</th><th>" + esc(t("purpose.enabled")) +
            "</th><th></th></tr></thead><tbody>";
    ids.forEach(function (id, i) {
      var p = ps[id], lb = p.label || {};
      var enabled = p.enabled !== false;
      h += "<tr" + (enabled ? "" : " class='offline'") + "><td class='dim'>" + (i + 1) +
           "</td><td style='font-size:20px'>" +
           esc(p.icon || "") + "</td><td>" + esc(lb.ja || "") + "</td><td>" +
           esc(lb.en || "") + "</td><td>" + esc(lb.zh || "") + "</td><td class='dim'>" +
           esc(id) + "</td><td><label class='mc'><input type='checkbox' data-purpose-enabled='" +
           esc(id) + "'" + (enabled ? " checked" : "") + "> " +
           esc(enabled ? t("purpose.enabled") : t("purpose.disabled")) + "</label></td>" +
           "<td class='ops'>" +
           "<button class='btn2' data-act='up' data-id='" + esc(id) + "'>↑</button>" +
           "<button class='btn2' data-act='down' data-id='" + esc(id) + "'>↓</button> " +
           "<button class='btn2' data-act='edit' data-id='" + esc(id) + "'>" +
           esc(t("admin.edit")) + "</button> " +
           "<button class='btn2 danger' data-act='del' data-id='" + esc(id) + "'>" +
           esc(t("admin.delete")) + "</button></td></tr>";
    });
    h += "</tbody></table></div>";


    var langs = uiLangs();
    h += "<div class='card'><h2>" + esc(t("admin.languages")) + "</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.visitor_languages")) + "</label>" +
         "<div class='mcwrap'>";
    ["ja", "en", "zh"].forEach(function (lg) {
      h += "<label class='mc'><input type='checkbox' data-uilang='" + lg + "'" +
           (langs.indexOf(lg) >= 0 ? " checked" : "") + "> " + esc(langName(lg)) + "</label>";
    });
    h += "</div><div class='dim fhint'>" + esc(t("admin.visitor_language_primary_hint")) + "</div>" +
         "</div><div class='frow'><label class='flab'>" +
         esc(t("admin.visitor_language_revert")) +
         " (visitor_lang_revert_s)</label><input id='uiRevert' type='number' value='" +
         esc(ui.visitor_lang_revert_s !== undefined ? ui.visitor_lang_revert_s : 60) +
         "' style='width:120px'></div>" +
         "<button class='btn small' id='uiSave'>" + esc(t("admin.save")) +
         "</button></div>";
    el.innerHTML = h;

    function move(id, dir) {
      var order = sortedPurposeIds();
      var i = order.indexOf(id), j = i + dir;
      if (i < 0 || j < 0 || j >= order.length) return;
      order[i] = order[j];
      order[j] = id;
      saveAndRefresh(L.purposeReorderEntries(order, cfgObj("visit_purposes")), null);
    }
    bindActs(el, {
      add: function () { editPurpose(null); },
      edit: function (id) { editPurpose(id); },
      del: function (id) {
        confirmDelete(L.labelOf(ps[id], LANG, id),
                      function () { saveAndRefresh(null, ["visit_purposes." + id]); });
      },
      up: function (id) { move(id, -1); },
      down: function (id) { move(id, 1); }
    });
    // Switching a purpose off keeps its wording, icon and order; deleting it does not.
    $all("[data-purpose-enabled]", el).forEach(function (box) {
      box.onchange = function () {
        saveAndRefresh([{ key: "visit_purposes." + box.getAttribute("data-purpose-enabled") +
                               ".enabled", value: box.checked }], null);
      };
    });
    $("#uiSave").onclick = function () {
      var ls = [];
      $all("[data-uilang]", el).forEach(function (c) {
        if (c.checked) ls.push(c.getAttribute("data-uilang"));
      });
      saveAndRefresh(L.uiEntries({ languages: ls, revert_s: $("#uiRevert").value }), null);
    };
  }



  var VISITOR_PREFIXES = ["idle.", "calling.", "incall.", "degraded.", "offline.", "reply.",
                          "purpose.", "panel.", "ring.", "emergency.", "event.", "notify.",
                          "app."];
  var textsAllKeys = false;

  function isVisitorKey(k) {
    for (var i = 0; i < VISITOR_PREFIXES.length; i++)
      if (k.indexOf(VISITOR_PREFIXES[i]) === 0) return true;
    return false;
  }


  function ensureLocales(langs, cb) {
    var pend = [];
    langs.forEach(function (l) { if (S.locales[l] === undefined) pend.push(l); });
    if (!pend.length) return cb();
    var n = pend.length;
    pend.forEach(function (l) {
      api("GET", "/locale/" + l + ".json", null, function (st, j) {
        S.locales[l] = (st === 200 && j) ? j : {};
        if (--n === 0) cb();
      });
    });
  }

  function defText(lang, key) {
    var d = S.locales[lang] || {};
    if (d[key]) return d[key];
    var ja = S.locales.ja || {};
    return ja[key] || key;
  }

  function renderTexts() {
    var el = $("#tab-texts");
    var langs = uiLangs();
    if (langs.indexOf("ja") < 0) langs = ["ja"].concat(langs);
    ensureLocales(langs, function () { drawTexts(el, langs); });
  }

  function drawTexts(el, langs) {
    var ov = cfgObj("i18n_overrides");
    var seen = {}, keys = [], i, k;
    for (i = 0; i < langs.length; i++) for (k in (S.locales[langs[i]] || {})) seen[k] = 1;
    for (i = 0; i < langs.length; i++)
      for (k in (ov[langs[i]] || {})) seen[k] = 1;
    for (k in seen) if (textsAllKeys || isVisitorKey(k)) keys.push(k);
    keys.sort();

    var h = "<div class='card'><div class='chead'><h2>" + esc(t("admin.texts")) +
            "</h2><label class='mc'><input type='checkbox' id='txAll'" +
            (textsAllKeys ? " checked" : "") + "> " + esc(t("admin.texts_show_all")) + "</label></div>" +
            "<div class='dim fhint' style='margin-bottom:8px'>" +
            esc(t("admin.texts_hint")) + " · " + esc(t("admin.texts_placeholder_hint")) +
            "</div><div class='scrollx'><table class='i18ntbl'><thead><tr><th>" +
            esc(t("admin.key")) + "</th>";
    langs.forEach(function (lg) { h += "<th>" + esc(langName(lg)) + "</th>"; });
    h += "</tr></thead><tbody>";
    keys.forEach(function (key) {
      h += "<tr><td class='k dim'>" + esc(key) + "</td>";
      langs.forEach(function (lg) {
        var cur = (ov[lg] || {})[key] || "";
        h += "<td><textarea rows='1' data-tx='" + esc(lg) + "' data-key='" + esc(key) +
             "' placeholder='" + esc(defText(lg, key)) + "'>" + esc(cur) + "</textarea></td>";
      });
      h += "</tr>";
    });
    h += "</tbody></table></div><button class='btn small' id='txSave' style='margin-top:10px'>" +
         esc(t("admin.save")) + "</button> <span class='dim fhint' id='txCount'></span>" +
         "</div>";
    el.innerHTML = h;

    $("#txAll").onchange = function () {
      textsAllKeys = this.checked;
      drawTexts(el, langs);
    };
    $("#txSave").onclick = function () {
      var changes = {}, n = 0, err = "";
      $all("[data-tx]", el).forEach(function (ta) {
        if (err) return;
        var lg = ta.getAttribute("data-tx"), key = ta.getAttribute("data-key");
        var val = ta.value.replace(/^\s+|\s+$/g, "");
        var cur = ((cfgObj("i18n_overrides")[lg]) || {})[key] || "";
        if (val === cur) return;
        if (val) {
          var d = L.placeholderDiff(defText(lg, key), val);
          if (d) { err = key + " [" + lg + "]: " + d; return; }
        }
        if (!changes[lg]) changes[lg] = {};
        changes[lg][key] = val;
        n++;
      });
      if (err) { msg(t("admin.texts_placeholder_mismatch") + " — " + err); return; }
      if (!n) { msg(t("admin.saved")); return; }
      var e = L.i18nEntries(cfgObj("i18n_overrides"), changes);
      saveAndRefresh(e.entries, e.dels);
    };
    $("#txCount").textContent = fmt(t("admin.texts_count"),
      { keys: keys.length, languages: langs.length });
  }


  var THEME_PRESETS = ["#101418", "#12202c", "#1c1030", "#2a1a12",
                       "#0f2018", "#301820", "#f2efe6", "#000000"];
  var themeScope = "";

  function firstDoorId() {
    var ds = cfgObj("doors");
    for (var id in ds) return id;
    return "";
  }

  function inkRegionLabel(region) {
    if (region === "clock") return t("theme.region_clock");
    if (region === "date") return t("theme.region_date");
    if (region === "status_line") return t("theme.region_status_line");
    if (region === "hint") return t("theme.region_hint");
    if (region === "tile_label") return t("theme.region_tile_label");
    if (region === "footer") return t("theme.region_footer");
    if (region === "notice") return t("theme.region_notice");
    return region;
  }

  function themeCur(scope) {
    return scope ? (((cfgObj("devices")[scope] || {}).local || {}).theme || {})
                 : ((cfgObj("display") || {}).theme || {});
  }

  function themeEffective(scope) {
    var base = themeCur(""), o = themeCur(scope);
    return { bg_color: (o.bg_color !== undefined && o.bg_color !== null && o.bg_color !== "")
                       ? o.bg_color : (base.bg_color || "#101418"),
             bg_image: (scope && o.bg_image === undefined) ? (base.bg_image || "")
                                                           : (o.bg_image || "") };
  }

  function renderTheme() {
    var el = $("#tab-theme");
    var scope = themeScope, own = themeCur(scope), eff = themeEffective(scope);
    var colorOn = !scope || (own.bg_color !== undefined && own.bg_color !== null);
    var imageOn = !scope || own.bg_image !== undefined;

    var h = "<div class='card'><div class='chead'><h2>" + esc(t("admin.theme")) +
            "</h2><select id='thScope'><option value=''" + (scope ? "" : " selected") +
            ">" + esc(t("admin.theme_global_default")) + " (display.theme)</option>";
    var devs = cfgObj("devices");
    for (var did in devs)
      h += "<option value='" + esc(did) + "'" + (scope === did ? " selected" : "") + ">" +
           esc(deviceName(did)) + " (" + esc(did.slice(0, 8)) + ")</option>";
    h += "</select></div><div class='dim fhint' style='margin-bottom:10px'>" +
         esc(t(scope ? "admin.theme_device_hint" : "admin.theme_global_hint")) + " " +
         esc(t("admin.theme_sync_hint")) + "</div>";


    h += "<div class='frow'><label class='flab'>" +
         esc(t("admin.theme_bg_color")) + "</label>";
    if (scope)
      h += "<label class='mc'><input type='checkbox' id='thColorOn'" +
           (colorOn ? " checked" : "") + "> " + esc(t("admin.theme_override_here")) + "</label><br>";
    h += "<input type='color' id='thColor' value='" + esc(eff.bg_color) + "'>" +
         "<span class='mono' id='thColorTxt' style='margin-left:8px'>" + esc(eff.bg_color) +
         "</span><span class='swatches'>";
    THEME_PRESETS.forEach(function (c) {
      h += "<button class='sw' data-sw='" + esc(c) + "' style='background:" + esc(c) +
           "' title='" + esc(c) + "'></button>";
    });
    h += "</span></div>";


    h += "<div class='frow'><label class='flab'>" +
         esc(t("admin.theme_bg_image")) + "</label>";
    if (scope)
      h += "<label class='mc'><input type='checkbox' id='thImageOn'" +
           (imageOn ? " checked" : "") + "> " + esc(t("admin.theme_override_here")) + "</label><br>";
    h += "<select id='thImage'>";
    assetOptions("image", t("admin.theme_no_image")).forEach(function (o) {
      h += "<option value='" + esc(o.v) + "'" + (o.v === eff.bg_image ? " selected" : "") +
           ">" + esc(o.label) + "</option>";
    });
    h += "</select><div class='dim fhint'>" + esc(t("admin.theme_image_hint")) + "</div></div>";


    h += "<div class='frow'><label class='flab'>" +
         esc(t("admin.theme_preview")) + "</label>" +
         "<div class='tprev' id='thPrev'><div class='inner'>" +
         "<div class='pclock' id='thClock'>--:--:--</div>" +

         "<div class='pcall'>" +
         esc(fmt(t("idle.call_button"),
                 { unit: doorLabel((cfgObj("devices")[scope] || {}).door ||
                                   firstDoorId() || "") })) + "</div>" +
         "<div class='pprow' id='thPurps'></div></div></div></div>";
    var appearance = L.appearanceModel(S.status, S.cfg, scope);
    h += "<div class='frow'><label class='flab'>" + esc(t("theme.appearance")) + "</label>" +
         "<select id='thAppearance'>";
    [["auto_system", "theme.appearance_auto_system"],
     ["auto_schedule", "theme.appearance_auto_schedule"],
     ["light", "theme.appearance_light"],
     ["dark", "theme.appearance_dark"]].forEach(function (option) {
      h += "<option value='" + esc(option[0]) + "'" +
        (appearance.configured === option[0] ? " selected" : "") + ">" +
        esc(t(option[1])) + "</option>";
    });
    // The chip states what it is right now, not which mode was chosen.
    h += "</select> <span class='tag'>" + esc(t("theme.now")) + ": " +
         esc(t(appearance.effective === "dark" ? "theme.mode_dark" : "theme.mode_light")) +
         "</span>";
    if (!scope)
      h += "<div class='frow' id='thScheduleRow'><label class='flab'>" +
           esc(t("theme.dark_from")) + "</label>" +
           "<input type='time' id='thDarkFrom' value='" + esc(appearance.darkFrom) + "'>" +
           "<label class='flab'>" + esc(t("theme.light_from")) + "</label>" +
           "<input type='time' id='thLightFrom' value='" + esc(appearance.lightFrom) + "'></div>";
    h += "</div>";

    // Automatic contrast: core publishes one answer for the whole cluster, and the operator may
    // override the call button or any single text region.
    var autoModel = L.themeAutoModel(S.status, eff.bg_color);
    var buttonOverride = own.call_button_bg || (themeCur("").call_button_bg || "");
    var inkOverrides = isObj(own.ink_override) ? own.ink_override :
      (isObj(themeCur("").ink_override) ? themeCur("").ink_override : {});
    h += "<div class='frow'><label class='flab'>" + esc(t("theme.call_button")) + "</label>" +
         "<label class='mc'><input type='radio' name='thBtnMode' value='auto'" +
         (L.colorOk(buttonOverride) ? "" : " checked") + "> " + esc(t("theme.auto")) + "</label>" +
         "<label class='mc'><input type='radio' name='thBtnMode' value='custom'" +
         (L.colorOk(buttonOverride) ? " checked" : "") + "> " + esc(t("theme.custom")) +
         "</label> <input type='color' id='thBtnColor' value='" +
         esc(L.colorOk(buttonOverride) ? buttonOverride : autoModel.callButton) + "'>" +
         "<span class='mono' id='thBtnTxt' style='margin-left:8px'></span>" +
         "<div class='dim fhint'>" +
         esc(t(autoModel.source === "image" ? "theme.background_source_image"
                                            : "theme.background_source_color")) + "</div></div>";

    h += "<div class='frow'><label class='flab'>" + esc(t("theme.ink")) + "</label>" +
         "<div class='scrollx'><table><thead><tr><th>" + esc(t("theme.ink_region")) +
         "</th><th>" + esc(t("theme.auto")) + "</th><th>" + esc(t("theme.custom")) +
         "</th></tr></thead><tbody>";
    for (var ri = 0; ri < L.INK_REGIONS.length; ri++) {
      var region = L.INK_REGIONS[ri];
      var override = inkOverrides[region];
      h += "<tr data-ink-row data-region='" + esc(region) + "'><td>" +
           esc(inkRegionLabel(region)) + "</td><td><input type='checkbox' data-ink-auto" +
           (L.colorOk(override) ? "" : " checked") + "></td><td><input type='color' " +
           "data-ink-color value='" + esc(L.colorOk(override) ? override :
             (autoModel.ink === "dark" ? "#101418" : "#F5F7FA")) + "'></td></tr>";
    }
    h += "</tbody></table></div></div>";

    h += "<button class='btn small' id='thSave'>" + esc(t("admin.save")) + "</button>";
    if (scope)
      h += " <button class='btn2 danger' id='thReset'>" +
           esc(t("admin.theme_reset_override")) + "</button>";
    h += "</div>";
    el.innerHTML = h;


    var pids = sortedPurposeIds().slice(0, 4), pv = "";
    pids.forEach(function (pid) {
      pv += "<div class='pp'>" + esc((cfgObj("visit_purposes")[pid] || {}).icon || "・") + "</div>";
    });
    $("#thPurps").innerHTML = pv || "<div class='pp'>🏠</div><div class='pp'>📦</div>";
    var now = new Date();
    $("#thClock").textContent =
      (now.getHours() < 10 ? "0" : "") + now.getHours() + ":" +
      (now.getMinutes() < 10 ? "0" : "") + now.getMinutes() + ":" +
      (now.getSeconds() < 10 ? "0" : "") + now.getSeconds();

    function paint() {
      var p = $("#thPrev");
      var c = $("#thColor").value;
      var img = $("#thImage").value;
      $("#thColorTxt").textContent = c;
      p.style.backgroundColor = c;

      p.style.backgroundImage = img ? "url('/asset/" + img + "')" : "none";

      // Live preview of the automatic decision for the colour currently in the form; core
      // republishes the same answer once the write lands.
      var model = L.themeAutoModel(S.status, c);
      var custom = el.querySelector("input[name='thBtnMode'][value='custom']").checked;
      var button = custom ? $("#thBtnColor").value : model.callButton;
      if (!custom) $("#thBtnColor").value = button;
      $("#thBtnTxt").textContent = button;
      var callEl = p.querySelector(".pcall");
      if (callEl) {
        callEl.style.backgroundColor = button;
        callEl.style.color = L.autoInk(button) === "dark" ? "#101418" : "#FFFFFF";
      }
      $all("[data-ink-row]", el).forEach(function (row) {
        var auto = row.querySelector("[data-ink-auto]").checked;
        var picker = row.querySelector("[data-ink-color]");
        picker.disabled = auto;
        if (auto) picker.value = model.ink === "dark" ? "#101418" : "#F5F7FA";
      });
      var inkEl = p.querySelector(".pclock");
      if (inkEl) inkEl.style.color = model.ink === "dark" ? "#101418" : "#F5F7FA";
    }
    $("#thColor").oninput = paint;
    $("#thColor").onchange = paint;
    $("#thImage").onchange = paint;
    $all("input[name='thBtnMode']", el).forEach(function (radio) { radio.onchange = paint; });
    $("#thBtnColor").oninput = function () {
      el.querySelector("input[name='thBtnMode'][value='custom']").checked = true;
      paint();
    };
    $all("[data-ink-row] [data-ink-auto]", el).forEach(function (box) { box.onchange = paint; });
    $all("[data-sw]", el).forEach(function (b) {
      b.onclick = function () { $("#thColor").value = b.getAttribute("data-sw"); paint(); };
    });
    paint();

    $("#thScope").onchange = function () { themeScope = this.value; renderTheme(); };
    $("#thSave").onclick = function () {
      var f = { bg_color: $("#thColor").value, bg_image: $("#thImage").value,
                color_on: !scope || $("#thColorOn").checked,
                image_on: !scope || $("#thImageOn").checked };
      var e = L.themeEntries(scope, f, own);
      // The colour overrides live in the same theme object, so they are folded into one write.
      var custom = el.querySelector("input[name='thBtnMode'][value='custom']").checked;
      var ink = {};
      $all("[data-ink-row]", el).forEach(function (row) {
        if (row.querySelector("[data-ink-auto]").checked) return;
        ink[row.getAttribute("data-region")] = row.querySelector("[data-ink-color]").value;
      });
      var base = (e.entries.length && e.entries[0].value) || {};
      var colors = L.themeColorEntries(scope, { call_button_auto: !custom,
                                                call_button_bg: $("#thBtnColor").value,
                                                ink_override: ink }, base);
      var entries = (colors.entries.length ? colors.entries : e.entries).concat(
        L.appearanceEntries(scope, { mode: $("#thAppearance").value,
                                     dark_from: $("#thDarkFrom") ? $("#thDarkFrom").value : "",
                                     light_from: $("#thLightFrom") ? $("#thLightFrom").value
                                                                   : "" }));
      saveAndRefresh(entries, colors.entries.length ? [] : e.dels);
    };
    if (scope) {
      $("#thReset").onclick = function () {
        confirmDelete(fmt(t("admin.theme_override_name"), { device: deviceName(scope) }), function () {
          var reset = L.themeEntries(scope, { color_on: false, image_on: false }, own);
          saveAndRefresh(reset.entries, reset.dels);
        });
      };
    }
  }




  function compressImageToLimit(file, maxBytes, cb) {
    if (typeof document.createElement("canvas").toBlob !== "function")
      return cb(null, t("admin.image_resize_unavailable"));
    var url = URL.createObjectURL(file);
    var img = new Image();
    img.onerror = function () { URL.revokeObjectURL(url); cb(null, t("admin.image_read_failed")); };
    img.onload = function () {
      URL.revokeObjectURL(url);
      var w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
      var maxDim = 1920;
      var scale = Math.min(1, maxDim / Math.max(w, h));
      function attempt(sc, q) {
        var cw = Math.max(1, Math.round(w * sc)), ch = Math.max(1, Math.round(h * sc));
        var cv = document.createElement("canvas");
        cv.width = cw; cv.height = ch;
        var ctx = cv.getContext("2d");
        ctx.fillStyle = "#000"; ctx.fillRect(0, 0, cw, ch);
        ctx.drawImage(img, 0, 0, cw, ch);
        cv.toBlob(function (blob) {
          if (!blob) return cb(null, t("admin.image_resize_failed"));
          if (blob.size <= maxBytes) {
            var base = (file.name || "image").replace(/\.[^.]+$/, "") || "image";
            var out;
            try { out = new File([blob], base + ".jpg", { type: "image/jpeg" }); }
            catch (e) { blob.name = base + ".jpg"; out = blob; }
            return cb(out, null);
          }
          if (q > 0.45) return attempt(sc, q - 0.1);
          if (sc > 0.12) return attempt(sc * 0.8, 0.8);
          cb(null, t("admin.image_resize_too_large"));
        }, "image/jpeg", q);
      }
      attempt(scale, 0.85);
    };
    img.src = url;
  }


  function uploadAsset(file, label, onProgress, cb) {
    var type = L.assetTypeOf(file.name, file.type);
    if (!type) return cb(false, t("admin.asset_format_unsupported"));
    if (file.size > L.ASSET_MAX_BYTES)
      return cb(false, fmt(t("admin.asset_too_large"), { size: L.fmtBytes(file.size) }));
    var url = "/api/assets?type=" + encodeURIComponent(type) +
              "&label=" + encodeURIComponent(label || file.name);
    if (MOCK) {
      onProgress(1);
      return api("POST", url, { size: file.size, type: type, label: label || file.name },
                 function (st, j) {
                   cb(st === 200 && j && j.ok, (j && (j.hash || j.err)) || "NG");
                 });
    }
    var fr = new FileReader();
    fr.onerror = function () { cb(false, t("admin.file_read_failed")); };
    fr.onload = function () {
      var x = new XMLHttpRequest();
      x.open("POST", url, true);
      x.setRequestHeader("X-Requested-With", "doorbell-admin");
      x.setRequestHeader("Content-Type", type);
      if (x.upload)
        x.upload.onprogress = function (e) {
          if (e.lengthComputable) onProgress(e.loaded / e.total);
        };
      x.onreadystatechange = function () {
        if (x.readyState !== 4) return;
        var j = null;
        try { j = JSON.parse(x.responseText); } catch (e2) {}
        if (x.status === 200 && j && j.ok) cb(true, j.hash);
        else cb(false, (j && j.err) || ("HTTP " + x.status));
      };
      x.send(fr.result);
    };
    fr.readAsArrayBuffer(file);
  }

  function renderAssets() {
    var el = $("#tab-assets");
    var as = cfgObj("assets"), refs = L.assetRefs(S.cfg || {});
    var ids = assetIds("");
    var st = S.status.assets || {};

    var uiCfg = cfgObj("ui");
    function selectHtml(id, value, opts) {
      var out = "<select id='" + id + "'>";
      for (var i = 0; i < opts.length; i++)
        out += "<option value='" + esc(opts[i].v) + "'" +
               (opts[i].v === value ? " selected" : "") + ">" + esc(opts[i].label) + "</option>";
      return out + "</select> <button class='btn2' data-soundpreview='" + id + "'>▶ " +
             esc(t("admin.audio_play")) + "</button>";
    }
    var h = "<div class='card'><h2>" + esc(t("admin.sound_manager")) +
      "</h2><div class='grid2'>" +
      "<div class='frow'><label class='flab'>" + esc(t("admin.launch_sound")) + "</label>" +
      selectHtml("launchSound", uiCfg.launch_sound === undefined ? "title_display" : uiCfg.launch_sound,
                 soundOptions(true)) + "</div>" +
      "<div class='frow'><label class='flab'>" + esc(t("admin.door_call_sound")) + "</label>" +
      selectHtml("callSound", uiCfg.call_sound === undefined ? "outdoor_call_alert" : uiCfg.call_sound,
                 soundOptions(true)) +
      "<label class='check'><input id='callSoundLoop' type='checkbox'" +
      (uiCfg.call_sound_loop ? " checked" : "") + "> " + esc(t("admin.call_sound_loop")) +
      "</label></div><div class='frow'><label class='flab'>" +
      esc(t("admin.button_sound")) + "</label>" +
      selectHtml("buttonSound", uiCfg.button_sound === undefined ? "button_click" : uiCfg.button_sound,
                 soundOptions(true)) + "</div>" +
      "<div class='frow'><label class='flab'>" + esc(t("admin.indoor_ringtone")) + "</label>" +
      selectHtml("ringtoneSelect", uiCfg.ringtone || "school_chime", ringtoneOptions()) + "</div>" +
      "<div class='frow'><label class='flab'>" + esc(t("admin.update_sound")) + "</label>" +
      selectHtml("updateSound", uiCfg.update_sound === undefined ? "indoor_update" : uiCfg.update_sound,
                 soundOptions(true)) + "</div></div>" +
      "<button class='btn small' id='soundSettingsSave'>" + esc(t("admin.save")) + "</button>" +
      "<div class='dim fhint'>" + esc(t("admin.sound_manager_hint")) + "</div></div>";


    h += "<div class='card'><h2>" + esc(t("admin.assets_upload")) + "</h2>" +
            "<div class='grid2'><div class='frow'><label class='flab'>" +
            esc(t("admin.asset_file_hint")) + "</label>" +
            "<input type='file' id='asFile' accept='image/jpeg,image/png,audio/mpeg,audio/wav'>" +
            "</div><div class='frow'><label class='flab'>" + esc(t("admin.asset_label_hint")) +
            "</label>" +
            "<input type='text' id='asLabel'></div></div>" +
            "<div id='asDrop' class='dropzone'>" +
            esc(t("admin.drop_here")) + "</div>" +
            "<button class='btn small' id='asUp'>" + icon("upload") + " " +
            esc(t("admin.assets_upload")) + "</button>" +
            "<div class='prog' id='asProg'><div></div></div>" +
            "<div class='dim fhint' id='asOut'></div></div>";


    h += "<div class='card'><h2>" + esc(t("admin.assets")) + "</h2>" +
         "<div class='frow'>" + esc(deviceName((S.status.node || {}).id) + " — ") +
         esc(fmt(t("admin.assets_cached"),
                 { n: st.cached !== undefined ? st.cached : "?",
                   total: st.total !== undefined ? st.total : "?" })) +
         "<div class='dim fhint'>" + esc(t("admin.asset_prefetch_hint")) + "</div>" +
         "</div>";
    if (!ids.length) {
      h += "<div class='dim'>" + esc(t("admin.assets_empty")) + "</div></div>";
    } else {
      h += "<div class='scrollx'><table><thead><tr><th>" + esc(t("admin.asset_label")) +
           "</th><th>" + esc(t("admin.asset_type")) + "</th><th>" +
           esc(t("admin.asset_size")) + "</th><th>hash</th><th>" +
           esc(t("admin.asset_used_by")) + "</th><th></th></tr></thead><tbody>";
      ids.forEach(function (hh) {
        var a = as[hh], used = refs[hh] || [];
        var usedHtml = used.length
          ? used.map(function (u) { return esc(u); }).join("<br>")
          : "<span class='dim'>" + esc(t("admin.asset_unused")) + "</span>";
        h += "<tr><td>" + esc(a.label || "—") + "</td><td class='dim'>" + esc(a.type || "") +
             "</td><td class='dim'>" + esc(L.fmtBytes(a.size)) + "</td>" +
             "<td class='mono dim'>" + esc(hh.slice(0, 12)) + "…</td>" +
             "<td class='refs'>" + usedHtml +
             "</td><td class='ops'><button class='btn2 danger' data-act='del' data-id='" +
             esc(hh) + "'>" + esc(t("admin.delete")) + "</button></td></tr>";
      });
      h += "</tbody></table></div></div>";

      h += "<div class='card'><h2>" + esc(t("admin.theme_preview")) +
           "</h2><div class='agrid'>";
      ids.forEach(function (hh) {
        var a = as[hh], isImg = (a.type || "").indexOf("image/") === 0;
        h += "<div class='acard'>";
        if (isImg)
          h += "<span class='athumb' style=\"background-image:url('/asset/" + esc(hh) +
               "')\"></span>";
        else
          h += "<audio controls preload='none' src='/asset/" + esc(hh) + "'></audio>";
        h += "<div class='lbl'>" + esc(a.label || hh.slice(0, 12)) + "</div>" +
             "<div class='dim' style='font-size:11px'>" + esc(a.type || "") + " · " +
             esc(L.fmtBytes(a.size)) + "</div></div>";
      });
      h += "</div></div>";
    }
    el.innerHTML = h;

    $all("[data-soundpreview]", el).forEach(function (b) {
      b.onclick = function () { playRingtone($("#" + b.getAttribute("data-soundpreview")).value); };
    });
    $("#soundSettingsSave").onclick = function () {
      saveAndRefresh([
        { key: "ui.launch_sound", value: $("#launchSound").value },
        { key: "ui.call_sound", value: $("#callSound").value },
        { key: "ui.call_sound_loop", value: $("#callSoundLoop").checked },
        { key: "ui.button_sound", value: $("#buttonSound").value },
        { key: "ui.ringtone", value: $("#ringtoneSelect").value },
        { key: "ui.update_sound", value: $("#updateSound").value }
      ], null);
    };

    var prog = $("#asProg"), bar = prog.firstChild, out = $("#asOut");
    function handleFile(f) {
      if (!f) { msg(t("admin.asset_choose_file")); return; }
      var isImage = /^image\//.test(f.type) || /\.(jpe?g|png)$/i.test(f.name);
      function doUpload(fileToSend, note) {
        prog.style.display = "block";
        bar.style.width = "0";
        out.className = "dim fhint";
        out.textContent = (note ? note + " · " : "") + t("admin.uploading");
        uploadAsset(fileToSend, $("#asLabel").value, function (p) {
          bar.style.width = Math.round(p * 100) + "%";
        }, function (ok, info) {
          prog.style.display = "none";
          out.className = ok ? "ok fhint" : "err fhint";
          out.textContent = ok ? (note ? note + " · " : "") +
            fmt(t("admin.asset_registered"), { info: info }) :
            fmt(t("admin.asset_failed"), { info: info });
          if (ok) { msg(t("admin.saved")); refreshAll(); }
        });
      }
      if (f.size > L.ASSET_MAX_BYTES) {
        if (!isImage) {
          out.className = "warn fhint";
          out.textContent = fmt(t("admin.audio_too_large"), { size: L.fmtBytes(f.size) });
          return;
        }

        out.className = "dim fhint";
        out.textContent = fmt(t("admin.image_resizing"), { size: L.fmtBytes(f.size) });
        compressImageToLimit(f, L.ASSET_MAX_BYTES, function (small, err) {
          if (!small) {
            out.className = "err fhint";
            out.textContent = fmt(t("admin.image_resize_error"),
              { error: err || t("info.unknown") });
            return;
          }
          doUpload(small, fmt(t("admin.image_resized"),
            { before: L.fmtBytes(f.size), after: L.fmtBytes(small.size) }));
        });
        return;
      }
      doUpload(f, null);
    }
    $("#asUp").onclick = function () {
      handleFile($("#asFile").files && $("#asFile").files[0]);
    };

    var dz = $("#asDrop");
    if (dz) {
      dz.onclick = function () { $("#asFile").click(); };
      ["dragenter", "dragover"].forEach(function (ev) {
        dz.addEventListener(ev, function (e) {
          e.preventDefault(); e.stopPropagation(); dz.classList.add("drag");
        });
      });
      ["dragleave", "dragend"].forEach(function (ev) {
        dz.addEventListener(ev, function (e) {
          e.preventDefault(); e.stopPropagation(); dz.classList.remove("drag");
        });
      });
      dz.addEventListener("drop", function (e) {
        e.preventDefault(); e.stopPropagation(); dz.classList.remove("drag");
        var files = e.dataTransfer && e.dataTransfer.files;
        if (files && files.length) handleFile(files[0]);
      });
    }
    bindActs(el, {
      del: function (hash) {
        var used = (refs[hash] || []);
        var name = assetLabel(hash);
        if (used.length &&
            !window.confirm(fmt(t("admin.asset_delete_in_use"),
              { name: name, count: used.length, locations: used.join(", ") })))
          return;


        confirmDelete(name, function () {
          api("DELETE", "/api/assets/" + hash, null, function (st, j) {
            if (st === 200 && j && j.ok) msg(t("admin.saved"));
            else msg(t("admin.save_failed"));
            refreshAll();
          });
        });
      }
    });
  }


  function refreshAll() {
    refreshConfig(function () { refreshStatus(function () { renderTab(); }); });
  }


  var TABS = {
    dash: renderDash, doors: renderDoors, devices: renderDevices, rules: renderRules,
    qr: renderQuickReplies, purposes: renderPurposes, texts: renderTexts, theme: renderTheme,
    assets: renderAssets, households: renderHouseholds, integrations: renderIntegrations,
    events: renderEvents, pair: renderPair, system: renderSystem
  };

  function renderTab() {
    var f = TABS[S.tab];
    if (f) f();
  }

  function switchTab(name) {
    var was = S.tab;
    S.tab = name;
    $all("nav button").forEach(function (b) {
      b.classList[b.getAttribute("data-tab") === name ? "add" : "remove"]("on");
    });
    for (var k in TABS) show($("#tab-" + k), k === name);
    if (was === "pair" && name !== "pair") pairTabLeave();
    if (name === "pair") { refreshStatus(pairTabEnter); return; }
    if (name === "events") refreshEvents(renderTab);
    else refreshConfig(function () { refreshStatus(renderTab); });
  }

  $all("nav button").forEach(function (b) {
    b.onclick = function () { switchTab(b.getAttribute("data-tab")); };
  });


  function poll() {
    refreshStatus(function () {
      if (S.tab === "dash") renderDash();
      if (S.tab === "devices") renderDevices();
    });
    if (S.tab === "events") refreshEvents(renderEvents);
  }

  /* ---- i18n ---- */
  api("GET", "/locale/" + LANG + ".json", null, function (st, j) {
    if (st === 200 && j) {
      I18N = j;
      document.title = t("admin.page_title");
      $all("[data-i18n]").forEach(function (el) {
        el.textContent = t(el.getAttribute("data-i18n"));
      });
      $all("[data-i18n-ph]").forEach(function (el) {
        el.placeholder = t(el.getAttribute("data-i18n-ph"));
      });
      $all("[data-i18n-title]").forEach(function (el) {
        el.title = t(el.getAttribute("data-i18n-title"));
      });
    }
  });


  (function () {
    var sel = $("#langSel");
    if (!sel) return;
    sel.value = LANG;
    sel.onchange = function () {
      lsSet("db_admin_lang", sel.value);
      var q = "?lang=" + encodeURIComponent(sel.value) + (MOCK ? "&mock=1" : "");
      window.location.search = q;
    };
  })();


  (function () {
    var sel = $("#uiSel");
    if (!sel) return;
    sel.value = document.documentElement.getAttribute("data-ui") || "modern";
    sel.onchange = function () {
      var v = sel.value;
      if (v === "modern") document.documentElement.removeAttribute("data-ui");
      else document.documentElement.setAttribute("data-ui", v);
      lsSet("db_admin_ui", v);
    };
  })();

  /* ---- login ---- */
  $("#loginBtn").onclick = function () {
    api("POST", "/api/login", { password: $("#pw").value }, function (st) {
      if (st === 200) { show($("#login"), false); show($("#app"), true); boot(); }
      else $("#loginErr").textContent = t("admin.pin_wrong");
    });
  };
  $("#pw").addEventListener("keydown", function (e) {
    if (e.key === "Enter") $("#loginBtn").click();
  });

  function boot() {
    var info = $("#nodeInfo");
    refreshConfig(function () {
      refreshStatus(function () {
        var n = S.status.node || {};
        info.textContent = (n.name || n.id || "") + " · v" + (n.version || "?");
        switchTab("dash");
      });
    });
    setInterval(poll, 5000);
  }


  api("GET", "/api/status", null, function (st) {
    if (st === 200 || MOCK) { show($("#app"), true); boot(); }
    else show($("#login"), true);
  });
})();
