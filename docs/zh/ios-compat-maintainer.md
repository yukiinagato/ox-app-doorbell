# iOS compatibility 維護者 runbook

本 runbook 適用於 iOS 5.1/armv7 的共用 `ios-kiosk` Objective-C shell 與中立
`ios-compat` 工具。不得替封存的 `ios-legacy` 新增功能。iOS 9 使用共用 Swift source 與獨立
build/signing lane。

## 硬體與安裝條件

第一代 iPad (A1219/A1337) 有內建麥克風與揚聲器，但沒有相機。內建麥克風可在實機完成
MiniSIP/RemoteIO commissioning 後提供輸入；不得寫成必須外接麥克風，也不得在測試前宣稱雙向通話
成功。若作 door station，必須明確綁定外部 camera，或顯示誠實的 no-video UI。

`door_station` 是 software role，不是戶外防護等級。iPad 並非戶外產品；入口安裝需要防水、防凝露、
溫控、連續供電、strain relief、安全維修斷電與 battery 檢查，並以實際季節溫濕度認證。

## 準備 controlled build host

使用合法的本機歷史 Apple SDK 與 compatibility libc++，不得 commit SDK/toolchain binary、簽署金鑰、
jailbreak package 或生成 archive/app。隔離 iOS 5 armv7、iOS 9 armv7/arm64、modern、simulator、SIP
與 signing profile 的 artifact lane。

## host 與 artifact gate

```sh
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_core_ios5.sh --install
ios-compat/scripts/build_app_ios5.sh
```

release 使用 clean tree。dirty integration build 同時需要 `DB_ALLOW_DIRTY=1` 與唯一 `DB_BUILD_ID`，
且不算 release 證據。檢查 manifest 的 revision、build identity、target、architecture、minimum OS、
dependency 與 digest。package install 使用 `ios-compat/scripts/build_deb.sh` 並驗證 rollback package。
direct-copy script 只是維護路徑；host access credential 不得寫入 repository、command、URL 或文件。

## pairing 與 media

使用 app pairing flow。Core 先透過 `secure_put` 將 `mesh.psk` 寫入 Keychain，再只向 shell 發出
`{t:"paired", psk_ref:"secret:mesh.psk"}` 供其保存，不傳送新的 `psk_hex`。Keychain 保存失敗時必須
發出 `pairing_persistence_error`，client 不得進入 ready。

外部 camera 依 `ios-compat/profiles/` 明確設定 `devices.<id>.local.camera.source_ref` 與
`media_sources.<id>`。URL 禁止 userinfo，credential 放在 `secret_ref` 後方；seed peer 不是 camera source。

目前 shell 支援 HTTP(S) MJPEG direct preview、HTTP(S) snapshot polling，以及 RTSP/RTP interleaved TCP 的
bounded baseline H.264 ingest。host/loopback contract 已驗證 SDP/`sprop-parameter-sets`、single NAL/
STAP-A/FU-A depacketization、封包遺失後等待 next IDR，以及向 Core 轉送 Annex-B。RTSP 宣告起初維持
`rtsp_ingest_pending` degraded state；只有 DESCRIBE、SETUP 成功且完整 IDR 實際被 Core 接受後，才可
advertise `rtsp_h264_forwarding`。HTTP camera 認證只在 request 時將 `secret_ref` 解成 ephemeral
Basic/Bearer header，保留 platform TLS validation 並拒絕 URL credential。JPEG 只在本機 render，回報
`jpeg_core_forwarding:false`，不成為 Core/mesh camera stream。RTSP 不是 direct fMP4 playback URL。
iPad 1 搭配真實 camera 尚未完成 qualification。

另一條 Core fMP4 playback route 已有 bounded 實機 evidence：Android 14 door station 的
`/stream.mp4` 在真實 iPad 1 foreground renderer 持續 15–16 fps、觀測 latency 20–33 ms，Wi-Fi rejoin
與 post-safe-mode recheck 均通過。這不代表 RTSP ingest 或 crash 後 unattended foreground resume 已
qualification。[device-smoke record](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md)。

## 實機 commissioning

