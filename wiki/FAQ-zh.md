# FAQ —— 常见问题与现实的回答

> English: [FAQ](FAQ) / 日本語: [FAQ-ja](FAQ-ja) / 繁體中文 (本頁)

platform 與 hardware 的答案以 [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md) 及 [recovery](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/recovery.md) 為準。

## 故障・排障

### Q1. 门铃不响。该从哪里查起?

按顺序排查: (1) 在管理界面的仪表盘看门口机、室内机是否**在线**，
有没有时钟同步警告。(2) 事件历史里 press 是否**有记录** ——
有记录说明「按铃已送达，是动作的问题」，没有则是设备/mesh 的问题。
(3) 呼叫规则是否启用、是否匹配目标门、门铃声有没有被 quiet_hours
抑制。(4) 只有电话不响的话，检查 Asterisk 侧（`pjsip show endpoints` /
`pjsip show registrations`）。

### Q2. Home Assistant 宕机会怎样?

已實作的 mesh-local path 可以繼續。HA automation、HA/HomeKit 通知及 HA 提供的 media 會停止。
Telegram 和 PBX 也各有依賴項；不要假設全部功能仍正常，請測試實際部署組合。

### Q3. Asterisk 宕机呢?

已配置的 direct SIP 不經 Asterisk；如果實際 artifact 使用 real SIP 且 peer 仍可達，這條 path 可以繼續。
PBX 路由的內線、手機呼叫及 browser WebRTC 會停止。→ [架构](Architecture-zh)

### Q4. 停电恢复后需要做什么吗?

請確認每個 node 都確實重新啟動、加入 mesh、解析 secure-store 引用並回報預期 capability，
再測試按鈴、audio、media 及 integration。依照
[recovery guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/recovery.md) 操作。

### Q5. 从按铃到通知莫名地慢

Telegram/MQTT 只由 leader 发送。leader 刚换人之后可能有数秒空白。
如果一直很慢，检查 leader 是否落在电池供电的弱设备上，给常时供电的设备加上
`caps_override: { "mains_power": true }`，把 leader 资格引过去。

### Q6. 访客语言不回到日语 / 自己变回去了

这是规格: 无操作 `ui.visitor_lang_revert_s` 秒（默认 60）后自动恢复日语，按铃会
延长计时器。不恢复的话，看看是不是持续有按铃或触摸，或者配置值是否
过大。访客选择 `lang=ja` 会立即恢复。

### Q7. 设成了 H.264（流畅影像）却不显示

那台设备可能没有硬编。`codec: auto` 在硬编探测失败时已经降回 MJPEG，
`/stream.mp4` 会返回 503。请把 go2rtc 的 source 行改写为 mjpeg 用
（`#video=h264#hardware`）。另外 `/stream.mp4` 要等订阅者出现后
编码器才启动，首次需要数秒。
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

### Q8. 通话中按了 *1 锁也不开

PSTN→HGW 的腿 DTMF 常常是 inband，依赖机型。先实测 Asterisk 的 DSP 检测
（当前配置）能否拾取，不行就试 rfc4733。
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) 的注意事项

## 运维

### Q9. 有在录像吗?

**没有。** 常时录像在设计边界之外（[设计理念](Design-Philosophy-zh)）。
留下的只有事件时的快照和事件历史。想要录像就在 go2rtc/HA 侧
录 `/stream.mjpeg` 或 `/stream.mp4` —— 系统不会阻碍。

### Q10. Windows Update 怎么办?

门口机的 Windows Update 已被 provision 封锁（弹窗也会被 watchdog 压回去）。
不要放着不管，请在**保养日手动打补丁**（`deploy/provision/windows/provision.cmd` §6）。
这是介于「擅自更新导致玄关变砖」和「永远不打补丁」之间的运维解。

### Q11. iOS 设备的应用突然打不开了

几乎可以肯定是 **Ad Hoc 描述文件的年度失效**。请用 Apple Configurator 重新装入
重签后的 ipa。到期会通过应用内显示和 Telegram 的提前 30 天警告预告。
永久对策是上架 App Store (unlisted)（Phase 7 计划）。
→ [deploy/provision/ios/provision.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md)

### Q12. 设备被偷/丢了。该做什么?

(1) 在管理界面「系统」**重新签发 PSK** → 剩余全部设备重新配对（被偷的设备
将无法进入 mesh）。(2) 轮换 SIP 密码和 Telegram bot token。
(3) 轮换面板 token。另外设备内的秘密保管在 secure store (DPAPI/Keystore/Keychain)
里，配置 CRDT 中没有明文。只有在 rule 選擇 offline 通知且所選 integration 可用時，才會送出提醒。

### Q13. 备份怎么做? 最多能加到几台?

