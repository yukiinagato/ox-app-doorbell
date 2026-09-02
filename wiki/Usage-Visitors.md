# The Visitor Experience — What Happens in Front of the Door Station

> English (this page) / 日本語: [Usage-Visitors-ja](Usage-Visitors-ja) / 中文: [Usage-Visitors-zh](Usage-Visitors-zh)

This page is not a "visitor manual" — visitors do not read manuals. It exists **so the installer can design the visitor flow**, by following what happens in front of the door station from the visitor's point of view.

## What the idle screen shows

- **A large call button** — "Touch to call". When in doubt, this one button is all it takes.
  (Wording and background are customizable by the installer — see Theme/Text in [Usage-Admin](Usage-Admin))
- **Purpose buttons** — under "Please select your purpose": Visit / Parcel delivery 📦 / Mail ✉️ /
  Sales & collection 💼 / Meter reading & construction 🔧 / Other. With `purpose_first`, choosing a
  purpose submits the ring. With `ring_then_purpose`, the station rings first, then offers purpose
  choices plus Skip purpose and Cancel call.
- **Language buttons** — 日本語 / English / 中文 (the installer chooses via `ui.languages`). Switching instantly changes every string on the screen to that language.

At night the screen dims and shifts red; after prolonged inactivity it drops to a screensaver (a clock), but a touch returns it to the idle screen immediately.

## What happens after pressing

1. Before a `purpose_first` call is submitted, Back/Cancel only returns home and emits no event.
   After submission, the screen changes to "Calling…" with a prominent Cancel call button.
2. The configured rules may chime devices, place SIP calls, or use integrations. Nothing is implied
   unless its rule, target capability, and service are available.
3. The response takes one of three forms:
   - **A call** — the resident's voice from the speaker. The visitor just talks normally into the door station's microphone.
   - **A quick reply** — the screen shows **large text** like "One moment, please", spoken aloud at the same time. The display disappears after about 30 seconds.
   - **An auto-reply** — depending on configuration, an answer comes back the instant the button is pressed (e.g. parcel delivery → "Please leave the package").
4. While ringing, Cancel call globally cancels the matching `call_id` and stops pending SIP legs
   and not-yet-run rule actions. After a call is established, the button becomes End call and uses
   hangup; it is no longer called cancellation.
5. If nobody answers before the configured TTL (60 seconds when absent), the originating station
   sends one idempotent global cancellation and returns to idle. Already-sent external messages
   are not guaranteed to be withdrawn.

After a crash, a ringing call is restored by its press-origin station. An in-call browser session
can be restored only by the winning dialog owner. If recovery cannot be proved within ten seconds,
Core sends one global cancel rather than leaving an ambiguous ringing session.

## Fine details of language switching (deliberate design)

- The fact that a visitor switched languages reaches the residents too, as a badge like "🌐 EN".
- Quick replies sent by residents are **displayed and spoken using the label in the language the visitor chose** (falling back to Japanese if no translation is registered). This prevents the accident of an English-speaking visitor hearing only Japanese audio.
- After 60 seconds of inactivity (setting `ui.visitor_lang_revert_s`) the station automatically reverts to Japanese. It is a reset timer so the next visitor does not inherit the previous visitor's language.

## What a visitor sees during a system failure

- If the network is degraded but the ring goes through: "Called — please wait for a response."
- If completely offline, it says so honestly: "**Cannot call. Please knock directly.**" — the final fallback, so a visitor is never left standing in front of a silent slab.

## For installers: tips for designing the visitor flow

- **Have the courage to cut purposes.** The more buttons there are, the more visitors flee to the generic button. If parcels and mail are most of your traffic, those two plus "Other" are enough (edit and reorder in the Purposes tab).
- **Auto-reply only what you can promise.** "Please leave the package" is a good auto-reply; never auto-play "Coming right away".
- **Custom recordings** can be registered per visitor language (Assets/Quick replies in [Usage-Admin](Usage-Admin)).
- **Camera angle and height**: the snapshots in Telegram notifications and the event history come from the door station's front camera. Mount it at a height that captures faces, facing away from backlight.
- At an entrance with no commissioned audio path, present an explicit notification-only fallback.
  An iPad 1 has a built-in microphone/speaker but no camera and is not outdoor-rated. A protected
  iPad visitor UI requires real-device audio/recovery tests plus an explicit LAN IP-camera or
  no-video profile; the iPad itself does not supply visitor video (see [FAQ Q14](FAQ)).

Related: [Features](Features) and [For Residents](Usage-Residents).
