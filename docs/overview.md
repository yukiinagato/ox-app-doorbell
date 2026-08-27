# システム全体像 (機能・構成の総覧)

自宅 (複数棟・複数玄関、同一 LAN) 向けドアホン。旧型・低スペック端末を玄関子機/室内機に
再利用する。**サーバレス自愈** — P2P メッシュが真実源で、HA/Asterisk が落ちても
ドアホン本体・対講・通知は動き続ける。

## ノードの役割

| role | 端末例 | 主機能 |
|---|---|---|
| door_station (門口機) | Toughpad(Win) / Android / iOS を玄関に固定 | 呼出ボタン・前面カメラ・マイク/スピーカ・kiosk |
| indoor_panel (室内機) | 室内のタブレット/PC/スマホ | 来鈴表示・応答/クイック返信・監視・SOS |
| indoor_panel + tv:true | Android TV | 来鈴で全画面ライブ+直接監聴・D-pad 応答 |
| (Web) door.html/monitor.html/call.html | ブラウザ (iPad 1 含む) | 網頁版子機/受鈴/通話 |

全ノードが共有 C++ コア (doorbell-core) を積み、mesh で対等につながる。

## 主要機能マップ

- **呼出**: 門口ボタン (汎用 or 用件別ワンタップ) → ルールエンジン → SIP発呼 / チャイム /
  Telegram / HA / 自動応答。訪客は言語切替可、用件 (訪問/宅配/…) 選択可。
- **対講** (Asterisk 非経由の直接 SIP, ポート 47190): 音声のみ / 門口映像+双方向音声 /
  室内外双方向映像 (対称 MJPEG)。監聴 (一方向) と応答接管 (電話腿を奪って室内で応答) 対応。
  PBX 障害時も生きる。ブラウザ通話のみ Asterisk WebRTC ゲートウェイ経由 (任意)。
- **電話連携** (Asterisk + ひかり電話): 押鈴で内線+外出先携帯 (PSTN) を同時呼、
  DTMF 機能碼で開錠等。deploy/asterisk/ 参照。
- **通知**: Telegram (写真+インラインボタンでクイック返信) / HA (MQTT Discovery: 呼び鈴 event・
  動体・端末オフライン・ブリッジ生存・緊急) / 室内チャイム。leader ノードのみが外部送信 (重複防止)。
- **映像**: 既定 MJPEG (全端末・全ブラウザ)。h264 档 (Phase 6) で HW エンコード fMP4 →
  滑らかな通話画質・HA 転码不要。go2rtc→HomeKit で Apple 家庭アプリに門鈴通知+ライブ。
- **クイック返信/留守応答**: 定型文 (多言語・自定義) を室内/Telegram/HA/網頁から送信 →
  門口で大字表示+読み上げ (系統 TTS or カスタム音声)。訪客言語に追従。
- **緊急 SOS**: 室内長押し → 全ノード警報+サイレン+Telegram🚨+MQTT (HA 連動)。
  警察消防への自動発信はしない。
- **個性化 (推送)**: 背景色/画像・文言・用件・言語・音声を室内/管理画面から変更 → CRDT で
  ミリ秒同期。画像/音声は各門口機に能動プリフェッチ (assets 台帳) で即応答。
- **防盗/kiosk**: 退出は描画テンキー PIN、シェル置換自起動、watchdog 前台守衛
  (Windows Update 弾窗等を押し戻す)、離線報警、Android は Device Owner ロック。

## 端末別対応表

| 機能 | Windows(WPF) | Android | iOS | Web |
|---|---|---|---|---|
| 門口機フル | ✅ | ✅ | Phase 4 | door.html (音声なし) |
| 室内対講 | ✅ | ✅ | Phase 4 | call.html (現代ブラウザ) |
| TV 監視 | — | ✅(TV) | AppleTV=HomeKit / tvOS app=Phase4 | — |
| kiosk 硬化 | シェル置換+守衛+テンキー | Device Owner+守衛 | 監督 SAM | — |
| 錠前防止 | SetThreadExecutionState | keyguard 無効+STAY_ON | isIdleTimerDisabled | — |
| 旧機下限 | Win7 SP1 | 5.0 (4.4 legacy) | 12 (9 legacy) | iOS5 Safari |

## リポジトリ構成 & ビルド

- コア/テスト: `cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
- ホスト実機模擬: `./build/doorbell_host --help` (Mac/Linux で子機を起こす)
- 各平台アプリは GitHub Actions (`.github/workflows/build.yml`) で CI ビルド →
  Windows/Android 成果物を Artifacts からダウンロード可。
- 開発用スタック: `deploy/dev/{asterisk,mosquitto}/docker-compose.yml`

## 設定 = 単一の CRDT

全設定は LWW-Map CRDT (docs/config-schema.md が正準)。管理画面 (任意ノードの
`http://<ip>:47180/admin/`) or API で書けば全 fleet にミリ秒で伝播。真実源は分散 —
1 台生きていれば設定は復元できる。
