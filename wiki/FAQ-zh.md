# FAQ —— 常见问题与现实的回答

> 日本語: [FAQ](FAQ) / English: [FAQ-en](FAQ-en)

## 故障・排障

### Q1. 门铃不响。该从哪里查起?

按顺序排查: (1) 在管理界面的仪表盘看门口机、室内机是否**在线**，
有没有时钟同步警告。(2) 事件历史里 press 是否**有记录** ——
有记录说明「按铃已送达，是动作的问题」，没有则是设备/mesh 的问题。
(3) 呼叫规则是否启用、是否匹配目标门、门铃声有没有被 quiet_hours
抑制。(4) 只有电话不响的话，检查 Asterisk 侧（`pjsip show endpoints` /
`pjsip show registrations`）。

### Q2. Home Assistant 宕机会怎样?

**门铃的一切照常运转。** 按铃显示、门铃声、室内对讲、Telegram、电话毫发无损。
失去的只有经 HA 的功能（HomeKit 通知、HA 自动化、go2rtc 影像）。HA 恢复后
MQTT 桥自动重连，并全量重发 discovery 和状态。

### Q3. Asterisk 宕机呢?

对讲、监听走的是不经 Asterisk 的直连 SIP，所以**照常运转**。死掉的只有电话腿
（内线、向手机的呼叫、DTMF 开锁）和网页浏览器通话。→ [架构](Architecture-zh)

### Q4. 停电恢复后需要做什么吗?

原则上不需要。各设备自动启动（替换 shell / Device Owner / SAM），重新加入 mesh，
配置是 CRDT 所以自动一致。NTP 同步完成前，时间依赖功能（时间表、
夜间模式）可能有偏差 —— 请确认仪表盘的「时钟未同步」警告消失。
HGW/Asterisk 恢复较慢时，电话腿的重新注册只能靠 retry（60 秒间隔）。

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
里，配置 CRDT 中没有明文。失窃本身可通过「⚠ 离线」通知（30 秒内）
察觉。

### Q13. 备份怎么做? 最多能加到几台?

管理界面「系统」→ 导出，从任意节点都能导出全量 JSON。不过
日常的生存性由分布式担保 —— 只要 1 台活着配置就能恢复。台数的实际制约
反而是 Asterisk/HGW 的并发通话数（通常 2）和 Ad Hoc 的 UDID 上限（100 台/年）。

## 设备・兼容性

### Q14. iPad 1 (iOS 5) 能做什么?

用 Safari 打开网页面板并做成 Web Clip 的话: `door.html` = 按铃面板（无音频、
仅通知），`monitor.html` = 接铃监视。双向通话 (`call.html`) 需要现代浏览器 +
WebRTC 网关所以不行。把自动锁定设为「无」，常时供电使用。

### Q15. 支持的最低 OS 是?

Windows 7 SP1（需 .NET Framework 4.8 + TLS1.2 补丁 —— provision 会配置）/ Android 5.0
（4.4 走 legacy 通道）/ iOS 12（9 走 legacy）/ 浏览器低至 iOS 5 Safari。
→ [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) 的设备支持表

### Q16. 能用 Apple TV 监视吗?

Apple TV 基本走 HomeKit（家庭 App 的摄像头显示、家居中枢）。tvOS 原生
应用已支持影像显示，SIP 监听未实现 (TODO)。想要全功能的 TV 监视端
请用 Android TV（来铃全屏 + 直接监听 + D-pad 回复）。

### Q17. 想从浏览器通话却用不了麦克风

浏览器的 getUserMedia **仅限 HTTPS 页面**。子机的面板是明文 HTTP，所以要么
架 Caddy 等反向代理 + 内部 CA，要么只给家里固定的设备设置 Chrome 的
insecure-origin 例外。
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. 夜间已把门铃声静音，却和 Asterisk 的夜间分支不一致

quiet_hours 用的是**应用侧的校正后时钟**，dialplan 的 GotoIfTime 用的是 **Asterisk 服务器的
时钟**判定。两边都写夜间设置的话请对齐时刻，并确认 NTP。

### Q19. 按了 SOS 会报警到警察那里吗?

**不会。** 通知对象只有家人（Telegram/全设备警报）以及配置了的用户自定义
电话号码。报警的判断由人来做，这是设计使然。解除需要 kiosk PIN。
→ [住户使用指南](Usage-Residents-zh) / [设计理念](Design-Philosophy-zh)

### Q20. 多个玄关同时按铃会怎样?

瓶颈是 HGW 内线的并发通话数（通常 2）。应用侧由 leader 仲裁把外呼
串行化，必要时也可用 dialplan 的 Queue 控制。宅内侧（门铃声、室内机、
Telegram）则按玄关数并行照常运转。
