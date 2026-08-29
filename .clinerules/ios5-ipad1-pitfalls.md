# iPad 1 (iOS 5.1.1) 门铃 app 构建/调试踩坑记录

## 工作规约 (用户要求, 必须遵守)
- **git push 到 GitHub 必须用户明确提出后才执行**。本地 commit 可以做, push 不要主动做。
- **等待要轮询, 不要死 sleep**：每 ~1s 检查一次条件 (CI 完成、文件出现、进程存活等),
  满足立即继续; 固定 sleep 只作为超时上限。

设备: iPad1,1, iOS 5.1.1 (9B206), 越狱 (OpenSSH + AppSync Unified), USB/SSH root@ipad 密码 alpine。
无摄像头、无内置麦克风。常供电 kiosk。

## 构建流程
- 构建: `bash ios-legacy/scripts/build_app.sh` (= make clean + make + ldid 伪签 + verify)
  产物 `ios-legacy/build/Doorbell.app`。armv7 + `-miphoneos-version-min=5.1` + iPhoneOS7.1.sdk + MRC + 静态 libc++。
- CI 状态: `gh run list --repo yukiinagato/ox-app-doorbell --limit 5`
- 注意 build_app.sh 是全量 clean build; core 没变时不用重跑 build_core_ios5.sh。

## 连接 (Mac → iPad)
- 现代 `devicectl` **看不到 iOS 5 设备**, 用 libimobiledevice: `idevice_id -l` 拿 UDID。
- USB 转发 SSH: `iproxy 2222 22` 后 `ssh -p 2222 root@localhost`。
- **iOS 5 sshd 只提供 ssh-rsa/ssh-dss host key**, macOS 新 OpenSSH 默认禁用 → 必须加
  `-o HostKeyAlgorithms=+ssh-rsa` (已修进 ios-legacy/scripts/install_via_ssh.sh)。
  ssh-dss 在 OpenSSH 10 已被移除, 别写进选项。scp 需要 `-O` (legacy 协议)。
- 密码可用 `SSHPASS` 环境变量传给 install_via_ssh.sh, 默认 alpine。

## 设备 shell 的坑 (dropbear, 非登录 shell)
- PATH 受限: `grep` 在 /bin/grep (无 /usr/bin/grep); 本机没有 `ps`、`md5`;
  校验文件用 `openssl sha1`。macOS 本地没有 `timeout` 命令。
- **uicache 必须以 mobile 用户跑**: `su mobile -c /usr/bin/uicache`。
  root 跑会报 "cannot open cache file. incorrect user?" (缓存文件归 mobile 所有)。
- `killall SpringBoard` (root) 可用; iOS 2-6 装进 /Applications 后 respring/重启即可看到图标。

## 安装 / 启动的坑 (重要!)
- **安装必须按此顺序** (install_via_ssh.sh 已按此实现, 勿改回):
  1. `killall SpringBoard` (防"拷贝中被 resume"竞态)
  2. scp 拷贝
  3. chmod + **核对设备端 `openssl sha1` 与本地 `shasum` 一致**
  4. `su mobile -c /usr/bin/uicache` (root 会报 "cannot open cache file") — **必须确认输出 `uicache-ok`**
  5. `killall SpringBoard` (用新缓存 respring)
  6. 让用户**实际点图标**验证 (uiopen 能启动 ≠ 图标点按正常!)
- **uicache 被中断 (SSH 断连/respring 打断) 后的状态**：`uiopen` 可能仍能启动 (有迷惑性！),
  但之后**点图标全部 dyld SIGKILL** → 重启 iPad 清状态, 重新按正确顺序装。
- **绝不在 app 可能被 SpringBoard resume 时覆盖二进制**: scp 覆盖中 SpringBoard 拉起 app
  → SIGKILL (EXC_CRASH, 死在 dyld), 且 LaunchServices 状态会坏掉 → 之后**所有合法启动
  (含 uiopen) 都在 dyld 阶段被 SIGKILL**。现象上像"app 必闪退"。
  → 解法: **重启 iPad** 清状态即可恢复, app 本身没问题。
