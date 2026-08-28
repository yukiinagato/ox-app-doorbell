# アーキテクチャ深掘り

> English: [Architecture-en](Architecture-en) / 中文: [Architecture-zh](Architecture-zh)

実装の中身に踏み込みます。正準の設定リファレンスは
[docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md)、
ポートは [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md) を参照してください。

## 全体構成

```
        +-------------------- 同一 L2 LAN ---------------------+
        |                                                      |
  [門口機 Win/Android/iOS]  [室内機]  [Android TV]  [ブラウザ] |
        |   \        mesh (UDP 47171 beacon / TCP 47172)   /   |
        |    +----------- P2P mesh = 真実源 ---------------+    |
        |         |                |                            |
        |    (leader のみ)    直接 SIP UDP 47190                |
        |     MQTT 1883       (対講・監聴)                      |
        |     Telegram 443                                      |
        +------|-----------------------------------------------+
               v
        [HA + Mosquitto + go2rtc]   [Asterisk] -- [ひかり電話 HGW] -- PSTN/携帯
```

全端末が共有 C++ コア (doorbell-core) を積み、平台殻 (WPF P/Invoke / JNI / Swift) は
[doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
の C ABI だけを見ます。UI イベントは JSON コールバック (`{"t":"chime",...}` 等) で殻へ流れます。

## mesh — 発見・gossip・選主

- **発見**: UDP 47171 のマルチキャスト beacon (HMAC 付き HELLO)。iOS 殻は Bonjour を併用。
  保険として `cluster.seed_peers` の静的リストも使えます。
- **輸送**: TCP 47172。PSK による AEAD で全通信を保護 (`secure_channel`)。
- **gossip/sync**: 設定 CRDT とイベントログをノード間で反同期。新規ノードは合流時に
  全量を吸い上げます。
- **選主 (leader)**: 決定的アルゴリズムで duty 毎にリーダーを選出。外部送信
  (MQTT / Telegram) はリーダーだけが行い、リーダーが消えれば自動で交代します。
  capability (常時給電か、ネット外向きに出られるか等) は実測 + `caps_override` で申告し、
  選主の資格に使われます。
- 実装: `core/src/mesh/`。

## 設定 = LWW-Map CRDT + HLC

設定はフラットな「ドットパス key → JSON 値」の Last-Writer-Wins Map です。
タイムスタンプは HLC (Hybrid Logical Clock) — 実時計が狂った端末があっても
因果順序が壊れません。どのノードで書いても勝敗が決定的に決まり、全ノードが
同じ結果に収束します。管理画面もアプリ内設定も、すべてこの CRDT への書込です。
秘密 (`*_ref: "secret:…"`) は参照だけを複製し、実体は各端末の secure store に置きます。
実装: `core/src/crdt/lww_map.cpp` (プロパティテスト付き)。

## イベント複製と冪等

イベント (press / motion / reply / offline / emergency / visitor_lang …) は
`(origin_node, origin_seq)` を ID として gossip で複製されます — 同じイベントを
何度受け取っても冪等です。press への応答状態 (誰が claim したか、Telegram の msg_id、
どの返信で答えたか) は notify として LWW マージされ、「応答済み」が全端末で一致します。
永続化は SQLite (`core/src/store/`)。

## 直連 SIP 対講 (X-Doorbell-Mode)

站間対講は **Asterisk を経由しません**。各子機の sipctl が UDP 47190 を固定 listen し、
室内機/TV は `sip:<host>:47190` へ直接 INVITE します。

- ヘッダ `X-Doorbell-Mode: answer` = 双方向対講 / `monitor` = 一方向監聴
  (受け側は自マイク音声のみ送出)。
- 受け付けるのは mesh 成員の IP のみ。SIP サーバや accounts が未設定でも直接呼は動きます。
- Asterisk (UDP 5060) は「電話腿」専用: 内線 REGISTER・押鈴時の 600 番発呼・
  ひかり電話 HGW 経由の PSTN 出局・DTMF 機能碼。PBX が死んでも対講と監聴は無傷です。
- 応答接管: 室内機の「応答」は電話腿を切ってから直連対講を張ります。
- 実装: `core/src/sipctl/` (PJSIP)。

## 媒体管線 — 帧総線から各消費者へ

カメラ採集は殻 (または Windows は core 内) が行い、`db_core_on_camera_frame` で
コアの **帧総線 (FrameBus)** に入ります。消費者は現在 4 系統:

```
 camera → FrameBus ─┬─ MJPEG エンコード → /stream.mjpeg (誰でも映る基調)
                    ├─ /snapshot.jpg (Telegram 写真・HA generic camera)
                    ├─ MotionDetector (動体イベント)
                    └─ (h264 档) 殻の HW エンコーダ → db_core_on_encoded_frame
                                → fMP4 マキサ → /stream.mp4
```

- H.264 のエンコードは平台の HW (MediaCodec / VideoToolbox / Media Foundation)。
  コアは AnnexB を受け取って fMP4 に箱詰めして配るだけです (自前マキサ、外部依存なし)。
- `/stream.mp4` は購読者が付いた時だけエンコーダを回します (`db_core_video_encoder_wanted`)。
  go2rtc は `#video=copy` で受けられるため HA 側の転码が不要になります。
- 網頁通話のブラウザ→門口機映像は WebRTC ではなく「getUserMedia → canvas → JPEG を
  `/call-frame` へ POST」という枯れた方式です ([Decisions](Decisions))。

## 資産配布

背景画像・カスタム音声は sha256 で台帳 (`assets.<hash>`) に登録され、実体 blob は
アップロード先ノードに置かれます。**設定から参照された時点**で各ノードが mesh の
FETCH_BLOB で能動前取りし (保持ノードならどこからでも取得可)、以後の再生・表示は
常にローカルファイル = ミリ秒応答。台帳を tombstone にすると各ノードが猶予付き GC で
回収します。取得系 API は 64 桁 hex 固定検証でパス走査を防ぎます。

## httpd — 1 ポートに全部

各ノードの TCP 47180 (CivetWeb) が 管理 SPA (`/admin/`) / 網頁パネル (`/panel/…`) /
MJPEG / fMP4 / snapshot / 管理 API / panel API を提供します。認証は
管理 = パスワードセッション、panel/stream = `?k=<token>`。webui はビルド時に
バイナリへ埋め込まれます (`embed_webui.py`) — 静的ファイル配布サーバさえ不要です。

## なぜリーダーだけが外部送信するのか

全ノードが Telegram/MQTT へ送ると、同じ来客通知が台数分届きます。かといって
「送信担当を固定」すると、その 1 台が単一障害点です。答えが「決定的選主 + 自動継任」:
平時は 1 台だけが代表して送り (重複ゼロ)、その 1 台が消えれば数秒で別ノードが
継ぎます (漏れゼロ)。イベント複製が冪等なので、交代の瞬間に二重送信が起きても
notify の LWW マージで「応答済み」状態は壊れません。「宁重勿漏」の実装形です。

関連: 設計判断の経緯は [Decisions](Decisions)、機能目線は [Features](Features)。
