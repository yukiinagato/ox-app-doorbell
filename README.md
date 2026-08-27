# app-doorbell — 多平台原生门铃系统

自宅（複数棟・複数玄関、同一 LAN）向けドアホンシステム。旧型・低スペック端末を玄関子機として再利用する。

- **doorbell-core**（C++17, C ABI）: P2P 自愈 mesh（確定的リーダー選出 + HLC + LWW-CRDT 設定複製）、SIP(PJSIP)、MJPEG 配信、内蔵管理画面(CivetWeb)、HA MQTT ブリッジ、Telegram 通知
- **プラットフォーム殻**: Windows (WPF/.NET FW 4.8, Win7 SP1+) / Android (Kotlin, minSdk 21 + legacy 19) / iOS (Swift, iOS 12 + legacy 9) / Web legacy (iOS 5 Safari 対応ページ)
- **統合**: Home Assistant (MQTT Discovery + go2rtc + HomeKit Bridge)、Asterisk + ひかり電話（通話は電話網へ）、Telegram Bot

実行計画: `~/.claude/plans/windows-toughpad-android-ios-app-home-a-quizzical-plum.md`

## リポジトリ構成

```
core/       C++17 共有コア（vendored: pjsip*, libjpeg-turbo*, civetweb, monocypher, sqlite, cJSON, doctest）
win/        WPF 子機 + watchdog + InnoSetup
android/    Kotlin 子機 (flavors: main/legacy)
ios/        Swift 子機 (targets: iOS12/iOS9)
webui/      管理 SPA + /panel/* legacy ページ（core に埋め込み）
i18n/       strings.yaml（ja 主）→ tools/gen_i18n.py で各形式生成
tools/      生成・ビルド・署名スクリプト
deploy/     Asterisk / HA / provisioning 設定サンプル
docs/       設置・運用・再署名 runbook
```
(* pjsip / libjpeg-turbo は Phase 1 で vendoring)

## ビルド（core, ホスト開発用）

```
cmake -S core -B build && cmake --build build -j && ctest --test-dir build
```
