> 日文原文: ../ja/network-ports.md（以日文为准）

# 端口总表

前提是同一 L2（无需在路由器上放行）。但各设备的本地防火墙
（Windows 由 installer 通过 netsh 注册），以及将来划分 VLAN 时，按本表放行。

| 用途 | 协议/端口 | 方向 | 备注 |
|---|---|---|---|
| mesh UDP beacon | UDP 47171 (multicast 239.255.71.71) | 子机⇔子机 | 带 HMAC 的 HELLO。iOS 壳使用 Bonjour |
| mesh TCP (gossip/sync/cmd) | TCP 47172 | 子机⇔子机 | PSK AEAD |
| httpd (admin/panel/MJPEG/snapshot) | TCP 47180 | 浏览器/HA/go2rtc → 子机 | 认证: 管理=密码, panel/stream=?k=token |
| mDNS（将来供 HA 发现用） | UDP 5353 | 子机⇔LAN | Phase 1 起 |
| SIP（Asterisk 注册 — 电话腿用） | UDP 5060 | 子机 → Asterisk | PBX 故障时对讲仍可用（见下行） |
| SIP 直接对讲（站间，无需服务器） | UDP 47190 | 室内机/TV ⇔ 门口机 | X-Doorbell-Mode: answer/monitor，仅限 mesh 成员 IP |
| RTP | UDP 4000-4099 | 子机⇔Asterisk | 在 PJSIP 侧配置固定范围 |
| MQTT | TCP 1883 | leader → HA (Mosquitto) | |
| HTTPS (Telegram) | TCP 443 | leader → api.telegram.org | 经由平台 TLS 栈 |
| NTP | UDP 123 | 子机 → NTP | 防时钟漂移（provision 中配置） |
