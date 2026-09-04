# 機能総覧

> 日本語 (this page) / English: [Features](Features) / 中文: [Features-zh](Features-zh)

以下は機能概念の説明です。実装・build・実機認証・未対応の区別は [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md) が優先します。

各機能の「何ができるか」を短くまとめます。使い方は [Usage-Residents](Usage-Residents-ja) /
[Usage-Admin](Usage-Admin-ja) / [Usage-Visitors](Usage-Visitors-ja)、仕組みは [Architecture](Architecture-ja) へ。

## 呼出

門口機の大ボタン (汎用) または用件ボタン 1 タップで押鈴。イベントはルールエンジンに入り、
設定した action が実行されます。
ドア別・用件別・時間帯別に分岐できます。→ [Usage-Admin](Usage-Admin-ja)

`purpose_first` は用件を選んでから ring、`ring_then_purpose` は先に ring して後から用件を選択または
skip します。visitor cancel は ringing 中だけで、通話確立後は End call/hangup を使います。
Web 手動応答は一つの `dialog_id` owner に限定され、recovery は ringing を origin で、in-call を
その owner だけで復元します。

## 用件ボタン (visit_purposes)

訪問 / 宅配便 / 郵便 / 営業・集金 / 検針・工事 / その他 — 既定 6 種、自由に編集可能。
宅配員は「宅配便」1 タップで押鈴まで完了します。用件は室内機・TV・Telegram・HA・管理画面の
すべてに表示され、ルールの分岐条件 (`when.purposes`) にも使えます。→ [Usage-Visitors](Usage-Visitors-ja)

管理者は `visit_purposes.<id>.enabled` を off にしても、ラベル、icon、並び順、履歴、rule を削除せずに
用件を一時停止できます。off の用件は新しい訪客に提示されず、呼出にも付けられません。更新未受信の
門口機が古いボタンを送っても、Core は訪客の押鈴を拒否せず、用件なしの汎用呼出にします。

## 訪客言語切替

門口機に言語ボタン (日/英/中 — `ui.languages` で選択) を表示。訪客が切り替えると
全ノードにバッジで伝わり、**クイック返信の表示と読み上げも訪客の言語に追従**します。
無操作 60 秒 (設定可) で日本語に自動復帰します。→ [Usage-Visitors](Usage-Visitors-ja)

## 対講 (三態) と応答接管

Asterisk 非経由の直接 SIP (UDP 47190) で、(1) 音声のみ、(2) 門口映像 + 双方向音声、
(3) 室内外双方向映像 (対称 MJPEG) の三態。電話に出た後でも室内機の「応答」で
電話腿を切って室内対講に**接管**できます。PBX が落ちても動きます。→ [Architecture](Architecture-ja)

実装済みの応答 shell では Core 経由で microphone mute も操作できます。設定は通話をまたいで保持され、
media が有効になった時に再適用されます。SIP backend のない development/display build でも状態は記録
されますが、それで通話が利用可能になるわけではありません。

## 監聴 (モニタ)

室内機・Android TV から門口機へ `X-Doorbell-Mode: monitor` の一方向呼 — 門口の音声・映像を
気付かれずに確認できます。来鈴時の TV は全画面ライブ + 監聴が自動で立ち上がります。

## クイック返信

「ただいま留守にしています」等の定型文 (多言語・自定義・並び順付き) を室内機 / TV リモコン /
Telegram インラインボタン / HA / 網頁から送信 → 門口機に大字表示 + 読み上げ。
読み上げは カスタム音声 (訪客言語別に登録可) → 系統 TTS → 提示音 の順でフォールバックします。

## 自動応答 (auto_reply)

ルールのアクションとして、押鈴に人が出ずとも門口機が自動でクイック返信を表示 + 読み上げます。
定番は「宅配便なら『置き配をお願いします』を自動再生し、電話は鳴らさない」。→ [Usage-Admin](Usage-Admin-ja)

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

SOS active/clear 状態は全 Core node へ複製されますが、visual、sound、system notification、Web Push、
Telegram、MQTT の送信先は rule-driven で、受信者ゼロも設定可能です。管理開關
`emergency.web_active_page_alerts` の既定値は true なので、受信者ゼロまたは Push-only rule でも
開いている Web page は SOS を表示します。false でも正の matching `device_alert` または配信済み Push は
表示できます。Core `delivery_result` は dispatch attempt、client channel report は実 presentation を示します。
raw-state 表示中、rule TTL は custom decoration/sound だけを終了し、安全な赤い overlay は clear まで
残ります。Web page は `?group=` の保存値を poll/Push で共用します。explicit native-only target は Web、
Web-only target は native shell に届かず、legacy no-target action だけが全対象です。complete Push
subscription は CRDT 内で XChaCha20-Poly1305 seal され、plaintext config/export には出ません。
解除には kiosk PIN。警察・消防への自動発信は行いません。→ [Design-Philosophy](Design-Philosophy-ja)

## 動体検知

門口機カメラの帧総線から動体を検出し、ルール (例: 夜間のみ Telegram + HA) に流します。
感度・最小間隔は端末別に調整できます。

