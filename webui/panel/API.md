# パネル API 契約 (Web legacy 前端 ⇄ Node)

`webui/panel/door.html` (網頁版門口子機) と `webui/panel/monitor.html` (受鈴表示面板) が
使う HTTP API の契約書。**実装は Node 側 (`core/src/node/node.cpp` の `registerHttp`) が
後で行う** — 既存 `/api/*` の流儀 (route 登録・`json::` ヘルパ・`HttpResp::json`) に合わせる。

対象クライアントは iOS 5 Safari (iPad 1) を含む legacy ブラウザ:

- ES5 のみ。XHR 短輪詢 (2 秒)。WebSocket / SSE / fetch は使わない。
- Cookie セッション (`dbsess`) ではなく **panel token** (`?k=`) で認証する
  (組込パネルはログイン UI を持たないため。URL に固定 token を含めてブックマーク運用)。

## 認証: panel token

- すべてのパネル API はクエリ (POST は form body) の `k=<token>` で認証する。
- token は管理画面で発行し、config `panel.tokens` (文字列配列) に保持する。
  例: `"panel": { "tokens": ["3f9c…", "a01b…"] }`
- token 不一致・欠落は `403` + `{"ok":false,"err":"bad token"}`。
- 静的ページ `/panel/door` `/panel/monitor` 自体は既存どおり認証免除 prefix
  (`/panel/`) で配信される。守るのは API と snapshot 転発のみ。

## GET /api/panel/state?k=\<token\>

パネルが 2 秒間隔で輪詢する唯一の状態取得口。応答:

```json
{
  "doors": [
    { "id": "d_front", "label": "正面玄関", "calling": false },
    { "id": "d_back",  "label": "裏口",     "calling": true }
  ],
  "events": [
    { "type": "press", "door": "d_front", "device": "", "wall_ms": 1756300000000 }
  ],
  "reply": { "text": "すぐ行きます", "ts": 1756300012345 },
  "server_ts": 1756300020000
}
```

- `doors[]` — 全ドア (config `doors.*`)。`label` は表示言語解決済みの文字列。
  `calling` は「呼出が発生し、まだ応答/タイムアウトしていない」間 true。
- `events[]` — 直近 10 件 (既存 `/api/events` と同スキーマの縮小版。`payload` は不要)。
- `reply` — 最新クイック返信 (`text` + `ts` ms)。無ければ `null`。
  クライアントは `ts` の単調増加のみ比較する (初回受信分は既読扱い)。
- `server_ts` — サーバ壁時計 (ms)。クライアント側キャッシュバスター等の参考用。

## POST /api/panel/press

- Content-Type: `application/x-www-form-urlencoded` (legacy Safari 互換のため JSON でなく form)
- Body: `door=<id>&k=<token>`
- 応答: `{"ok":true}` / `403` (token 不正) / `{"ok":false,"err":"…"}` (door 不明など)
- 効果は既存 `/api/press` (`doPress`) と同じ: 呼出イベント発火・通知経路へ。

## POST /api/panel/emergency

SOS 緊急モードの**発報のみ** (解除は不可)。

- Content-Type: `application/x-www-form-urlencoded`、Body: `k=<token>`
- 応答: `{"ok":true}` / `403` (token 不正)
- `active=0` (または `active=false`) を付けた解除要求は `403` +
  `{"ok":false,"err":"cancel not allowed"}` — 解除は kiosk PIN 経由の端末操作
  (`db_core_emergency(0)`) か管理セッションの `POST /api/emergency` のみ。
- 効果: `emergency` イベントが全ノードへ複製され、各端末が警報 UI + サイレン、
  Telegram 🚨 (全 households)、MQTT `doorbell/emergency` (retain) が発火する。
  quiet_hours の影響は受けない (組込動作)。

## GET /snapshot-proxy?door=\<id\>&k=\<token\>

その door の担当子機 (door_station) の**最新 JPEG 1 枚**を返す。

- 応答: `200` + `image/jpeg` (Cache-Control: no-store)。
- 呼び先の子機が**他ノード**の場合の転発手段は実装側に委ねる:
  mesh 経由で取り寄せて串流転発するか、子機の `http://<host>:47180/snapshot.jpg` へ
  `302` リダイレクトするかのどちらでもよい (302 の場合、リダイレクト先は
  既存の認証免除 URI なので token 不要)。
- クライアントは `&t=<ts>` を付けてキャッシュ破りする (単純 `<img>` 差替 —
  door.html は使わず monitor.html が平時 5 秒毎/呼出中 2 秒毎)。
