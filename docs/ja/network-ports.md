# ポート総表

同一 L2 前提 (ルータ越しの開放は不要)。ただし各端末のローカルファイアウォール
(Windows は installer が netsh で登録) と、将来 VLAN を切る場合はこの表に従って開放する。

記載した trusted-LAN endpoint 間だけに許可し、Internet から port forward しません。panel token や
admin password は application 認可であり LAN HTTP を public transport-security 境界にはしません。
[security](security.md) を参照してください。

| 用途 | プロトコル/ポート | 方向 | 備考 |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | 子機⇔子機 | HMAC 付き HELLO。multicast 不可なら seed peer を明示 |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | 子機⇔子機 | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | ブラウザ/HA/go2rtc → 子機 | Admin/panel route は session を使用。LAN 互換 media route (`/stream.mjpeg`, `/stream.mp4`, `/snapshot.jpg`, `/video-meta`, `/peer-frame.jpg`) と exact `GET /asset/<64-lowercase-hex-sha256>` は未認証のため、port 全体を trusted media LAN または認証付き TLS proxy に限定 |
| mDNS | UDP 5353 | 子機⇔LAN | 任意 discovery。明示 seed peer には不要 |
| SIP (Asterisk 登録 — 電話レッグ用) | UDP 5060 | 子機 → Asterisk | PBX 障害時も通話は生きる (下の行) |
| SIP 直接通話 (端末間, サーバ不要) | UDP 47190 | 室内機/TV ⇔ 門口機 | X-Doorbell-Mode: answer/monitor, mesh メンバーの IP に限定 |
| RTP | UDP 4000-4099 | 子機⇔Asterisk | PJSIP 側で固定レンジ設定 |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | プラットフォームの TLS スタック経由 |
| NTP | UDP 123 | 子機 → NTP | 時計狂い対策 (provision で設定) |
