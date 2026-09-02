# パネル API 契約

`webui/panel/door.html` (網頁版門口子機) と `webui/panel/monitor.html` (受鈴表示面板) が
使う HTTP API の契約書。実装の真実は Node 側
(`core/src/node/node.cpp` の `registerHttp`) と Web クライアントにある。

対象クライアントは iOS 5 Safari (iPad 1) を含む legacy ブラウザ:

- ES5 のみ。XHR 短輪詢 (2 秒)。WebSocket / SSE / fetch は使わない。
- 管理 UI が発行した credential を URL fragment (`#k=`) から
  `POST /api/panel/session` へ一度だけ交換し、以後は HttpOnly `dbpanel` cookie で認証する。

## 認証: panel token

- credential 本体は各 node の platform secure store に保存し、config には
  `panel.token_refs: ["secret:panel.access.…"]` と非 secret の `panel.token_generation` だけを保持する。
  session は generation と canonical ref set に紐付くため、複製済み rotation は全 node の旧 cookie を
  拒否する。failover に使う各 panel-serving node には、同じ ref の実値を Admin から個別に配備する。
- query/form の token は拒否する。cross-node upload だけは URL ではなく
  `Authorization: Bearer <credential>` を使用できる。
- token 不一致・欠落は `403` + `{"ok":false,"err":"bad token"}`。
- 静的ページ `/panel/door` `/panel/monitor` 自体は既存どおり認証免除 prefix
  (`/panel/`) で配信される。守るのは API と snapshot 転発のみ。

## GET /api/panel/state

パネルが 2 秒間隔で輪詢する唯一の状態取得口。optional `group=<name>` query は、この page の
`device_alert` 投影に使う Web subscription group を選ぶ。Web runtime は panel URL の
`?group=<name>` を検証して local に保持し、poll と Push subscription の両方に同じ group を使う。
欠落または不正な値は `all` に fallback する。応答:

```json
{
  "call_flow": "purpose_first",
  "active_page": "monitor",
  "emergency": { "active": false, "hlc": "", "web_active_page_alerts": true },
  "doors": [
    { "id": "d_front", "label": "正面玄関", "calling": false },
    { "id": "d_back",  "label": "裏口", "calling": true,
      "call_id": "0195…", "call_state": "ringing", "stage_revision": 1,
      "expires_at_ms": 1756300050000, "recovery_required": false }
  ],
  "events": [
    { "type": "press", "door": "d_front", "device": "", "wall_ms": 1756300000000 }
  ],
  "quick_replies": [
    { "id": "soon", "label": "すぐ行きます",
      "labels": { "ja": "すぐ行きます", "en": "Be right there", "zh": "马上来" } }
  ],
  "reply": { "text": "すぐ行きます", "ts": 1756300012345 },
  "server_ts": 1756300020000
}
```

- `doors[]` — 全ドア (config `doors.*`)。`label` は表示言語解決済みの文字列。
  `calling` は「呼出が発生し、まだ応答/タイムアウトしていない」間 true。
- `call_flow` — 固定文字列 `purpose_first | ring_then_purpose`。前者は用件を選んでから
  `POST /api/panel/press`、後者は press で得た `call_id` に
  `POST /api/panel/purpose` を関連付ける。object 形式は旧試作クライアントだけの読み取り互換。
- `doors[].call_id` / `call_state` / `stage_revision` / `expires_at_ms` — call v2 の optional 欄。
  `call_id` は呼出 1 回を一意に識別し、取消・後置用件には**必須**。クライアントは
  `stage_revision` が古い state/response で画面を巻き戻してはならない。`call_state` は
  `ringing | purpose_pending | answered | in_call | cancelled | expired | ended` を取り得る。
  terminal state は最大 30 秒だけ表示する読み取り専用 tombstone で、recovery 対象には戻らない。
- `doors[].recovery_required:true` — 再起動後に Core が未解決 call を復元し、client の明示的な
  復元結果を待っていることを示す。新しい呼出ではないため、同じ `call_id` で下記 recovery API を
  1 回だけ送る。
