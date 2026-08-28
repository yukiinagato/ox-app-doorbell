[日本語](ipad1-jailbreak.ja.md) | [English](ipad1-jailbreak.en.md) | [中文](ipad1-jailbreak.zh.md)

# 将 iPad 1 (A1219, iOS 5.1.1) 变成门铃节点

把初代 iPad (2010, A4, 256MB, **无摄像头、无麦克风**) 通过越狱 + 自行构建的
原生 app 变成**门铃网格的一等节点**的步骤。完整的 C++17 核心 (doorbell-core)
可在 armv7/iOS5.1 上运行 —— 这是真能跑的 (已在 A0/B 上验证)。

## 此设备能做什么 / 不能做什么 (硬件上限)

| | 可否 | 原因 |
|---|---|---|
| 查看门口的实时视频 | ✅ | 接收 MJPEG，在 A4 上解码 |
| 听门口的声音 | ✅ | 通过迷你 SIP 直呼门口机，扬声器播放 |
| 快捷回复・开锁 (屏幕操作) | ✅ | C ABI + SIP DTMF `*1` |
| 作为网格节点同步配置・事件 | ✅ | 完整搭载核心 |
| **发送自己的声音 (对讲)** | ⚠️ 必须外接麦克风 | 无内置麦克风。插入耳机(TRRS)/dock 麦克风即可 |
| **发送自己的视频** | ❌ 不可 | 物理上没有摄像头 |

## 0. 前提 (母机 Mac 侧)

构建产物与工具链已在仓库的 `tools/` `ios-legacy/` 中备好:
- `tools/sdk/iPhoneOS7.1.sdk` — 从 Xcode 5.1 DMG 提取 (sysroot；已 gitignore)
- `tools/toolchain/ios5-armv7/` — 自行构建的现代 libc++/libc++abi/libunwind (用 `tools/build_libcxx_ios5.sh` 重新生成)
- `ios-legacy/lib/libdoorbell_all.a` — armv7/iOS5.1 版核心 (`ios-legacy/scripts/build_core_ios5.sh`)
- `ldid` (`brew install ldid`)

若要重建 SDK: 用 `hdiutil attach` 挂载 Xcode 5.1 (或 4.x) 的 DMG，
把 `.../iPhoneOS.platform/Developer/SDKs/iPhoneOS7.1.sdk` 复制到 `tools/sdk/`。

## 1. 越狱 iPad 1 (不完美/untethered)

**Legacy iOS Kit** (LukeZGD) — 可在现代 macOS 上运行、支持 iPad 1 的 untethered 越狱工具。
1. `git clone https://github.com/LukeZGD/Legacy-iOS-Kit && cd Legacy-iOS-Kit`
2. 用 USB 连接 iPad 1 → `./restore.sh` → 从菜单选择 **Jailbreak (untethered)**。
   (如有需要，先恢复到 5.1.1 —— 菜单中的 Restore/Downgrade。NVRAM 清除步骤见 Kit 的 wiki)
3. 完成后 iPad 上会装有 **Cydia**。
- 替代方案: Absinthe 2.0 / redsn0w 0.9.12b1 (当年的 untethered 工具，若有能运行的母机)。

## 2. 越狱后的准备

1. 在 Cydia 中安装 **OpenSSH** (用于通过 SSH 推送 app)。
2. 安装 **AppSync Unified** (允许 ldid 伪签名的 app)。
   - 添加源 `https://cydia.akemi.ai/` → 安装 AppSync Unified。
   - 若源不可用，可经 Kit 的 App Management 或用 `dpkg -i` 手动安装 .deb。
3. 记下 iPad 的 IP (设置 > Wi-Fi)。默认 SSH: `root@<ip>` / 密码 `alpine`
   (**务必用 `passwd` 修改**)。

## 3. 构建 app 并推送 (母机 Mac)

```bash
cd app-doorbell
bash ios-legacy/scripts/build_core_ios5.sh   # 核心 .a (首次/更新时)
bash ios-legacy/scripts/build_app.sh          # 生成 Doorbell.app + ldid 伪签名
# 推送 (二选一)
scp -r ios-legacy/build/Doorbell.app root@<ipad-ip>:/Applications/
ssh root@<ipad-ip> "uicache"                  # 反映到主屏幕
#   ── 或使用 Legacy iOS Kit 的 Install IPA
```

## 4. iPad 侧的初始设置

1. 启动主屏幕上的「门铃」。
2. 首次设置 (应用内 or `/var/mobile/.../boot.plist`):
   - `role` = `indoor_panel`
   - `seed_peers` = 一个或多个既有节点的 `IP:47172` (同一 L2 下，一个即可接入整个网格)
   - `psk_hex` = 集群 PSK (管理界面「添加设备」发行的值，或与既有节点相同)
   - 门口机的 direct SIP 目标 = `<门口机IP>:47190`
   - 是否有外接麦克风
3. 加入网格后，设置 (主题・快捷回复・事由・语言) 会自动同步。

## 5. 外接麦克风 (仅在想对讲时)

由于没有内置麦克风，**说话**需要外部麦克风:
- 耳机口: 带麦克风的耳麦 (TRRS)。iPad 1 的 3.5mm 是否接受耳麦麦克风
  取决于个体/配件 —— 若被识别，RemoteIO 会拾取输入。
- dock 接口: 支持麦克风的 dock 配件。
若无麦克风/无法识别，则以「仅收听」运行 (能听到门口的声音，己方声音为静音)。

## 6. 运行确认

- 按铃 → iPad 全屏显示门口视频，并能听到门口的声音。
- 快捷回复按钮 → 门口机上大字显示 + 朗读。
- 开锁按钮 → 经门口机打开 HA 的锁 (DTMF `*1`)。
- 拔掉 LAN 网线/Wi-Fi → 几十秒内离开网格，恢复后重新加入。
- 有外接麦克风时: 己方声音从门口扬声器传出。

## 注意

- 越狱设备以此门铃专用・LAN 内运行为前提 (不对外公开)。务必修改 SSH 密码。
- 常供电・常亮 (app 会禁用 idleTimer)。注意电池鼓包 (可能的话拆下电池直接供电)。
- 不更新 OS (固定 5.1.1)。更新 app 请重新执行 §3。
