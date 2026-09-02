# 設定スキーマ (正準リファレンス)

設定は LWW-Map CRDT のフラットな key→JSON。キーはドットパス。以下は materialize 後の全体像。
`*_ref: "secret:…"` は secrets 名前空間 (管理画面では書込のみ・表示不可、platform secure store 保管)。

`boot.json` は CRDT ではなく端末ローカルの bootstrap profile です。Android、iOS/iPadOS
（iOS 5 compatibility を含む）、Windows は、新規 profile、明示的な `setup_complete:true` の欠落、`role` の欠落/不正、または
`door_station` の有効な `door` 欠落を検出すると、Core 起動前に blocking setup screen を表示します。
operator は `door_station` / `indoor_panel` を選択します。door 欄は door station のみ必須で、
そのまま確定できる random `door-xxxxxxxx` が初期入力されます。有効な door ID は 1～64 文字、先頭が
ASCII 英数字、以降が英数字・`_`・`-` です。保存成功時だけ `setup_complete:true` を atomic に書きます。
tvOS は対応する door-camera role がないため、意図的に `indoor_panel` 固定です。

mesh PSK は CRDT 値ではなく端末ローカルの bootstrap data。Core は先に
`secure_put("mesh.psk", …)` を完了し、shell へ
`{"t":"paired","psk_ref":"secret:mesh.psk"}` だけを通知します。shell は opaque reference と秘密でない
`seed_peers` を `boot.json` に保存し、新しい `psk_hex` は受け取りません。secure store 失敗時は
`pairing_persistence_error` を通知して not-ready のままにします。旧 `psk_hex` は移行入力専用です。

