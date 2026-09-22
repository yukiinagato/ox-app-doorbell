# T11 执行报告

日期：2026-09-22。执行：`/root/t02_translation`。
状态：VERIFIED_IN_SCOPE；`production_test` 四项验收通过，等待主任务独立复核及最终候选整合。本任务未修改 progress。

## 来源与范围

HEAD 为 `b26e0d346df99f2879915241b6e98d8ef1aa0707`，在 T09/T10 已验证的 dirty 工作树上继续。输入来源见 `evidence/before-source.json`，最终受测来源见 `evidence/after-source.json`，独立差异见 `evidence/task-diff.patch`，SHA-256 为 `6fab0bcc06991a82f13a7406023da9af2836542e4f1edbd437f6bbe73fcd47b1`。

本任务精确修改 `node.cpp` 的 WebDialogLease 结构、租约定时器/剩余时间函数与 `/api/panel/call-lifecycle` 路由，以及 `core/tests/test_panel.cpp`、`webui/panel/call.html` 和相关 Web 测试。未修改 T19 状态快照段、T08 管理员凭据/session 段、runtime.js、全局 i18n、版本或 CMake。Node 差异证据仅提取这三处约定范围，未把并行 T08 改动归入本卡。

最终 `call.html` SHA-256：`0424a27b3c52335fcbe7b1c293f28c5ea9b2d65be11fbb1805c0bef30a1605c6`。
最终 `node.cpp` SHA-256：`622b482e68e0677ef1e690d83ae2bb4550487796cc2ce49d2c3131cdbd342f77`。
Node 冻结后再次增量构建；最终 panel 测试结束时本卡来源哈希均未变化。

## 服务端契约

- Web 租约记录增加单调截止点和 stage revision。`lease_remaining_ms` 仅由实时 lifecycle handler 根据当前租约计算，范围 0..10000，并与响应 `call_id`、`stage_revision`、`dialog_owner` 一起返回。保留原有 10000 ms 租约长度。
- 明确区分 `stale_owner`、`call_ended`、`auth_required` 与非终止的 `stale_revision`、`recovery_required`、`persistence_failed`。保留原有 `err` 和 HTTP 状态兼容字段，不再把所有失败折叠成 stale call。
- 即使租约到期后的持久化取消暂时失败、Core 仍保留 in_call 投影，过期 heartbeat/answered 也不能重新取得租约。持久化取消的既有有限重试继续运行，不把重试延迟当成新的授权时间。
- 旧 owner 的 ended 写入仍调用原有精确 call/revision/owner 检查；拒绝不会结束胜者。Core 重启后缺少实时租约时要求既有 recovery，不凭旧请求重新建立所有权。

T19 的 cached status `snapshot_age_ms`、`server_now_ms`、`remaining_ms` 从未被用于续租。前台恢复的 state 只允许恢复 owner 核查，只有实时 lifecycle ACK 可以更新租约。

## 浏览器行为

- 确认接听后按服务端成功响应建立本地租约。心跳拥有自己的 XHR lane、2 秒正常周期、1500 ms 单次 deadline；最后一次请求的 deadline 还受已知租约剩余时间限制。state/config/locale 黑洞不阻挡该链。
- 503、network、timeout、未知 409 或非法 ACK 在原租约内按 500/1000/2000 ms 有限退避，显示控制连接恢复中并保留媒体。明确 stale owner、call ended、授权拒绝只结束精确旧 binding/session。
- 续期截止点采用“该请求的单调发出时刻 + 服务端 remaining”，不采用 ACK 到达时刻。过期、错 call、错 revision、错 owner 或非法 remaining 均不能延长授权；独立 expiry timer 保证所有心跳持续失败时仍会结束。
- 页面隐藏时暂停新所有权请求并取消在途心跳，保留原租约边界。恢复时先获取 Core 状态再核查 owner，旧内存不会直接重新声明拥有通话。页面关闭/结束清理旧计时器和请求；旧成功、旧终止错误及旧 end 回调不能影响新通话。
- answered/ended 同样使用有界生产请求适配器，并保留完整 HTTP/业务错误信息。无新租约字段的旧节点不能被前端猜测为具有完整租约能力。

