# iOS 子機のプロビジョニング (監督 SAM kiosk / Ad Hoc 配布) + tvOS 監視端末

対象: `ios/` の iOS アプリ (`jp.keihan.doorbell` — 門口機/室内機両用) と
tvOS アプリ (`jp.keihan.doorbell.tv` — 監視端末)。iOS 12 以降の廃品 iPhone/iPad を
門口機・室内機に転用する。Android 版 `deploy/provision/android/provision.ja.md` に相当。

## 0. ビルドと署名の全体像

- ビルド: `xcodebuild -project ios/Doorbell.xcodeproj -scheme Doorbell -sdk iphoneos`
  (要 Apple Developer Program のチーム設定 — Xcode で Signing & Capabilities から
  Team を選ぶだけ。CI では `-allowProvisioningUpdates` か手動プロファイル)。
  core (C++) は run-script が CMake で自動ビルドする — 開発機に `cmake` と `python3` が
  要るだけ。lane に一致する PJSIP artifact を先に `tools/build_pjsip_ios.sh` で作る。
  SIP stub build は development/display 専用で、通話 release として配布しない。
- 配布は **Ad Hoc** (家庭内の少台数前提):
  1. Apple Developer で各端末の UDID をデバイス登録 (上限 100 台/年)。
  2. Xcode → Product → Archive → Distribute App → **Ad Hoc** → ipa を書き出す。
  3. Apple Configurator (Mac に端末を USB 接続) で ipa をインストール。
- **証明書期限に注意**: Ad Hoc のプロビジョニングプロファイルは **1 年で失効**し、
  失効後はアプリが起動しなくなる。**年 1 回の再署名・再インストールが必須** —
  カレンダーへのリマインダ登録を強く推奨 (失効日は Xcode の Organizer か
  developer.apple.com の Profiles で確認できる)。長期運用を固めたければ
  App Store 配布 (unlisted app) か Apple Business Manager + カスタム App 配布へ移行する。
- 開発者アカウント無しの検証は「無料チーム + 7 日期限の署名」でも可 (毎週再署名が要る —
  常設運用には不向き)。

## 1. 事前準備 (端末側)

1. 端末を**初期化** (設定 → 一般 → 転送またはリセット)。**監督 (supervised) 化は
   初期化が必要** — Apple Configurator で「デバイスを準備」する時に消去される。
2. 初期セットアップは Apple Configurator の「準備」ウィザードに任せる
   (Apple ID サインインはスキップ)。
3. Wi-Fi を宅内 LAN に接続 (メッシュは同一セグメント前提 — docs/ja/network-ports.md)。
4. 設定 → 画面表示と明るさ → **自動ロック = なし** (監督端末のみ選べる)。
   アプリ側でも `isIdleTimerDisabled` で消灯を防ぐが、二重に保険を掛ける。

## 2. 監督化 + SAM (Single App Mode) — kiosk 堅牢化

iOS には Android の Device Owner に相当する常駐 kiosk 化として
**監督デバイスの Single App Mode** を使う (ガイドアクセスは手動解除できるため非常用)。

Apple Configurator (Mac App Store から無料) で:

1. デバイスを USB 接続 → 「準備」→ 監督する (組織を作成、監督識別証明書は保存しておく —
   以後の設定変更に必要)。
2. アプリ (Ad Hoc ipa) を「追加」→ App からインストール。
3. **Single App Mode**: 「操作」→「詳細」→「シングル App モードを開始」→ Doorbell を選択。
   以後、再起動してもこのアプリしか動かない (ホーム/通知センター/コントロールセンターは
   すべて封鎖)。解除も Configurator から (物理アクセス + 監督証明書が要る = 盗難対策)。
4. 推奨の追加プロファイル (Configurator → プロファイル作成):
   - ソフトウェアアップデートの延期 (門口機が勝手に更新画面へ落ちない)
   - パスコード不要化 (着信画面がロック画面に遮られない — SAM 中はそもそもロック画面に落ちない)

アプリ内の隠し管理入口 (右上 7 連打 → PIN テンキー) は SAM 中でも使える。SAM 有効化前に
承認済み保守経路で固有 PIN hash を設定し、共有値・factory 値のまま配備しない。
PIN が通ると保守情報 (node id / peers / data dir) を表示し自動消灯を一時解放する。
kiosk 自体の解除は SAM の性質上 Configurator からのみ。

## 3. boot.json 配置

