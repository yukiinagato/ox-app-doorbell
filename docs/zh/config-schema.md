# 配置 Schema（正准参考）

配置是 LWW-Map CRDT 的扁平 key→JSON。key 为点号路径。以下是 materialize 后的整体形态。
`*_ref: "secret:…"` 指向 secrets 命名空间（管理页面只写不显示，存于 platform secure store）。

`boot.json` 是设备本地 bootstrap profile，不属于 CRDT。Android、iOS/iPadOS（包括 iOS 5
兼容版）与 Windows 在 profile 为首次生成、缺少明确的 `setup_complete:true`、`role` 缺失/非法，或 `door_station` 没有有效 `door`
时，会在 Core 启动前显示阻塞式设置界面。管理员必须选择 `door_station` 或 `indoor_panel`；只有门口机
需要 door 字段，并会预填可直接确认的随机 `door-xxxxxxxx`。有效 door ID 长度为 1–64，首字符必须是
ASCII 字母或数字，后续仅允许字母、数字、`_`、`-`。仅保存成功后才原子写入
`setup_complete:true`。tvOS 没有受支持的门口摄像头角色，因此固定为 `indoor_panel`。

mesh PSK 是裝置本機 bootstrap data，不是 CRDT 值。Core 先完成 `secure_put("mesh.psk", …)`，再只向
shell 發出 `{"t":"paired","psk_ref":"secret:mesh.psk"}`。shell 將 opaque reference 與非秘密
`seed_peers` 保存到 `boot.json`，不接收新的 `psk_hex`。secure store 失敗時發出
`pairing_persistence_error` 並維持 not-ready。舊 `psk_hex` 僅供遷移。

