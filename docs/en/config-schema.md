> Japanese original: ../ja/config-schema.md (canonical)

# Configuration Schema (canonical reference)

Configuration is a flat key→JSON LWW-Map CRDT. Keys are dot paths. Below is the full picture after
materialization. `*_ref: "secret:…"` refers to the secrets namespace (write-only in the admin UI,
never displayed; stored in the platform secure store).

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // safety net on a single L2 (the beacon is primary)
  },

  "buildings": {
    "b_main":  { "label": { "ja": "母屋", "en": "Main House" } },
    "b_annex": { "label": { "ja": "離れ", "en": "Annex" } }
  },

  "doors": {
    "d_front": { "building": "b_main",  "label": { "ja": "正面玄関" } },
    "d_back":  { "building": "b_main",  "label": { "ja": "勝手口" } },
    "d_annex": { "building": "b_annex", "label": { "ja": "離れ玄関" } }
  },

  "devices": {
    "<node_id>": {
      "name": "front-panel",
      "role": "door_station",                   // door_station | indoor_panel
      "door": "d_front",                        // null for indoor_panel
      "platform": "windows",
      "caps_override": { "mains_power": true }, // admin override of measured capabilities
      "local": {                                // per-device settings (also replicated — editable remotely)
        "ui_lang": "ja", "volume": 80, "screen_brightness": 70,
        "screensaver_after_s": 120,
        "video": { "playback": "low_latency" }, // low_latency (default) / hls / mjpeg
        "camera": { "device_hint": "", "rotation": 0, "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto" = probe for HW h264, fall back to mjpeg / "mjpeg" / "h264"
                    // with h264, /stream.mp4 (fMP4, platform HW encoder) becomes available and
                    // resolution/fps are set separately via the h264_* keys (Phase 6)
                    "codec": "auto", "h264_resolution": "640x360", "h264_fps": 30,
                    "h264_bitrate_kbps": 700 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "motion": { "enabled": true, "sensitivity": 40, "min_interval_s": 30 },
        "aec": { "mode": "auto", "tail_ms": 0 },  // written by on-device calibration
        // Marker for a TV monitor (resident Android TV app). Operational notes:
        //   - role=indoor_panel + tv:true. On chime, the visitor monitor screen overlays the
        //     foreground, showing the door station's live video (MJPEG) + direct listen-in to the
        //     door mic (direct INVITE to sip.direct_port with
        //     X-Doorbell-Mode: monitor — no Asterisk, no dialplan changes).
        //   - Quick replies via D-pad (quick_replies shown in `order` order).
        //   - Setup: the "Android TV" section of deploy/provision/android/provision.en.md.
        "tv": false
      }
    }
  },

  "households": {
    "h_ox": { "label": { "ja": "オーナー" },
              "telegram_chat_ids": [123456789],
              "sip_extensions": ["201"] }
  },

  "sip": {
    "server": "10.0.1.5", "port": 5060, "transport": "udp",
    // accounts.<node_id>.user = that device's extension number. Both door stations (8001..) and
    // indoor panels (201..) are listed here — the peer's video during a call is resolved via the
    // reverse lookup user(extension)→node_id→peers[].stream.
    // answer_mode: "auto" (door-station default — answer immediately) | "ring" (indoor-panel
    // default — manual answer via the incoming-call UI)
    "accounts": { "<node_id>": { "user": "door-front", "pass_ref": "secret:sip.<node_id>",
                                 "answer_mode": "auto" } },
    // Listening UDP port for direct calls (bypassing Asterisk). Each station's sipctl listens on a
    // fixed port; indoor panels/TVs INVITE directly to "sip:<host>:47190" (the self-healing policy
    // that keeps intercom/listen-in alive during PBX outages).
    // X-Doorbell-Mode: monitor = one-way listen-in / answer = two-way.
    // Direct calls work even if server or the device's own accounts are unset.
    "direct_port": 47190,
    // DTMF feature codes (peer's keypress during a call → action; executed via mesh/MQTT)
    "dtmf_actions": { "*1": { "type": "ha_command", "command": "unlock", "door": "self" },
                      "*0": { "type": "hangup" } }
  },

  "ui": {
    "languages": ["ja", "en", "zh"],            // languages offered on the door station's visitor language switcher
    "ringtone": "ding1",                          // ding1 / ding2 / classic / asset:<sha256>
    "visitor_lang_revert_s": 60                 // revert to the primary language (ja) after this many idle seconds
  },
  // Runtime overrides for wording (take precedence over the built-in resx/strings.xml). Edit from
  // the admin UI "Wording" tab / the indoor panel's simple editor → immediate CRDT push
  // (millisecond-level on the LAN) → door stations repaint. Placeholders like {name} are validated
  // for consistency on the editing side. Keys are identical to i18n/strings.yaml.
  "i18n_overrides": {
    "ja": { "idle.touch_to_call": "タッチして呼び出してください" },
    "en": {}
  },

  // Unified asset ledger: blob catalog of background images + custom audio (wav/mp3 ≤3MB). The
  // actual bytes live in each node's assets/ directory. **On config changes, each node proactively
  // prefetches the hashes it references** (mesh FETCH_BLOB — from any node that holds it) →
  // playback/display always comes from a local file = millisecond-level. The admin UI shows each
  // node's cache coverage.
  "assets": {
    "<sha256>": { "size": 123456, "type": "image/jpeg | audio/mpeg | audio/wav",
                  "origin": "<node_id>", "label": "桜.jpg" }
  },

  "display": {                                  // display & burn-in protection (fleet default; override via devices.<id>.local.display)
    // theme: the door station background ("push" from the indoor panel/admin UI = just write this
    // setting. Synced instantly via CRDT)
    "theme": { "bg_color": "#101418", "bg_image": null },   // bg_image: an assets sha256 or null
    "brightness": 70,                           // 0-100 (remote adjustment — slider in the admin UI)
    "night": { "enabled": true, "from": "22:00", "to": "06:00",
               "brightness": 15, "red_tint": true },   // night mode (evaluated with the corrected clock)
    "screensaver_after_s": 120,                 // screensaver after idle (clock drift, low brightness)
    "pixel_shift_s": 300                        // periodically shift idle-screen elements by a few px (burn-in protection)
  },

  "emergency": {                                // indoor emergency call for help (SOS)
    "button_on_roles": ["indoor_panel"],        // roles that show the SOS button
    "hold_to_trigger_s": 3,                     // long-press duration in seconds (prevents accidental triggering)
    "alarm_sound": "siren1", "alarm_volume": 100,
    "sip_call": { "enabled": false, "target_extension": "" },  // optional: call a user-defined destination via Asterisk
    "cancel_requires_pin": true                 // cancelling requires the kiosk PIN
  },
  // Default emergency behavior (built-in, independent of rules): alarm UI + siren on all nodes,
  // Telegram 🚨 to all households, MQTT doorbell/emergency (retain) — hook up lights/sirens/calls
  // freely on the HA side. **No automatic calls to police or fire services** (recipients are family
  // and user-defined phone destinations only — a human makes the judgment call).

  "visit_purposes": {                           // visitor purpose buttons (user-editable; default seed below)
    // On the door station, one tap on a purpose button = a ring with that purpose attached
    // (a courier is done in a single action). The big "Call" button is a generic ring with no
    // purpose. Labels follow the visitor's language.
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1 },
    "p_delivery": { "label": { "ja": "宅配便",     "en": "Delivery", "zh": "快递" }, "icon": "📦", "order": 2 },
    "p_mail":     { "label": { "ja": "郵便",       "en": "Mail",     "zh": "邮件" }, "icon": "✉️", "order": 3 },
    "p_sales":    { "label": { "ja": "営業・集金", "en": "Sales",    "zh": "推销/收费" }, "icon": "💼", "order": 4 },
    "p_work":     { "label": { "ja": "検針・工事", "en": "Utility",  "zh": "检修/施工" }, "icon": "🔧", "order": 5 },
    "p_other":    { "label": { "ja": "その他",     "en": "Other",    "zh": "其他" }, "icon": "❓", "order": 6 }
  },
  // The press event payload carries "purpose": "<id>". Displayed on: indoor/TV ring badges,
  // Telegram (icon + purpose name), the HA event payload, panel state, and the admin UI.
  // Rule integration: trigger_rules.when.purposes: ["p_delivery"] branches per purpose, and the
  // new action { "type": "auto_reply", "reply_id": "qr_okihai" } makes the door station
  // automatically show a quick reply + TTS (e.g. delivery → "Please leave the package" + no
  // phone call).

  // Each quick_replies entry may optionally carry "audio": {"ja": "<sha256>", "en": "<sha256>"} —
  // played as custom audio matching the visitor's language (priority: cached audio → system TTS →
  // notification tone). auto_reply actions inherit the same audio. A chime's sound supports custom
  // audio via the "asset:<sha256>" form, as does emergency.alarm_sound.
  "quick_replies": {                            // quick replies (user-editable)
    "qr_away":    { "label": { "ja": "ただいま留守にしています", "en": "We are away right now",
                               "zh": "现在不在家" }, "speak": true, "order": 1 },
    "qr_no":      { "label": { "ja": "結構です", "en": "Not interested",
                               "zh": "不需要，谢谢" }, "speak": true, "order": 2 },
    "qr_wrong":   { "label": { "ja": "お間違いのようです", "en": "Wrong address",
                               "zh": "您可能找错地方了" }, "speak": true, "order": 3 },
    "qr_wait":    { "label": { "ja": "少々お待ちください", "en": "One moment please",
                               "zh": "请稍等" }, "speak": true, "order": 4 }
  },
  "reply": { "display_ttl_s": 30 },             // panel display duration

  "trigger_rules": {
    "r1": { "enabled": true,
            "when": { "type": "button", "doors": ["d_front", "d_back"] },
            "schedule": { "always": true },
            "actions": [ { "type": "sip_call", "target_extension": "600" },
                         { "type": "telegram", "households": ["h_ox"], "with_snapshot": true },
                         { "type": "ha_event" },
                         { "type": "chime", "devices": ["<indoor_node_id>"], "sound": "ding1" } ] },
    "r3": { "enabled": true,
            "when": { "type": "motion", "doors": ["d_front"] },
            "schedule": { "windows": [ { "days": ["mon","tue","wed","thu","fri","sat","sun"],
                                         "from": "22:00", "to": "06:00" } ] },
            "actions": [ { "type": "telegram", "households": ["h_ox"], "with_snapshot": true },
                         { "type": "ha_event" } ] },
    "r4": { "enabled": true,
            "when": { "type": "device_offline", "devices": "all" },
            "actions": [ { "type": "telegram", "households": ["h_ox"] },
                         { "type": "ha_event" } ] }
  },

  "quiet_hours": {
    "default": { "windows": [ { "from": "23:00", "to": "07:00" } ],
                 "suppress": ["chime"],
                 "never_suppress": ["sip_call", "telegram", "ha_event"] }
  },

  "integrations": {
    "mqtt": { "host": "10.0.1.5", "port": 1883, "user": "doorbell",
              "pass_ref": "secret:mqtt", "discovery_prefix": "homeassistant",
              "base_topic": "doorbell" },
    "telegram": { "bot_token_ref": "secret:tg_bot",
                  "poll_updates": true,          // getUpdates long-polling for inline button replies (leader)
                  "text_template": { "ja": "{door} に来客です ({time})" } },
    // Web calls (webui/panel/call.html — optional feature). Browsers cannot speak SIP/UDP, so
    // Asterisk is used as a WebRTC gateway (deploy/asterisk/webrtc.en.md).
    // Empty ws_url = call button disabled (video viewing/sending works independently of SIP).
    // sip_user/sip_pass = the browser extension (the [260] template in webrtc.en.md).
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260", "sip_pass": "…" },
    "tz_offset_min": 540                         // JST. Used for schedule evaluation
  }
}
```

## Events (events table / gossip)

- ID = `(origin_node, origin_seq)`, idempotent. Types: `press | motion | answered | missed | reply |
  offline | online | config_changed | emergency | emergency_cancel | visitor_lang`
- `emergency` payload: `{ "source": "<node_id>", "via": "panel|web|admin" }`. Exempt from
  quiet_hours suppression (always notified on all channels). UI: `{"t":"emergency","active":true|false}`
- `visitor_lang` (a visitor switched language at the door station): payload `{ "lang": "en" }`. The
  press payload also carries `visitor_lang` (when a selection was made). Displayed on: the language
  badge on indoor/TV ring screens, /api/panel/state, the "🌐 EN" in Telegram notifications, and the
  HA attrs topic. **Quick replies are shown + spoken via TTS using this language's labels**
  (falling back to ja when no translation exists). When the revert timer expires, it returns to ja
  and clears.
- `reply` event payload: `{ "reply_id": "qr_away", "text": "…", "via": "telegram|mqtt|web",
  "target_press": "<origin>:<seq>" }`
- press notify (LWW merge): `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`

## MQTT (Phase 2 — implemented)

The plan's topic table + `doorbell/<door_id>/reply/set` (subscribed; payload = reply_id or free
text). Implementation: `core/src/bridge/` (mqtt_client = homegrown MQTT 3.1.1 QoS0, ha_bridge =
HA integration).

- Enabled when: `integrations.mqtt.host` is non-empty AND this node is the mesh `mqtt_bridge` duty
  leader. Starts/stops automatically on leader changes and config changes. `/api/status` reports
  `bridge.mqtt = connected|disconnected|inactive`.
- On connect: LWT=`<base>/bridge/availability`=offline(retain) → online(retain) →
  all discovery (retain) → current state (door/node availability) → subscriptions
  (`<prefix>/status`, `<base>/+/reply/set`, `<base>/cmd/ack`). On `<prefix>/status`="online"
  (HA restart), discovery + state are fully republished.
- Discovery entities (object_id/unique_id are ASCII; Japanese appears only in name):
  per door, `event.doorbell_<door_id>` (device_class doorbell) and
  `binary_sensor.doorbell_<door_id>_motion` (off_delay 30); per device,
  `binary_sensor.doorbell_node_<first 8 chars of node_id>` (connectivity — anti-theft device-loss
  detection); plus `binary_sensor.doorbell_bridge_online` (LWT-based; referenced by the deploy/ha
  watchdog) and `binary_sensor.doorbell_emergency` (device_class safety, state_topic
  `<base>/emergency` retain — SOS emergency mode. ON/OFF follows whichever of emergency /
  emergency_cancel has the greater hlc).
- Snapshots/cameras are not carried over MQTT — live video goes through go2rtc, and stills are
  fetched by an HA generic camera directly from the door station's `/snapshot.jpg`
  (see `deploy/ha/`).
- MVP uses plaintext `user`/`pass` auth (moving `pass_ref` into the secure store is planned
  together with sip).

## Unified Asset API / Visitor Language API (details finalized in the implementation)

- `POST /api/assets?type=<mime>&label=<name>` (admin session required) — body is raw bytes.
  Allowed types are only `image/jpeg` `image/png` `audio/mpeg` `audio/wav`, limit 3MB.
  Response `{"hash":"<sha256>"}`. Empty body=400 / disallowed type=415 / over limit=413 /
  not logged in=401. Registration writes the ledger entry `assets.<hash>` =
  `{size,type,origin,label}`, replicated to all nodes via CRDT.
- `GET /asset/<sha256>` — retrievable with an admin session **or** a panel token (`?k=`) (403/404).
  `<sha256>` must be exactly 64 lowercase hex digits; anything else is 400 (path-traversal defense).
- `DELETE /api/assets/<sha256>` (admin session) — tombstones the ledger entry `assets.<hash>` and
  immediately deletes the local cache on this node. Other nodes see the ledger removal (CRDT
  replication) and reclaim it naturally via grace-period GC.
- Prefetching happens not "when it enters the ledger" but "when it is referenced from the config" —
  reference sources are `display.theme.bg_image` / `devices.*.local.theme.bg_image` /
  `quick_replies.*.audio.*` / a chime's `sound:"asset:<hash>"` / `emergency.alarm_sound`. On fetch
  completion, `{"t":"asset_ready","hash":"<sha256>"}` is sent via uiNotify (the shell repaints/
  reloads on it). `/api/status`'s `assets: {cached,total}` is the per-node cache coverage.
- Development injection: `doorbell_host --add-asset <file> [--asset-type <mime>] [--asset-label <name>]`
  (type inferred from the extension when omitted; hash printed to stdout).
- MQTT additions: the press event payload is `{"event_type":"press","purpose":…,"visitor_lang":…}`
  (purpose/visitor_lang only when applicable). `<base>/<door_id>/attrs` publishes
  `{"visitor_lang":"ja|en|zh"}` with retain, discovered as
  `sensor.doorbell_<door>_visitor_lang`. Telegram press notifications lead with
  `{icon} {purpose name}` and the visitor-language badge `🌐 EN`.