初回起動で `Documents/boot.json` に既定が生成されます。Core 起動前に **門口機** または **室内機**
を選択します。門口機は door ID も必須で、そのまま確定できる random `door-xxxxxxxx` が入力済みです。
旧 profile に明示的な `setup_complete:true` がない場合は一度確認画面を表示します。保存済み role が不正、または門口機 ID が欠落した場合も画面を再表示します。室内機には door assignment
を保存しません。生成された profile の編集手段 (どれでも可):

- **Finder / Apple Configurator のファイル共有**: 現状アプリは File Sharing 非公開のため、
  管理 webui からの投入が基本 (下記)。
- **管理 webui**: 既に mesh に居る別ノードの `http://<ip>:47180/admin/` → デバイス →
  参加 PIN で本端末を招き入れる。
- PSK を手書きしない。pair 後の秘密を含まない永続形式は次のとおり:

```json
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_ref": "secret:mesh.psk",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
```

Core は先に `mesh.psk` を Keychain へ保存し、shell には
`{t:"paired", psk_ref:"secret:mesh.psk"}` だけを通知します。新しい `psk_hex` は渡しません。
`pairing_persistence_error` は not-ready のまま扱います。PSK、SIP password、token 等を
`boot.json` に置きません。

**seed_peers は iOS では必須**: iOS 14+ はマルチキャスト受送信に特別な entitlement
(com.apple.developer.networking.multicast — Apple への申請制) が要るため、core の
UDP beacon による自動発見は当てにしない。同一 L2 に seed 1 台あれば gossip が全員をつなぐ。
初回起動時に「ローカルネットワーク」権限ダイアログが出る — **必ず許可** (拒否すると
mesh に一切つながらない。設定 → プライバシー → ローカルネットワークで後から変更可)。

## 4. tvOS 監視端末 (DoorbellTV)

- Apple TV 4K/HD (tvOS 15+)。`-scheme DoorbellTV` でビルド、Ad Hoc は iOS と同様
  (Apple TV は Xcode → Devices and Simulators でネットワーク経由ペアリング)。
- 役割は Android TV と同じ: role=indoor_panel の常駐監視端末。来客で全画面着信
  (門口機のライブ MJPEG + クイック返信を Siri Remote で選ぶ)。SOS 警報の全画面表示 + サイレン +
  PIN 解除 (リモコンで描画テンキー操作) も出る。
- **制約**:
  - source は映像とクイック返信に加えて direct-SIP **listen-only audio** を実装する。tracked CI が
    証明するのは real PJSIP を link した unsigned arm64 DoorbellTV **Debug simulator** build だけで、
    tvOS Release/device artifact は生成しない。Apple TV は mic を持たないため Answer は意図的に
    非表示で、audio transmit/双方向通話は未対応。
  - tvOS はローカル恒久ストレージが無い (Caches は OS が随時掃除する)。boot.json 相当は
    UserDefaults に保持し、CRDT 設定・イベント DB は Caches — 消えても mesh から自動復元
    される (自己修復)。単独台だけで長期のイベント履歴を持ちたい用途には使わない。
  - フォアグラウンド前提 (tvOS アプリはバックグラウンド常駐不可)。ホームに戻されたら
    着信を受けられない — 運用は「Doorbell TV を出しっぱなし」+ 設定 → 一般 →
    スクリーンセーバ = 開始しない。

## 5. 動作確認チェックリスト

1. 起動 → 待機画面 (時計 + 呼出ボタン)。左下に `名前 · vX.Y.Z` が出る。
2. 管理 webui (別ノード) のダッシュボードに本端末が Online で載る (mesh 合流)。
3. 門口機: 呼出タップ → 室内機/TV に着信画面 + チャイム。用件ボタン/言語バーも確認。
4. 室内機: クイック返信 → 門口機に大きな文字での表示 + 読み上げ (AVSpeechSynthesizer)。
5. 室内機: モニタ → 門口機の音声が聞こえる / 応答 → 双方向通話 (VoiceProcessingIO の AEC で
   スピーカーフォン可)。
6. tvOS: tracked Debug simulator build は source/build contract としてだけ扱う。別途 signed device
   artifact を作成・記録し、exact Apple TV で Monitor audio/video と Answer/transmit control が無いことを確認する。
7. SOS 長押し → active rule が選んだ recipient/channel を確認 → PIN 解除。
8. 電源断→復電で自動復帰 (SAM が自動再起動) を確認。
