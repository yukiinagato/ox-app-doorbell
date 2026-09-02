# Web 管理 API 追加契約

管理画面が機能対齊に使う最小契約。認証は既存 `dbsess` cookie + SameSite=Strict。

## secret write

認証済み Admin session の `POST /api/secrets` は
`{"secret_ref":"secret:<name>","value":"<secret>"}` を platform secure-store callback へ書き、値を
返したり config に materialize したりしません。成功後だけ対応 `*_ref` を `/api/config/batch` で保存します。
MQTT、Telegram、SIP の単一 field 編集は未知 field と既存 ref を lossless に保持します。

`DELETE /api/secrets` は、対応する config 更新が commit した後に同じ `secret_ref` を受け付けます。
materialize 済み config のどこかがまだその secret を参照している間は
`409 secret_ref_in_use` を返し、共有 ref を別 account の使用中に削除しません。

MQTT/Telegram の ref は fleet config ですが、実値は各 node の secure store にのみ保存します。
初回保存または rotation 後、integration leader 候補の各 node で Admin を開き、既に複製済みの ref に
**このノードに配備** で同じ実値を書きます。この操作は新しい ref や fleet config mutation を作りません。
すべての候補が対応 backend ready を報告するまで failover 完了とは扱いません。

SIP account は device ごとです。password の作成、rotation、同一 ref への local provisioning は、その
account の target node 自身が提供する Admin でだけ実行できます。remote row は非 secret の user field
だけを編集でき、target の password を別 node の secure store へ誤保存できません。

すべての config write endpoint は同じ recursive secret contract を適用します。plaintext `pass`/
`password`/`bot_token`/`sip_pass`、VAPID private key、`panel.tokens`、不正 ref、URL userinfo、credential
query parameter は nested object/array 内でも request 全体を拒否します。

`POST /api/panel-token/rotate` は新 credential を secure store に保存し、`panel.token_refs` と非 secret
の `panel.token_generation` を原子的に置換します。response は `Cache-Control:no-store` で一度だけ
値を返し、Admin は query でなく `#k=<credential>` の launch link を生成します。panel session は
複製済み generation と canonical ref set に紐付くため、rotation は fleet 全体の session を無効にします。

`POST /api/panel-token/provision` は
`{"secret_ref":"secret:panel.access.…","token":"<credential>"}` を受け付けます。ただし、複製済み
`panel.token_refs` で現在 active な ref に限ります。この node の secure store へ書き、local panel
session を無効化しますが、config は変更せず、`Cache-Control:no-store` の response に credential を
返しません。panel failover に使う全 node の認証済み Admin で繰り返します。

Web Push subscription は plaintext config/export に出しません。Core は subscription 全体の
`endpoint`/`p256dh`/`auth` を mesh PSK から導出した key と XChaCha20-Poly1305 で schema-v2 CRDT record
へ一括 seal します。起動時は旧 raw record を再 seal し、できなければ fail-closed で削除するため、
削除された browser は再 subscription が必要です。

## POST /api/config/batch

複数の LWW-map 操作を 1 commit として適用する。JSON body:

```json
{
  "ops": [
    {
      "op": "set",
      "key": "devices.node.local.ui.elements.call.primary",
      "value": { "scale": 1.1, "foreground": "#ffffff", "background": "#101418" }
    },
    { "op": "delete", "key": "devices.node.local.ui.elements.status.offline" }
  ]
}
```

- `set.value` は任意の JSON 値であり、JSON 文字列へ二重 encode しない。
- 全 op を先に検証し、1 件でも不正なら non-2xx + `{ok:false,err}` で**何も変更しない**。
- 全件を同じ原子 commit として永続化してから config change を 1 回通知する。
- 成功: `{ "ok":true, "n":2, "revision":"<opaque>" }`。`revision` は診断/将来の
  optimistic concurrency 用で、client は数値と仮定しない。移行中の `hlc` alias も受理できるが、
  新 client 契約は `revision`。
- 同一 request 内の空 key / 重複 key / 未知 op は拒否する。
- endpoint が `404/501` の旧ノードへ、管理画面は逐次 `/api/config` に fallback しない。
  UI に「原子的設定 API は利用不可」と表示して partial save を防ぐ。

