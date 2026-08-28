# For Residents — Answering Visitors

> 日本語: [Usage-Residents](Usage-Residents) / 中文: [Usage-Residents-zh](Usage-Residents-zh)

This page walks through everyday scenarios from a family member's point of view: "what do I do when…". For changing settings see [Usage-Admin](Usage-Admin-en); for the feature list see [Features](Features-en).

## Scenario 1: The chime rings while you are home

When the bell rings, the indoor station shows **which entrance, the purpose (e.g. parcel delivery), the visitor's language**, and live video from the door. There are four ways to answer — any of them is fine.

1. **Answer on the indoor station** — tap "Answer" for a two-way call with the door station. Choose audio-only if your voice is enough, or two-way video if you want to show your face.
2. **Answer on the phone** — the moment the bell rang, the indoor extension phones and your registered mobiles started ringing too. Just answer the phone as usual and you are talking to the door.
3. **Send a quick reply** — just press a button like "One moment, please". It appears in large text on the door station and is read aloud. Handy when your hands are full, e.g. while cooking.
4. **Reply with the TV remote** — the Android TV's incoming-call screen takes over the whole display, with the door's video and audio starting automatically. Pick a quick reply with the D-pad and press select.

If you answered on the phone but decide you would rather talk on the indoor station after all, press "Answer" on the indoor station — the phone leg is dropped and the call switches to indoor intercom (answer takeover).

### Just want to look (without answering)

Use "Monitor" on an indoor station or the TV to check the door's video and audio **one-way**. No sound from your side is transmitted. If it looks like a salesperson, finish it right there with a "No thank you" quick reply.

## Scenario 2: A visitor arrives while you are out

- **A Telegram notification with a photo** arrives, with the purpose like "📦 Parcel delivery" and, if the visitor switched languages, a "🌐 EN" badge. Press a button under the message and a canned phrase is displayed and read aloud at the door station right away (in the visitor's language).
- **Your mobile phone is ringing too** (PSTN via Hikari Denwa). Answer it and you are talking to the door directly; pressing *1 during the call unlocks the door (depending on configuration). Even deep in the mountains where push cannot reach, the phone still rings.
- **The iPhone Home app** (if HomeKit integration is set up) also shows a doorbell notification and lets you check live video. Watching from outside the home requires an Apple TV / HomePod home hub.
- **If you can run a VPN**, joining the home LAN gives you everything as-is: web panels, the admin UI, even browser calling.

Whichever path you answer through, other family members' screens show "answered", preventing double handling.

## Scenario 3: A day when you only want packages delivered

Ask the administrator (or do it yourself in the admin UI) to set a rule: "for parcel delivery, automatically speak 'Please leave the package' and don't ring the phone". The door station answers the instant the courier taps the purpose button — nobody has to do anything. Details in the recipes section of [Usage-Admin](Usage-Admin-en).

## Scenario 4: An emergency (SOS)

**Long-press the emergency button on an indoor station for 3 seconds** to raise the alarm (the long press prevents accidental triggering).

- Every device in the house switches to an alarm display and sirens sound.
- A 🚨 notification goes to every family member's Telegram.
- With Home Assistant integration, you can also wire in flashing lights, external sirens, and so on.

**To dismiss**, use "Dismiss" on the alarm screen — the kiosk PIN is required (tamper protection). On dismissal all devices return to normal and a "✅ Emergency cleared" notification is sent.

Important: **no automatic call is made to the police or fire services**. The decision to report is always made by a human, by design (see [Design-Philosophy](Design-Philosophy-en)). If needed, you can configure additional SIP calls to user-defined numbers (a family member's mobile, etc.).

## Behavior at night

- **quiet_hours** (default 23:00–07:00): only the indoor chime goes silent. Phone, Telegram, and HA notifications still always arrive, even at night — the default exists so no visitor is ever missed. If it is too noisy, adjust it in the admin UI.
- **Night mode** (default 22:00–06:00): the door station and indoor station screens dim and take on a reddish tint, so the hallway is not glaring.
- You can also build rules such as "at night, send motion detection to Telegram only" ([Usage-Admin](Usage-Admin-en)).

## Small tricks worth remembering

- You can "push" a theme (the door station's background) or text strings from an indoor station — e.g. switch to a seasonal greeting. Changes propagate to all devices in milliseconds.
- Visitors you failed to answer remain in the admin UI's event history, snapshots included.
- If a device disappears from the LAN, a "⚠ offline" Telegram message arrives within 30 seconds. Power outage, cut cable, or theft — you notice first, whichever it is.