- `emergency` — optional の現在 SOS 状態。rolling upgrade 中に欄が無い場合だけ、active page は
  `events` 中で最新の `emergency | emergency_cancel` を fallback として使う。明示 `active:false`
  がある時に古い event で上書きしてはならない。
- `active_page` — optional の推奨ページ (`door | monitor | call`)。未知値は無視する。
  `web_active_page_alerts` が有効なら複製済みの active SOS が page より優先する。無効でも、
  Web group を対象とする正の `device_alert` または配信済み Push は page より優先できる。
- `doors[].stream_mp4` — H.264 の可用性ヒント/legacy direct URL。担当門口機の
  `camera.codec` が h264/auto の時に載る。現行 Web client は cross-origin URL を fetch せず、
  door id から同一 origin の `/stream-proxy.mp4` を組み立てる。MediaSource+fetch
  が使えるブラウザで MSE 再生し、未対応/失敗/503 (auto で硬編なし) は従来の
  スナップショット輪詢へ自動回落する。iPad 1 はキー自体を無視するだけ。
- `doors[].source_node_id` / `stream_mjpeg` — 担当門口機の node id と MJPEG ライブ URL。
- `doors[].playback_profile` — このページを配信するノードを受信側として解決済みの再生策略。
  `strategies[]` の順序・`enabled`・`startup_timeout_ms`・`stall_timeout_ms` を含む。
  Web は未対応の `h264_hls` を待たずに読み飛ばす。
- `events[]` — 直近 10 件 (既存 `/api/events` と同スキーマの縮小版。`payload` は不要)。
- `reply` — 最新クイック返信 (`text` + `ts` ms)。無ければ `null`。
  クライアントは `ts` の単調増加のみ比較する (初回受信分は既読扱い)。
- `quick_replies` — audio path や無関係な config を含まない、上限付きの設定済み返信 catalog。
  monitor は `doors[].visitor_lang` と同じ label を選べる。
- `server_ts` — サーバ壁時計 (ms)。クライアント側キャッシュバスター等の参考用。

## POST /api/panel/press

- Content-Type: `application/x-www-form-urlencoded` (legacy Safari 互換のため JSON でなく form)
- Body: `door=<id>`
- 応答: `{"ok":true,"call_id":"<opaque>","call_state":"ringing",`
  `"stage_revision":0,"expires_at_ms":<ms>}` / `403` (token 不正) /
  `{"ok":false,"err":"…"}` (door 不明など)。成功応答の `call_id` は call v2 で必須。
  Web panel は terminal state を観測するまで call identity と取消操作を保持する。poll 断だけで
  呼出終了と判断してはならない。durable event write に失敗した時は `500`。
- 効果は既存 `/api/press` (`doPress`) と同じ: 呼出イベント発火・通知経路へ。
- `call_flow=purpose_first` では `purpose=<id>` をこの request に含める。

## POST /api/panel/purpose

`call_flow=ring_then_purpose` の後置用件。Content-Type は form、Body は
`door=<id>&call_id=<opaque>&purpose=<id>`。

- `call_id` と door が現在の呼出に一致する時だけ受理する。古い call id は `409` とし、
  次の呼出へ用件を誤関連付けしてはならない。
- 成功: `{"ok":true,"call_id":"…","stage_revision":2}`。

## POST /api/panel/cancel

門口 Web client から現在の呼出を取り消す。Content-Type は form、Body は
`door=<id>&call_id=<opaque>`。

- `call_id` は必須。door だけの取消は `400/409` で拒否し、次の呼出を誤取消ししない。
- 成功は「取消 command の受理」であり、client は state が `cancelled` / `calling:false` に
  進むまで表示を勝手に idle に戻さない。
- endpoint が無い (`404/501`) または call_id を返さない旧ノードでは、client は
  「安全な取消 API は利用不可」と表示し、成功を装わない。

`answered` または `in_call` へ進んだ後は取消ではなく、次の hangup を使う。

## POST /api/panel/reply

