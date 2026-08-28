# The Visitor Experience — What Happens in Front of the Door Station

> 日本語: [Usage-Visitors](Usage-Visitors) / 中文: [Usage-Visitors-zh](Usage-Visitors-zh)

This page is not a "visitor manual" — visitors do not read manuals. It exists **so the installer can design the visitor flow**, by following what happens in front of the door station from the visitor's point of view.

## What the idle screen shows

- **A large call button** — "Touch to call". When in doubt, this one button is all it takes.
  (Wording and background are freely customizable by the installer — see Theme/Text in [Usage-Admin](Usage-Admin-en))
- **Purpose buttons** — under "Please select your purpose": Visit / Parcel delivery 📦 / Mail ✉️ / Sales & collection 💼 / Meter reading & construction 🔧 / Other. **One tap completes the entire ring**. A courier's whole interaction is "tap 📦" — there is no second screen.
- **Language buttons** — 日本語 / English / 中文 (the installer chooses via `ui.languages`). Switching instantly changes every string on the screen to that language.

At night the screen dims and shifts red; after prolonged inactivity it drops to a screensaver (a clock), but a touch returns it to the idle screen immediately.

## What happens after pressing

1. The screen changes to "Calling…" (with a cancel button).
2. Inside the house, chimes, indoor stations, the TV, phones, and Telegram are all running in parallel — invisible to the visitor, but a response typically comes back within a few seconds to a dozen or so.
3. The response takes one of three forms:
   - **A call** — the resident's voice from the speaker. The visitor just talks normally into the door station's microphone.
   - **A quick reply** — the screen shows **large text** like "One moment, please", spoken aloud at the same time. The display disappears after about 30 seconds.
   - **An auto-reply** — depending on configuration, an answer comes back the instant the button is pressed (e.g. parcel delivery → "Please leave the package").
4. If nobody can answer: "No answer" → back to the idle screen. Even then, the residents still have a notification with a photo.

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
- **Custom recordings** are easier to understand than TTS and give the house its own character. Recordings can be registered per visitor language (Assets/Quick replies in [Usage-Admin](Usage-Admin-en)).
- **Camera angle and height**: the snapshots in Telegram notifications and the event history come from the door station's front camera. Mount it at a height that captures faces, facing away from backlight.
- At an entrance with no audio (e.g. a non-jailbroken iPad 1 running the web door.html), the panel shows "Calls are not available at this entrance (notification only)". Put a native-app device at any entrance that needs calling. (A jailbroken iPad 1 becomes an audio node, but with no camera it is unsuited to the door-station role that films visitors; for its indoor use see [FAQ Q14](FAQ-en).)

Related: for the feature overview see [Features](Features-en); for the residents' side of the picture see [Usage-Residents](Usage-Residents-en).
