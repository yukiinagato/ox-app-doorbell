# iOS 子机的部署（受监督 SAM kiosk / Ad Hoc 分发）+ tvOS 监视端

对象: `ios/` 的 iOS App（`jp.ox.doorbell` — 门口机/室内机两用）与
tvOS App（`jp.ox.doorbell.tv` — 监视端）。把 iOS 12 及以上的废旧 iPhone/iPad
转用为门口机、室内机。相当于 Android 版 `deploy/provision/android/provision.zh.md`。

## 0. 构建与签名的全貌

- 构建: `xcodebuild -project ios/Doorbell.xcodeproj -scheme Doorbell -sdk iphoneos`
  （需要 Apple Developer Program 的团队设置 — 在 Xcode 的 Signing & Capabilities
  选择 Team 即可。CI 用 `-allowProvisioningUpdates` 或手动 profile）。
  core (C++) 由 run-script 用 CMake 自动构建 — 开发机上只需要 `cmake` 和 `python3`。
  先用 `tools/build_pjsip_ios.sh` 建立符合 lane 的 PJSIP artifact。SIP stub build 僅供
  development/display，不得作為通話 release 發佈。
- 分发用 **Ad Hoc**（面向家庭内少量设备）:
  1. 在 Apple Developer 注册各设备的 UDID（上限 100 台/年）。
  2. Xcode → Product → Archive → Distribute App → **Ad Hoc** → 导出 ipa。
  3. 用 Apple Configurator（设备 USB 连到 Mac）安装 ipa。
- **注意证书有效期**: Ad Hoc 的 provisioning profile **1 年失效**，
  失效后 App 无法启动。**每年必须重新签名、重新安装一次** —
  强烈建议在日历里登记提醒（失效日可在 Xcode 的 Organizer 或
  developer.apple.com 的 Profiles 查看）。想把长期运维夯实，可迁移到
  App Store 分发（unlisted app）或 Apple Business Manager + 自定 App 分发。
- 无开发者账号的验证可以用「免费团队 + 7 天有效期的签名」（每周都要重签 —
  不适合常设运行）。

## 1. 事前准备（设备侧）

1. 将设备**抹掉**（设置 → 通用 → 传输或还原）。**监督 (supervised) 化需要
   抹掉设备** — 用 Apple Configurator「准备」设备时会被清除。
2. 初始设置交给 Apple Configurator 的「准备」向导
   （跳过 Apple ID 登录）。
3. 把 Wi-Fi 接入宅内 LAN（mesh 前提是同一网段 — docs/zh/network-ports.md）。
4. 设置 → 显示与亮度 → **自动锁定 = 永不**（仅受监督设备可选）。
   App 侧也会用 `isIdleTimerDisabled` 防止熄屏，双重保险。

## 2. 监督化 + SAM（Single App Mode）— kiosk 加固

iOS 上相当于 Android Device Owner 的常驻 kiosk 化，使用
**受监督设备的 Single App Mode**（引导式访问可被手动解除，只作应急用）。

在 Apple Configurator（Mac App Store 免费）中:

1. USB 连接设备 →「准备」→ 选择监督（创建组织，保存好监督身份证书 —
   之后修改设置都需要它）。
2. 「添加」App（Ad Hoc ipa）→ 从 App 安装。
3. **Single App Mode**: 「操作」→「高级」→「开始单 App 模式」→ 选 Doorbell。
   此后即使重启也只能运行这个 App（主屏/通知中心/控制中心
   全部封锁）。解除也要在 Configurator 上做（需要物理接触 + 监督证书 = 防盗）。
4. 推荐的附加 profile（Configurator → 创建描述文件）:
   - 推迟软件更新（门口机不会自己掉进更新画面）
   - 免除密码（来铃画面不被锁屏挡住 — SAM 中本来就不会落到锁屏）

App 內的隱藏管理員入口（右上連點 7 次 → PIN 數字鍵盤）在 SAM 中也可用。啟用 SAM 前須透過
核准維護路徑設定唯一 PIN hash，不得以共用值或 factory 值部署。
PIN 通过后显示维护信息（node id / peers / data dir）并临时放开自动熄屏。
kiosk 本身的解除因 SAM 的性质只能在 Configurator 上做。

## 3. 放置 boot.json

