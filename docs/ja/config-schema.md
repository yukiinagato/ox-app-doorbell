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
        "video": { "playback": "low_latency" }, // low_latency（既定）/ hls / mjpeg
        "camera": { "device_hint": "", "rotation": 0, "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto"=ハードウェアエンコード (h264) を検出し不可なら mjpeg / "mjpeg" / "h264"
                    // h264 時は /stream.mp4 (fMP4, プラットフォームの HW エンコーダ) が有効になり
                    // resolution/fps は h264_* 系で別指定 (Phase 6)
                    "codec": "auto", "h264_resolution": "640x360", "h264_fps": 30,
                    "h264_bitrate_kbps": 700 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "motion": { "enabled": true, "sensitivity": 40, "min_interval_s": 30 },
        "aec": { "mode": "auto", "tail_ms": 0 },  // 設置時キャリブレーションで書込
        // TV モニタ端末 (Android TV 常駐 app) の目印。運用ノート:
        //   - role=indoor_panel + tv:true。chime で来客モニタ画面が前面に重なり、
        //     門口機のライブ映像 (MJPEG) + 門口機のマイクの直接モニタリング (sip.direct_port へ
        //     X-Doorbell-Mode: monitor の直接発呼 — Asterisk 不要・dialplan 変更不要)。
        //   - D-pad でクイック返信 (quick_replies を order 順に表示)。
        //   - 導入手順: deploy/provision/android/provision.ja.md の「Android TV」節。
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
    // accounts.<node_id>.user = その端末の内線番号。門口機 (8001..) と室内機 (201..) の両方が
    // ここに載る — 通話中の相手映像は user(内線)→node_id→peers[].stream の逆引きで解決する。
    // answer_mode: "auto"(門口機既定 — 即応答) | "ring"(室内機既定 — 着信 UI で手動応答)
    "accounts": { "<node_id>": { "user": "door-front", "pass_ref": "secret:sip.<node_id>",
                                 "answer_mode": "auto" } },
    // 直接発呼 (Asterisk 非経由) の待受 UDP ポート。各子機の sipctl が固定 listen し、
    // 室内機/TV はここへ "sip:<host>:47190" で直接 INVITE する (PBX 障害時も通話/モニタリングが
    // 生きる自己修復方針)。X-Doorbell-Mode: monitor = 一方向モニタリング / answer = 双方向。
    // server や自機 accounts が未設定でも直接発呼だけは動く。
    "direct_port": 47190,
    // DTMF 機能コード (通話中の相手キー → アクション; 実行体は mesh/MQTT 側)
    "dtmf_actions": { "*1": { "type": "ha_command", "command": "unlock", "door": "self" },
                      "*0": { "type": "hangup" } }
  },

  "ui": {
    "languages": ["ja", "en", "zh"],            // 門口機の来訪者言語切替に出す言語
    "ringtone": "ding1",                          // ding1 / ding2 / classic / asset:<sha256>
    "visitor_lang_revert_s": 60                 // 無操作でこの秒数後に主言語 (ja) へ自動復帰
  },
  // 文言の実行時上書き (組込 resx/strings.xml より優先)。管理画面「文言」タブ /
  // 室内機の簡易エディタから編集 → CRDT 即時 push (LAN 内ミリ秒級) → 門口機が再描画。
  // プレースホルダ {name} は編集側で整合検証。キーは i18n/strings.yaml と同一。
  "i18n_overrides": {
    "ja": { "idle.touch_to_call": "タッチして呼び出してください" },
    "en": {}
  },

  // 統一資産台帳: 背景画像 + カスタム音声 (wav/mp3 ≤3MB) の blob 目録。実体は各ノードの
  // assets/ ディレクトリ。**設定変更時に各ノードが参照中の hash を能動的にプリフェッチ**
  // (mesh FETCH_BLOB — 保持ノードならどこからでも) → 再生/表示は常にローカルファイル =
  // ミリ秒級。管理画面はノード毎のキャッシュカバー率を表示。
  "assets": {
    "<sha256>": { "size": 123456, "type": "image/jpeg | audio/mpeg | audio/wav",
                  "origin": "<node_id>", "label": "桜.jpg" }
  },

  "display": {                                  // 表示・焼付対策 (全端末既定; devices.<id>.local.display で上書き)
    // theme: 門口機の背景 (室内機/管理画面から「プッシュ配信」= この設定を書くだけ。CRDT で即時同期)
    "theme": { "bg_color": "#101418", "bg_image": null },   // bg_image: assets の sha256 or null
    "brightness": 70,                           // 0-100 (遠隔調整 — 管理画面のスライダー)
    "night": { "enabled": true, "from": "22:00", "to": "06:00",
               "brightness": 15, "red_tint": true },   // 夜間モード (補正済み時計で判定)
    "screensaver_after_s": 120,                 // 無操作でスクリーンセーバ (時計表示の移動・低輝度)
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

  "visit_purposes": {                           // 来訪者の用件ボタン (ユーザー編集可能; 既定 seed 下記)
    // 門口機では用件ボタン 1 タップ = その用件付きの呼出 (宅配員は 1 動作で完了)。
    // 大ボタン「呼出」は用件なしの汎用呼出。ラベルは来訪者言語に追従。
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1 },
    "p_delivery": { "label": { "ja": "宅配便",     "en": "Delivery", "zh": "快递" }, "icon": "📦", "order": 2 },
    "p_mail":     { "label": { "ja": "郵便",       "en": "Mail",     "zh": "邮件" }, "icon": "✉️", "order": 3 },
    "p_sales":    { "label": { "ja": "営業・集金", "en": "Sales",    "zh": "推销/收费" }, "icon": "💼", "order": 4 },
    "p_work":     { "label": { "ja": "検針・工事", "en": "Utility",  "zh": "检修/施工" }, "icon": "🔧", "order": 5 },
    "p_other":    { "label": { "ja": "その他",     "en": "Other",    "zh": "其他" }, "icon": "❓", "order": 6 }
  },
  // press イベント payload に "purpose": "<id>" が載る。表示先: 室内/TV 着信バッジ・
  // Telegram (アイコン+用件名)・HA event payload・panel state・管理画面。
  // ルール連携: trigger_rules.when.purposes: ["p_delivery"] で用件別分岐、
  // 新アクション { "type": "auto_reply", "reply_id": "qr_okihai" } = 門口機が自動で
  // クイック返信を表示+TTS (例: 宅配→「置き配をお願いします」+ 電話は鳴らさない)。

  // quick_replies 各項は任意で "audio": {"ja": "<sha256>", "en": "<sha256>"} を持てる —
  // 来訪者言語に合わせたカスタム音声で再生 (優先度: キャッシュ済 audio → システム TTS → 通知音)。
  // auto_reply アクションも同じ音声を継承。chime の sound は "asset:<sha256>" 形式で
  // カスタム音対応、emergency.alarm_sound も同様。
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
  "reply": { "display_ttl_s": 30 },             // パネル表示時間

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
                  "poll_updates": true,          // inline ボタン返信の getUpdates ロングポーリング (leader)
                  "text_template": { "ja": "{door} に来客です ({time})" } },
    // Web 通話 (webui/panel/call.html — 任意機能)。ブラウザは SIP/UDP を話せないため
    // Asterisk を WebRTC ゲートウェイに使う (deploy/asterisk/webrtc.ja.md)。
    // ws_url 空 = 通話ボタン無効 (映像閲覧・映像送信は SIP と独立に動く)。
    // sip_user/sip_pass = ブラウザ用内線 (webrtc.ja.md の [260] テンプレート)。
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260", "sip_pass": "…" },
    "tz_offset_min": 540                         // JST。スケジュール判定に使用
  }
}
```

## イベント (events テーブル / gossip)

- ID = `(origin_node, origin_seq)` 冪等。型: `press | motion | answered | missed | reply |
  offline | online | config_changed | emergency | emergency_cancel | visitor_lang`
- `emergency` payload: `{ "source": "<node_id>", "via": "panel|web|admin" }`。quiet_hours の
  suppress 対象外 (常に全経路通知)。UI: `{"t":"emergency","active":true|false}`
- `visitor_lang` (来訪者が門口機で言語を切替): payload `{ "lang": "en" }`。press の payload にも
  `visitor_lang` を同梱 (選択済みの場合)。表示先: 室内機/TV 着信画面の言語バッジ・
  /api/panel/state・Telegram 通知の「🌐 EN」・HA attrs topic。**クイック返信はこの言語の
  ラベルで表示+TTS** (訳が無ければ ja へフォールバック)。revert タイマー超過で ja へ戻り解除。
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
  `binary_sensor.doorbell_node_<node_id 先頭8桁>` (connectivity — 盗難対策の端末切断検知)、
  加えて `binary_sensor.doorbell_bridge_online` (LWT 由来、deploy/ha のウォッチドッグが参照) と
  `binary_sensor.doorbell_emergency` (device_class safety、state_topic `<base>/emergency`
  retain — SOS 緊急モード。ON/OFF は emergency / emergency_cancel の hlc 最大側)。
- スナップショット/カメラは MQTT に載せない — ライブ映像は go2rtc、静止画は HA generic camera
  が門口機の `/snapshot.jpg` を直接取る (`deploy/ha/` 参照)。
- MVP は認証 `user`/`pass` 平文 (`pass_ref` の secure store 化は sip と同時に対応予定)。

## 統一資産 API / 来訪者言語 API (実装で確定した細部)

- `POST /api/assets?type=<mime>&label=<name>` (管理セッション必須) — body は生バイト列。
  許可 type は `image/jpeg` `image/png` `audio/mpeg` `audio/wav` のみ、上限 3MB。
  応答 `{"hash":"<sha256>"}`。空 body=400 / 許可外 type=415 / 上限超=413 / 未ログイン=401。
  登録すると台帳 `assets.<hash>` = `{size,type,origin,label}` が書かれ CRDT で全ノードへ複製される。
- `GET /asset/<sha256>` — 管理セッション **または** panel token (`?k=`) で取得可 (403/404)。
  `<sha256>` は 64 桁小文字 hex 固定で、それ以外は 400 (パス走査対策)。
- `DELETE /api/assets/<sha256>` (管理セッション) — 台帳 `assets.<hash>` を tombstone にし、
  自ノードのローカルキャッシュも即削除する。他ノードは台帳消滅 (CRDT 複製) を見て
  猶予付き GC で自然に回収する。
- プリフェッチは「台帳に載った時」ではなく「設定から参照された時」— 参照元は
  `display.theme.bg_image` / `devices.*.local.theme.bg_image` / `quick_replies.*.audio.*` /
  chime の `sound:"asset:<hash>"` / `emergency.alarm_sound`。取得完了で
  `{"t":"asset_ready","hash":"<sha256>"}` を uiNotify (UI シェルはこれで再描画/再読込する)。
  `/api/status` の `assets: {cached,total}` がノード毎のキャッシュカバー率。
- `POST /api/panel/visitor-lang?lang=<ja|en|zh>[&door=<id>]` (panel token) — door 省略時は
  自機担当 door。`lang=ja` は即時復帰。無操作 `ui.visitor_lang_revert_s` 秒で自動的に ja へ戻る
  (呼出で計時やり直し)。現在値は `/api/panel/state` の各 door の `visitor_lang`
  (ja のときはキー自体が出ない) と `/api/status` の `visitor_lang.<door>`。
- 開発投入: `doorbell_host --add-asset <file> [--asset-type <mime>] [--asset-label <name>]`
  (type 省略時は拡張子から推定、hash を stdout へ)。
- MQTT 追加分: press の event payload は `{"event_type":"press","purpose":…,"visitor_lang":…}`
  (purpose/visitor_lang は該当時のみ)。`<base>/<door_id>/attrs` に
  `{"visitor_lang":"ja|en|zh"}` を retain で発行し、`sensor.doorbell_<door>_visitor_lang` として
  discovery する。Telegram の press 通知は先頭行に `{icon} {用件名}` と来訪者言語バッジ `🌐 EN`。