Web Push subscription は暗号化した例外です。Core は complete `endpoint`/`p256dh`/`auth` を
mesh-PSK-derived key と XChaCha20-Poly1305 で seal した schema-v2 CRDT record として保存し、
materialized config/export に plaintext を出しません。起動時は legacy raw record を再 seal し、
できなければ fail-closed で削除します。

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // 同一 L2 なので保険 (beacon が主)
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
                 // 任意のお知らせ。その門口の来訪者画面と室内ダッシュボードに表示する。
                 // text は 1-200 文字、expires_ms は絶対時刻 (ミリ秒) で 0 は「取り消すまで」。
                 // 期限切れは 1 分ごとの tick で削除し notice_changed を送出する。
                 "notice": { "text": "本日は勝手口へお願いします",
                             "from_device": "<node_id>", "created_ms": 0, "expires_ms": 0 } },
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
        // 端末ごとの音量上書き (0-100)。無いレベルは audio.volume を継承する。
        "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },
        "screensaver_after_s": 120,
        "video": { "playback": "low_latency",   // low_latency（既定）/ hls / mjpeg
                   "rotation": "auto" },          // auto=姿勢センサ追随 / 0 / 90 / 180 / 270（管理者固定）
        "camera": { "device_hint": "", "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto"=ハードウェアエンコード (h264) を検出し不可なら mjpeg / "mjpeg" / "h264"
                    // h264 時は /stream.mp4 (fMP4, プラットフォームの HW エンコーダ) が有効になり
                    // resolution/fps は h264_* 系で別指定 (Phase 6)
                    "codec": "auto", "h264_resolution": "640x360", "h264_fps": 30,
                    "h264_bitrate_kbps": 700 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "recovery": { "helper_mode": "auto" }, // off | auto | on
        // semantic override は element 単位の完全な object。native shell は top-level
        // ui_manifest、同じ node の Web panel は status.web_ui.manifest で検証する。
        "ui": { "elements": {
          "call.primary": { "scale": 1.1, "foreground": "#FFFFFF",
                            "background": "#1A2027", "accent": "#4DA3FF" },
          "cancel.call": { "scale": 1.0, "foreground": "#FFFFFF",
                           "background": "#8D2932" }
        } },
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

  // 外部 media source は明示設定し、seed_peers から推定しない。URL userinfo と plaintext
  // credential は拒否し、認証は secret_ref を使う。
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

  // 受信側の再生方針。配列順が優先度で、disabled の方式は即座に読み飛ばす。
  // pair 設定は該当する室内機×門口機の global 設定を全体置換する。
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
    "call_flow": "purpose_first",             // purpose_first | ring_then_purpose
    "languages": ["ja", "en", "zh"],            // 門口機の来訪者言語切替に出す言語
    "launch_sound": "title_display",             // 起動音。空文字 = 再生しない
    "call_sound": "outdoor_call_alert",          // 門口機の呼出確認音。空文字 = 再生しない
    "call_sound_loop": false,                     // 応答または 30 秒タイムアウトまで循環
    "button_sound": "button_click",              // その他のボタン音。空文字 = 再生しない
    "update_sound": "indoor_update",             // 呼出取消/訪問目的など追加通知の音
    "ringtone": "school_chime",                  // school_chime / ding1 / ding2 / classic / asset:<sha256>
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

  // クラスタの時刻。IANA ゾーンは core に同梱した表で解決するため、tz データベースを持たない
  // プラットフォームのシェルでも他の端末と同じ時計を表示できる。下の integrations.tz_offset_min
  // は引き続き有効で、"zone" が設定されていればそこから (夏時間を含めて) 導出される。ゾーンを
  // 一度も設定していない設置では従来どおり固定オフセットが真の値。
  "time": {
    "zone": "Asia/Tokyo",                       // 同梱表に含まれる IANA 識別子
    // 独立時刻サービス。core は OS の時計を変更せず、SNTP で測ったオフセットをすべての
    // wall-clock 読み出し (HLC、イベントと呼出履歴のタイムスタンプ、ルールのスケジュール、
    // 静音時間帯、画面の時計) に加算する。同期が 3 間隔続けて失敗するとオフセットは破棄する。
    "ntp": { "enabled": false,                  // 既定は無効
             "servers": ["ntp.nict.jp", "time.google.com"],   // 1-4 個の "host" / "host:port"
             "interval_s": 900 }                // 60..86400
  },

  // クラスタ既定の音量 (0-100)。端末は devices.<id>.local.audio.volume.{call,sos,idle} で
  // 上書きする。sos はこのキーが無い旧設置のために emergency.alarm_volume にも fallback する。
  "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },

  "emergency": {                                // 室内緊急求助 (SOS)
    "button_on_roles": ["indoor_panel"],        // SOS ボタンを表示する役割
    "hold_to_trigger_s": 3,                     // 旧: 長押し秒数。slide モードでは未使用
    // スライドで発報するコントロール。mode は "slide" ("hold" も旧設定のため引き続き有効)。
    // countdown_s は 0..10 秒で、この間に取り消せる。0 になったとき core に発報を伝える。
    "trigger": { "mode": "slide", "countdown_s": 3 },
    "alarm_sound": "siren1", "alarm_volume": 100,
    // true なら recipient がゼロまたは Push-only rule でも、開いている Web panel は複製済み
    // active SOS を表示する。false でも一致する positive device_alert/Push は表示できる。
    "web_active_page_alerts": true,
    "sip_call": { "enabled": false, "target_extension": "" },  // 任意: Asterisk でユーザー定義先へ発呼
    "cancel_requires_pin": true                 // 解除に kiosk PIN
  },
  // SOS active/clear state は常に複製する。表示と外部配信は rule-driven で、recipient はゼロにも
  // できる。警察・消防への自動発信を意味しない。

  "visit_purposes": {                           // 来訪者の用件ボタン (ユーザー編集可能; 既定 seed 下記)
    // 門口機では用件ボタン 1 タップ = その用件付きの呼出 (宅配員は 1 動作で完了)。
    // 大ボタン「呼出」は用件なしの汎用呼出。ラベルは来訪者言語に追従。
    // "enabled": false は用件を削除せずに来訪者から隠す。文言・アイコン・並び順は残るので
    // 再度有効にすればそのまま戻る。既定は true。
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1, "enabled": true },
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
                         { "type": "ha_event" } ] },
    "r_sos_default_on": {
      "enabled": true, "when": { "type": "emergency_on" },
      "actions": [
        { "type": "device_alert", "targets": { "roles": "all", "web_subscription_groups": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "never_suppress": true,
          "presentation": { "visual": true, "sound": "siren1", "volume": 100,
                            "sticky": true, "ttl_s": 0, "background": "#8F1010",
                            "foreground": "#FFFFFF", "accent": "#FFD166" } },
        { "type": "telegram", "households": "all", "never_suppress": true }
      ]
    },
    "r_sos_default_off": {
      "enabled": true, "when": { "type": "emergency_off" },
      "actions": [
        { "type": "device_alert", "targets": { "roles": "all", "web_subscription_groups": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "never_suppress": true,
          "presentation": { "visual": true, "sticky": false, "ttl_s": 10 } },
        { "type": "telegram", "households": "all", "never_suppress": true }
      ]
    },
    // 初回のみ自動投入。不在着信 = reason が "timeout" または "recovery_*" の call_cancelled。
    // 室内ロールのみ: 室外機は来訪者に警報を出してはならない。
    "r_missed_call_default": {
      "enabled": true, "when": { "type": "call_missed" },
      "actions": [
        { "type": "device_alert",
          "targets": { "roles": ["indoor_panel"], "web_profiles": "all" },
          "channels": ["in_app", "system_notification", "web_push"],
          "presentation": { "visual": true, "sticky": false, "ttl_s": 30 } }
      ]
    }
  },

  // ローカルのイベント保持。各 origin の最新 5,000 件は常に残り、それより古いものは
  // クラスタ全端末が保持していることを複製が証明できた場合にのみ削除される。
  "events": { "retention_days": 90 },           // 1..3650、既定 90

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
    // Web Push は保守された HTTPS sender 経由で送信する。private 値は eligible leader candidate
    // ごとの local secure store に置き、reference だけを複製する。
    "web_push": { "sender_url": "https://push-sender.example/doorbell/send",
                  "vapid_public_key": "<base64url-public-key>",
                  "vapid_private_key_ref": "secret:webpush.vapid_private",
                  "vapid_subject": "mailto:doorbell@example.com",
                  "sender_secret_ref": "secret:webpush.sender" }, // optional sender bearer token
    // Web 通話 (webui/panel/call.html — 任意機能)。ブラウザは SIP/UDP を話せないため
    // Asterisk を WebRTC ゲートウェイに使う (deploy/asterisk/webrtc.ja.md)。
    // ws_url 空 = 通話ボタン無効 (映像閲覧・映像送信は SIP と独立に動く)。
    // sip_user/sip_pass_ref = ブラウザ用内線 (webrtc.ja.md の [260] テンプレート)。
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260",
                "sip_pass_ref": "secret:webrtc.260" },
    "tz_offset_min": 540                         // JST。スケジュール判定に使用
  }
}
```

Web Push backend は 2 段階で配備します。まず `web_push` duty の候補にする各 node の認証済み
`POST /api/secrets` で、同じ `vapid_private_key_ref` の実値を local secure store に書きます。sender が
Bearer token を要求する場合は `sender_secret_ref` も同様です。全 secret write の成功後にだけ、秘密で
ない `integrations.web_push` field と reference を atomic に保存します。sender URL は HTTPS 必須で、
`vapid_public_key` は `0x04` prefix を含む 65-byte の非圧縮 P-256 public point を base64url で
符号化した値でなければなりません。private 値を config/export/URL/log/command line に置きません。Push-only SOS に依存する前に、
`/api/status.web_push.delivery_backend:true`、非空の `leader`、および failover 候補ごとの実測
`web_push_ready` を確認します。`configured:true` だけでは、その leader が local secret を読めることや
sender へ到達できることの証明になりません。

leader election はさらに `tls12`、`wan`、`mains_power`、`wall_clock_sane`、`web_push_ready` を
すべて要求します。LAN/default route は Internet reachability の証拠ではなく、汎用 sender probe もないため、
shipping shell は fail-closed で `wan:false` を公開します。exact node/network から設定済み HTTPS sender
への egress を試験した後だけ、管理者は `devices.<id>.caps_override.wan:true` を明示できます。その外部
試験を measurement source として記録し、route 変更時は override を外します。`mains_power` の override は
固定電源を commissioning した場合だけにします。override で TLS support、読める secret、working backend
を捏造してはいけません。

iOS compatibility の `streams.h264` と `transport:"tcp"` は direct fMP4 URL ではなく bounded
RTSP/RTP interleaved ingest を選びます。runtime は `rtsp_ingest_pending` の degraded state から始まり、
DESCRIBE/SETUP と Core が実際に accept した Annex-B IDR の後だけ `rtsp_h264_forwarding` を advertise
できます。config だけでは availability の証拠にならず、iPad 1 + 実 camera qualification は未完了です。

`panel.token_refs` と非 secret の 32 桁 hex `panel.token_generation` は fleet 設定です。rotation は
両方を 1 commit で置換します。各 `dbpanel` session は現在の generation と canonical ref set に
紐付くため、rotation が複製されると全 node の session が無効になります。secret 実値は複製されません。
panel を配信する各 node の認証済み Admin で **このノードに配備** を使い、設定を変更せず、すでに
複製済みの同じ ref に同じ実値を書きます。

`devices.<id>.local.recovery.helper_mode` は設定上の request であり、helper の install/有効性の証拠では
ありません。Admin form の既定は `auto` で、認証済み atomic config batch として書き込み、Core は
`off`、`auto`、`on` 以外を拒否します。capability/runtime status は実測した helper availability と
effective mode を別に報告します。helper が届かない `on` は supervision 成功ではなく visible degraded/
error です。atomic config apply 後、platform client は fixed local `MODE <value>` を送り helper status を
確認します。helper は mode を原子的に保存し helper/OS restart 後も復元します。config から generic command/
argv を生成しません。

## 単一の管理パスワード・お知らせ・開錠・外観

`admin.password_hash` はクラスタ全体で唯一の管理者資格情報で、Web 管理画面と各端末の設定画面は
同じ秘密を使う。`{"salt":"<hex>","hash":"<hex>","algo":"blake2b-256","updated_ms":…}` として複製し、
平文は決して保存しない。したがってオフラインの端末も手元の複製で照合できる。どの画面でも最初に
入力されたパスワードがクラスタのものになる (Web ログインの既存の TOFU 経路)。どこかで 5 回失敗すると
すべての画面が 10 分間停止する。カウンタは `POST /api/login` と `db_core_admin_password_verify` で共有する。

このキーが無かった頃は各ノードがローカルにダイジェストを持ち、キオスクは別の終了コードを持っていた。
そのローカルダイジェストは最初の照合成功まで有効で、成功した時点でクラスタのパスワードとして複製する。
独自の `exit_pin.txt` ダイジェストを持つシェルは、`db_core_admin_password_verify` が成功または「未設定」を
返した時点で参照をやめて削除すること。パスワードを変更しても別の入口が残るのを防ぐため。

**パスワード未設定のときに SOS の解除を妨げてはならない。** `status.emergency.cancel_requires_password`
を読むこと。core が `emergency.cancel_requires_pin` とパスワードが実際に設定されていることの
両方から計算する。`emergency.cancel_requires_pin` だけで解除を止めると、自宅の警報を自分で
止められなくなる。

`notice.global` はクラスタ全体のお知らせで、`doors.<id>.notice` が門口ごとに上書きする。
`status.doors.<id>.notice` は解決後の値を `scope` (`door` / `global`) 付きで返す。
`notice.presets` は管理者が編集できる最大 8 件の `{id, text}` で、お知らせダイアログはこれを描画する。
初回に 3 件を seed するが、以後は自由に編集・削除できる。

`doors.<id>.unlock.show_button` は開錠コントロールを表示するかを決める。既定は
「動作するときだけ表示する」で、`doors.<id>.unlock.command` か `sip.dtmf_actions` の最初の
`ha_command` があるときだけ true。管理者はどちらにも固定できる。`status.doors.<id>.unlock` は
`configured` / `command` / `show_button` と、その答えが既定と管理者のどちらに由来するかを返すので、
押される前に判断できる。`POST /api/doors/<id>/open` と `db_core_open_door` は SIP の特番と同じ
`ha_command` を送出し、未設定なら黙って何もせず `unlock_not_configured` を返す。

`display.appearance` は `auto_system` / `auto_schedule` / `light` / `dark`。
`display.appearance_schedule = {dark_from, light_from}` は `time.zone` で評価する。どちらも
クラスタ既定と `devices.<id>.local.display` の両方に置ける。公開する契約には `follow_system` があり、
true なら OS 自身の設定を優先する。OS に設定が無いプラットフォーム (iOS 5、Android 10 未満) は
スケジュールの結果を使う。

`boot.json` で門口を指定した門口機は、`doors.<door>` が無ければ自分で作成する。クラスタの作成時と
参加時、そしてペアリング済みで起動するたびに確認し、端末名を 3 言語のラベルとして書き込む。これが
無いと、作成直後のクラスタは `devices.<id>.door` が存在しない門口を指し、`status.doors` は空になり、
門口をキーとするすべての面 (お知らせ・開錠ボタンの表示・タイル) に対象が無かった。エントリは作成のみで
上書きは決してしない。名前の変更・建物の割り当て・担当機の変更は管理画面の 門口 タブで行い、その編集は
再起動しても残る。室内機は門口を持たないので何も seed しない。

`status.doors` にはさらに、**生存している門口機ピア**が担当していて設定エントリがまだ無い門口も
含める。`"configured": false` を付け、その端末名をラベルにする。したがってこの挙動より前に構成された
設置でもタイルは表示され、お知らせも受け付ける。最初の書き込みでエントリが作成され、以後は
`configured` を報告する。誰も担当せず設定も無い門口は従来どおり不明として拒否する。

`display.theme.auto_background` は `{"color":"#RRGGBB","source":…}` を返し、source が
`image_unsampled` のときだけ `"reason"` を伴う。3 つの source は意図的に区別している。

| `source` | 意味 |
|---|---|
| `color` | 背景画像が設定されていない。`color` はテーマ色そのもので信頼してよい |
| `image` | 背景画像をサンプリングできた。`color` はその平均色 |
| `image_unsampled` | 画像は設定されているが core がサンプリングできなかった。`color` は平らなテーマ色にすぎない |

`reason` は `too_large` (core のデコード上限 16 MP 超)、`decode_failed` (このビルドで扱えない形式)、
`missing` (このノードにまだ資産が無い) のいずれか。`image_unsampled` のとき、シェルは `auto_ink` と
`auto_accent` を信頼してはならない。実際に画面に出ている画像ではなくテーマ色から導いた値だからである。
自分で画像をサンプリングして判断するか、資産が届くまで直前のインクを維持すること。

core は最大 16x16 点のグリッドをサンプリングするが、stb にはデコード時の縮小が無いため、デコードは
一時的に 1 画素あたり約 3 バイト (上限で約 48 MB) を使い、直後に解放する。これを負担できない
ハードウェアのシェルはいずれにせよ自前でサンプリングすること。core がサンプリングしていないことは
`source` が伝える。

### インクの選び方

`auto_ink` は背景に直接描く文字のインクトークンを示す。**ダークとライトのうち、サンプリングした
輝度に対する WCAG コントラスト比が高い方**を選ぶ。2 つの比が交差するのは Y = 0.1791 であり、
中間輝度ではない。したがって「中間に見える」程度の背景でもすでにダークインクが適する。

Y >= 0.5 で分ける旧規則は、この 2 つのしきい値の間で破綻する。平均 `#BBBBB4` の明るいグレーの
写真は Y 0.494 にあり、ライトインクは 1.93:1、ダークインクは 9.58:1 になる。
`core/tests/test_color.cpp` が固定している実測値:

| 背景 | Y | ダーク | ライト | `auto_ink` |
|---|---|---|---|---|
| `#BBBBB4` | 0.494 | 10.88:1 | 1.93:1 | `dark` |
| `#808080` | 0.216 | 5.32:1 | 3.95:1 | `dark` |
| `#767676` | 0.1812 | 4.62:1 | 4.54:1 | `dark` |
| `#757575` | 0.1779 | 4.56:1 | 4.61:1 | `light` |
| `#404040` | 0.051 | 2.03:1 | 10.37:1 | `light` |

1 px・40% の反対色シャドウは、選んだ方のインクでも 4.5:1 に届かない場合の fallback として残す。
自前でサンプリングするシェル (`source` が `image_unsampled` の場合や、core のデコードを負担できない
ハードウェア) も同じ規則を適用するので、フリート全体の答えは 1 つになる。

自動生成されたエントリは `seeded_by` (作成したノード) と `seeded_label` (書き込んだラベル) を持つ。
そのノードが次に起動する、またはペアリングされた時点で、役割が `door_station` でない、あるいは
`boot.door` が変わっていれば、自分が作成したエントリを削除する。そうしないと、門口機から室内機に
変更した端末が「誰も担当していない門口」のゴーストタイルを残す。削除するのは、書き込んだ内容の
ままであるエントリだけである。他のフィールドが増えている、あるいはラベルが変更されている場合は
管理者がその門口を引き取ったということであり、引き取られた門口は作成した端末より長く生き残る。
これは単に停止しているだけの実在の門口機にとって正しい挙動である。

