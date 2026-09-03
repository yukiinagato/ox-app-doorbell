# システム概要

ox-app-doorbell は複数 node の宅内 doorbell/intercom です。native client は C++ core を共有し、
mesh、複製 config/event、rule、HTTP API、media 配信、SIP control を扱います。platform shell は
versioned `db_platform_v2` を通じて UI、camera/audio、secure storage、HTTPS、kiosk、実測 capability
を提供します。

English が正準です。[capability](capability-matrix.md)、[deployment](deployment.md)、
[config](config-schema.md)、[security](security.md)、[recovery](recovery.md)、
[ports](network-ports.md) を参照してください。

## role と障害境界

| role | 責務 |
|---|---|
| `door_station` | 訪問者 UI、ring event、その端末に実在する media/audio。role は camera、mic、屋外規格、実機認証を意味しない。 |
| `indoor_panel` | 対象指定された着信 UI、monitor/answer、reply、emergency UI。 |
| browser panel | HTTP panel/API。音声通話には secure context と Asterisk WebRTC 設定が必要。 |
| 任意 integration | MQTT/HA、Telegram、Asterisk/PSTN、go2rtc/HomeKit。依存 action は各 service 停止時に利用不可。 |

中央 DB が無くても mesh 状態は収束します。適切な rule と実 PJSIP があれば mesh ring/local chime/
direct intercom は HA/PBX 停止中も継続可能です。Telegram、HA、PSTN、browser WebRTC、PBX 経由 call
は各 service に依存します。

## 実装済み contract

実装済みの中心契約は call ID、targeted schema-v2 chime、cancel/recovery/stale rejection、LWW config/
event、runtime capability/status、rule、admin/panel API、asset、MJPEG/snapshot、verified platform が
渡す H.264 の fMP4 packaging、secure-store の `secret:` reference です。`sipctl_stub` は product 通話に
使えません。

schema-v2 lifecycle では手動応答 client が exact `door`/`call_id`/`stage_revision` を answer-mode SIP
dialog にだけ bind します。接続後 `call_answered` は決定的な `dialog_owner` を 1 つ保存し ring timeout
を止め `in_call` にします。visitor cancel は以後拒否し、同時応答 loser は winner を ended にせず
hangup、monitor は ownership を claim しません。owner hangup が `call_ended` を発行します。restart 後
ringing は press origin、in-call は dialog owner が 10 秒以内に復旧し、失敗時は global idempotent
recovery cancel を 1 回だけ発行します。

SOS state は常に複製しますが recipient/channel presentation は rule-driven で空にもできます。Web は
既定で replicated SOS を処理し、`emergency.web_active_page_alerts:false` は raw-state path だけを
無効にします。matching positive `device_alert`/Web Push は引き続き表示できます。Core
`delivery_result` は dispatch attempt であり、client runtime report は channel 別
presentation/limitation です。raw path が
有効な間、rule TTL は custom decoration/sound だけを終了し、安全な赤い raw-SOS overlay は clear
または switch off まで残ります。

## indoor camera preview の scheduling

preview の負荷は door の設定総数ではなく、panel が同時表示できる数で制限します。1 台は aspect を
保った大きな tile、2〜3 台は利用可能な viewport を分割し、それ以上は compact tile と明示的な
scroll/page 選択を使います。Android は 1 cycle につき可視 tile を最大 3、modern iOS は 1 page 4、
iPad 1 は 1 page 3 (safe mode は 1) だけ更新し、非表示 tile は snapshot を取得・decode しません。

`press`/`motion` event は対象 door を active set の先頭へ昇格します。重複を除いた newest-first とし、
burst が起きても active slot 数を超えて処理しません。resident は Android の scroll、iOS の番号付き
camera page で event の選択を上書きできます。これは dashboard scheduling だけの規則であり、設定済み
door はすべて direct monitor 可能なままです。

## 映像起動 hot path

H.264 設定の door station は viewer がいない間も platform encoder を稼働させます。Core は初期化
segment と最新の完全な random-access fragment を保持し、新しい fMP4 subscriber に即時送信すると
同時に、集約可能な keyframe request を発生させます。Android MediaCodec、Apple VideoToolbox、
iOS 5 RTSP ingest (RTCP PLI)、Windows Media Foundation は encoder を再起動せず request を処理します。
MJPEG path は bounded cache を background で準備し、live stream が追い付くまで 250 ms 以内の信頼
できる frame を先に提示できます。

