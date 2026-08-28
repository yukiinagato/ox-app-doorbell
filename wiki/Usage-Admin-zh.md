# 管理员指南 —— 管理界面导览与配方集

> 日本語: [Usage-Admin](Usage-Admin) / English: [Usage-Admin-en](Usage-Admin-en)

管理界面在**任意节点上都是一样的**: `http://<任意设备IP>:47180/admin/`。
无论在哪里修改，CRDT 都会毫秒级同步到所有设备。首次访问时的登录
即为管理密码的设置。部署本身的步骤请以
[docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) 为准。

## 13 个标签页的地图

| 标签页 | 是做什么的地方 |
|---|---|
| 仪表盘 | 节点一览（leader / 在线 / 时钟同步）、实时影像、同步状态 |
| 设备 | 每台设备的名称、角色（门口机/室内机/TV）、负责的门、摄像头（codec/分辨率/fps）、动体、显示语言 |
| 门／楼栋 | 登记玄关和楼栋，日英中标签 |
| 呼叫规则 | 「何时・在哪・发生什么・做什么」（按铃/动体/离线 × 时间表 × 动作） |
| 通知对象 | households —— 家人的 Telegram chat_id 和 SIP 内线 |
| 快捷回复 | 编辑预设短语（多语言、朗读、自定义语音、排序） |
| 集成 | MQTT (HA) / Telegram / SIP (Asterisk) / WebRTC / 时区 |
| 事件历史 | press / motion / reply / offline… 的时间线，按类型筛选 |
| 资产 | 上传背景图片、自定义语音，及每个节点的缓存覆盖率 |
| 主题 | 门口机的背景色、背景图片（带预览）、亮度、夜间模式 |
| 文案 | 运行时的文案覆盖 (i18n_overrides) —— 留空则用默认文案 |
| 事由 | 编辑访客的事由按钮（标签、图标、排序） |
| 系统 | 面板 token、签发添加 PIN、配置导出/导入、日志、原始 JSON |

## 常用配方集

### 只对快递自动「放门口」应答（不响电话）

1. 在快捷回复标签页添加 `请放在门口`（需要的话加英/日文。也可加自定义语音）。
2. 在呼叫规则标签页建新规则: 条件 = 呼叫按钮，事由 = 仅快递 (p_delivery)。
3. 动作 = auto_reply（指定刚创建的回复）+ Telegram（用于记录）。不放 SIP 呼叫。
4. 在既有的通用规则那边排除快递，或确认优先顺序，即完成。

### 夜间静音门铃声（保留通知）

在 集成 → 静音时间段 (quiet_hours) 设置时间段（例 23:00–07:00），「要抑制的」里
只放门铃声。SIP / Telegram / HA 保持「始终允许」—— 不漏掉来客。
另外注意 Asterisk 侧的夜间分支（dialplan 的 GotoIfTime）是按**另一只时钟**运转的
（参见 [FAQ](FAQ-zh)）。

### 按设备设置背景

在资产标签页上传图片 (jpeg/png ≤3MB) → 在主题标签页设置全局默认，
想按设备区分时，覆盖设备标签页中对应设备的 local.theme。上传后
各门口机会主动预取，覆盖率齐了之后才会显示（数秒）。

### 文案的换季

在文案标签页把例如 `idle.touch_to_call` 覆盖为「タッチして呼び出してください 🎍」。
保存的瞬间所有门口机都会重绘。清空后即恢复默认文案。
占位符（{name} 等）会在保存时做一致性校验。

### 添加新设备（PIN 步骤）

1. 系统标签页 →「添加设备」→ 签发添加 PIN（**10 分钟有效**）。
2. 在新设备上启动应用，在初始设置画面输入既有节点的 IP 和这个 PIN。
3. PSK 和配置自动分发，加入 mesh。
4. 在设备标签页分配名称、角色、负责的门，即完成。
   各平台的 kiosk 化参见 [Android](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/android/provision.ja.md) /
   [iOS](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md) /
   Windows (`deploy/provision/windows/provision.cmd`)。

### 面板 token 的分发

网页面板 (door/monitor/call.html) 和影像 URL 用 `?k=<token>` 认证。
token 可在系统标签页查看、轮换。**轮换后旧 token 立即失效**，
所以已分发的 Web Clip（iPad 1 等）和 go2rtc 的 URL 也要更新。

## 备份与恢复

- **导出**: 系统标签页 → 导出。在任意节点执行都能导出全量
  （不含 secrets 的实体 —— secure store 是设备本地的）。
- **导入**: 粘贴导出的 JSON，会扁平化后逐项写入。
- 日常的生存性由分布式来担保 —— 只要 1 台活着配置就还在。导出是
  面向「同时失去所有设备」这种灾害的保险。

## 如何打更新

- **Windows**: 分发 GitHub Actions 的 `doorbell-windows` artifact。watchdog 允许
  停止 → 替换 → 重启。
- **Android**: 若是 Device Owner 可以静默安装。
- **iOS**: Ad Hoc 签名**必须每年重签 1 次**。请遵照应用内的到期显示和
  Telegram 的提前 30 天警告（另见 [FAQ](FAQ-zh)）。
- 更新前先在仓库打好标签，回退会更容易。
- Windows Update 已被 provision 封锁 —— 在保养日手动打补丁。

## 安全运维检查清单

- 务必把 kiosk 退出 PIN 从默认值 (000000) 改掉。
- 记下面板 token，出现不再需要的分发对象时就轮换。
- 设备被盗时: 在系统标签页重新签发 PSK → 所有剩余设备重新配对，SIP 密码和
  Telegram bot token 也要轮换（参见 [FAQ](FAQ-zh) 的对应条目）。
