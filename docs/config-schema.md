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
    // accounts.<node_id>.user = その端末の内線番号。門口機 (8001..) と室内機 (201..) の両方が
    // ここに載る — 通話中の相手映像は user(内線)→node_id→peers[].stream の逆引きで解決する。
    // answer_mode: "auto"(門口機既定 — 即応答) | "ring"(室内機既定 — 着信 UI で手動応答)
    "accounts": { "<node_id>": { "user": "door-front", "pass_ref": "secret:sip.<node_id>",
                                 "answer_mode": "auto" } },
    // DTMF 機能碼 (通話中の相手キー → アクション; 実行体は mesh/MQTT 側)
    "dtmf_actions": { "*1": { "type": "ha_command", "command": "unlock", "door": "self" },
                      "*0": { "type": "hangup" } }
  },

  "display": {                                  // 表示・焼付対策 (全端末既定; devices.<id>.local.display で上書き)
    "brightness": 70,                           // 0-100 (遠隔調整 — 管理画面のスライダー)
    "night": { "enabled": true, "from": "22:00", "to": "06:00",
               "brightness": 15, "red_tint": true },   // 夜間モード (補正済み時計で判定)
    "screensaver_after_s": 120,                 // 無操作でスクリーンセーバ (時計漂移・低輝度)
    "pixel_shift_s": 300                        // 待機画面要素を数 px 周期移動 (焼付対策)
  },

  "emergency": {                                // 室内緊急求助 (SOS)
    "button_on_roles": ["indoor_panel"],        // SOS ボタンを表示する役割
    "hold_to_trigger_s": 3,                     // 長押し秒数 (誤操作防止)
    "alarm_sound": "siren1", "alarm_volume": 100,
    "sip_call": { "enabled": false, "target_extension": "" },  // 任意: Asterisk でユーザー定義先へ発呼
    "cancel_requires_pin": true                 // 解除に kiosk PIN
  },
  // emergency の既定挙動 (ルール非依存の組込動作): 全ノード警報 UI+サイレン、
  // Telegram 🚨 を全 households へ、MQTT doorbell/emergency (retain) — HA 側でライト/サイレン/
  // 発呼など自由に連動。**警察・消防への自動発信は行わない** (通知先は家族と
  // ユーザー定義の電話先のみ — 判断は人が行う)。

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
  offline | online | config_changed | emergency | emergency_cancel`
- `emergency` payload: `{ "source": "<node_id>", "via": "panel|web|admin" }`。quiet_hours の
  suppress 対象外 (常に全経路通知)。UI: `{"t":"emergency","active":true|false}`
- `reply` イベント payload: `{ "reply_id": "qr_away", "text": "…", "via": "telegram|mqtt|web",
  "target_press": "<origin>:<seq>" }`
- press の notify (LWW マージ): `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`

## MQTT (Phase 2 — 実装済み)

計画書の topic 表 + `doorbell/<door_id>/reply/set` (購読; payload = reply_id または自由文)。
実装: `core/src/bridge/` (mqtt_client = 自前 MQTT 3.1.1 QoS0、ha_bridge = HA 統合)。

- 有効条件: `integrations.mqtt.host` 非空 かつ mesh の `mqtt_bridge` duty leader。
  leader 交代・設定変更で自動 start/stop。`/api/status` に `bridge.mqtt =
  connected|disconnected|inactive`。
- 接続時: LWT=`<base>/bridge/availability`=offline(retain) → online(retain) →
  全 discovery (retain) → 現在状態 (door/node availability) → 購読
  (`<prefix>/status`・`<base>/+/reply/set`・`<base>/cmd/ack`)。`<prefix>/status`="online"
  (HA 再起動) で discovery+状態を全再発行。
- Discovery entity (object_id/unique_id は ASCII、日本語は name のみ):
  door 毎に `event.doorbell_<door_id>` (device_class doorbell) と
  `binary_sensor.doorbell_<door_id>_motion` (off_delay 30)、device 毎に
  `binary_sensor.doorbell_node_<node_id 先頭8桁>` (connectivity — 防盗の端末断)、
  加えて `binary_sensor.doorbell_bridge_online` (LWT 由来、deploy/ha の看門狗が参照)。
- スナップショット/カメラは MQTT に載せない — 実画は go2rtc、静止画は HA generic camera
  が門口機の `/snapshot.jpg` を直接取る (`deploy/ha/` 参照)。
- MVP は認証 `user`/`pass` 平文 (`pass_ref` の secure store 化は sip と同時に対応予定)。
