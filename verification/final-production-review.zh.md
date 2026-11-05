# 生产发布复核

日期：2026-09-26

## A. Baseline 与本次范围

- 起始 baseline：`d9547b3b4f5b0d5dafb9698a3681a0ddc7a0d252`。
- 本次已测应用源码 revision：`f63e53041412ba9a4f942d27db6a1c3fb1e6040e`。
- 之后新增的验收账本不改变已测应用源码。最终 git 状态由本报告交付时的 `git status --short` 给出。
- 起始时存在用户拥有的未跟踪目录 `verification/qa-v2/`；保留原样，未清理或覆盖。
- 没有 push、发布或更改生产部署状态。

## B. 修复及复核结果

### T17：视频上传临时故障恢复

- 严重度：高。
- 根因：HTTP 上传、授权错误、超时和暂时性故障共用立即关闭视频的失败路径；服务端 `remote_core_accepted` 也未形成持久的、与身份绑定的 UI 状态。
- 修复：`webui/panel/call.html` 与 `webui/panel/video-session.js` 现在区分 `OFF`、`LOCAL_READY`、`AUTHORIZING`、`SENDING`、`REMOTE_CORE_ACCEPTED`、`RECOVERING`、`INTERRUPTED`、`DENIED`、`STALE`。本地相机 ready、帧发送成功和远端 Core accepted 独立表示。临时 5xx、断网和 timeout 使用有上限的 250/500/1000/2000/4000 ms 退避；达到上限后进入 `INTERRUPTED`，保留发送意图。401/403/409、撤销和身份不匹配不重试。timer、请求和回调绑定 call/revision/generation/owner/session，并在执行前重验；关闭、挂断、登出、替换通话会取消恢复。
- 测试：22 个 Web 测试通过。回归覆盖 503/timeout 恢复、403/409 不重试、旧 generation timer 不影响新通话、手动关闭取消 timer、重试上限、接受响应匹配以及本地预览与远端接受的区分。
- 结果：`PASS_COMPONENT_ONLY`。真实双节点 HTTPS、相机权限、媒体 relay 和设备视频尚未验收；独立复核未运行。

### T19/F19：浏览器播放状态

- 严重度：高，浏览器可能在收到/解码首帧前报告 `playing`。
- 根因：加载态提前转成播放态；Core call fallback 探针与生产使用的单 JPEG 轮询路径不一致。
- 修改：`webui/panel/playback.js` 等待首张图片实际解码；startup deadline 覆盖首帧等待。`tools/qa_v2/browser_probe.py` 使用生产 `poll` 模式；`webui/tests/playback.test.js` 增加无首帧不报播放回归。按仓库规则同步递增 Android、iOS 与 iOS kiosk 版本/build。
- 结果：Web 单测通过，真实 Chromium 对干净 Core fixture 的 6 个浏览器场景通过。此项仅证明 fixture 上的播放组件与图像状态，不证明登录 panel 或 T18 端到端链路。

### T16：media relay

- 复核了 `core/src/node/media_relay_service.inc`、边界控制及相关服务：代码路径包含 generation/call/owner/principal 绑定、peer epoch、期限、active + latest pending 队列、容量/速率限制和撤销清队列。
- 选定 ASan/UBSan media/T16/HTTP/SecureChannel 用例通过（8 cases、64 assertions）。同进程双 Node loopback 测试不等于独立进程的真实两节点部署。
- 未运行慢 peer、正在发送时换 call、撤销即时阻断、peer reconnect/epoch 变化等独立双节点场景。状态仍为 `IMPLEMENTED_CANDIDATE`，verification `BLOCKED_ENV`，independent review `NOT_RUN`。

### T30、T31、T32

- T30 原因为操作测试在目标 MQTT bridge 尚未连接时发起请求；Core 当时正确返回 `authority_unavailable`，测试却只等待可能过期的 `connected` 状态。测试现在等待实际 MQTT CONNECT。ACK 测试 11 cases/1,481 assertions、HTTP 测试 5 cases/198 assertions 通过。全量 Core 及冻结 Web + native Core/SQLite HTTP 集成尚未完成，T30 仍 `PARTIAL`。
- T31 仍 `IN_PROGRESS`：生产授权与撤销生命周期、session mapping、legacy fallback/migration 的全面安全审阅、文档与独立审查未收口。
- T32 仍 `NOT_IMPLEMENTED`：panel 管理创建/列出/授权修改/撤销、media grant 撤销、最后活动、legacy_shared 识别及安全迁移管理路径没有完整验收。
- T16/T17/T18/T30/T31/T32 均没有完成独立复核；没有把重复运行同一测试称为 independent review。

## C. 自动化、浏览器和构建结果

