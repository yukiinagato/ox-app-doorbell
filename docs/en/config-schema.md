# Configuration Schema (canonical reference)

Configuration is a flat key→JSON LWW-Map CRDT. Keys are dot paths. Below is the full picture after
materialization. `*_ref: "secret:…"` refers to the secrets namespace (write-only in the admin UI,
never displayed; stored in the platform secure store).

`boot.json` is the local bootstrap profile, not part of this CRDT. Android, iOS/iPadOS (including
iOS 5 compatibility), and Windows open a blocking setup screen before Core starts when the profile
is new, lacks an explicit `setup_complete:true`, has a missing/invalid `role`, or a `door_station`
has no valid `door`. The operator must
choose `door_station` or `indoor_panel`; the door field is required only for a door station and is
pre-filled with a random `door-xxxxxxxx` value that may be accepted unchanged. Valid door IDs are
1–64 characters, begin with an ASCII letter or digit, and then contain only letters, digits, `_`,
or `-`. A successful save writes `setup_complete:true` atomically. tvOS is intentionally fixed to
the `indoor_panel` profile because it has no supported door-camera role.

After a device joins a cluster, `devices.<self>.name`, `.role`, and `.door` are its remotely
editable desired identity. Android and iOS/iPadOS target shells validate a changed identity and
write it to local
`boot.json` atomically, then restart the UI and Core so the new role is advertised and used by the
platform runtime. Until that restart finishes, peers use the target's live signed advertisement
instead of a newer replicated identity that the target has not applied yet.

The mesh PSK is device-local bootstrap data, not a CRDT value. Core must first complete
`secure_put("mesh.psk", …)`, then emits only
`{"t":"paired","psk_ref":"secret:mesh.psk"}`. The shell persists that opaque reference with
non-secret `seed_peers` in `boot.json`; it never receives a new `psk_hex`. A secure-store failure
emits `pairing_persistence_error` and must remain not-ready. Legacy `psk_hex` is migration-only.