`status.doors.<id>.served_by` は、その門口を担当している生存中の門口機のノード ID、いなければ
`null`。「門口機がオフライン」と「そもそも担当する門口機がいない」を区別するのはこの値である。
`configured` は「この門口に設定エントリがある」と「まだ設定されていない門口を生きた門口機が
担当している」を区別する。

### クラスタへの参加は無音で行う

anti-entropy は参加したノードにクラスタのイベント履歴をまとめて渡す。これらは元の outcome の
まま呼出履歴に取り込むが、**鳴らしてはならない**。呼出イベントが提示 (チャイム・着信画面・
不在着信通知・Telegram・MQTT) されるのは、その呼出が「今」生きている場合だけである。すなわち
門口機でまだ `ringing` であり、press 自身が宣言した呼出時間枠 (`expires_at_ms`、補正済み
クラスタ時刻で判定) の内側にある場合に限る。終端イベントは、この端末が実際に表示中の呼出を
閉じるときか、不在着信通知に意味がある程度に新しいときだけ提示する。

お知らせと SOS は仕組み上これを満たす。どちらも複製された設定と状態なので、参加ノードは
「現在の値」を 1 度適用するだけで、そこに至る遷移を再演することはない。

### 誰が応答してよいか

`sip.accounts.<node_id>.answer_mode` は `auto` (即時応答) か `ring` (呼び出して人を待つ)。
**既定は役割に従う**: `door_station` は `auto`、`indoor_panel` は `ring`。実効値は
`status.sip.answer_mode` が返す。

