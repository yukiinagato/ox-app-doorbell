# T27 configuration editor migration

The production source is identified by `source-final.json`. Every modal receives its own immutable configuration base and opaque revision from `openModal`; inline settings use the snapshot captured by `renderTab`. Secret staging captures that same editor before its first asynchronous request. No helper substitutes the latest revision for an old draft.

| Modal | Production entry point | Commit route |
| --- | --- | --- |
| Building | `editBuilding` | `saveAndRefresh` → conditional config service |
| Door | `editDoor` | `saveAndRefresh` → conditional config service |
| Notice preset | `addNoticePreset` | Whole-array intent → conditional config service |
| Door unlock | `editDoorUnlock` | Typed sets and explicit clears → conditional config service |
| Notice | `editDoorNotice` | The same rebase/choice controller, dedicated conditional notice POST; Core stamps times |
| Device | `editDevice` | `saveAndRefresh` → conditional config service |
| Semantic UI | `editDeviceUi` | Whole semantic write root plus explicit `remove_fields` |
| Device volume | `editDeviceVolume` | Typed values or explicit inheritance deletes |
| Rule | `editRule` | Complete editor proposal converted to typed intents; action arrays remain whole values |
| Quick reply | `editQuickReply` | `saveAndRefresh` → conditional config service |
| Speech | `editSpeechSettings` | Secret staging, conditional config service, outcome-aware cleanup |
| Household | `editHousehold` | `saveAndRefresh` → conditional config service |
| Visit purpose | `editPurpose` | `saveAndRefresh` → conditional config service |

Inline callers of `saveAndRefresh` and `savePlanAndRefresh` share the rendered base: notice presets, entity deletions, video playback profiles, rule enablement/call flow, quick-reply and purpose order, MQTT/Telegram/Web Push/SIP settings, quiet hours, time settings, volume/SOS presentation, text overrides, appearance/theme/screensaver overrides, and related reset buttons. Both direct `postEntries` callers (raw key/value editing and current import UI) now use the same conditional service. Raw/import object values remain patches; their omitted fields never imply deletion. This is not the staged/preflight import work assigned to T29/T30.

Builders that clone their full original entity before clearing an editable field explicitly opt into conversion of those cleared fields to delete intent. The actual wire always uses `delete` or `set.remove_fields`; missing JSON members are never used as wire deletion instructions. Unknown fields survive because the existing lossless builders retain them, and three-way comparison emits only changed fields. A semantic reset and sibling edit share one set operation, retaining the Core manifest validation boundary.

Dedicated non-editor actions are separate: pairing/removal, asset upload/deletion, panel-token rotation/provisioning, secret provisioning, call/door actions, SOS and time-sync commands are not transformed into configuration CAS operations. Existing notice clear actions remain dedicated DELETE actions, not stale form submissions. T28 distributed conflict storage and T29/T30 staged import remain outside this task.

Configuration-related locations in the final UI source:

- `configIntents`, `configRebase`, `configIntentOps`: typed comparison, explicit removal and grouped semantic operations.
- `postEntries`: conditional commit, fresh snapshot after 409, one automatic rebase, at most three commits per save attempt, explicit choices thereafter.
- `openModal`: modal base and revision ownership; original DOM survives failure and authorization expiry.
- `suspendInlineDraft` / `restoreInlineDraft`: changed non-sensitive inline DOM and original base survive login; raw JSON and sensitive fields are cleared.
- `refreshConfig`: reads the coherent `/api/config/snapshot` envelope; no fallback to an unconditional legacy mutation.
