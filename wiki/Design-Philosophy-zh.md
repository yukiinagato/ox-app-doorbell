# 设计理念 —— 为什么是这样一台门铃

> English: [Design-Philosophy](Design-Philosophy) / 日本語: [Design-Philosophy-ja](Design-Philosophy-ja) / 繁體中文 (本頁)

設計目標與目前 release 狀態不同；目前狀態以 [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md) 為準。

这个项目不是「替换市售门铃」，而是被设计为**家这套基础设施的一部分**。
根底里有几条信念，请按顺序当作故事来读。

## 1. 不把性命托付给服务器 —— 无服务器自愈

mesh state 的真實來源位於 P2P mesh。native Core node 會 gossip 並複製 configuration/event；
optional integration 各自是獨立的 failure boundary。

- Home Assistant 宕機時，已實作的 mesh-local action 可以繼續，但 HA、HomeKit 與 HA-hosted media
  action 不會繼續。
- Asterisk 宕機時，commissioning 完成的 direct-SIP path 可以繼續，但 PBX/PSTN/WebRTC path 會停止。
- 尚存且健康的 native node 有助於恢復複製設定；backup 與 device-local secret 的恢復方式仍然必要。

只有对外部的通知 (Telegram / MQTT) 为了避免重复，由「leader」节点代表发送，
但 leader 由确定性算法自动选出，倒下了就由别的节点接任。

## 2. 不抛弃旧设备 —— 降级的阶梯

放在玄关的设备不需要最新机型。倒不如说「沉睡在抽屉里的设备」才是合适的材料。
这套系统有意保持着一条很长的降级阶梯。

- Windows: WPF + .NET Framework 4.8 —— 一直到 **Windows 7 SP1 的 Toughpad** 都能跑。
- Android: minSdk 21 (Android 5.0)。4.4 的 API 19 legacy path 已存在，但 production SKU allowlist
  目前為空；tracked debug-contract build 不代表 release 或 hardware qualification。
- iOS: iOS 12 及以上（面向 9 有 legacy）。报废的 iPhone/iPad 可以变成门口机、室内机。
- **iPad 1 (A1219/A1337, iOS 5.1.1)** 有 compatibility shell。它有內建麥克風與揚聲器，
  但沒有 camera，也不是戶外等級。audio、外部 MJPEG/snapshot/no-video、recovery、thermal/耐候
  enclosure 與 power 都要實機
  commissioning。bounded RTSP/RTP-over-TCP H.264 與 Annex-B path 已通過 host/loopback test，涵蓋
  SDP/sprop、single NAL/STAP-A/FU-A 與 next-IDR recovery；實際 IDR accept 前保持 degraded，且尚無
  真實 camera iPad qualification。optional root helper 也已實作並通過 host test，但仍需實機 commissioning
  ([部署程序](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.zh.md))。
- 影像也是同一思想: 基调是「到哪儿都能显示」的 MJPEG。H.264 是只有支持的设备才用的上位档，
  不支持的设备只是默默降回 MJPEG（参见[决策记录](Decisions-zh)）。

## 3. 各平台原生 —— 没有选 Electron

在低配旧设备上 Electron/Web 包壳太重，而且够不到摄像头、音频、kiosk、电源控制这类
OS 深层的功能。于是采用了**共享 C++ 核心 (doorbell-core) + 各平台的薄原生外壳**
（WPF / Android / Swift）的构成。逻辑只有 1 处，只有 UI 和 OS 集成按平台分开。
外壳只看 [core/include/doorbell/doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
的 C ABI。

## 4. 电话网这一最强冗余

在 app push 不可用時仍可能可用的電話網，其實家中早已存在。若 Asterisk/光纖電話 HGW path 已
commissioning 且 matching rule 選中，按鈴可以並行呼叫宅內內線與外出手機 (PSTN)。通話中可用
已配置的 DTMF code 執行開鎖等操作。這不是「在智能家居之上疊一個電話」，而是把獨立測試的
電話 path 納入另一道防線。

## 5. 「宁重勿漏」—— 与其漏掉，不如重复通知

漏掉一次來客的代價遠大於通知重複的打擾，因此 rule engine 可並行 dispatch 獨立的 SIP、
Telegram、HA 與 chime action。不過這些 action 始終是 rule-driven；管理員可以縮小 recipient、
讓 channel 靜音或完全移除 action。`quiet_hours` 只是可用 condition 之一，不保證其他 channel 都會執行。

## 6. 安全边界 —— 不自动呼叫警察、消防

SOS active/clear 狀態始終複製到所有 Core node，並在重新連線後恢復。各 device 顯示或播放什麼，
以及是否使用 Web Push、Telegram、MQTT 或自訂 SIP 目的地，全部由 rule 決定；管理員可以刻意設為
零 recipient 或 silent presentation。由於誤報風險及需要人類判斷，系統不會自動呼叫警察或消防。

開啟中的 Web page 有獨立安全 switch。`emergency.web_active_page_alerts` 預設為 `true`，因此即使
rule 是零 recipient 或 Push-only，也會渲染複製的 SOS active/clear 狀態。關閉 switch 不會阻擋正向
匹配的 `device_alert` 或實際送達的 Push。運維上，Core 的 `delivery_result` 只證明 dispatch attempt；
client runtime 的逐 channel report 才能證明 presentation。

raw-state path 開啟期間，rule TTL 可停止 custom sound/decoration，但 SOS active 時的安全紅色 overlay
只能由 clear 或 switch-off 消除。明確 target 不跨 surface 洩漏：native-only selector 不對 Web，
Web-only group 不對 native shell；只有沒有 `targets` 的 legacy action 保留 all-target compatibility。
Web page 用同一個保存的 `?group=` 做 poll/Push。

## 7. 秘密存放位置與 trusted-LAN 邊界

- bot token、SIP 密码等秘密**不会以明文放进**配置 CRDT。
  只复制 `secret:` 引用，实体保管在各设备的 secure store
  (DPAPI / Keystore / Keychain) 中。在管理界面也是只能写入、无法查看。
- Push subscription 必須保持完整 opaque value，因此 endpoint 與 `p256dh`/`auth` key 會用
  mesh-PSK-derived key 和 XChaCha20-Poly1305 一起 seal 成 schema-v2 CRDT record。config/export 不含
  plaintext；啟動時重新 seal 舊 raw record，否則 fail-closed 刪除。
- node HTTP/video 是 trusted LAN interface，不是 Internet security 邊界。不可公開到 Internet；使用
  維護良好的 VPN 或有驗證的 TLS reverse proxy。panel URL/token 應視為秘密，不得放入 log 或公開
  config（參見 [security](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/security.md)）。

## 8. 不录像

这套系统是门铃，不是监控摄像头。不做常时录像，只处理事件时的
快照和需要的人观看的实时影像。想要录像的话，
在 go2rtc/HA 那边随意录就好 —— 只是被放在了边界之外而已。

---

下一步: 功能全貌见[功能总览](Features-zh)，实现内幕见[架构](Architecture-zh)，
各项设计判断的来龙去脉见[决策记录](Decisions-zh)。
