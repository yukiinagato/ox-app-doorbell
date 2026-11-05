# UI guidelines (cross-platform)

Status: adopted 2026-11-06 for the UI redesign on branch `fix/full-review-2026-11`.
Every shell implements these with its own native controls. Behavior, Core
contracts, and the semantic UI manifest stay authoritative; this document only
decides layout, hierarchy, and interaction.

## 1. Principles

1. **One job per screen.** Each screen has a single primary action that is the
   largest, highest-contrast control. Secondary actions are visibly secondary.
2. **Role decides home.** A door station opens on the visitor screen, an indoor
   panel on the dashboard, a display/monitor on live view. Nothing else competes
   with that home.
3. **Fixed action zone.** Actions live in a fixed bar at the bottom (portrait)
   or right edge (landscape). Content scrolls; actions never move or hide behind
   content, the keyboard, or safe areas.
4. **Same words, same place.** A given action has the same label, icon, color
   role, and position on every platform and every screen it appears on.
5. **Readable at a distance and in three languages.** Layouts must survive the
   longest of ja/en/zh, 200% text size, and a 1.5 m viewing distance on a door
   station.
6. **Native first.** Use the platform's controls and navigation patterns; only
   the visual tokens below are shared.

## 2. Size classes

| Class | Width (dp/pt/effective px) | Navigation | Typical device |
|---|---|---|---|
| Compact | < 600 | Bottom tab bar (max 4), drill-down | Phone, iPad 1 portrait split |
| Medium | 600–899 | Navigation rail or tab bar, two columns where useful | Small tablet, portrait tablet |
| Expanded | ≥ 900 | Side navigation, master–detail | Landscape tablet, desktop, wall panel |

Layouts are chosen from the current window size, not the device model, and
switch live on rotation or window resize.

## 3. Tokens

- Spacing on a 4-point grid: 4, 8, 12, 16, 24, 32, 48.
- Touch targets: at least 44 pt (iOS) / 48 dp (Android) / 44 px (Web, Windows);
  door-station visitor targets at least 72 pt.
- Type scale (relative to platform body): caption 0.8, body 1.0, title 1.25,
  headline 1.6, display 2.2 (door-station call button label, clock).
- Corner radius: 12 for cards, 999 for pills, 20 for sheets.
- Color roles come from Core's semantic regions and theme: `surface`,
  `on_surface`, `accent`, `positive` (answer/connected), `negative`
  (hang up/SOS/errors), `warning`, `muted`. Never hard-code a color that a region
  provides; measured low-contrast warnings stay visible in Admin.
- Motion: 150–250 ms ease-out for transitions; none when reduced motion is on.

## 4. Screens

### Visitor (door station)

- Top bar: building/door name left, clock center (optional), language switch
  right (flag-free text labels: 日本語 / English / 中文).
- Notice banner below the top bar when an announcement exists.
- Center: purpose cards in a grid (2 columns compact, 3–4 expanded), large icon
  plus label; disabled purposes are hidden.
- Bottom action zone: one full-width primary "Call" button (or "Call without
  choosing" in purpose-first mode).
- States reuse the same frame: calling (pulsing status + Cancel), connected
  (talk indicator + End), reply shown (large reply text, auto-return countdown),
  unanswered (message + Call again). The SOS slide sits in the action zone's
  leading edge only where configured.

### Dashboard (indoor panel)

- Header: cluster clock and status chips (offline devices, SOS state, missed
  calls with badge).
- Door tiles in an adaptive grid (1 column compact, 2 medium, 3–4 expanded):
  live/still preview, door name, last activity, state chip (idle, ringing,
  in call, offline). Tap opens live view; a ringing tile is highlighted.
- Secondary destinations: History, Monitor, Settings via the tab bar or side
  navigation.

### Incoming call

- Full screen, always wins over other screens (see the iOS router).
- Portrait: video top (16:9, letterboxed), door name + purpose + visitor
  language under it, action zone at the bottom.
- Landscape/expanded: video left (≥ 60% width), details and actions in a right
  column.
- Actions, in this order: **Answer** (positive, largest), **Reply** (opens the
  quick-reply sheet), **Ignore** (local only). Secondary row: Monitor/listen,
  Unlock (only when configured), Mic mute in call. In call, **End** replaces
  Answer in the same position.
- Quick-reply sheet: bottom sheet (compact) or popover/side sheet (expanded),
  one tap sends; the call screen stays underneath and alive.

### Live view / monitor

- Video fills the available area; overlay controls auto-hide after 4 s and
  reappear on tap. Pinch/double-tap zoom where the platform supports it.
- Door switcher as a horizontal strip (compact) or side list (expanded).

### History

- Grouped by day; each row: time, door, purpose, outcome icon (answered,
  missed, replied, cancelled), thumbnail when present. Unread missed calls are
  marked; marking seen applies only to what the user has displayed.
- Expanded: list left, detail (snapshot, timeline) right.

### Settings

- Compact: grouped list → drill-down detail with back navigation.
- Expanded: master–detail; left grouped category list with icons and search,
  right grouped inset sections. Row = label + secondary text + native control.
- Destructive or security actions (rotate cluster key, rebuild cluster, remove
  device, factory reset) sit at the bottom of their section, in `negative`
  color, with a confirmation that names the consequence.
- Changes that require the admin window prompt for the admin password once per
  window, never per control.

### Pairing

- Unpaired device: large 8-digit confirm code, device name, and status in the
  center; instructions below; QR when available.
- Adding a device: list of discovered devices → enter its confirm code → result.
- "Re-pair required after upgrade" is a full-width warning state with one clear
  action.

### SOS

- Active SOS: full-screen `negative` overlay that cannot be hidden by other
  screens, source and time, one "Clear" action that needs a deliberate gesture
  (slide or long press) and the admin rules already defined in Core.

## 5. Platform notes

- **iOS / iPadOS**: UINavigationController, UISplitViewController (expanded),
  UITabBarController (compact), sheets/popovers. iOS 9 target uses availability
  adapters; inset-grouped style only on iOS 13+.
- **tvOS**: focus engine; large focus targets; no answer/mic controls.
- **iOS 5 kiosk (iPad 1)**: UIKit 5.1 only, two-pane layouts via a container
  controller; avoid continuous animation and offscreen rendering on the A4.
- **Android**: Material components where available on API 21+, plain views with
  the same metrics on API 19; navigation rail/side panel on ≥ 600 dp.
- **Windows (WPF, .NET 4.8)**: NavigationView-like left pane built from
  standard controls, touch-sized, DPI aware.
- **Web**: CSS grid with container/media queries for the three size classes,
  `dvh`/safe-area insets, native form controls, works without hover.

## 6. Acceptance

A screen is done when, at compact and expanded sizes and in ja/en/zh at 200%
text, the primary action is visible without scrolling, nothing overlaps or
clips, every target meets the minimum size, and the layout matches this
document. Web is checked with screenshots; native shells list the device/size
combinations still to check on hardware.
