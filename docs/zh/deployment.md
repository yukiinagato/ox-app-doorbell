> 日文原文: ../ja/deployment.md（以日文为准）

# 部署步骤（实宅上线检查清单）

按顺序推进，即可把所有设备接入现有的 HA / Asterisk / 光电话（ひかり電話）环境。
各节的细节见括号内标注的文档。

## 0. 事前准备

- [ ] HA 主机（x86 iGPU 或 RPi4+）上已运行 Mosquitto 插件 + go2rtc
- [ ] 已将 `deploy/asterisk/pjsip.conf` / `extensions.conf` 导入 Asterisk
      （改写 `CHANGE_ME_*` 和手机号码，配置光电话 HGW 的内线号码）— 步骤见
      `deploy/asterisk/README.zh.md`
- [ ] Telegram bot（@ox_doorbell_bot）的 token 和家人的 chat_id 清单
- [ ] 检查各设备电池（是否鼓包）。可行的话拆掉电池改为直连供电

## 1. 第一台设备（管理的起点）

任意平台均可，但常供电的门口机（推荐 Toughpad）最合适。

- [ ] Windows: 解压 GitHub Actions 的 `doorbell-windows` artifact →
      运行 `deploy/provision/windows/provision.cmd`（管理员）→ 在 kiosk 用户下执行
      `kiosk-enable.cmd` → 重新登录（详情: `docs/zh/win-build-env.md` §实机）
- [ ] 首次启动会生成 `%ProgramData%\Doorbell\boot.json` — 编辑 `name` / `role` /
      `door` / `psk_hex`（自行生成 64 位 hex）/ `seed_peers` 后重启
- [ ] 浏览器打开 `http://<设备IP>:47180/admin/` → 首次登录 = 设置管理密码
- [ ] **安全初始化**: 修改 kiosk 退出 PIN（`exit_pin.txt`，默认 000000），
      在「系统」标签页记下面板 token

## 2. 配置骨架（在管理页面）

- [ ] 门／建筑: 注册各玄关（d_front 等）与楼栋，配日英中标签
- [ ] 集成: MQTT（HA 的 Mosquitto）、Telegram（token + 打开 poll_updates）、SIP
      （Asterisk IP + 各设备的内线/密码）、tz
- [ ] 通知对象: 在 households 填家人的 chat_id / 内线
- [ ] 呼叫规则: 按铃 → SIP 600 + Telegram + 门铃声。也可按喜好设置例如仅快递
      （p_delivery）时 auto_reply「放门口」+ 不打电话
- [ ] 调整主题 / 文案 / 事由 / 快捷回复 / 资产（背景图片、自定义语音）

## 3. 添加设备（任意台数）

- [ ] 管理页面「系统」→「添加设备」签发 PIN（10 分钟有效）
- [ ] 在新设备上启动 App → 初始设置中输入 已有节点 IP + PIN → PSK/配置自动分发
      （也可直接把 psk_hex/seed_peers 写进 boot.json）
- [ ] 在设备标签页分配名称、负责的门、角色（door_station / indoor_panel / TV）
- Android: `deploy/provision/android/provision.zh.md`（Device Owner 化 = 完全 kiosk，含 TV 一节）
- iOS: `deploy/provision/ios/provision.zh.md`（受监督 + Single App Mode、Ad Hoc 签名与逐年更新）
- iPad 1 等 legacy 设备: 用 Safari 把 `http://<任意节点>:47180/panel/door?k=<token>`
  存为 Web 快捷方式（`monitor` 同理）。自动锁定设为「无」
- 若要把 iPad 1 (A1219, iOS5.1.1) 越狱成原生节点，请参见
  `deploy/provision/ios/ipad1-jailbreak.md`（完整 core・音频・开锁，接外麦还能对讲）

## 4. HA / HomeKit

- [ ] 连上 Mosquitto 后，实体会自动出现在 HA（门铃 event / 移动侦测 /
      设备在线 / 紧急 / 访客语言 sensor）
- [ ] 按各门口机的 IP 修改并导入 `deploy/ha/go2rtc.yaml`
      （codec=h264 的设备用 `#video=copy` — 无需转码）
- [ ] 导入 `deploy/ha/configuration-snippets.yaml` 中的 HomeKit Bridge / 看门狗 /
      actionable 通知 / 开锁 automation，把 entity_id 改成实际值
- [ ] 确认 iPhone 家庭 App 能收到门铃通知+直播。想在外面观看需
      Apple TV / HomePod 作为家庭中枢

## 5. 功能验证（每次添加设备后）

- [ ] 按铃 → 内线+手机响铃 / Telegram 照片+按钮 / HA 通知 / 室内门铃声
- [ ] 在 Telegram 点按钮回复 → 门口机大字显示+朗读
- [ ] 从室内机点「应答」→ 电话腿被切断并进入双向通话（含视频）
- [ ] 通话中从手机按 *1 → HA 的锁打开
- [ ] 拔掉设备网线 → 30 秒内向 Telegram/HA 发离线通知
- [ ] **停掉 HA 和 Asterisk 后**: 按铃显示、门铃声、室内对讲、面板仍持续工作

## 6. 运维

- 更新: 分发 GitHub Actions 的 artifact（Windows 由 watchdog 容许 停止→替换→重启。
  Android 用 DO 静默安装）。更新前打 tag，便于回退
- iOS Ad Hoc 签名**每年必须重新签名一次** — 遵循 App 内的到期显示和 Telegram 的
  提前 30 天警告（永久化 = 上架 App Store，计划为 Phase 7）
- 配置备份: 管理页面「系统」→ 导出（任一节点都能导出全量）
- 设备被盗时: 在管理页面重新签发 PSK → 所有设备重新配对，轮换 SIP 密码和 bot token
- Windows Update 已封锁 — 在维护日手动应用（参见 `provision.cmd` §6）