Indoor shell は再利用可能な rendering resource を事前準備します。Android は停止状態の AVC decoder
を 1 個、modern iOS は `AVPlayer`/`AVPlayerLayer` の組、iOS 5 は 1-pixel GL/VideoToolbox view を保持し、
Windows は main window と共に media element を生成します。memory pressure 時にはこれら任意 reserve
を解放できます。着信 preview は H.264 の frame 表示が実証されるまで availability layer として残り、
応答後も再接続せず同じ transport/player を継続します。browser viewer も同じ Core-side cached JPEG
または fMP4 bootstrap を受け取ります。visitor cancel は call lifecycle と呼出音だけを終了し、indoor
panel の current preview は切断しません。transport の終了は resident の close 操作または通常の page
deadline が担います。これは起動遅延を減らす仕組みであり、全 hardware が固定の
glass-to-glass 目標を満たすという主張ではありません。実機 timing qualification は別途必要です。

Core は peer の last-valid native UI manifest/capability を永続 cache します。`cached_contract:true` の
configured offline device は cached contract に対して検証/queue できますが、適用証明は後の renderer
report が必要です。Web manifest は serving Core node local のままです。`targets` object がない legacy
alert は全 native node/Web group を対象にします。明示 selector は対称で、Web group だけなら native
shell は対象外、native selector だけなら active Web page/Push subscription は対象外です。Web page は
`?group=<name>` の保存値を state poll と Push enrollment の両方に使います。complete Push subscription
secret は mesh-PSK-derived key と XChaCha20-Poly1305 で schema-v2 CRDT record に一括 seal し、
config/export に plaintext を出しません。

## platform 状態

| platform | 対象 | 状態 |
|---|---|---|
| Android | API 21+ modern、API 19 armv7/NEON legacy | moto g64y 5G/API 34 の bounded critical-trim/fMP4 recovery smoke は合格。API 19 qualification list は空 (support SKU 0)。CI debug-contract APK は release ではない。 |
| Windows | .NET 4.8 WPF、x86/x64 core | gate はあるが Windows VM/Toughpad 検証は未完了。 |
| iOS | iOS 12+、iOS 9 arm64、iOS 5.1 armv7 | iOS 9 arm64 は unsigned link proof のみ、armv7 formal gate は未 commission。iOS 5 は `ios-kiosk` + staged `ios-compat`。 |
| tvOS | 映像 monitor/reply + direct-SIP listen-only source path | tracked CI は real PJSIP の unsigned Debug simulator build だけ。Release/device 未検証。mic 無しで Answer/transmit 未対応。 |
| Web | admin/panel/same-origin media/active SOS/optional Push | WebRTC/Push は条件付き。native/Web manifest は別で remote Web manifest は複製しない。legacy Safari は best-effort。 |

初代 iPad は内蔵マイク・スピーカ有り、カメラ無しです。実機試験後に indoor role または明示した
外部 camera/no-video door profile で使用します。屋外対応品ではないため、玄関利用には防水、防露、
温度管理した enclosure が必要です。bounded RTSP/TCP H.264 ingest と Annex-B 転送は host/loopback
検証済みですが、実 IDR accept までは degraded で、iPad 1 + 実 camera qualification は未完了です。
HTTP(S) MJPEG/snapshot direct playback は `secret_ref` を ephemeral auth header にだけ解決し、JPEG を
Core に forward しません。optional root helper は実装・host test 済みで、launchd を無効のままにする
再現可能な staged DEB もありますが、opt-in で iOS 実機 qualification は未完了です。別の bounded
Android→Core fMP4→iPad smoke では実 iPad 1 foreground renderer が 15～16 fps で合格しましたが、
crash 後の unattended foreground video resume と全体の hardware gate は未完了です。

## repository 検証入口

基本検証は English overview の command と各 platform README/release gate を使用します。host core
test の成功を signed/SIP-enabled/hardware artifact の合格証跡にしません。

`tools/conformance/run.py` は golden reference-model replay + narrow source-anchor smoke であり、client
artifact、rendering、timing、signing、hardware の証明ではありません。