主任务已加入并生成三语键 `panel.control_reconnecting`、`panel.lifecycle_lease_expired`、`panel.lifecycle_lease_unavailable`；受影响应用版本/build 沿用主任务本轮统一递增记录，本任务不重复修改。

## 实际验证

cwd：`/Users/ox/Documents/project/app-doorbell`。命令、开始/结束时间、退出码、来源和原始日志见 `evidence/*.json`。Web 测试加载完整生产页面及 runtime，控制 DOM、XHR、时钟与 SIP 事件边界；心跳、期限、重试、错误分类和会话隔离均执行生产函数。Core 使用真实本地 HTTP 路由、生产 Node 与可控 SimClock/持久化故障。

| 验收 | 修复前业务反例 | 修复后结果 | 证据 |
| --- | --- | --- | --- |
| T11-01 | 单次 heartbeat 503 立即挂断 | 租约内保留会话，500 ms 后独立重试；延迟 ACK 不按到达时刻续满 10 秒 | `before-T11-01.log`、`call_heartbeat.log` |
| T11-02 | unrelated 409 被当成终止 | stale_revision 保留会话；明确 stale_owner 结束旧会话；旧 end 结果不影响新 owner | `before-T11-02.log`、`call_heartbeat.log`、`core-panel.log` |
| T11-03 | 首次失败就在租约前挂断 | 失败仍保留媒体，原 10000 ms 边界正确退出，不无限续权 | `before-T11-03.log`、`call_heartbeat.log` |
| T11-04 | 新 binding 没有服务端租约边界 | 新通话使用自己的剩余期限；旧成功/终止响应不续租或结束它 | `before-T11-04.log`、`call_heartbeat.log` |

四项修复前命令为 `node webui/tests/call_heartbeat.test.js T11-01` 至 `T11-04`，均以业务断言失败退出 1；修复后完整脚本退出 0。开发过程中曾补齐夹具缺少的 `webrtc` 数据；正式 red 证据在该夹具问题修正后、生产改动前采集。

Core 修复前反例命令：`build/remediation-t11-20260922/host/doorbell_tests --test-case=panel dialog lease retries a failed durable recovery cancellation`（完整 test-case 是单个参数）。实际 1 个用例失败、13 条断言失败：包括缺少身份/期限字段、错误码不明确、过期心跳复活租约。日志 `core-red.log`，元数据 `core-red.json`；当时的测试二进制另存 `build/remediation-t11-20260922/red-doorbell_tests`。

修复后以 `cmake --build build/remediation-t11-20260922/host -j4` 构建，再执行 `doorbell_tests --test-case=panel*`（同目录），**6/6 用例、441/441 断言通过**，退出 0。验证覆盖了真实 lease 响应身份/范围、错误分类、时钟墙钟偏移、过期但持久化取消待重试时拒绝续租、旧 owner 不结束胜者、既有面板/recovery 行为。

全部 **16 个** `webui/tests/*.test.js` 脚本实际执行且退出 0，记录在 `web-suite.json`。新增补充断言覆盖 call/revision/owner 不匹配、remaining 越界/类型错误、授权拒绝、休眠前后台、实际 timeout、迟到响应不释放新 pending。T10 的 fixture 现显式提供预先取得的 server lease，再验证 locale/config 与心跳独立，不再依赖旧 state 成功时顺带调用心跳。

生产 inline script/runtime 语法、限定差异空白检查及 `tools/gen_i18n.py --check` 通过。Core 构建配置与二进制 SHA-256 见 `core-artifact.json`。聚合验收为 `evidence/acceptance.json`。

## 限制与下一步

这是主机生产路径验收：Core 为 DB_WITH_PJSIP=OFF 的受控测试构建，浏览器行为由 Node VM 执行。不代表真实 SIP/音视频、真实浏览器后台计时、设备部署、签名安装或现场长期运行已通过。未执行任何物理动作或真实 SOS。

T08/T04/T19 与本卡的最终整合候选、全量 Core 回归、嵌入资源和应用资格由主任务统一记录；本卡只主张上列实际已完成的定向结果。等待独立复核后再推进主线后续任务。

主任务独立源码复核与16套Web重跑PASS，见evidence/review.json及independent-web.json。Core T08认证相邻变更另有集成测试，不把旧哈希冒充当前全部源码。
