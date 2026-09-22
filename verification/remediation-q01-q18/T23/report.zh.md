# T23 执行报告

状态：IMPLEMENTED_AND_TESTED_PENDING_INDEPENDENT_REVIEW。最终候选 r4；r3 报告与验收已单独保留。验证范围为计划指定的 native_source，计划状态由主 agent 在独立复核后更新。工作日期跨 2026-09-22/23（Asia/Tokyo）。

兼容门口屏此前忽略 Core 缓存年龄，重复读取会延长本地截止点；住户恢复和普通实时 chime 还直接比较 NSDate 与 expires_at_ms。恢复事件可以覆盖当前快照 state/owner。最终实现让这些入口遵守当前 Core 快照，不因设备墙钟偏差漏接来电，也不会将本地倒计时到零解释成取消授权。

## 实现与入口

- 新增 Foundation/ARC `DBCallTiming`。快照持有复制后的 JSON、Core 生命周期代次及请求开始的单调时间；历史系统已有的 mach_absolute_time 投影扣除 snapshot_age_ms 与请求后经过时间。代次不一致、年龄未知、非法时长不会生成有效时长；重复缓存只能缩短原锚，不能续时。
- `DBCoreBridge` 沿用现有 serial queue 调用 C、复制及释放 JSON，快照与恢复上报同时检查捕获的 Core generation。没有扩大为另一次句柄生命周期重构。
- `DBDoorScreen` 从同一快照检查当前 origin/door/state、剩余时长和恢复窗口。未知或到零显示既有“正在检查”文本并复查 Core，不发取消。timer 身份包含对象、Core generation、call ID 和 revision，重复刷新不累积 timer。
- `DBRouter` 恢复事件只选择身份，不覆盖快照权威 state/owner。无法跨进程恢复的本机原生 in_call 仍报告失败；ringing 的未知时间只等待。先筛本门 origin 或本机 dialog_owner，再操作恢复锚，无关门候选不能替换当前锚。
- 持久化住户恢复仍要求已有 targeted 标记。普通实时 targeted chime 现在也先与实际 Core call/door/revision、remaining/age 核对。事件先到而缓存未更新时，按身份等待新的 snapshot_generation；每个身份独立锚，固定十秒 TTL、最多 128 个候选，同一或较旧 revision 不延长 TTL。最多一个异步读取和一个重试 timer，旧 Core 结果不能激活新 Core 候选。无 call_id 的管理测试响铃保留原行为。
- 后台撤销 timer/异步 epoch 并保存新鲜性屏障。前台相同 snapshot_generation 与年龄不能证明休眠后的新鲜性；未知基线的首次读取只建立基线，之后新样本才释放。普通 chime 和恢复路径共用这一约束。
- 删除 `DBIncomingScreen` 中互补 return 后永远不可达的旧 autoClose 墙钟代码。真正使用的 `DBCallReturnCountdown` 本地返回行为、通话期间暂停及结束后恢复均保留；既有生产返回计时测试继续通过。

精确入口见 `entrypoints.json`。未编辑 archival ios-legacy，Info 版本由主 agent 统一递增；未修改 i18n 或计划 progress。

## 反例与四项验收

`source-before.json` 对应的原生产 DBCallEventTracker 副本由 `timing-original-build` 编译，`timing-original-red` 仅执行其原 acceptChimeEvent:nowMs:。Core 仍有效的呼叫在设备墙钟快五分钟时被拒绝，业务断言失败、退出 1。测试程序额外链接的新 helper 仅供绿分支使用，红运行没有执行它。这是原生产方法的行为反例，不是编译失败或复制算法；系统时钟未实际修改。

