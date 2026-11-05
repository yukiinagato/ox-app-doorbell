# Port Reference

Assumes a single L2 segment (no router traversal rules needed). However, each device's local
firewall (on Windows the installer registers rules via netsh) — and any future VLAN split —
should allow traffic per this table.

Allow these ports only between the listed trusted-LAN endpoints. Do not forward them from the
Internet. Browsers and peers use HTTPS on 47443; the plain port answers only the device's own shell
over loopback. See [security](security.md) and [security protocol v3](security-v3.md).

| Purpose | Protocol/Port | Direction | Notes |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | station ⇔ station | HMAC-signed HELLO; use explicit seed peers where multicast is unavailable |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | station ⇔ station | PSK AEAD |
| httpd plain | TCP 47180 | loopback only | Serves the device's own shell (media with `X-Doorbell-Local`). Any non-loopback request receives `308` to `https://<host>:47443` (or `403 tls_required` while TLS is unavailable) |
| httpd HTTPS (admin/panel/media) | TCP 47443 | browser/HA/go2rtc/peer → station | Per-node self-signed ECDSA certificate; peers pin `devices.<id>.tls_sha256`. Every media route needs a session, a panel credential (Bearer or Basic), or a peer `X-Doorbell-Peer` MAC. `boot.json` `https_port` changes the port; `0` disables HTTPS |
| mDNS | UDP 5353 | station ⇔ LAN | Optional discovery only; not required for explicit seed peers |
| SIP (Asterisk registration — for the phone leg) | UDP 5060 | station → Asterisk | Intercom survives PBX outages (see next row) |
| Direct SIP intercom (station-to-station, no server) | UDP 47190 | indoor panel/TV ⇔ door station | Member address plus a single-use `X-Doorbell-Auth` MAC; otherwise only the configured registrar may INVITE. SRTP (SDES) is negotiated between peers |
| RTP | UDP 4000-4099 | station ⇔ Asterisk | Fixed range configured on the PJSIP side |
| MQTT | TCP 1883 (or the broker's TLS port) | leader → HA (Mosquitto) | Optional TLS pinned by `integrations.mqtt.tls_sha256`; packets over 256 KiB close the connection |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | Via the platform TLS stack |
| NTP | UDP 123 | station → NTP | Clock-drift countermeasure (set up by provisioning) |