これは呼出履歴の意味に直結する。`outcome: "answered"` と `answered_by` は「人が応答した」
という記録である。したがって既定のままの室内機が自分で応答してはならない。インターコムとして
使いたい世帯は端末ごとに `auto` を設定でき、その場合は履歴もその端末に帰属する。

### ペアリング QR のペイロード

参加のために読み取る QR はカスタムスキームの URI である。アプリが既に入っている端末なら、
ブラウザではなく参加フローが直接開く。

```
doorbell://pair?host=<ip:port>&pin=<6 桁>&exp=<unix 秒>&cluster=<名前>
```

`host` と `pin` は必須。`exp` は絶対 Unix 秒なので、読み取り側は「いつ作られたか」を知らなくても
期限切れを拒否できる。`cluster` は人が読むクラスタ名。値は RFC 3986 の unreserved 集合で
percent-encode するため、空白や日本語を含む名前もそのまま往復する。`+` は空白ではなく
文字どおりのプラス。定義されるキーはこの 4 つだけで、パーサは**それ以外を無視する**。
これにより、既に出荷したシェルを壊さずにキーを追加できる。

生成するのは core 側である。`db_core_mint_join_token_json`、`db_core_start_pairing_json`、
`POST /api/join-token`、`POST /api/pairing/start`、または `db_core_pairing_json` /
`GET /api/pairing` の `token` オブジェクトの `uri` を読むこと。シェルで文字列を組み立てては
ならない。また、QR の横に host と PIN を必ず印字しておくこと。普通のカメラアプリで読む人は
それを読んで入力する必要がある。

