> 日文原文: README.ja.md（以日文为准）

# Home Assistant 集成（go2rtc / MQTT / HomeKit）

本目录的分发内容:

- `go2rtc.yaml` — 把门口机的直播视频接进 HA 的 go2rtc 流定义示例
- `configuration-snippets.yaml` — generic camera / HomeKit Bridge / 必配自动化片段

## 通过 MQTT 注册的实体

设置 `integrations.mqtt.host` 后，`mqtt_bridge` 的 leader 设备会通过 MQTT Discovery
注册下列实体。entity_id 由 ASCII 的 object_id 决定（示例里的门是 `d_front`）。
名称按 `integrations.ha.language`（ja / en / zh；未设置时用界面第一语言）显示。

| 实体 | 状态 topic | 内容 |
|---|---|---|
| `event.doorbell_d_front` | `doorbell/d_front/event` | event_type 为 `press` / `answered` / `missed` / `replied` / `cancelled`。press 带 purpose、visitor_lang、call_id；replied 带 text |
| `sensor.doorbell_d_front_call_state` | `doorbell/d_front/call_state` | `idle` / `ringing` / `in_call`（retain） |
| `sensor.doorbell_d_front_last_call` | `doorbell/d_front/last_call`（+ `/attrs`） | 最近一次已结束呼叫的结果（`none` / `answered` / `missed` / `replied` / `cancelled`）。属性: time、ts、purpose、visitor_lang、call_id、answered_by、duration_s、reply_text、seen、image_last_updated |
| `sensor.doorbell_d_front_missed_calls` | `doorbell/d_front/missed` | 这道门未查看的未接来访数，与各面板相同，按设备本地的已读水位计数 |
| `image.doorbell_d_front_snapshot` | `doorbell/d_front/snapshot` | 按铃瞬间的 JPEG（仅 200 KiB 以内，不 retain）。不依赖 HTTP 认证 |
| `select.doorbell_d_front_quick_reply` | command: `doorbell/d_front/reply/select` | 快捷回复选项（quick_replies 的标签）。只发给正在进行的呼叫 |
| `binary_sensor.doorbell_d_front_motion` | `doorbell/d_front/motion` | 移动侦测（30 秒后变 off） |
| `sensor.doorbell_d_front_visitor_lang` | `doorbell/d_front/attrs` | 访客选择的语言；属性里有 image_last_updated |
| `binary_sensor.doorbell_emergency` | `doorbell/emergency`（+ `/attrs`） | SOS。属性: active、source、source_name、door、via、triggered_at(_iso)、cleared_at(_iso)、cleared_via |
| `button.doorbell_sos_clear` / `button.doorbell_sos_trigger` | command: `doorbell/emergency/set`（`OFF` / `ON`） | 仅在 `integrations.ha.allow_sos_control: true` 时注册 |
| `text.doorbell_notice` | `doorbell/notice`，command: `doorbell/notice/set` | 全体公告，空字符串表示撤下。仅在 `integrations.ha.allow_notice_control: true` 时注册 |
| `binary_sensor.doorbell_node_<id8>` / `binary_sensor.doorbell_bridge_online` | — | 设备与网桥的在线状态 |

原有的 `doorbell/<door>/reply/set`（reply_id、自由文本，或带 call_id/stage_revision 的 JSON）
照常可用。

### MQTT 命令的授权

经 MQTT 到达的命令**以 broker 的认证为边界**：能向 `doorbell/` 下发布的客户端都可以发快捷
回复。SOS 触发/解除和公告会改变集群状态，默认关闭，只有管理员把上面两个开关明确设为 true
才会接受。broker 必须配置用户认证和 ACL，确保除门铃网桥外没有客户端能向 `doorbell/#` 发布。
以 retain 方式到达的命令会被忽略，避免重连时被重放。

## 视频源的选法（codec 配置与转码的关系）

每台子机的配置 `devices.<id>.local.camera.codec`（管理页面 → 设备 → 视频编码）
决定直播视频的输出形态:

| codec | 子机输出的流 | go2rtc 源示例 | HA 侧转码 |
|---|---|---|---|
| `h264` / `auto`（支持机型） | `/stream.mp4`（fMP4，子机硬件编码） | `ffmpeg:https://<user>:<pass>@<子机>:47443/stream.mp4#video=copy` | **不需要**（copy） |
| `mjpeg` / `auto`（无硬编的旧机） | `/stream.mjpeg`（MJPEG） | `ffmpeg:https://<user>:<pass>@<子机>:47443/stream.mjpeg#video=h264#hardware` | 需要 |

- **需要安全协议 v3 的集成凭据**：从 v3 起，视频和静止图都必须认证，并且对局域网只通过
  HTTPS（47443）提供；47180 上的明文 HTTP 对局域网客户端只返回重定向。在管理页面为集成
  创建一个只能查看视频的凭据，用它的 user/pass 做 Basic 认证。旧的 `?k=<token>` 写法不再可用。
- 门口机证书是自签名的。ffmpeg 默认不校验证书，所以连接是加密的，但不能证明连到的就是真正的
  门口机；HA 主机要放在可信的局域网里。管理页面会显示证书指纹，可人工核对。
- **codec=h264 时 HA 侧无需转码**: 子机（Android MediaCodec / Windows
  Media Foundation）产出 H.264，core 只是装进 fMP4 分发，
  go2rtc 用 `#video=copy` 只做容器重封装（HA 主机 CPU 几乎为零，
  720p 也流畅）。
- 使用 go2rtc 的 `ffmpeg:` 源（http 直接源对 fMP4 直播的处理因版本而异，
  `ffmpeg:...#video=copy` 的写法最稳妥）。
- `/stream.mp4` 是**有订阅者之后**才启动子机编码器的省电设计
  （无人观看时零编码）。首次需要启动 + 初始化数秒，想让 HomeKit 通知
  首帧最快的主玄关建议常驻消耗（常设 go2rtc 的 consumer）。
- `auto` 表示「有硬编则 h264，否则 mjpeg」— 无硬编的子机的 `/stream.mp4` 会
  返回 503，这类子机要按 mjpeg 那行来写。

按铃时的静止图最简单的做法是用 MQTT 的 `image.doorbell_<door>_snapshot`（不需要 HTTP 凭据）。
用 generic camera 抓 `/snapshot.jpg` 以及 HomeKit 的配置见 `configuration-snippets.yaml`。
站间通话画面（室内机⇔门口机）与 HA 集成无关。
