# iPad 1 (iOS 5.1.1) 门铃 app 构建/调试踩坑记录

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
- **绝不在 app 可能被 SpringBoard resume 时覆盖二进制**: scp 覆盖中 SpringBoard 拉起 app
  → SIGKILL (EXC_CRASH, 死在 dyld), 且 LaunchServices 状态会坏掉 → 之后**所有合法启动
  (含 uiopen) 都在 dyld 阶段被 SIGKILL**。现象上像"app 必闪退"。
  → 解法: **重启 iPad** 清状态即可恢复, app 本身没问题。
- 从 SSH 直接执行 app 二进制 (`su mobile -c /Applications/.../Doorbell`) 会被系统 SIGKILL —
  iOS 5 只允许 SpringBoard 拉起。**远程启动用 `uiopen doorbell://`** (URL scheme 已加进
  ios-legacy/Doorbell/Info.plist)。
- 验证 app 是否存活: 看 /var/mobile/Library/Logs/CrashReporter/ 有无新 Doorbell_*.plist
  (失败模式 = 启动后 1-2 秒内出新 log; 15-45s 无新 log = 存活)。
- `idevicescreenshot` 在 iOS 5 上不可用 (需挂 Developer Disk Image)。

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

## 设备状态结论 (2026-08-29 调试)
- 闪退根因 = 上述 CA commit 内 present 的 iOS 5.1 UIKit bug, 已修复并装机验证
  (reboot 后 uiopen 启动, 45s+ 无新崩溃)。
- 19:52-19:56 的 dyld SIGKILL 全部是安装时序/LaunchServices 状态问题, 与代码无关。
