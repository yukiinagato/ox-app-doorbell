# Android 門口機のプロビジョニング (kiosk / Device Owner)

対象: `android/` の門口機アプリ (`jp.keihan.doorbell`)。minSdk 21 — Android 5.0 以降の
廃品タブレット・スマホを門口機に転用する。Windows 版の
`deploy/provision/windows/provision.cmd` に相当する手順。

## 1. 事前準備 (端末側)

1. 端末を**初期化** (設定 → システム → リセット)。Device Owner 化は
   「アカウント未追加のセットアップ直後」しかできない。
2. 初期セットアップで **Google アカウントを追加しない** (スキップする)。
3. 開発者向けオプションを有効化 (ビルド番号 7 連打) → **USB デバッグ** を ON。
4. Wi-Fi を宅内 LAN に接続 (メッシュは同一セグメント前提 — docs/ja/network-ports.md)。

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
- **ロック画面**: DO なら起動時に自動で無効化される (`setKeyguardDisabled` + 給電中常時点灯 +
  システム更新ポップアップの延期)。**非 DO 端末は 設定 → セキュリティ → 画面ロック = なし を手動設定**
  すること (ロック画面に入ると着信画面が遮られる — 着信 Activity 自体は showWhenLocked で
  ロック画面上にも出るが、平時の待機画面は覆われる)。

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

## 8. Android TV (室内モニタ端末)

同一 APK を Android TV に入れると室内モニタ端末になる: 呼出ボタンが押されると視聴中の画面の上に
来客モニタ画面が全画面で被さり、門口機のカメラのライブ映像 + 門口機のマイクの音声が出る。
テレビリモコン (D-pad) でクイック返信を選んで応答できる。

### 8.1 接続とインストール

```sh
# TV 側: 設定 → デバイス設定 → 開発者向けオプション (ビルド 7 連打) → USB/ネットワークデバッグ ON
adb connect <TVのIP>:5555
adb install -r app/build/outputs/apk/release/app-release.apk
```

### 8.2 boot.json (TV は indoor_panel)

```sh
cat > boot.json <<'EOF'
{ "name": "living-tv", "role": "indoor_panel",
  "listen_port": 47172, "http_port": 47180, "psk_hex": "<64hex>",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": false }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"   # debug ビルド
adb shell rm /sdcard/boot.json
```

kiosk は **false** (TV は普段テレビとして使う)。管理画面から
`devices.<tv_node_id>.local.tv = true` を目印として立てておく (docs/ja/config-schema.md)。

### 8.3 権限 (来客時に前面に表示するための必須設定)

Android 10+ はバックグラウンドからの画面起動を制限する。TV では「他のアプリの上に表示」
を許可すると免除される (adb だけで完結):

```sh
adb shell appops set jp.keihan.doorbell SYSTEM_ALERT_WINDOW allow
# モニタリングに SIP は使わないが確認: 通知 (常駐サービス用, Android 13+)
adb shell pm grant jp.keihan.doorbell android.permission.POST_NOTIFICATIONS 2>/dev/null || true
```

Device Owner にできる TV (初期化直後) なら §3 の DO 化でも良いが、TV は視聴が主用途
なので通常は上記 appops のみで足りる。

- 常駐: フォアグラウンドサービス (通知 1 本) + BOOT_COMPLETED 起動。TV の省電力 kill は緩いが、
  初回はランチャーから一度アプリを開いて常駐を開始させること。
- 来客時に鳴る条件は fleet 設定の trigger_rules (chime アクション) — devices 省略時は
  indoor_panel 全台が対象なので TV は既定で鳴る。

### 8.4 音声モニタリングと Asterisk

TV のモニタリングは **Asterisk を経由しない**。TV → 門口機の SIP 待受 (UDP `sip.direct_port`,
既定 47190) へ直接 INVITE し (`X-Doorbell-Mode: monitor`)、門口機はマイク音声のみを
一方向で返す (在宅側の音は流れない)。したがって:

- **Asterisk 側の設定変更は不要** (dialplan 変更不要・TV 用内線アカウント不要)。
- config `sip.server` が未設定の宅でも TV モニタリングは動く。
- 門口機が Asterisk 通話中 (呼出中) でもモニタ呼は追加受理される (最大 2 本)。
- LAN のファイアウォールを絞る場合は UDP 47190 (SIP) と UDP 4000-4099 (RTP) を
  子機間で開ける (docs/ja/network-ports.md)。

### 8.5 動作確認

1. 門口機の呼出ボタン (または `curl -X POST http://<門口機>:47180/api/press`) を押す。
2. TV の視聴画面の上に来客モニタが出て、映像 + 門口機の音が出ること。
3. D-pad 上下で返信を選び決定 → 門口機にパネル表示 + TTS 読み上げ → 「送信しました」。
4. BACK (戻る) で閉じる → モニタ呼が切れる (門口機ログ: モニタ呼 終了)。
