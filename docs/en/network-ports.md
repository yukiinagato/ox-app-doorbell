# Port Reference

Assumes a single L2 segment (no router traversal rules needed). However, each device's local
firewall (on Windows the installer registers rules via netsh) — and any future VLAN split —
should allow traffic per this table.

Allow these ports only between the listed trusted-LAN endpoints. Do not forward them from the
Internet. Panel tokens and admin passwords provide application authorization but do not turn LAN
HTTP into a public transport-security boundary; see [security](security.md).

| Purpose | Protocol/Port | Direction | Notes |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | station ⇔ station | HMAC-signed HELLO; use explicit seed peers where multicast is unavailable |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | station ⇔ station | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | browser/HA/go2rtc → station | Admin/panel routes use sessions; LAN compatibility media routes (`/stream.mjpeg`, `/stream.mp4`, `/snapshot.jpg`, `/video-meta`, `/peer-frame.jpg`) and exact `GET /asset/<64-lowercase-hex-sha256>` are unauthenticated, so restrict the whole port to a trusted media LAN or authenticated TLS proxy |
| mDNS | UDP 5353 | station ⇔ LAN | Optional discovery only; not required for explicit seed peers |
| SIP (Asterisk registration — for the phone leg) | UDP 5060 | station → Asterisk | Intercom survives PBX outages (see next row) |
| Direct SIP intercom (station-to-station, no server) | UDP 47190 | indoor panel/TV ⇔ door station | X-Doorbell-Mode: answer/monitor, restricted to mesh member IPs |
| RTP | UDP 4000-4099 | station ⇔ Asterisk | Fixed range configured on the PJSIP side |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | Via the platform TLS stack |
| NTP | UDP 123 | station → NTP | Clock-drift countermeasure (set up by provisioning) |
