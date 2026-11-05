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

## Phone-side voice menu (talk, reply, decline)

The first phone that answers a door-station call (an extension or the mobile) hears a menu:

- **1**: talk to the visitor. Only now is the door-station call answered.
- **2**: choose a reply. The quick replies are read in display order (1-9, 0 goes back). The door station shows and speaks the reply, and the call history records it as replied.
- **9**: this phone declines. Other indoor devices keep ringing; if nobody answers the call is missed.
- After `MENU_TRIES` prompts without a key, `MENU_TIMEOUT_ACTION` runs. It defaults to `decline` so a mobile voicemail that picks up is never connected to the visitor.

How it works: the door leg stays in `Progress()` early media and is not answered. For a reply or a decline Asterisk sends RFC 4733 DTMF (`#21`-`#29` / `#90`) to the door station and releases the leg. The menu lives in `doorbell-menu.conf`, included from `extensions.conf`.

Setup:

1. Render the prompts on a Mac: `tools/gen_asterisk_prompts.sh --config <configuration exported from Admin>.json`. Copy `deploy/asterisk/sounds/<lang>/` to `/var/lib/asterisk/sounds/<lang>/doorbell/` on the PBX.
2. Put the `REPLY_COUNT` the script prints in `[globals]`.
3. Set the printed `sip.dtmf_actions` on the door stations in Admin, for example:
   `{"#21":{"type":"quick_reply","reply_id":"qr_away"},"#22":{"type":"quick_reply","reply_id":"qr_no"},"#90":{"type":"decline"}}`
4. Repeat steps 1-3 whenever the quick replies change order or wording.

A mobile reached through the Hikari line often sends inband DTMF; with `[hgw] dtmf_mode=inband` Asterisk detects it. The DTMF sent to the door station is RFC 4733 between Asterisk and the door station and is unaffected.

Development check: in `deploy/dev/asterisk`, `tools/dev_ivr_test.sh` uses SIPp as the door station and scripted phones inside Asterisk to verify reply, talk, decline and voicemail automatically. With a real door station, use target extension 620 (menu on softphone 201) or 621-624.

## SIP Video (Phase 6)

For Tier A door stations, add `allow=ulaw,h264` + `max_video_streams=1` to the endpoint.
Asterisk does **not transcode** video (passthrough) — the receiving client (Groundwire/Linphone)
must also be set to H.264 (baseline, packetization-mode=1). The PSTN leg coexists as audio-only.
