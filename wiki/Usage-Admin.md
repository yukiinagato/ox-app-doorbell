# Administrator Guide — Navigating the Admin UI, Plus Recipes

> English (this page) / 日本語: [Usage-Admin-ja](Usage-Admin-ja) / 中文: [Usage-Admin-zh](Usage-Admin-zh)

The admin UI is served by every native node at `http://<device>:47180/admin/`. Changes enter the replicated CRDT. For installation and security requirements, use the English [deployment guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/deployment.md) and [security guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/security.md).

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

## Shared administrator access

The password set through any current Admin or native settings surface becomes the replicated
cluster credential; only its salted digest is stored. Changing it invalidates Admin sessions on the
node that changes it. Five failed checks trigger a ten-minute lockout shared by that node's Web
login and device-side settings entry. This counter is not replicated to other nodes, so it is not a
cluster-wide rate limiter. If no password has ever been set, Core does not require one to clear an
active SOS alarm.

## Frequently used recipes

### Publish an announcement, expose unlock, or pause a visitor purpose

Use the door's announcement control for a door-specific message, or the global announcement for a
cluster-wide default; the door message wins without deleting the global one. Announcements may have
an expiry, and the preset list holds up to eight reusable messages. The door's unlock control is
shown by default only when its command (or a SIP DTMF `ha_command`) is configured. If pressed
without a configured action, Core returns an explicit failure rather than a false success.

In the Purposes tab, turn a purpose off to remove it from new visitor choices while retaining its
labels, icon, order, history, and existing rule references. A stale door station can still submit
the old button; its press becomes a generic ring, so a visitor is not blocked by propagation delay.

### Choose a readable fleet theme

Choose light, dark, system-following, or scheduled appearance. Core resolves scheduled appearance
in the cluster time zone and supplies automatic ink and call-button colors per semantic region.
When a background image makes the pixels under text device-specific, shells may sample locally;
explicit regional overrides still win. A low-contrast color is saved with a measured WCAG warning,
not silently changed or rejected.

### Auto "leave the package" for parcel delivery only (no phone ringing)

1. In the Quick replies tab, add `置き配をお願いします` (add EN/ZH if needed; a custom recording works too).
2. In the Call rules tab, create a new rule: condition = call button, purpose = parcel delivery (p_delivery) only.
3. Actions = auto_reply (pointing at the reply you created) + Telegram (for the record). Do not include a SIP call.
4. Either exclude parcel delivery from the existing generic rule or check rule priority, and you are done.

### Silence the chime at night (keep the notifications)

Integrations → quiet hours (`quiet_hours`): set the window and explicit suppression policy. Test it with each optional integration; Asterisk's own night branching uses a separate clock (see [FAQ](FAQ)).

### Configure and preview SOS delivery

Create `emergency_on`/`emergency_off` rules with `device_alert` targets (device IDs, roles, or Web
subscription groups), channels, and presentation. Visual presentation supports sound, volume,
sticky/TTL, and background/foreground/accent colors. The dry run resolves each target's measured
channel support and permission and warns—without blocking save—about zero recipients, silent
rules, unavailable/unsupported or rolling-upgrade-unknown channels, missing Push subscriptions,
and an unavailable Push backend.

`emergency.web_active_page_alerts` defaults to on. It makes an open Web page display replicated
active SOS even when rules have zero recipients or are Push-only. If switched off, a positive
matching `device_alert` or a delivered Push can still display. Treat Core `delivery_result` as a
dispatch attempt; use the client's per-channel runtime report to verify actual presentation.
With the raw path on, rule TTL ends custom decoration/sound but the safe red overlay stays until SOS
clear or switch-off.

Targeting is explicit and symmetric: a target containing only `web_subscription_groups` addresses
no native shell, and a target without that selector addresses no active Web page or Push
subscription. A legacy `device_alert` action with no `targets` object retains its all-native-and-Web
compatibility meaning. Give a Web panel `?group=guards`; it persists that valid group and uses it for
both polling and Push enrollment. Core seals the full Push endpoint/key subscription in CRDT, so
config/export does not contain it in plaintext; a fail-closed legacy migration may require
re-enrollment.

### Setting a per-device background

Upload an image (jpeg/png ≤3MB) in the Assets tab → set the global default in the Theme tab; for per-device backgrounds, override local.theme on the device in the Devices tab. After upload, each door station prefetches proactively, so the image appears once coverage is complete (a few seconds).

### Adjusting per-device semantic controls

Use the device's manifest-driven editor for allowed size and color properties. Native
`ui_manifest` and local `web_ui.manifest` are separate contracts. Core durably caches the last
valid native peer manifest/capabilities, so a configured offline device can be edited when status
shows `cached_contract:true`; this is validation against the cached contract, not proof that the
offline renderer applied the change. Remote Web manifests are not catalogued, so only the Web UI
served by the current Core node is editable. Final success requires the renderer's apply report.

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

Admin issues a panel credential once. Put it in the launch URL fragment as `#k=<credential>`; the
page exchanges it with `POST /api/panel/session` and then uses an HttpOnly cookie. Do not put
credentials in query strings, stream URLs, logs, or configuration. Rotation invalidates the old
credential immediately, so reissue affected Web Clips/sessions.

## Backup and restore

- **Export**: System tab → Export. Run it on any node and you get the full configuration (the actual secret values are not included — secure stores are device-local).
- **Import**: paste an exported JSON; Admin validates all operations and writes one atomic
  `/api/config/batch`. If the endpoint is unavailable, import fails instead of falling back to
  sequential partial writes.
- Day-to-day survivability is guaranteed by distribution — as long as one device is alive, the configuration survives. The export is insurance for the "lose every device at once" disaster.

## Applying updates

- **Windows**: distribute the `doorbell-windows` artifact from GitHub Actions. The watchdog tolerates stop → replace → restart.
- **Android**: with Device Owner, silent installs are possible.
- **iOS**: track the actual provisioning-profile/signature expiry and renew before it blocks launch (see [FAQ](FAQ)).
- Tagging the repository before an update makes rollback easier.
- Windows Update is blocked by provisioning — apply it manually on maintenance days.

## Security operations checklist

- Provision a unique kiosk exit PIN before commissioning; never retain or document a shared factory value.
- Keep track of panel tokens; rotate when a distribution target is no longer needed.
- If a device is stolen: rotate the mesh PSK and every credential/token accessible to it, then re-pair remaining devices (see [FAQ](FAQ) and the security guide).
