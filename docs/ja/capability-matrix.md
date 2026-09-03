# 機能・リリース状態マトリクス

このページをプラットフォーム対応状況の基準とします。ソースに処理があるだけでは、実機や
リリース成果物が本番利用可能になったことにはなりません。

## 状態の定義

| 状態 | 意味 |
|---|---|
| 実装済み | 現在のソースに処理があり、関連する自動契約テストがある。 |
| ビルド検証済み | 対象成果物そのものがビルド、ABI、依存関係、梱包ゲートを通過した。 |
| 実機認証済み | 記録された端末・OS・firmware の組合せが commissioning と soak を通過した。 |
| 未対応 | 処理が無い、意図的に無効、または capability として広告してはならない。 |

## 現在の状態

| 対象 | 状態 | 根拠と制限 |
|---|---|---|
| core mesh/CRDT/API/event/rule/call lifecycle、MJPEG/fMP4、ABI v2 | 実装済み | `call_answered`/`call_ended` は call-ID scoped。core tests と公開 ABI。 |
| リリース SIP | 条件付き | 成果物は `pjsip` を報告必須。`stub` は開発・表示専用で通話未対応。 |
| Android API 21+ | 実装済み、ビルド lane あり | modern tier/NDK r27。全端末を一括認証するものではない。 |
| Android modern critical-memory recovery | bounded 実機 smoke 合格、hardware certification ではない | moto g64y 5G/API 34 で実 `RUNNING_CRITICAL` trim 後も同じ process/foreground Activity を維持し、encoder release を記録、30 秒 protection window 後に `c2.mtk.avc.encoder` を再生成して有効な 640×360 fMP4 を配信した。[2026-08-31 evidence](../evidence/android-modern-memory-pressure-smoke-2026-08-31.md)。OOM kill、in-call audio、power、thermal、soak は未検証。 |
| Android API 19 armv7/NEON | 実装済み、lane あり、support SKU は 0 | qualification list は空。exact fingerprint と evidence artifact が codec/recovery/thermal/SIP/8 時間 soak gate を通るまで未 commission。CI の debug-key `debug-contract` APK は release ではない。 |
| Windows x86/x64 WPF | 実装済み、host contract/stub compile と opt-in self-hosted release gate あり | hosted stub は upload せず、real-PJSIP x86/x64 bundle は commissioned runner だけが upload。VM/Toughpad 実機認証記録はない。 |
| iOS 12+ | 実装済み、hosted simulator と unsigned device-link gate あり、署名実機検証が必要 | CI は keyed real-PJSIP simulator/iPhoneOS archive、iOS 12 simulator contract、unsigned arm64 device binary を build。camera/audio/SAM/recovery/signing/install/soak は実機 gate。 |
| iOS 9 arm64 | unsigned device-link proof あり、install/実機未検証 | unsigned `iphoneos` arm64/9.0 Release binary の ABI v2、min OS、real-PJSIP symbol、Swift runtime を検証するが、sign/install/launch/hardware test はしない。 |
| iOS 9 armv7 | formal profile/gate 実装済み、未 commission | historical Xcode 7/SDK、real-PJSIP、stock IPA/jailbreak package gate はあるが、commissioned runner artifact と実機結果はない。 |
| iOS 5.1 armv7 compatibility shell | 実装済み、host contract と licensed self-hosted artifact gate あり、実機認証待ち | armv7 app/package upload は licensed runner のみ。iPad 1 は内蔵 mic/speaker 有り、camera 無し。 |
| iPad 1 Core fMP4/H.264 playback | bounded 実機 smoke 合格、hardware certification ではない | Android 14 door station から Core `/stream.mp4` を配信し、iPad 1 の foreground renderer は 15～16 fps、観測 latency 20～33 ms を維持し、Wi-Fi rejoin と safe-mode exit 後も復旧、matching cancel で終了した。process crash 後の call identity/UI recovery は合格したが、optional helper 未導入のため relaunch は background-only となり unattended video resume は未合格。[2026-08-31 evidence](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md)。 |
| iPad 1 の外部 IP camera MJPEG/snapshot | 制限付きで実装済み | 明示的 `media_sources` のみ。HTTP(S) MJPEG/snapshot は shell が direct playback し、`secret_ref` を ephemeral Basic/Bearer header にだけ解決し platform TLS validation を使う。JPEG は local-only (`jpeg_core_forwarding:false`)。 |
| iPad 1 の RTSP/TCP H.264 ingest・転送 | 実装済み、host/loopback contract 検証済み、実機未 qualification | bounded path は SDP/`sprop-parameter-sets`、single NAL/STAP-A/FU-A RTP、loss 後の next IDR 待機、Core への Annex-B 転送を実装。DESCRIBE/SETUP 成功と実 IDR の Core accept までは `rtsp_ingest_pending` の degraded state で、`rtsp_h264_forwarding` を advertise しない。iPad 1 + 実 camera は未検証。 |
| optional iOS/rooted-Android keepalive helper | 実装・host test 済み、実機未 qualification | `tools/helper` に fixed local Unix transport、compiled launch profile、peer/PID check、永続 `off|auto|on`、maintenance lease、atomic status、2/5/10/30/60 秒 backoff、crash-loop safe mode がある。永続 `auto`/`on` は helper restart 後に cold launch し、`off` は動作中 app を kill せず disarm する。設定 mode は request のみで、実測 availability/effective mode に基づき advertise する。iOS 5 lane は launchd を無効のままにする再現可能な staged DEB を生成するが、実機合格証跡はない。 |
| tvOS listen-only direct SIP monitor | source 実装済み、tracked Debug simulator build、実機未 qualification | tracked job は unsigned arm64 `DoorbellTV` Debug を `appletvsimulator` + real PJSIP で build。tvOS Release/device artifact、sign/install、実 Apple TV audio/video は未検証。 |
| tvOS SIP Answer/transmit | 未対応 | Apple TV に mic がないため UI は Answer を意図的に隠し、transmit を advertise しない。 |
| browser WebRTC 通話 | 条件付き | Asterisk WebSocket/WebRTC と secure context が必要。MJPEG panel はマイク対応を意味しない。 |
| Web SOS active-page/Push presentation | 実装済み、browser/deployment qualification は別 | open page は replicated SOS を既定で表示。`emergency.web_active_page_alerts:false` は raw-state 表示だけを止め、positive matching `device_alert`/Push は表示可能。raw state 有効時、rule TTL は decoration/sound を終了しても安全な赤い overlay は clear まで残す。visual/sound/volume/sticky/TTL/color を検証・Push に保持するが、OS notification は custom color/audio を制限する場合がある。`?group=` の保存値を poll/Push で共用し、complete subscription secret は CRDT 内で XChaCha20-Poly1305 seal する。Core `delivery_result` は dispatch evidence で presentation proof ではない。 |
| Native/Web semantic UI manifest | durable native cache + local Web scope 制限付きで実装済み | Core は peer の last-valid native manifest/capability を永続化。configured offline device は `cached_contract:true` として検証/queue できるが renderer apply report は後で必要。別の `web_ui.manifest` は serving node local で remote Web catalog ではない。 |
| cross-platform conformance harness | golden model + source smoke | reference trace と狭い source literal を検査するだけで、client artifact、rendering、timing、hardware、release evidence ではない。 |