Body は `door=<id>&call_id=<opaque>&stage_revision=<n>&reply_id=<configured-id>`。一致する
still-ringing call に設定済み quick reply だけを送る。古い・superseded・in-call は `409`、未知 reply は
`400`。成功時は ringing call を終了する。panel session から arbitrary text は受理しない。

## POST /api/panel/hangup

Body は `door=<id>&call_id=<opaque>`。一致する call が `answered` または `in_call` の時だけ、
その call が所有する SIP leg を終了し `call_ended` を発行する。訪客取消の経路は使わない。
ringing、欠落、古い、または未対応の call は `409`。

## POST /api/panel/call-lifecycle

Body は
`door=<id>&call_id=<opaque>&stage_revision=<n>&dialog_id=<32-hex>&state=<answered|heartbeat|ended>[&reason=<token>]`。

- WebRTC の手動応答 client は応答試行ごとに暗号学的に乱数な `dialog_id` を一つ生成する。
- その SIP dialog が確立した後だけ `answered`、確立中は少なくとも 10 秒ごとに
  `heartbeat`、成功した answered claim の dialog だけ `ended` を送る。monitor call はこの API を使わない。
- 応答には opaque な `dialog_owner` が含まれる。state が別 owner を示したら、負けた SIP dialog は
  `ended` を報告せず終了する。欠落 identity、古い revision、2 個目の browser dialog、終了済みまたは
  未確立 call は拒否される。heartbeat が 10 秒失われると recovery は全域取消を一度だけ発行する。

## POST /api/panel/recovery

再起動後の call 復元結果を解決する。Content-Type は form、Body は
`door=<id>&call_id=<opaque>&restored=<true|false>`。

- 対応する state が `recovery_required:true` の間だけ送る。`restored=true` は client が call
  UI/session を復元したこと、false は復元できなかったことを示す。
- 成功は `{"ok":true}` で pending flag を解除する。欠落・古い・解決済み・pending でない call は
  `409`、token 不正は `403`。retry は必ず同じ call id に限定し、新しい call を解決してはならない。
- in-call WebRTC の復元には answered claim を勝ち取った同じ `dialog_id` が必要。別 browser や一般の
  door page はその dialog の復元を確認できない。

## POST /api/panel/emergency

SOS 緊急モードの**発報のみ** (解除は不可)。標準 panel は常時表示する `sos.trigger` を持ち、
連続 2 秒の長押しが完了した場合だけ送信する。

- Content-Type: `application/x-www-form-urlencoded`、Body: `active=1`。HttpOnly panel session
  または rolling-upgrade 用の `k=<token>` credential が必要。
- 応答: `{"ok":true}` / `403` (token 不正)
- `active=0` (または `active=false`) を付けた解除要求は `403` +
  `{"ok":false,"err":"cancel not allowed"}` — 解除は kiosk PIN 経由の端末操作
  (`db_core_emergency(0)`) か管理セッションの `POST /api/emergency` のみ。
- SOS active/clear 状態は常に全 Core ノードへ複製されるが、表示、音、Push、Telegram、MQTT の
  実行先は有効な rule によって決まる。rule は受信者ゼロまたは Push のみにもでき、保存を妨げない。
- 管理者 boolean `emergency.web_active_page_alerts` の既定値は true。true なら開いている Web page は、
  受信者ゼロ、Push のみ、または古い負の `device_alert` 投影より先に複製済み active SOS を表示する。
  false なら raw state だけでは表示しないが、Web group を対象とする正の `device_alert` または配信済み
  Web Push は引き続き表示できる。
- `device_alert.presentation` と Push payload は `visual`、`sound`、`volume` (0–100)、`sticky`、
  `ttl_s`、`background`、`foreground`、`accent` を指定できる。Web は範囲と色のコントラストを検証し、
  不正なら安全な palette を使う。browser audio policy が許す場合だけ上限付きの警報音を鳴らす。
  raw active-page SOS が有効で SOS が active の間、non-sticky の正の TTL が終了させるのは rule
  decoration と sound だけである。page は SOS clear または管理者 switch off まで安全な赤い raw-SOS
  overlay に戻る。raw path が off の場合は TTL で投影表示を閉じられるが、複製 SOS state は解除しない。