- 担当子機オフライン等で画が無い場合は `503` (img は壊れ表示になるが、
  次回差替で自然回復するのでクライアント側の特別処理は不要)。

### 任意拡張: `&live=1` (MJPEG 昇格)

- `live=1` 付きの要求には `multipart/x-mixed-replace` の MJPEG 串流を返して**よい**
  (未対応なら無視して JPEG 1 枚でよい — クライアントは差替を止めているだけなので
  静止画のままになるが壊れない)。
- monitor.html は **UA 判定をしない**。`<body data-live="1">` を手動で付けた場合のみ
  この URL を使い、`<img>` の src を据え置く (それ以外は snapshot 輪詢)。

## GET /api/panel/call-info?k=\<token\>  (網頁通話 — call.html 用)

網頁通話ページの設定/宛先解決 (現代ブラウザ専用 — legacy 面板は使わない)。応答:

```json
{
  "ok": true,
  "webrtc": { "ws_url": "ws://10.0.1.5:8088/ws", "sip_user": "260",
              "sip_pass": "…", "server": "10.0.1.5" },
  "doors": {
    "d_front": { "extension": "8001", "station": "http://10.0.1.7:47180", "online": true }
  }
}
```

- `webrtc` — config `integrations.webrtc` の写し + `sip.server`。`ws_url` 空 =
  Asterisk 未設定 → クライアントは通話ボタンを無効化し理由を表示する。
- `doors.<id>.extension` — その door 担当門口機の内線 (`sip.accounts.<node_id>.user`)。
  空 = 通話不可 (映像のみ)。
- `doors.<id>.station` — 担当門口機の origin (`http://<host>:47180`)。**空文字 = このノード
  自身が担当** (相対 URL でよい)。`/stream.mjpeg` の表示と `/call-frame` の POST 先に使う。
- 担当門口機が devices に無い door は `doors` に載らない。

## POST /call-frame?door=\<id\>&k=\<token\>  (ブラウザ → 門口機の相手映像)

網頁通話中のブラウザが自分のカメラ画 (getUserMedia → canvas) を門口機へ流し込む口。
**担当門口機のノードへ直接 POST する** (`call-info` の `station` origin。CORS 対応 —
preflight OPTIONS も同パスで応える)。

- Body: JPEG 1 枚そのまま (Content-Type: image/jpeg)。SOI マーカ検査あり (`400 not jpeg`)。
- 受理条件: panel token 一致 (`403`)、宛先がこのノード担当の door (`404 not this station`)、
  **SIP 通話中のみ** (`409 not in call` — 通話外の流し込みは捨てる)。
- 推奨レート 2fps (500ms)。フレームは「peer frame スロット」(FrameBus とは別) に置かれ、
  最新 1 枚だけ保持される。

## GET /peer-frame.jpg  (門口機殻の相手映像輪詢)

門口機の殻が通話中画面の「相手映像」に使う。`peer_stream` (UI イベント参照) が解決できた
通話では不要 — 解決できない相手 (網頁通話・電話) のときに自機のこの URL を輪詢する。

- 認証免除 (LAN 公開 — `/snapshot.jpg` と同格)。Cache-Control: no-store。
- `/call-frame` で最後に受けたフレームを返す。**3 秒より古いと `404`** (相手が送信を
  止めた/通話終了 — 殻は「映像なし」表示へ戻る)。

### UI イベント (殻向け — 対称双方向映像の契約)

SIP 通話確立時の `{"t":"state","state":"in_call"}` に相手解決結果が載る:

```json
{ "t":"state", "state":"in_call", "remote":"\"indoor\" <sip:201@10.0.1.5>",
  "peer_node":"<node_id>", "peer_stream":"http://10.0.1.8:47180/stream.mjpeg" }
```

- 解決経路: 直接呼 = remote host → mesh peers[].addrs 照合 / Asterisk 経由 =
  remote user (内線) → `sip.accounts.*` の user 逆引き。
- `peer_stream` 無し = 相手特定不能 (PSTN/Groundwire/網頁内線) → 門口機殻は
  `/peer-frame.jpg` 輪詢に降級、室内機殻は映像なし。

## 個性化 (訪客言語・用件・統一資産) の追加契約

### GET /api/panel/state の追加欄

- `doors[].visitor_lang` — その door で訪客が選択中の言語 ("en" 等)。主言語 (ja) の間は
  キー自体が無い。門口ページは言語バーの現在値に、monitor は言語バッジに使う。
