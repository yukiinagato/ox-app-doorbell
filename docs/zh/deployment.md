# 部署指南

先依 [capability matrix](capability-matrix.md) 選擇目標，再逐裝置、OS/韌體、media path、enclosure 與
signed artifact commissioning。compile 成功不等於硬體認證。

## 1. trusted network 與 integration

- 將 [ports](network-ports.md) 限於 trusted LAN；遠端 access 使用 VPN 或有驗證的 TLS reverse proxy。
  不可直接向 Internet 暴露 node HTTP/mesh/MiniSIP/MQTT/camera。
- 只配置所需的 Asterisk、MQTT/HA、Telegram、go2rtc/HomeKit，並測試服務中斷時的行為。
- 檢查 battery/power；入口裝置需要戶外防水、防凝露、溫控 enclosure。

## 2. build 與 qualification artifact

- 執行 common check 與 platform release gate，驗證真實 PJSIP、target/arch/min OS/API/dependency/source/
  signing identity。Android API 19、Windows VM/Toughpad、iOS 9 在未完成驗證前不得宣稱已認證。
  iOS 5 使用 [maintainer runbook](ios-compat-maintainer.md)。

## 3. 不以 plaintext secret 配對

使用 app/admin 的 bounded pairing flow，確認 parent 與新 node identity。Core 必須先完成
`secure_put("mesh.psk", …)`，之後只發出 `{t:"paired", psk_ref:"secret:mesh.psk"}`，shell 再把該 reference
與非秘密 bootstrap 欄位寫入 `boot.json`。`pairing_persistence_error` 必須維持 not-ready。SIP/MQTT/
Telegram/WebRTC/camera credential 透過支援 secure storage 的 UI/API 輸入，config 只存 `secret:` reference。

Web Push 必須在每個預定 `web_push` leader candidate 的 local secure store，以相同的已複製 reference
配置 VAPID private 值與可選的 sender bearer 值；之後才原子保存 [config schema](config-schema.md) 中的
HTTPS sender URL、VAPID public key/subject 與 secret reference。確認 status 有非空 Push leader 且
`delivery_backend:true`，不可只把 `configured:true` 當成 readiness。
shipping shell 在沒有 configured endpoint probe 時會回報 `wan:false`。逐一從候選節點實測能連到 exact
HTTPS sender 後，才設定該節點的 `caps_override.wan:true`；保留測試紀錄，network 改變時移除 override。
Push leader 也必須具備 `tls12`、`mains_power`、`wall_clock_sane` 與 `web_push_ready`。

不得將 cluster PSK、password、token、URL userinfo 或 signing secret 複製到 `boot.json`、CRDT JSON、
command、log 或文件。舊 `psk_hex` 僅供遷移輸入。

## 4. role 與行為

只設定 shell 實測的 capability。camera source 必須明確指定，不可從 seed peer 推測。iPad 1 有內建
mic/speaker、沒有 camera，應使用外部 MJPEG/snapshot/RTSP 或 no-video mode。bounded RTSP/TCP H.264
ingest 與 Annex-B 轉送已通過 host/loopback 驗證，但在 IDR 被接受前 runtime 維持 degraded，真實 camera
hardware qualification 尚未完成。

SOS rule 應明確設定 target/channel/presentation，並檢查 dry-run 的 zero recipient、silent、unsupported/
unavailable、Push subscription/backend warning；同時記錄 `emergency.web_active_page_alerts` 選擇。
逐一驗證各 Web group 的 `?group=` 同時控制 poll/Push、native-only target 不到 Web、rule TTL 後 raw-SOS
仍保留至 clear，以及 config/export 不含 plaintext Push endpoint/key。

## 5. commissioning 每個 node

記錄 artifact/signature/runtime status、ring/cancel/purpose/answer/hangup/reply/DTMF/unlock/SOS、重複或
過期 event、Core `delivery_result` dispatch evidence 與 client channel presentation report 的區別、
camera/audio/rotation/color/fallback/AEC、integration 中斷、network/peer/process/memory/
reboot/power/rollback、kiosk maintenance、thermal/battery 與長時間 soak。iOS root helper 已實作並通過
host test，也有不會啟用 launchd 的可重現 armv7/iOS 5.1 staged DEB，但實機 qualification 仍未完成。
明確 opt-in workflow、exact binary、root-owned launchd、UID/GID/socket permission、maintenance lease、
safe mode、rollback 與 soak 通過前不得依賴。

## 6. 維運與復原

舊 signed artifact 與 manifest 保留在獨立 rollback lane。config export 不含秘密實值，須與 secret backup
分開。依 [recovery](recovery.md) 與 [security](security.md) 操作。
