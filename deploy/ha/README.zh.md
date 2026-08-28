> 日文原文: README.ja.md（以日文为准）

# Home Assistant 集成（go2rtc / MQTT / HomeKit）

本目录的分发内容:

- `go2rtc.yaml` — 把门口机的直播视频接进 HA 的 go2rtc 流定义示例
- `configuration-snippets.yaml` — generic camera / HomeKit Bridge / 必配自动化片段

## 视频源的选法（codec 配置与转码的关系 — Phase 6a）

每台子机的配置 `devices.<id>.local.camera.codec`（管理页面 → 设备 → 视频编码）
决定直播视频的输出形态:

| codec | 子机输出的流 | go2rtc 源示例 | HA 侧转码 |
|---|---|---|---|
| `h264` / `auto`（支持机型） | `/stream.mp4`（fMP4，子机硬件编码） | `ffmpeg:http://<子机>:47180/stream.mp4#video=copy` | **不需要**（copy） |
| `mjpeg` / `auto`（无硬编的旧机） | `/stream.mjpeg`（MJPEG） | `ffmpeg:http://<子机>:47180/stream.mjpeg#video=h264#hardware` | 需要（与以往相同） |

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
- 若启用了认证（panel token），URL 需附加 `?k=<token>`
  （`/stream.mp4` 与 `/stream.mjpeg` 遵循相同的公开/令牌规则）。

静止图（`/snapshot.jpg`）与 MQTT/HomeKit 的配置见 `configuration-snippets.yaml`。
站间通话画面（室内机⇔门口机）在本 Phase 仍维持 MJPEG（H.264 硬解
计划在 Phase 6b）— 与 HA 集成无关。