| 项目 | 结果 | 证据及限制 |
|---|---|---|
| Web | PASS | `webui/tests/*.test.js` 共 22 个测试通过。 |
| i18n/英文源码 | PASS | `python3 tools/gen_i18n.py --check` 与 `python3 tools/check_english_source.py` 通过。 |
| 干净 Core 构建 | PASS | macOS 干净目录构建成功，配置 `DB_WITH_PJSIP=OFF`，明确使用 `sipctl_stub`，不构成 SIP 验收。 |
| Core 全量套件 | FAIL / TIMEOUT | macOS 180 秒界限内未完成；Linux Docker 初次全量运行在 300 秒界限到达 media TCP bounds 时未完成。单独 Linux `media TCP bounds*` 测试通过，1 case/32 assertions。修正测试 fixture 后正在重跑完整 Linux suite；最终状态按 `verification/latest/execution-evidence.json` 更新。 |
| ASan/UBSan | PASS（选定用例） | 8 cases/64 assertions；macOS ASan 不支持 leak detection，本次关闭 leak 检查。 |
| QA v2 时钟 | PASS | Clean Core 的 5 个时钟用例和 8 个 Swift 时钟用例通过。 |
| Chromium | PASS（组件/fixture） | 系统真实 Chromium，6/6 用例：有效 JPEG 解码、无效图与无首帧不报播放、MJPEG 像素变化、单 JPEG 轮询 fallback 持续移动、停止时释放 image 资源。数据在 `verification/latest/browser-results.json`。fixture 不是 Node A/B HTTPS 双节点，无真实 Cookie、camera、远端 relay 或 Core 接受确认。 |
| Linux/Docker | PARTIAL | Ubuntu 24.04 clean build 成功，Linux 定向 media TCP 用例通过。完整套件重跑状态以 evidence JSON 为准；未形成一键 clean runner，也未运行独立两节点故障矩阵。 |
| HTTP/SIP/media | PARTIAL | 定向 Core 测试和部分 sanitizer 用例通过。真实 SIP register/INVITE/RTP/audio 与真实 HTTPS relay 未完成；stub 构建不能作生产 SIP 证明。 |

## D. 越狱 iPad 实机

采集过程、去敏后的设备身份和限制见 `verification/device-inventory.json`。密码、密钥、地址未写入仓库；未制作设备备份。

| 设备 | 实际型号 / OS / build / arch | 部署与运行观察 | 通话验收 |
|---|---|---|---|
| iPad 1 | `iPad1,1` / iOS 5.1.1 / `9B206` / armv7 | 真实 SSH 采集；干净 iOS 5.1 armv7 app 0.3.52 build 55 安装成功，launch 命令观察到进程。 | 未登录呼叫；无设备 SIP register、INVITE、RTP、音频、视频、后台/前台、连续呼叫、重连或重启验收。Core SIP 控制报告为 stub；compat app 有 MiniSIP 适配器，不能以 host loopback 代替设备音频。 |
| iPad mini 3 | 未采集 | SSH 端口拒绝连接。 | `BLOCKED_ENV`，未部署或测试。 |
| iPad Air 1 | `iPad4,2` / iOS 12.5.8 / `16H88` / arm64 | 真实 SSH 采集；当前 arm64 Release app 0.1.40 build 41 和嵌入 Swift dylib 以越狱 `ldid` platform entitlement 签名。LaunchServices 注册到并存的新 bundle 路径，设备进程启动并持续存在 6 秒。原 bundle 与 app 数据未删除。 | 完成安装/启动观察；未完成截图、真实 UI 操作、认证呼叫、SIP/RTP 音频、视频、后台/前台、网络重连或重启。Xcode 缺少 iOS 12.5.8 developer image。 |

## E. Windows 原生 VM

| 系统 | 方式/状态 | 结果 |
|---|---|---|
| Windows XP SP3 | `NOT_SUPPORTED` | 不是支持目标：Windows 外壳面向 .NET Framework 4.8，安装程序要求 Windows 7 SP1（MinVersion 6.1sp1），watchdog 使用 Vista 以上 API，HTTPS 集成需要 WinHTTP TLS 1.2。不再作为待验收项。 |
| Windows 7 SP1 | `BLOCKED_ENV_MISSING_WINDOWS_IMAGE` | 未找到本机原生 VM runtime 和合法 Windows 7 镜像；没有进行原生运行。 |
| Modern Windows | `BLOCKED_ENV` | 无 Windows host/VM。 |

Docker 仅用于 Linux；没有用 Docker、Wine 或交叉编译声称 Windows 7 通过。没有 guest/Core IP、桥接、TCP 或 SIP 连通证据。

## F. 未完成项

- `FAIL`：Core 全量套件尚未获得通过结果；Linux 重跑未完成前保留失败/超时，不以单测通过抵销。
- `BLOCKED_ENV`：HTTPS 双节点真实浏览器 E2E；独立进程 relay 与 slow peer/revoke/epoch 测试；iPad Air 1 屏幕/UI 自动化与完整通话测试；iPad mini 3 实测；Windows 7/现代系统原生 VM。
- `NOT_RUN`：设备真实 SIP/RTP/audio/video；T18 全流程；T31 完整 identity/grant 撤销和迁移；T32 panel 管理生命周期；reference frame 拒绝后的依赖差分帧实测；T16/T17/T18/T30/T31/T32 独立复核。
- `feature-parity.json` 将 Chromium 播放 fixture 证据限定记录在 Web Panel 的 F19 单元格；它没有把设备安装或单元测试外推到其他平台。其他没有证据的功能单元继续 `NOT_RUN`。
- 唯一当前任务状态账本为 `verification/progress.json`；报告与其状态必须保持一致。

## NOT_RELEASE_READY

依据：Core 全量测试没有绿色结果；真实双节点 HTTPS、SIP/RTP 设备通话、三台目标 iPad 完整验收、原生 Windows 测试、T31/T32 收口及独立复核仍缺失。当前只具备局部源码修复、Web/Chromium fixture、定向 Core 与 iPad 1 安装启动证据，不能作为生产 release gate 通过。