記錄 model、OS build、jailbreak/tool version、revision、manifest、package digest、enclosure/power，並驗證
cold boot、pairing/secure-store migration、schema-v2 響鈴、內建 mic/speaker、MiniSIP/DTMF、media/RTSP
fallback 與 IDR capability gate、
reply/cancel/unlock/SOS、Wi-Fi/peer/process/memory/power/rollback 與長時間 thermal/memory soak。

受控 memory-warning qualification 應暫時將 `debug.ui_dumps` 設為 `true`，保持 app 在 foreground，並在
裝置執行 `/usr/bin/uiopen doorbell://memorypressure`。diagnostics 未啟用或 app 位於 background 時 URL
會被拒絕；允許時會使用與 UIKit 真實 memory warning 完全相同的 release/safe-mode handler。確認 runtime
的 `memory_pressure.last_source=diagnostic_url`、counter 增加、optional video 已釋放，且 bounded
JPEG/audio fallback 仍可用；完成後恢復 `debug.ui_dumps=false`。這只 qualification handler，不代表
OOM kill 或 long soak 已通過。

optional root helper 已在 `tools/helper/doorbell_keepalive.c` 實作並有非 root host test。使用
`DB_ALLOW_DIRTY=1 DB_BUILD_ID=<reviewed-id> ios-compat/scripts/build_helper_ios5.sh` 可產生可重現的
armv7/iOS 5.1 staged DEB。package 只安裝 binary 與未啟用的 launchd template，不會啟用 root service；
可用 `SSHPASS=<commissioned-password> ios-compat/scripts/install_helper_ios5.sh --stage` 檢查。iOS 實機
qualification 仍未完成。只有裝置明確 opt-in 時，才以 `DB_CONFIRM_ROOT_HELPER=YES` 執行 `--enable`，並
commission root-owned plist、正確 UID/GID/socket permission、maintenance lease、hang、2/5/10/30/60 秒
backoff、5 分鐘 3 次的 safe mode、rollback 與 soak；在此之前仍須維持沒有 helper 的復原能力。host
test 會在 CI 的 `keepalive-helper` job 與 `ios-compat/scripts/test_host.sh` 中執行。installer 預設
透過 `iproxy` 的 local port 2223（可用 `DB_IOS_SSH_LOCAL_PORT` 覆寫），並保留 iOS 5 sshd 需要的
legacy KEX/cipher/MAC 選項。

commissioning 前必須了解的 rail：

- `ios5` profile 會先等 boot grace，再確認 app UID 所有的 `SpringBoard` process 才 launch，因此
  cold boot 不會消耗三個 failure slot；
- 尚未送出 heartbeat 但正在執行的 app 會被視為 `launch_pending_no_heartbeat` 而不重新 launch；
  app 也會從 bootstrap setup 送出 `started`；
- `/var/db/doorbell-keepalive.disable` 是 root 專用 kill switch，強制 mode 為 `off` 但不改寫已持久
  化的 mode（`--disable-file` / `--enable-file`）；
- safe mode 中 launch 超過 10 次後停止 launch（`launch_inhibited`），僅回應 status/control；
  `--clear-safe-mode` 刪除 root 所有的 marker 以重置；
- `install_via_ssh.sh` 與 `install_deb.sh` 會在 kill 前後取得 300 秒 maintenance lease，因此
  helper 運作中的 app upgrade 不會被計為 crash；
- iOS 5 的 SSH session 執行 `launchctl load` 常會回報 `Socket is not connected`。installer 在確認
  socket 與 status file 之前不會回報成功，而是輸出重開機指示並以 40 結束。

實機 checklist（cold boot ×3、未 provisioning boot、kill、hang、crash loop、launch cap、
maintenance lease、permission 拒絕、mode wiring、kill switch、helper 運作中的 upgrade、斷電、
soak、rollback）詳見 `ios-compat/helper/README.md`。

## release record

local 且未 push 的 `ios-legacy-0.2.0-final` tag 已存在，但此 working tree 的 `ios-compat` 尚未 tracked，
fresh clone 不含 migration tooling。migration tracked 且 fresh-clone/實機 smoke/rollback/docs/tag approval
gate 完成前保留 `ios-legacy`。
