# 生产发布复核

日期：2026-09-26

## A. Baseline

- 起始 commit：`d9547b3b4f5b0d5dafb9698a3681a0ddc7a0d252`
- 已提交代码修复：`86f61e6b146f9ebe505fbdb3496278b7ba88fcd3`（`fix(web): recover transient panel video upload failures`）
- 本报告与验收账本在代码提交之后生成；验收文件提交不改变上述已测代码 revision。
- 初始 worktree 有预存未跟踪目录 `verification/qa-v2/`；已保留，没有读取、覆盖或清理其中内容。最终状态还包括本轮新增验收文件。
- 该检查未推送代码、部署状态或发布物。

## B. 修复列表

### T17：视频上传临时故障恢复

- 严重度：高，通话视频可用性及 generation 隔离。
- 根因：上传、授权、超时和永久拒绝都进入同一 `failVideo()`，立即关掉勾选并永久停止摄像头；成功响应没有消费 `acceptance`。
- 修改：`webui/panel/call.html`、`webui/panel/video-session.js`、`webui/tests/call_media_authority.test.js`、`webui/tests/video_session.test.js`。
- 修复：显式区分 `OFF`、`LOCAL_READY`、`AUTHORIZING`、`SENDING`、`REMOTE_CORE_ACCEPTED`、`RECOVERING`、`INTERRUPTED`、`DENIED`、`STALE`；`LOCAL_READY` 等到 `getUserMedia` 成功；对 5xx、网络错误及 timeout 按 250/500/1000/2000/4000 ms 有界恢复；超过 5 次失败后标记 `INTERRUPTED`，保留用户发送意图；401/403/409 与身份/授权错误不重试并关闭当前 generation。重试 timer、XHR 回调和接受响应均由当前 binding 约束，binding 固定 call id、revision、owner、session、door 和 media generation。视频关闭会取消恢复 timer。只在 binding 仍有效且 generation/sequence 匹配时记录远端接受时间与 sequence。
- 回归覆盖：503 后恢复、授权 timeout 后恢复、403/409 不重试、旧 retry 不触碰替换通话、手动关闭取消 retry、重试耗尽进入 `INTERRUPTED`、匹配的 `remote_core_accepted` 才更新状态、本地媒体 ready 与远端接受分开。
- 结果：22 个 Web 测试全通过；T17 两个专项测试通过。未完成真实 HTTPS 双节点验收及独立复核。

### T16：media relay 代码复核

- 严重度：高，媒体授权、队列、撤销与节点 epoch 隔离。
- 本轮读审了 `core/src/node/media_relay_service.inc` 与 `core/src/node/media_relay_bounds.h`：生产代码使用 generation 授权、call/owner/principal 绑定、peer epoch 校验、grant deadline、逐 publisher 的 active + latest pending 队列、容量和速率限制、撤销时清理队列与 RPC。
- 现有 `T16 real two-node HTTP to authenticated Mesh return-frame relay` 测试实际启动两个 Node、独立 HTTP 端口并通过 loopback TCP Mesh 通信；它们仍在同一进程。按本任务要求，这不算独立进程的 Node A/Node B 生产场景，也不算 HTTPS 浏览器场景。
- 结果：选取的 T16/media/HTTP/SecureChannel ASan/UBSan host 用例 8/8 通过；真实双进程、慢 peer、正在发送时换 call、即时 revoke 与 reconnect epoch 场景未验收。状态仍为 `IMPLEMENTED_CANDIDATE`，未独立复核。

### T30、T31、T32

- T30 当前代码/报告仍标为 `IMPLEMENTED / INTEGRATION_PENDING`。缺口明确为当前冻结 Web 与 native Core/SQLite 的真实 HTTP 集成；本轮没有用旧报告或旧产物替代该集成，因此未关闭。
- T31 仓库 checkpoint 仍列出生产 media grant 安全边界复核、迁移文档、冻结 source 与独立审查；本轮未完成这些工作，仍 `IN_PROGRESS`。
- 仓库中没有找到 T32 当前生命周期实现或验收包；管理创建/授权/撤销/media grant 撤销、活动记录与安全迁移未验收。
- T16/T17/T18/T30/T31/T32 的独立审查均未执行。

## C. 自动测试结果

