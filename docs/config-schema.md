# 設定スキーマ (正準リファレンス)

設定は LWW-Map CRDT のフラットな key→JSON。キーはドットパス。以下は materialize 後の全体像。
`*_ref: "secret:…"` は secrets 名前空間 (管理画面では書込のみ・表示不可、platform secure store 保管)。

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // 同一 L2 なので保険 (beacon が主)
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
      "door": "d_front",                        // indoor_panel は null
      "platform": "windows",
      "caps_override": { "mains_power": true }, // 実測 capability の管理上書き
      "local": {                                // 端末別設定 (これも複製 — 遠隔変更可)
        "ui_lang": "ja", "volume": 80, "screen_brightness": 70,
        "screensaver_after_s": 120,
        "camera": { "device_hint": "", "rotation": 0, "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480" },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "motion": { "enabled": true, "sensitivity": 40, "min_interval_s": 30 },
        "aec": { "mode": "auto", "tail_ms": 0 }  // 装機標定で書込
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
    "accounts": { "<node_id>": { "user": "door-front", "pass_ref": "secret:sip.<node_id>" } },
    // DTMF 機能碼 (通話中の相手キー → アクション; 実行体は mesh/MQTT 側)
    "dtmf_actions": { "*1": { "type": "ha_command", "command": "unlock", "door": "self" },
                      "*0": { "type": "hangup" } }
  },

  "quick_replies": {                            // クイック返信 (ユーザー編集可能)
    "qr_away":    { "label": { "ja": "ただいま留守にしています", "en": "We are away right now",
                               "zh": "现在不在家" }, "speak": true, "order": 1 },
    "qr_no":      { "label": { "ja": "結構です", "en": "Not interested",
                               "zh": "不需要，谢谢" }, "speak": true, "order": 2 },
    "qr_wrong":   { "label": { "ja": "お間違いのようです", "en": "Wrong address",
                               "zh": "您可能找错地方了" }, "speak": true, "order": 3 },
    "qr_wait":    { "label": { "ja": "少々お待ちください", "en": "One moment please",
                               "zh": "请稍等" }, "speak": true, "order": 4 }
  },
  "reply": { "display_ttl_s": 30 },             // 面板表示時間

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
                  "poll_updates": true,          // inline ボタン返信の getUpdates 長輪詢 (leader)
                  "text_template": { "ja": "{door} に来客です ({time})" } },
    "tz_offset_min": 540                         // JST。スケジュール判定に使用
  }
}
```

## イベント (events テーブル / gossip)

- ID = `(origin_node, origin_seq)` 冪等。型: `press | motion | answered | missed | reply |
  offline | online | config_changed`
- `reply` イベント payload: `{ "reply_id": "qr_away", "text": "…", "via": "telegram|mqtt|web",
  "target_press": "<origin>:<seq>" }`
- press の notify (LWW マージ): `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`

## MQTT (Phase 2)

計画書の topic 表 + `doorbell/<door_id>/reply/set` (購読; payload = reply_id または自由文)。