- Push payload は全 presentation field を保持する。Service Worker は sticky/TTL と requested
  sound/volume を browser notification capability に map し、同じ payload を open panel へ渡して
  full-screen color と bounded audio を render する。browser/OS notification API は custom sound/volume を
  無視する場合があり、arbitrary background/foreground/accent color は提供しない。この制限を OS
  presentation success と報告してはならない。
- Core の `delivery_result` は dispatch の試行結果であり、画面表示や音の成功証明ではない。
  client の runtime status にある channel 別 presentation report が適用、抑制、未対応、失敗を示す。

## GET /snapshot-proxy?door=\<id\>

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

## GET /stream-proxy.mp4?door=\<id\>

担当 door station の fMP4/H.264 live stream を**同一 origin**で転送する。panel token または
管理 cookie を検証し、`200 video/mp4` (chunked/streaming、`Cache-Control: no-store`) を返す。

- 担当が自機なら `/stream.mp4` provider を同じ response に接続し、他ノードなら server 側で
  転送する。ブラウザへ peer origin の redirect を返してはならない (fetch CORS が再発する)。
- codec が MJPEG / encoder 無効は `503`、door 不明は `404`、token 不正は `403`。
- disconnect は上流 subscription も即時解除する。Web は MSE 不可・503・stall 時に playback
  profile の次 strategy へ進む。

## Web Push (optional modern-browser extension)

legacy panel の 2 秒 poll は常に残し、以下は HTTPS/localhost + Service Worker 対応時だけ使う。
endpoint 未実装 (`404/501`) は client に明示し、購読済みと表示しない。

- `GET /api/panel/push-vapid-public-key` →
  `{"ok":true,"public_key":"<base64url P-256 public key>"}`。
- `POST /api/panel/push-subscription` JSON body
  `{"subscription":<PushSubscription.toJSON()>,"page":"/panel/monitor","group":"guards"}` →
  `{"ok":true}`。page は `?group=<name>` の有効値を local に保持し、同じ group を
  `/api/panel/state?group=<name>` と subscription に使う。未指定時は `all`。
- `DELETE /api/panel/push-subscription` JSON body
  `{"endpoint":"https://push-service/…"}` → `{"ok":true}`。他 subscription は消さない。

Core は subscription 全体の `endpoint`/`p256dh`/`auth` を normalize し、mesh PSK から導出した key と
XChaCha20-Poly1305 で schema-v2 CRDT record に一括 seal する。config/export に plaintext は出ない。
起動時、旧 raw record は可能なら seal し、できなければ fail-closed で削除するため、その場合 operator
は再 subscription が必要になる。subscription operation/provider delivery に必要な時だけ bounded memory
内で open し、delete は送信された exact endpoint から record key を導出する。sealed boundary 内では
opaque byte を lossless に保持する。

push payload は少なくとも `{kind,title,body,tag,url,door,call_id,active,wall_ms}` の部分集合。
Service Worker は通知を表示すると同時に開いている `/panel/` client へ payload を postMessage する。
通知 click は既存 active page を優先して focus + postMessage し、無い場合だけ token を保持した
`/panel/monitor` を開く。`url` は same-origin `/panel/` 以外を拒否する。
- monitor.html は **UA 判定をしない**。`<body data-live="1">` を手動で付けた場合のみ
  この URL を使い、`<img>` の src を据え置く (それ以外は snapshot 輪詢)。

## GET /api/panel/call-info  (網頁通話 — call.html 用)

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
  SIP password は secure reference から memory 内で解決して認証済み response にだけ返す。
  `boot.json`、URL、event、log、平文 config に埋め込んではならない。
- `doors.<id>.extension` — その door 担当門口機の内線 (`sip.accounts.<node_id>.user`)。
  空 = 通話不可 (映像のみ)。