| 项目 | 结果 | 依据与限制 |
|---|---|---|
| Web | PASS | `webui/tests/*.test.js` 22/22；包括 T17 新增回归。 |
| i18n / 英文源码 | PASS | `tools/gen_i18n.py --check`、`tools/check_english_source.py`。 |
| Clean Core build | PASS | 新目录 `/tmp/doorbell-prod-clean-d9547b3-1` 完整配置并编译；`DB_WITH_PJSIP=OFF`，明确链接 `sipctl_stub`。 |
| Core 全量测试 | FAIL | `doorbell_tests --no-colors` 180 秒内没有完成，超时终止；未确定具体阻塞用例。不得视为通过。 |
| Core 定向 CAS | PASS | 独立运行 `config CAS: materialized schema rejects child writes that corrupt typed parents`，17 assertions 通过。 |
| ASan / UBSan | PASS（选定用例） | 新目录构建成功；media/T16/HTTP/SecureChannel 选择集 8 cases、64 assertions 通过。macOS ASan 不支持 `detect_leaks`，本次关闭 leak detection。 |
| QA v2 Core/时钟 | PASS | clean Core 构建及 5 个 Core、8 个 Swift clock case 通过，记录在 `verification/latest/qa-v2-summary.json`。这是 macOS host 结果，不是 Linux Docker 结果。 |
| 真实浏览器组件 | BLOCKED_ENV | Chromium probe 因缺少 Python `playwright` 模块未运行；见 `verification/latest/browser-results.json`。 |
| Linux/Docker | BLOCKED_ENV | `docker version` 报告无法连接本机 Docker daemon；未执行容器测试。仓库没有可用的 QA compose runner。 |
| HTTP / SIP / media | 部分 | Core 定向 relay/HTTP tests 与 ASan/UBSan 选择集通过；真实 HTTPS 双节点浏览器和真实 SIP/RTP 音频没有执行。host build 使用 SIP stub。 |

## D. 越狱 iPad 实机

真实 OS 与 architecture 必须从设备读取。本轮没有任何一台成功完成 SSH inventory，所以不把历史记录冒充为当前采集结果。具体连接尝试与缺项见 `verification/device-inventory.json`。

| 设备 | 型号 / ProductType | iOS / build / arch | 安装、启动、SIP 音频、视频、生命周期、重连 |
|---|---|---|---|
| iPad 1 | BLOCKED_ENV，未读取 | BLOCKED_ENV，未读取 | 未安装或运行；无设备结果。旧 SSH 算法协商成功，但当前认证返回 Permission denied。 |
| iPad mini 3 | BLOCKED_ENV，未读取 | BLOCKED_ENV，未读取 | 未安装或运行；SSH 端口拒绝连接。 |
| iPad Air 1 | BLOCKED_ENV，未读取 | BLOCKED_ENV，未读取 | 未安装或运行；文档 alias 的 SSH 端口拒绝连接。 |

设备 IP、密码、密钥均未写入仓库。设备 no-backup policy 未触碰。

## E. Windows 原生 VM

| Profile | 执行方式 / 状态 | 结果 |
|---|---|---|
| Windows XP SP3 | `BLOCKED_ENV_MISSING_WINDOWS_IMAGE` | 没有发现 UTM、VMware Fusion、VirtualBox、Parallels 或 QEMU；没有授权镜像。 |
| Windows 7 SP1 | `BLOCKED_ENV_MISSING_WINDOWS_IMAGE` | 同上。未使用 Docker 或 Wine 冒充原生系统。 |
| Modern Windows | `BLOCKED_ENV` | 没有 Windows host 或 Windows guest VM。未执行安装、启动或通话测试。 |

未获得 guest IP、Core IP、桥接网络、TCP 或 SIP 连通性证据。

## F. 未完成项与最终发布判断

- FAIL：Clean Core 全量测试 180 秒超时；失败用例尚未隔离。
- BLOCKED_ENV：真实双节点 HTTPS/browser E2E、Docker/Linux、Chromium probe、iPad 三台实机及 Windows XP/7/modern Windows native VM。
- NOT_RUN：T16 的 separate-process 两节点慢 peer/revoke/epoch场景、T18 完整场景、真实 SIP register/INVITE/RTP 音频、reference-frame 拒绝后的依赖帧门控、T30 Core/SQLite HTTP integration、T31 完整身份迁移验收、T32 管理生命周期、T16/T17/T18/T30/T31/T32 independent review。
- `feature-parity.json` 的 44×12 profile cell 已使用指定状态词汇；未复核/未分类/未盘点字段统一记为 `NOT_RUN`，未把缺失证据改写为 PASS。F20 / Web Panel 是本轮唯一获得新 T17 用例证据的单元格，其余单元格仍有 `NOT_RUN`，不能据此宣称全平台 parity。
- 唯一当前账本为 `verification/progress.json`；该文件将 T16/T17/T18/T30/T31/T32 和全量 Core、设备、Windows 状态指向相同 evidence。

## NOT_RELEASE_READY

依据：全量 Core 测试未通过/未完成，真实浏览器、独立双节点、SIP/RTP、iOS 实机、Windows VM、T30/T31/T32 收口和独立复核均缺少当前运行证据。T17 局部修复及 host regression 不能替代这些 release gate。