- **【最重要】绝不在同一 inode 上原位覆盖二进制 (scp 直接覆盖)**：内核按 inode 缓存
  代码签名页，原位覆盖后该 inode 的签名状态损坏 → **之后每一次启动都在 dyld 被 SIGKILL，
  且 SpringBoard 会触发 "failed to launch too many times" 熔断**（此后 uiopen 只是假象地
  "无反应"，不会真正拉起进程——别把"无新 crash log"当存活！）。除 reboot 外的解法：
  **先 `rm -rf /Applications/Doorbell.app` 删掉旧 bundle（换新 inode）再拷贝**，立即恢复，
  无需重启 (2026-08-29 实机验证)。install_via_ssh.sh 已固化此步骤。
- 熔断器触发时 "uiopen 验证" 会假阴性：判断存活要看 syslog 里
  `UIKitApplication:jp.keihan.doorbell ... Exited: Killed: 9` 与 `Throttling respawn`。
- 从 SSH 直接执行 app 二进制 (`su mobile -c /Applications/.../Doorbell`) 会被系统 SIGKILL —
  iOS 5 只允许 SpringBoard 拉起。**远程启动用 `uiopen doorbell://`** (URL scheme 已加进
  ios-legacy/Doorbell/Info.plist)。
- 验证 app 是否存活: 看 /var/mobile/Library/Logs/CrashReporter/ 有无新 Doorbell_*.plist
  (失败模式 = 启动后 1-2 秒内出新 log; 15-45s 无新 log = 存活)。
- `idevicescreenshot` 在 iOS 5 上不可用 (需挂 Developer Disk Image); 5.1.1 的 IPSW 里没有
  DDI, Legacy-iOS-Kit 自带的 iOS_DDI 只有现代 iOS 的 → 别走截图这条路。

## 崩溃日志分析
- 位置 `/var/mobile/Library/Logs/CrashReporter/`。
- `LatestCrash-<App>.plist` 只是 stub, **全文在 description 字段** (转 json 后取 description)。
  完整报告是 `Doorbell_<时间>_<hostname>.plist`。
- 符号化: `atos -arch armv7 -o Doorbell -l <报告里的 load address> <PC>`。

## 已修复的代码级坑 (勿回退!)
- **iOS 5.1: 在 dismissViewControllerAnimated 的 completion (CA commit 上下文) 里立刻
  presentViewController → EXC_BAD_ACCESS (SIGSEGV at 0x8) 必崩** (新 iOS 只是 warning)。
  修复: DBAdminPinViewController.m submit() 里回调改为
  `dispatch_after(0.7s, main queue)` 脱离 CA commit 再执行。别改回 completion 里直接回调。
- **iOS 5.1: `UIButtonTypeSystem` = RoundedRect，会绘制系统浅色渐变背景图**，
  显式设置的 backgroundColor 被压在渐变图下不生效 → 深色底+白字的设计里白字完全看不见
  (来电画面/应急画面的按钮)。所有自绘按钮一律用 `UIButtonTypeCustom`。
  修复: DBIncomingViewController.m makeButton/buildReplyButtons、
  DBMainViewController.m _emergencyCancel (b2b5158)。
  全库排查法: `grep -n 'buttonWithType:' ios-legacy/Doorbell/*.m`
  (注意 DBAdminPinViewController/DBInfoViewController/DBPairingViewController 已全部 Custom)。
- **MRC: DBMiniSip 的 poll 线程存活期间对象可能被 dealloc** → SIP 线程稍后
  (ms_hangup BYE 重传可达数秒) 通过 DBSipOnState 向主线程 dispatch 已释放对象的
  delegate 回调 → 堆破坏 → **第二次呼出 UI 冻结 (无 crash log)**。
  修复 (2026-08-29): start() 里 [self retain]、threadMain 末尾 [self release] (线程完走前
  对象不死)；Incoming 在 dealloc/viewDidDisappear/onAnswer/startSip 释放 _sip 前置
  `delegate = nil`。assign 型 delegate 的类都要按此模式处理。

## 调试手段备忘 (本次验证用)
- **没有 admin 密码也能远程触发动作**：panel token 在设备 doorbell.db 的
  `panel.tokens` (scp 回本地 sqlite3 读) → `POST http://127.0.0.1:47180/api/panel/press?k=<token>`
  (但需要 config 里有 doors.*，当前集群 door 为空串时用不了；/api/press 需 admin 会话)。
- **idevicesyslog 在 iOS 5 可用 (无需 DDI)**，抓 UIKit 的
  "Attempt to present while a presentation is in progress" 警告可确认 present/dismiss 竞态。