Web Push subscription 是僅以加密形式保存的例外。Core 把完整 `endpoint`/`p256dh`/`auth` 以
mesh-PSK-derived key 和 XChaCha20-Poly1305 seal 成 schema-v2 CRDT record；materialized config/export
不會出現 plaintext。啟動時會重新 seal legacy raw record，否則 fail-closed 刪除。

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // 同一 L2，故仅作保险（beacon 为主）
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
                 // 可选公告，显示在该门口的访客界面与室内仪表盘。
                 // text 为 1-200 个字符；expires_ms 是绝对时间（毫秒），0 表示“直到取消”。
                 // 过期公告在每分钟的 tick 中清除，并送出 notice_changed。
                 "notice": { "text": "今日请走侧门",
                             "from_device": "<node_id>", "created_ms": 0, "expires_ms": 0 } },
    "d_back":  { "building": "b_main",  "label": { "ja": "勝手口" } },
    "d_annex": { "building": "b_annex", "label": { "ja": "離れ玄関" } }
  },

  "devices": {
    "<node_id>": {
      "name": "front-panel",
      "role": "door_station",                   // door_station | indoor_panel
      "door": "d_front",                        // indoor_panel 时为 null
      "platform": "windows",
      "caps_override": { "mains_power": true }, // 对实测 capability 的管理侧覆盖
      "local": {                                // 每设备配置（同样会复制 — 可远程修改）
        "ui_lang": "ja", "volume": 80, "screen_brightness": 70,
        // 各设备的音量覆盖（0-100）。缺失的级别继承 audio.volume。
        "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },
        "screensaver_after_s": 120,
        "video": { "playback": "low_latency",   // low_latency（默认）/ hls / mjpeg
                   "rotation": "auto" },          // 跟随姿态传感器 / 管理员固定 0、90、180、270 度
        "camera": { "device_hint": "", "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto"=探测硬编 h264，不可用则退回 mjpeg / "mjpeg" / "h264"
                    // h264 时启用 /stream.mp4（fMP4，平台 HW encoder），
                    // resolution/fps 用 h264_* 系列单独指定 (Phase 6)
                    "codec": "auto", "h264_resolution": "640x360", "h264_fps": 30,
                    "h264_bitrate_kbps": 700 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
        "recovery": { "helper_mode": "auto" }, // off | auto | on
        // semantic override 是完整的 element object。native shell 依 top-level ui_manifest
        // 驗證；同一 node 的 Web panel 依 status.web_ui.manifest 驗證。
        "ui": { "elements": {
          "call.primary": { "scale": 1.1, "foreground": "#FFFFFF",
                            "background": "#1A2027", "accent": "#4DA3FF" },
          "cancel.call": { "scale": 1.0, "foreground": "#FFFFFF",
                           "background": "#8D2932" }
        } },
        "motion": { "enabled": true, "sensitivity": 40, "min_interval_s": 30 },
        "aec": { "mode": "auto", "tail_ms": 0 },  // 装机标定时写入
        // TV 监视器（Android TV 常驻 app）的标记。运维笔记:
        //   - role=indoor_panel + tv:true。chime 时来客监视画面覆盖到前台，
        //     显示门口直播视频 (MJPEG) + 直接监听门口麦克风（向 sip.direct_port 发
        //     X-Doorbell-Mode: monitor 的直呼 — 无需 Asterisk、无需改 dialplan）。
        //   - 用 D-pad 选择快捷回复（quick_replies 按 order 顺序显示）。
        //   - 部署步骤: deploy/provision/android/provision.zh.md 的「Android TV」一节。
        "tv": false
      }
    }
  },

  // 外部 media source 必須明確設定，不可從 seed_peers 推測。URL userinfo 與 plaintext
  // credential 會被拒絕，認證使用 secret_ref。
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

  // 接收端播放策略。数组顺序即优先级，disabled 的策略会立即跳过。
  // 配对设置会完整取代对应室内机×室外机的全局设置。
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
    // accounts.<node_id>.user = 该设备的内线号码。门口机 (8001..) 与室内机 (201..) 都
    // 会列在这里 — 通话中对端视频通过 user(内线)→node_id→peers[].stream 反查解析。
    // answer_mode: "auto"（门口机默认 — 立即应答）| "ring"（室内机默认 — 来电 UI 手动应答）
    "accounts": { "<node_id>": { "user": "door-front", "pass_ref": "secret:sip.<node_id>",
                                 "answer_mode": "auto" } },
    // 直接呼叫（不经 Asterisk）的监听 UDP 端口。各子机的 sipctl 固定 listen，
    // 室内机/TV 向 "sip:<host>:47190" 直接发 INVITE（PBX 故障时对讲/监听仍可用的
    // 自愈方针）。X-Doorbell-Mode: monitor = 单向监听 / answer = 双向。
    // 即使未配置 server 或本机 accounts，直接呼叫也能工作。
    "direct_port": 47190,
    // DTMF 功能码（通话中对端按键 → 动作; 执行体在 mesh/MQTT 侧）
    "dtmf_actions": { "*1": { "type": "ha_command", "command": "unlock", "door": "self" },
                      "*0": { "type": "hangup" } }
  },

  "ui": {
    "call_flow": "purpose_first",             // purpose_first | ring_then_purpose
    "languages": ["ja", "en", "zh"],            // 门口机访客语言切换里展示的语言
    "launch_sound": "title_display",             // 启动音；空字符串 = 不播放
    "call_sound": "outdoor_call_alert",          // 室外机呼出确认音；空字符串 = 不播放
    "call_sound_loop": false,                     // 循环到住客回应或 30 秒超时
    "button_sound": "button_click",              // 其他按钮音；空字符串 = 不播放
    "update_sound": "indoor_update",             // 取消呼出/访问目的等追加消息音
    "ringtone": "school_chime",                  // school_chime / ding1 / ding2 / classic / asset:<sha256>
    "visitor_lang_revert_s": 60                 // 无操作达此秒数后自动回到主语言 (ja)
  },
  // 文案的运行时覆盖（优先于内置 resx/strings.xml）。在管理页面「文案」标签 /
  // 室内机的简易编辑器编辑 → CRDT 即时 push（LAN 内毫秒级）→ 门口机重绘。
  // 占位符 {name} 在编辑侧做一致性校验。key 与 i18n/strings.yaml 相同。
  "i18n_overrides": {
    "ja": { "idle.touch_to_call": "タッチして呼び出してください" },
    "en": {}
  },

  // 统一资产台账: 背景图片 + 自定义语音 (wav/mp3 ≤3MB) 的 blob 目录。实体存放在各节点的
  // assets/ 目录。**配置变更时各节点会主动预取自己引用中的 hash**
  // (mesh FETCH_BLOB — 只要有持有节点，从哪拉都行) → 播放/显示始终是本地文件 =
  // 毫秒级。管理页面展示每节点的缓存覆盖率。
  "assets": {
    "<sha256>": { "size": 123456, "type": "image/jpeg | audio/mpeg | audio/wav",
                  "origin": "<node_id>", "label": "桜.jpg" }
  },

  "display": {                                  // 显示与防烧屏（全设备默认; 可用 devices.<id>.local.display 覆盖）
    // theme: 门口机背景（从室内机/管理页面「推送」= 只是写这个配置。CRDT 即时同步）
    "theme": { "bg_color": "#101418", "bg_image": null },   // bg_image: assets 的 sha256 或 null
    "brightness": 70,                           // 0-100（远程调节 — 管理页面的滑块）
    "night": { "enabled": true, "from": "22:00", "to": "06:00",
               "brightness": 15, "red_tint": true },   // 夜间模式（用校正后的时钟判定）
    "screensaver_after_s": 120,                 // 无操作后进入屏保（时钟漂移显示、低亮度）
    "pixel_shift_s": 300                        // 待机画面元素周期性移动数 px（防烧屏）
  },

  // 集群时间。IANA 时区由 core 内置的表解析，因此没有可用 tz 数据库的平台上的外壳
  // 也能显示与其他设备一致的时钟。下方的 integrations.tz_offset_min 仍然有效，
  // 只要设置了 "zone" 就由它派生（含当前夏令时状态）；从未设置时区的安装仍以固定偏移为准。
  "time": {
    "zone": "Asia/Tokyo",                       // 内置表中的 IANA 标识符
    // 独立时间服务。core 从不修改操作系统时钟：它用 SNTP 测量偏移，并把该偏移加到所有
    // wall-clock 读取上（HLC、事件与呼叫记录时间戳、规则计划、静音时段、界面时钟）。
    // 连续三个间隔没有成功同步后，偏移会被撤销。
    "ntp": { "enabled": false,                  // 默认关闭
             "servers": ["ntp.nict.jp", "time.google.com"],   // 1-4 个 "host" 或 "host:port"
             "interval_s": 900 }                // 60..86400
  },

  // 集群默认音量（0-100）。设备可用 devices.<id>.local.audio.volume.{call,sos,idle} 覆盖；
  // 对于早于这些键的安装，sos 还会回退到 emergency.alarm_volume。
  "audio": { "volume": { "call": 80, "sos": 100, "idle": 60 } },

  "emergency": {                                // 室内紧急求助 (SOS)
    "button_on_roles": ["indoor_panel"],        // 显示 SOS 按钮的角色
    "hold_to_trigger_s": 3,                     // 旧: 长按秒数；slide 模式下不使用
    // 滑动触发控件。mode 为 "slide"（"hold" 仍被接受，以便旧配置继续通过校验）；
    // countdown_s 为 0..10 秒的可取消倒计时，归零后才告知 core 发报。
    "trigger": { "mode": "slide", "countdown_s": 3 },
    "alarm_sound": "siren1", "alarm_volume": 100,
    // true 時，即使 recipient 為零或 rule 只有 Push，已開啟 Web panel 仍顯示複製的 active SOS。
    // false 時，相符的 positive device_alert 或已送達 Push 仍可顯示。
    "web_active_page_alerts": true,
    "sip_call": { "enabled": false, "target_extension": "" },  // 可选: 经 Asterisk 呼叫用户定义的目标
    "cancel_requires_pin": true                 // 解除需 kiosk PIN
  },
  // SOS active/clear state 始終複製；顯示與外部投遞由 rule 決定，可設為零 recipient，
  // 也不代表會自動呼叫警察或消防。

  "visit_purposes": {                           // 访客事由按钮（用户可编辑; 默认 seed 见下）
    // 门口机上事由按钮 1 次点按 = 带该事由的按铃（快递员 1 个动作即完成）。
    // 大按钮「呼叫」是不带事由的通用按铃。标签跟随访客语言。
    // "enabled": false 在不删除的前提下对访客隐藏该事由；文案、图标与顺序都会保留，
    // 重新启用即可恢复。默认为 true。
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1, "enabled": true },
    "p_delivery": { "label": { "ja": "宅配便",     "en": "Delivery", "zh": "快递" }, "icon": "📦", "order": 2 },
    "p_mail":     { "label": { "ja": "郵便",       "en": "Mail",     "zh": "邮件" }, "icon": "✉️", "order": 3 },
    "p_sales":    { "label": { "ja": "営業・集金", "en": "Sales",    "zh": "推销/收费" }, "icon": "💼", "order": 4 },
    "p_work":     { "label": { "ja": "検針・工事", "en": "Utility",  "zh": "检修/施工" }, "icon": "🔧", "order": 5 },
    "p_other":    { "label": { "ja": "その他",     "en": "Other",    "zh": "其他" }, "icon": "❓", "order": 6 }
  },
  // press 事件 payload 携带 "purpose": "<id>"。展示面: 室内/TV 来铃徽标、
  // Telegram（图标+事由名）、HA event payload、panel state、管理页面。
  // 规则联动: trigger_rules.when.purposes: ["p_delivery"] 按事由分支，
  // 新动作 { "type": "auto_reply", "reply_id": "qr_okihai" } = 门口机自动
  // 显示快捷回复+TTS（例: 快递→「请放门口」+ 不响铃打电话）。

  // quick_replies 各项可选携带 "audio": {"ja": "<sha256>", "en": "<sha256>"} —
  // 按访客语言用自定义语音播放（优先级: 已缓存 audio → 系统 TTS → 提示音）。
  // auto_reply 动作也继承同一语音。chime 的 sound 用 "asset:<sha256>" 形式
  // 支持自定义音，emergency.alarm_sound 同理。
  "quick_replies": {                            // 快捷回复（用户可编辑）
    "qr_away":    { "label": { "ja": "ただいま留守にしています", "en": "We are away right now",
                               "zh": "现在不在家" }, "speak": true, "order": 1 },
    "qr_no":      { "label": { "ja": "結構です", "en": "Not interested",
                               "zh": "不需要，谢谢" }, "speak": true, "order": 2 },
    "qr_wrong":   { "label": { "ja": "お間違いのようです", "en": "Wrong address",
                               "zh": "您可能找错地方了" }, "speak": true, "order": 3 },
    "qr_wait":    { "label": { "ja": "少々お待ちください", "en": "One moment please",
                               "zh": "请稍等" }, "speak": true, "order": 4 }
  },
  "reply": { "display_ttl_s": 30 },             // 面板显示时长

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
    // 仅首次自动写入。未接来电 = reason 为 "timeout" 或 "recovery_*" 的 call_cancelled。
    // 仅限室内角色: 门口机不得向访客发出提醒。
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

  // 本地事件保留策略。每个 origin 最新的 5,000 条始终保留; 更旧的记录只有在复制证明
  // 集群中每个成员都已持有时才会被删除。
  "events": { "retention_days": 90 },           // 1..3650, 默认 90

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
                  "poll_updates": true,          // 内联按钮回复的 getUpdates 长轮询 (leader)
                  "text_template": { "ja": "{door} に来客です ({time})" } },
    // Web Push 透過受維護的 HTTPS sender 投遞。private 值存放於每個 eligible leader candidate
    // 的 local secure store，只複製 reference。
    "web_push": { "sender_url": "https://push-sender.example/doorbell/send",
                  "vapid_public_key": "<base64url-public-key>",
                  "vapid_private_key_ref": "secret:webpush.vapid_private",
                  "vapid_subject": "mailto:doorbell@example.com",
                  "sender_secret_ref": "secret:webpush.sender" }, // optional sender bearer token
    // 网页通话（webui/panel/call.html — 可选功能）。浏览器无法直接说 SIP/UDP，
    // 故用 Asterisk 作 WebRTC 网关（deploy/asterisk/webrtc.zh.md）。
    // ws_url 为空 = 通话按钮禁用（视频浏览、视频发送与 SIP 无关，照常工作）。
    // sip_user/sip_pass_ref = 瀏覽器用內線（webrtc.zh.md 的 [260] 模板）。
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260",
                "sip_pass_ref": "secret:webrtc.260" },
    "tz_offset_min": 540                         // JST。用于计划时段判定
  }
}
```

Web Push backend 分兩階段配置。先在每個預定參與 `web_push` duty 的節點，透過已驗證的
`POST /api/secrets`，把同一 `vapid_private_key_ref` 實值寫入各自的 local secure store；若 sender
需要 Bearer token，也同樣配置 `sender_secret_ref`。所有 secret write 成功後，才原子保存非秘密的
`integrations.web_push` 欄位與 reference。sender URL 必須是 HTTPS；private 值不得出現在 config、
`vapid_public_key` 必須是以 base64url 編碼、含 `0x04` 前綴的 65-byte 未壓縮 P-256 公鑰點；private 值不得出現在 config、
export、URL、log 或 command line。依賴 Push-only SOS 前，確認
`/api/status.web_push.delivery_backend:true`、非空 `leader`，以及每個預定 failover 候選都實測回報
`web_push_ready`。只有 `configured:true` 不能證明 leader 能讀取 local secret 或連到 sender。

leader election 還要求 `tls12`、`wan`、`mains_power`、`wall_clock_sane` 與 `web_push_ready` 全部為真。
LAN/default route 不是 Internet reachability 證據，而且目前沒有通用 sender probe，所以 shipping shell
會 fail-closed 回報 `wan:false`。只有在 exact node/network 實測能以 HTTPS 連到已配置 sender 後，管理員
才可明確設定 `devices.<id>.caps_override.wan:true`；應記錄該外部測試作為 measurement source，route 改變
時移除 override。只有完成固定供電 commissioning 才可 override `mains_power`。override 不得虛構 TLS
support、可讀 secret 或 working backend。

iOS compatibility 的 `streams.h264` 配合 `transport:"tcp"` 表示 bounded RTSP/RTP interleaved ingest，
不是 direct fMP4 URL。runtime 起初為 `rtsp_ingest_pending` degraded state；只有 DESCRIBE/SETUP 完成且
Annex-B IDR 實際被 Core 接受後，才可 advertise `rtsp_h264_forwarding`。單有 config 不代表 availability，
iPad 1 搭配真實 camera 尚未 qualification。

`panel.token_refs` 與非秘密的 32 位 hex `panel.token_generation` 都是 fleet 配置；輪換會在同一個
commit 中替換兩者。每個 `dbpanel` session 都綁定當前 generation 與 canonical ref set，因此輪換
複製到各節點後，所有節點的舊 session 都會失效。秘密實值不會複製；請在每個提供 panel 的節點上，
透過已驗證的 Admin 使用 **配置到此節點**，把同一實值寫入已複製的同一 ref，且不修改配置。

`devices.<id>.local.recovery.helper_mode` 是設定 request，不代表 helper 已安裝或生效。Admin form 預設為
`auto`，並透過已驗證的 atomic config batch 寫入；Core 只接受 `off`、`auto`、`on`。capability/runtime
status 必須另外回報實測 helper availability 與 effective mode。helper 不可達時設定 `on` 是可見的
degraded/error，不是 supervision 成功證據。atomic config apply 後，platform client 發送 fixed local
`MODE <value>` 並驗證 helper status；helper 原子保存 mode，供 helper/OS restart 復原。config 不會衍生
generic command/argv。

## 统一的管理密码、公告、开锁与外观

`admin.password_hash` 是整个集群唯一的管理员凭据：Web 管理界面与每台设备的设置界面使用同一个密钥。
它以 `{"salt":"<hex>","hash":"<hex>","algo":"blake2b-256","updated_ms":…}` 的形式复制，绝不保存明文，
因此离线设备也能用手上已有的副本校验。任何界面上第一次输入的密码即成为集群密码（沿用 Web 登录既有的
首次信任流程）。任一界面连续 5 次失败会让所有界面暂停 10 分钟；该计数由 `POST /api/login` 与
`db_core_admin_password_verify` 共享。

在此键出现之前，每个节点各自保存摘要，信息亭还另有退出码。该本地摘要在第一次校验成功前仍然有效，
成功后即作为集群密码被复制。仍持有自己 `exit_pin.txt` 摘要的外壳，应在
`db_core_admin_password_verify` 返回成功或“未设置”后停止使用并删除它，以免改了密码却留下另一个入口。

**未设置密码时绝不能阻止解除正在响的 SOS。** 请读取 `status.emergency.cancel_requires_password`，
它由 core 依据 `emergency.cancel_requires_pin` 与“确实设置了密码”两者共同计算。
仅凭 `emergency.cancel_requires_pin` 就拦住解除操作，会让住户无法关掉自家的警报。

`notice.global` 是集群范围的公告，`doors.<id>.notice` 会对单个门口覆盖它；
`status.doors.<id>.notice` 返回解析后的值以及 `scope`（`door` 或 `global`）。
`notice.presets` 是管理员可编辑的至多 8 条 `{id, text}`，公告对话框据此渲染；
首次会 seed 三条，之后可自由编辑或删除。

`doors.<id>.unlock.show_button` 决定是否显示开锁控件。默认是“能用才显示”：
仅当配置了 `doors.<id>.unlock.command` 或 `sip.dtmf_actions` 中的第一个 `ha_command` 时为 true。
管理员可以强制为任一取值。`status.doors.<id>.unlock` 返回 `configured`、`command`、`show_button`
以及该结论来自默认还是管理员，因此外壳在按下之前就能决定。
`POST /api/doors/<id>/open` 与 `db_core_open_door` 发出与 SIP 特服码相同的 `ha_command`，
未配置时返回 `unlock_not_configured` 而不是静默无操作。

`display.appearance` 取值为 `auto_system`、`auto_schedule`、`light`、`dark`；
`display.appearance_schedule = {dark_from, light_from}` 在 `time.zone` 中求值。两者都可置于
集群默认与 `devices.<id>.local.display`。公开的契约还带有 `follow_system`：为真时外壳优先使用
操作系统自身的设置；没有该设置的平台（iOS 5、Android 10 以下）改用日程结果。

在 `boot.json` 中指定了门口的门口机，会在 `doors.<door>` 缺失时自行创建它：创建或加入集群时，
以及此后每次在已配对状态下启动时都会检查，并用设备名称写入三种语言的标签。若无此项，
刚创建的集群中 `devices.<id>.door` 会指向一个并不存在的门口，`status.doors` 为空，
所有以门口为键的界面（公告、开锁按钮可见性、磁贴）都没有可寻址的目标。该条目只创建、绝不覆盖：
改名、归入建筑或改派门口机都在管理界面的 门口 标签页进行，这些修改可在每次重启后保留。
室内机不拥有门口，因此不会 seed 任何内容。

`status.doors` 还会列出由**存活的门口机对等端**负责、但尚无配置条目的门口，
标记为 `"configured": false`，并以该设备名称作为标签。因此在此行为出现之前完成配置的安装
仍能渲染磁贴并接受公告；第一次写入会创建该条目，之后即报告 `configured`。
无人负责且没有配置的门口仍视为未知并被拒绝。

`display.theme.auto_background` 返回 `{"color":"#RRGGBB","source":…}`；当 source 为
`image_unsampled` 时还带有 `"reason"`。三种 source 是有意区分的：

| `source` | 含义 |
|---|---|
| `color` | 未配置背景图片；`color` 就是主题色，可以信任 |
| `image` | 已对背景图片采样；`color` 是其平均色 |
| `image_unsampled` | 确实配置了图片，但 core 无法采样；`color` 只是扁平的主题色 |

`reason` 为 `too_large`（超过 core 的 16 MP 解码预算）、`decode_failed`（本构建无法解码的格式）
或 `missing`（该节点尚未缓存此资产）。在 `image_unsampled` 时，外壳**不得**信任 `auto_ink` 与
`auto_accent`：它们来自主题色，而不是屏幕上真正显示的图片。请在本地采样后自行判断，
或在资产到达前保留先前的文字颜色。

core 最多采样 16x16 个点，但 stb 没有解码时缩放，因此解码是瞬时的，约每像素 3 字节
（上限约 48 MB），随后立即释放。承受不起该开销的硬件上的外壳无论如何都应自行采样；
`source` 字段就是用来告知 core 未曾采样的。

### 如何选择文字颜色

`auto_ink` 指出要在背景上绘制的文字色标记：**在深色与浅色中，取对采样亮度具有更高 WCAG
对比度的那一个**。两条比值曲线的交点在 Y = 0.1791，而非中间亮度，因此看起来“不深不浅”的背景
其实已经更适合深色文字。

以 Y >= 0.5 划分是旧规则，它在两个阈值之间失效：平均为 `#BBBBB4` 的浅灰照片位于 Y 0.494，
此处浅色文字只有 1.93:1，而深色文字为 9.58:1。`core/tests/test_color.cpp` 固定的实测值：