import と raw-key editor もこの endpoint を使う。旧 `/api/config/import` は互換 endpoint に残せるが、
現行 Web UI の保存経路には使わない。

端末別 recovery mode は complete value として
`devices.<node_id>.local.recovery.helper_mode` に書く。有効値は `off|auto|on` のみで、Admin の既定は
`auto`。partial save を防ぐため認証済み batch endpoint を使う。設定 mode は root helper の install、
到達性、effective mode の証拠ではないため、実測 runtime helper status を別に表示する。

## Per-device semantic UI

native `ui_manifest` は client が `/api/status` の top-level に公開する read-only runtime capability
です。Admin を配信する node は別の built-in Web renderer contract を `web_ui.manifest` に公開します。
element set が違うため **Native UI** と **Web UI** editor は別ですが、同じ serving-device config path
へ書きます。現行 Web manifest は `call.primary`、`cancel.call`、`call.end`、`purpose.button`、
`ring.title`、`ring.action`、`status.offline`、`reply.button`、`monitor.close`、常時表示の 2 秒長押し
control `sos.trigger` を含みます。panel session には SOS 解除権限がないため `sos.cancel` は含めません。

peer gossip は native manifest を運び、Core は各 peer の最後に有効な native manifest/capability を
永続 cache します。`cached_contract:true` の configured offline device は Core restart 後も cached
contract に対して検証・保存できます。ただし apply success ではなく、exact renderer が再接続・検証し
runtime report を出すまで待ちます。Web UI は現在の server node だけ編集でき、remote/offline Web
manifest catalog はありません。native peer manifest を Web fallback に使わず、manifest 自体も書換えません。

schema v1 の shape:

```json
{
  "schema_version": 1,
  "units": "logical",
  "viewport": {
    "minimum_touch": 44,
    "scale_min": 0.75,
    "scale_max": 2.0
  },
  "elements": {
    "call.primary": {
      "properties": [
        "scale", "font_scale", "foreground", "background",
        "accent", "border", "radius"
      ],
      "safety_critical": false
    },
    "cancel.call": {
      "properties": ["scale", "foreground", "background", "accent", "border", "radius"],
      "safety_critical": true
    }
  }
}
```

管理画面が書けるのは、manifest に列挙された element/property の override だけ:

```json
{
  "scale": 1.1,
  "font_scale": 1.05,
  "foreground": "#ffffff",
  "background": "#101418",
  "accent": "#4da3ff",
  "border": "#4da3ff",
  "radius": 12
}
```

保存先は `devices.<node_id>.local.ui.elements.<semantic_id>`。複数 element の変更/reset は
`/api/config/batch` 1 request で原子的に保存する。既存 `devices.<node_id>.local.ui.style` は
移行時の初期値を表示するためだけに読めるが、新しい Admin はこの key へ書かない。
import/raw-key editor も writable manifest、legacy style、個別 property leaf を拒否し、element
override object 単位に復元して batch 送信する。

管理 editor の安全規則:

- property は `scale | font_scale | foreground | background | accent | border | radius` のうち、
  当該 element descriptor が列挙したものだけ。`visible`、`emphasis`、汎用 `color` alias はない。
- 色は `#RRGGBB`。同じ override に foreground/background があれば 4.5:1 以上、
  accent/background があれば 3:1 以上。
- `scale` と `font_scale` は manifest の `viewport.scale_min`–`scale_max`。
  `radius` は 0–`viewport.minimum_touch` logical。
- `safety_critical:true` の element に `visible` はそもそも指定できず、管理画面は scale 1 未満も
  拒否する。
- schema/version/shape が不正または欠落した runtime manifest は部分適用せず、明示的に unavailable
  と表示する。offline/missing manifest を writable default で置換しない。

## 呼出フローの互換性

`ui.call_flow` は `purpose_first` または `ring_then_purpose` の文字列として、原子的な
batch endpoint で保存する。`ring_then_purpose` に対応すると判定できるのは、実測済みの
status feature map に `call_flow_v2:true` を明示する peer だけである。version、role、または
feature map の欠落から対応を推測しない。その宣言がない全 peer を保存前に警告表示する。
ローリングアップグレード中の旧 client は `purpose_first` 動作を維持するため、警告は保存を
ブロックしない。

