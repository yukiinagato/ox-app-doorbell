# 復原與 rollback

self-healing 指 node 或選用 integration 回復後，複製狀態可以收斂；不代表所有平台都能無條件從
force-stop、kernel 故障、斷電、簽署過期或硬體損壞恢復。

逐裝置 `devices.<id>.local.recovery.helper_mode` 是 `off|auto|on` request policy。Admin 預設 `auto`，以
authenticated atomic batch 寫入；Core 拒絕其他值。platform 轉送 fixed `MODE`，helper 原子保存供 restart
復原。必須區分 configured mode 與實測 helper availability/effective runtime mode。helper 缺失、被拒或未
qualification 時，單有設定 `on` 不構成 capability。
持久化 `auto` 與 `on` 在 helper/OS restart 後都以 armed 狀態啟動，並可 cold-launch fixed app；只有
`off` 會持久 disarm supervision。切換至 `off` 不會終止已在執行的 app。Android `DISABLE` 是 `auto`
允許的暫時 disarm，不會變更持久 mode。

## 故障邊界

| 故障 | 預期路徑 | operator gate |
|---|---|---|
| view/activity 重建 | ringing 只由 press origin、in-call 只由記錄的 `dialog_owner` 依 exact `door`/`call_id`/`stage_revision` 復原；monitor 不擁有 visitor call | 驗證無重複響鈴、過期 call、event 遺失或 loser 結束 winner |
| process crash/hang | platform supervisor 以 backoff/circuit breaker 重啟 | 測試 crash/hang/memory pressure/safe mode |
| force-stop/service 抑制 | process 內機制可能無法恢復 | 實機 commissioning 外部 supervisor，或記錄限制 |
| node/network 中斷 | 標記 unavailable，恢復後 config/event 收斂 | 測試 partition/reconnect/clock skew/重複傳送 |
| HA/Asterisk 中斷 | 已設定的 mesh ring、local chime/rule、direct SIP 可繼續 | 外部 HA/PSTN/WebRTC 會停止，須以實際部署驗證 |
| config 損壞 | 有實作的平台回到原子保存的上一代，再從健康 peer 同步 | 驗證 secret reference 仍可解析 |
| 裝置遺失 | 輪換 PSK 與 integration/panel credential，重新 pair | 驗證舊 node/token 被拒絕 |

## backup 與 rollback 步驟

備份必須分離 config export 與 device-local secret。逐成品記錄 source revision、build ID、manifest/
checksum、OS/API、architecture、SIP backend、dependency hash、signing identity，並將舊 package 存於
獨立 lane。rollback 後重新驗證 pairing、capability/runtime status、media/audio/call/kiosk、斷電與
network loss。

## platform 注記

Android 的 process 內復原無法處理所有 force-stop。Windows watchdog 已實作，但仍待 elevated VM/實機
驗證。Windows safe mode 保留 Core/ringer/SOS/control/real-PJSIP audio，停用 custom visual/animation/
H.264；有 JPEG source 時使用 bounded low-resolution MJPEG。modern iOS 僅在 foreground 由 background queue
發送 bounded main-thread probe。連續三次約五秒失敗會記錄 `main_run_loop_stall_3x5s`；若實測 Guided Access
啟用，便以 `SIGABRT` 結束 process，讓 supervised kiosk 帶著 crash evidence 重新拉起。sentinel 在 background
disarm。依 Apple TN2448，`UIAccessibility.isGuidedAccessEnabled` 可量測 Guided Access 與 Single App
Mode；client 監聽其狀態變更通知、在 launch 兩秒後再次檢查，並維持有界的十秒複測。`auto` 保留已設定的
helper mode，量測 active 時續期短 maintenance lease；只有量測 inactive 時 helper supervision 才是 fallback。
其 modern launcher 仍是獨立 qualification gate。簽署期限也必須列入維運。iOS 5 safe mode 保留 Core/MiniSIP audio/ringer/SOS/control，停用
H.264 ingest/decode 與 custom visual；設定存在時 direct playback bounded low-resolution HTTP(S) MJPEG/
snapshot，否則回報 audio-only。JPEG 不 forward 到 Core。本機 crash/OOM safe mode 連續健康運行 5 分鐘
後自動解除，並在目前 process 恢復實測 media capability；root helper 仍回報 safe mode 時，以 helper 判斷
為準。optional iOS 5/rooted-Android helper 已實作並通過 host test。iOS 5 lane 有不會啟用 launchd 的
可重現 staged DEB，但兩個平台仍採獨立 provisioning，實機 qualification 尚未完成。root service、
UID/socket permission、maintenance lease、safe mode、rollback 與 soak 通過前不得依賴。

iOS 5 helper 會先等待 SpringBoard 才 launch。launchd 在 cold boot 時比 window server 早數分鐘啟動
helper，其間 `uiopen` 會無聲失敗，因此以 bounded boot grace 與 process table gate 延後第一次
launch；這段等待不計 failure，也不推進 backoff。launcher 以非 0 結束時回報為 `launcher_failed`，
而非 startup timeout。

尚未開始 heartbeat 但已在執行的 app（例如 bootstrap setup 中）以 process presence 偵測，回報為
`launch_pending_no_heartbeat`，既不重新 launch 也不計為 failure。app 端也會從 bootstrap setup
branch 送出 `started`。

系統要求的結束不是 crash。`stopping` heartbeat 之後的結束與 maintenance lease 期間的結束都會重新
launch，且不消耗 failure slot。app upgrade 會自動取得 maintenance lease，因此安裝不會被 helper 視為
crash loop。

有兩道絕對 rail：root 所有的 kill switch file（`/var/db/doorbell-keepalive.disable`）在下一個
supervision tick 將 mode 強制為 `off`，但不改寫已持久化的 mode；safe mode 中 launch 超過 10 次後
helper 完全停止 launch（`launch_inhibited`），僅繼續回應 status 與 control。刪除 root 所有的
safe-mode marker 可同時解除兩者；iOS 5 的 datagram socket 沒有 peer credential，這是受支援的解除
方式。