- `doors.<id>.station` — 担当門口機の origin (`http://<host>:47180`)。**空文字 = このノード
  自身が担当** (相対 URL でよい)。`/stream.mjpeg` の表示と `/call-frame` の POST 先に使う。
- `doors.<id>.source_node_id` / `stream_mjpeg` / `stream_mp4` / `playback_profile` — 通話ページが
  monitor と同じ H.264 優先・MJPEG 背景予熱・順方向フォールバックを行うための情報。
- 担当門口機が devices に無い door は `doors` に載らない。

## POST /call-frame?door=\<id\>  (ブラウザ → 門口機の相手映像)

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

- Body (form): `lang=<ja|en|zh>[&door=<id>]`。door 省略 = そのノードの担当 door。
- `lang=ja` は即時復帰。無操作 `ui.visitor_lang_revert_s` 秒 (既定 60) で自動的に ja へ
  戻る (按鈴で計時やり直し)。切替は `visitor_lang` イベントとして全ノードへ複製される。

### GET /api/panel/i18n

パネルページの文言解決 (実行時上書きと言語一覧)。読込時に 1 回取得する (輪詢しない)。

```json
{ "ok": true, "languages": ["ja", "en", "zh"],
  "overrides": { "ja": { "idle.touch_to_call": "タッチして呼び出してください" } } }
```

- `overrides` = config `i18n_overrides` の全文 (無ければ `{}`)。ルックアップ順は
  上書き → ページ内蔵文言 → キー自身 (core の Node::text と同順)。

### GET /asset/\<sha256\>

統一資産 (背景画像/カスタム音声) の実体。trusted media LAN では panel または管理
セッションなしで取得できる。公開扱いは 64 桁小文字 SHA-256 を含む正確な GET path のみで、
他の method や asset に似た path は session gate の対象。内容アドレスなので不変 —
`Cache-Control: immutable` 付き (詳細は docs/config-schema.md の「統一資産 API」)。
原生殻は core が検証したローカルパス、または query credential のない loopback asset URL を使う。

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

## Web semantic UI

panel state は `web_ui.device_id`、配信中 Core node に内蔵された schema-v1
`web_ui.manifest`、および `devices.<device_id>.local.ui.elements` の実効 override を含む。
これは native runtime status の top-level `ui_manifest` とは別の manifest で、現時点では
`call.primary`、`cancel.call`、`call.end`、`purpose.button`、`ring.title`、`ring.action`、
`status.offline`、`reply.button`、`monitor.close`、`sos.trigger` を宣言する。SOS entry は 2 秒長押し control と full-screen
presentation の安全 baseline を同時に style し、valid な rule presentation color は一時的に優先する。
page は宣言済み property、contrast、最小 44 effective px を検証し、
不正な更新では last-known-good style を維持する。`/api/panel/ui-report` は renderer が実際に適用または
拒否した後だけ送る。

`sos.cancel` は Web contract に意図的に含めない。panel session は SOS を発報できるが、複製済み
emergency state の解除権限はなく、kiosk PIN または authenticated Admin control が担う。

Web manifest はその Core node に local であり、peer ごとの Web catalog として複製されない。
Admin は native peer manifest から remote/offline Web surface を推測・編集できず、manifest 不明時に
架空の fallback editor を表示してはならない。

## クライアント側挙動 (参考・実装済み)

| 項目 | door.html | monitor.html |
|---|---|---|
| 輪詢間隔 | 2 秒 | 2 秒 (snapshot 差替は平時 5 秒) |
| オフライン判定 | XHR 連続 5 回失敗で帯表示、輪詢は継続 | 同左 |
| 自愈 | `<meta refresh 300>` | なし (audio 解錠が消えるため) |
| 押下後 | 同じ `call_id` の state が終了するまで call UI を表示 | — |
| 返信表示 | `reply.ts` が前回より新しければ大字バナー 30 秒 | — |
| 鈴声 | — | 初回タップで `<audio>` 解錠 → 呼出検知で play() (失敗しても無害) |
| mock | `?mock=1` で XHR せず内蔵データ描画 (実データと同一の `render()` を通る) | 同左 |