`db_core_parse_pair_uri_json` は読み取った内容を検証し、どのプラットフォームでも同じ判定に
なるようにする。`{"ok":true,"host":…,"pin":…,"exp":…,"cluster":…}` か
`{"ok":false,"err":…}` を返し、`err` は `bad_scheme` / `missing_pin` / `missing_host` /
`expired` のいずれか。期限判定には core 稼働中なら補正済みクラスタ時刻を、そうでなければ
プラットフォームの時計を使う。core 起動前に読み取ることがあるためである。

## 時刻・電源・お知らせ

同梱のタイムゾーン表は `core/src/util/tz.{h,cpp}` にあり、設定 UI が提示するアジア・ヨーロッパ・
南北アメリカ・オセアニア・アフリカのゾーンを収録する。現行規則のスナップショットで履歴データは
持たない。夏時間は規制ごと (EU / 北米 / オーストラリア南部 / ニュージーランド / チリ / イスラエル)
にモデル化しており、現行規則より前の時刻は現在の規則で解決される。`time.zone` は表で解決できない
値を拒否するので、UI に出るゾーンは必ず実際に使われるゾーンと一致する。

`integrations.tz_offset_min` は Telegram ブリッジと旧シェルのための互換面として残る。`time.zone`
が設定されていれば、起動時・ゾーン変更時・1 分ごとの tick で core がゾーンから書き直すため、
ゾーンを選んだ時点のオフセットで固定されず夏時間に追従する。`time.zone` を一度も設定していない
設置では固定オフセットが真の値で、書き換えは行わない。

`time.ntp` の既定は無効。有効にすると core は最小の SNTP v4 クライアント (RFC 4330) を短命の
ワーカースレッドで実行する。サーバごとに 3 サンプル取り、往復時間が最小のものを採用し、往復 3 秒
超またはオフセット 24 時間超のサンプルは捨てる。測定したオフセットは `IClock::wallMs()` に加算し、
HLC・イベントのタイムスタンプ・呼出履歴・ルールのスケジュール・静音時間帯・画面の時計がすべて
これを読む。OS の時計は決して書き換えない。3 間隔連続で同期に失敗すると補正を撤回するので、NTP
サーバに到達できなくなった端末は古い測定値でずれ続けるのではなく素の system 時刻に戻る。
`POST /api/time/sync` (管理セッション) は即時の 1 回を開始する。結果は `status.time` に出て、
ソースが切り替わるか適用中のオフセットが 500 ms を超えて動いたとき `time_changed` を送出する。

電源状態は任意の `db_platform_v2.power_state` コールバックから 1 分ごとに取得する。
`status.self.power` (同じ内容の `status.node.power` も) として公開し、限定された runtime 射影を
通して `peers[].power` に gossip し、電池が 5 ポイント以上動くか充電/外部電源が反転したとき
`power_changed` を送出する。`mains` を報告するプラットフォームでは、管理者オーバーライドを適用
する前に生成時の `mains_power` 推定をその測定値で置き換える。電池のない端末は `battery_pct: -1`
を報告し、シェルは表示自体を隠す。

