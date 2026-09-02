# セキュリティ運用

本システムの境界は信頼済み宅内 LAN です。Internet に直接公開せず、遠隔利用は保守された VPN
または認証付き TLS reverse proxy の背後に置きます。ポートは [network ports](network-ports.md)
を参照してください。

## 秘密情報の契約

- plaintext credential を CRDT、event、log、URL、diagnostics、export、`boot.json` に保存しません。
- 通常の secret-bearing 設定には `psk_ref: "secret:mesh.psk"`、SIP/MQTT の `pass_ref`、Telegram の
  `bot_token_ref`、WebRTC の `sip_pass_ref`、media source の `secret_ref` だけを置きます。不可分な
  sealed Web Push subscription の例外は下記に示します。
- 実値は `db_platform_v2.secure_put`/`secure_get` を通し、Windows は DPAPI、Android は secure storage、
  iOS は Keychain に保存します。新規 pairing では Core が先に `secure_put("mesh.psk", …)` を成功させ、
  shell には `{t:"paired", psk_ref:"secret:mesh.psk"}` だけを通知し、`psk_hex` を渡しません。
- secure store に失敗すると Core は `pairing_persistence_error` を通知し `paired` を通知しません。client は
  not-ready のままにします。`psk_hex` や旧 plaintext password/token は移行入力専用です。
- media URL に userinfo を入れません。`media_sources.<id>.secret_ref` を明示し、seed peer から
  camera URL を推定しません。

設定 export は秘密の実値を含みません。復旧時は設定と各端末の秘密を別々に戻します。
MQTT/Telegram の ref は fleet config として複製されますが、実値は複製されません。初回保存や rotation
の後、その integration の leader 候補となる全 node で Admin の「このノードに配備」を使い、現在の ref
へ同じ実値を保存します。全候補が backend ready を報告するまで failover 完了とは扱いません。
SIP password は target device 自身の Admin でだけ入力します。remote row は非 secret の account metadata
だけを変更でき、別 device の secure store に password を誤保存しません。

panel の ref と非 secret の credential generation は複製されますが、token 実値は複製されません。
rotation は ref と generation を原子的に置換し、両方に紐付いた panel session は、その設定を受信した
全 node で拒否されます。一度だけ表示される rotation 値を承認済みの経路で渡し、Web panel を配信する
各 node で **このノードに配備** を実行します。配備は現在参照中の panel secret だけを local secure
store に書き、local panel session を無効化します。fleet 設定の変更や secret 値の返却は行いません。

Web Push subscription の bearer-like endpoint と `p256dh`/`auth` は 1 つの complete value として
normalize/seal します。schema-v2 CRDT record は mesh PSK から導出した key と
XChaCha20-Poly1305 を使い、materialized config、diagnostics、export に plaintext を出しません。
subscription operation/provider delivery に必要な時だけ bounded memory で open し、delete は送信された
exact endpoint から record key を導出します。起動時、legacy raw record は可能なら再 seal し、失敗時は
fail-closed で削除します。削除された subscription は browser から再登録が必要です。秘密でない
group/page metadata は ciphertext の外に保存します。検証済み `?group=<name>` を local に保持し、state
poll と Push enrollment に共用します。

mesh PSK を rotate すると、旧 PSK で seal された record は意図的に open できなくなります。PSK
rotation / re-pair 後は、登録済み browser/profile をすべて開き、必要な group ごとに Push を再有効化し、
実 Push を確認してから復旧扱いにします。`configured` や backend-ready だけでは closed browser の
再登録を証明できません。

## access と transport 境界

mesh は cluster PSK で認証・暗号化します。47180 の Admin/panel route は各 session を使いますが、
native client、HA、go2rtc 互換の `/stream.mjpeg`、`/stream.mp4`、`/snapshot.jpg`、`/video-meta` と
exact `GET /asset/<64-lowercase-hex-sha256>` と `/peer-frame.jpg` は意図的に session なしで LAN から読み取れます。それ以外の
`/asset` method、malformed hash、suffix path は認証対象または reject のままです。47180 全体を trusted media LAN に限定するか、
認証付き TLS reverse proxy の背後に置きます。panel cookie は video authorization ではありません。
panel token を秘密として扱い、配布先や端末を外した時に回転し、token 付き URL を log や公開設定へ
載せません。legacy iOS の MiniSIP は LAN 専用 UDP/PCMU で TLS/SRTP はありません。
越獄端末は隔離した LAN に置き、operator が固有の host access credential を設定します。

optional root helper は fixed filesystem Unix socket だけを公開し、TCP、shell、arbitrary argv、reboot
operation はありません。Android は stream `SO_PEERCRED` と heartbeat PID ownership、legacy Apple は
root-owned socket permission と heartbeat PID ownership を検証します。mode/status/safe-mode marker は
symlink check 後に原子的に置換し、親 directory は root-owned にします。設定 `helper_mode` から
availability を推定しません。

## rotation と incident checklist

盗難・漏えい時は端末を隔離し、mesh PSK を再発行して残存端末を再 pair し、SIP/MQTT/Telegram/
WebRTC/media/admin/panel の credential と token を回転します。secure store を先に更新し、旧値で
接続不能なこと、backup/log に実値が無いことを確認します。

Apple SDK、署名 material、provisioning profile、private key、secure-store export、生成 binary、
実環境の address/credential を commit しません。