| 背景 | Y | 深色 | 浅色 | `auto_ink` |
|---|---|---|---|---|
| `#BBBBB4` | 0.494 | 10.88:1 | 1.93:1 | `dark` |
| `#808080` | 0.216 | 5.32:1 | 3.95:1 | `dark` |
| `#767676` | 0.1812 | 4.62:1 | 4.54:1 | `dark` |
| `#757575` | 0.1779 | 4.56:1 | 4.61:1 | `light` |
| `#404040` | 0.051 | 2.03:1 | 10.37:1 | `light` |

1 px、40% 的反色阴影仍然保留，作为“即便较好的一方也低于 4.5:1”时的兜底。自行采样的外壳
（`source` 为 `image_unsampled`，或硬件无法承担 core 的解码）应用同一规则，因此整个设备群
得到同一个答案。

自动创建的条目带有 `seeded_by`（创建它的节点）与 `seeded_label`（它写入的标签）。
当该节点下次启动或完成配对时，若其角色不再是 `door_station`，或 `boot.door` 已改变，
它会删除自己创建的那条条目——否则由门口机改为室内机的设备会留下一块无人负责的“幽灵”磁贴。
它只删除仍与自己写入内容完全一致的条目：出现任何其他字段，或标签被改名，
都意味着管理员已经接管了该门口，而被接管的门口应比恰好创建它的设备存活得更久。
对于只是暂时离线的真实门口机而言，这才是正确的行为。

