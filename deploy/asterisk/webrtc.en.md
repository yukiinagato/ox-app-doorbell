> Japanese original: webrtc.ja.md (canonical)

# Browser Calls (WebRTC) — Asterisk-Side Configuration (**optional feature**)

**Positioning**: intercom between the indoor-panel apps (Windows/Android/iOS/TV) and the door
stations uses direct SIP (UDP 47190) without going through Asterisk — intercom survives even when
the PBX is down. This document covers the extra configuration needed **only if you want to make
calls from a browser (the web panel)**. Browsers cannot speak SIP/UDP directly, so Asterisk is
used as a WebRTC gateway. If you don't use web calls, none of this is needed.

Two-way audio on the web panel uses the "browser = an Asterisk extension" approach
(JsSIP + WebSocket). No changes on the door-station side — the browser simply dials the door
station's extension (8001 etc.) normally.

## 1. Important prerequisite: secure context

**The browser's getUserMedia (microphone) only works on HTTPS pages** (localhost excepted).
The stations' admin/panel pages are plain HTTP, so you need one of the following:

- **Recommended: a reverse proxy such as Caddy on the HA host + an internal CA**
  `https://doorbell.home` → proxied to a station's 47180, `wss://` → Asterisk 8089.
  Install the internal CA once on each device.
- **Simple: a per-browser exception** — Chrome:
  add `http://<station IP>:47180` to `chrome://flags/#unsafely-treat-insecure-origin-as-secure`.
  Realistic if only a fixed set of home devices is involved.

## 2. http.conf (Asterisk built-in HTTP — for WebSocket)

```ini
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
; if using wss (not needed when Caddy terminates TLS):
;tlsenable=yes
;tlsbindaddr=0.0.0.0:8089
;tlscertfile=/etc/asterisk/keys/asterisk.pem
```

## 3. pjsip.conf additions (ws transport + browser extension template)

```ini
[transport-ws]
type=transport
protocol=ws                 ; keep ws when Caddy terminates wss; use protocol=wss for direct wss
bind=0.0.0.0

[browser](!)
type=endpoint
context=from-internal
disallow=all
allow=opus,ulaw             ; browsers default to opus; ulaw as fallback
webrtc=yes                  ; shorthand for the whole use_avpf/ice_support/dtls set (Asterisk 15+)
dtls_auto_generate_cert=yes ; auto-generate a self-signed DTLS certificate
dtmf_mode=rfc4733

;---- web-panel extensions (add one per device) ----
[260](browser)
auth=260
aors=260
callerid="Web Panel" <260>
[260](door-auth)
username=260
password=CHANGE_ME_260
[260](door-aor)
max_contacts=3              ; allow multiple simultaneous browser logins
```

- `webrtc=yes` requires Asterisk 15+ (20 is fine). opus comes from the codec_opus module
  (bundled by default; check with `module show like opus`). Asterisk transcodes
  opus⇔ulaw between the browser and the door station (server load — negligible for 1-2
  concurrent calls).
- extensions.conf needs no changes — 260 is in from-internal and can dial `8001` (direct to a
  door station) or `0…` (Hikari Denwa outbound) as-is.

## 4. Verification

```
asterisk -rx "pjsip show transports"     ; ws is present
asterisk -rx "pjsip show endpoint 260"
```
The browser side (the panel's call page) REGISTERs via JsSIP to
`wss://<host>:8089/ws` (or via Caddy: `wss://doorbell.home/asterisk/ws`).

## 5. About video

- Browser ← door-station video is not WebRTC but MJPEG (`/stream.mjpeg`) shown side by side —
  no Asterisk video configuration needed.
- Browser → door station (for two-way video) uses getUserMedia → canvas → JPEG POSTed to the
  door station's `/call-frame` (implemented on the app side). No WebRTC video negotiation.
