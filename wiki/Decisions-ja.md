# 意思決定録 (ADR 風)

> 日本語 (this page) / English: [Decisions](Decisions) / 中文: [Decisions-zh](Decisions-zh)

主要な設計判断を「背景 → 選択肢 → 決定 → 理由」の形で記録します。
理念レベルの話は [Design-Philosophy](Design-Philosophy-ja)、実装は [Architecture](Architecture-ja) へ。

## D1: 映像は MJPEG 基調 + H.264 档の二層

- **背景**: 端末は Win7 Toughpad から最新 iPhone まで。単一コーデックでは両立しません。
- **選択肢**: (a) 全部 MJPEG、(b) 全部 H.264、(c) 二層。
- **決定**: (c)。MJPEG (`/stream.mjpeg`) を compatibility baseline とし、実測 hardware path が healthy
  な device だけ HW-encoded fMP4 (`/stream.mp4`) を publish します。client が path を claim するのは
  exact renderer/source の commissioning 後だけです。iOS 5 shell は HTTP(S) MJPEG/snapshot を direct
  playback し、JPEG は local のまま Core に forward しません。
- **理由**: MJPEG は旧 CPU でも実用的ですが、compatibility は universal promise でなく client ごとの
  implementation/test 結果です。qualified H.264 は go2rtc `#video=copy` で HA transcoding を避けられます。
  codec health 失敗時 `auto` は MJPEG に fallback します。Android API 19 の正式 supported SKU は現在 0 です。

## D2: 站間対講は直接 SIP (PBX 非依存)

- **背景**: 当初は対講も Asterisk 経由の設計でした。しかし PBX が単一障害点になります。
- **選択肢**: (a) Asterisk 経由に統一、(b) 独自プロトコル、(c) 標準 SIP の直接呼。
- **決定**: (c)。各子機が UDP 47190 を固定 listen し、`X-Doorbell-Mode` ヘッダで
  answer/monitor を区別。相手 IP は mesh の成員名簿から解決 (成員限定)。
- **理由**: PBX 障害時も対講・監聴が生きる (自愈方針)。SIP のままなので PJSIP の
  実装を電話腿と共用でき、独自プロトコルの発明を避けられる。dialplan 変更も不要。
  Asterisk の役割は「電話網への腿」1 本に純化されました。

## D3: 在外ビデオ通話に Telegram 通話・FaceTime を採らない

- **背景**: 外出先から門口と「ビデオ通話」したい (計画書 §17 で調査)。
- **選択肢**: (a) Telegram video call、(b) FaceTime、(c) HomeKit 遠隔視聴 + PSTN 音声、
  (d) VPN + 自家スタック、(e) Telegram video note (短動画)。
- **決定**: (c) を標準、(d) を上級者向け、(e) を補助に。**(a)(b) は不採用**。
- **理由**: Telegram の通話 API は bot に開放されておらず、自動応答する門口機を
  作れません。FaceTime は Apple 端末限定のうえ自動化 API が皆無で、kiosk 端末での
  無人応答が成立しません。HomeKit (映像) + ひかり電話 (音声) の組み合わせは
  既存の枯れた経路だけで「見て話す」を満たします。VPN を張れば自家 UI の全機能が
  そのまま使えます。

## D4: HomeKit に対講 (双方向音声) を載せない

- **背景**: 家庭 App で通知・ライブ視聴はできるのに、応答ボタンで話せない。
- **選択肢**: (a) HomeKit Doorbell として双方向音声まで実装、(b) 視聴のみ。
- **決定**: (b)。HomeKit は「通知 + ライブ映像」に限定し、音声応答は電話 (PSTN) か
  自家アプリで行う。
- **理由**: HA の HomeKit Bridge 経由では双方向音声ストリームの取り回しに制約があり、
  安定した対講品質を保証できません。不安定な対講を 1 つ増やすより、確実に繋がる
  電話腿に音声を任せるほうが「宁重勿漏」に適います。

## D5: 依存を増やさない — 自前 fMP4・自前 MQTT クライアント

- **背景**: fMP4 マキサも MQTT クライアントも既製ライブラリがあります。
- **選択肢**: (a) ffmpeg/libmosquitto 等をリンク、(b) 必要最小限を自前実装。
- **決定**: (b)。fMP4 は「H.264 AnnexB を箱詰めする」だけの自前マキサ、MQTT は
  3.1.1 QoS0 のみの自前クライアント (`core/src/bridge/mqtt_client.cpp`)。
- **理由**: 対象は Win7 x86 から iOS まで — 依存が増えるほど旧平台のビルドと配布が
  壊れやすくなります。使う機能は仕様のごく薄い断面だけで、自前のほうが
  テスト・移植・長期保守が軽い。TLS だけは平台の枠組み (SPI `https_request`) に
  委譲し、暗号の自前実装は避けています。

## D6: iOS 配布は Ad Hoc → App Store (段階)

- **背景**: 家庭内の少台数に配るだけなのに、iOS は署名の壁があります。
- **選択肢**: (a) 無料チーム 7 日署名、(b) Ad Hoc、(c) App Store (unlisted)、(d) ABM カスタム App。
- **決定**: まず (b) Ad Hoc (UDID 登録 + 年 1 回の再署名)。恒久化は (c) を Phase 7 で計画。
- **理由**: (a) は毎週再署名で常設運用に不適。(b) は年 1 回の儀式で済み、アプリ内の
  期限表示と Telegram の 30 日前警告で失念を防いでいます。台数や運用が固まった段階で
  App Store (unlisted) に上架し、再署名自体を無くすのが終着点です。

## D7: 網頁通話だけ Asterisk WebRTC ゲートウェイ (任意機能)

- **背景**: ブラウザは SIP/UDP を直接話せません。
- **決定**: ネイティブ端末の対講は D2 の直連で完結させ、**ブラウザ通話を使いたい場合のみ**
  Asterisk を WebRTC (JsSIP + WebSocket) のゲートウェイにする。使わなければ設定不要。
  ブラウザ→門口機の映像も WebRTC 協商ではなく canvas→JPEG POST の枯れた方式。
- **理由**: WebRTC の複雑さ (ICE/DTLS/SFU) をコア必須経路に持ち込まない。
  詳細: [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)。

## D8: 文言は単一 YAML → 各平台形式へ生成

- **背景**: resx (WPF) / strings.xml (Android) / Swift と、平台毎に文言形式が違います。
- **決定**: [i18n/strings.yaml](https://github.com/yukiinagato/ox-app-doorbell/blob/main/i18n/strings.yaml)
  (ja 原文 + en/zh) を単一ソースにし、`tools/gen_i18n.py` が各形式を生成。実行時の
  上書き (i18n_overrides) は同じキー体系で CRDT に載せる。
- **理由**: 三言語 × 多平台の文言を手で同期するのは必ず破綻します。生成物は編集禁止
  ヘッダ付きで追跡し、キーの重複・欠落は CI で露見します (開発史にその修復コミットが
  残っています — [FAQ](FAQ-ja) ではなく git log を参照)。