`status.doors.<id>.served_by` 是正在负责该门口的存活门口机的节点 ID，若无则为 `null`。
正是它区分了“门口机离线”与“根本没有门口机负责该门口”；而 `configured` 区分的是
“该门口已有配置条目”与“存活的门口机正在负责一个尚未配置的门口”。

### 从来电界面返回

`call.indoor.return_s`（5～600 秒，默认 60）以及按设备的覆盖
`devices.<id>.local.call.return_s`，决定室内机停留在来电界面的时长。界面标题会显示倒计时
「(60)」，归零后返回主页。本节点的实际生效值由 `status.call.return_s` 给出。

对外壳而言有两点很重要。访客取消呼叫时，面板**不会**立即离开该页面：实时画面会保留到倒计时结束，
或用户自行离开为止——这样刚抬头的住户仍能看清刚才是谁来过。点按倒计时数字会取消该次呼叫的倒计时，
正在查看门口的住户不会在中途被弹回主页。

### 加入集群时保持安静

anti-entropy 会把集群的全部事件历史一次性交给新加入的节点。这些记录应按其原始 outcome
完整写入呼叫记录，但**不得响铃**。呼叫事件只有在它此刻仍然“存活”时才会呈现
（提示音、来电界面、未接来电通知、Telegram、MQTT）：即在门口机上仍为 `ringing`，
且处于该 press 自身声明的振铃窗口内（`expires_at_ms`，以校正后的集群时间判定）。
终端事件只有在关闭本设备正在显示的呼叫时，或新到足以让未接来电提醒仍有意义时才呈现。

