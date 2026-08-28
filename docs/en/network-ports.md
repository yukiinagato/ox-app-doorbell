> Japanese original: ../ja/network-ports.md (canonical)

# Port Reference

Assumes a single L2 segment (no router traversal rules needed). However, each device's local
firewall (on Windows the installer registers rules via netsh) — and any future VLAN split —
should allow traffic per this table.

| Purpose | Protocol/Port | Direction | Notes |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | station ⇔ station | HMAC-signed HELLO. The iOS shell uses Bonjour |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | station ⇔ station | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | browser/HA/go2rtc → station | Auth: admin=password, panel/stream=?k=token |
| mDNS (future HA discovery) | UDP 5353 | station ⇔ LAN | Phase 1 onward |
| SIP (Asterisk registration — for the phone leg) | UDP 5060 | station → Asterisk | Intercom survives PBX outages (see next row) |
| Direct SIP intercom (station-to-station, no server) | UDP 47190 | indoor panel/TV ⇔ door station | X-Doorbell-Mode: answer/monitor, restricted to mesh member IPs |
| RTP | UDP 4000-4099 | station ⇔ Asterisk | Fixed range configured on the PJSIP side |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | Via the platform TLS stack |
| NTP | UDP 123 | station → NTP | Clock-drift countermeasure (set up by provisioning) |
