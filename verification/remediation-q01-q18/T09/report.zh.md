# T09 执行报告

日期：2026-09-22。执行：`/root/t02_translation`（本轮负责 T09）。
任务状态：VERIFIED_IN_SCOPE（production_test）；四项验收及主任务发现的集成退化回归通过。
主任务已完成版本、资源嵌入、综合验证和独立复核；不宣称真机资格通过。

## 来源与范围

审查参照、执行前 HEAD、验证来源 SHA 均为
`b26e0d346df99f2879915241b6e98d8ef1aa0707`，加上当前 dirty 工作树。
修复后测试时的整体 tracked diff SHA256 为
`95b0c5256009eb7fc4f40073c8ee722046c134a1e9bf5083ec39312b4c5a1ea9`。
其他 agent 在互不重叠范围并行修改，最终整体摘要由主 agent 另行记录。
本任务相对传入工作树的最终独立差异为 `evidence/task-diff-r2.patch`，SHA256 为
`34b6a7cba9d76e105091af650772e3b4744627bafd30a3de612a9dc76d175398`。
修复前后源文件和测试文件的精确哈希分别见 `evidence/before-source.json`、
`evidence/after-source-r2.json`。初版差异和来源证据保留；复核发现的退化及修正另有记录。
原始传入文件副本位于
`build/remediation-t09-20260922/incoming/`，没有重置或覆盖之前的修复。

仅改动 `webui/panel/runtime.js`、`webui/panel/call.html`、
`webui/tests/call_state_controller.test.js`，新增 `webui/tests/request_deadline.test.js`。
call 页之前已有的通话身份/代次、旧回调、语言、页面生命周期与 UI 修复保留。
未改 admin、i18n、原生 ABI 或 `ios-legacy`；应用版本/build 和嵌入产物交由主 agent 统一更新。

## 真实生产入口

共享 `DoorbellPanelRuntime.requestWithDeadline(options, complete)` 直接使用浏览器 XHR；
`createRequestLane()` 拥有单条链的在途句柄和递增代次。
现代 call 页的 `load()` 首先迁移 `GET /api/panel/call-info`，使用冻结的 4000 ms
期限；`pagehide` 取消该链的在途传输。原有 `loadPending` 及页面/选择/通话身份检查继续生效。

按现有 `webui/panel/API.md`，door/monitor 是面向旧 Safari 的 ES5/XHR 页面，
call 页本来就是现代浏览器页面。新增共享模块代码仅使用 ES5/XHR，不引入新框架、
AbortController、fetch、Promise 或 Promise.finally 依赖。测试的异步辅助工具使用
Node 能力，不把它们注入生产兼容层。

## 改动与失败语义

- 设置真实 `xhr.timeout`，同时建立一个兼容 watchdog；旧引擎拒绝 timeout 属性时，
  watchdog 仍约束等待。所有完成入口仅结算一次，清除计时器并拆除 XHR 回调。
- 支持 deadline、cancel、method、headers、body、generation。结果独立保留 HTTP
  status、业务 error_code、响应 data，并区分 success/http/business/timeout/network/
  aborted/parse_error。
- 每条 lane 最多一个在途请求；取消后立即释放旧链的槽位。旧句柄和迟到回调不能清理
  新请求的 busy 状态，也不能再次交付旧结果。请求代次在启动时冻结。
- 每次 load 拥有自己的 call-info 句柄。state 提前失败时，finally 取消该次 load
  尚未完成的 call-info；仅操作自己的句柄，不取消页面恢复后的新请求。lane 拒绝接纳
  时立即失败，不留下永远无法结算的 Promise。
- 取消/超时只终止本地等待和传输。写操作的本地不确定错误标记 outcome_unknown，
  适配器不重试、不创建新的操作 ID，也不声称服务端副作用已取消。
- 本轮只迁移 call-info。state/locale/heartbeat/SOS/upload 的完整独立调度和迁移
  留给对应 T10/T11/T12/T17；不能用本卡关闭整个 Q06/Q07/Q13。

## 验证

所有命令 cwd 为 `/Users/ox/Documents/project/app-doorbell`。
工具链为 Node.js v25.9.0；精确主机 OS/架构、开始/结束时间、退出码和来源清单摘要
见各 `evidence/*.json`。证据层是执行真实生产 JS/HTML 的主机 VM 行为测试；
XHR、时钟和 DOM 是可控夹具，未复制请求算法或页面控制器。