管理界面 export 會保存複製設定，但刻意不包含秘密值。另行備份 artifact manifest/package，
並安排 device-local secret 的恢復方式。容量取決於已 commissioning 的裝置與 integration。

## 设备・兼容性

### Q14. iPad 1 (iOS 5) 能做什么?

有两种方式。

**(A) compatibility native shell**: iPad 1 有內建麥克風與揚聲器，但沒有 camera。shell、MiniSIP、
direct HTTP(S) MJPEG/snapshot、bounded RTSP-over-TCP H.264 與 no-video profile 已實作；audio、recovery
及最終 enclosure 仍須逐裝置 commissioning。H.264 ingest 與 Annex-B 轉送已通過 host/loopback contract；
DESCRIBE/SETUP 與實際 IDR accept 前 capability 維持 degraded，且尚無真實 camera iPad qualification。
另一項 bounded Android→Core fMP4→iPad smoke 已在 foreground renderer 確認 15–16 fps，但 crash 後
unattended foreground video resume 仍未完成。
optional root helper 已實作並通過 host test；iOS 5 lane 有不會啟用 launchd 的可重現 staged DEB，
但 iPad 實機 qualification 尚未完成。
[部署程序](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.zh.md)。

初代 iPad 並非戶外等級。實際 camera、audio、thermal、耐候 enclosure、power、recovery、helper
組合通過硬體 commissioning 前，不得當作 qualified outdoor station。

**(B) 不想越狱 → 传统网页面板（best-effort）**: 用 Safari 打开网页面板并做成 Web Clip:
`door.html` = 按铃面板（无音频、仅通知），`monitor.html` = 接铃监视。双向通话
(`call.html`) 需要现代浏览器 + WebRTC 网关所以不行。无论哪种方式，都把自动锁定设为
「无」，常时供电使用。

### Q15. 支持的最低 OS 是?

build target 不等於 qualification。請看
[capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md)。
尤其 Android API 19 的 production allowlist 目前為空，**supported SKU 是 0 台**；tracked Android job
只是 debug-contract build，不是 release artifact 或 hardware qualification。

### Q16. 能用 Apple TV 监视吗?

Apple TV 沒有 microphone，因此 tvOS 的 product boundary 是 listen-only。目前 tracked evidence 只有
**連結 real PJSIP 的 unsigned Debug arm64 simulator build**，沒有 Release build、signed device artifact、
Apple TV 實際執行或 hardware/audio qualification。現階段不可把 tvOS monitor 當作 release-supported。
HomeKit camera/home hub 屬於另一個 integration。

### Q17. 想从浏览器通话却用不了麦克风

浏览器的 getUserMedia **仅限 HTTPS 页面**。子机的面板是明文 HTTP，所以要么
架 Caddy 等反向代理 + 内部 CA，要么只给家里固定的设备设置 Chrome 的
insecure-origin 例外。
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. 夜间已把门铃声静音，却和 Asterisk 的夜间分支不一致

quiet_hours 用的是**应用侧的校正后时钟**，dialplan 的 GotoIfTime 用的是 **Asterisk 服务器的
时钟**判定。两边都写夜间设置的话请对齐时刻，并确认 NTP。

### Q19. 按了 SOS 会报警到警察那里吗?

**不會。** SOS 不會自動呼叫警察或消防。`emergency_on` 與 `emergency_off` 狀態會複製到所有
Core node，但 recipient 和 presentation 完全由 rule 選擇。可以指定 device、role、Web subscription
group、Telegram、MQTT 或自訂 SIP 目的地，也可以刻意設定零 recipient 或 silent。

對開啟中的 Web page，`emergency.web_active_page_alerts` 預設為 `true`，即使 rule 是零 recipient
或 Push-only，也會渲染 active/clear 狀態。管理員關閉後，Web 仍會處理正向匹配的 `device_alert`
或實際送達的 Push。開啟時，rule TTL 即使停止 custom decoration/sound，安全紅色 overlay 仍保留至
clear。明確 native-only target 不會到 Web；page 保存的 `?group=` 同時選擇 poll/Push delivery。
clear 需要已配置的 PIN/permission。diagnostics 內的 `delivery_result` 只代表
Core 嘗試 dispatch；visual、sound 或 system notification 是否真正呈現，要看 client runtime 的逐 channel report。
→ [住户使用指南](Usage-Residents-zh) / [设计理念](Design-Philosophy-zh)

### Q20. 多个玄关同时按铃会怎样?

瓶颈是 HGW 内线的并发通话数（通常 2）。应用侧由 leader 仲裁把外呼
串行化，必要时也可用 dialplan 的 Queue 控制。mesh-local 與外部 action 仍只由 matching rule
選擇；不要假設每個玄關都必定執行 chime、indoor display 或 Telegram。
