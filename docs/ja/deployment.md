# 配備ガイド

[capability matrix](capability-matrix.md) で対象を選び、端末・OS/firmware・media path・enclosure・
signed artifact ごとに commissioning します。compile 成功は実機認証ではありません。

## 1. trusted network と integration

- [ports](network-ports.md) を trusted LAN に制限し、遠隔 access は VPN または認証付き TLS reverse
  proxy を使います。node HTTP/mesh/MiniSIP/MQTT/camera を Internet に直接公開しません。
- Asterisk、MQTT/HA、Telegram、go2rtc/HomeKit は必要なものだけ設定し、停止時も試験します。
- battery/power を点検し、入口機は屋外用の防水・防露・温度管理 enclosure に入れます。

## 2. artifact の build と qualification

- common check と platform release gate を実行し、実 PJSIP、target/arch/min OS/API/dependency/source/
  signing identity を確認します。Android API 19、Windows VM/Toughpad、iOS 9 を未検証のまま認証済みと
  記載しません。iOS 5 は [maintainer runbook](ios-compat-maintainer.md) を使います。

## 3. plaintext secret 無しで pair

app/admin の bounded pairing flow で親 node と追加 node の identity を確認します。Core が先に
`secure_put("mesh.psk", …)` を成功させてから `{t:"paired", psk_ref:"secret:mesh.psk"}` だけを通知し、
shell がその reference と秘密でない bootstrap 項目だけを `boot.json` に保存することを確認します。
`pairing_persistence_error` は not-ready のまま扱います。SIP/MQTT/Telegram/WebRTC/camera credential も secure-
storage 対応 UI/API から入力し、config には `secret:` reference だけを置きます。

Web Push は、予定する各 `web_push` leader candidate の local secure store に、同じ複製済み reference
で VAPID private 値と任意の sender bearer 値を配備します。その後、[config schema](config-schema.md)
の HTTPS sender URL、VAPID public key/subject、secret reference を atomic に保存します。非空の Push
leader と `delivery_backend:true` を status で確認し、`configured:true` だけを readiness と見なしません。
shipping shell は configured endpoint probe がない限り `wan:false` です。各候補から exact HTTPS sender
への egress を実測した後だけ、その node に `caps_override.wan:true` を設定し、試験記録を残して network
変更時に外します。Push leader には `tls12`、`mains_power`、`wall_clock_sane`、`web_push_ready` も必要です。

cluster PSK、password、token、URL userinfo、signing secret を `boot.json`、CRDT JSON、command、log、
文書へコピーしません。旧 `psk_hex` は移行入力専用です。

## 4. role と動作

node name、role、door/building、language、rule と、shell が実測した capability だけを設定します。
camera source は明示し、seed peer から推定しません。iPad 1 は内蔵 mic/speaker 有り、camera 無しなので、
外部 MJPEG/snapshot/RTSP または no-video mode を使用します。bounded RTSP/TCP H.264 ingest と Annex-B
転送は host/loopback 検証済みですが、IDR accept までは runtime degraded で、実 camera hardware
qualification は未完了です。

SOS rule は target/channel/presentation を明示し、dry-run の zero recipient、silent、unsupported/
unavailable、Push subscription/backend warning を確認します。`emergency.web_active_page_alerts` の
選択も記録します。各 Web group で `?group=` が poll/Push の両方を選ぶこと、native-only target が
Web に届かないこと、rule TTL 後も raw-SOS が clear まで残ること、config/export に plaintext Push
endpoint/key がないことを確認します。

## 5. 全 node の commissioning

artifact/signature/runtime status、ring/cancel/purpose/answer/hangup/reply/DTMF/unlock/SOS、重複・期限切れ
event、Core `delivery_result` dispatch evidence と client channel presentation report の区別、
camera/audio/rotation/color/fallback/AEC、integration 停止、network/peer/process/memory/reboot/
power/rollback、kiosk maintenance、thermal/battery、長時間 soak を記録します。iOS root helper は実装・
host test 済みで、launchd を有効化しない再現可能な armv7/iOS 5.1 staged DEB もあります。ただし実機
qualification は未完了です。明示的 opt-in workflow、正確な binary、root-owned launchd、UID/GID/socket
permission、maintenance lease、safe mode、rollback、soak が合格するまで依存しません。

## 6. 運用と復旧

旧 signed artifact と manifest を別 rollback lane に保存します。config export は秘密の実値を含まない
ため secret backup と分離します。[recovery](recovery.md) と [security](security.md) に従います。
