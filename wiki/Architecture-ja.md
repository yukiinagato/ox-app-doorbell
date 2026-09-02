# アーキテクチャ深掘り

> 日本語 (this page) / English: [Architecture](Architecture) / 中文: [Architecture-zh](Architecture-zh)

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

native client は [doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
の versioned `db_platform_v2` C ABI を通して共有 C++ core と統合します。
UI イベントは JSON callback (`{"t":"chime",...}` 等) で shell へ流れます。

## mesh — 発見・gossip・選主

- **発見**: UDP 47171 の multicast beacon (HMAC 付き HELLO)。multicast 不可時は端末ローカル
  `boot.json` の `seed_peers` を使います。
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

schema-v2 call lifecycle は `(door, call_id, stage_revision)` 単位です。訪客が cancel できるのは
ringing 中だけで、`answered` / `in_call` 後は hangup が `call_ended` を発行します。Web の手動応答は
乱数 `dialog_id` を一つ claim して opaque な `dialog_owner` を受け取り、競合に負けた SIP dialog は
終了します。restart 時、ringing call は press-origin node が復元し、in-call session は勝った
dialog owner だけが復元できます。10 秒以内に証明できなければ Core は冪等な全域 cancel を一度だけ
発行します。

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
  `/call-frame` へ POST」という枯れた方式です ([Decisions](Decisions-ja))。

## 資産配布

背景画像・カスタム音声は sha256 で台帳 (`assets.<hash>`) に登録され、実体 blob は
アップロード先ノードに置かれます。**設定から参照された時点**で各ノードが mesh の
FETCH_BLOB で能動前取りし (保持ノードならどこからでも取得可)、以後の再生・表示は
常にローカルファイル = ミリ秒応答。台帳を tombstone にすると各ノードが猶予付き GC で
回収します。取得系 API は 64 桁 hex 固定検証でパス走査を防ぎます。

## httpd — 1 ポートに全部

各ノードの TCP 47180 (CivetWeb) が 管理 SPA (`/admin/`) / 網頁パネル (`/panel/…`) /
MJPEG / fMP4 / snapshot / 管理 API / panel API を提供します。認証は
管理はパスワード session です。panel credential は URL fragment (`#k=`、HTTP では送信されない) に
一度だけ渡し、`POST /api/panel/session` で交換後は HttpOnly cookie を使います。query/form credential は
拒否し、cross-node upload だけ bearer header を使えます。webui はビルド時にバイナリへ埋め込まれます
(`embed_webui.py`)。

## SOS 配信と semantic UI contract

SOS active/clear 状態は全 Core node に複製されます。表示と外部配信は rule-driven で、受信者ゼロも
有効な設定です。管理開關 `emergency.web_active_page_alerts` の既定値は true で、受信者ゼロまたは
Push-only rule でも開いている Web page が複製済み SOS を表示できます。false でも正の matching
`device_alert` または配信済み Push は表示できます。Core の `delivery_result` は dispatch attempt、
client runtime の channel 別 report は visual、sound、system notification、Web presentation の
applied/suppressed/unsupported/failed を表します。raw path が有効な間、rule TTL は custom
decoration/sound を終了しても安全な赤い raw-SOS overlay を clear または switch-off まで残します。

`targets` がない legacy alert は全 native node/Web group を対象にします。明示 `targets` は対称で、
Web-only group は native shell、native-only selector は active Web page/Push subscription を対象に
しません。panel `?group=<name>` は検証・保存し、state 投影と Push enrollment に共用します。Core は
complete Push `endpoint`/`p256dh`/`auth` を mesh-PSK-derived key と XChaCha20-Poly1305 で 1 つの
schema-v2 CRDT record に seal します。config/export に plaintext はなく、旧 raw record は起動時に
再 seal または fail-closed で削除します。

native client は top-level `ui_manifest` を公開し、配信中 Core node は別の built-in Web renderer
contract を `web_ui.manifest` として公開します。Web manifest は local であり remote Web surface の
複製 catalog ではありません。Admin は native peer manifest から remote/offline Web editor を推測したり、
未知 manifest を捏造したりできません。Core は peer の last-valid native manifest/capability を永続 cache
するため、`cached_contract:true` の configured offline device をその cache に対して検証/queue できますが、
適用証明には後の renderer report が必要です。

## なぜリーダーだけが外部送信するのか

全 node が Telegram/MQTT へ送ると、同じ来客通知が端末台数分届く可能性があります。一方、送信担当を
固定すると 1 台が単一障害点です。Core は deterministic duty election を使い、mesh convergence 後に
再 election します。通常は 1 leader に dispatch を限定し、複製 event identity と LWW claim が handover
時の重複 state change を bounded にします。ただし zero-miss または delivery-time の保証ではなく、partition、
convergence delay、external provider の結果は delivery diagnostics に表示します。

関連: 設計判断の経緯は [Decisions](Decisions-ja)、機能目線は [Features](Features-ja)。