お知らせは `doors.<id>.notice` という通常の複製設定なので、再起動しても残り、他の設定と同じ CRDT
経路ですべての端末に届く。期限切れは 1 分ごとの tick で削除し (tombstone が複製され再実行は
no-op なので、どのノードが削除してもよい)、`notice_changed` を送出する。
`POST` / `DELETE /api/doors/<id>/notice` は管理セッションと panel 資格情報のどちらでも受け付ける。
これにより室内のお知らせダイアログと管理画面の門口タブが同じ値を書ける。

## runtime UI manifest

native shell は read-only の top-level `ui_manifest`、Core は Admin を配信する node 専用の
`web_ui.manifest` を公開します。両者は schema v1 で、`scale`、`font_scale`、`foreground`、
`background`、`accent`、`border`、`radius`、minimum touch、contrast、安全 control を制約します。
設定 path は共通ですが、element set が違うため Admin は **Native UI** と **Web UI** を別 surface
として表示します。現行 Web manifest は `call.primary`、`cancel.call`、`call.end`、
`purpose.button`、`ring.title`、`ring.action`、`status.offline`、`reply.button`、`monitor.close`、
常時表示の 2 秒長押し control `sos.trigger` を含みます。SOS style は full-screen Web
presentation の安全 baseline にもなり、valid な rule presentation color は一時的に優先します。
panel session は複製済み emergency state を解除できないため、Web は `sos.cancel` を宣言しません。

Core は peer ごとの最後に有効な native manifest/capability を永続 cache します。configured offline
device は status に `cached_contract:true` で現れ、Core restart 後も cached native contract に対して
Admin が検証・保存できます。ただし apply success ではなく、exact renderer が再接続・検証・報告する
必要があります。reject 時は last-known-good style を維持します。Web manifest は Admin を配信する
node の local contract のままで、peer 別 catalog ではなく、native manifest から remote/offline Web
surface を推測できません。

## イベント (events テーブル / gossip)

- ID = `(origin_node, origin_seq)` 冪等。型には `press | purpose_selected | call_answered |
  call_ended | call_cancelled | motion | reply | offline | online | config_changed | emergency |
  emergency_cancel | delivery_result | visitor_lang` がある。
- `call_answered`/`call_ended` は schema version、`door`、`call_id`、`stage_revision` を持つ。
  手動応答 client は answer-mode SIP dialog の接続後だけ exact tuple を claim し、Core は決定的な
  `dialog_owner` を 1 つ保存します。同時応答の loser は winner を ended にせず hangup し、monitor は
  ownership を claim しません。`call_answered` 後は visitor cancel を拒否し、owner hangup が exact
  call の `call_ended` を発行します。restart 後は ringing は press origin、in-call は dialog owner が
  10 秒以内に復旧し、失敗時は idempotent recovery cancel を 1 回だけ発行します。
- `emergency` state は常に複製し、presentation は一致する rule action だけが生成します。
  `never_suppress:true` はその action を quiet hours から除外しますが、recipient を強制せず explicit
  empty channels を上書きしません。
- `targets` object がない legacy `device_alert` は全 native node と全 Web subscription group を
  対象にします。`targets` がある場合は selector が明示的で、`web_subscription_groups` だけなら
  native shell は 1 台も対象にせず、逆に `web_subscription_groups` がなければ active Web page/Push
  subscription は対象外です。`web_profiles` は read-only compatibility alias で、新規 write は
  `web_subscription_groups` を使います。Web page は `?group=<name>` を local に保持し、state poll と
  Push の両方へ同じ値を使います。
- `emergency.web_active_page_alerts` が true で SOS が active の間、non-sticky rule TTL は custom
  decoration/sound だけを終了し、安全な赤い raw-SOS overlay は clear または switch off まで残ります。
  TTL は replicated emergency state を解除しません。
- Core の `delivery_result` は `local_shell:dispatched`、`shell_unavailable`、
  `web_push:accepted`、`no_recipients`、`backend_unavailable` など dispatch attempt の記録であり、OS
  表示の証明ではありません。native shell は runtime `device_alert` に channel 別 presentation、
  permission、TTL expiry、limitation を別途報告します。