公告与 SOS 天然满足这一原则：两者都是复制的配置与状态，新加入的节点只应用**当前值**一次，
不会重演产生该值的历次变更。

### 谁可以接听

`sip.accounts.<node_id>.answer_mode` 为 `auto`（立即接听）或 `ring`（振铃并等待有人接听）。
**默认值取决于角色**：`door_station` 为 `auto`，`indoor_panel` 为 `ring`。
实际生效值由 `status.sip.answer_mode` 给出。

这直接关系到呼叫记录的含义：`outcome: "answered"` 与 `answered_by` 记录的是“有人接听了”。
因此保持默认设置的室内机不得自行接听。希望当作对讲机使用的家庭仍可按设备设置为 `auto`，
此时记录也会归属到该设备。

### 配对二维码的载荷

用于加入集群的二维码是一个自定义 scheme 的 URI，因此已安装应用的设备扫描后会直接进入加入流程，
而不是打开浏览器：

```
doorbell://pair?host=<ip:port>&pin=<6 位数字>&exp=<unix 秒>&cluster=<名称>
```

`host` 与 `pin` 为必填。`exp` 是绝对 Unix 秒，扫描方无需知道二维码何时生成即可拒绝过期的码。
`cluster` 是供人阅读的集群名称。取值按 RFC 3986 的 unreserved 集合做百分号编码，
因此含空格或日文的名称也能原样往返；`+` 是字面的加号，而非空格。
仅定义这四个键，解析器会**忽略**其他键，因此格式日后可新增键而不破坏已发布的外壳。