## lossless trigger rule 編集と SOS dry-run

`trigger_rules.<id>` は whole-value 設定である。visual editor は deep copy から開始し、管理者が
変更した field だけを merge する。top-level、`when`、`schedule`、action、`targets`、
`presentation` の未知 field と `never_suppress` を保持する。未知 action type は read-only で
表示し、別の type へ変換したり削除したりしない。seed 済みの `r_sos_default_on` または
`r_sos_default_off` を変更せず開いて保存した値は、元の値と構造的に同一でなければならない。

editor は `emergency_on`、`emergency_off` trigger と、次の `device_alert` action を扱う:

```json
{
  "type": "device_alert",
  "targets": {
    "devices": ["panel-a"],
    "roles": ["indoor_panel"],
    "web_subscription_groups": ["guards"]
  },
  "channels": ["in_app", "system_notification", "web_push"],
  "never_suppress": true,
  "presentation": {
    "visual": true,
    "sound": "siren1",
    "volume": 100,
    "sticky": true,
    "ttl_s": 0,
    "background": "#8F1010",
    "foreground": "#FFFFFF",
    "accent": "#FFD166"
  }
}
```

各 selector は配列または `"all"` を受け取る。`targets` object がない legacy action は全 native node と
全 Web subscription group を対象にする。`targets` がある時は selector が明示的で、
`web_subscription_groups` だけの object は native shell を対象にせず、逆に
`web_subscription_groups` がない object は active Web page/Push subscription を対象にしない。
`web_profiles` は read-only compatibility alias で、新規保存は
`web_subscription_groups` を使う。`channels` の省略は従来の `in_app` 既定値を維持し、明示的な空配列は
silent を意味します。color は `#RRGGBB` で、Web renderer は unsafe contrast を拒否して safe palette を
使います。dry-run は device ID/role/Web group/offline target/Push subscription に加え、各 target の実測
`device_alert_channels`/support/permission を解決し、configured local recipient と現在 presentation
可能な recipient を分けます。zero recipient、silent、unsupported/unavailable channel、rolling-upgrade
で support unknown、該当 Push subscription なし、backend unavailable を警告しますが保存は阻止しません。

`status.web_push.delivery_backend:true` は、現在の mesh partition に eligible な `web_push` leader が
存在し、その実測 capability が有効な HTTPS sender 設定と local で読める VAPID private secret を
含むことを表します。`configured:true` だけでは delivery ready ではありません。診断用に `leader`、
`local_secret_ready`、bounded `warning_code` も公開します。

Integrations tab では non-secret sender URL、VAPID public key/subject、secret reference を一つの save
plan として編集します。新しい VAPID private key または optional sender bearer token を入力すると、
まず current node の secure store に fresh reference で保存し、その secure write が成功した後だけ
replicated configuration を commit します。reference 作成後は、各 leader candidate 自身の Admin page
から **このノードに配備** を使い、replicated configuration を変更せず同じ値を local に保存します。
全 candidate の配備が済み、status が non-empty leader と `delivery_backend:true` を示すまでは
Push-only SOS に依存しないでください。

`emergency.web_active_page_alerts` は independent boolean switch で既定 `true` です。true なら zero
recipient、Push-only、stale negative projection より replicated active SOS を優先して open Web page に
表示します。false は raw-state path だけを止め、matching positive `device_alert`/delivered Push は表示可能です。
raw path が有効な間、rule TTL は custom decoration/sound だけを終了し、安全な赤い raw-SOS overlay は
SOS clear または switch off まで消しません。

Core `delivery_result` event は local shell callback dispatch、shell unavailable、Push accepted/failed、
no recipients、backend unavailable など dispatch attempt の証拠で、OS/browser presentation の証明では
ありません。native client は runtime `device_alert` に channel 別 presentation/permission/TTL expiry/
limitation を別に報告し、Admin は両 evidence level を区別します。

## 時刻サービス

`GET /api/status` は `time` オブジェクトを返します。

