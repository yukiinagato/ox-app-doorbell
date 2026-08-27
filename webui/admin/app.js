/* 管理画面 SPA (vanilla JS / ES5)。
   構成:
     1. AdminLogic — フォーム値 → フラット設定 key 群への分解 (DOM 非依存・node で単体テスト可)
     2. UI — タブ描画・編集フォーム・API 呼び出し
   設定書込の流儀: フォーム → AdminLogic.*Entries() → POST /api/config を 1 key ずつ順次。
   削除は POST /api/config/delete (LwwMap tombstone)。?mock=1 で XHR せず内蔵データ描画。 */

/* ================================================================ 1. 純粋ロジック */
var AdminLogic = (function () {
  "use strict";

  function isObj(v) { return v !== null && typeof v === "object" && !(v instanceof Array); }
  function num(v, def) { var n = parseFloat(v); return isNaN(n) ? def : n; }

  // "111, 222　333" → ["111","222","333"] (カンマ/読点/空白区切り)
  function parseList(s) {
    if (!s) return [];
    var parts = String(s).split(/[,、，\s]+/), out = [];
    for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i]);
    return out;
  }

  // chat ID は数値化できるものは数値で (Telegram API は数値 chat_id)
  function parseChatIds(s) {
    var l = parseList(s), out = [];
    for (var i = 0; i < l.length; i++)
      out.push(/^-?\d+$/.test(l[i]) ? parseInt(l[i], 10) : l[i]);
    return out;
  }

  // 空欄は落とした label オブジェクト
  function labelObj(ja, en, zh) {
    var o = {};
    if (ja) o.ja = ja;
    if (en) o.en = en;
    if (zh) o.zh = zh;
    return o;
  }

  // 表示用 label 解決 (lang → ja → 最初の値 → fallback)
  function labelOf(entity, lang, fallback) {
    var l = entity && entity.label;
    if (isObj(l)) {
      if (l[lang]) return l[lang];
      if (l.ja) return l.ja;
      for (var k in l) if (l[k]) return l[k];
    }
    return fallback || "";
  }

  // ---- 実体コレクション (1 実体 = 1 key の whole-value 書込) ----
  function buildingEntries(id, f) {
    return [{ key: "buildings." + id, value: { label: labelObj(f.ja, f.en, f.zh) } }];
  }

  function doorEntries(id, f) {
    var v = { label: labelObj(f.ja, f.en, f.zh) };
    if (f.building) v.building = f.building;
    return [{ key: "doors." + id, value: v }];
  }

  function quickReplyEntries(id, f) {
    return [{ key: "quick_replies." + id,
              value: { label: labelObj(f.ja, f.en, f.zh), speak: !!f.speak,
                       order: num(f.order, 1) } }];
  }

  // 並べ替え: 表示順の id 配列 + 現行値 → order 1..n を振り直した entries
  function reorderEntries(sortedIds, qrs) {
    var out = [];
    for (var i = 0; i < sortedIds.length; i++) {
      var id = sortedIds[i], cur = (qrs && qrs[id]) || {};
      out.push({ key: "quick_replies." + id,
                 value: { label: cur.label || {}, speak: cur.speak !== false, order: i + 1 } });
    }
    return out;
  }

  function householdEntries(id, f) {
    return [{ key: "households." + id,
              value: { label: labelObj(f.ja, f.en, f.zh),
                       telegram_chat_ids: parseChatIds(f.chat_ids),
                       sip_extensions: parseList(f.sip_ext) } }];
  }

  // ---- デバイス: 基底 key (devices.<id>) はノード自身が起動時に書く —
  //      管理編集は深い field-level key で行う (materialize は深いパス優先で合成する) ----
  function deviceEntries(id, f) {
    var base = "devices." + id, e = [];
    e.push({ key: base + ".name", value: String(f.name || "") });
    e.push({ key: base + ".role", value: f.role || "door_station" });
    e.push({ key: base + ".door", value: f.door || "" });
    e.push({ key: base + ".local.ui_lang", value: f.ui_lang || "ja" });
    e.push({ key: base + ".local.camera",
             value: { device_hint: f.cam_hint || "", mjpeg_fps: num(f.cam_fps, 8),
                      mjpeg_quality: num(f.cam_quality, 60),
                      resolution: f.cam_resolution || "640x480" } });
    e.push({ key: base + ".local.motion",
             value: { enabled: !!f.motion_enabled, sensitivity: num(f.motion_sensitivity, 40),
                      min_interval_s: num(f.motion_interval, 30) } });
    // caps_override は UI 側でパース済みオブジェクト (null = 書かない)
    if (isObj(f.caps_override)) e.push({ key: base + ".caps_override", value: f.caps_override });
    return e;
  }

  // ---- 呼出ルール (whole-value) ----
  // f = { enabled, whenType, doors:[], devices:[]|"all", always, windows:[{days,from,to}],
  //       actions:[{type, target_extension?, households?, with_snapshot?, devices?, sound?}] }
  function ruleEntries(id, f) {
    var when = { type: f.whenType || "button" };
    if (when.type === "device_offline") {
      when.devices = (f.devices === "all" || !f.devices || !f.devices.length) ? "all" : f.devices;
    } else if (f.doors && f.doors.length) {
      when.doors = f.doors;
    }
    var v = { enabled: !!f.enabled, when: when };
    if (f.always) {
      v.schedule = { always: true };
    } else {
      var ws = [];
      for (var i = 0; i < (f.windows || []).length; i++) {
        var w = f.windows[i];
        if (!w.from || !w.to) continue;
        ws.push({ days: (w.days && w.days.length) ? w.days :
                        ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
                  from: w.from, to: w.to });
      }
      v.schedule = { windows: ws };
    }
    v.actions = [];
    for (var j = 0; j < (f.actions || []).length; j++) {
      var a = f.actions[j], o = { type: a.type };
      if (a.type === "sip_call") o.target_extension = a.target_extension || "600";
      else if (a.type === "telegram") {
        o.households = a.households || [];
        o.with_snapshot = !!a.with_snapshot;
      } else if (a.type === "chime") {
        if (a.devices && a.devices.length) o.devices = a.devices;  // 省略 = 室内機全部
        o.sound = a.sound || "ding1";
      }
      v.actions.push(o);
    }
    return [{ key: "trigger_rules." + id, value: v }];
  }

  // ---- 統合 (field-level key — 兄弟 key を潰さない) ----
  function mqttEntries(f) {
    var e = [{ key: "integrations.mqtt.host", value: String(f.host || "") },
             { key: "integrations.mqtt.port", value: num(f.port, 1883) },
             { key: "integrations.mqtt.user", value: String(f.user || "") }];
    if (f.pass) e.push({ key: "integrations.mqtt.pass", value: String(f.pass) });
    return e;
  }

  function telegramEntries(f) {
    var e = [{ key: "integrations.telegram.poll_updates", value: !!f.poll_updates }];
    if (f.bot_token) e.push({ key: "integrations.telegram.bot_token", value: String(f.bot_token) });
    return e;
  }

  function sipEntries(f) {
    return [{ key: "sip.server", value: String(f.server || "") },
            { key: "sip.port", value: num(f.port, 5060) },
            { key: "sip.transport", value: f.transport || "udp" }];
  }

  // アカウントは whole-value — pass 空欄は既存 pass を温存する
  function sipAccountEntries(nodeId, user, pass, existing) {
    var v = { user: String(user || "") };
    var p = pass || (existing && existing.pass) || "";
    if (p) v.pass = p;
    return [{ key: "sip.accounts." + nodeId, value: v }];
  }

  function tzEntries(min) {
    return [{ key: "integrations.tz_offset_min", value: num(min, 540) }];
  }

  function quietEntries(f) {
    var ws = [];
    for (var i = 0; i < (f.windows || []).length; i++) {
      var w = f.windows[i];
      if (w.from && w.to) ws.push({ from: w.from, to: w.to });
    }
    return [{ key: "quiet_hours.default",
              value: { windows: ws, suppress: f.suppress || [],
                       never_suppress: f.never_suppress || [] } }];
  }

  // ---- インポート用フラット化 (書込粒度 = 各編集画面と同じ) ----
  // 粒度が編集画面とズレると「深いパス優先」の合成で古い枝が残るため、必ずここを経由する。
  function flattenConfig(cfg) {
    var out = [];
    var ENTITY2 = { buildings: 1, doors: 1, households: 1, quick_replies: 1,
                    trigger_rules: 1, quiet_hours: 1 };
    function push(key, v) { if (v !== undefined) out.push({ key: key, value: v }); }
    for (var k in cfg) {
      var v = cfg[k];
      if (!isObj(v)) { push(k, v); continue; }              // scalar / 配列は葉
      if (ENTITY2[k]) {                                     // 実体: depth2 whole-value
        for (var id in v) push(k + "." + id, v[id]);
      } else if (k === "devices") {                         // field-level (+ local を 1 段展開)
        for (var did in v) {
          var d = v[did], b = "devices." + did;
          for (var f in d) {
            if (f === "local" && isObj(d.local)) {
              for (var g in d.local) push(b + ".local." + g, d.local[g]);
            } else push(b + "." + f, d[f]);
          }
        }
      } else if (k === "sip") {
        for (var sf in v) {
          if (sf === "accounts" && isObj(v.accounts)) {
            for (var aid in v.accounts) push("sip.accounts." + aid, v.accounts[aid]);
          } else push("sip." + sf, v[sf]);                  // dtmf_actions は whole-value
        }
      } else if (k === "integrations") {
        for (var inf in v) {
          if (isObj(v[inf])) {
            for (var ig in v[inf]) push("integrations." + inf + "." + ig, v[inf][ig]);
          } else push("integrations." + inf, v[inf]);
        }
      } else {                                              // panel / cluster / reply / 未知
        for (var of in v) push(k + "." + of, v[of]);
      }
    }
    return out;
  }

  // ---- mock 用: ドットパス書込/削除 (materialize の近似 — 深いパスで枝を作る) ----
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

  // 既存に無い連番 id ("r" → r1, r2, …)
  function newId(prefix, obj) {
    var i = 1;
    while (obj && obj[prefix + i] !== undefined) i++;
    return prefix + i;
  }

  // config key セグメントとして安全な id に整形
  function safeId(s) {
    return String(s || "").replace(/[^A-Za-z0-9_]/g, "_");
  }

  return {
    parseList: parseList, parseChatIds: parseChatIds, labelObj: labelObj, labelOf: labelOf,
    buildingEntries: buildingEntries, doorEntries: doorEntries,
    quickReplyEntries: quickReplyEntries, reorderEntries: reorderEntries,
    householdEntries: householdEntries, deviceEntries: deviceEntries, ruleEntries: ruleEntries,
    mqttEntries: mqttEntries, telegramEntries: telegramEntries, sipEntries: sipEntries,
    sipAccountEntries: sipAccountEntries, tzEntries: tzEntries, quietEntries: quietEntries,
    flattenConfig: flattenConfig, applyKey: applyKey, deleteKey: deleteKey,
    newId: newId, safeId: safeId
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
  var LANG = qs("lang") || "ja";

  var I18N = {};
  function t(k, def) { return I18N[k] || def || k; }
  function fmt(s, vars) {
    return s.replace(/\{(\w+)\}/g, function (m, n) { return vars[n] !== undefined ? vars[n] : m; });
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
  // HTML/属性値エスケープ (属性は ' 引用で埋め込むため引用符も潰す)
  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  /* ---------------- mock データ (?mock=1 — 描画は実データと同一関数を通す) ---------------- */
  var MOCK_ID1 = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
  var MOCK_ID2 = "0f1e2d3c4b5a69788766554433221100";
  var MOCK_CFG = {
    schema_version: 1,
    buildings: { b_main: { label: { ja: "母屋", en: "Main House" } },
                 b_annex: { label: { ja: "離れ" } } },
    doors: { d_front: { building: "b_main", label: { ja: "正面玄関" } },
             d_back: { building: "b_main", label: { ja: "勝手口" } } },
    devices: (function () {
      var d = {};
      d[MOCK_ID1] = { name: "front-panel", role: "door_station", door: "d_front",
                      local: { ui_lang: "ja",
                               camera: { device_hint: "", mjpeg_fps: 8, mjpeg_quality: 60,
                                         resolution: "640x480" },
                               motion: { enabled: true, sensitivity: 40, min_interval_s: 30 } } };
      d[MOCK_ID2] = { name: "living", role: "indoor_panel" };
      return d;
    })(),
    households: { h_ox: { label: { ja: "オーナー" }, telegram_chat_ids: [123456789],
                          sip_extensions: ["201"] } },
    quick_replies: {
      qr_away: { label: { ja: "ただいま留守にしています" }, speak: true, order: 1 },
      qr_no: { label: { ja: "結構です" }, speak: true, order: 2 },
      qr_wait: { label: { ja: "少々お待ちください" }, speak: true, order: 3 } },
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
            actions: [{ type: "telegram", households: ["h_ox"] }] } },
    quiet_hours: { "default": { windows: [{ from: "23:00", to: "07:00" }],
                                suppress: ["chime"],
                                never_suppress: ["sip_call", "telegram", "ha_event"] } },
    integrations: { mqtt: { host: "10.0.1.5", port: 1883, user: "doorbell" },
                    telegram: { poll_updates: true }, tz_offset_min: 540 },
    sip: { server: "10.0.1.5", port: 5060, transport: "udp",
           accounts: (function () {
             var a = {}; a[MOCK_ID1] = { user: "door-front" }; return a;
           })() },
    panel: { tokens: ["mocktoken0123456789abcdef0123456"] },
    reply: { display_ttl_s: 30 }
  };
  var MOCK_STATUS = {
    node: { id: MOCK_ID1, name: "front-panel", role: "door_station", version: "0.1.0" },
    sip: { registered: false, state: "idle", call: "idle" },
    leaders: { telegram: MOCK_ID1, mqtt_bridge: MOCK_ID1 },
    bridge: { mqtt: "connected", telegram: "active" },
    peers: [
      { id: MOCK_ID1, name: "front-panel", role: "door_station", status: "alive", self: true,
        sw: "0.1.0", addrs: ["10.0.1.10:47172"], door: "d_front", door_label: "正面玄関" },
      { id: MOCK_ID2, name: "living", role: "indoor_panel", status: "dead", sw: "0.1.0",
        addrs: [] }]
  };
  var MOCK_EVENTS = [
    { type: "press", door: "d_front", device: MOCK_ID1, wall_ms: Date.now() - 60000, payload: "{}" },
    { type: "reply", door: "d_front", device: MOCK_ID2, wall_ms: Date.now() - 50000,
      payload: "{\"text\":\"すぐ行きます\"}" },
    { type: "motion", door: "d_front", device: MOCK_ID1, wall_ms: Date.now() - 30000,
      payload: "{\"changed_pct\":12}" },
    { type: "offline", door: "", device: MOCK_ID2, wall_ms: Date.now() - 10000, payload: "{}" }];

  function mockApi(method, path, body, cb) {
    var p = path.split("?")[0];
    function ok(j) { setTimeout(function () { cb(200, j); }, 0); }
    if (method === "GET") {
      if (p === "/api/status") return ok(MOCK_STATUS);
      if (p === "/api/config") return ok(MOCK_CFG);
      if (p === "/api/events") return ok({ events: MOCK_EVENTS });
      if (p === "/api/logs") return ok({ logs: ["I mock: これは mock ログです"] });
      return setTimeout(function () { cb(404, null); }, 0);
    }
    if (p === "/api/login") return ok({ ok: true });
    if (p === "/api/config") { L.applyKey(MOCK_CFG, body.key, body.value); return ok({ ok: true }); }
    if (p === "/api/config/delete") { L.deleteKey(MOCK_CFG, body.key); return ok({ ok: true }); }
    if (p === "/api/config/import") {
      var n = 0, es = (body && body.entries) || [];
      for (var i = 0; i < es.length; i++)
        if (es[i].key) { L.applyKey(MOCK_CFG, es[i].key, JSON.stringify(es[i].value)); n++; }
      return ok({ ok: true, n: n });
    }
    if (p === "/api/join-token") return ok({ ok: true, pin: "482913", expires_s: 600 });
    if (p === "/api/test/telegram") return ok({ ok: true });
    if (p === "/api/panel-token/rotate") {
      var tok = "mock" + Math.random().toString(16).slice(2, 10);
      MOCK_CFG.panel = { tokens: [tok] };
      return ok({ ok: true, token: tok });
    }
    return setTimeout(function () { cb(404, null); }, 0);
  }

  /* ---------------- API ---------------- */
  function api(method, path, body, cb) {
    if (MOCK) return mockApi(method, path, body, cb);
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

  // entries ([{key,value}]) を 1 件ずつ順次 POST → dels (key 配列) を順次削除 → cb(ok)
  function postEntries(entries, dels, cb) {
    var i = 0, j = 0;
    function next() {
      if (entries && i < entries.length) {
        var e = entries[i++];
        api("POST", "/api/config", { key: e.key, value: JSON.stringify(e.value) },
            function (st) { if (st !== 200) return cb(false); next(); });
        return;
      }
      if (dels && j < dels.length) {
        api("POST", "/api/config/delete", { key: dels[j++] },
            function (st) { if (st !== 200) return cb(false); next(); });
        return;
      }
      cb(true);
    }
    next();
  }

  // 保存 → 再取得 → 該当タブ再描画 の定型
  function saveAndRefresh(entries, dels) {
    postEntries(entries, dels, function (ok) {
      msg(ok ? t("admin.saved", "保存しました") : t("admin.save_failed", "保存に失敗しました"));
      refreshConfig(function () { renderTab(); });
    });
  }

  /* ---------------- 状態 ---------------- */
  var S = { cfg: {}, status: {}, events: [], tab: "dash" };

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

  /* ---------------- 汎用フォーム (モーダル) ---------------- */
  // fields: [{id,label,type,value,options,ph,hint}]
  //   type: text|password|number|time|select|check|multicheck|textarea|static
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
      "<button class='btn' id='mSave'>" + esc(t("admin.save", "保存")) + "</button>" +
      "<button class='btn ghost' id='mCancel'>" + esc(t("admin.cancel", "キャンセル")) +
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

  function confirmDelete(name, doIt) {
    if (window.confirm(fmt(t("admin.confirm_delete", "{name} を削除しますか?"), { name: name })))
      doIt();
  }

  /* ---------------- 選択肢ヘルパ ---------------- */
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
  var DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  var DAY_JA = { mon: "月", tue: "火", wed: "水", thu: "木", fri: "金", sat: "土", sun: "日" };
  function dayLabel(d) { return t("day." + d, DAY_JA[d] || d); }

  function fmtTime(ms) {
    if (!ms) return "-";
    var d = new Date(ms);
    function p(n) { return n < 10 ? "0" + n : n; }
    return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) + " " +
           p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }

  /* ================================================================ タブ描画 */

  /* ---------------- 1. ダッシュボード ---------------- */
  function renderDash() {
    var j = S.status;
    var rows = "";
    var peers = j.peers || [];
    for (var i = 0; i < peers.length; i++) {
      var p = peers[i];
      var stCls = p.status === "alive" ? "ok" : (p.status === "suspect" ? "warn" : "err");
      var duties = [];
      if (j.leaders) for (var d in j.leaders) if (j.leaders[d] === p.id) duties.push(d);
      rows += "<tr><td>" + esc(p.name || p.id.slice(0, 8)) +
              (p.self ? " <span class='tag'>self</span>" : "") + "</td><td>" +
              esc(p.role || "") + "</td><td class='" + stCls + "'>" + esc(p.status) +
              "</td><td>" + esc(duties.join(",")) + "</td><td>" + esc(p.sw || "") +
              "</td><td class='dim'>" + esc((p.addrs || []).join(" ")) + "</td></tr>";
    }
    $("#peersTbl tbody").innerHTML = rows;
    var br = j.bridge || {};
    $("#bridgeInfo").textContent =
      "MQTT: " + (br.mqtt || "-") + " / Telegram: " + (br.telegram || "-") +
      (j.sip ? " / SIP: " + j.sip.state : "");
    // ライブ映像 (src は据え置き — 差し替えるとストリームが切れる)
    var grid = $("#liveGrid"), want = {};
    for (var li = 0; li < peers.length; li++) {
      var pp = peers[li];
      if (pp.stream && pp.status === "alive") want[pp.id] = pp;
    }
    var cards = $all("[data-node]", grid);
    for (var ci = 0; ci < cards.length; ci++) {
      var id = cards[ci].getAttribute("data-node");
      if (!want[id]) grid.removeChild(cards[ci]); else delete want[id];
    }
    for (var nid in want) {
      var p2 = want[nid], card = document.createElement("div");
      card.className = "card";
      card.setAttribute("data-node", nid);
      card.innerHTML = "<div class='dim' style='margin-bottom:6px'>" +
        esc(p2.door_label || p2.name || nid.slice(0, 8)) +
        "</div><img style='width:100%; border-radius:6px; background:#000; min-height:160px' alt='live'>";
      card.querySelector("img").src = p2.stream;
      grid.appendChild(card);
    }
  }

  /* ---------------- 2. ドア/建物 ---------------- */
  function editBuilding(id) {
    var isNew = !id;
    var cur = isNew ? {} : cfgObj("buildings")[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "bid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("b", cfgObj("buildings")) : id },
      { id: "ja", label: t("admin.label_ja", "ラベル (日本語)"), value: lb.ja },
      { id: "en", label: t("admin.label_en", "ラベル (英語)"), value: lb.en },
      { id: "zh", label: t("admin.label_zh", "ラベル (中国語)"), value: lb.zh }];
    openForm(t("admin.buildings", "建物"), fields, function (v) {
      var bid = isNew ? L.safeId(v.bid) : id;
      if (!bid) return "ID?";
      saveAndRefresh(L.buildingEntries(bid, v), null);
    });
  }

  function editDoor(id) {
    var isNew = !id;
    var cur = isNew ? {} : cfgObj("doors")[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "did", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("d", cfgObj("doors")) : id },
      { id: "ja", label: t("admin.label_ja", "ラベル (日本語)"), value: lb.ja },
      { id: "en", label: t("admin.label_en", "ラベル (英語)"), value: lb.en },
      { id: "zh", label: t("admin.label_zh", "ラベル (中国語)"), value: lb.zh },
      { id: "building", label: t("admin.building_assign", "所属建物"), type: "select",
        value: cur.building || "", options: buildingOptions() }];
    openForm(t("admin.door_list", "ドア"), fields, function (v) {
      var did = isNew ? L.safeId(v.did) : id;
      if (!did) return "ID?";
      saveAndRefresh(L.doorEntries(did, v), null);
    });
  }

  function renderDoors() {
    var el = $("#tab-doors");
    var bs = cfgObj("buildings"), ds = cfgObj("doors");
    var h = "<div class='card'><div class='chead'><h2>" + esc(t("admin.buildings", "建物")) +
            "</h2><button class='btn small' data-act='addB'>+ " +
            esc(t("admin.add_building", "建物を追加")) + "</button></div><table><thead><tr>" +
            "<th>ID</th><th>ja</th><th>en</th><th>zh</th><th></th></tr></thead><tbody>";
    for (var b in bs) {
      var lb = bs[b].label || {};
      h += "<tr><td class='dim'>" + esc(b) + "</td><td>" + esc(lb.ja || "") + "</td><td>" +
           esc(lb.en || "") + "</td><td>" + esc(lb.zh || "") + "</td><td class='ops'>" +
           "<button class='btn2' data-act='editB' data-id='" + esc(b) + "'>" +
           esc(t("admin.edit", "編集")) + "</button> <button class='btn2 danger' data-act='delB' data-id='" +
           esc(b) + "'>" + esc(t("admin.delete", "削除")) + "</button></td></tr>";
    }
    h += "</tbody></table></div>";
    h += "<div class='card'><div class='chead'><h2>" + esc(t("admin.door_list", "ドア")) +
         "</h2><button class='btn small' data-act='addD'>+ " +
         esc(t("admin.add_door", "ドアを追加")) + "</button></div><table><thead><tr>" +
         "<th>ID</th><th>" + esc(t("admin.label_ja", "ラベル")) + "</th><th>" +
         esc(t("admin.building_assign", "所属建物")) + "</th><th></th></tr></thead><tbody>";
    for (var d in ds) {
      h += "<tr><td class='dim'>" + esc(d) + "</td><td>" + esc(doorLabel(d)) + "</td><td>" +
           esc(ds[d].building ? L.labelOf(bs[ds[d].building], LANG, ds[d].building) : "—") +
           "</td><td class='ops'><button class='btn2' data-act='editD' data-id='" + esc(d) +
           "'>" + esc(t("admin.edit", "編集")) +
           "</button> <button class='btn2 danger' data-act='delD' data-id='" + esc(d) + "'>" +
           esc(t("admin.delete", "削除")) + "</button></td></tr>";
    }
    h += "</tbody></table></div>";
    el.innerHTML = h;
    bindActs(el, {
      addB: function () { editBuilding(null); },
      editB: function (id) { editBuilding(id); },
      delB: function (id) {
        confirmDelete(id, function () { saveAndRefresh(null, ["buildings." + id]); });
      },
      addD: function () { editDoor(null); },
      editD: function (id) { editDoor(id); },
      delD: function (id) {
        confirmDelete(doorLabel(id), function () { saveAndRefresh(null, ["doors." + id]); });
      }
    });
  }

  // data-act ボタンの一括バインド
  function bindActs(root, handlers) {
    $all("[data-act]", root).forEach(function (b) {
      var act = b.getAttribute("data-act");
      if (handlers[act])
        b.onclick = function () { handlers[act](b.getAttribute("data-id")); };
    });
  }

  /* ---------------- 3. デバイス ---------------- */
  function editDevice(id) {
    var d = cfgObj("devices")[id] || {};
    var lo = d.local || {}, cam = lo.camera || {}, mo = lo.motion || {};
    var fields = [
      { id: "nid", label: "ID", type: "static", value: id },
      { id: "name", label: t("admin.dev_name", "名前"), value: d.name },
      { id: "role", label: t("admin.dev_role", "役割"), type: "select",
        value: d.role || "door_station",
        options: [{ v: "door_station", label: t("admin.role_door", "門口機") },
                  { v: "indoor_panel", label: t("admin.role_indoor", "室内機") }] },
      { id: "door", label: t("admin.door_assign", "担当ドア"), type: "select",
        value: d.door || "", options: doorOptions(true) },
      { id: "ui_lang", label: t("admin.ui_lang", "表示言語"), type: "select",
        value: lo.ui_lang || "ja",
        options: [{ v: "ja", label: "日本語" }, { v: "en", label: "English" },
                  { v: "zh", label: "中文" }] },
      { id: "cam_fps", label: t("admin.cam_fps", "フレームレート"), type: "number",
        value: cam.mjpeg_fps !== undefined ? cam.mjpeg_fps : 8 },
      { id: "cam_quality", label: t("admin.cam_quality", "JPEG 品質"), type: "number",
        value: cam.mjpeg_quality !== undefined ? cam.mjpeg_quality : 60 },
      { id: "cam_resolution", label: t("admin.cam_resolution", "解像度"),
        value: cam.resolution || "640x480", ph: "640x480" },
      { id: "cam_hint", label: t("admin.cam_hint", "カメラ指定"), value: cam.device_hint },
      { id: "motion_enabled", label: t("admin.motion", "動体検知"), type: "check",
        value: mo.enabled !== false },
      { id: "motion_sensitivity", label: t("admin.motion_sensitivity", "感度"), type: "number",
        value: mo.sensitivity !== undefined ? mo.sensitivity : 40 },
      { id: "motion_interval", label: t("admin.motion_interval", "最小間隔 (秒)"),
        type: "number", value: mo.min_interval_s !== undefined ? mo.min_interval_s : 30 },
      { id: "caps_override", label: t("admin.caps_override", "能力上書き (JSON)"),
        type: "textarea", value: d.caps_override ? JSON.stringify(d.caps_override) : "" }];
    openForm(t("admin.devices", "デバイス"), fields, function (v) {
      var caps = null;
      var ct = (v.caps_override || "").replace(/^\s+|\s+$/g, "");
      if (ct) {
        try { caps = JSON.parse(ct); } catch (e) { return "caps_override: JSON?"; }
        if (caps === null || typeof caps !== "object") return "caps_override: JSON?";
      }
      v.caps_override = caps;
      saveAndRefresh(L.deviceEntries(id, v), null);
    });
  }

  function renderDevices() {
    var el = $("#tab-devices");
    var ds = cfgObj("devices");
    var ids = [];
    for (var id in ds) ids.push(id);
    // peers にだけいる (config 未着) の端末も一応載せる
    (S.status.peers || []).forEach(function (p) {
      if (ids.indexOf(p.id) < 0) ids.push(p.id);
    });
    var h = "<div class='card'><table><thead><tr><th>" + esc(t("admin.dev_name", "名前")) +
            "</th><th>ID</th><th>" + esc(t("admin.dev_role", "役割")) + "</th><th>" +
            esc(t("admin.door_assign", "担当ドア")) + "</th><th>" +
            esc(t("admin.online", "オンライン")) + "</th><th></th></tr></thead><tbody>";
    ids.forEach(function (nid) {
      var d = ds[nid] || {};
      var p = peerOf(nid);
      var alive = p && p.status === "alive";
      var stCls = alive ? "ok" : (p && p.status === "suspect" ? "warn" : "err");
      var stTxt = p ? p.status : t("admin.offline", "オフライン");
      h += "<tr class='" + (alive ? "" : "offline") + "'><td>" + esc(d.name || "") +
           (p && p.self ? " <span class='tag'>self</span>" : "") + "</td><td class='dim'>" +
           esc(nid.slice(0, 8)) + "</td><td>" +
           esc(d.role === "indoor_panel" ? t("admin.role_indoor", "室内機") :
               (d.role ? t("admin.role_door", "門口機") : "")) + "</td><td>" +
           esc(d.door ? doorLabel(d.door) : "—") + "</td><td class='" + stCls + "'>" +
           esc(stTxt) + "</td><td class='ops'><button class='btn2' data-act='edit' data-id='" +
           esc(nid) + "'>" + esc(t("admin.edit", "編集")) + "</button></td></tr>";
    });
    h += "</tbody></table></div>";
    el.innerHTML = h;
    bindActs(el, { edit: function (id) { editDevice(id); } });
  }

  /* ---------------- 4. 呼出ルール (ビジュアルエディタ) ---------------- */
  function whenLabel(type) {
    if (type === "motion") return t("admin.when_motion", "動体検知");
    if (type === "device_offline") return t("admin.when_offline", "デバイス離線");
    return t("admin.when_button", "呼出ボタン");
  }
  function actionLabel(a) {
    if (a.type === "sip_call")
      return t("admin.act_sip", "SIP 発呼") + " → " + (a.target_extension || "600");
    if (a.type === "telegram") {
      var hs = (a.households || []).map(householdLabel).join(",");
      return t("admin.act_telegram", "Telegram") + " → " + (hs || "?") +
             (a.with_snapshot ? " 📷" : "");
    }
    if (a.type === "chime") return t("admin.act_chime", "チャイム") + " (" + (a.sound || "ding1") + ")";
    return t("admin.act_ha", "HA イベント");
  }
  function scheduleLabel(sc) {
    if (!sc || sc.always) return t("admin.always", "常時");
    var ws = sc.windows || [];
    var parts = [];
    for (var i = 0; i < ws.length; i++) {
      var w = ws[i];
      var days = (w.days || DAYS).map(dayLabel).join("");
      parts.push(days + " " + (w.from || "") + "-" + (w.to || ""));
    }
    return parts.join(" / ") || t("admin.always", "常時");
  }

  // アクション行の HTML (種類 select + 種類別パラメータ)
  function actionRowHtml(idx, a) {
    var typeOpts = [["sip_call", t("admin.act_sip", "SIP 発呼")],
                    ["telegram", t("admin.act_telegram", "Telegram 通知")],
                    ["ha_event", t("admin.act_ha", "HA イベント")],
                    ["chime", t("admin.act_chime", "チャイム")]];
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
      params = "<span class='mcwrap'>";
      for (var k = 0; k < hs.length; k++)
        params += "<label class='mc'><input type='checkbox' data-ra='households' data-idx='" +
                  idx + "' value='" + esc(hs[k].v) + "'" +
                  ((a.households || []).indexOf(hs[k].v) >= 0 ? " checked" : "") + "> " +
                  esc(hs[k].label) + "</label>";
      params += "</span><label class='mc'><input type='checkbox' data-ra='with_snapshot' data-idx='" +
                idx + "'" + (a.with_snapshot ? " checked" : "") + "> " +
                esc(t("admin.with_snapshot", "写真付き")) + "</label>";
    } else if (a.type === "chime") {
      var devs = deviceOptions();
      params = "<span class='mcwrap'>";
      for (var m = 0; m < devs.length; m++)
        params += "<label class='mc'><input type='checkbox' data-ra='devices' data-idx='" + idx +
                  "' value='" + esc(devs[m].v) + "'" +
                  ((a.devices instanceof Array ? a.devices : []).indexOf(devs[m].v) >= 0 ?
                   " checked" : "") + "> " + esc(devs[m].label) + "</label>";
      params += "</span> <input type='text' data-ra='sound' data-idx='" + idx + "' value='" +
                esc(a.sound || "ding1") + "' style='width:90px' placeholder='ding1'>";
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

  function editRule(id) {
    var isNew = !id;
    var rid = isNew ? L.newId("r", cfgObj("trigger_rules")) : id;
    var cur = isNew ?
      { enabled: true, when: { type: "button" }, schedule: { always: true },
        actions: [{ type: "chime" }] } :
      JSON.parse(JSON.stringify(cfgObj("trigger_rules")[id] || {}));
    var st = {
      enabled: cur.enabled !== false,
      whenType: (cur.when && cur.when.type) || "button",
      doors: (cur.when && cur.when.doors) || [],
      devices: (cur.when && cur.when.devices) || "all",
      always: !cur.schedule || !!cur.schedule.always,
      windows: (cur.schedule && cur.schedule.windows) ?
               JSON.parse(JSON.stringify(cur.schedule.windows)) : [],
      actions: cur.actions ? JSON.parse(JSON.stringify(cur.actions)) : []
    };

    function bodyHtml() {
      var h = "<div class='frow frow-check'><label><input type='checkbox' id='rEnabled'" +
              (st.enabled ? " checked" : "") + "> " + esc(t("admin.enabled", "有効")) +
              "</label></div>";
      // 条件
      h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_when", "条件")) +
           "</label><select id='rWhen'>";
      [["button", t("admin.when_button", "呼出ボタン")], ["motion", t("admin.when_motion", "動体検知")],
       ["device_offline", t("admin.when_offline", "デバイス離線")]].forEach(function (o) {
        h += "<option value='" + o[0] + "'" + (st.whenType === o[0] ? " selected" : "") + ">" +
             esc(o[1]) + "</option>";
      });
      h += "</select></div>";
      if (st.whenType === "device_offline") {
        h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_devices", "対象デバイス")) +
             "</label><div class='mcwrap'><label class='mc'><input type='checkbox' id='rDevAll'" +
             (st.devices === "all" ? " checked" : "") + "> " + esc(t("admin.all", "すべて")) +
             "</label>";
        deviceOptions().forEach(function (o) {
          h += "<label class='mc'><input type='checkbox' data-rdev='1' value='" + esc(o.v) + "'" +
               (st.devices instanceof Array && st.devices.indexOf(o.v) >= 0 ? " checked" : "") +
               "> " + esc(o.label) + "</label>";
        });
        h += "</div></div>";
      } else {
        h += "<div class='frow'><label class='flab'>" + esc(t("admin.rule_doors", "対象ドア")) +
             "</label><div class='mcwrap'>";
        doorOptions(false).forEach(function (o) {
          h += "<label class='mc'><input type='checkbox' data-rdoor='1' value='" + esc(o.v) + "'" +
               (st.doors.indexOf(o.v) >= 0 ? " checked" : "") + "> " + esc(o.label) + "</label>";
        });
        h += "</div><div class='dim fhint'>" + esc(t("admin.all", "すべて")) +
             " = チェックなし</div></div>";
      }
      // スケジュール
      h += "<div class='frow'><label class='flab'>" + esc(t("admin.schedule", "スケジュール")) +
           "</label><label class='mc'><input type='radio' name='rSched' value='always'" +
           (st.always ? " checked" : "") + "> " + esc(t("admin.always", "常時")) +
           "</label><label class='mc'><input type='radio' name='rSched' value='windows'" +
           (!st.always ? " checked" : "") + "> " + esc(t("admin.windows", "時間帯")) + "</label></div>";
      if (!st.always) {
        h += "<div id='rWins'>";
        for (var i = 0; i < st.windows.length; i++) h += windowRowHtml(i, st.windows[i]);
        h += "</div><button class='btn2' id='rAddWin'>+ " +
             esc(t("admin.add_window", "時間帯を追加")) + "</button>";
      }
      // アクション
      h += "<div class='frow'><label class='flab'>" + esc(t("admin.actions", "アクション")) +
           "</label></div><div id='rActs'>";
      for (var j = 0; j < st.actions.length; j++) h += actionRowHtml(j, st.actions[j]);
      h += "</div><button class='btn2' id='rAddAct'>+ " +
           esc(t("admin.add_action", "アクションを追加")) + "</button>";
      return h;
    }

    // モーダル本体の再描画 (種類変更などの度に collect → state 更新 → 再描画)
    function collectState(m) {
      st.enabled = $("#rEnabled") ? $("#rEnabled").checked : st.enabled;
      var wSel = $("#rWhen");
      if (wSel) st.whenType = wSel.value;
      if (st.whenType === "device_offline") {
        var all = $("#rDevAll") && $("#rDevAll").checked;
        var devs = [];
        $all("[data-rdev]", m).forEach(function (el) { if (el.checked) devs.push(el.value); });
        st.devices = all || !devs.length ? "all" : devs;
      } else {
        var doors = [];
        $all("[data-rdoor]", m).forEach(function (el) { if (el.checked) doors.push(el.value); });
        st.doors = doors;
      }
      var sc = m.querySelector("input[name='rSched']:checked");
      if (sc) st.always = sc.value === "always";
      // windows
      var wins = [];
      $all("[data-wrow]", m).forEach(function (row) {
        var idx = row.getAttribute("data-wrow");
        var days = [];
        $all("[data-rw='day'][data-idx='" + idx + "']", row).forEach(function (el) {
          if (el.checked) days.push(el.value);
        });
        var from = row.querySelector("[data-rw='from']"), to = row.querySelector("[data-rw='to']");
        wins.push({ days: days, from: from ? from.value : "", to: to ? to.value : "" });
      });
      if ($all("[data-wrow]", m).length) st.windows = wins;
      // actions
      var acts = [];
      $all("[data-arow]", m).forEach(function (row) {
        var idx = row.getAttribute("data-arow");
        var typeEl = row.querySelector("[data-ra='type']");
        var a = { type: typeEl ? typeEl.value : "chime" };
        if (a.type === "sip_call") {
          var te = row.querySelector("[data-ra='target_extension']");
          a.target_extension = te ? te.value : "600";
        } else if (a.type === "telegram") {
          a.households = [];
          $all("[data-ra='households']", row).forEach(function (el) {
            if (el.checked) a.households.push(el.value);
          });
          var ws2 = row.querySelector("[data-ra='with_snapshot']");
          a.with_snapshot = ws2 ? ws2.checked : false;
        } else if (a.type === "chime") {
          a.devices = [];
          $all("[data-ra='devices']", row).forEach(function (el) {
            if (el.checked) a.devices.push(el.value);
          });
          var se = row.querySelector("[data-ra='sound']");
          a.sound = se ? se.value : "ding1";
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
        st.actions.push({ type: "chime" });
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
      $all("[data-rw='del']", m).forEach(function (b) {
        b.onclick = function () {
          collectState(m);
          st.windows.splice(parseInt(b.getAttribute("data-idx"), 10), 1);
          rerender(m);
        };
      });
    }

    var m = openModal(t("admin.rules", "呼出ルール") + " — " + rid, bodyHtml(), function (mm) {
      collectState(mm);
      saveAndRefresh(L.ruleEntries(rid, st), null);
    });
    bindDynamic(m);
  }

  function renderRules() {
    var el = $("#tab-rules");
    var rs = cfgObj("trigger_rules");
    var h = "<div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_rule", "ルールを追加")) + "</button></div>";
    for (var id in rs) {
      var r = rs[id];
      var when = r.when || {};
      var target = "";
      if (when.type === "device_offline") {
        target = when.devices === "all" || !when.devices ? t("admin.all", "すべて") :
                 (when.devices || []).map(deviceName).join(", ");
      } else {
        target = (when.doors && when.doors.length) ?
                 when.doors.map(doorLabel).join(", ") : t("admin.all", "すべて");
      }
      var acts = (r.actions || []).map(actionLabel);
      h += "<div class='card rule" + (r.enabled === false ? " offline" : "") + "'>" +
           "<div class='chead'><h2>" + esc(whenLabel(when.type)) + ": " + esc(target) +
           " <span class='dim'>(" + esc(id) + ")</span></h2>" +
           "<label class='mc'><input type='checkbox' data-act='toggle' data-id='" + esc(id) +
           "'" + (r.enabled !== false ? " checked" : "") + "> " +
           esc(t("admin.enabled", "有効")) + "</label></div>" +
           "<div class='dim' style='margin:4px 0'>" + esc(t("admin.schedule", "スケジュール")) +
           ": " + esc(scheduleLabel(r.schedule)) + "</div><div>";
      for (var i = 0; i < acts.length; i++) h += "<span class='chip'>" + esc(acts[i]) + "</span>";
      h += "</div><div class='ops' style='margin-top:8px'><button class='btn2' data-act='edit' data-id='" +
           esc(id) + "'>" + esc(t("admin.edit", "編集")) +
           "</button> <button class='btn2 danger' data-act='del' data-id='" + esc(id) + "'>" +
           esc(t("admin.delete", "削除")) + "</button></div></div>";
    }
    el.innerHTML = h;
    bindActs(el, {
      add: function () { editRule(null); },
      edit: function (id) { editRule(id); },
      del: function (id) {
        confirmDelete(id, function () { saveAndRefresh(null, ["trigger_rules." + id]); });
      }
    });
    // enabled トグル: whole-value を維持したまま enabled のみ差し替え
    $all("[data-act='toggle']", el).forEach(function (cb) {
      cb.onchange = function () {
        var id = cb.getAttribute("data-id");
        var r = JSON.parse(JSON.stringify(cfgObj("trigger_rules")[id] || {}));
        r.enabled = cb.checked;
        saveAndRefresh([{ key: "trigger_rules." + id, value: r }], null);
      };
    });
  }

  /* ---------------- 5. クイック返信 ---------------- */
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
      { id: "ja", label: t("admin.label_ja", "文言 (日本語)"), value: lb.ja },
      { id: "en", label: t("admin.label_en", "文言 (英語)"), value: lb.en },
      { id: "zh", label: t("admin.label_zh", "文言 (中国語)"), value: lb.zh },
      { id: "speak", label: t("admin.qr_speak", "読み上げ"), type: "check",
        value: cur.speak !== false }];
    openForm(t("admin.quick_replies", "クイック返信"), fields, function (v) {
      var qid = isNew ? L.safeId(v.qid) : id;
      if (!qid) return "ID?";
      v.order = isNew ? sortedQrIds().length + 1 : (cur.order || 1);
      saveAndRefresh(L.quickReplyEntries(qid, v), null);
    });
  }

  function renderQuickReplies() {
    var el = $("#tab-qr");
    var qrs = cfgObj("quick_replies");
    var ids = sortedQrIds();
    var h = "<div class='card'><div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_reply", "返信を追加")) + "</button></div><table><thead><tr><th>#</th><th>" +
            esc(t("admin.label_ja", "文言")) + "</th><th>" + esc(t("admin.qr_speak", "読み上げ")) +
            "</th><th></th></tr></thead><tbody>";
    ids.forEach(function (id, i) {
      var q = qrs[id];
      h += "<tr><td class='dim'>" + (i + 1) + "</td><td>" + esc(L.labelOf(q, LANG, id)) +
           "</td><td>" + (q.speak !== false ? "🔊" : "—") + "</td><td class='ops'>" +
           "<button class='btn2' data-act='up' data-id='" + esc(id) + "'>↑</button>" +
           "<button class='btn2' data-act='down' data-id='" + esc(id) + "'>↓</button> " +
           "<button class='btn2' data-act='edit' data-id='" + esc(id) + "'>" +
           esc(t("admin.edit", "編集")) + "</button> <button class='btn2 danger' data-act='del' data-id='" +
           esc(id) + "'>" + esc(t("admin.delete", "削除")) + "</button></td></tr>";
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
      down: function (id) { move(id, 1); }
    });
  }

  /* ---------------- 6. 通知先 (households) ---------------- */
  function editHousehold(id) {
    var isNew = !id;
    var hs = cfgObj("households");
    var cur = isNew ? {} : hs[id] || {};
    var lb = cur.label || {};
    var fields = [
      { id: "hid", label: "ID", type: isNew ? "text" : "static",
        value: isNew ? L.newId("h", hs) : id },
      { id: "ja", label: t("admin.label_ja", "ラベル (日本語)"), value: lb.ja },
      { id: "en", label: t("admin.label_en", "ラベル (英語)"), value: lb.en },
      { id: "zh", label: t("admin.label_zh", "ラベル (中国語)"), value: lb.zh },
      { id: "chat_ids", label: t("admin.tg_chat_ids", "Telegram chat ID"),
        value: (cur.telegram_chat_ids || []).join(", "), ph: "123456789, -100200300" },
      { id: "sip_ext", label: t("admin.sip_extensions", "SIP 内線"),
        value: (cur.sip_extensions || []).join(", "), ph: "201, 202" }];
    openForm(t("admin.households", "通知先"), fields, function (v) {
      var hid = isNew ? L.safeId(v.hid) : id;
      if (!hid) return "ID?";
      saveAndRefresh(L.householdEntries(hid, v), null);
    });
  }

  function renderHouseholds() {
    var el = $("#tab-households");
    var hs = cfgObj("households");
    var h = "<div class='card'><div class='chead'><h2></h2><button class='btn small' data-act='add'>+ " +
            esc(t("admin.add_household", "通知先を追加")) + "</button></div><table><thead><tr><th>" +
            esc(t("admin.households", "通知先")) + "</th><th>Telegram</th><th>SIP</th><th></th></tr>" +
            "</thead><tbody>";
    for (var id in hs) {
      var hh = hs[id];
      h += "<tr><td>" + esc(householdLabel(id)) + " <span class='dim'>(" + esc(id) +
           ")</span></td><td class='dim'>" + esc((hh.telegram_chat_ids || []).join(", ")) +
           "</td><td class='dim'>" + esc((hh.sip_extensions || []).join(", ")) +
           "</td><td class='ops'><button class='btn2' data-act='edit' data-id='" + esc(id) + "'>" +
           esc(t("admin.edit", "編集")) + "</button> <button class='btn2 danger' data-act='del' data-id='" +
           esc(id) + "'>" + esc(t("admin.delete", "削除")) + "</button></td></tr>";
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

  /* ---------------- 7. 統合 ---------------- */
  function renderIntegrations() {
    var el = $("#tab-integrations");
    var integ = cfgObj("integrations");
    var mqtt = integ.mqtt || {}, tg = integ.telegram || {};
    var sip = cfgObj("sip");
    var qh = (cfgObj("quiet_hours") || {})["default"] || {};
    var h = "";

    // MQTT
    h += "<div class='card'><h2>MQTT (Home Assistant)</h2>" +
         "<div class='grid2'>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.host", "ホスト")) +
         "</label><input id='mqHost' value='" + esc(mqtt.host || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.port", "ポート")) +
         "</label><input id='mqPort' type='number' value='" + esc(mqtt.port || 1883) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.user", "ユーザー")) +
         "</label><input id='mqUser' value='" + esc(mqtt.user || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.pass", "パスワード")) +
         "</label><input id='mqPass' type='password' placeholder='(未変更)'></div></div>" +
         "<button class='btn small' id='mqSave'>" + esc(t("admin.save", "保存")) + "</button></div>";

    // Telegram
    h += "<div class='card'><h2>Telegram</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.bot_token", "Bot token")) +
         "</label><input id='tgToken' type='password' placeholder='" +
         (tg.bot_token ? "********（設定済み）" : "123456:ABC-…") + "'></div>" +
         "<div class='frow frow-check'><label><input type='checkbox' id='tgPoll'" +
         (tg.poll_updates ? " checked" : "") + "> " + esc(t("admin.poll_updates", "返信ボタンを受信")) +
         "</label></div>" +
         "<button class='btn small' id='tgSave'>" + esc(t("admin.save", "保存")) + "</button> " +
         "<span style='display:inline-block; width:16px'></span>" +
         "<input id='tgTestChat' placeholder='chat_id (空 = 全通知先)' style='width:200px'> " +
         "<button class='btn2' id='tgTest'>" + esc(t("admin.test_send", "テスト送信")) +
         "</button></div>";

    // SIP
    h += "<div class='card'><h2>SIP</h2><div class='grid2'>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.host", "ホスト")) +
         "</label><input id='sipServer' value='" + esc(sip.server || "") + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.port", "ポート")) +
         "</label><input id='sipPort' type='number' value='" + esc(sip.port || 5060) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.transport", "トランスポート")) +
         "</label><select id='sipTransport'>";
    ["udp", "tcp", "tls"].forEach(function (tr) {
      h += "<option value='" + tr + "'" + ((sip.transport || "udp") === tr ? " selected" : "") +
           ">" + tr + "</option>";
    });
    h += "</select></div></div>" +
         "<h3 class='dim' style='margin:10px 0 4px'>" +
         esc(t("admin.sip_accounts", "SIP アカウント (デバイス毎)")) + "</h3>" +
         "<table><thead><tr><th>" + esc(t("admin.devices", "デバイス")) + "</th><th>" +
         esc(t("admin.user", "ユーザー")) + "</th><th>" + esc(t("admin.pass", "パスワード")) +
         "</th></tr></thead><tbody>";
    var accounts = sip.accounts || {};
    var devIds = [];
    for (var did in cfgObj("devices")) devIds.push(did);
    for (var aid in accounts) if (devIds.indexOf(aid) < 0) devIds.push(aid);
    devIds.forEach(function (nid) {
      var a = accounts[nid] || {};
      h += "<tr><td>" + esc(deviceName(nid)) + " <span class='dim'>(" + esc(nid.slice(0, 8)) +
           ")</span></td><td><input data-sipacct-user='" + esc(nid) + "' value='" +
           esc(a.user || "") + "'></td><td><input type='password' data-sipacct-pass='" +
           esc(nid) + "' placeholder='" + (a.pass ? "(未変更)" : "") + "'></td></tr>";
    });
    h += "</tbody></table><button class='btn small' id='sipSave' style='margin-top:8px'>" +
         esc(t("admin.save", "保存")) + "</button></div>";

    // 全般 + 静音時間帯
    h += "<div class='card'><h2>" + esc(t("admin.quiet_hours", "静音時間帯")) + " / TZ</h2>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.tz_offset", "タイムゾーン (分)")) +
         "</label><input id='tzMin' type='number' value='" +
         esc(integ.tz_offset_min !== undefined ? integ.tz_offset_min : 540) + "'></div>" +
         "<div class='frow'><label class='flab'>" + esc(t("admin.windows", "時間帯")) +
         "</label><div id='qhWins'>";
    (qh.windows || []).forEach(function (w, i) {
      h += "<div class='arow' data-qhrow='" + i + "'><input type='time' data-qh='from' value='" +
           esc(w.from || "") + "'> – <input type='time' data-qh='to' value='" + esc(w.to || "") +
           "'> <button class='btn2 danger' data-qh='del'>×</button></div>";
    });
    h += "</div><button class='btn2' id='qhAdd'>+ " + esc(t("admin.add_window", "時間帯を追加")) +
         "</button></div>";
    var ACT_TYPES = [["sip_call", t("admin.act_sip", "SIP 発呼")],
                     ["telegram", t("admin.act_telegram", "Telegram")],
                     ["ha_event", t("admin.act_ha", "HA イベント")],
                     ["chime", t("admin.act_chime", "チャイム")]];
    h += "<div class='frow'><label class='flab'>" + esc(t("admin.suppress", "抑制する")) +
         "</label><div class='mcwrap'>";
    ACT_TYPES.forEach(function (a) {
      h += "<label class='mc'><input type='checkbox' data-qhsup='" + a[0] + "'" +
           ((qh.suppress || []).indexOf(a[0]) >= 0 ? " checked" : "") + "> " + esc(a[1]) +
           "</label>";
    });
    h += "</div></div><div class='frow'><label class='flab'>" +
         esc(t("admin.never_suppress", "常に許可")) + "</label><div class='mcwrap'>";
    ACT_TYPES.forEach(function (a) {
      h += "<label class='mc'><input type='checkbox' data-qhnev='" + a[0] + "'" +
           ((qh.never_suppress || []).indexOf(a[0]) >= 0 ? " checked" : "") + "> " + esc(a[1]) +
           "</label>";
    });
    h += "</div></div><button class='btn small' id='qhSave'>" + esc(t("admin.save", "保存")) +
         "</button></div>";

    el.innerHTML = h;

    $("#mqSave").onclick = function () {
      saveAndRefresh(L.mqttEntries({ host: $("#mqHost").value, port: $("#mqPort").value,
                                     user: $("#mqUser").value, pass: $("#mqPass").value }), null);
    };
    $("#tgSave").onclick = function () {
      saveAndRefresh(L.telegramEntries({ bot_token: $("#tgToken").value,
                                         poll_updates: $("#tgPoll").checked }), null);
    };
    $("#tgTest").onclick = function () {
      api("POST", "/api/test/telegram", { chat_id: $("#tgTestChat").value }, function (st, j) {
        if (st === 200 && j && j.ok) { msg(t("admin.test_sent", "テスト通知を送信しました")); return; }
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
      devIds.forEach(function (nid) {
        var u = el.querySelector("[data-sipacct-user='" + nid + "']");
        var p = el.querySelector("[data-sipacct-pass='" + nid + "']");
        var existing = accounts[nid] || {};
        if (!u) return;
        if (!u.value && !(p && p.value) && !existing.user) return;  // 未使用行は書かない
        entries = entries.concat(
          L.sipAccountEntries(nid, u.value, p ? p.value : "", existing));
      });
      saveAndRefresh(entries, null);
    };
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
        wins.push({ from: f ? f.value : "", to: to ? to.value : "" });
      });
      var sup = [], nev = [];
      $all("[data-qhsup]", el).forEach(function (c) {
        if (c.checked) sup.push(c.getAttribute("data-qhsup"));
      });
      $all("[data-qhnev]", el).forEach(function (c) {
        if (c.checked) nev.push(c.getAttribute("data-qhnev"));
      });
      var entries = L.tzEntries($("#tzMin").value).concat(
        L.quietEntries({ windows: wins, suppress: sup, never_suppress: nev }));
      saveAndRefresh(entries, null);
    };
  }

  /* ---------------- 8. イベント履歴 ---------------- */
  var evFilter = "";
  function renderEvents() {
    var el = $("#tab-events");
    var types = ["", "press", "motion", "reply", "answered", "missed", "offline", "online",
                 "config_changed", "dtmf_action"];
    var h = "<div class='card'><div class='chead'><h2></h2><select id='evFilter'>";
    types.forEach(function (ty) {
      h += "<option value='" + ty + "'" + (evFilter === ty ? " selected" : "") + ">" +
           (ty || esc(t("admin.filter_type", "種別で絞り込み"))) + "</option>";
    });
    h += "</select></div><table><thead><tr><th>時刻</th><th>種別</th><th>ドア/機器</th>" +
         "<th>詳細</th></tr></thead><tbody>";
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

  /* ---------------- 9. システム ---------------- */
  function renderSystem() {
    var el = $("#tab-system");
    var toks = (cfgObj("panel") || {}).tokens || [];
    var tok = toks[0] || "";
    var base = window.location.protocol + "//" + window.location.host;
    var h = "";
    // エクスポート / インポート
    h += "<div class='card'><h2>" + esc(t("admin.export", "エクスポート")) + " / " +
         esc(t("admin.import", "インポート")) + "</h2>" +
         "<button class='btn small' id='sysExport'>" + esc(t("admin.export", "エクスポート")) +
         "</button><div class='dim fhint' style='margin:10px 0 4px'>" +
         esc(t("admin.import_hint", "エクスポートした JSON を貼り付けてください")) + "</div>" +
         "<textarea id='sysImport' style='min-height:110px' placeholder='{ \"doors\": … }'></textarea>" +
         "<button class='btn small' id='sysImportBtn' style='margin-top:8px'>" +
         esc(t("admin.import", "インポート")) + "</button></div>";
    // パネル token
    h += "<div class='card'><h2>" + esc(t("admin.panel_token", "パネル token")) + "</h2>" +
         "<div class='mono' id='panelTok'>" + esc(tok || "—") + "</div>";
    if (tok)
      h += "<div class='dim fhint'><a href='" + esc(base + "/panel/door?k=" + tok) +
           "' target='_blank'>/panel/door?k=…</a> · <a href='" +
           esc(base + "/panel/monitor?k=" + tok) + "' target='_blank'>/panel/monitor?k=…</a></div>";
    h += "<button class='btn2' id='tokRotate' style='margin-top:8px'>" +
         esc(t("admin.rotate", "ローテート")) + "</button></div>";
    // デバイス追加 (join token)
    h += "<div class='card'><h2>" + esc(t("admin.add_device", "デバイスを追加")) + "</h2>" +
         "<button class='btn small' id='joinBtn'>" + esc(t("admin.join_pin", "追加 PIN")) +
         "</button><div id='joinOut'></div></div>";
    // 生設定 + 個別書込 (旧 UI 踏襲)
    h += "<div class='card'><h2>" + esc(t("admin.raw_config", "設定 (生 JSON)")) + "</h2>" +
         "<textarea id='cfgView' readonly></textarea>" +
         "<div style='display:flex; gap:8px; margin-top:10px'>" +
         "<input id='cfgKey' type='text' placeholder='doors.d_front.label' style='flex:1'>" +
         "<input id='cfgVal' type='text' placeholder='{\"ja\":\"正面玄関\"}' style='flex:2'>" +
         "<button class='btn' id='cfgSet'>書込</button></div></div>";
    // ログ
    h += "<div class='card'><h2>" + esc(t("admin.logs", "ログ")) + "</h2>" +
         "<button class='btn2' id='logBtn'>↻</button><pre id='logOut' class='mono' " +
         "style='white-space:pre-wrap; font-size:11px; margin-top:8px'></pre></div>";
    el.innerHTML = h;

    $("#cfgView").value = JSON.stringify(S.cfg, null, 2);
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
      if (parsed instanceof Array) entries = parsed;                    // entries 配列そのもの
      else if (parsed && parsed.entries instanceof Array) entries = parsed.entries;
      else entries = L.flattenConfig(parsed);                           // 全文 → フラット化
      api("POST", "/api/config/import", { entries: entries }, function (st, j) {
        if (st === 200 && j && j.ok) {
          msg(fmt(t("admin.imported", "{n} 件を書き込みました"), { n: j.n }));
          refreshConfig(function () { renderTab(); });
        } else msg(t("admin.save_failed", "保存に失敗しました"));
      });
    };
    $("#tokRotate").onclick = function () {
      if (!window.confirm(t("admin.rotate_confirm", "旧 token は即時無効になります。よろしいですか?")))
        return;
      api("POST", "/api/panel-token/rotate", {}, function (st, j) {
        if (st === 200 && j && j.ok) {
          msg(t("admin.saved", "保存しました"));
          refreshConfig(function () { renderTab(); });
        } else msg(t("admin.save_failed", "保存に失敗しました"));
      });
    };
    $("#joinBtn").onclick = function () {
      api("POST", "/api/join-token", {}, function (st, j) {
        if (st !== 200 || !j || !j.ok) { msg(t("admin.save_failed", "失敗")); return; }
        var self = peerOf((S.status.node || {}).id) || {};
        var addr = (self.addrs || [])[0] || window.location.hostname + ":47172";
        $("#joinOut").innerHTML =
          "<div class='pin'>" + esc(j.pin) + "</div><div class='mono' style='text-align:center'>" +
          esc(addr) + "</div><div class='dim fhint' style='text-align:center'>" +
          esc(t("admin.join_hint", "新しい端末でこの PIN と接続先を入力してください (10 分有効)")) +
          "</div>";
      });
    };
    $("#cfgSet").onclick = function () {
      var key = $("#cfgKey").value.replace(/^\s+|\s+$/g, "");
      var val = $("#cfgVal").value.replace(/^\s+|\s+$/g, "");
      if (!key || !val) return;
      api("POST", "/api/config", { key: key, value: val }, function (st) {
        msg(st === 200 ? "OK" : "NG (" + st + ")");
        refreshConfig(function () { renderTab(); });
      });
    };
    $("#logBtn").onclick = function () {
      api("GET", "/api/logs", null, function (st, j) {
        if (st === 200 && j) $("#logOut").textContent = (j.logs || []).join("\n");
      });
    };
    $("#logBtn").onclick();
  }

  /* ================================================================ タブ切替・起動 */
  var TABS = {
    dash: renderDash, doors: renderDoors, devices: renderDevices, rules: renderRules,
    qr: renderQuickReplies, households: renderHouseholds, integrations: renderIntegrations,
    events: renderEvents, system: renderSystem
  };

  function renderTab() {
    var f = TABS[S.tab];
    if (f) f();
  }

  function switchTab(name) {
    S.tab = name;
    $all("nav button").forEach(function (b) {
      b.classList[b.getAttribute("data-tab") === name ? "add" : "remove"]("on");
    });
    for (var k in TABS) show($("#tab-" + k), k === name);
    if (name === "events") refreshEvents(renderTab);
    else refreshConfig(function () { refreshStatus(renderTab); });
  }

  $all("nav button").forEach(function (b) {
    b.onclick = function () { switchTab(b.getAttribute("data-tab")); };
  });

  // 周期 refresh: 状態駆動タブ (dash/devices/events) だけ再描画 — フォーム編集を消さない
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
      $all("[data-i18n]").forEach(function (el) {
        el.textContent = t(el.getAttribute("data-i18n"), el.textContent);
      });
      $all("[data-i18n-ph]").forEach(function (el) {
        el.placeholder = t(el.getAttribute("data-i18n-ph"), el.placeholder);
      });
    }
  });

  /* ---- login ---- */
  $("#loginBtn").onclick = function () {
    api("POST", "/api/login", { password: $("#pw").value }, function (st) {
      if (st === 200) { show($("#login"), false); show($("#app"), true); boot(); }
      else $("#loginErr").textContent = t("admin.pin_wrong", "パスワードが違います");
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

  // 起動: 認証状態を status で確認
  api("GET", "/api/status", null, function (st) {
    if (st === 200 || MOCK) { show($("#app"), true); boot(); }
    else show($("#login"), true);
  });
})();
