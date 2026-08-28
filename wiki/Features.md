# 機能総覧

> English: [Features-en](Features-en) / 中文: [Features-zh](Features-zh)

各機能の「何ができるか」を短くまとめます。使い方は [Usage-Residents](Usage-Residents) /
[Usage-Admin](Usage-Admin) / [Usage-Visitors](Usage-Visitors)、仕組みは [Architecture](Architecture) へ。

## 呼出

門口機の大ボタン (汎用) または用件ボタン 1 タップで押鈴。イベントはルールエンジンに入り、
SIP 発呼 / Telegram / HA イベント / 室内チャイム / 自動応答が設定どおり並行実行されます。
ドア別・用件別・時間帯別に分岐できます。→ [Usage-Admin](Usage-Admin)

## 用件ボタン (visit_purposes)

訪問 / 宅配便 / 郵便 / 営業・集金 / 検針・工事 / その他 — 既定 6 種、自由に編集可能。
宅配員は「宅配便」1 タップで押鈴まで完了します。用件は室内機・TV・Telegram・HA・管理画面の
すべてに表示され、ルールの分岐条件 (`when.purposes`) にも使えます。→ [Usage-Visitors](Usage-Visitors)

## 訪客言語切替

門口機に言語ボタン (日/英/中 — `ui.languages` で選択) を表示。訪客が切り替えると
全ノードにバッジで伝わり、**クイック返信の表示と読み上げも訪客の言語に追従**します。
無操作 60 秒 (設定可) で日本語に自動復帰します。→ [Usage-Visitors](Usage-Visitors)

## 対講 (三態) と応答接管

Asterisk 非経由の直接 SIP (UDP 47190) で、(1) 音声のみ、(2) 門口映像 + 双方向音声、
(3) 室内外双方向映像 (対称 MJPEG) の三態。電話に出た後でも室内機の「応答」で
電話腿を切って室内対講に**接管**できます。PBX が落ちても動きます。→ [Architecture](Architecture)

## 監聴 (モニタ)

室内機・Android TV から門口機へ `X-Doorbell-Mode: monitor` の一方向呼 — 門口の音声・映像を
気付かれずに確認できます。来鈴時の TV は全画面ライブ + 監聴が自動で立ち上がります。

## クイック返信

「ただいま留守にしています」等の定型文 (多言語・自定義・並び順付き) を室内機 / TV リモコン /
Telegram インラインボタン / HA / 網頁から送信 → 門口機に大字表示 + 読み上げ。
読み上げは カスタム音声 (訪客言語別に登録可) → 系統 TTS → 提示音 の順でフォールバックします。

## 自動応答 (auto_reply)

ルールのアクションとして、押鈴に人が出ずとも門口機が自動でクイック返信を表示 + 読み上げます。
定番は「宅配便なら『置き配をお願いします』を自動再生し、電話は鳴らさない」。→ [Usage-Admin](Usage-Admin)

## 電話連携 (Asterisk + ひかり電話)

押鈴で宅内内線と外出先携帯 (PSTN) を同時呼。通話中の DTMF 機能碼 (*1 = 開錠等、
アクションは設定可能) に対応。分配ロジックは dialplan 側で自由に変更できます。
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md)

## 通知

- **Telegram**: 押鈴を写真 + 用件 + 訪客言語バッジ付きで推送。インラインボタンで即返信。
- **Home Assistant** (MQTT Discovery): 呼び鈴 event / 動体 / 端末オンライン / ブリッジ生存 /
  緊急 / 訪客言語 sensor が自動出現。actionable 通知の断片も同梱。
- **室内チャイム**: カスタム音 (`asset:<sha256>`) 対応。
- 外部送信はリーダーノードのみが行い、重複通知を防ぎます。

## SOS (緊急求助)

室内機で長押し (既定 3 秒) → 全ノード警報 UI + サイレン + Telegram 🚨 + MQTT (HA 連動可)。
解除には kiosk PIN。警察・消防への自動発信は行いません。→ [Design-Philosophy](Design-Philosophy)

## 動体検知

門口機カメラの帧総線から動体を検出し、ルール (例: 夜間のみ Telegram + HA) に流します。
感度・最小間隔は端末別に調整できます。

## 映像 — MJPEG 基調 + H.264 流暢档

既定は全端末・全ブラウザで映る MJPEG。硬編を持つ端末は `codec: auto/h264` で
HW エンコード fMP4 (`/stream.mp4`) を配信 — 通話画質が滑らかになり、HA 側の転码も不要に
なります (go2rtc `#video=copy`)。購読者ゼロならエンコーダは止まる省電力設計。→ [Decisions](Decisions)

## HomeKit 連携

go2rtc + HA の HomeKit Bridge 経由で、iPhone の家庭 App に門鈴通知とライブ映像。
ホームハブ (Apple TV / HomePod) があれば外出先からも見られます。
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

## テーマ推送・文言編集・個性化

背景色 / 背景画像・文言 (i18n_overrides) ・用件・クイック返信・カスタム音声を
室内機や管理画面から変更すると、CRDT で全端末にミリ秒同期。夜間モード (減光 + 赤色化)、
スクリーンセーバ、焼付対策の pixel shift も設定できます。

## 資産配布 (assets)

背景画像・カスタム音声 (≤3MB) は sha256 台帳で管理され、**参照された時点で各端末が能動的に
前取り** (mesh FETCH_BLOB) — 再生・表示は常にローカルファイルでミリ秒応答です。
管理画面にノード毎のキャッシュ被覆率が出ます。

## kiosk 防盗

- Windows: シェル置換 + watchdog 前台守衛 (Update 弾窗を押し戻す) + 描画テンキー PIN
- Android: Device Owner 完全ピン留め + keyguard 無効
- iOS: 監督 + Single App Mode (解除は Configurator + 監督証明書のみ)
- 全平台: 離線 30 秒以内に Telegram/HA へ通知 (端末盗難・断線の検知)

## 網頁パネル (legacy 対応)

`door.html` (押鈴) / `monitor.html` (受鈴) は iPad 1 の iOS 5 Safari でも動きます。
`call.html` (双方向通話) は現代ブラウザ + Asterisk WebRTC ゲートウェイ (任意機能) が必要です。
