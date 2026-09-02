# ox-app-doorbell Wiki

> English (this page) / 日本語: [Home-ja](Home-ja) / 中文: [Home-zh](Home-zh)

A multi-node home doorbell/intercom with replicated mesh state and optional HA, Telegram, Asterisk/PSTN, go2rtc, and HomeKit integrations. Mesh-native paths can continue through an integration outage when the exact clients and real SIP artifacts are commissioned; actions that depend on the failed integration do not.

This wiki is a readable knowledge base. For exact status and procedures, the English repository [overview](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/overview.md) and [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md) are authoritative.

## Where to start — a map by goal

| You are… | You want to… | Read |
|---|---|---|
| New here | Understand what this system is | This page + [Design Philosophy](Design-Philosophy) |
| Evaluating | See supported and conditional capabilities | [Features](Features) + [status matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md) |
| A resident | Learn how to answer visitors | [For Residents](Usage-Residents) |
| An administrator | Navigate the admin UI | [For Admins](Usage-Admin) |
| An installer | Design the visitor experience | [Visitor Experience](Usage-Visitors) |
| A developer | Understand mesh / CRDT / SIP internals | [Architecture](Architecture) + [Decisions](Decisions) |
| Troubleshooting | Diagnose and recover | [FAQ](FAQ) + [recovery](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/recovery.md) |

## The whole system in 30 seconds

- **Devices**: native door/indoor shells, visual TV clients, and browser panels. A role or OS target does not imply hardware certification.
- **When the bell is pressed**: the rule engine dispatches configured local and optional-integration actions.
- **To answer**: available choices depend on the target shell, real SIP backend, media hardware, and commissioned integrations.
- **Configuration**: native nodes replicate a CRDT. Export it as well; replication is not a substitute for backup or secret recovery.

## Main entry points in the repository

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) — trilingual hub
- [docs/en/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/overview.md) — system overview
- [docs/en/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/deployment.md) — rollout and commissioning
- [docs/en/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/config-schema.md) — canonical configuration reference
- [docs/en/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/network-ports.md) — port table
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) — Asterisk + Hikari Denwa
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) — Home Assistant / go2rtc / HomeKit

## About languages

English unsuffixed pages are authoritative. Japanese (`-ja`) and Traditional Chinese (`-zh`) are synchronized translations. Application strings remain generated from `i18n/strings.yaml` (see [Visitor Experience](Usage-Visitors)).
