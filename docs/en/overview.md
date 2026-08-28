> Japanese original: ../ja/overview.md (canonical)

# System Overview (features and architecture at a glance)

A doorbell/intercom system for a private home (multiple buildings, multiple entrances, one shared LAN). Old, low-spec devices are repurposed as door stations and indoor panels. **Serverless self-healing** — the P2P mesh is the source of truth: even if HA/Asterisk goes down, the doorbell itself, intercom, and notifications keep working.

## Node roles

| role | Example devices | Main functions |
|---|---|---|
| door_station | Toughpad (Win) / Android / iOS mounted at the entrance | Call button, front camera, mic/speaker, kiosk |
| indoor_panel | Indoor tablet / PC / phone | Ring display, answer/quick replies, monitoring, SOS |
| indoor_panel + tv:true | Android TV | Full-screen live view on ring + direct listen-in, D-pad answering |
| (Web) door.html/monitor.html/call.html | Browser (incl. iPad 1) | Web-based station / ring receiver / calls |

Every node runs the shared C++ core (doorbell-core) and connects as an equal peer over the mesh.

## Feature map

- **Calling**: door-station button (generic or one-tap per purpose) → rule engine → SIP call / chime /
  Telegram / HA / auto-reply. Visitors can switch language and pick a purpose (visit/delivery/…).
- **Intercom** (direct SIP without Asterisk, port 47190): audio only / door video + two-way audio /
  two-way indoor-outdoor video (symmetric MJPEG). Supports listen-in (one-way) and answer takeover
  (grab the phone leg and answer indoors). Survives PBX outages. Only browser calls go through the
  Asterisk WebRTC gateway (optional).
- **Phone integration** (Asterisk + Hikari Denwa): a ring simultaneously calls indoor extensions and
  mobile phones away from home (PSTN); DTMF feature codes unlock the door, etc. See deploy/asterisk/.
- **Notifications**: Telegram (photo + inline buttons for quick replies) / HA (MQTT Discovery: doorbell
  event, motion, device offline, bridge liveness, emergency) / indoor chime. Only the leader node sends
  external notifications (prevents duplicates).
- **Video**: default is MJPEG (all devices, all browsers). The h264 profile (Phase 6) uses HW-encoded
  fMP4 → smooth in-call video quality, no transcoding on HA. go2rtc → HomeKit brings doorbell
  notifications + live view to the Apple Home app.
- **Quick replies / away responses**: canned messages (multilingual, customizable) sent from
  indoors/Telegram/HA/web → shown in large text at the door station and read aloud (system TTS or
  custom audio). Follows the visitor's language.
- **Emergency SOS**: long-press indoors → alarm on all nodes + siren + Telegram 🚨 + MQTT (HA hooks).
  No automatic calls to police or fire services.
- **Personalization (push)**: change background color/image, wording, purposes, languages, and audio
  from the indoor panel/admin UI → synced in milliseconds via CRDT. Images/audio are proactively
  prefetched to each door station (assets ledger) for instant playback.
- **Anti-theft / kiosk**: exit requires an on-screen keypad PIN, shell-replacement autostart, watchdog
  foreground guard (pushes back Windows Update popups etc.), offline alarm, Device Owner lock on
  Android.

## Per-platform support matrix

| Feature | Windows (WPF) | Android | iOS | Web |
|---|---|---|---|---|
| Full door station | ✅ | ✅ | ✅ | door.html (no audio) |
| Indoor intercom | ✅ | ✅ | ✅ | call.html (modern browsers) |
| TV monitoring | — | ✅ (TV) | AppleTV=HomeKit / tvOS app=✅ (video only — SIP listen-in is TODO) | — |
| Kiosk hardening | shell replacement + guard + keypad | Device Owner + guard | supervised SAM | — |
| Screen-lock prevention | SetThreadExecutionState | keyguard disabled + STAY_ON | isIdleTimerDisabled | — |
| Oldest supported | Win7 SP1 | 5.0 (4.4 legacy) | 12 (9 legacy) | iOS5 Safari |

## Repository layout & builds

- Core/tests: `cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
- Host device simulation: `./build/doorbell_host --help` (bring up a station on Mac/Linux)
- Platform apps are CI-built by GitHub Actions (`.github/workflows/build.yml`) →
  Windows/Android artifacts can be downloaded from Artifacts.
- iOS/tvOS: `xcodebuild -project ios/Doorbell.xcodeproj -scheme Doorbell|DoorbellTV`
  (the core is built automatically by a run-script via CMake. For SIP, run
  `tools/build_pjsip_ios.sh` first. Signing/kiosk/distribution: deploy/provision/ios/provision.en.md)
- Development stack: `deploy/dev/{asterisk,mosquitto}/docker-compose.yml`

## Configuration = a single CRDT

All configuration lives in an LWW-Map CRDT (docs/en/config-schema.md is canonical). Write via the
admin UI (`http://<ip>:47180/admin/` on any node) or the API and it propagates to the whole fleet in
milliseconds. The source of truth is distributed — as long as one node survives, the configuration can
be restored.
