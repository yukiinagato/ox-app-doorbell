# Administrator Guide — Navigating the Admin UI, Plus Recipes

> 日本語: [Usage-Admin](Usage-Admin) / 中文: [Usage-Admin-zh](Usage-Admin-zh)

The admin UI is **identical on every node**: `http://<any device IP>:47180/admin/`. Whichever node you write on, the CRDT syncs to all devices in milliseconds. Logging in for the first time is how the admin password gets set. For the installation procedure itself, treat [docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) as authoritative.

## A map of the 13 tabs

| Tab | What it is for |
|---|---|
| Dashboard | Node list (leader / online / time sync), live video, sync status |
| Devices | Per-device name, role (door station/indoor station/TV), assigned door, camera (codec/resolution/fps), motion, display language |
| Doors / Buildings | Registering entrances and buildings, with JA/EN/ZH labels |
| Call rules | "When, where, on what event, do what" (press/motion/offline × schedule × actions) |
| Recipients | households — each family member's Telegram chat_id and SIP extension |
| Quick replies | Editing canned phrases (multilingual, speech, custom recordings, ordering) |
| Integrations | MQTT (HA) / Telegram / SIP (Asterisk) / WebRTC / time zone |
| Event history | Timeline of press / motion / reply / offline… with type filtering |
| Assets | Uploading background images and custom recordings, per-node cache coverage |
| Theme | Door station background color / background image (with preview), brightness, night mode |
| Text | Runtime text overrides (i18n_overrides) — leave blank for the default wording |
| Purposes | Editing visitor purpose buttons (labels, icons, ordering) |
| System | Panel tokens, issuing enrollment PINs, config export/import, logs, raw JSON |

## Frequently used recipes

### Auto "leave the package" for parcel delivery only (no phone ringing)

1. In the Quick replies tab, add `置き配をお願いします` (add EN/ZH if needed; a custom recording works too).
2. In the Call rules tab, create a new rule: condition = call button, purpose = parcel delivery (p_delivery) only.
3. Actions = auto_reply (pointing at the reply you created) + Telegram (for the record). Do not include a SIP call.
4. Either exclude parcel delivery from the existing generic rule or check rule priority, and you are done.

### Silence the chime at night (keep the notifications)

Integrations → quiet hours (quiet_hours): set the window (e.g. 23:00–07:00) and put only the chime under "suppress". Leave SIP / Telegram / HA on "always allow" — no visitor gets missed. Note that Asterisk's own night branching (GotoIfTime in the dialplan) runs on **a different clock** (see [FAQ](FAQ-en)).

### Setting a per-device background

Upload an image (jpeg/png ≤3MB) in the Assets tab → set the global default in the Theme tab; for per-device backgrounds, override local.theme on the device in the Devices tab. After upload, each door station prefetches proactively, so the image appears once coverage is complete (a few seconds).

### Seasonal wording changes

In the Text tab, override e.g. `idle.touch_to_call` with 「タッチして呼び出してください 🎍」. The instant you save, every door station redraws. Clear the field to restore the default wording. Placeholders ({name} etc.) are validated for consistency on save.

### Adding a new device (PIN procedure)

1. System tab → "Add device" → an enrollment PIN is issued (**valid for 10 minutes**).
2. Launch the app on the new device and enter an existing node's IP and this PIN on the setup screen.
3. The PSK and configuration are distributed automatically and the device joins the mesh.
4. Assign a name, role, and door in the Devices tab, and you are done.
   For per-platform kiosk setup see [Android](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/android/provision.ja.md) /
   [iOS](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md) /
   Windows (`deploy/provision/windows/provision.cmd`).

### Distributing panel tokens

The web panels (door/monitor/call.html) and video URLs authenticate with `?k=<token>`. Tokens can be viewed and rotated in the System tab. **Rotation invalidates the old token immediately**, so update any distributed Web Clips (iPad 1 etc.) and go2rtc URLs as well.

## Backup and restore

- **Export**: System tab → Export. Run it on any node and you get the full configuration (the actual secret values are not included — secure stores are device-local).
- **Import**: paste an exported JSON and it is flattened and written entry by entry.
- Day-to-day survivability is guaranteed by distribution — as long as one device is alive, the configuration survives. The export is insurance for the "lose every device at once" disaster.

## Applying updates

- **Windows**: distribute the `doorbell-windows` artifact from GitHub Actions. The watchdog tolerates stop → replace → restart.
- **Android**: with Device Owner, silent installs are possible.
- **iOS**: Ad Hoc signing **requires re-signing once a year**. Follow the in-app expiry display and Telegram's 30-day advance warning (see also [FAQ](FAQ-en)).
- Tagging the repository before an update makes rollback easier.
- Windows Update is blocked by provisioning — apply it manually on maintenance days.

## Security operations checklist

- Always change the kiosk exit PIN from the default (000000).
- Keep track of panel tokens; rotate when a distribution target is no longer needed.
- If a device is stolen: reissue the PSK in the System tab → re-pair all remaining devices, and rotate the SIP password and the Telegram bot token as well (see the relevant entry in [FAQ](FAQ-en)).
