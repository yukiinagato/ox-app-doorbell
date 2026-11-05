> Japanese original: README.ja.md (canonical)

# Home Assistant Integration (go2rtc / MQTT / HomeKit)

Files distributed in this directory:

- `go2rtc.yaml` — example go2rtc stream definitions for bringing the door stations' live video into HA
- `configuration-snippets.yaml` — snippets for generic camera / HomeKit Bridge / must-have automations

## Entities registered over MQTT

When `integrations.mqtt.host` is set, the `mqtt_bridge` leader registers the following entities
through MQTT Discovery. Entity ids come from ASCII object_ids (examples use door `d_front`).
Names follow `integrations.ha.language` (ja / en / zh; default: the first UI language).

| Entity | State topic | Content |
|---|---|---|
| `event.doorbell_d_front` | `doorbell/d_front/event` | event_type `press` / `answered` / `missed` / `replied` / `cancelled`. press carries purpose, visitor_lang and call_id; replied carries text |
| `sensor.doorbell_d_front_call_state` | `doorbell/d_front/call_state` | `idle` / `ringing` / `in_call` (retained) |
| `sensor.doorbell_d_front_last_call` | `doorbell/d_front/last_call` (+ `/attrs`) | Outcome of the latest finished call (`none` / `answered` / `missed` / `replied` / `cancelled`). Attributes: time, ts, purpose, visitor_lang, call_id, answered_by, duration_s, reply_text, seen, image_last_updated |
| `sensor.doorbell_d_front_missed_calls` | `doorbell/d_front/missed` | Unseen missed calls at this door, counted against the same device-local seen watermark as the panels |
| `image.doorbell_d_front_snapshot` | `doorbell/d_front/snapshot` | JPEG taken at the bell press (only up to 200 KiB, not retained). Does not depend on HTTP authentication |
| `select.doorbell_d_front_quick_reply` | command: `doorbell/d_front/reply/select` | Quick-reply choices (quick_replies labels). Sent only to the call in progress |
| `binary_sensor.doorbell_d_front_motion` | `doorbell/d_front/motion` | Motion (turns off after 30 s) |
| `sensor.doorbell_d_front_visitor_lang` | `doorbell/d_front/attrs` | Language the visitor chose; image_last_updated attribute |
| `binary_sensor.doorbell_emergency` | `doorbell/emergency` (+ `/attrs`) | SOS. Attributes: active, source, source_name, door, via, triggered_at(_iso), cleared_at(_iso), cleared_via |
| `button.doorbell_sos_clear` / `button.doorbell_sos_trigger` | command: `doorbell/emergency/set` (`OFF` / `ON`) | Registered only with `integrations.ha.allow_sos_control: true` |
| `text.doorbell_notice` | `doorbell/notice`, command: `doorbell/notice/set` | Cluster-wide announcement; an empty value clears it. Registered only with `integrations.ha.allow_notice_control: true` |
| `binary_sensor.doorbell_node_<id8>` / `binary_sensor.doorbell_bridge_online` | — | Device and bridge liveness |

The existing `doorbell/<door>/reply/set` topic (a reply_id, free text, or JSON with
call_id/stage_revision) keeps working.

### Authorization of MQTT commands

Commands that arrive over MQTT are authorized by the **broker**: any client that can publish
under `doorbell/` can send a quick reply. SOS trigger/clear and announcements change cluster
state, so they are off by default and accepted only after an administrator sets the two flags
above to true. Always configure broker users and ACLs so that nothing except the doorbell bridge
can publish to `doorbell/#`. Commands delivered as retained messages are ignored so that a
reconnect cannot replay them.

## Choosing a video source (codec setting vs. transcoding)

The per-station setting `devices.<id>.local.camera.codec` (admin UI → Devices → Video codec)
changes how live video is served:

| codec | Stream the station serves | go2rtc source example | Transcoding on HA |
|---|---|---|---|
| `h264` / `auto` (capable device) | `/stream.mp4` (fMP4, HW-encoded on the station) | `ffmpeg:https://<user>:<pass>@<station>:47443/stream.mp4#video=copy` | **Not needed** (copy) |
| `mjpeg` / `auto` (older device without HW encode) | `/stream.mjpeg` (MJPEG) | `ffmpeg:https://<user>:<pass>@<station>:47443/stream.mjpeg#video=h264#hardware` | Needed |

- **Requires a security v3 integration credential.** From v3, video and stills require
  authentication and are served to the LAN only over HTTPS (47443); plain HTTP on 47180 answers
  LAN clients with a redirect only. In Admin > Panels, issue a credential with only the
  "View status" grant for the integration and use it as the Basic password (any user name). The old `?k=<token>` URL form no longer
  works.
- The station certificate is self-signed. ffmpeg does not verify certificates by default, so
  the connection is encrypted but does not prove it reached the real station; keep the HA host on
  the trusted LAN. Admin shows the certificate fingerprint for manual checking.
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

For the still image at a bell press, the MQTT `image.doorbell_<door>_snapshot` entity is the
simplest option (no HTTP credential needed). For a generic camera on `/snapshot.jpg` and for
HomeKit, see `configuration-snippets.yaml`. The station-to-station call screen (indoor panel ⇔
door station) is independent of the HA integration.
