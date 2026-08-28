# 设计理念 —— 为什么是这样一台门铃

> 日本語: [Design-Philosophy](Design-Philosophy) / English: [Design-Philosophy-en](Design-Philosophy-en)

这个项目不是「替换市售门铃」，而是被设计为**家这套基础设施的一部分**。
根底里有几条信念，请按顺序当作故事来读。

## 1. 不把性命托付给服务器 —— 无服务器自愈

普通的智能门铃，一旦集线器、云端、或者 Home Assistant 这样的
「中心」死掉，立刻变成一块废板。这里我们把真实源放在 **P2P mesh** 上。
所有设备对等地 gossip，配置和事件都被复制到所有节点。

- Home Assistant 宕机: 按铃显示、门铃声、室内对讲、面板照常运转。
- Asterisk (PBX) 宕机: 对讲走的是不经 Asterisk 的直连 SIP (UDP 47190)，所以还活着。
  死掉的只有「向电话呼出」这一条腿。
- 只要剩下 1 台设备: 配置可以从那里全量恢复。备份当然有比没有好，
  但日常的生存性并不依赖备份。

只有对外部的通知 (Telegram / MQTT) 为了避免重复，由「leader」节点代表发送，
但 leader 由确定性算法自动选出，倒下了就由别的节点接任。

## 2. 不抛弃旧设备 —— 降级的阶梯

放在玄关的设备不需要最新机型。倒不如说「沉睡在抽屉里的设备」才是合适的材料。
这套系统有意保持着一条很长的降级阶梯。

- Windows: WPF + .NET Framework 4.8 —— 一直到 **Windows 7 SP1 的 Toughpad** 都能跑。
- Android: minSdk 21 (Android 5.0)。面向 4.4 有 legacy 通道。
- iOS: iOS 12 及以上（面向 9 有 legacy）。报废的 iPhone/iPad 可以变成门口机、室内机。
- 再往下: **iPad 1 (A1219, iOS 5.1.1)** 也能成为一等节点。把它越狱并装上自行构建的原生 app，
  它就是搭载完整 C++ 核心的网格节点 —— 可以查看门口视频、听声音、快捷回复、开锁（接外麦还能对讲）。
  唯一的上限是物理性的: 没有摄像头，所以无法发送自己的视频；没有内置麦克风，所以不接外麦时仅收听
  ([ipad1-jailbreak](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.md))。
  如果不想越狱，传统方式依然保留: 把网页面板 (door.html / monitor.html) 做成 Web Clip，
  当按铃和接铃监视器用。
- 影像也是同一思想: 基调是「到哪儿都能显示」的 MJPEG。H.264 是只有支持的设备才用的上位档，
  不支持的设备只是默默降回 MJPEG（参见[决策记录](Decisions-zh)）。

## 3. 各平台原生 —— 没有选 Electron

在低配旧设备上 Electron/Web 包壳太重，而且够不到摄像头、音频、kiosk、电源控制这类
OS 深层的功能。于是采用了**共享 C++ 核心 (doorbell-core) + 各平台的薄原生外壳**
（WPF / Android / Swift）的构成。逻辑只有 1 处，只有 UI 和 OS 集成按平台分开。
外壳只看 [core/include/doorbell/doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
的 C ABI。

## 4. 电话网这一最强冗余

停电了也照常运转的网络，其实家里早就有 —— 电话网。
组合 Asterisk + 光纤电话 HGW，按铃时**让宅内内线和外出手机 (PSTN) 同时**
振铃。即使在手机应用 push 到不了的环境，电话也会响。通话中还可以用
DTMF（*1 等）执行开锁等操作。这不是「在智能家居之上叠一个电话」，
而是「把电话网当作最后堡垒纳入设计」的思路。

## 5. 「宁重勿漏」—— 与其漏掉，不如重复通知

漏掉一次来客的代价，远大于通知响两次的烦扰。按铃 1 次，
SIP 呼叫、Telegram、HA 事件、室内门铃声会**并行**执行。想安静的时间段可以用
quiet_hours 只抑制门铃声，但默认情况下电话、Telegram、HA 是
`never_suppress` —— 即使半夜，来客和紧急事件也必定送达。

## 6. 安全边界 —— 不自动呼叫警察、消防

室内机的 SOS（长按报警）通过全节点警报 + 警笛 + Telegram 🚨 + MQTT
**通知家人**。但是我们有意没有实现向警察、消防的自动呼叫。
理由是误报的代价，以及机器无法做出情境判断。报警的判断永远由人来做，
系统专注于以最快速度送达为此所需的信息
（影像、通知、向任意用户自定义号码的 SIP 呼叫）。

## 7. 秘密的存放处，与明文 LAN 这一取舍

- bot token、SIP 密码等秘密**不会以明文放进**配置 CRDT。
  只复制 `secret:` 引用，实体保管在各设备的 secure store
  (DPAPI / Keystore / Keychain) 中。在管理界面也是只能写入、无法查看。
- 另一方面，宅内 LAN 的 HTTP/影像流是明文的。这是基于「同一 L2 的家庭内网络」
  这一前提的现实取舍 —— mesh 本身由 PSK 的 HMAC/AEAD 保护，
  管理界面有密码、面板/流媒体有 token 守护，而 TLS 化则作为
  想架设反向代理（Caddy 等）的人的选项保留着
  （参见 [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)）。

## 8. 不录像

这套系统是门铃，不是监控摄像头。不做常时录像，只处理事件时的
快照和需要的人观看的实时影像。想要录像的话，
在 go2rtc/HA 那边随意录就好 —— 只是被放在了边界之外而已。

---

下一步: 功能全貌见[功能总览](Features-zh)，实现内幕见[架构](Architecture-zh)，
各项设计判断的来龙去脉见[决策记录](Decisions-zh)。