该字符串由 core 生成：请读取 `db_core_mint_join_token_json`、`db_core_start_pairing_json`、
`POST /api/join-token`、`POST /api/pairing/start`，或 `db_core_pairing_json` /
`GET /api/pairing` 的 `token` 对象中的 `uri` 字段。外壳不得自行拼接该字符串。
同时务必在二维码旁继续显示 host 与 PIN——用普通相机应用扫描的人需要读取并手动输入它们。

`db_core_parse_pair_uri_json` 用于校验扫描到的内容，使各平台得到一致结论：返回
`{"ok":true,"host":…,"pin":…,"exp":…,"cluster":…}` 或 `{"ok":false,"err":…}`，
其中 `err` 为 `bad_scheme`、`missing_pin`、`missing_host`、`expired` 之一。
过期判定在 core 运行时使用校正后的集群时间，否则使用平台时钟，因为外壳可能在 core 启动前扫描。

## 时间、电源与公告

内置时区表位于 `core/src/util/tz.{h,cpp}`，覆盖设置界面提供的亚洲、欧洲、美洲、大洋洲与非洲时区。
它是现行规则的快照，不含历史数据：夏令时按规则族建模（欧盟 / 北美 / 澳大利亚南部 / 新西兰 /
智利 / 以色列），早于现行规则的时刻会按今天的规则解析。`time.zone` 只接受表中能解析的值，
因此界面上显示的时区始终就是实际使用的时区。

`integrations.tz_offset_min` 仍是 Telegram 桥接与旧外壳的兼容面。只要设置了 `time.zone`，
core 就会在启动时、时区变更时以及每分钟的 tick 中由时区重写它，从而跟随夏令时，
而不是冻结在选定时区那一刻的偏移。从未设置 `time.zone` 的安装仍以固定偏移为准，不会被改写。

`time.ntp` 默认关闭。开启后 core 在短命的工作线程上运行一个最小的 SNTP v4 客户端（RFC 4330）：
每台服务器取 3 个样本，往返最短者胜出；往返超过 3 秒或偏移超过 24 小时的样本会被丢弃。
测得的偏移加到 `IClock::wallMs()` 上，而 HLC、事件时间戳、呼叫记录、规则计划、静音时段
以及界面上的所有时钟都读取它。操作系统时钟从不被写入；连续三个间隔同步失败后撤销该补偿，
因此 NTP 服务器不可达的设备会退回纯系统时间，而不是继续按陈旧的测量值漂移。
`POST /api/time/sync`（管理会话）启动一次立即同步；结果见 `status.time`，
当时间源翻转或已应用的偏移变动超过 500 ms 时送出 `time_changed`。

电源状态来自可选的 `db_platform_v2.power_state` 回调，每分钟轮询一次。它作为
`status.self.power`（以及内容相同的 `status.node.power`）发布，经受限的 runtime 射影
gossip 到 `peers[].power`，并在电量变动达到 5 个百分点或充电/外部供电翻转时送出 `power_changed`。
报告 `mains` 的平台会在应用管理员覆盖之前，用该测量值取代创建时对 `mains_power` 的猜测。
没有电池的设备报告 `battery_pct: -1`，外壳则完全隐藏该指示。

公告是位于 `doors.<id>.notice` 的普通复制配置，因此可在重启后保留，并经与其他设置相同的 CRDT
路径到达每台设备。过期公告在每分钟的 tick 中清除（tombstone 会复制且重复清除是 no-op，
所以任何节点都可以执行），并送出 `notice_changed`。`POST` 与 `DELETE /api/doors/<id>/notice`
接受管理会话或 panel 凭据，这正是室内公告对话框与管理界面门口标签页能写入同一个值的原因。

## runtime UI manifest

native shell 公開 read-only top-level `ui_manifest`；Core 另為目前提供 Admin 的 node 公開
`web_ui.manifest`。兩者都是 schema v1，限制 `scale`、`font_scale`、`foreground`、
`background`、`accent`、`border`、`radius`、minimum touch、contrast 與安全 control。設定 path
相同，但 element set 不同，所以 Admin 分開顯示 **Native UI** 與 **Web UI**。目前 Web manifest
包含 `call.primary`、`cancel.call`、`call.end`、`purpose.button`、`ring.title`、`ring.action`、
`status.offline`、`reply.button`、`monitor.close`，以及始終可見、需連續長按 2 秒的
`sos.trigger`。SOS 樣式也是 Web 全螢幕提示的安全基準；有效的規則提示配色可暫時優先。
Web panel session 無權解除已複製的 emergency state，因此不宣告 `sos.cancel`。

