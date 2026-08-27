# Android 門口機のプロビジョニング (kiosk / Device Owner)

対象: `android/` の門口機アプリ (`jp.keihan.doorbell`)。minSdk 21 — Android 5.0 以降の
廃品タブレット・スマホを門口機に転用する。Windows 版の
`deploy/provision/windows/provision.cmd` に相当する手順。

## 1. 事前準備 (端末側)

1. 端末を**初期化** (設定 → システム → リセット)。Device Owner 化は
   「アカウント未追加のセットアップ直後」しかできない。
2. 初期セットアップで **Google アカウントを追加しない** (スキップする)。
3. 開発者向けオプションを有効化 (ビルド番号 7 連打) → **USB デバッグ** を ON。
4. Wi-Fi を宅内 LAN に接続 (メッシュは同一セグメント前提 — docs/network-ports.md)。

## 2. インストール

```sh
# ビルド (開発機):
cd android && ./gradlew assembleRelease   # または assembleDebug
adb install -r app/build/outputs/apk/release/app-release.apk
```

## 3. Device Owner 化 (完全 kiosk に必須)

```sh
adb shell dpm set-device-owner jp.keihan.doorbell/.AdminReceiver
```

成功すると `Success: Device owner set to package jp.keihan.doorbell` と表示される。

- `java.lang.IllegalStateException: Trying to set the device owner, but device owner is
  already set` → 手順 1 の初期化をやり直す (既存アカウント/既存 DO が残っている)。
- Device Owner にすると本アプリが `setLockTaskPackages` + `startLockTask` で
  **完全ピン留め** される: ステータスバー・ホーム・戻る・最近のアプリが全て無効。

## 4. boot.json 配置

アプリ初回起動で `filesDir/boot.json` に既定が生成される。編集して差し替える:

```sh
adb shell "run-as jp.keihan.doorbell cat files/boot.json"   # 確認 (debug ビルドのみ run-as 可)
cat > boot.json <<'EOF'
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_hex": "<64hex>",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"
adb shell rm /sdcard/boot.json
```

release ビルド (run-as 不可) は管理 webui (`http://<端末>:47180/admin/`) から投入するか、
DO 経由の managed configuration を使う (Phase 3 後半)。

## 5. HOME (起動器) 置き換えと自動起動

MainActivity は `android.intent.category.HOME` を持つ。kiosk=true ならば:

```sh
# 既定ホームに設定 (機種の設定 UI: 設定→アプリ→既定のアプリ→ホームアプリ → ドアホン)
# DO 化済みなら adb からも可:
adb shell cmd package set-home-activity jp.keihan.doorbell/.MainActivity
adb reboot   # 再起動して自動起動 (BOOT_COMPLETED + HOME) を確認
```

## 6. 管理入口 (kiosk 解除)

- 画面**右上の透明領域 (200dp 四方) を 5 秒以内に 7 回タップ** → PIN 入力。
- PIN は `filesDir/exit_pin.txt` の SHA-256 hex。無ければ既定 `000000` —
  **設置時に必ず変更する**:

```sh
printf '%s' '123456' | shasum -a 256 | cut -d' ' -f1 > exit_pin.txt
adb push exit_pin.txt /sdcard/ && adb shell "run-as jp.keihan.doorbell cp /sdcard/exit_pin.txt files/"
```

- 5 回失敗で 10 分ロック (プロセス内)。成功で lock task を解除しアプリを閉じる。

## 7. kiosk を完全に外す (撤去時)

```sh
adb shell dpm remove-active-admin jp.keihan.doorbell/.AdminReceiver   # DO 解除 (API による)
# 解除できない機種は端末初期化が確実
adb uninstall jp.keihan.doorbell
```