```json
{
  "zone": "Asia/Tokyo", "zone_known": true,
  "source": "system", "enabled": false, "ok": false,
  "offset_ms": 0, "measured_offset_ms": 0,
  "last_sync_ms": 0, "rtt_ms": 0, "server": "", "interval_s": 900,
  "offset_min": 540, "syncing": false,
  "local": { "iso": "2026-09-02T21:30:00+09:00", "date": "2026-09-02",
             "hh": 21, "mm": 30, "ss": 0, "weekday": "wed", "weekday_num": 3,
             "offset_min": 540, "dst": false, "known": true,
             "wall_ms": 1772000000000, "tz": "Asia/Tokyo" }
}
```

`source` が `ntp` になるのは `time.ntp.enabled` が true で、かつ 3 間隔以内に同期が成功している
場合だけです。それ以外は `system` で `offset_ms` は 0 になります。`measured_offset_ms` は
どちらの場合も最後の測定値を保持するので、NTP を切ったあとも測定結果を表示できます。
`err` は同期失敗後に現れ、`no_response` / `bad_server` / `bad_reply` / `implausible` のいずれかです。
Admin は `source` をそのまま表示し、`enabled` だけから推測してはいけません。有効でも到達できない
時刻サービスは system 時刻で動いているからです。

`POST /api/time/sync` (管理セッション) は即時の 1 回を開始し `{"ok":true,"started":true}` を返します。
独立時刻サービスが無効なら `409 {"ok":false,"err":"ntp_disabled"}`、core 起動前なら
`409 {"ok":false,"err":"not_started"}` です。交換は非同期なので、200 を同期完了とみなさず
`/api/status` を読み直すか `time_changed` イベントを待ってください。

`time.zone` は core 同梱の表にある識別子でなければ通常の設定 API でも拒否されます。派生値の
`integrations.tz_offset_min` は core 自身が書き直すので、Admin のフォームから両方を書かないでください。

## 音量

クラスタ既定は `audio.volume.{call,sos,idle}` (0..100)、端末上書きは
`devices.<id>.local.audio.volume.<level>` です。コンテナ書き込み (`audio` / `audio.volume` /
`devices.<id>.local.audio`) は全体として検証するため、atomic batch で親オブジェクト経由に
範囲外の値を紛れ込ませることはできません。上書きの解除は `null` の書き込みではなく leaf key の削除です。

core の解決順は 端末上書き → クラスタ既定 → 組み込み既定 (call 80 / sos 100 / idle 60) で、
sos だけは `emergency.alarm_volume` にも fallback します。`db_core_audio_json` は同じ解決結果を
ネイティブシェルへ公開します。

## お知らせ

`POST /api/doors/<id>/notice` は `{"text":"…","expires_ms":0}` または
`{"text":"…","ttl_s":3600}` を受け付けます。両方あるときは `expires_ms` が優先、0 は「取り消すまで」です。
`DELETE /api/doors/<id>/notice` で解除し、存在しないお知らせの解除も成功扱いです。どちらも
管理セッションと panel 資格情報の**どちらでも**受け付けます。室内のお知らせダイアログと管理画面の
門口タブが同じ値を書くためです。

値は `doors.<id>.notice` の通常の複製設定です。

```json
{ "text": "本日は勝手口へお願いします", "from_device": "<node_id>",
  "created_ms": 1772000000000, "expires_ms": 0 }
```

`text` は Unicode コードポイントで 1..200 文字。`from_device` と `created_ms` は呼び出し側ではなく
core が書きます。未知の門口、空文字、上限超過は `400 {"ok":false,"err":"rejected"}` で、既存の
お知らせはそのまま残ります。期限切れは core が 1 分ごとの tick で削除し `notice_changed` を送出するので、
表示中の panel が独自の期限タイマーを持つ必要はありません。

## 電池と電源

任意の platform power コールバックを実装した端末は `status.self.power` (同内容の
`status.node.power` も) を公開し、`status.peers[].power` にも同じオブジェクトが現れます。

```json
{ "battery_pct": 82, "charging": false, "mains": true }
```

電池のない端末では `battery_pct` は `-1` で、UI は 0% 表示ではなく何も出さないでください。
コールバックを実装しない端末には `power` キー自体がありません。これは「電池残量 0」とは別物です。
peer の値は限定された runtime 射影を通るため、この 3 フィールド以外は運びません。