- `visitor_lang` (来訪者が門口機で言語を切替): payload `{ "lang": "en" }`。press の payload にも
  `visitor_lang` を同梱 (選択済みの場合)。表示先: 室内機/TV 着信画面の言語バッジ・
  /api/panel/state・Telegram 通知の「🌐 EN」・HA attrs topic。**クイック返信はこの言語の
  ラベルで表示+TTS** (訳が無ければ ja へフォールバック)。revert タイマー超過で ja へ戻り解除。
- `reply` イベント payload: `{ "schema_version": 2, "reply_id": "qr_away", "text": "…",
  "via": "telegram|mqtt|web", "call_id": "…", "stage_revision": 0 }`。schema-v2 の通話への返信は
  正確な call_id と revision が必須で、旧形式の返信は通話中には表示専用となり通話を終了しません。
- press の notify (LWW マージ): `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`
- **呼出履歴。** `call_projection` が 1 通話 = 1 行を実体化する。結果 (outcome) は保存せず導出する:
  `ended`+`reply` → `replied`、それ以外の `ended` → `answered`、`cancelled`+`timeout` または
  `recovery_*` → `missed`、それ以外の `cancelled` → `cancelled`。競合敗者
  (`concurrent_press_loser` / `concurrent_answer_loser`)、フェンス済み (`terminal_fence`)、および
  `ringing`/`in_call` の通話は履歴に出ない。`answered_by` は投影された `dialog_owner`、
  `duration_ms` は `ended_wall_ms − answered_wall_ms`。
- 取得は `GET /api/call-log?since_ms&before_ms&limit&door&outcome` (パネル資格情報または管理
  セッション) か C ABI の `db_core_call_log_json`。`since_ms` は行のタイムスタンプの下限
  (含む)、`before_ms` は古い方向へのページングのための上限 (含まない)。新しい順で、`limit` は
  500 で頭打ち。
- **既読ウォーターマークは端末ローカルで複製されない**: `POST /api/call-log/seen
  {"up_to_hlc":"…"}` (空ならすべて既読) または `db_core_call_log_mark_seen`。前にしか進まない。
  `unread_missed` はこれより新しい不在着信の件数で、待受画面のバッジそのもの。
  `{"t":"call_log_changed","unread_missed":N}` は通話ライフサイクルイベントごと、および
  ウォーターマーク更新のたびに配信される。
- `call_missed` は**仮想のルールトリガー**で、どのノードも発行しない。reason が `timeout` または
  `recovery_*` の `call_cancelled` は `call_cancelled` と `call_missed` の両方に一致するため、
  既存ルールはそのまま動く。既定投入の `r_missed_call_default` がこれを室内ロールと Web Push 向け
  `device_alert` に変換し、管理画面のルールタブで無効化できる。
- `GET /api/events` は `since_ms` / `type` / `door` を受け付け、各行は従来のフィールドに加えて
  `origin` / `seq` / `hlc` を持つ。
- **保持期間。** `events.retention_days` (1..3650、既定 90) はローカル保持スイープの下限日数で、
  加えて各 origin の最新 5,000 件は常に残る。削除にはさらに「適用済み・配信済み・永続化された
  複製カバレッジベクタで覆われている」ことが必要で、そのベクタはまだ生成されないため、実運用では
  剪定はログのみの no-op である。

## MQTT (Phase 2 — 実装済み)

計画書の topic 表 + `doorbell/<door_id>/reply/set` (購読; 通話中は `reply_id`、`call_id`、
`stage_revision` を含む JSON。旧形式の reply_id/自由文は通話外の表示専用)。
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
- MQTT 認証は `user` と `pass_ref` を使用し、bridge 設定直前に platform secure store から実値を
  解決する。新規 config への平文 `pass` 書込は拒否され、旧設定の移行入力に限る。

## 統一資産 API / 来訪者言語 API (実装で確定した細部)

- `POST /api/assets?type=<mime>&label=<name>` (管理セッション必須) — body は生バイト列。
  許可 type は `image/jpeg` `image/png` `audio/mpeg` `audio/wav` のみ、上限 3MB。
  応答 `{"hash":"<sha256>"}`。空 body=400 / 許可外 type=415 / 上限超=413 / 未ログイン=401。
  登録すると台帳 `assets.<hash>` = `{size,type,origin,label}` が書かれ CRDT で全ノードへ複製される。
- `GET /asset/<sha256>` — LAN 公開の互換読込であり、管理または panel credential は使用しない。
  セッションなしで許可されるのは、`/asset/` の後が正確に 64 桁の小文字 hex である GET のみ。
  有効な hash が未キャッシュなら 404、認証済み要求の不正 hash は 400。他の method や
  asset に似た path は公開扱いにならない (パス走査対策)。
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