## 磨りガラス blur の方針

OS が effect を所有する場合は native system blur を正とします。特に modern iOS shell は
`UIBlurEffect` を維持し、数値 radius を提供するためだけに custom renderer へ置き換えません。
Apple は `UIBlurEffect` の public radius を提供しないため、この shell では radius control を
表示せず、Web の device editor は保存値が適用されたように見せず system-managed と説明します。

数値の磨りガラス radius を提供できるのは、shell 自身が blur renderer を所有する場合、または
platform の public API が実際の radius parameter を提供する場合だけです。未対応 shell は設定を
無視し、適用済み capability として advertise してはいけません。これは presentation capability
であり、OS 間で見た目を完全一致させるためのものではありません。

iOS 5 compatibility shell は OpenGL ES 2.0 の offscreen framebuffer で横・縦を二巡する
separable blur を使用できます。background image、target size、radius の変更時だけ render して
結果を cache し、memory pressure/backgrounding では GPU resource を解放します。ES 2.0 context、
framebuffer、shader、texture allocation が使えない場合は bounded CPU blur に fallback します。
`CIGaussianBlur` は iOS 5 では利用できないため Core Image を fallback にしません。GPU 利用と
timing は compile だけでは証明できず、exact iPad 1 qualification の対象です。

## 現行 release gate

対象の tests/lint、English-source/i18n check、成果物 metadata、実 PJSIP、lane 分離、secure
store、署名、端末別の media/audio/call/kiosk/recovery/power/network/thermal/soak をすべて確認します。
公開 PR を trusted signing/jailbreak runner で実行しません。

現時点では Android API 19 の合格 SKU、Windows VM/Toughpad、iOS 9 armv7 commission、iOS 9
arm64 signed device、tvOS Release/device、iPad 1 camera/audio/enclosure の完了証跡はありません。
local `ios-legacy-0.2.0-final` tag はありますが、この working tree の `ios-compat` は未 tracked で
fresh-clone/device/rollback gate が未完了のため、`ios-legacy` は現時点で保持します。
