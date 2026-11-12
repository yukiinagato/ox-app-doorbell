# Windows 构建环境（Apple Silicon Mac + 本地 VM）

本頁是環境配置方案，不是目前 revision 已完成 Windows VM/Toughpad 驗證的證據。只有記錄 VM、
toolchain、artifact 與結果後才能標為 build verified；實機 commissioning 另行處理。

方针: 开发迭代用本地 VM，（可选）发布产物用 GitHub Actions。
Docker 不可行 — macOS 上的 Docker 只有 Linux 容器，而 WPF/.NET Framework 的
构建链只存在于 Windows。

## 1. 准备 VM（Windows 11 ARM64）

| 软件 | 费用 | 备注 |
|---|---|---|
| UTM | 免费 | 导入 ARM64 Win11 的 ISO/VHDX。省事 |
| VMware Fusion | 个人使用免费 | 稳定。有共享文件夹 |
| Parallels | 收费 | 体验最佳。Microsoft 认可的 Win11 ARM 获取流程 |

- 安装 Windows 11 ARM64（通过 Microsoft 官方 Insider/ISO，或 Parallels 自动获取）。
- ARM64 Windows 可模擬許多 x86/x64 工具，但 repository 沒有此 VM 路徑已完成的驗證記錄。
  應把它視為候選 build 環境。

## 2. VM 内需要安装的软件

1. **Visual Studio 2022 Community** — 工作负载:
   - 「.NET 桌面开发」（WPF / .NET Framework 4.8 SDK+targeting pack）
   - 「使用 C++ 的桌面开发」（MSVC v143, CMake, Windows 10 SDK）
   - 单个组件: 「MSVC v141 - VS2017 C++ x64/x86 生成工具」
     （面向 Win7 实机的保险。在 ARM64 上以模拟方式运行，慢但可用）
2. **Git**、（可选）**Claude Code** — 以便在 VM 内也能接力。
3. **Inno Setup 6**（制作安装器，Phase 1 后半）。

## 3. 仓库共享

- 推荐: 用 VM 的共享文件夹挂载 Mac 侧的 `~/Documents/project/app-doorbell`
  （VMware/Parallels）。或用 git 同步（以 commit 为单位往返）。
- 构建在 VM 内本地磁盘的 build 目录进行（在共享文件系统上
  构建很慢）: `win/build.cmd` 会这样安排。

## 4. 构建（VM 内）

```bat
win\build.cmd            :: core DLL (x86+x64, MSVC) + WPF app + 运行测试
```

將錯誤與精確 toolchain version 保存到 release record。

## 5. Mac 侧的事前验证（mingw-w64）

在 Mac 上 `brew install mingw-w64` 后:

```bash
cmake -S core -B build-win64 -DCMAKE_TOOLCHAIN_FILE=core/cmake/mingw-w64.cmake && cmake --build build-win64 -j8
```

这样大部分 Winsock/API 移植错误可以在进 VM 之前消灭（最终确认仍需 MSVC/实机）。

## 6. Toughpad 实机验证（最终）

- 支持下限为 Windows 7 SP1。Windows XP 不是目标平台（.NET Framework 4.8、安装程序的
  MinVersion 6.1sp1、watchdog 使用 Vista 以上 API）。
- Win7 机器: 需先安装 .NET Framework 4.8 离线安装包和 KB3140245（WinHTTP 的 TLS 1.2）。
  缺少 .NET 4.8 时安装程序会中止，缺少 KB3140245 时会警告；安装前 HTTPS 集成会失败，原因写在
  `logs\doorbell.log`。只有当 v143 产物跑不起来时才切到 v141 构建。
- AEC 标定、摄像头枚举、kiosk（替换 shell）只能在实机上做最终确认。

## 7. 2026-11 审查修复的验证

编写这些修复时尚未在 Windows 上运行过。在把 Windows 通道标为已验证之前，请在 VM 中执行。

```bat
:: Contract tests and the watchdog policy
python win\tests\test_windows_contracts.py
cmake -S win\watchdog -B build-watchdog -A x64 -DBUILD_TESTING=ON
cmake --build build-watchdog --config Release -j
ctest --test-dir build-watchdog -C Release --output-on-failure

:: Full bundle; a release additionally needs DB_SIGN_CERT_SHA1 and DB_UPDATE_PUBLISHER (the CN)
set DB_ALLOW_SIP_STUB=1
win\build.cmd
```

在已安装的设备上（第 1–3 项使用管理员命令提示符）：

1. `icacls "%ProgramData%\Doorbell"` 中 Users 仅为 `(RX)`，`...\service` 没有 Users 写权限，
   `...\data` 为 Users `(M)`，`...\data\secure` 包含 `Doorbell Operators`。