Web Push is a deliberate exception only in encrypted form: Core stores each complete
`endpoint`/`p256dh`/`auth` subscription as one schema-v2 CRDT record sealed with
XChaCha20-Poly1305 under a mesh-PSK-derived key. Materialized configuration and exports never show
the plaintext subscription. Startup reseals a legacy raw record or removes it fail-closed.

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // safety net on a single L2 (the beacon is primary)
  },

  "panel": {
    "token_refs": ["secret:panel.access.<random>"],
    "token_generation": "0123456789abcdef0123456789abcdef"
  },

  "buildings": {
    "b_main":  { "label": { "ja": "母屋", "en": "Main House" } },
    "b_annex": { "label": { "ja": "離れ", "en": "Annex" } }
  },

  "doors": {
    "d_front": { "building": "b_main",  "label": { "ja": "正面玄関" },
                 // Optional announcement shown on that door's visitor screen and on the indoor
                 // dashboard. text is 1-200 characters; expires_ms is an absolute wall-clock
                 // deadline and 0 means "until cleared". Core prunes an expired notice on its
                 // one-minute tick and emits notice_changed.
                 "notice": { "text": "Deliveries to the side gate today",
                             "from_device": "<node_id>", "created_ms": 0, "expires_ms": 0 } },
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
        // Per-device volume overrides, 0-100. An absent level inherits audio.volume.
        "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },
        "screensaver_after_s": 120,
        "video": { "playback": "low_latency",   // low_latency (default) / hls / mjpeg
                   "rotation": "auto" },          // follow sensor / force 0, 90, 180, or 270 degrees
        "camera": { "device_hint": "", "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto" = probe for HW h264, fall back to mjpeg / "mjpeg" / "h264"
                    // with h264, /stream.mp4 (fMP4, platform HW encoder) becomes available and
                    // resolution/fps are set separately via the h264_* keys (Phase 6)
                    "codec": "auto", "h264_resolution": "640x360", "h264_fps": 30,
                    "h264_bitrate_kbps": 700 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "recovery": { "helper_mode": "auto" }, // off | auto | on
        // Semantic overrides are complete element objects. The native shell validates them
        // against its top-level ui_manifest. The Web panel on the serving node validates the
        // same path against status.web_ui.manifest.
        "ui": { "elements": {
          "call.primary": { "scale": 1.1, "foreground": "#FFFFFF",
                            "background": "#1A2027", "accent": "#4DA3FF" },
          "cancel.call": { "scale": 1.0, "foreground": "#FFFFFF",
                           "background": "#8D2932" }
        } },
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

  // External media sources are explicit configuration, never inferred from seed_peers.
  // URL userinfo and plaintext credential fields are rejected; authentication is secret_ref.
  "media_sources": {
    "front_camera": {
      "schema_version": 1, "kind": "ip_camera",
      "streams": {
        "mjpeg": { "url": "http://192.0.2.20/live.mjpeg" },
        "snapshot": { "url": "https://192.0.2.20/snapshot.jpg" },
        "h264": { "url": "rtsp://192.0.2.20/live", "transport": "tcp",
                  "profile": "baseline" }
      },
      "secret_ref": "secret:media.front_camera"
    }
  },

  // Receiver playback policy. Array order is priority; disabled strategies are skipped.
  // A pair profile completely replaces global for that indoor/outdoor node-id pair.
  "video_playback": {
    "global": { "strategies": [
      { "id": "h264_low_latency", "enabled": true,
        "startup_timeout_ms": 5000, "stall_timeout_ms": 3000 },
      { "id": "h264_hls", "enabled": false,
        "startup_timeout_ms": 5000, "stall_timeout_ms": 5000 },
      { "id": "mjpeg", "enabled": true,
        "startup_timeout_ms": 5000, "stall_timeout_ms": 3000 }
    ] },
    "pairs": { "<indoor_node_id>": { "<outdoor_node_id>": { "strategies": [] } } }
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
    "call_flow": "purpose_first",             // purpose_first | ring_then_purpose
    "languages": ["ja", "en", "zh"],            // languages offered on the door station's visitor language switcher
    "launch_sound": "title_display",             // startup sound; empty string disables it
    "call_sound": "outdoor_call_alert",          // door-station call acknowledgement; empty disables it
    "call_sound_loop": false,                     // loop until reply or the 30-second timeout
    "button_sound": "button_click",              // all other buttons; empty disables it
    "update_sound": "indoor_update",             // cancellation/purpose and other visitor updates
    "ringtone": "school_chime",                  // school_chime / ding1 / ding2 / classic / asset:<sha256>
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
    "theme": { "bg_color": "#101418", "bg_image": null,   // bg_image: an assets sha256 or null
               // The semi-transparent layer a shell composites between the background image and
               // everything drawn on it, so text stays readable over a bright photograph. On by
               // default; every leaf is overridable per device under
               // devices.<id>.local.theme.backdrop.*, and each leaf resolves on its own.
               "backdrop": { "enabled": true, "color": "#000000", "opacity": 62 },  // 0..100
               "glass": { "blur_radius": 24 } },       // 0..40; capable shells only
    "brightness": 70,                           // 0-100 (remote adjustment — slider in the admin UI)
    "night": { "enabled": true, "from": "22:00", "to": "06:00",
               "brightness": 15, "red_tint": true },   // night mode (evaluated with the corrected clock)
    "screensaver_after_s": 120,                 // screensaver after idle (clock drift, low brightness)
    "pixel_shift_s": 300                        // periodically shift idle-screen elements by a few px (burn-in protection)
  },

  // Cluster time. The IANA zone is resolved from a table bundled in core, so a shell on a
  // platform without a usable tz database renders the same clock as every other device.
  // integrations.tz_offset_min below stays valid and is derived from this zone (including its
  // current daylight-saving state) whenever "zone" is set; an installation that never set a zone
  // keeps the fixed offset as the source of truth.
  "time": {
    "zone": "Asia/Tokyo",                       // IANA identifier from the bundled table
    // Independent time service. Core never sets the operating-system clock: it measures an
    // offset by SNTP and adds it to every wall-clock reading (HLC, event and call-history
    // timestamps, rule schedules, quiet hours, displayed clocks). The offset is dropped again
    // after three intervals without a successful sync.
    // One round runs when the service is switched on, when the servers change, and at start-up;
    // after that the interval. A failed round retries from one minute, doubling to at most an
    // hour, rather than waiting a whole day. POST /api/time/sync triggers one by hand.
    "ntp": { "enabled": false,                  // default off
             "servers": ["ntp.nict.jp", "time.google.com"],   // 1-4 "host" or "host:port"
             "interval_s": 86400 }              // 3600..604800; default once a day
  },

  // Cluster default volumes, 0-100. A device overrides them with
  // devices.<id>.local.audio.volume.{call,sos,idle}; the sos level additionally falls back to
  // emergency.alarm_volume for an installation that predates these keys.
  "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },

  "emergency": {                                // indoor emergency call for help (SOS)
    "button_on_roles": ["indoor_panel"],        // roles that show the SOS button
    "hold_to_trigger_s": 3,                     // legacy long-press duration; unused by slide mode
    // Slide-to-trigger control. mode is "slide" ("hold" stays accepted so an older
    // configuration keeps validating); countdown_s is 0..10 seconds of cancellable countdown
    // before core is told the emergency is real.
    "trigger": { "mode": "slide", "countdown_s": 3 },
    "alarm_sound": "siren1", "alarm_volume": 100,
    // When true, an open Web panel renders replicated active SOS even if a rule has no
    // recipients or requests Web Push only. When false, a matching positive device_alert or
    // delivered Web Push may still render it.
    "web_active_page_alerts": true,
    "sip_call": { "enabled": false, "target_extension": "" },  // optional: call a user-defined destination via Asterisk
    "cancel_requires_pin": true                 // cancelling requires the kiosk PIN
  },
  // SOS active/clear state always replicates. Presentation and external delivery are rule-driven,
  // may target zero recipients, and never imply an automatic police/fire-services call.

  "visit_purposes": {                           // visitor purpose buttons (user-editable; default seed below)
    // On the door station, one tap on a purpose button = a ring with that purpose attached
    // (a courier is done in a single action). The big "Call" button is a generic ring with no
    // purpose. Labels follow the visitor's language.
    // "enabled": false hides a purpose from visitors without deleting it; its wording, icon
    // and order survive being switched off and back on. Default true.
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1, "enabled": true },
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
                         { "type": "ha_event" } ] },
    "r_sos_default_on": {
      "enabled": true,
      "when": { "type": "emergency_on" },
      "actions": [
        { "type": "device_alert",
          "targets": { "roles": "all", "web_subscription_groups": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "never_suppress": true,
          "presentation": { "visual": true, "sound": "siren1", "volume": 100,
                            "sticky": true, "ttl_s": 0, "background": "#8F1010",
                            "foreground": "#FFFFFF", "accent": "#FFD166" } },
        { "type": "telegram", "households": "all", "never_suppress": true }
      ]
    },
    "r_sos_default_off": {
      "enabled": true,
      "when": { "type": "emergency_off" },
      "actions": [
        { "type": "device_alert",
          "targets": { "roles": "all", "web_subscription_groups": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "never_suppress": true,
          "presentation": { "visual": true, "sticky": false, "ttl_s": 10 } },
        { "type": "telegram", "households": "all", "never_suppress": true }
      ]
    },
    // Seeded once. A missed call is a call_cancelled event whose reason is "timeout" or
    // "recovery_*". Indoor roles only: a door station must never alert the visitor.
    "r_missed_call_default": {
      "enabled": true,
      "when": { "type": "call_missed" },
      "actions": [
        { "type": "device_alert",
          "targets": { "roles": ["indoor_panel"], "web_profiles": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "presentation": { "visual": true, "sticky": false, "ttl_s": 30 } }
      ]
    }
  },

  // Local event retention. The newest 5,000 records of every origin always survive; older ones
  // may be removed only once replication proves every cluster member holds them.
  "events": { "retention_days": 90 },           // 1..3650, default 90

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
    // Web Push is delivered through a maintained HTTPS sender. Private material stays in each
    // eligible leader candidate's local secure store; only references replicate.
    "web_push": { "sender_url": "https://push-sender.example/doorbell/send",
                  "vapid_public_key": "<base64url-public-key>",
                  "vapid_private_key_ref": "secret:webpush.vapid_private",
                  "vapid_subject": "mailto:doorbell@example.com",
                  "sender_secret_ref": "secret:webpush.sender" }, // optional sender bearer token
    // Web calls (webui/panel/call.html — optional feature). Browsers cannot speak SIP/UDP, so
    // Asterisk is used as a WebRTC gateway (deploy/asterisk/webrtc.en.md).
    // Empty ws_url = call button disabled (video viewing/sending works independently of SIP).
    // sip_user/sip_pass_ref = the browser extension (the [260] template in webrtc.en.md).
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260",
                "sip_pass_ref": "secret:webrtc.260" },
    "tz_offset_min": 540                         // JST. Used for schedule evaluation
  }
}
```

Provision a Web Push backend in two phases. First, on every node intended to be eligible for the
`web_push` duty, use authenticated `POST /api/secrets` to write the same
`vapid_private_key_ref` value locally (and `sender_secret_ref` when the sender requires a bearer
token). Only after those writes succeed, atomically save the non-secret `integrations.web_push`
fields and references. The sender URL must be HTTPS, and `vapid_public_key` must be an uncompressed
P-256 public point encoded as base64url (65 bytes including the `0x04` prefix). Do not put either private value in config,
exports, URLs, logs, or command lines. Verify `/api/status.web_push.delivery_backend:true`, a
non-empty `leader`, and that each intended failover candidate reports measured `web_push_ready`
before relying on Push-only SOS delivery. `configured:true` alone does not prove that a leader can
read the local secret or reach a sender.

Leader election additionally requires `tls12`, `wan`, `mains_power`, `wall_clock_sane`, and
`web_push_ready`. Shipping shells fail closed with `wan:false` because a LAN/default route is not
evidence of Internet reachability and no general sender probe is built in. After testing HTTPS
egress to the configured sender from the exact node/network, an administrator may explicitly set
`devices.<id>.caps_override.wan:true`; record that external test as the measurement source and
remove the override when routing changes. Override `mains_power` only after commissioning a fixed
power supply. An override must never be used to invent TLS support, a readable secret, or a working
backend.

An iOS compatibility `streams.h264` entry with `transport:"tcp"` selects bounded RTSP/RTP
interleaved ingest, not a direct fMP4 URL. Runtime starts degraded as `rtsp_ingest_pending` and may
advertise `rtsp_h264_forwarding` only after DESCRIBE/SETUP and an Annex-B IDR actually accepted by
Core. Configuration alone is never availability evidence; iPad 1 real-camera qualification is pending.

`panel.token_refs` and the non-secret 32-hex `panel.token_generation` are fleet configuration.
Rotation replaces both in one commit. Every `dbpanel` session is bound to the current generation
and canonical reference set, so a replicated rotation invalidates sessions on every node. Secret
values do not replicate: use the authenticated Admin **Provision on this node** action on every
panel-serving node, writing the same already-replicated reference without changing configuration.

`devices.<id>.local.recovery.helper_mode` is the configured request, not proof that a helper is
installed or effective. The Admin form defaults to `auto` and writes it through an authenticated
atomic config batch; Core accepts only `off`, `auto`, or `on`. Capability/runtime status must
separately report measured helper availability and the effective mode. `on` with no reachable
helper is a visible degraded/error condition, not a successful supervision claim. After an atomic
config apply, the platform client sends the fixed local `MODE <value>` command and verifies helper
status; the helper atomically persists that mode for helper/OS restart. No generic command or argv
is derived from configuration.

## One administrator password, announcements, unlock, and appearance

`admin.password_hash` is the single administrator credential for the whole cluster: the same
secret opens the web admin and every device's settings screen. It replicates as
`{"salt":"<hex>","hash":"<hex>","algo":"blake2b-256","updated_ms":…}` and never as plaintext, so
an offline device verifies against the copy it already holds. The first password offered on any
surface becomes the cluster's (the web login's existing trust-on-first-use path). Five failed
attempts on any surface pause every surface for ten minutes; the counter is shared between
`POST /api/login` and `db_core_admin_password_verify`.

Before this key existed each node kept its own digest in local storage, and a kiosk kept a
separate exit code. That local digest stays authoritative until the first successful
verification, which republishes it as the cluster password. A shell that still holds its own
`exit_pin.txt` digest must stop consulting it as soon as `db_core_admin_password_verify` returns
success or "unset", and delete it: one password change must not leave a second way in.

**An unset password never blocks clearing a running SOS alarm.** Read
`status.emergency.cancel_requires_password`, which core computes as `emergency.cancel_requires_pin`
AND a password actually being set. Gating the clear control on `emergency.cancel_requires_pin`
alone would lock a household out of silencing its own alarm.

`notice.global` is the cluster-wide announcement and `doors.<id>.notice` overrides it for one
door; `status.doors.<id>.notice` reports the resolved value with a `scope` of `door` or `global`.
`notice.presets` is an administrator-editable list of at most eight `{id, text}` entries that the
announcement dialogs render; three are seeded once and may be edited or deleted freely.

`doors.<id>.unlock.show_button` decides whether the unlock control appears. It defaults to
"show it when it does something": true exactly when an unlock action is configured, which means
`doors.<id>.unlock.command` or the first `ha_command` in `sip.dtmf_actions`. An administrator may
force either answer. `status.doors.<id>.unlock` reports `configured`, `command`, `show_button` and
whether the answer came from the default or an administrator, so a shell decides before the
control is ever pressed. `POST /api/doors/<id>/open` and `db_core_open_door` publish the same
`ha_command` the SIP feature code does, and report `unlock_not_configured` rather than a silent
no-op.

`display.appearance` is `auto_system`, `auto_schedule`, `light`, or `dark`, with
`display.appearance_schedule = {dark_from, light_from}` evaluated in `time.zone`. Both exist at
cluster scope and under `devices.<id>.local.display`. The published contract adds
`follow_system`, which tells a shell to prefer the operating system's own setting; platforms
without one (iOS 5, Android before 10) use the schedule result instead.

A door station whose `boot.json` names a door creates `doors.<door>` itself when the entry is
absent — on founding or joining a cluster and on every later start while paired — labelling it
with the device name in all three languages. Without it a freshly founded cluster had
`devices.<id>.door` pointing at a door that did not exist, `status.doors` was empty, and every
door-keyed surface (announcements, unlock visibility, tiles) had nothing to address. The entry is
only ever created, never rewritten: rename it, give it a building, or reassign the station in the
Admin 門口 tab and those edits survive every restart. An indoor panel owns no door and seeds
nothing.

`status.doors` additionally lists any door served by an **alive door-station peer** that has no
configuration entry yet, marked `"configured": false` and labelled with that device's name. An
installation configured before this behaviour existed therefore still renders its tiles and still
accepts an announcement for them; the first write creates the entry and it reports `configured`
from then on. A door nobody serves and nothing configures remains unknown and is refused.

`display.theme.auto_background` reports `{"color":"#RRGGBB","source":…}` and, when the source is
`image_unsampled`, a `"reason"`. The three sources are distinct on purpose:

| `source` | meaning |
|---|---|
| `color` | no background image is configured; `color` is the theme colour and is authoritative |
| `image` | the background image was sampled; `color` is its average |
| `image_unsampled` | an image **is** configured but core could not sample it; `color` is only the flat theme colour |

`reason` is `too_large` (beyond core's decoded-pixel budget of 16 MP), `decode_failed` (not a JPEG
or PNG this build decodes), or `missing` (the asset is not cached on this node yet). On
`image_unsampled` a shell must **not** trust `auto_ink` or `auto_accent`: they were derived from
the theme colour, not from the picture actually on screen. Sample the image locally and decide
there, or leave the previous ink in place until the asset arrives.

Core samples a grid of at most 16x16 points, but stb has no downscale-on-decode, so the decode is
transient and costs about three bytes per pixel (roughly 48 MB at the cap) and is freed
immediately. A shell on hardware that cannot afford that should sample locally regardless; the
`source` field is what tells it core has not.

### Choosing the ink

`auto_ink` names the ink token to draw on the background: **whichever of dark or light has the
higher WCAG contrast ratio against the sampled luminance**. The two ratios cross at Y = 0.1791,
not at mid luminance, so a background that merely looks middling already wants dark ink.

Splitting at Y >= 0.5 was the earlier rule and it fails in the band between the two thresholds: a
light grey photograph averaging `#BBBBB4` sits at Y 0.494, where white ink scores 1.93:1 and dark
ink 9.58:1. Worked vectors, which `core/tests/test_color.cpp` pins:

| background | Y | dark ink | light ink | `auto_ink` |
|---|---|---|---|---|
| `#BBBBB4` | 0.494 | 10.88:1 | 1.93:1 | `dark` |
| `#808080` | 0.216 | 5.32:1 | 3.95:1 | `dark` |
| `#767676` | 0.1812 | 4.62:1 | 4.54:1 | `dark` |
| `#757575` | 0.1779 | 4.56:1 | 4.61:1 | `light` |
| `#404040` | 0.051 | 2.03:1 | 10.37:1 | `light` |

The 1 px 40% opposite-ink shadow stays, as the fallback for when even the better ink is below
4.5:1. Shells that sample locally (because `source` is `image_unsampled`, or because the hardware
cannot afford core's decode) apply the same rule, so the fleet agrees on one answer.

An auto-seeded entry carries `seeded_by` (the node that created it) and `seeded_label` (the label
it wrote). When that node next starts, or becomes paired, with a role other than `door_station` or
a different `boot.door`, it deletes the entry it seeded — otherwise a station switched to an
indoor panel leaves a ghost tile behind for a door nobody serves. It deletes only an entry that is
still exactly what it wrote: any other field, or a renamed label, means an administrator has
adopted the door, and an adopted door outlives the device that happened to create it. That is
correct for a real station that is merely down.

`status.doors.<id>.served_by` is the node id of the alive door station serving the door, or
`null`. It is what separates "the station is offline" from "no station serves this door at all";
`configured` separates "this door has an entry" from "a live station is serving a door nobody has
set up yet".

`served_by` and `peers[].status` are read from one liveness map that the status response builds
once, so the two can never contradict each other: a node named in `served_by` is always `alive`
in `peers[]`, and a node that is anything else is never named. A configured device the mesh has
not seen appears as `offline` and never serves a door.

A station that goes away and comes back keeps its node id: it refreshes the entry it already had
rather than adding a second one. This holds even when the station restarts with its heartbeat
counters reset, which would otherwise look like a replay of an advertisement already seen.

### Returning from the incoming-call screen

`call.indoor.return_s` (5..600 seconds, default 60), with the per-device override
`devices.<id>.local.call.return_s`, is how long an indoor panel stays on the incoming-call page.
The page title carries the countdown -- "(60)" -- and the panel returns to its home page when it
reaches zero. `status.call.return_s` reports the effective value for this node.

Two behaviours matter for the shells. If the visitor cancels the call, the panel does **not**
leave the page immediately: the live view stays until the countdown ends or someone leaves
manually, because a resident who has just looked up should still get to see who was there.
Tapping the countdown number cancels the countdown for that call, so a resident watching the door
is never thrown back to the home page mid-look.

### Joining a cluster is silent

Anti-entropy hands a joining node the cluster's entire event history at once. Those records are
applied to the call log in full, with their original outcomes, and **none of them ring**. A call
event presents -- chime, incoming screen, missed-call alert, Telegram, MQTT -- only while its call
is live now: still `ringing` on the door station, and inside the ring window the press itself
declared (`expires_at_ms`, evaluated against corrected cluster time). A terminal event presents
only while it closes a call this device is actually showing, or while it is recent enough for a
missed-call alert to still mean something.

The same principle covers announcements and SOS by construction: both are replicated
configuration and replicated state, so a joining node applies the *current* value once and never
replays the transitions that produced it.

### Who may answer

`sip.accounts.<node_id>.answer_mode` is `auto` (answer immediately) or `ring` (ring and wait for a
person). **The default follows the role**: `auto` on a `door_station`, `ring` on an
`indoor_panel`. `status.sip.answer_mode` reports the effective value.

This matters for the call history: `outcome: "answered"` and `answered_by` are meant to record
that a person picked up. An indoor panel left on the default must therefore not answer by itself.
A household that wants an intercom can still set `auto` per device, and the history then
attributes the call to that device.

### The pairing QR payload

The QR a device scans to join is a custom-scheme URI, so a device that already has the app
installed opens straight into the join flow instead of a browser:

```
doorbell://pair?host=<ip:port>&pin=<6 digits>&exp=<unix seconds>&cluster=<name>
```

`host` and `pin` are required. `exp` is an absolute Unix second, so a scanner rejects a stale code
without having to know when it was produced. `cluster` is the human-readable cluster name. Values
are percent-encoded with the RFC 3986 unreserved set, so a name with spaces or Japanese survives
the round trip; `+` is a literal plus, never a space. Only these four keys are defined and a
parser **ignores** any other, so the format can gain one without breaking shells already shipped.

Core builds it: read the `uri` field of `db_core_mint_join_token_json`,
`db_core_start_pairing_json`, `POST /api/join-token`, `POST /api/pairing/start`, or the `token`
object of `db_core_pairing_json` / `GET /api/pairing`. Never assemble the string in a shell.
Always keep the host and PIN printed beside the code as well — someone scanning with a plain
camera app has to be able to read and type them.

`db_core_parse_pair_uri_json` validates a scanned code so every platform reaches the same verdict:
`{"ok":true,"host":…,"pin":…,"exp":…,"cluster":…}` or `{"ok":false,"err":…}` with `err` one of
`bad_scheme`, `missing_pin`, `missing_host`, `expired`. The expiry is checked against corrected
cluster time when core is running, and against the platform clock otherwise, because a shell may
scan a code before core has started.

## Time, power, and announcements

The bundled time-zone table lives in `core/src/util/tz.{h,cpp}` and covers the zones the settings
UI offers across Asia, Europe, the Americas, Oceania, and Africa. It is a snapshot of the rules
currently in force, with no historical data: daylight saving is modelled per regime (EU, North
America, southern Australia, New Zealand, Chile, Israel), and an instant from before the current
regime may resolve to today's rule. `time.zone` is rejected unless the table can resolve it, so a
zone shown in the UI is always the zone actually used.

`integrations.tz_offset_min` remains the compatibility surface for the Telegram bridge and older
shells. Whenever `time.zone` is set, Core rewrites it from the zone -- on startup, on a zone
change, and on the one-minute housekeeping tick, so it follows daylight saving instead of freezing
at the offset that happened to be current when the zone was chosen. An installation that never set
`time.zone` keeps the fixed offset as the source of truth and nothing rewrites it.

`time.ntp` is off by default. When it is on, Core runs a minimal SNTP v4 client (RFC 4330) on a
short-lived worker thread: three samples per server, the lowest round trip wins, and a sample is
discarded when its round trip exceeds three seconds or its offset exceeds 24 hours. The measured
offset is applied to `IClock::wallMs()`, which is what the HLC, event timestamps, call history,
rule schedules, quiet hours, and every rendered clock read. The operating-system clock is never
written, and the correction is withdrawn after three intervals without a successful sync, so a
device whose NTP servers become unreachable falls back to plain system time rather than drifting on
a stale measurement. `POST /api/time/sync` (admin session) starts one immediate round;
`status.time` reports the result and `time_changed` is emitted when the source flips or the applied
offset moves by more than 500 ms.

Power state comes from the optional `db_platform_v2.power_state` callback, polled once a minute.
It is published as `status.self.power` (and the identical `status.node.power`), gossiped into
`peers[].power` through the bounded runtime projection, and reported as `power_changed` when the
battery moves five points or more or charging/mains flips. A platform that reports `mains` replaces
the create-time `mains_power` guess with that measurement before administrator overrides apply. A
device with no battery reports `battery_pct: -1` and shells hide the indicator entirely.

An announcement is ordinary replicated configuration at `doors.<id>.notice`, so it survives a
restart and reaches every device through the same CRDT path as any other setting. Core prunes an
expired notice on the one-minute tick -- any node may prune, because the tombstone replicates and a
repeated prune is a no-op -- and emits `notice_changed`. `POST` and `DELETE /api/doors/<id>/notice`
accept either an administrator session or a panel credential, which is what lets the indoor
announcement dialog and the Admin doors tab write the same value.

## Runtime UI manifests

The native shell publishes a read-only top-level `ui_manifest`; Core publishes the serving node's
separate built-in Web contract as `web_ui.manifest`. Both use schema version 1 and constrain
`scale`, `font_scale`, `foreground`, `background`, `accent`, `border`, and `radius`, minimum touch
size, contrast, and safety-critical controls. They share the configuration path shown above, but
Admin presents **Native UI** and **Web UI** as separate surfaces because their element sets differ.
The current Web manifest covers `call.primary`, `cancel.call`, `call.end`, `purpose.button`,
`ring.title`, `ring.action`, `status.offline`, `reply.button`, `monitor.close`, and the always-visible
two-second hold control `sos.trigger`. The SOS style is also the safe baseline for the full-screen
Web presentation; valid rule-projected presentation colors temporarily take precedence. Web omits
`sos.cancel` because a panel session cannot clear replicated emergency state.

Core durably caches each peer's last valid native manifest and capabilities. A configured offline
device appears in status with `cached_contract:true`, so Admin may validate and save against that
cached native contract across Core restart. This is not apply success: the exact renderer must
reconnect, validate, and report before Admin marks the override applied. On rejection, it retains
its last-known-good style. The Web manifest remains local to the node serving Admin and is not a
replicated per-peer Web catalog; Admin cannot infer a remote/offline Web surface from a native
manifest.

## Pairing state and events

`GET /api/pairing` and `db_core_pairing_json` return the same snapshot, rebuilt on every call so
countdowns tick. Shells render `pairing.state` and never infer it from `paired` /
`persistence_ready`:

| `state` | Meaning | Next action for the shell |
|---|---|---|
| `unpaired` | No PSK. The device announces itself for pairing. | Onboarding: searching + own Add QR |
| `joining` | A PIN join or an arriving invitation is being applied. | Spinner |
| `persist_error` | PSK is in memory but `secure_put` failed. | Error + retry (`POST /api/pairing/retry-persist`) |
| `ready` | PSK persisted; member of a cluster. | Main UI + membership |
| `revoked` | Removed by an administrator. | Message, then wipe → `unpaired` |

```jsonc
{
  "state": "ready", "paired": true, "persistence_ready": true,
  "is_founder": true,                                // persisted in store meta (pairing.is_founder)
  "psk_source": "secure_store",                      // secure_store | boot_plaintext | none
  "psk_ref": "secret:mesh.psk",                      // null unless psk_source is secure_store
  "role": "door_station",
  "self": {"id":…, "addr":…, "name":…, "role":…, "pk":…,
           "model":"Pixel 4a", "platform":"android", "sw":"0.1.0"},
  "pair_qr": "doorbell-pair:<addr>|<id>|<pk>",
  "home": {"member_count": 2, "connected_count": 2},
  "token": {"active": true, "expires_s": 180, "attempts_left": 3,
            "host": "10.0.1.5:47172", "pin": "418205"},   // pin present only while active
  "pending": {
    "pairing_mode": false, "pairing_mode_left_s": 0, "auto_added_count": 0,
    "devices": [{"id":…, "addr":…, "name":…, "role":…, "model":…, "platform":…, "sw":…,
                 "age_s": 3, "invite_state": "sent", "attempts": 1, "last_error": ""}]
  }
}
```

`invite_state` is `none | sent | acked | joined | failed`. A manual invitation retries three times
at two-second intervals and then fails with `no_ack`; an automatic one (bulk add) is sent once. A
pending entry is removed when its device completes the secure handshake.

Pairing UI events (uiNotify, distinct from the replicated event log below):

| Event | Payload | When |
|---|---|---|
| `pairing_state` | `{state, is_founder, psk_source}` | Every state change. The one shells key off. |
| `pending_changed` | — | Pending device added, removed, expired, or a field changed |
| `invite_result` | `{id, ok, err}` | End of a manual invitation (`err`: `no_ack`, `host_unpaired`, `unknown_device`, `bad_pk`, `no_addr`, or the invitee's rejection reason) |
| `device_joined` | `{id, name, role}` | A pending device established its secure channel |
| `pairing_mode_changed` | `{active, left_s, auto_added_count}` | Bulk-add start, stop, or expiry |
| `join_token_changed` | `{active, expires_s, attempts_left}` | PIN mint, expiry, or burn after three failures |
| `invite_rejected` | `{reason}` | On the *invited* device (`already_paired`, `no_pair_key`, `bad_payload`, `decrypt_failed`, `host_zero_psk`, `local_persist_failed`) |
| `qr_scan_state` | `{active}` | `db_core_qr_scan_start` / `stop` / the 120 s auto-stop |
| `qr_scanned` | `{text, invited}` | A decoded QR (2 s debounce per distinct payload); `invited` is true when a `doorbell-pair:` payload was auto-invited |
| `join_result` | `{ok, err}` | Emitted **before** `paired` / `pairing_state` (`err`: `already_paired`, `bad_pin`, `expired`, `no_token`, `host_unpaired`, `bad_payload`, `host_zero_psk`, `local_persist_failed`, `persist_failed`) |
| `paired` | `{psk_ref, psk_id, seeds}` | Only after `secure_put` succeeded; never carries the PSK |
| `pairing_persistence_error` | `{reason}` | `secure_put` failed; state becomes `persist_error` |
| `pairing_revoked` | `{by}` | Administrator removed this device |

Pairing HTTP routes all require an admin session (they are not public prefixes); older routes are
kept for existing shells. `GET /api/pairing` returns the snapshot above.
`POST /api/pairing/start {seconds}` opens the bulk-add window and mints a PIN in one step
(`{ok,host,pin,expires_s}`; 409 `host_unpaired` while unpaired). `/stop` closes the bulk-add window
and leaves a live PIN alone, so a device already typing the code is not locked out. `/deny {id}`
drops one pending device and ignores it for ten minutes (400 `no_id`). `/retry-persist` re-runs
`secure_put` after `persist_error` and is an idempotent success on a node that is already `ready`.
`/unpair` leaves the cluster. `/scan {text}` is the paste fallback for a browser without a camera
in a secure context (400 `bad_qr`). `POST /api/pairing/mode` on an unpaired node answers 409
`host_unpaired` instead of `ok`.

`psk_source` is `none` only when no key is configured; a node holding a key that was supplied
without a declared provenance reports `boot_plaintext`.

`boot.json` may carry `model` and `platform`; they are announced in the pairing beacon and shown
on the device card the inviter renders. The `db_platform_v2` SPI gained an optional trailing
`secure_delete(user, key)`; a shell that still reports the pre-`secure_delete` `struct_size` keeps
working and simply leaves an orphaned secret behind on unpair.

Deferred to a later rework (TODO): a cluster fingerprint/identity shown next to the membership
count, persisting `pair_sk` so a device's Add QR survives a reboot, and a cap on how many devices
one bulk-add window may auto-add.

## Events (events table / gossip)

- ID = `(origin_node, origin_seq)`, idempotent. Types include `press | purpose_selected |
  call_answered | call_ended | call_cancelled | motion | reply | offline | online |
  config_changed | emergency | emergency_cancel | delivery_result | visitor_lang`.
- `call_answered` and `call_ended` carry schema version, `door`, `call_id`, and `stage_revision`.
  A manual-answer client claims only its answer-mode SIP dialog after connection; Core persists one
  deterministic `dialog_owner`. A losing simultaneous dialog hangs up without ending the winner,
  and a monitor session never claims ownership. `call_answered` stops the ring timeout and moves
  only the exact call to `in_call`; visitor cancellation is then rejected. Owner hangup emits
  `call_ended`. After restart, the press origin owns ringing recovery and `dialog_owner` owns
  in-call recovery; failure within ten seconds emits one idempotent recovery cancellation.
- `emergency` payload: `{ "source": "<node_id>", "via": "panel|web|admin" }`. State always
  replicates. Presentation is produced only by matching rule actions. `never_suppress:true` exempts
  that action from quiet hours; it does not force a recipient or override an explicit empty channel
  list.
- A legacy `device_alert` action with no `targets` object addresses all native nodes and all Web
  subscription groups. Once a `targets` object is present, its selectors are explicit: one
  containing only `web_subscription_groups` addresses no native shell, while one without
  `web_subscription_groups` addresses no active Web page or Push subscription. `web_profiles` is a
  read-only compatibility alias; new writes use `web_subscription_groups`. Web pages obtain their
  group from `?group=<name>`, persist it locally, and use the same value for state polling and Push.
- While `emergency.web_active_page_alerts` is true and SOS remains active, a non-sticky rule TTL
  expires custom decoration and sound only; the safe red raw-SOS overlay remains until clear or
  until that switch is disabled. TTL never clears replicated emergency state.
- Core `delivery_result` records a dispatch attempt such as `local_shell:dispatched`,
  `shell_unavailable`, `web_push:accepted`, `no_recipients`, or `backend_unavailable`. It is not
  evidence that the OS displayed an alert. Each native shell separately publishes per-channel
  presentation status under runtime `device_alert`, including applied visual/sound, permission,
  TTL expiry, and limitations.
- `visitor_lang` (a visitor switched language at the door station): payload `{ "lang": "en" }`. The
  press payload also carries `visitor_lang` (when a selection was made). Displayed on: the language
  badge on indoor/TV ring screens, /api/panel/state, the "🌐 EN" in Telegram notifications, and the
  HA attrs topic. **Quick replies are shown + spoken via TTS using this language's labels**
  (falling back to ja when no translation exists). When the revert timer expires, it returns to ja
  and clears.
- `reply` event payload: `{ "schema_version": 2, "reply_id": "qr_away", "text": "…",
  "via": "telegram|mqtt|web", "call_id": "…", "stage_revision": 0 }`. A reply for a
  schema-v2 call must carry the exact call identity and revision; legacy unscoped replies remain
  display-only while a call is active and never terminate a call.
- press notify (LWW merge): `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`
- **Call history (呼出履歴).** `call_projection` materializes one row per call. The outcome is
  derived, never stored: `ended`+`reply` → `replied`; any other `ended` → `answered`;
  `cancelled`+`timeout` or `recovery_*` → `missed`; any other `cancelled` → `cancelled`.
  Concurrency losers (`concurrent_press_loser`, `concurrent_answer_loser`), fenced calls
  (`terminal_fence`), and calls that are still `ringing`/`in_call` never appear. `answered_by` is
  the projected `dialog_owner` and `duration_ms` is `ended_wall_ms − answered_wall_ms`.
- Read it with `GET /api/call-log?since_ms&before_ms&limit&door&outcome` (panel credential or
  admin session) or with the `db_core_call_log_json` C ABI. `since_ms` is an inclusive lower bound
  on a row's timestamp and `before_ms` an exclusive upper bound for paging older; rows are newest
  first and `limit` is clamped to 500.
- The **seen watermark** is device-local and never replicates: `POST /api/call-log/seen
  {"up_to_hlc":"…"}` (empty marks everything seen) or `db_core_call_log_mark_seen`. It only ever
  moves forward. `unread_missed` counts missed calls newer than it and is what the idle-screen
  badge shows. `{"t":"call_log_changed","unread_missed":N}` follows every call-lifecycle event and
  every watermark move.
- `call_missed` is a **virtual rule trigger**: no node emits it. A `call_cancelled` event whose
  reason is `timeout` or `recovery_*` matches both `call_cancelled` and `call_missed`, so existing
  rules keep working. The seeded `r_missed_call_default` turns it into a `device_alert` on indoor
  roles and Web Push, and can be disabled in the Admin rules tab.
- `GET /api/events` accepts `since_ms`, `type`, and `door`, and every row carries `origin`, `seq`,
  and `hlc` alongside the existing fields.
- **Retention.** `events.retention_days` (1..3650, default 90) is the age floor of the local
  retention sweep, which also always keeps the newest 5,000 records per origin. Deletion further
  requires that the record is applied, dispatched, and covered by a durable replication coverage
  vector; no such vector is produced yet, so pruning is still a logged no-op in practice.

## MQTT (Phase 2 — implemented)

The plan's topic table + `doorbell/<door_id>/reply/set` (subscribed; payload = a scoped JSON object
`{"reply_id":"qr_away","call_id":"<call-id>","stage_revision":0}` for an active call, or a
legacy reply_id/free-text announcement only when no call is active). Implementation:
`core/src/bridge/` (mqtt_client = homegrown MQTT 3.1.1 QoS0, ha_bridge = HA integration).

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
- MQTT authentication uses `user` plus `pass_ref`; the referenced value is resolved from the
  platform secure store immediately before configuring the bridge. Plaintext `pass` writes are
  rejected for new configuration and remain migration-only input.

## Unified Asset API / Visitor Language API (details finalized in the implementation)

- `POST /api/assets?type=<mime>&label=<name>` (admin session required) — body is raw bytes.
  Allowed types are only `image/jpeg` `image/png` `audio/mpeg` `audio/wav`, limit 3MB.
  Response `{"hash":"<sha256>"}`. Empty body=400 / disallowed type=415 / over limit=413 /
  not logged in=401. Registration writes the ledger entry `assets.<hash>` =
  `{size,type,origin,label}`, replicated to all nodes via CRDT.
- `GET /asset/<sha256>` — LAN-public compatibility read; it does not use an admin or panel
  credential. Only a GET whose path contains exactly 64 lowercase hex digits after `/asset/` is
  admitted without a session. A missing valid hash is 404; authenticated malformed hashes are 400.
  Other methods and asset-shaped paths do not receive this public access (path-traversal defense).
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

### The background dimming layer

`display.theme.backdrop` controls the semi-transparent layer a shell draws between the background
image and everything on top of it, which is what keeps a clock legible over a bright photograph.
`enabled` (default true), `color` (`#RRGGBB`, default `#000000`) and `opacity` (0-100, default 62)
are each overridable per device under `devices.<id>.local.theme.backdrop.*`, and each resolves on
its own: a panel in a brighter room can raise the opacity without restating the colour.

Core publishes the resolved answer as
`status.display.theme.backdrop = {enabled, color, opacity, source}`, where `source` is `device`,
`admin` or `default` -- the strongest origin among the three values. The same object rides in the
`display` UI event, so a shell paints from what core resolved rather than reading configuration
itself.

A write with a malformed colour or an opacity outside 0-100 is refused. Turning the layer off, or
down below 20, is accepted but reported as a warning (`theme.backdrop_weak`) while a background
image is configured: over a bright picture that is usually a mistake, and over a dark one it is
not, and core cannot tell which.

`display.theme.glass.blur_radius` is an integer from 0 through 40, defaults to 24, and may be
overridden at `devices.<id>.local.theme.glass.blur_radius`. Core publishes the resolved value and
its `default|admin|device` source in `status.display.theme.glass`. Only a client advertising
`frosted_glass_radius_v1` applies it. Modern iOS deliberately does not advertise that capability:
it keeps `UIBlurEffect`, whose radius is system-managed and has no public numeric setting.