首次启动会在 `Documents/boot.json` 生成默认值。Core 启动前必须选择 **门口机** 或 **室内机**。旧 profile 若没有明确的 `setup_complete:true`，也会显示一次确认页面。
门口机还必须设置 door ID，界面会预填可直接确认的随机 `door-xxxxxxxx`；保存的 role 非法或门口机 ID
丢失时会再次显示。室内机不保存 door assignment。生成 profile 后可用以下任一方式编辑：

- **Finder / Apple Configurator 的文件共享**: 目前 App 未开放 File Sharing，
  基本靠管理 webui 投放（见下）。
- **管理 webui**: 在已入 mesh 的其他节点打开 `http://<ip>:47180/admin/` → 设备 →
  用加入 PIN 把本设备接进来。
- 不得手寫 PSK。pair 後不含秘密的持久格式如下：

```json
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_ref": "secret:mesh.psk",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
```

Core 先將 `mesh.psk` 寫入 Keychain，再只向 shell 發出
`{t:"paired", psk_ref:"secret:mesh.psk"}`，不傳送新的 `psk_hex`。
`pairing_persistence_error` 必須維持 not-ready。不得把 PSK、SIP password、token 或其他 credential
放進 `boot.json`。

**seed_peers 在 iOS 上是必填**: iOS 14+ 的组播收发需要特殊 entitlement
（com.apple.developer.networking.multicast — 需向 Apple 申请），因此不要指望 core 的
UDP beacon 自动发现。同一 L2 上有 1 台 seed，gossip 就能把所有人连起来。
首次启动会弹出「本地网络」权限对话框 — **务必允许**（拒绝的话
完全连不上 mesh。之后可在 设置 → 隐私 → 本地网络 修改）。

## 4. tvOS 监视端（DoorbellTV）

- Apple TV 4K/HD（tvOS 15+）。用 `-scheme DoorbellTV` 构建，Ad Hoc 与 iOS 相同
  （Apple TV 在 Xcode → Devices and Simulators 里经网络配对）。
- 角色与 Android TV 相同: role=indoor_panel 的常驻监视端。来客时全屏来铃
  （门口直播 MJPEG + 用 Siri Remote 选快捷回复）。SOS 警报的全屏显示 + 警笛 +
  PIN 解除（用遥控器操作绘制数字键盘）也会出现。
- **限制**:
  - source 在畫面與快捷回复之外實作 direct-SIP **listen-only audio**。tracked CI 只證明 link real
    PJSIP 的 unsigned arm64 DoorbellTV **Debug simulator** build，不產生 tvOS Release/device artifact。
    Apple TV 沒有 mic，因此刻意隱藏 Answer，且不支援 audio transmit/雙向通話。
  - tvOS 没有本地持久存储（Caches 会被 OS 随时清理）。boot.json 等价物
    存在 UserDefaults，CRDT 配置、事件 DB 在 Caches — 即使被清也会从 mesh 自动恢复
    （自愈）。不要用于「只靠这一台长期保存事件历史」的用途。
  - 前台前提（tvOS App 不能后台常驻）。被切回主屏就收不到铃 —
    运维方式是「让 Doorbell TV 一直开着」+ 设置 → 通用 →
    屏幕保护程序 = 永不开始。

## 5. 验证清单

1. 启动 → 待机画面（时钟 + 呼叫按钮）。左下角显示 `名称 · vX.Y.Z`。
2. 管理 webui（其他节点）的仪表盘上本设备显示 Online（已入 mesh）。
3. 门口机: 点呼叫 → 室内机/TV 出来铃画面 + 门铃声。也确认事由按钮/语言栏。
4. 室内机: 快捷回复 → 门口机大字显示 + 朗读（AVSpeechSynthesizer）。
5. 室内机: 监视 → 能听到门口声音 / 应答 → 双向通话（VoiceProcessingIO 的 AEC
   可实现免提）。
6. tvOS: tracked Debug simulator build 只作 source/build contract。另建並記錄 signed device artifact，
   在 exact Apple TV 驗證 Monitor audio/video 與沒有 Answer/transmit control。
7. 長按 SOS → 驗證 active rule 選出的 recipient/channel → PIN 解除。
8. 断电→复电后自动恢复（SAM 自动重启）。
