> Japanese original: README.ja.md (canonical)

# Asterisk-Side Setup (reference configuration)

This directory contains a **reference configuration** for an Asterisk instance that you manage
yourself. The app only knows about "SIP server / accounts / call-target extension" — the
distribution logic (who rings, how nights are handled, whether to dial out to mobiles) can all be
changed freely in the dialplan.

## Topology

```
[Door stations 8001/8002] --SIP--> [Asterisk] --extension REGISTER--> [Hikari Denwa HGW] --> NTT network --> Mobile (PSTN)
                                      |--> [Desk phone 201], [Smartphone SIP 202 (VPN)]
Ring: door station → 600/601   Reverse call (monitor): extension → 8001..
```

## Steps

1. In the HGW (PR-400/500/RX-600 series) admin UI → "Phone Settings > Extension Settings" enable
   one extension number (e.g. extension 4). Note the username/password and copy them into the
   `hgw-*` sections of `pjsip.conf`. No MAC authentication or spoofing needed — it registers with
   an ordinary SIP REGISTER.
2. Load `pjsip.conf` / `extensions.conf`, replace `CHANGE_ME_*` and `MOBILE`, then run
   `pjsip reload; dialplan reload`.
3. In the door-station app's admin UI, configure the SIP server IP, accounts (8001..), and
   call-target extensions (600/601).
4. Verify: `pjsip show registrations` (HGW registration OK), `pjsip show endpoints`
   (door station 8001 Avail). Ring the door station → indoor extensions + mobile ring → answer
   and confirm two-way audio and check for echo.

## Caveats (model-dependent)

- **The HGW extension supports few concurrent calls** (usually 2). Simultaneous rings from multiple
  entrances can contend for the mobile trunk — the app serializes outbound calls via leader
  arbitration, but you can also control this on the dialplan side with Queue etc.
- **DTMF**: the PSTN→HGW leg is often inband. Whether in-call feature codes (unlock *1 etc.) reach
  the door station must be measured in practice. If they don't arrive: keep
  `[hgw] dtmf_mode=inband` and rely on Asterisk's DSP detection (the current configuration), or
  try switching to rfc4733. The door-station side only supports receiving RFC2833.
- Caller-ID presentation and international/area-code prefixes follow the HGW's dialing rules
  (the same format you would dial from a handset).
- Recovery after an HGW reboot relies on `retry_interval=60`. If it stays UNREACHABLE for a long
  time, check the HGW-side settings.
- The night-time branch (GotoIfTime in extensions.conf) is evaluated against **the Asterisk
  server's clock**. It is independent of the app-side quiet_hours (chime suppression) — the admin
  UI documentation notes the same.

## SIP Video (Phase 6)

For Tier A door stations, add `allow=ulaw,h264` + `max_video_streams=1` to the endpoint.
Asterisk does **not transcode** video (passthrough) — the receiving client (Groundwire/Linphone)
must also be set to H.264 (baseline, packetization-mode=1). The PSTN leg coexists as audio-only.