- `events[]` の press 行に `purpose` (visit_purposes のキー) と `visitor_lang` (該当時のみ)。
- `purposes[]` — 訪客の用件ボタン (order 昇順)。例:
  `{ "id": "p_delivery", "icon": "📦", "order": 2,
     "label": { "ja": "宅配便", "en": "Delivery", "zh": "快递" } }`
  門口ページは大ボタン「呼出」の下にこの一覧を描画し、タップ = その用件付きの按鈴
  (press に `purpose=<id>` を添える)。ラベルは全言語同梱 — 言語切替時の再取得は不要。
- `languages[]` — 訪客言語切替に出す言語 (config `ui.languages`、既定 `["ja","en","zh"]`)。

### POST /api/panel/press の追加パラメータ

- `purpose=<visit_purposes のキー>` (任意 — 省略は用件なしの汎用按鈴)。未知の purpose は
  `400` + `{"ok":false,"err":"unknown purpose"}`。

### POST /api/panel/visitor-lang

- Body (form): `lang=<ja|en|zh>&k=<token>[&door=<id>]`。door 省略 = そのノードの担当 door。
- `lang=ja` は即時復帰。無操作 `ui.visitor_lang_revert_s` 秒 (既定 60) で自動的に ja へ
  戻る (按鈴で計時やり直し)。切替は `visitor_lang` イベントとして全ノードへ複製される。

### GET /api/panel/i18n?k=\<token\>

パネルページの文言解決 (実行時上書きと言語一覧)。読込時に 1 回取得する (輪詢しない)。

```json
{ "ok": true, "languages": ["ja", "en", "zh"],
  "overrides": { "ja": { "idle.touch_to_call": "タッチして呼び出してください" } } }
```

- `overrides` = config `i18n_overrides` の全文 (無ければ `{}`)。ルックアップ順は
  上書き → ページ内蔵文言 → キー自身 (core の Node::text と同順)。

### GET /asset/\<sha256\>?k=\<token\>

統一資産 (背景画像/カスタム音声) の実体。panel token または管理セッション。
内容アドレスなので不変 — `Cache-Control: immutable` 付き (詳細は docs/config-schema.md の
「統一資産 API」)。原生殻は原則 core がキャッシュしたローカルパス (UI イベントの
`audio_path` / `theme.bg_image_path`) を直接使い、この URL は web パネル/管理画面用。

### UI イベント追加 (殻向け — 個性化の契約)

- `{"t":"display",…,"theme":{"bg_color":"#101418","bg_image":"<sha256>|null",
  "bg_image_path":"<ローカル絶対パス>|null"}}` — 待機画面テーマ (`display.theme` を
  `devices.<id>.local.theme` がキー単位で上書きした実効値)。`bg_image_path` null =
  未キャッシュ — キャッシュ完了 (`asset_ready`) 後に display が再発行される。
- `{"t":"emergency","active":true,"alarm_sound":"siren1|asset:<sha256>",
  "alarm_volume":100,"audio_path":"…"}` — 警報音。`audio_path` はカスタム音キャッシュ済時のみ。
- `{"t":"reply",…,"lang":"en","audio":"<sha256>","audio_path":"…"}` — クイック返信は
  訪客言語のラベルで表示。`audio_path` があればそれを再生し TTS はしない。
- `{"t":"chime","sound":"asset:<sha256>","audio_path":"…"}` — カスタム鈴音。
- `{"t":"visitor_lang","door":"d_front","lang":"en"}` — 言語バッジの即時更新 (全ノード)。
- `{"t":"asset_ready","hash":"<sha256>"}` — 資産キャッシュ完了 (画像/音声の再読込合図)。

## クライアント側挙動 (参考・実装済み)

| 項目 | door.html | monitor.html |
|---|---|---|
| 輪詢間隔 | 2 秒 | 2 秒 (snapshot 差替は平時 5 秒) |
| オフライン判定 | XHR 連続 5 回失敗で帯表示、輪詢は継続 | 同左 |
| 自愈 | `<meta refresh 300>` | なし (audio 解錠が消えるため) |
| 押下後 | `panel.calling` を 30 秒表示 → 待機へ | — |
| 返信表示 | `reply.ts` が前回より新しければ大字バナー 30 秒 | — |
| 鈴声 | — | 初回タップで `<audio>` 解錠 → 呼出検知で play() (失敗しても無害) |
| mock | `?mock=1` で XHR せず内蔵データ描画 (実データと同一の `render()` を通る) | 同左 |