| test_id | 命令 | 退出码 | 实际结果 | 原始日志 |
|---|---|---:|---|---|
| 修复前反例 | `node webui/tests/call_state_controller.test.js --deadline-regression` | 1 | call-info 无响应时，4000 ms 后 loadPending 仍非空；业务断言失败 | `evidence/before-read-deadline-r2.log` |
| T09-01 | `node webui/tests/request_deadline.test.js` | 0 | 静默 XHR 到期只回调一次 timeout，释放 lane | `evidence/request-deadline-r2.log` |
| T09-02 | 同上 | 0 | watchdog/native timeout 两种顺序均只结算一次，零残留计时器 | 同上 |
| T09-03 | 同上 | 0 | 取消后旧成功/失败回调不覆盖数据、不清除新请求 busy | 同上 |
| T09-04 | 同上 | 0 | 无 AbortController/Promise/fetch，及原生 timeout setter 不可用时仍有界 | 同上 |
| 复核修复前反例 | `node webui/tests/call_state_controller.test.js --early-state-failure` | 1 | state 先返回 500，旧 call-info 阻挡下一次轮询，恢复断言失败 | `evidence/review-before-early-state-r2.log` |
| 真实页面回归 | `node webui/tests/call_state_controller.test.js` | 0 | 黑洞期限、提前 state 失败后恢复、lane 拒绝、旧 finally/新页面隔离及先前保护全部通过 | `evidence/call-state-r2.log` |
| 共享 runtime | `node webui/tests/runtime.test.js` | 0 | SOS/Push/共享运行时既有行为通过 | `evidence/runtime-r2.log` |
| recovery | `node webui/tests/call_recovery_controller.test.js` | 0 | 旧恢复和摄像头回调不能影响新会话 | `evidence/call-recovery-r2.log` |
| i18n | `node webui/tests/panel_i18n.test.js` | 0 | 既有页面语言验证通过 | `evidence/panel-i18n-r2.log` |
| video | `node webui/tests/video_session.test.js` | 0 | 既有媒体生命周期保护通过 | `evidence/video-session-r2.log` |
| 语法/空白 | `node --check webui/panel/runtime.js`；限定本任务文件的 `git diff --check` | 0 | 通过；语法检查不冒充旧浏览器资格 | `evidence/syntax.log`、`evidence/whitespace-r2.log` |

聚合证据见 `evidence/acceptance.json`。修复前首次记录使用的是传入 manifest；
`before-read-deadline-r2` 补充记录了当时实际新增反例测试的哈希，作为正式修复前证据。
上述为 6 个行为测试脚本，不把内部断言数量或重复运行次数当成新增覆盖数量。

## 自检与剩余资格

检查了单次结算、并发取消、同步完成/发送异常、网络/HTTP/业务/解析错误分类、
旧代次迟到、无新 API 环境、单条链上限，以及写操作结果未知且不重试。
没有改写 Core 授权、恢复窗口、SOS 清除、通话 owner 或物理开锁行为。
主 agent 独立复核通过，见 independent-review.md 和 evidence/independent-review.json。

主 agent 复核发现初版集成的退化：state 提前失败后，旧 call-info 仍占用 lane，
2 秒后的 load 创建了未获接纳且不能结算的 Promise。已先保存真实页面断言失败证据，
再以每次 load 的句柄所有权修复，并补充拒绝接纳和页面恢复竞争反例。最终 call.html
SHA256 为 `93c7c88a2cd2a99b695c0512d83e5f28c777e2a5a1949d98aa25b4e526184177`。
这次仅修正 T09 集成本身，没有提前实施 T10 的完整调度拆分。

全部 14 套 Web 测试通过；最终 call.html/runtime.js 在真实 Core HTTP 夹具中逐字节匹配来源，
见 ../parallel-batch/evidence/embedded-assets-r2.json。Android 两条构建通道和 iOS5 Core/App
已重建嵌入资源，版本见 ../parallel-batch/versions.json。
旧 Safari/WebView 真机和安装验证尚未运行；浏览器 UI 检查受 Chrome 扩展弹窗与 IAB 未连接阻挡，
明确记为 BLOCKED_ENV。其他平台的测试与资格独立记录。

## 下一步

本卡整合通过后，依赖已满足的 T10 可将 state/call-info/locale 分成独立调度链。
报告不授权 push、tag、release、部署、真实开锁或 SOS。
