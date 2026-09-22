# Admin modal save callers

All 13 production editor entry points were inspected and migrated to explicit completion. The existing ES5 callback style is retained; Promise support is not required.

| Editor entry point | Modal construction | Completion route |
| --- | --- | --- |
| `editBuilding` | `openForm` | `saveAndRefresh(..., done)` |
| `editDoor` | `openForm` | `saveAndRefresh(..., done)` |
| `addNoticePreset` | `openForm` | `saveAndRefresh(..., done)`; creates a fresh proposal per attempt |
| `editDoorUnlock` | `openForm` | `saveAndRefresh(..., done)` |
| `editDoorNotice` | `openModal` | Dedicated notice API; explicit successful/failed completion |
| `editDevice` | `openForm` | `saveAndRefresh(..., done)` |
| `editDeviceUi` | `openModal` | `saveAndRefresh(..., done)`; explicit completion for no changes |
| `editDeviceVolume` | `openModal` | `saveAndRefresh(..., done)` |
| `editRule` | `openModal` | `saveAndRefresh(..., done)` after synchronous presentation validation |
| `editQuickReply` | `openForm` | `saveAndRefresh(..., done)` |
| `editSpeechSettings` | `openForm` | `savePlanAndRefresh(plan, done)` after secret staging and config outcome |
| `editHousehold` | `openForm` | `saveAndRefresh(..., done)` |
| `editPurpose` | `openForm` | `saveAndRefresh(..., done)` after synchronous label validation |

The modal wrapper forwards completion through `openForm`. Each save attempt owns its editor, attempt sequence, and page epoch. A synchronous validation error is a failed editing state with no request; asynchronous success closes only the owning editor. An unknown save result retains the draft and cannot authorize rollback of a credential that the live configuration may already reference.

Existing inline settings continue to use the same save helpers. Failed saves no longer refresh/re-render these settings either. This task does not migrate legacy configuration writes to the pending C08 compare-and-swap protocol; that remains T27 after T26 verification.

See `evidence/after-source.json` for the reviewed file hash, `production-diff.patch` for the scoped implementation, and `report.zh.md` for actual test coverage and limitations.
