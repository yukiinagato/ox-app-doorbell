> 日文原文: ../ja/config-schema.md（以日文为准）

# 配置 Schema（正准参考）

配置是 LWW-Map CRDT 的扁平 key→JSON。key 为点号路径。以下是 materialize 后的整体形态。
`*_ref: "secret:…"` 指向 secrets 命名空间（管理页面只写不显示，存于 platform secure store）。

```jsonc
{
  "schema_version": 1,
  "cluster": {
    "name": "京阪ハウス",
    "psk_id": "k1",
    "seed_peers": ["10.0.1.10:47172"]          // 同一 L2，故仅作保险（beacon 为主）
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
      "door": "d_front",                        // indoor_panel 时为 null
      "platform": "windows",
      "caps_override": { "mains_power": true }, // 对实测 capability 的管理侧覆盖
      "local": {                                // 每设备配置（同样会复制 — 可远程修改）
        "ui_lang": "ja", "volume": 80, "screen_brightness": 70,
        "screensaver_after_s": 120,
        "camera": { "device_hint": "", "rotation": 0, "mjpeg_fps": 8,
                    "mjpeg_quality": 60, "resolution": "640x480",
                    // codec: "auto"=探测硬编 h264，不可用则退回 mjpeg / "mjpeg" / "h264"
                    // h264 时启用 /stream.mp4（fMP4，平台 HW encoder），
                    // resolution/fps 用 h264_* 系列单独指定 (Phase 6)
                    "codec": "auto", "h264_resolution": "1280x720", "h264_fps": 25,
                    "h264_bitrate_kbps": 1500 },
        "kiosk": { "exit_pin_hash": "<pbkdf2>", "watchdog": true },
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
    "languages": ["ja", "en", "zh"],            // 门口机访客语言切换里展示的语言
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

  "emergency": {                                // 室内紧急求助 (SOS)
    "button_on_roles": ["indoor_panel"],        // 显示 SOS 按钮的角色
    "hold_to_trigger_s": 3,                     // 长按秒数（防误触）
    "alarm_sound": "siren1", "alarm_volume": 100,
    "sip_call": { "enabled": false, "target_extension": "" },  // 可选: 经 Asterisk 呼叫用户定义的目标
    "cancel_requires_pin": true                 // 解除需 kiosk PIN
  },
  // emergency 的默认行为（不依赖规则的内置动作）: 全节点警报 UI+警笛、
  // 向所有 households 发 Telegram 🚨、MQTT doorbell/emergency (retain) — HA 侧可自由联动
  // 灯光/警笛/呼叫等。**不会自动呼叫警察/消防**（通知对象仅为家人和
  // 用户定义的电话目标 — 由人来判断）。

  "visit_purposes": {                           // 访客事由按钮（用户可编辑; 默认 seed 见下）
    // 门口机上事由按钮 1 次点按 = 带该事由的按铃（快递员 1 个动作即完成）。
    // 大按钮「呼叫」是不带事由的通用按铃。标签跟随访客语言。
    "p_visit":    { "label": { "ja": "訪問",       "en": "Visit",    "zh": "访客" }, "icon": "🏠", "order": 1 },
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
                  "poll_updates": true,          // 内联按钮回复的 getUpdates 长轮询 (leader)
                  "text_template": { "ja": "{door} に来客です ({time})" } },
    // 网页通话（webui/panel/call.html — 可选功能）。浏览器无法直接说 SIP/UDP，
    // 故用 Asterisk 作 WebRTC 网关（deploy/asterisk/webrtc.zh.md）。
    // ws_url 为空 = 通话按钮禁用（视频浏览、视频发送与 SIP 无关，照常工作）。
    // sip_user/sip_pass = 浏览器用内线（webrtc.zh.md 的 [260] 模板）。
    "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260", "sip_pass": "…" },
    "tz_offset_min": 540                         // JST。用于计划时段判定
  }
}
```

## 事件（events 表 / gossip）

- ID = `(origin_node, origin_seq)` 幂等。类型: `press | motion | answered | missed | reply |
  offline | online | config_changed | emergency | emergency_cancel | visitor_lang`
- `emergency` payload: `{ "source": "<node_id>", "via": "panel|web|admin" }`。不受 quiet_hours 的
  suppress 影响（始终全渠道通知）。UI: `{"t":"emergency","active":true|false}`
- `visitor_lang`（访客在门口机切换语言）: payload `{ "lang": "en" }`。press 的 payload 也会附带
  `visitor_lang`（已选择时）。展示面: 室内机/TV 来铃画面的语言徽标、
  /api/panel/state、Telegram 通知中的「🌐 EN」、HA attrs topic。**快捷回复会用该语言的
  标签显示+TTS**（无译文时回落到 ja）。revert 计时器超时后回到 ja 并解除。
- `reply` 事件 payload: `{ "reply_id": "qr_away", "text": "…", "via": "telegram|mqtt|web",
  "target_press": "<origin>:<seq>" }`
- press 的 notify（LWW 合并）: `{ "hlc": "…", "claimed_by": "…", "notified_at": "…",
  "telegram_msg_ids": {"<chat_id>": msg_id}, "replied": {"reply_id": "qr_away", "by": "telegram"} }`

## MQTT（Phase 2 — 已实现）

计划书的 topic 表 + `doorbell/<door_id>/reply/set`（订阅; payload = reply_id 或自由文本）。
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
- MVP 的认证为 `user`/`pass` 明文（`pass_ref` 的 secure store 化计划与 sip 同时处理）。

## 统一资产 API / 访客语言 API（实现中确定的细节）

- `POST /api/assets?type=<mime>&label=<name>`（须管理会话）— body 为原始字节流。
  允许的 type 仅 `image/jpeg` `image/png` `audio/mpeg` `audio/wav`，上限 3MB。
  响应 `{"hash":"<sha256>"}`。空 body=400 / type 不允许=415 / 超限=413 / 未登录=401。
  注册后写入台账 `assets.<hash>` = `{size,type,origin,label}` 并经 CRDT 复制到全节点。
- `GET /asset/<sha256>` — 管理会话**或** panel token（`?k=`）均可获取 (403/404)。
  `<sha256>` 固定为 64 位小写 hex，否则 400（防路径穿越）。
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
