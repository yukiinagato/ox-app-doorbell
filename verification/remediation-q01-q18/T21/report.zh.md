# T21 执行报告

状态：IMPLEMENTED_AND_TESTED；等待主 agent 独立复核，不由本子任务修改计划完成状态。日期：2026-09-22（Asia/Tokyo）。

当前工作区此前已把部分墙钟比较换为 `remaining_ms`，但 `CallTiming` 每次读取旧缓存仍返回完整时长，且恢复路径把未知/零时长直接报告为恢复失败。本次沿当前源码完成迁移，保留 T20 的句柄租约、摄像头/编码器代次以及既有 UI 改动。

## 修复

- `CallTiming` 用 Core 代次、快照代次、call/door/revision/owner/state 绑定单调锚点；减去 `snapshot_age_ms` 和从读取开始计算的本地单调耗时。重复同一快照只能缩短锚点，无效重复字段也不会遗忘既有截止点。
- `CoreBridge.callTimingSnapshot()` 在 T20 的 expected-generation 租约内读取、复制和释放真实 C 状态 JSON，并在返回前拒绝已停止/换代的结果。恢复上报也携带同一 Core generation，在租约锁内复核。
- MainViewController 到零或字段缺失只显示既有翻译“正在检查”，继续查询 Core；计时器不发送取消。完整权威快照中呼叫消失才收起旧界面。恢复事件只选取 call ID，不能用旧事件中的 state/owner 覆盖当前快照；恢复窗口和可恢复性来自 Core。
- 后台与停止会撤销旧计时器及锚点，并保留挂起前 Core/快照代次作为刷新屏障。foreground 对同代次、同年龄的旧缓存只显示“正在检查”；必须收到新快照代次或新 Core 代次才能恢复。若挂起前没有读取样本，恢复后的首次读取只建立基线，下一新样本才释放屏障。回调同时检查 timer revision、Core generation 和 call ID，因此同一编号也不能让旧 Core 回调进入新生命周期。
- tvOS 没有自己的业务呼叫到期墙钟比较；共享 CoreBridge/CallRevisionLifecycle 已实际编译。继续使用最低系统已有的 systemUptime 与 IOSAvailability Timer 适配，没有提高最低系统版本。

精确入口、保留的非呼叫日期用途见 `entrypoints.json`。墙钟显示、公告/配置时间戳、屏保/隐藏管理入口手势，以及室内屏无人操作后的本地返回计时不构成 Core 呼叫到期权限，本卡未改写这些行为。未修改 archival ios-legacy、Core、i18n、版本文件或进度。

## 真实反例与验证

`red-cached-duration` 编译执行修复前的真实 Swift CallTiming helper：快照年龄为 5000 ms 时仍返回 10 秒，预期上限为 5 秒，退出 1。该反例是 host native helper，未冒充 UIKit 或设备测试。

最终来源为 `source-candidate-r4.json` / `source-final.json`；HEAD 为 b26e0d346df99f2879915241b6e98d8ef1aa0707，工作区 dirty，逐文件 SHA 标识保留了先前工作成果的真实输入。

| 验收 | 实际结果 |
| --- | --- |
| T21-01 | 生产 helper 的快照墙字段 ±5 分钟不改变单调剩余时长；缓存年龄、读取耗时、重复样本、零/未知恢复均通过 |
| T21-02 | 实际 MainViewController 冻结真实 Core 同代次/同年龄空缓存仍保留核实状态；只有真实新快照才移除旧呼叫；缺字段只显示核实中 |
| T21-03 | 实际旧 timer 闭包在 Core 重启后，即使 call ID 相同也不能改变界面；真实 C getter 持租约直至复制结束，stop 后结果丢弃 |
| T21-04 | 实际 iOS9 arm64 unsigned Release：minimum iOS9.0、ABI v2、real PJSIP，仓库发布产物校验通过 |

现代 iOS 首轮专项 39/39 通过；最终完整测试 **157/157，通过，新增 14 项**。iOS9 arm64 与 tvOS Simulator 最终增量构建均退出 0。命令、时间、原始日志和限制分别在 `evidence/xcode-full-r4.json`、`ios9-arm64-r3.json`、`tvos-build-r3.json`；4 项验收逐条映射在 `acceptance.json`。

每次运行完成后保存独立 `*-artifacts.json` 和忽略目录中的 App Mach-O/原生归档固定副本，避免把下一次重编后的归档冒充旧运行产物。实际 iOS/iOS9 App 版本 **0.1.37 / 38**，tvOS **0.1.14 / 15**，由主 agent 统一递增。

## 限制与清理

现代测试使用 iOS26.5 Simulator、Debug SIP stub，但租约和前台恢复测试调用真实 Core ABI。iOS9/tvOS 构建链接 real PJSIP；构建成功不代表真实 SIP、媒体、旧系统或设备资格。系统墙钟没有被修改，±5 分钟验证是控制输入快照字段；Core 校正时间本身另由 T19 的生产测试验证。当前 Xcode 对 iOS9 deployment target 有支持范围警告，仓库最低系统/架构/ABI/后端产物门禁实际通过。

测试专用 Simulator 5675591C-491D-4232-9887-B2ECBB030C10 已确认 Shutdown，见 `evidence/cleanup.json`。未安装/重启真实设备、未操作门锁/SOS、未备份设备、未推送或部署。后续设备资格由主 agent 安排，不能由本报告替代。

## 前台屏障补审与历史结果

主 agent 复核指出旧系统单调时钟可能不计休眠，单纯重新读取年龄不足以证明前台缓存新鲜；本次增加上述代次屏障以及确定性的真实 MainViewController 冻结样本测试。r3 全套有一项旧 timer 测试的两条断言失败：测试错误假设恢复后必保留旧页面，而真实 Core 已发布新代次，可以合法移除页面；r4 仅把旧回调前后的实际页面与 timer revision 作比较，保留精确同代次前台测试不变，157 项全绿。r3 与 r4 生产输入逐文件相同，iOS9/tvOS r3 构建依 `evidence/build-reuse.json` 复用，没有重新归属旧产物。

共用 host Swift 测试原来调用已移除静态接口，已改为执行当前生产快照投影；两条 Python 源码约束也同步 Core 快照权威与带代次恢复上报，首次失败日志保留。host 测试仍是 host/源码范围，不替代设备。

最终完整 `ios-compat/scripts/test_host.sh` 退出 0，见 `evidence/compat-host-r2.json`；专用 Simulator 再次确认 Shutdown。

## 最终恢复对象隔离补充（r5）

恢复循环现由生产 `observeRecovery` 在修改单呼叫时间锚点前筛选当前快照中的门、origin、dialog_owner。新增异门、异 origin、异 dialog_owner 三候选的真实 helper 测试，证明相同缓存经过这些候选后，原呼叫和恢复窗口仍只剩原截止点的剩余时间。最终来源 `source-candidate-r5.json` / `source-final.json`，专项 CallTiming + 真实 CoreBridge 生命周期 **28/28 通过**；完整157/157为此前r4历史，r5新增1项，未冒称完整158已重跑。iOS9 arm64 与 tvOS Simulator **r5重新构建通过**，均保存本次产物及原生归档。先前build-reuse只解释历史r3/r4，最终不复用其输入。

T21修改的共用Python检查随后由T23继续修改兼容端断言；T21最终manifest保留其当时输入，Swift生产及测试以r5冻结，T23变更另行验证。
