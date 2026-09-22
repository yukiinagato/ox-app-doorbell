# T10 执行报告

日期：2026-09-22。执行：`/root/t02_translation`。
状态：VERIFIED_IN_SCOPE；本任务 `production_test` 四项验收通过。主任务独立复核和 15 套 Web 回归重跑通过（evidence/review.json）；本轮受影响版本与三语资源已整合，平台构建另计。

## 来源与范围

开始与结束的 HEAD 均为 `b26e0d346df99f2879915241b6e98d8ef1aa0707`，基于当前 dirty 工作树继续，保留先前 call 页修复。读取了 canonical T10、03-contracts、04-workflow、05-validation、progress、冻结 ADR C06，以及 T09 最终报告/证据。

输入源哈希见 `evidence/before-source.json`，测试实际来源见 `evidence/after-source.json`；相对本任务输入的独立差异见 `evidence/task-diff.patch`。原始输入副本保存在 `build/remediation-t10-20260922/incoming/`。并行工作中的整体 diff 只作快照，不能替代逐文件来源清单。

本任务仅修改 `webui/panel/call.html`、`webui/tests/call_state_controller.test.js`，新增 `webui/tests/call_page_fixture.js` 和 `webui/tests/call_poll_lanes.test.js`。复用 T09 的生产 `runtime.js` XHR lane 和 deadline 适配器，没有修改共享兼容层。

三个语言键 `panel.state_stale`、`panel.state_waiting`、`panel.config_stale` 已交主任务加入 `i18n/strings.yaml` 并生成三语资源。受影响应用版本/build 由主任务本轮统一递增，避免并行覆盖；本报告的 Node VM 结果不等同于已更新设备中的资源。

## 生产行为

- 将 `load` 拆为 state、call-info、locale 三条链。state 在 finalize 后 1000 ms 调度下一次，deadline 3000 ms；call-info 为 5000/4000 ms；locale 仅目标语言或页面/选择/通话上下文改变时请求，deadline 4000 ms。每条链最多一个在途请求，只拥有自己的计时器。
- 启动不等待词典返回；状态成功立即更新 SOS、门信息和通话状态。call-info 黑洞不会延迟状态，locale 黑洞不会延迟状态或原有 heartbeat 调用。
- 配置失败保留上次有效的 `webrtc` 和门配置，并单独显示设置未更新提示，不取消当前 SIP 会话。语言失败或结构非法保留上次有效词典；未改变的失败语言不会每秒重复请求。
- 成功时间使用 `performance.now()` 的单调值记录；读取失败或快照过期显示最后成功更新的年龄。失败响应不调用 SOS 投影，因此不会清除已知 active SOS，也不会制造 SOS。后续权威成功状态仍可按既有规则清除。
- pagehide 和隐藏页面取消三条读链与计时器；恢复可见性重新查询权威状态，恢复期间旧成功仍显示过期。请求句柄、页面代次和选择/通话身份阻止退休请求修改当前结果；旧 finalize 不会安排新页面的重试。
- 配置成功只重投影仍属于当前选择/通话上下文的最新状态，不重放抢答、结束或恢复副作用。T09 的拒绝接纳、期限、早期 state 失败恢复保护继续保留。

保留原有 SOS runtime、规则收件人/零接收者、target group、raw SOS/规则投影优先级、Web Push、抢答败者、旧 call/revision 与 recovery/session 保护。未修改 Core 业务规则，也未执行真实 SOS。

## red → green 与回归

cwd：`/Users/ox/Documents/project/app-doorbell`。各命令、时间、退出码、主机/架构、Node 版本与日志路径记录在 `evidence/*.json`。测试执行完整生产 inline script 和 `runtime.js`，仅 DOM、时钟、XHR/fetch 边界受控；夹具没有复制轮询、代次或 SOS 算法。

| 验收 | 修复前业务失败 | 修复后实际断言 | 证据 |
| --- | --- | --- | --- |
| T10-01 | call-info 黑洞导致成功 state/SOS 尚未应用 | SOS 立即显示，state 连续刷新；配置 4000 ms 有界失败、恢复；失败保留 SIP 设置 | `before-T10-01.log`、`call_poll_lanes.log` |
| T10-02 | locale 黑洞导致启动时没有 state 请求 | 旧词典保留，连续 state 和原有 heartbeat 调用继续；同语言不反复请求，非法词典不覆盖 | `before-T10-02.log`、`call_poll_lanes.log` |
| T10-03 | active SOS 后 state 失败未呈现最后成功更新年龄 | 多次失败保留 SOS，显示 6 秒单调年龄；权威清除仍有效；state 黑洞 3000 ms 超时并恢复 | `before-T10-03.log`、`call_poll_lanes.log` |
| T10-04 | 恢复页面仍被 locale 阻挡 | 旧 XHR 全部取消，旧响应不回灌；重复关/开和前后台切换计时器有界，恢复立即查询 | `before-T10-04.log`、`call_poll_lanes.log` |

修复前分别运行 `node webui/tests/call_poll_lanes.test.js T10-01` 至 `T10-04`，均退出 1，且因目标业务断言失败。修复后运行 `node webui/tests/call_poll_lanes.test.js`，退出 0，四项 PASS。

`call_state_controller.test.js` 保留并迁移 T09 页面断言到独立 lane 结构，同时继续覆盖旧门/旧会话结果、旧 revision、当前 owner 冲突、旧 locale、页面退出与 SOS 控件复用；新增迟到配置不能把旧 call 投影到新选择。退出 0。

全部 15 个 `webui/tests/*.test.js` 脚本实际运行并退出 0，详见 `evidence/web-suite.json` 和对应原始日志。包括 request_deadline、runtime SOS/Push、call-flow、recovery、i18n、video-session 与其余已有 Web 套件。另有生产 runtime/inline script 语法检查及限定文件的空白检查，均通过。聚合入口为 `evidence/acceptance.json`。

## 限制与后续

本次证据层为主机 VM 的生产页面行为测试；未运行真实浏览器、SIP、物理 SOS、设备部署或长期运行资格。嵌入资源与应用版本由主任务整合验证。

T11 尚未实施：heartbeat 仍由成功 state 路径调用，其独立 2000/1500 ms lane、瞬时失败分类、服务端租约剩余时间与退避不属于本卡已完成结果。当前只证明 locale/config 黑洞不会阻止原有 heartbeat 调用；state 黑洞对 heartbeat 的隔离仍待 T11。待 T10 独立复核通过后，主线再验收 T11 的依赖和实现。