## 映像 — MJPEG 基調 + H.264 流暢档

既定は全端末・全ブラウザで映る MJPEG。硬編を持つ端末は `codec: auto/h264` で
HW エンコード fMP4 (`/stream.mp4`) を配信 — 通話画質が滑らかになり、HA 側の転码も不要に
なります (go2rtc `#video=copy`)。購読者ゼロならエンコーダは止まる省電力設計。→ [Decisions](Decisions-ja)

live fMP4 track は access unit ごとに直ちに fragment を出し、遅い subscriber には最新 fragment だけを
残すため、遅延を貯めずに追い付きます。encoder は subscriber が付いてから起動し、pre-warm はしません。
iOS 5 compatibility player は H.264 が実際に連続表示できるまで MJPEG を前面に残します。その後、端末の
displayed frame から範囲を限定した live-edge を学習し、新しい frame が待っている時だけ古い frame を
skip、表示 stall 時には MJPEG に戻します。これは host test と限定的な iPad 1 smoke evidence を持つ path
であり、一般的な hardware certification の主張ではありません。

## HomeKit 連携

go2rtc + HA の HomeKit Bridge 経由で、iPhone の家庭 App に門鈴通知とライブ映像。
ホームハブ (Apple TV / HomePod) があれば外出先からも見られます。
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

## テーマ推送・文言編集・個性化

背景色 / 背景画像・文言 (i18n_overrides) ・用件・クイック返信・カスタム音声を
室内機や管理画面から変更すると、CRDT で全端末にミリ秒同期。夜間モード (減光 + 赤色化)、
スクリーンセーバ、焼付対策の pixel shift も設定できます。

Core は cluster time zone で `auto_system`、`auto_schedule`、light、dark の外観を解決し、semantic region
ごとに自動の text/accent 色を配信します。背景画像で文字の背後の pixel が端末ごとに異なる場合は shell が
local に sample できますが、明示的な region override が優先です。低 contrast は保存を拒否せず、測定済み
WCAG warning として返ります。

端末別 semantic size/color override は renderer manifest の制限内で適用します。native client は
top-level `ui_manifest`、配信中 Core は別の local `web_ui.manifest` を公開します。last-valid native peer
contract は永続 cache され、`cached_contract:true` の configured offline device を検証/queue できますが、
後の apply report が必要です。remote/offline Web manifest が不明な場合、Admin は native peer manifest
から Web editor を捏造しません。

## 資産配布 (assets)

背景画像・カスタム音声 (≤3MB) は sha256 台帳で管理され、**参照された時点で各端末が能動的に
前取り** (mesh FETCH_BLOB) — 再生・表示は常にローカルファイルでミリ秒応答です。
管理画面にノード毎のキャッシュ被覆率が出ます。

## kiosk 防盗

- Windows: シェル置換 + watchdog 前台守衛 (Update 弾窗を押し戻す) + 描画テンキー PIN
- Android: Device Owner 完全ピン留め + keyguard 無効
- iOS: 監督 + Single App Mode (解除は Configurator + 監督証明書のみ)
- offline event は matching rule と commissioning 済み integration が選んだ場合だけ Telegram/HA を
  実行でき、全 platform 共通の 30 秒または delivery 保証はありません。

## 網頁パネル (legacy 対応)

legacy web panel は対象 Safari/端末での実機試験まで best-effort です。`call.html` には modern secure
context と Asterisk WebRTC が必要です。iPad 1 compatibility shell は内蔵 mic/speaker を使えますが
camera はありません。端末別 commissioning と外部 camera/no-video profile が必要です。bounded
RTSP/RTP-over-TCP H.264 ingest と Annex-B 転送は host/loopback test 済みですが、実 IDR accept までは
degraded で、実 camera iPad qualification は未完了です。別の bounded Android→Core fMP4→iPad 実機
smoke は foreground renderer で 15～16 fps を確認済みですが、crash 後の unattended foreground resume
は未完了です。optional root helper は実装・host test 済みで、
iOS 5 lane には launchd を無効のままにする再現可能な staged DEB がありますが、実機 qualification は
未完了です。

## 現在の artifact gate

- Android API 19 の正式 SKU allowlist は空で、supported SKU は 0。CI artifact は debug-contract で
  distributable release ではありません。
- tvOS は real PJSIP を link した unsigned Debug simulator build のみ。tracked Release/device artifact と
  Apple TV 実機検証はありません。
- iOS 9 arm64 は unsigned device-link proof まで。正式 armv7 signing/hardware gate は未 commission です。
- cross-platform conformance は golden behavior model + source-smoke contract で、全 runtime artifact の
  trace 実行証明ではありません。
- iPad 1 は mic/speaker を持つ一方 camera はなく、outdoor-rated ではありません。hardware、enclosure、
  audio、rollback gate は未完了です。
- local で未 push の `ios-legacy-0.2.0-final` tag はありますが、この working tree の `ios-compat` は
  untracked で fresh-clone/device/rollback gate が未完了です。`ios-legacy` を変更せず保持します。
