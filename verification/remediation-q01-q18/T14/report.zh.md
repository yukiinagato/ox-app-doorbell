# T14 执行报告

日期：2026-09-23 JST（原始运行日志使用 UTC）。执行：`/root/t02_translation`。
状态：IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务独立复核。本任务未修改 progress。

## 来源与范围

在 T13 已完成、T11 已独立复核的共享工作树继续。最终来源见 `evidence/after-source.json`；开始前来源见 `before-source.json`。并行 T08 认证改动属于整合来源，生产差异证据仅提取本卡三个 Node 区域，未归入本卡。

本卡生产差异见 `production-diff.patch`，SHA-256 为 `7ce03b35a43047d3851081ffcc4c79a134bf2a2537f1a19756db7c3c63d19a9e`。

最终 `webui/panel/call.html`：`5aad5a5d646982411eed7dd9952608f906ac37b721e4693b839b7baa603d6953`。
最终 `core/src/node/node.cpp`：`d75fefe49fbb846dc709861fd578979772c9f92533c983db0aa08a742293c0d1`。

生产修改限于 call 页面和 Node 的两个 Web 配置缓存成员、call-info 路由；测试修改为 `core/tests/test_panel.cpp` 和新增 `webui/tests/call_ua_generation.test.js`。未修改 T08 凭据/会话、onConfigChanges、T19 状态快照、全局 runtime、版本或 progress。四个翻译键及版本由主任务统一整合。

## 实现

- call-info 返回 `webrtc.sip_pass_ref` 和随机 128-bit、32 位小写十六进制 `webrtc.config_generation`，并加 `Cache-Control: no-store`。这是该节点有效 WebRTC 连接配置的代次，不是全局 CRDT 提交序号或管理 API 的 expected_revision。内部比较 ws_url、sip_user、secret reference、解析后的实际密码、SIP server 与启动 epoch；同一 reference 的安全存储轮换也变代次，无关门名称变化不变。公开 token 为随机数，不包含秘密或可猜密码摘要。
- 前端保存不可变 desired 配置、当前 UA 配置和已成功注册配置，区分 desired_config_generation、applied_generation 与 ua_generation。缺少服务端代次的旧节点使用私有内存字段比较和本地代次，仍检测密码/reference 变化；不会把秘密写入 URL、日志或界面。当前实际连接字段没有可配置 ICE；本卡未新增未经实现的 ICE 设置。
- 空闲变更先解绑旧 UA 的自有监听器，执行 unregister/stop，并等待断开；2200 ms 边界强制关闭传输后才允许新 UA。关闭状态仍无法确认则显示失败并阻止叠加新连接。正常页面关闭强制清理并保留既有 lifecycle keepalive 顺序。
- 活动通话延后普通配置变更，保留该通话的原配置和媒体，仅保留最新待应用配置。结束后自动应用最新目标。明确 401/403 授权拒绝立即撤销当前页面的通话能力，不受普通配置延后策略限制；旧页面/旧通话请求的失败受上下文校验。
- 注册/连接/失败/断开回调全部检查实际 UA 对象和代次。新分机只有注册成功后才显示已注册。注册初始化上限为 10000 ms；同一失败配置不会被每次轮询重复创建 UA。注册失败时已有媒体通话继续保留，到通话结束后清理。错误提示区分目标分机与上次成功注册分机。
- 已有 T09 请求结算、T10 独立 state/config/locale、T11 租约、T13 焦点保持和通话 identity guards 保留。

翻译键：`panel.config_pending`、`panel.config_applying`、`panel.config_apply_failed`、`panel.config_revoked`。主任务管理三语生成及受影响应用版本/build，本卡不重复修改。

## 实际验证

cwd：`/Users/ox/Documents/project/app-doorbell`。Web 用例加载完整真实生产页面及 runtime，控制 HTTP、时钟和 JsSIP 事件边界；配置接收、延后、关闭、代次判断、UI 和失败清理由生产函数执行。没有在测试中复制 UA 配置状态机。

| 验收 | 修改前业务失败 | 修改后实际结果 |
| --- | --- | --- |
| T14-01 | 空闲改分机/网关仍保留旧 UA | 自动关闭旧 UA 并注册新 UA，只有一个有效连接；ACK 前不显示新分机已注册 |
| T14-02 | 新配置直接覆盖活动通话使用的配置 | 通话不受普通修改影响，明确待应用；结束后仅应用最后一次配置 |
| T14-03 | 没有新 UA 代次 | 新 UA 注册后释放旧 connected/registered/unregistered/failure/disconnected，均不能覆盖新状态；旧监听器清空 |
| T14-04 | 慢初始化期间无法应用最新代次 | 旧 UA 慢退役时合并连续三次变更，只创建最终目标；旧注册成功不能回灌 |

四条 red 命令为 `node webui/tests/call_ua_generation.test.js T14-01` 至 `T14-04`，均真实退出 1，保存 `before-T14-*.log/json`。最终脚本退出 0，日志 `call_ua_generation.log`；红绿测试的来源说明见 `red-source.json`。四项 red 后新增的补充用例另覆盖：10000 ms 注册超时与有限尝试、503 保留/403 撤销、注册错误保留现有媒体、密码与 reference 变化、页面关闭清理、无法确认传输关闭时不创建新 UA。

全部 **18 个** `webui/tests/*.test.js` 实际运行退出 0，逐命令时间、退出码和原始日志见 `web-suite.json`。

Core 以独立 `build/remediation-t14-20260922/host` 配置 `DB_WITH_PJSIP=OFF`、`RelWithDebInfo`。旧生产 Node 加新增真实 call-info HTTP 断言时，缺少 config_generation，实际 1 用例失败（`core-red.log`）。修复后构建退出 0，执行 `doorbell_tests --test-case=panel*`，**6/6 用例、477/477 断言 PASS**。验证了响应代次格式/稳定性、no-store、无关修改不换代、同 reference 密码轮换、reference、分机、网关、SIP server 变化均换代；保留既有租约和生命周期测试。测试 secure store 增加互斥保护，轮换与 Core 读取有明确定序。

主任务将提示修订为“上次注册的分机”后，再次增量嵌入构建和 panel 回归：6/6、477/477 通过，见 `core-build-final-resources.*`、`core-panel-final-resources.*`。

构建命令、结果和日志见 `core-configure.*`、`core-build-red.*`、`core-build-green.*`、`core-panel.*`；编译器、CMake、目标、SIP 后端和二进制哈希见 `core-artifact.json`。限定差异空白、i18n 生成一致性和英文源检查均通过，见 `checks.json`。聚合验收为 `acceptance.json`。

## 限制

本卡是主机生产页面/真实 Core HTTP 行为验收；JsSIP 传输事件采用可控替身，Core 为 SIP stub。未声称真实 PBX 注册、媒体通话、设备浏览器后台行为或目标硬件资格。受影响应用嵌入资源、签名、安装、设备版本确认与综合候选由主任务继续执行。本卡未部署、推送、触发门锁或真实 SOS。

主任务独立审查 PASS，见 `evidence/review.json`；本卡已标为 VERIFIED_IN_SCOPE，未替代后续集成或设备门禁。
