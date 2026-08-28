> Japanese original: README.ja.md (canonical)

# Home Assistant Integration (go2rtc / MQTT / HomeKit)

Files distributed in this directory:

- `go2rtc.yaml` — example go2rtc stream definitions for bringing the door stations' live video into HA
- `configuration-snippets.yaml` — snippets for generic camera / HomeKit Bridge / must-have automations

## Choosing a video source (codec setting vs. transcoding — Phase 6a)

The per-station setting `devices.<id>.local.camera.codec` (admin UI → Devices → Video codec)
changes how live video is served:

| codec | Stream the station serves | go2rtc source example | Transcoding on HA |
|---|---|---|---|
| `h264` / `auto` (capable device) | `/stream.mp4` (fMP4, HW-encoded on the station) | `ffmpeg:http://<station>:47180/stream.mp4#video=copy` | **Not needed** (copy) |
| `mjpeg` / `auto` (older device without HW encode) | `/stream.mjpeg` (MJPEG) | `ffmpeg:http://<station>:47180/stream.mjpeg#video=h264#hardware` | Needed (as before) |

- **With codec=h264 no transcoding is needed on the HA side**: the station (Android MediaCodec /
  Windows Media Foundation) produces H.264 and the core merely boxes it into fMP4 and serves it, so
  go2rtc only repackages the container with `#video=copy` (near-zero CPU on the HA host — smooth
  even at 720p).
- Use go2rtc's `ffmpeg:` source (the direct http source handles live fMP4 differently across
  versions, so the `ffmpeg:...#video=copy` form is the reliable one).
- `/stream.mp4` is a power-saving design where the station's encoder starts **only once a
  subscriber attaches** (zero encoding when nobody is watching). The first start takes a few
  seconds for startup + initialization, so for a main entrance where you want the fastest
  HomeKit-notification response, a resident consumer is recommended (keep a permanent go2rtc
  consumer attached).
- `auto` means "h264 if HW encoding exists, otherwise mjpeg" — a station without HW encoding
  returns 503 for `/stream.mp4`, so write that station using the mjpeg row.
- If authentication (panel token) is enabled, append `?k=<token>` to the URL
  (`/stream.mp4` follows the same public/token rules as `/stream.mjpeg`).

For stills (`/snapshot.jpg`) and the MQTT/HomeKit configuration, see
`configuration-snippets.yaml`. The station-to-station call screen (indoor panel ⇔ door station)
remains MJPEG in this phase (H.264 HW decoding is planned for Phase 6b) — independent of the HA
integration.
