# 復旧と rollback

self-healing は node や任意 integration の復帰後に複製状態が収束することを意味します。force-stop、
kernel 障害、停電、署名切れ、hardware 故障から全 platform が無条件に復旧する意味ではありません。

端末別 `devices.<id>.local.recovery.helper_mode` は `off|auto|on` の request policy です。Admin の既定は
`auto` で認証済み atomic batch として書き、Core は他の値を拒否します。platform は fixed `MODE` を転送し、
helper は restart を跨いで原子的に保存します。設定 mode と実測 helper availability/effective runtime mode を
必ず分けて確認します。helper が無い、拒否された、未 qualification の場合、設定 `on` だけで capability
にはなりません。
永続 `auto` と `on` は helper/OS restart 後も armed で、fixed app を cold launch できます。永続 supervision
を disarm するのは `off` だけです。`off` への変更は既に動作中の app を終了しません。Android の
`DISABLE` は `auto` で許可される一時 disarm で、永続 mode の変更ではありません。

## 障害境界

| 障害 | 期待する経路 | operator gate |
|---|---|---|
| view/activity 再生成 | ringing は press origin、in-call は記録済み `dialog_owner` だけが exact `door`/`call_id`/`stage_revision` で復旧。monitor は visitor call を所有しない | 二重着信、古い call、event 消失、loser が winner を ended にしないこと |
| process crash/hang | platform supervisor が backoff と circuit breaker 付きで再起動 | crash/hang/memory pressure/safe mode 試験 |
| force-stop/service 抑止 | process 内の仕組みだけでは復旧不能の場合あり | 外部 supervisor を実機 commissioning、または制限を記録 |
| node/network 消失 | unavailable 化し、復帰後に config/event が収束 | partition/reconnect/clock skew/重複配送試験 |
| HA/Asterisk 停止 | 設定済みの mesh ring、local chime/rule、direct SIP は継続可能 | 外部 HA/PSTN/WebRTC は停止。実配備で確認 |
| config 破損 | 実装済み platform は原子的な旧世代へ戻し、健全 peer から再同期 | secret reference の解決を確認 |
| 盗難 | PSK と integration/panel credential を回転し再 pair | 旧 node/token の拒否を確認 |

## backup と rollback 手順

backup は config export と device-local secret を分離します。成果物ごとに source revision、build ID、
manifest/checksum、OS/API、architecture、SIP backend、dependency hash、signing identity を記録し、旧 package
を別 lane に保存します。rollback 後は pairing、capability/runtime status、media/audio/call/kiosk、停電・
network loss を再確認します。

## platform 注記

Android の process 内復旧は全 force-stop を救えません。Windows watchdog は実装済みですが elevated
VM/実機検証待ちです。Windows safe mode は Core/ringer/SOS/control/real-PJSIP audio を保持し、custom
visual/animation/H.264 を止め、JPEG source があれば bounded low-resolution MJPEG を使います。modern
iOS は supervised SAM と runtime supervisor に依存し、署名期限も障害として管理します。iOS 5 safe
mode は Core/MiniSIP audio/ringer/SOS/control を保持し、H.264 ingest/decode と custom visual を止め、
設定済みなら bounded low-resolution HTTP(S) MJPEG/snapshot direct playback、無ければ audio-only を
報告します。JPEG は Core に forward しません。local crash/OOM safe mode は 5 分間連続して正常動作
すると解除され、実測 media capability を running process 内で復元します。root helper が safe mode を
通知している間は helper の判断を優先します。optional iOS 5/rooted-Android helper は実装・host test
済みです。iOS 5 lane には launchd を無効のままにする再現可能な staged DEB がありますが、両 platform
とも別 provisioning で実機 qualification は未完了です。root service、UID/socket、maintenance lease、
safe mode、rollback、soak が合格するまで依存しません。
