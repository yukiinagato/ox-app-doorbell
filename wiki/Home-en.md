# ox-app-doorbell Wiki

> 日本語: [Home](Home) / 中文: [Home-zh](Home-zh)

A **serverless, self-healing doorbell/intercom system** for private homes (multiple buildings, multiple entrances). It repurposes old Windows tablets (Toughpad), Android, and iOS devices as door stations and indoor stations. The source of truth is a P2P mesh — even if Home Assistant or Asterisk goes down, ringing, intercom, and notifications keep working. Via Hikari Denwa (NTT fiber phone), calls also reach your mobile phone (PSTN) when you are away, and a single Telegram button is all it takes to reply to a visitor.

This wiki is not a copy of [docs/](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) — it is a knowledge base meant to be read. For exact step-by-step procedures, the repository docs are authoritative; use this wiki as your entry point for background, rationale, and practical know-how.

## Where to start — a map by goal

| You are… | You want to… | Read |
|---|---|---|
| New here | Understand what this system is | This page + [Design-Philosophy](Design-Philosophy-en) |
| Evaluating | See everything it can do | [Features](Features-en) |
| A resident (family member) | Learn how to answer visitors | [Usage-Residents](Usage-Residents-en) |
| A resident (family member) | Watch and talk while away from home | "While away" in [Usage-Residents](Usage-Residents-en) |
| An administrator | Navigate the admin UI and find recipes | [Usage-Admin](Usage-Admin-en) |
| An administrator | Add a new device | "Adding a device" in [Usage-Admin](Usage-Admin-en) |
| An installer | Design the visitor (courier/guest) experience | [Usage-Visitors](Usage-Visitors-en) |
| A developer | Understand mesh / CRDT / SIP internals | [Architecture](Architecture-en) |
| A developer | Understand why it is designed this way | [Decisions](Decisions-en) |
| Troubleshooting | Nothing rings, won't recover, device stolen | [FAQ](FAQ-en) |

## The whole system in 30 seconds

- **Devices**: door stations (a Toughpad/Android/iOS device fixed at the entrance) + indoor stations (tablets/PCs/phones) + Android TV / browsers (down to Safari on an iPad 1). Every device runs the shared C++ core (doorbell-core).
- **When the bell is pressed**: the rule engine runs SIP calls (indoor extensions + your mobile away from home, rung simultaneously) / a Telegram notification with a photo / a Home Assistant event / indoor chimes — all in parallel.
- **To answer**: pick up on an indoor station, answer the phone, send a canned reply with a Telegram button, or reply with the TV remote — any of them. The reply is shown in large text on the door station and read aloud.
- **Configuration**: write it in any node's admin UI (`http://<ip>:47180/admin/`) and the CRDT syncs it to every device within milliseconds. As long as one device survives, the configuration is never lost.

## Main entry points in the repository

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) — trilingual hub
- [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) — system overview
- [docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) — real-home rollout checklist
- [docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md) — canonical configuration reference
- [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md) — full port table
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) — Asterisk + Hikari Denwa
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) — Home Assistant / go2rtc / HomeKit

## About languages

Japanese is the authoritative text; English (-en) and Chinese (-zh) are synchronized translations. The app UI itself supports all three languages (Japanese/English/Chinese), and on the door station visitors can switch the language themselves (see [Usage-Visitors](Usage-Visitors-en)).