| 验收 | 实际证据与边界 |
| --- | --- |
| T23-01 | 实际 Foundation helper 与 tracker 在快照墙字段 ±5 分钟时允许有效恢复及普通实时 chime；迟到快照先等待，新样本到达才进入 UI。原生产墙钟反例失败。host 输入注入，不冒称真实设备改钟。 |
| T23-02 | 过期/未知时长不接纳 chime；终态与已接纳 revision 不重新响铃。重复候选不续十秒 TTL；128 容量与过期清理均有实际生产测试。Door/Router 时间路径不推导取消命令。 |
| T23-03 | 实际生产 token 拒绝旧 Core、call 和 timer revision。前台相同代次/年龄仍等待；旧 Core snapshot 不能消耗新 Core 候选，当前 snapshot 正例可接纳。异门/异 owner 候选不改变已有恢复锚。UIKit 闭包经过源码核对和历史 SDK 编译，未冒称旧设备上执行 UIKit 并发测试。 |
| T23-04 | 干净 r4 App 通过实际历史 SDK armv7/最低 iOS5.1 编译与链接，非系统未解析符号为零。Core/Web 输入与干净 r3 Core 构建完全一致，明确复用其已保留归档；没有混用并行修改的 live Core。 |

最终完整 `ios-compat/scripts/test_host.sh` 在冻结 r4 目录退出 0，包含生产时间 helper、真实 tracker、既有 MiniSIP loopback 与兼容测试。新的时间测试输出明确包括 live chime、bounded admission、wall offsets、cache age、recovery、foreground 与 stale callbacks。英文源检查无违规，i18n 15 个生成文件保持当前。命令、真实退出码和原始日志见 `evidence/compat-host-frozen-r4.*`、`ios5-app-frozen-r4.*`；Core 原始干净构建见 `ios5-core-frozen-r3.*`。`acceptance.json` 逐项链接命令和日志 hash。

## 输入隔离与产物身份

`source-candidate-r4.json` 和 `source-final.json` 记录本卡最终输入；真实差异在 `candidate-r4.patch`，相对任务开始副本，保留先前所有修改。HEAD 为 b26e0d346df99f2879915241b6e98d8ef1aa0707，dirty。

并行 T26 修改 Store mutex 时的非冻结 Core/App r2/r3 仅作为开发历史。r3 Core 在 596 文件的独立冻结编译源从空缓存重建，后续完整 host 所需的跨平台 fixture 增补不覆盖原输入。r4 从这一冻结源复制，仅覆盖 T23 修改；1222 个输入在最终两次运行前后全部一致，Core/Web 输入逐项与 r3 相同。归档 SHA 为 `567353487b2721a3508daa69a80b6f384e9ecfd1d0fc44b502e3b48f289ecacb`，保留原 Core manifest 与构建命令，见 `source-frozen-r4.json`、`evidence/source-postcheck-r4.json`。SDK/runtime 是忽略目录的本地依赖。

最终 App **0.3.49 / 52**，**armv7 / minimum iOS5.1**，**ldid-jailbreak** 本地签名，历史 SDK 头来自本机许可的 iPhoneOS7.1.sdk。兼容壳使用 **ios_compat_minisip_uac_uas**，Core 按现有 profile 关闭 PJSIP；这不属于现代 real-PJSIP 资格。App Mach-O、Core archive、两份 manifest 与 host executable 均有保留副本和 hash，见 `evidence/artifacts-final-r4.json`。App SHA 为 `b651b6df3136020768994b9b614b00c77f77e0d01c6a763318a7f9b662fe18c0`。

## 限制与复核

没有安装/重启真实设备、改系统时间、触发门锁/SOS、读取秘密、备份设备或部署推送。Foundation 测试运行在 macOS host；UIKit、老系统运行时与硬件表现仍须各自平台资格。iOS9 armv7 共用源文件，但实际资格由 T45 单独完成，不能以本次 iOS5 armv7 或此前 arm64 构建替代。

独立复核尚待主 agent 执行；没有自行标记 VERIFIED。后续整合 Core 变化需重新构建平台产物；本卡证据只对应已记录的冻结输入。旧 acceptChimeEvent:nowMs: 作为显式兼容方法留给既有测试，生产 Router 的实时/恢复入口均不再调用墙钟 admission。通知日期、媒体时间戳、时钟标签等非呼叫权威用途未在本卡迁移。

## 主任务独立复核

/root 已核对最终 r4 的 13 个本卡输入散列，复核普通实时 chime、恢复、前后台新快照屏障、单调时间、旧回调和有界待解析队列；独立运行冻结 Foundation timing/tracker 测试通过。evidence/review.json 为 PASS，T23 在 native_source 指定范围关闭。iOS 9 armv7 与设备运行仍在后续卡；多呼叫展示协调器仍属 T36。