2. 以标准用户身份无法在 `%ProgramData%\Doorbell\service` 中创建文件。
3. `sc qc DoorbellWatchdog` 仍能启动应用，`watchdog.log` 位于 `...\service`。
4. 5 分钟内强制结束 `DoorbellApp.exe` 三次会进入安全模式；连续三次离开集群（恢复出厂）不会。
5. 快速切换到另一个账户后，应用会迁移到新的控制台会话。
6. 冻结 UI 线程（在调度器上用调试器中断）约 20 秒后，watchdog 会重启应用。
7. 启动第二个 `DoorbellApp.exe` 会以退出码 5 结束，第一个继续运行。
8. 拔插门口机摄像头后，无需重启应用视频即可恢复。
9. 反复打开和关闭来电画面后，`netstat -ano` 中没有残留的回环媒体连接。
10. 用未签名或其他签名的安装程序进行应用内更新会被拒绝，并显示 `web_admin.update_untrusted`。

## 8. 在局域网 Windows 电脑上的自动化 UI 测试

UI 冒烟测试在局域网内的一台真实 Windows 电脑上运行，由 Mac 通过 SSH 驱动。电脑上只需要手动
操作一次。

**在电脑上只做一次的步骤。** 用将要显示应用的账户（必须是管理员）登录，把
`win/scripts/setup_test_host.ps1` 复制到电脑上，在管理员权限的 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_test_host.ps1
```

该脚本会安装 Windows 自带的 OpenSSH 服务器，把 `sshd` 设为自动启动，添加一条防火墙规则
（TCP 22，专用网络配置文件，仅限本地子网），把测试密钥写入
`%ProgramData%\ssh\administrators_authorized_keys`，把 SSH 默认 shell 设为 PowerShell，创建
`C:\DoorbellTest`，并注册按需运行的计划任务 `DoorbellTest-RunJob`。该任务在已登录的桌面会话中
运行作业（SSH 会话无法显示窗口）。脚本会打印每一项更改，可以重复运行，不会更改密码或其他安全
设置；`-Uninstall` 只撤销它自己做过的更改。对应的私钥是 Mac 上的
`~/.ssh/doorbell_win_test_ed25519`。

如果 `sshd` 无法启动，脚本会给出它判断的原因（端口被其他程序占用、缺少主机密钥、`sshd.exe -t`
的输出、OpenSSH 和服务控制管理器最近的事件），继续完成不依赖该服务的步骤，并以非零状态退出；
排除原因后再运行一次即可。端口 22 被占用时，用 `-Port <空闲端口>` 运行（它会把 `Port` 写入
`%ProgramData%\ssh\sshd_config`，`-Uninstall` 时恢复），并给 `run_remote_tests.sh` 加上
`--port <n>`。

**每次运行，在 Mac 上。** 保持测试账户已登录且屏幕未锁定，然后执行：

```sh
win/scripts/run_remote_tests.sh <host> [user]              # 当前分支最新的成功 CI 构建
win/scripts/run_remote_tests.sh <host> [user] --run <id>   # 指定的 Actions 运行
win/scripts/run_remote_tests.sh <host> [user] --zip <file> # 本地构建包
```

驱动脚本会下载 CI `windows-contract` 作业的产物 `doorbell-win-test-bundle`（未签名的 SIP 桩
构建），复制到电脑上，分别以室内机和门口机身份各运行一次 `win/scripts/ui_smoke.ps1`，并把
`result-<role>.json`、应用日志以及每个界面的浅色和深色截图取回到
`build-redesign-win/remote-tests/<时间>/`。只要有一项检查失败，就以非零状态退出。

被测应用不会接触家庭集群，也不会接触电脑上已安装的数据。它以 UI 测试模式启动，该模式必须同时
具备 `--ui-test`、`--data-dir <一次性目录>` 和 `DOORBELL_UI_TEST=1` 三项才生效，并且拒绝使用
已安装的数据目录；它的 `boot.json` 未配对，没有种子节点，使用端口 47972/47980，并关闭 HTTPS。
Core 没有关闭发现信标的开关，因此驱动脚本在每次运行期间会添加两条防火墙规则，阻止测试用的
`DoorbellApp.exe` 使用 UDP 47171（`DoorbellTest block discovery (in)` 和 `(out)`），运行结束
（包括失败时）即删除。

测试只使用 Windows 自带的 UI 自动化程序集，不在电脑上安装任何东西。它通过 AutomationId
（XAML 的 `x:Name`）查找元素，所以重命名带名称的控件时要同步更新 `ui_smoke.ps1`。不需要
Windows 的部分有主机侧测试：`win/scripts/test_ui_test_mode.sh` 和
`win/scripts/test_zoom_pan_math.sh`。
