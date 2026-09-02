# iOS kiosk client

`ios-kiosk` 是越獄 iPad 1 / iOS 5.1 compatibility target 的 Objective-C kiosk client。
English [`README.md`](README.md) 為正準。

共用 compatibility foundation、host tests、歷史 SDK build entry 與 optional root-helper
contract 位於 `ios-compat`。維護時使用：

- [`../docs/zh/ios-compat-maintainer.md`](../docs/zh/ios-compat-maintainer.md)
- [`../ios-compat/README.md`](../ios-compat/README.md)
- [`../ios-compat/helper/README.md`](../ios-compat/helper/README.md)

`ios-legacy` 是 archive，不再增加功能。local 且未 push 的
`ios-legacy-0.2.0-final` tag 已存在，但此 working tree 的 `ios-compat` 尚未 tracked；fresh-clone、
iPad 實機與 rollback gates 未完成，所以目前保留 `ios-legacy` directory。

不得把 credential 寫進 script、command line、URL 或 `boot.json`。pairing 必須先透過 platform
secure-store callback 保存 `mesh.psk`，再只公開 `psk_ref:"secret:mesh.psk"`；
`pairing_persistence_error` 不是 ready state。

## 硬體與 media 限制

iPad 1 有內建麥克風與揚聲器，但沒有 camera。只有 exact-device MiniSIP/RemoteIO test 通過後才宣稱
雙向 audio。它不是戶外產品；入口使用需要另外 qualification 的防水、防凝露、溫控 enclosure、
受保護電源與 battery/cable 維護。

明確 IP-camera source 可提供 HTTP(S) MJPEG/snapshot direct playback，或 bounded RTSP/TCP H.264
ingest。HTTP credential 保持在 `secret_ref` 後，只成為 ephemeral Basic/Bearer header，並保留
platform TLS validation；URL credential 會被拒絕。JPEG 只是 local preview
(`jpeg_core_forwarding:false`)。H.264 在完整 IDR 被 Core 接受前保持 degraded，且目前沒有真 camera
通過 iPad 1 qualification。

手動住戶接聽只把 exact `door`/`call_id`/`stage_revision` bind 到 answer-mode SIP dialog。monitor 不
擁有 visitor call；同時接聽的 loser hangup 時不能結束 winner。safe mode 保留 Core、MiniSIP audio、
ringer、SOS 與 controls，停用 H.264/custom visual，並在存在時使用 bounded low-resolution
MJPEG/snapshot。

## Build 與驗證

從 repository root 執行 neutral compatibility scripts：

```sh
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_app_ios5.sh
```

iOS 5 device lane 需要已授權的 local historical SDK 與 compatibility libc++。不得 commit SDK、signing
material、generated static archive、jailbreak credential 或含 secret 的 device log。host build 成功不
等於 iOS 5 硬體 qualification；正式標記前必須完成 maintainer runbook 的 cold boot、audio、call
lifecycle、recovery、長時間 soak 與 rollback checks。
