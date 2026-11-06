# Standby media and first-frame qualification

An indoor Core keeps up to four authenticated media connections to directly
connected door stations. Each station admits at most eight standby owners;
these connections also count against the HTTP server's media-stream limit.
Control stays on the existing authenticated mesh channel. Camera bytes use
separate pinned HTTPS responses, never the mesh control socket.

`GET /media-standby.mp4` requires a valid peer MAC and a 32-character channel
identifier in `X-Doorbell-Channel`. Its response type is
`application/x-doorbell-standby-v1`. Idle responses carry a 12-byte `dbrt` box
once per second: a normal MP4 box header followed by a big-endian rotation in
degrees. Idle connections have no VideoTrack reader and require no H.264
encoding or receiver decoding. A bounded local startup subscription primes the
encoder once. Cached init data crosses the idle channel once per format change,
so the kiosk can prepare and retain a decoder without decoding video. Runtime
telemetry is deduplicated and burst updates are coalesced; call events and
activation commands are sent immediately.

The mesh command `standby_video_v1` binds an activation token to the
requester's identity and channel. Token zero stops the subscription. An active
token is renewed every five seconds and expires after fifteen seconds without
renewal. Activation sends a 24-byte `dbeg` box containing the big-endian token
and source system wall milliseconds, then init data and fMP4 fragments. The
reader requests a fresh IDR and rejects the cached IDR from before activation.
The receiver filters old activation tokens. A lease is limited to 4 MiB and
128 queued boxes; overflow terminates it rather than breaking frame dependencies.

A chime reserves a lease before notifying the UI; reservations expire after
five seconds or when the call is no longer ringing. A second concurrent viewer
uses the existing media path. Membership removal, key changes, endpoint/pin
changes, stale heartbeats, and shutdown invalidate the corresponding channels.
Legacy stations retain the existing HTTPS fallback. Failed connection attempts
are spaced by at least fifteen seconds.

`media-startup` logs separate DNS, TCP, TLS, request write, response headers,
first response body, and standby activation waits. Kiosk logs record admission,
request, decoder configuration, IDR receipt, UIKit submission, and first capture
time. `press_local_wall_ms` projects the corrected press event into the
receiver's raw system clock; `capture_cutoff_ms` uses the source's raw clock,
as do camera capture timestamps. Do not compare corrected and raw clocks. Media trace writes are asynchronous and bounded; use embedded event timestamps, not log delivery times.

Authenticated loopback UI requests may claim their Core-reserved lease without
another runloop dispatch; other requests keep normal media admission.