Core 會永久 cache 每個 peer 最後有效的 native manifest/capability。configured offline device 會在
status 顯示 `cached_contract:true`，Core restart 後 Admin 仍可依 cached native contract 驗證並保存。
這不代表 apply success；exact renderer 必須重連、驗證並回報，拒絕時保留 last-known-good style。
Web manifest 仍只屬於配信 Admin 的 node，不是 peer Web catalog；不能由 native manifest 推測
remote/offline Web surface。

## 事件（events 表 / gossip）

- ID = `(origin_node, origin_seq)` 冪等。類型包含 `press | purpose_selected | call_answered |
  call_ended | call_cancelled | motion | reply | offline | online | config_changed | emergency |
  emergency_cancel | delivery_result | visitor_lang`。
- `call_answered`/`call_ended` 帶 schema version、`door`、`call_id`、`stage_revision`。手動接聽
  client 只在 answer-mode SIP dialog 接通後 claim exact tuple，Core 保存一個決定性的
  `dialog_owner`。同時接聽的 loser hangup 時不能結束 winner，monitor 不 claim ownership。
  `call_answered` 後拒絕 visitor cancel；owner hangup 對 exact call 發出 `call_ended`。restart 後
  ringing 由 press origin、in-call 由 dialog owner 在 10 秒內復原，失敗只發出一次 idempotent
  recovery cancel。
- `emergency` state 始終複製，presentation 只由相符 rule action 產生。`never_suppress:true` 只讓
  該 action 不受 quiet hours 抑制，不會強制 recipient 或覆蓋 explicit empty channels。
- 沒有 `targets` object 的 legacy `device_alert` 會對所有 native node 與所有 Web subscription group。
  只要存在 `targets`，selector 即為明確語意：只有 `web_subscription_groups` 時不對任何 native shell；
  沒有 `web_subscription_groups` 時不對 active Web page/Push subscription。`web_profiles` 是 read-only
  compatibility alias，新 write 使用 `web_subscription_groups`。Web page 從 `?group=<name>` 取得並在
  local 保存 group，state poll 與 Push 使用同一值。
- 當 `emergency.web_active_page_alerts` 為 true 且 SOS 仍 active，non-sticky rule TTL 只結束 custom
  decoration/sound；安全的紅色 raw-SOS overlay 會保留至 clear 或 switch off。TTL 不會解除 replicated
  emergency state。
- Core `delivery_result` 是 `local_shell:dispatched`、`shell_unavailable`、`web_push:accepted`、
  `no_recipients`、`backend_unavailable` 等 dispatch attempt 記錄，不證明 OS 已顯示。native shell
  另在 runtime `device_alert` 回報各 channel 的 presentation、permission、TTL expiry 與 limitation。
- `visitor_lang`（访客在门口机切换语言）: payload `{ "lang": "en" }`。press 的 payload 也会附带
  `visitor_lang`（已选择时）。展示面: 室内机/TV 来铃画面的语言徽标、
  /api/panel/state、Telegram 通知中的「🌐 EN」、HA attrs topic。**快捷回复会用该语言的
  标签显示+TTS**（无译文时回落到 ja）。revert 计时器超时后回到 ja 并解除。
- `reply` 事件 payload: `{ "schema_version": 2, "reply_id": "qr_away", "text": "…",
  "via": "telegram|mqtt|web", "call_id": "…", "stage_revision": 0 }`。對 schema-v2 呼叫必須帶
  精確 call_id 與 revision；舊格式回覆在通話進行中僅作顯示公告，不會結束通話。
- press 的 notify（LWW 合并）: `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`
- **呼叫记录。** `call_projection` 为每次呼叫实体化一行。结果 (outcome) 不存储而是导出:
  `ended`+`reply` → `replied`; 其他 `ended` → `answered`; `cancelled`+`timeout` 或
  `recovery_*` → `missed`; 其他 `cancelled` → `cancelled`。并发失败方
  (`concurrent_press_loser` / `concurrent_answer_loser`)、被围栏终止 (`terminal_fence`) 以及仍处于
  `ringing`/`in_call` 的呼叫都不会出现。`answered_by` 即投影的 `dialog_owner`,
  `duration_ms` = `ended_wall_ms − answered_wall_ms`。
- 读取方式: `GET /api/call-log?since_ms&before_ms&limit&door&outcome` (面板凭据或管理会话), 或
  C ABI 的 `db_core_call_log_json`。`since_ms` 是行时间戳的下界 (含), `before_ms` 是向更早翻页的
  上界 (不含); 结果按时间倒序, `limit` 上限为 500。
- **已读水位线是设备本地的, 不参与复制**: `POST /api/call-log/seen {"up_to_hlc":"…"}` (为空表示
  全部标为已读) 或 `db_core_call_log_mark_seen`, 且只会前进。`unread_missed` 统计比水位线更新的
  未接来电, 也就是待机界面上的红点数字。每个呼叫生命周期事件之后以及每次水位线更新之后都会下发
  `{"t":"call_log_changed","unread_missed":N}`。
- `call_missed` 是**虚拟规则触发器**, 没有任何节点会发出它。reason 为 `timeout` 或 `recovery_*`
  的 `call_cancelled` 同时匹配 `call_cancelled` 与 `call_missed`, 因此既有规则不受影响。默认写入的
  `r_missed_call_default` 将其转换为面向室内角色与 Web Push 的 `device_alert`, 可在管理页规则标签
  中关闭。
