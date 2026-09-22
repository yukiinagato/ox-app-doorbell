# T35 Windows 子项报告

状态：**IMPLEMENTED，WPF 目标运行验收 NOT_RUN / BLOCKED_ENV**。没有关闭 T35 全卡，也没有把主机逻辑测试或源码编译当作 WPF 界面资格。

## 修改

访客首页、呼叫、普通离线、通话中的主按钮使用相同底部位置、边距及实测文字所需高度；次级内容、长状态、目的、语言可滚动或换行。普通离线改为中性色；无应答/恢复中状态与目的发送结果分开。保留 purpose_first / ring_then_purpose，跳过目的只隐藏选择，不取消呼叫。

取消与结束捕获输入开始时的 call、Core generation、view revision 和动作类别，拒绝跨呼叫/跨阶段的旧输入。CancelActiveCall 在 in_call 明确拒绝。结束仍走原 SIP hangup，未改开门、室内接听、本地忽略和权限规则。

SOS 滑动保留；Space/Enter 与 UI Automation Invoke 提供确认入口，确认进入同一倒计时。确认、排队的辅助动作、计时回调分别绑定代次；取消、隐藏、卸载、最小化、Core 重建使旧动作失效。旧确认不能确认或撤销新确认。

独立复核 R1 的实际旧 guard 反例显示：物理输入取消且没有 Click 后，残留手势会拒绝下一次合法辅助操作。r3 增加输入 identity；松开、失去捕获/焦点时在 Dispatcher Send 队列异步清理自身输入，保留当前 WPF routed input 内先释放捕获再同步 Click 的保护，旧清理不能清除新手势。新增 4 项生产 helper 回归；真实 WPF 事件顺序仍待目标运行验证。真实 SOS 触发与清除继续由原 Core API/权限处理。

只修改 manifest 中的 8 个 owned 输入。既有 T22 时间/T15 媒体等修改保留。复用已生成 i18n；本批版本由主任务统一为 Windows 0.1.14 / 0.1.14.11，本子项未再次递增。未修改 Core、Web、其他平台或进度表。

## 真实执行证据

- `guard-runtime-r3`：编译并执行实际生产 VisitorActionGuard / SosReviewGuard，19 项断言通过。覆盖持按取消切通话、call/Core 换代、隐藏阶段、可访问当前操作、旧 A/新 B 确认、取消与一次性消费。
- `contracts-r3`：冻结源的既有 Windows XML/源码契约 70 个通过。这是源码检查，未执行 WPF。
- `managed-api-compile-r3`：全部生产 C# 对官方 .NET Framework 4.8 / WPF 引用程序集编译通过，3 个既有警告。生成的 named-field 声明及空 InitializeComponent **仅供 API 编译**；没有 XAML 编译、资源嵌入、应用包、Windows native DLL 或运行时。
- 英文源、i18n 生成一致性和 Windows diff whitespace 均通过；8 owned 输入与冻结 r3 一致。
- r1 快照漏了 multiline read() 引用的依赖，3 个 FileNotFoundError 保留在原日志；r2 增加 6 个只读依赖（后续访问也需要），当时 owned 源未变。r3 是随后独立复核 R1 的修正。该失败不是产品行为 RED，不声称有新功能实施前的可运行 WPF 反例。

完整命令、退出码、时间、输入 SHA 与测试/编译产物 SHA 见 evidence 中 JSON。source-candidate-r3.json 冻结全部 Windows 输入及静态测试跨平台依赖，candidate-r3.patch 是同一 owned 源的最终变更。

## WPF 环境与限制

仅探测项目记忆中已有的 Windows 节点：RDP/SMB 可达，SSH/WinRM/应用 API 不可达。Mac 本机无 dotnet/MSBuild/WPF 运行时；Windows App 的原生 UI 入口被系统锁屏阻止。未更改锁屏或 Windows 安全设置，未读取凭据、部署、打开真实门锁/SOS、扫描网段或备份设备。

因此没有真实 WPF 基线/修改后截图或辅助技术树。`source-only-baseline-tree.json` 仅为原始 XAML 结构，明确不是运行语义树。也没有在 Windows 7/10/11、x86/x64 上完成产品构建、全流程、放大/横竖屏或实际辅助操作验收。表内四项继续 NOT_RUN，等待授权运行环境，不能用 Mono 模型替代。

## 恢复与清理

先通过已有 Windows App / 授权 RDP 在系统正常解锁后访问已知节点；保持既有凭据与安全设置。用 r3 冻结源构建应用，记录实际版本/build、平台/架构、真实 PJSIP 与签名身份，再在隔离/记录式动作网关执行四项 WPF 验收；不得触发真实 SOS/开门。当前没有后台测试进程或设备配置变更。忽略目录保留官方引用包与编译证据以便复查。

## 独立复核闭环

t02_translation 对 r3 的全部 98 个冻结输入核对，独立执行实际 guard 测试 19 断言通过，R1 判定 FIXED；结论 PASS_IN_REVIEWED_SOURCE_AND_GUARD_SCOPE。原反例、绿测与 review 保留在 evidence。该复核没有扩展为 WPF 运行资格，四项目标 UI 验收仍 NOT_RUN。
