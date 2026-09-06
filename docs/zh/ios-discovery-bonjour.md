# iOS 通过 Bonjour 做发现

状态：设计说明，尚未实现。写于 2026-09-06，起因是第一台受沙盒约束的 iOS 节点
（iPhone 17 / iOS 26，免费个人团队签名）加入家庭集群。落地之前，用 host + PIN 手动配对
是受支持的替代方案。

## 问题

mesh 的发现机制是 `239.255.71.71:47171` 上的 UDP 组播信标
（`core/src/mesh/udp_beacon.cpp`）。自 iOS 14 起，App 收发组播必须持有
`com.apple.developer.networking.multicast` 权限。Apple 只向付费开发者计划成员按申请授予，
个人团队拿不到。内核会静默丢包，所以 `IP_ADD_MEMBERSHIP` 成功、Core 也不会记录任何失败：

```
kernel: necp_check_restricted_multicast_drop: Dropping unentitled multicast (SDK 0x1a0500, min 0xc0000)
```

对这样的节点意味着：

- 集群看不见它，它也看不见任何 peer，配对页面永远列不出东西。
- 单播不受影响。`POST /api/pairing/join {host,pin}` 可用，`seed_peers` 会写入
  `boot.json`，之后所有 mesh 链路都是单播 TCP。丢失的只是自动发现。
- 广播（`255.255.255.255`）受同一条规则限制，不是替代方案。

不受影响：iOS 12 壳（规则从 iOS 14 开始）、注入了权限的越狱壳、Windows、Android。

## 决定设计形状的约束

通过系统 API（`NWListener`、`NWBrowser`、`NetService`）使用 Bonjour 是豁免的：组播由
`mDNSResponder` 完成，不是 App 自己。Core 自己开一个原始 mDNS socket 会撞上同样的丢包。因此：

- iOS 上 mDNS 流量必须走平台 API；
- 其他所有平台也必须会说 mDNS，否则 iPhone 广播了没人听、也听不到任何人。

## 设计

1. **发现集合。** `IDiscovery`（`core/src/mesh/transport.h`）已经把信标抽象掉了。新增
   `DiscoverySet : IDiscovery`，把 `start/announce/stop/setPairAnnounce/setPairFound/setPsk`
   扇出到多个后端并合并回调，按 node id 去重。组播信标保留；在被拦的地方它只是不贡献任何东西。
2. **共享信标编解码。** 把 HELLO 与 pair-announce 的编码/校验从 `UdpBeacon` 抽到
   `mesh/beacon_packet.{h,cpp}`。Bonjour 的 TXT 记录承载同一份带 MAC 的 JSON，集群成员身份的
   安全性不变，且只测一次。
3. **服务形状。** 类型 `_doorbell._udp`，实例名 = node id，端口 = mesh 监听端口。TXT：`v=1`，
   以及 base64 后的报文分放在 `p0`、`p1`……（单条 TXT 字符串上限 255 字节；HELLO 约 150 字节，
   pair-announce 可能要两段）。peer 地址取自解析到的 SRV/A 记录；报文自带的 `addr` 仍经 MAC 校验。
4. **平台 SPI。** 在 `db_platform_v2` 末尾追加（字段只增不改）：
   `int (*discovery_advertise)(user, service_type, instance, txt_json)`，`txt_json` 为空表示停止
   发布；`int (*discovery_browse)(user, service_type, on)`。新增 `db_core_discovery_result(core, json)`
   供壳把解析结果 `{"instance","addrs":[…],"port","txt":{…}}` 推回来。Core 用
   `PlatformDiscovery : IDiscovery` 包装。钩子留 `NULL` 的壳就没有 Bonjour 后端。
5. **iOS 壳。** `NWListener(service:)` 发布，`NWBrowser` 浏览并解析，两者都接上面的钩子。
   `Info.plist` 增加 `NSBonjourServices = ["_doorbell._udp"]`（iOS 14+ 没有它浏览会被拒绝）。
   本地网络权限依然需要，首次使用时由系统弹出。
6. **其他所有平台。** Core 内置一个精简 mDNS responder/browser（`mesh/mdns.{h,cpp}`）：为上述
   服务提供 PTR、SRV、TXT、A 记录，三次主动通告后应答 PTR 查询，浏览时每隔几秒发一次 PTR 查询。
   复用 `socket_compat.h` 里的组播工具。Windows、Android、Linux 主机和越狱 iPad 都经 Core 免费获得。
7. **配置。** `discovery.mdns = on|off`，默认 `on`。流量是每节点每个通告周期几个包，与信标相当。

## 安全

HELLO 仍由集群 PSK 加 MAC；pair-announce 按设计仍不做认证，与今天的信标完全一致。TXT 记录局域网内
任何人可读，这和组播信标的暴露面相同。TXT 里永远不会出现任何秘密。

## 推进

1. Core：编解码抽取、`DiscoverySet`、`PlatformDiscovery`、SPI 字段、内存测试。iOS 壳后端。
   用 Mac 上的 host 节点当对端验证。
2. Core mDNS 后端。在家庭局域网验证 Windows ↔ iPhone。
3. Android 与 kiosk 经 Core 自动获得；在硬件上做资格验证。

被否决的替代方案：单播扫网段（慢、吵、大网络下不对）；广播（同样受限）；只依赖组播权限
（需要付费计划加 Apple 审批；面向 App Store 的构建仍值得申请，但对测试包无济于事）。

## 待定

- 未配对时是否发布。信标是发布的（pair-announce），照做。
- App 挂起时 Bonjour 会停止，和壳持有的其他 socket 一样；保活方案不变。
- 私有局域网服务，向 IANA 注册服务类型是可选项。