- 冻结类问题不会有 crash log；验证存活 = 启动后 15-45s 内 CrashReporter 无新文件。
- **UI 看门狗 (2026-08-29 引入, DBAppDelegate)**：后台线程每 3s ping 主线程，无响应
  连续 3 次 (~15s) → 写 `/var/mobile/Documents/doorbell-hangs.log` → 遗留
  `( sleep 1; uiopen doorbell:// ) &` 子进程 → `_exit(0)` 自杀 → SpringBoard 1s 后重新拉起
  app。kiosk 上"UI 冻结=崩溃"，必须有自愈。hangs.log 是冻结类问题的关键取证来源
  (crash log 不会记录 hang)。误触发阈值: 3s 轮询 + 5s 等待 × 3 次，主线程最长合法
  阻塞 (MJPEG 解码/音頻停止) 远小于此，安全。
- **DDI (截图) 现状**：Xcode_5.1.dmg 的 DeviceSupport 只有 4.2/4.3/5.0/5.1/6.0/6.1/7.0/7.1，
  **没有 5.1.1 (9B206)**；把 5.1 的 DDI 挂到 5.1.1 上 → ideviceimagemounter "can't mount"
  (签名按 build 校验)。要截图需 Apple 开发者站下载 Xcode 4.6.3 DMG 取
  "5.1.1 (9B206)/DeveloperDiskImage.dmg" 再 ideviceimagemounter。
  (`ideviceimagemounter /tmp/ddi51.dmg /tmp/ddi51.dmg.signature`)

## 设备状态结论 (2026-08-29 调试)
- 闪退根因 = 上述 CA commit 内 present 的 iOS 5.1 UIKit bug, 已修复并装机验证
  (reboot 后 uiopen 启动, 45s+ 无新崩溃)。
- 19:52-19:56 的 dyld SIGKILL 全部是安装时序/LaunchServices 状态问题, 与代码无关。

## ios-kiosk 重写版 (2026-08-29 深夜, 全面重构后新增的坑)
- **`dict[@"key"]` 下标语法是 iOS 6+**。iOS 5.1 实机直接
  `objectForKeyedSubscript: unrecognized selector` 起动即死 (编译器不报错!)。
  → ios-kiosk 全库禁用下标语法, 一律 `objectForKey:`/`setObject:forKey:`。
- **`[UIButton buttonWithType:...]` 生成后再调 `init`/`initWithFrame:` 在 iOS 5 是
  assertion 崩溃** ("unsafe to initWithFrame: already initialized UIButton")。
  → buttonWithType 创建后只能 setFrame, 绝不再 init。
- **ARC 在 armv7 + min iOS 5.1 完全可用** (`-fobjc-arc`; 所需 runtime 符号 iOS 5.0+ 全有,
  clang 按 deployment target 不发 iOS 8+ 的 objc_alloc)。旧 Makefile "ARC 不可"是误判。
  ios-kiosk 全库 ARC。
- **core JSON 快照绝不在 main 线程同步取**: 起动直后的 config_changed/peers_changed storm ×
  core 内部锁 → main 被 15s+ 塞死 → watchdog 自杀 (表现为"UI 没反应/闪退")。
  → ios-kiosk: 背景直列 queue 收集 (dirty 合并) + main 只反映。
- **看门狗自杀重启会触发 SpringBoard "failed to launch too many times" 熔断吗?** 不会
  (_exit 是正常退出), 但崩溃风暴 (如上述下标语法) 会 → 需 reboot 清状态再验证。
- **多开 idevicesyslog 会互抢连接且抓不到新行** (ASL 缓冲回放会混入旧行) → 验证前
  `pkill -f idevicesyslog`, 并用设备端 `date` 对齐时间戳过滤。
- **探活新手段**: Mac 侧 `iproxy 8180 47180` 后 `curl http://localhost:8180/` —
  内嵌 core httpd 有响应 (302/unauthorized 均算活) = app 进程存活, 无需截图。
- ios-kiosk 版结构: 屏幕 = UIView + DBRouter 单点切换 (无 present/dismiss/UIAlertView),
  MJPEG = BSD socket 线程收流 + 后台解码 (main 只 blit)。详见 ios-kiosk/README.md。

