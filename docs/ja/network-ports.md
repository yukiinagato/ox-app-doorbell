# ポート総表

同一 L2 前提 (ルータ越しの開放は不要)。ただし各端末のローカルファイアウォール
(Windows は installer が netsh で登録) と、将来 VLAN を切る場合はこの表に従って開放する。

| 用途 | プロトコル/ポート | 方向 | 備考 |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | 子機⇔子機 | HMAC 付き HELLO。iOS アプリは Bonjour 使用 |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | 子機⇔子機 | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | ブラウザ/HA/go2rtc → 子機 | 認証: 管理=パスワード, panel/stream=?k=token |
| mDNS (将来 HA 発見用) | UDP 5353 | 子機⇔LAN | Phase 1 以降 |
| SIP (Asterisk 登録 — 電話レッグ用) | UDP 5060 | 子機 → Asterisk | PBX 障害時も通話は生きる (下の行) |
| SIP 直接通話 (端末間, サーバ不要) | UDP 47190 | 室内機/TV ⇔ 門口機 | X-Doorbell-Mode: answer/monitor, mesh メンバーの IP に限定 |
| RTP | UDP 4000-4099 | 子機⇔Asterisk | PJSIP 側で固定レンジ設定 |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | プラットフォームの TLS スタック経由 |
| NTP | UDP 123 | 子機 → NTP | 時計狂い対策 (provision で設定) |
