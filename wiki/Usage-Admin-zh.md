# 管理员指南 —— 管理界面导览与配方集

> English: [Usage-Admin](Usage-Admin) / 日本語: [Usage-Admin-ja](Usage-Admin-ja) / 繁體中文 (本頁)

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

## 共享的管理员 access

在当前 Admin 或 native settings surface 中设置的 password 会成为 replicated cluster credential，只保存其
salted digest。修改 password 会使执行修改的 node 上的 Admin session 失效。五次失败会触发十分钟 lockout，
但它只在该 node 的 Web login 和 device-side settings entry 间共享。这个 counter 不会复制到其他 node，
因此不是 cluster-wide rate limiter。若从未设置过 password，Core 不会要求 password 才能 clear active SOS。

## 常用配方集

### 发布 announcement、显示 unlock 或暂停事由

door 的 announcement control 用于 door-specific message，global announcement 用于 cluster-wide default；door
message 会优先显示但不会删除 global one。announcement 可设 expiry，preset list 最多可保留八条复用 message。
door unlock control 默认只在其 command（或 SIP DTMF `ha_command`）已配置时显示；若无 action 而被按下，Core
会返回明确 failure，而不会伪装成功。

在事由 tab 关闭一个 purpose，可把它从新的访客选项中移除，同时保留 labels、icon、order、history 和已有的
rule reference。更新滞后的门口机仍可能提交旧 button；该 press 会成为 generic ring，不会因 propagation delay
拒绝访客。

### 选择易读的 fleet theme

可选择 light、dark、system-following 或 scheduled appearance。Core 在 cluster time zone 中解析 scheduled
appearance，并按 semantic region 提供 automatic ink 和 call-button color。background image 令 text 背后的
pixel 因 device 而异时，shell 可在 local 取样；explicit regional override 仍优先。low-contrast color 会保存并
返回 measured WCAG warning，不会被 silent change 或 reject。

### 只对快递自动「放门口」应答（不响电话）

1. 在快捷回复标签页添加 `请放在门口`（需要的话加英/日文。也可加自定义语音）。
2. 在呼叫规则标签页建新规则: 条件 = 呼叫按钮，事由 = 仅快递 (p_delivery)。
3. 动作 = auto_reply（指定刚创建的回复）+ Telegram（用于记录）。不放 SIP 呼叫。
4. 在既有的通用规则那边排除快递，或确认优先顺序，即完成。

### 夜间静音门铃声（保留通知）

在 集成 → 靜音時段 (`quiet_hours`) 設定時間與明確 suppress policy，並逐一測試 optional integration。
Asterisk 的夜間分支使用**另一個時鐘**（見 [FAQ](FAQ-zh)）。

### 設定與 preview SOS 配送

在 `emergency_on` / `emergency_off` rule 設定 `device_alert` target（device ID、role、Web subscription
group）、channel 與 presentation。visual presentation 支援 sound、volume、sticky/TTL、
background/foreground/accent color。dry-run 會依每個 target 的實測 channel support/permission 解析，並警告
零收件者、silent、unavailable/unsupported、rolling-upgrade 未知、沒有 Push subscription 或 backend；警告不阻止保存。

`emergency.web_active_page_alerts` 預設 on，即使規則為零收件者或 Push-only，開啟中的 Web page 仍會
呈現複製的 SOS。off 時正向 matching `device_alert` 或已送達 Push 仍能呈現。Core `delivery_result` 只是
dispatch attempt，client runtime 的逐 channel report 才是實際 presentation。raw path 為 on 時，rule TTL
即使結束 custom decoration/sound，安全的紅色 overlay 仍保留至 SOS clear 或 switch-off。

target 是明確且對稱的：只有 `web_subscription_groups` 時不對 native shell；沒有該 selector 時不對
active Web page/Push subscription。只有完全沒有 `targets` object 的 legacy action 保留全 native node/Web
相容語意。給 Web panel 加上 `?group=guards`，有效 group 會被保存並供 poll/Push enrollment 共用。Core
在 CRDT 內 seal 完整 Push endpoint/key subscription，config/export 不含 plaintext；fail-closed 的舊 record
遷移後可能需要重新 enrollment。

### 按设备设置背景

在资产标签页上传图片 (jpeg/png ≤3MB) → 在主题标签页设置全局默认，
想按设备区分时，覆盖设备标签页中对应设备的 local.theme。上传后
各门口机会主动预取，覆盖率齐了之后才会显示（数秒）。

### 調整每裝置 semantic control

使用 manifest-driven editor 編輯允許的 size/color property。native `ui_manifest` 與 local
`web_ui.manifest` 是不同 contract。Core 會永久 cache 最後有效的 native peer manifest/capability，因此
status 顯示 `cached_contract:true` 的 configured offline device 可依 cached contract 保存；這不代表 offline
renderer 已套用。remote Web manifest 沒有 catalog，只有目前 Core node 配信的 Web UI 可編輯。最終成功
須看 renderer apply report。

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

Admin 只發出一次 panel credential。將它放在 launch URL fragment `#k=<credential>`，page 經
`POST /api/panel/session` 交換後使用 HttpOnly cookie。不要把 credential 放進 query、stream URL、log 或
config。rotate 會立即使舊 credential 失效，因此要重新發出受影響的 Web Clip/session。

## 备份与恢复

- **导出**: 系统标签页 → 导出。在任意节点执行都能导出全量
  （不含 secrets 的实体 —— secure store 是设备本地的）。
- **导入**: 驗證完整 JSON，使用一次 atomic `/api/config/batch` 保存。endpoint 不存在時會失敗，
  不 fallback 到 sequential partial write。
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

- commissioning 前設定唯一 kiosk exit PIN，不保留或記錄共用 factory 值。
- 记下面板 token，出现不再需要的分发对象时就轮换。
- 设备被盗时: 在系统标签页重新签发 PSK → 所有剩余设备重新配对，SIP 密码和
  Telegram bot token 也要轮换（参见 [FAQ](FAQ-zh) 的对应条目）。
