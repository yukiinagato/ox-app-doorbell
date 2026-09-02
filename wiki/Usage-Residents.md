# For Residents — Answering Visitors

> English (this page) / 日本語: [Usage-Residents-ja](Usage-Residents-ja) / 中文: [Usage-Residents-zh](Usage-Residents-zh)

This page walks through everyday scenarios from a family member's point of view. Which phones, apps, integrations, and devices react is determined by the commissioned hardware and matching rules. For changing settings see [Administrator Guide](Usage-Admin); for the feature list see [Features](Features).

## Scenario 1: The chime rings while you are home

When a matching rule targets a commissioned indoor station, it can show **which entrance, the
purpose, and the visitor's language**, plus video when that source/playback path is available. The
following response paths are conditional capabilities, not a promise that every installation has all four.

1. **Answer on the indoor station** — where a real SIP/audio path is commissioned, tap "Answer" for
   the implemented audio or media profile.
2. **Answer on the phone** — when a matching SIP/PSTN rule and the commissioned PBX path are available, an extension or registered mobile can ring. Answer it as usual to talk to the door.
3. **Send a quick reply** — just press a button like "One moment, please". It appears in large text on the door station and is read aloud. Handy when your hands are full, e.g. while cooking.
4. **Reply with the TV remote** — on a commissioned Android TV path selected by the rule, use the
   incoming UI and D-pad quick replies; media starts only when its measured profile is available.

If you answered on the phone but decide you would rather talk on the indoor station after all, press "Answer" on the indoor station — the phone leg is dropped and the call switches to indoor intercom (answer takeover).

### Just want to look (without answering)

Use "Monitor" on an indoor station or the TV to check the door's video and audio **one-way**. No sound from your side is transmitted. If it looks like a salesperson, finish it right there with a "No thank you" quick reply.

## Scenario 2: A visitor arrives while you are out

- **If a matching Telegram rule is enabled**, its notification can include a photo, purpose such as "📦 Parcel delivery", language badge, and configured quick-reply buttons.
- **If a matching SIP/PSTN rule and the commissioned PBX path are available**, your mobile can ring too. Answering connects you to the door; configured DTMF actions such as *1 may unlock it.
- **The iPhone Home app** (if HomeKit integration is set up) also shows a doorbell notification and lets you check live video. Watching from outside the home requires an Apple TV / HomePod home hub.
- **If you can run a VPN**, joining the home LAN gives you everything as-is: web panels, the admin UI, even browser calling.

Whichever path you answer through, other family members' screens show "answered", preventing double handling.

## Scenario 3: A day when you only want packages delivered

An administrator can configure a purpose-specific reply rule. Test the exact door shell and optional integrations before relying on it. See [Usage-Admin](Usage-Admin).

## Scenario 4: An emergency (SOS)

**Long-press the emergency button on an indoor station for 3 seconds** to raise the alarm (the long press prevents accidental triggering).

- The SOS active state is replicated to every Core node and is restored when a node reconnects.
- Visual alarms, sound, system notifications, Web Push, Telegram, MQTT, SIP targets, and Home Assistant actions happen only when matching rules select them. Rules may intentionally select zero recipients or a silent presentation.
- On an open Web page, `emergency.web_active_page_alerts` defaults to `true`, so the page renders SOS active/clear state even for zero-recipient or Push-only rules. If an administrator disables it, a positively matched `device_alert` or an actually delivered Push can still be presented. While it is enabled, a rule TTL may stop custom sound/color decoration, but the safe red SOS overlay remains until clear. The page uses its administrator-assigned `?group=` for both polling and Push.

**To clear**, use the authorized clear action with its configured PIN/permission. The clear state is replicated to every Core node; whether a device displays or sends a separate clear notification is still rule- and Web-switch-dependent.

In the administrator's delivery diagnostics, `delivery_result` means that Core attempted dispatch. It does not prove that a screen, sound, or system notification appeared; that evidence comes from the client's runtime per-channel presentation report.

Important: **no automatic call is made to the police or fire services**. The decision to report remains human (see [Design Philosophy](Design-Philosophy)).

## Behavior at night

- **quiet_hours** (default 23:00–07:00): matching rules can use this period to suppress or alter selected actions. It does not itself guarantee that phone, Telegram, HA, or any other channel will run; inspect the active rules in the admin UI.
- **Night mode** (default 22:00–06:00): the door station and indoor station screens dim and take on a reddish tint, so the hallway is not glaring.
- You can also build scheduled rules for implemented event/action paths ([Usage-Admin](Usage-Admin)).

## Small tricks worth remembering

- You can "push" a theme (the door station's background) or text strings from an indoor station — e.g. switch to a seasonal greeting. Changes propagate to all devices in milliseconds.
- Visitors you failed to answer remain in the admin event history; a snapshot is included only
  when the selected camera path produced one.
- If an offline-device rule is configured, it can send Telegram or another selected alert when a node disappears from the LAN. Delivery depends on that rule and the selected integration.
