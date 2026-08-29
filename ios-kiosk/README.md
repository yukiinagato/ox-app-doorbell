# ios-kiosk — iPad1 (iOS 5.1.1) 门铃 kiosk 殻 (ARC 重写版)

`ios-legacy/` 的彻底重构版。旧版保留不动; 本目录是新的生产实现。

## 为什么要重写 (旧版的问题诊断)

| # | 问题 | 根源 | 本版的解法 |
|---|------|------|-----------|
| 1 | **UI 一直没反应** | `DBMjpegClient` 的 `NSURLConnection` 挂在 main runloop, `parseLoop` 的 `while(YES)` 里 `[UIImage imageWithData:]` **主线程同步解码 JPEG**。A5 单核上周期性长阻塞 | BSD socket 专用线程收流 → 后台串行 queue 解码 (ImageIO 缩略图 = DCT 直接缩放, ≤640px) → **latest-wins 丢帧 + ~8fps 上限** → main 只做 blit |
| 2 | **"闪退"** | 看门狗把 1 的卡死检测为 15s 无响应 → `_exit(0)` 自杀重启 → 用户看到闪退。卡和崩是同一条因果链 | 根因 1 消除后看门狗只兜真正的未知卡死; 日志带**当前屏幕名**便于取证 |
| 3 | **present/dismiss 崩溃类** (CA commit 内 present 必崩、事件中 dismiss/dealloc 再入崩、UIAlertView 冲突) | iOS 5.1 UIKit 模态机薄脆; 旧版每修一处要加 0.7s dispatch_after 之类的补丁 | **整个代码库不存在 present/dismiss/UIAlertView**。屏幕 = 普通 UIView, `DBRouter` 单点 `addSubview/removeFromSuperview` 切换; PIN/确认 = 覆盖层; 配对错误 = 屏内 label |
| 4 | **MRC 手工内存 bug** (堆破坏 → 二次来电冻结) | 4000 行手工 retain/release + `__unsafe_unretained` | **ARC** (`-fobjc-arc` + min iOS 5.1 实测可用; 所需 runtime 符号 iOS 5.0+ 全有, clang 不会发 iOS 8+ 的 `objc_alloc`) |
| 5 | SIP delegate 跨线程所有权 | assign delegate + poll 线程回调 vs dealloc 竞争 | delegate = ARC weak + 显式 nil 化; `NSThread` 对 target 的强持有天然保证 "线程完走前对象不死" (旧 self-retain 手法的语义化); **全 app 单 SIP 会话**, 唯一所有者是 DBRouter |

## 结构

```
ios-kiosk/
├── Makefile                    # clang 直接驱动 (armv7 + min 5.1 + iPhoneOS7.1.sdk + ARC)
├── scripts/
│   ├── build_app.sh            # clean + make + ldid 伪签 + verify
│   └── install_via_ssh.sh      # 安全安装流程 (见下)
├── lib/libdoorbell_all.a       # core C++ 静态库 (armv7, 与旧版同一产物)
├── mini_sip/                   # 纯 C mini SIP (原样复用)
├── qr/                         # qrcodegen C (原样复用)
└── src/
    ├── Info.plist              # bundle id 不变 → 端机 boot.json/doorbell.db/配对状态直接继承
    ├── main.m
    ├── Support/                # DBAppDelegate (+最小 root VC), DBWatchdog
    ├── Core/                   # DBCoreBridge (core C ABI 包装), DBBootConfig, DBConfigUtil, DBTexts (ja/en/zh)
    ├── Net/                    # MJPEG/fMP4 客户端 + 本机 loopback HLS server
    ├── Media/                  # SIP/音频/警铃/QR + fMP4→MPEG-TS→MPMoviePlayer H.264 路径
    └── Screens/                # DBScreen 基类, DBRouter (状态机), DBHomeScreen,
                                # DBIncomingScreen, DBPinOverlay, DBInfoScreen, DBPairingScreen
```

## 事件流 (单点)

```
core 内部线程 ──ui event cb──▶ DBCoreBridge (marshal) ──▶ DBRouter.onCoreEvent (main)
                                              │
   press ──▶ DBIncomingScreen.showIncoming    │
   reply/chime/display/emergency ──▶ DBHomeScreen
   paired ──▶ persistPsk → closePairing       │
   SIP state ──▶ DBIncomingScreen             │
                                              ▼
   屏幕切换只有一处: DBRouter.transitionTo (addSubview/removeFromSuperview + fade)
```

## 不变量 (改代码时必须维持)

1. **不引入** `presentViewController` / `dismissViewControllerAnimated` / `UIAlertController` / `UIAlertView`。
2. **main 线程不做解码** (JPEG/QR/图片解码一律后台), main 只做布局和 blit。
3. 所有按钮 `UIButtonTypeCustom` (iOS5 System = RoundedRect 白渐变, 白字看不见)。
4. 事件处理必须幂等 (重复事件无害); SIP 同时最多一个 session。
5. MRC 语法 (`retain`/`release`/`NSAutoreleasePool`) 不可回退 — 本目录是 ARC。

## 构建 / 安装

```bash
bash ios-kiosk/scripts/build_app.sh        # → ios-kiosk/build/Doorbell.app
make -C ios-kiosk test                     # MPEG-TS PAT/PMT/PES/continuity 主机端测试
bash ios-kiosk/scripts/install_via_ssh.sh  # USB (iproxy 2222) 或传 iPad IP 走 WiFi；已有 app 时快速更新
bash ios-kiosk/scripts/install_via_ssh.sh --full  # 强制 uicache + respring
```

安装脚本会先把新 bundle 上传到 staging 路径。检测到已有 app 时，只停止 Doorbell、**删除旧 bundle 后移动 staging bundle (换新 inode，防 dyld SIGKILL 熔断)**，再启动新 app，不重启 SpringBoard。首次安装或指定 `--full` 时才执行 `uicache` 和 respring；修改图标、名称等系统缓存信息时应使用 `--full`。
