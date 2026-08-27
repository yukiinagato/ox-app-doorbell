# ポート総表

同一 L2 前提 (ルータ越え放行は不要)。ただし各端末のローカルファイアウォール
(Windows は installer が netsh で登録) と、将来 VLAN を切る場合はこの表で放行する。

| 用途 | プロトコル/ポート | 方向 | 備考 |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | 子機⇔子機 | HMAC 付き HELLO。iOS 壳は Bonjour 使用 |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | 子機⇔子機 | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | ブラウザ/HA/go2rtc → 子機 | 認証: 管理=パスワード, panel/stream=?k=token |
| mDNS (将来 HA 発見用) | UDP 5353 | 子機⇔LAN | Phase 1 以降 |
| SIP | UDP 5060 | 子機 → Asterisk | |
| RTP | UDP 4000-4099 | 子機⇔Asterisk | PJSIP 側で固定レンジ設定 |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | 平台 TLS 栈経由 |
| NTP | UDP 123 | 子機 → NTP | 時計狂い対策 (provision で設定) |