- `GET /api/events` 接受 `since_ms` / `type` / `door`, 每行在原有字段之外还带有 `origin` / `seq`
  / `hlc`。
- **保留策略。** `events.retention_days` (1..3650, 默认 90) 是本地保留清扫的年龄下限, 同时每个
  origin 最新的 5,000 条始终保留。删除还要求记录已应用、已派发, 并被持久化的复制覆盖向量覆盖;
  该向量目前尚未产生, 因此实际运行中剪枝仍是仅记录日志的空操作。

## MQTT（Phase 2 — 已实现）

计划书的 topic 表 + `doorbell/<door_id>/reply/set`（订阅; 通话中使用包含 `reply_id`、
`call_id`、`stage_revision` 的 JSON；旧格式 reply_id/自由文本仅可在通话外作显示公告）。
实现: `core/src/bridge/`（mqtt_client = 自研 MQTT 3.1.1 QoS0、ha_bridge = HA 集成）。

- 启用条件: `integrations.mqtt.host` 非空 且为 mesh 的 `mqtt_bridge` duty leader。
  leader 更替、配置变更时自动 start/stop。`/api/status` 含 `bridge.mqtt =
  connected|disconnected|inactive`。
- 连接时: LWT=`<base>/bridge/availability`=offline(retain) → online(retain) →
  全 discovery (retain) → 当前状态 (door/node availability) → 订阅
  (`<prefix>/status`、`<base>/+/reply/set`、`<base>/cmd/ack`)。`<prefix>/status`="online"
  （HA 重启）时重新发布全部 discovery+状态。
- Discovery entity（object_id/unique_id 为 ASCII，日语仅出现在 name）:
  每 door 一个 `event.doorbell_<door_id>`（device_class doorbell）和
  `binary_sensor.doorbell_<door_id>_motion`（off_delay 30），每 device 一个
  `binary_sensor.doorbell_node_<node_id 前 8 位>`（connectivity — 防盗的设备断连），
  另有 `binary_sensor.doorbell_bridge_online`（源自 LWT，deploy/ha 的看门狗引用）与
  `binary_sensor.doorbell_emergency`（device_class safety，state_topic `<base>/emergency`
  retain — SOS 紧急模式。ON/OFF 取 emergency / emergency_cancel 中 hlc 较大一侧）。
- 快照/摄像头不走 MQTT — 实时画面用 go2rtc，静止图由 HA generic camera
  直接抓门口机的 `/snapshot.jpg`（参见 `deploy/ha/`）。
- MQTT 認證使用 `user` 與 `pass_ref`，bridge 設定前才從 platform secure store 解析實值。新 config
  的 plaintext `pass` 寫入會被拒絕，只保留舊設定遷移輸入。

## 统一资产 API / 访客语言 API（实现中确定的细节）

- `POST /api/assets?type=<mime>&label=<name>`（须管理会话）— body 为原始字节流。
  允许的 type 仅 `image/jpeg` `image/png` `audio/mpeg` `audio/wav`，上限 3MB。
  响应 `{"hash":"<sha256>"}`。空 body=400 / type 不允许=415 / 超限=413 / 未登录=401。
  注册后写入台账 `assets.<hash>` = `{size,type,origin,label}` 并经 CRDT 复制到全节点。
- `GET /asset/<sha256>` — LAN 公开兼容读取，不使用管理或 panel credential。只有 `/asset/`
  后恰为 64 位小写 hex 的 GET 才能在无会话时通过。有效 hash 尚未缓存时返回 404；
  已认证请求中的无效 hash 返回 400。其他 method 或形似 asset 的 path 不享有公开访问
  （防路径穿越）。
- `DELETE /api/assets/<sha256>`（管理会话）— 把台账 `assets.<hash>` 置为 tombstone，
  并立即删除本节点的本地缓存。其他节点看到台账消失（CRDT 复制）后
  以带宽限期 GC 自然回收。
- 预取时机是「被配置引用时」而非「进台账时」— 引用来源为
  `display.theme.bg_image` / `devices.*.local.theme.bg_image` / `quick_replies.*.audio.*` /
  chime 的 `sound:"asset:<hash>"` / `emergency.alarm_sound`。获取完成后
  向 uiNotify 发 `{"t":"asset_ready","hash":"<sha256>"}`（壳据此重绘/重新加载）。
  `/api/status` 的 `assets: {cached,total}` 是每节点的缓存覆盖率。
- `POST /api/panel/visitor-lang?lang=<ja|en|zh>[&door=<id>]`（panel token）— 省略 door 时为
  本机负责的 door。`lang=ja` 立即恢复。无操作 `ui.visitor_lang_revert_s` 秒后自动回到 ja
  （按铃会重新计时）。当前值见 `/api/panel/state` 各 door 的 `visitor_lang`
  （为 ja 时该 key 本身不出现）与 `/api/status` 的 `visitor_lang.<door>`。
- 开发投放: `doorbell_host --add-asset <file> [--asset-type <mime>] [--asset-label <name>]`
  （省略 type 时按扩展名推断，hash 输出到 stdout）。
- MQTT 追加部分: press 的 event payload 为 `{"event_type":"press","purpose":…,"visitor_lang":…}`
  （purpose/visitor_lang 仅在适用时出现）。向 `<base>/<door_id>/attrs` 以 retain 发布
  `{"visitor_lang":"ja|en|zh"}`，并以 `sensor.doorbell_<door>_visitor_lang` 做
  discovery。Telegram 的 press 通知首行为 `{icon} {事由名}` 加访客语言徽标 `🌐 EN`。
