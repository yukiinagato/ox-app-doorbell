[日本語](ipad1-jailbreak.ja.md) | [English](ipad1-jailbreak.en.md) | [繁體中文]

# 部署 iPad 1 compatibility node

本程序適用於受控、已越獄的 iOS 5.1.1 iPad 1 (A1219/A1337)，不代表硬體已認證。依
[maintainer runbook](../../../docs/zh/ios-compat-maintainer.md) 記錄裝置、artifact、package、jailbreak
環境與測試結果。

## 硬體限制

iPad 1 有內建麥克風與揚聲器，但沒有 camera。只有在該裝置的 MiniSIP/RemoteIO input 與雙向 audio
通過後才使用內建麥克風。影像使用明確外部 MJPEG/snapshot/RTSP camera 或 no-video mode。bounded
RTSP/RTP-over-TCP H.264 ingest 與 Annex-B 轉送已通過 host/loopback contract，包括 SDP/sprop、single
NAL/STAP-A/FU-A，以及 loss 後等待 next IDR。runtime 在 DESCRIBE、SETUP 與實際 IDR accept 前維持
degraded；iPad 1 搭配真實 camera 尚未 qualification。

另一條 Core fMP4 playback path 已通過 bounded 實機 smoke：Android 14 door station 畫面在 foreground
iPad 1 以 15–16 fps 顯示，Wi-Fi rejoin 與 post-safe-mode recheck 也通過。external-camera RTSP ingest
與 crash 後 unattended foreground video resume 仍未 qualification。參考
`docs/evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md`。

shell direct playback HTTP(S) MJPEG/snapshot。camera credential 保持在 `secret_ref` 後方，只解成
ephemeral Basic/Bearer request header；拒絕 URL credential 並保留 platform TLS validation。此 JPEG
path 只作 local preview (`jpeg_core_forwarding:false`)，不是 Core/mesh camera feed。

裝置不是戶外產品。入口安裝需要防水、防凝露、溫控、連續供電 enclosure，以及 battery/cable/
thermal 檢查。

## controlled install

1. 依 jailbreak upstream 文件操作並建立唯一 host access credential；不得使用或記錄共用/default
   credential。
2. 在 controlled host 執行：

   ```sh
   ios-compat/scripts/test_host.sh
   ios-compat/scripts/build_core_ios5.sh
   ios-compat/scripts/build_core_ios5.sh --install
   ios-compat/scripts/build_app_ios5.sh
   ios-compat/scripts/build_deb.sh
   ```

3. 驗證 manifest、package 內容/digest、rollback package，再用
   `ios-compat/scripts/install_deb.sh` 安裝。SSH direct copy 只作維護 fallback。該 fallback 在終止 app
   前寫入 root-owned maintenance-restart marker，避免把有意的更新計入 crash loop。
4. 從 app pair，確認 Core 先在 Keychain 保存 `mesh.psk`，之後只發出
   `{t:"paired", psk_ref:"secret:mesh.psk"}`，而 `boot.json` 只有該 reference 與非秘密欄位。
   `pairing_persistence_error` 必須維持 not-ready，不得把 PSK 貼入檔案。
5. 外部 camera 使用 `ios-compat/profiles/` 範例，credential 放在 `secret_ref`。禁止 URL userinfo，
   不可從 seed peer 推測 camera。RTSP 必須驗證在 IDR accept 前保持 degraded，且 packet loss 後會
   回到 next-IDR recovery。

驗證 cold boot、targeted ring、duplicate/stale/cancel、內建 mic/speaker、MiniSIP/DTMF、media/RTSP/no-video、
Wi-Fi/peer/process/memory/power/rollback、kiosk maintenance 與 enclosure long soak。optional root keepalive
helper 已實作並通過 host test，也能產生可重現的 armv7/iOS 5.1 staged DEB。package 只安裝 binary 與未啟用
的 launchd template；一般 app provisioning 只執行 `ios-compat/scripts/install_helper_ios5.sh --stage`，不得
直接啟用。iPad helper qualification 仍未完成；只有取得明確批准後，才能用
`DB_CONFIRM_ROOT_HELPER=YES ... --enable` 驗證 root-owned plist、UID/GID/socket permission、maintenance
lease、crash/hang safe mode、rollback 與 soak。在實機通過前不得依賴。置於隔離 trusted LAN，勿向
Internet 暴露 SSH/MiniSIP/mesh/HTTP/camera。
