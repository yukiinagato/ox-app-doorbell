# T23 执行报告

状态：IMPLEMENTED_AND_TESTED_PENDING_INDEPENDENT_REVIEW。本卡范围 native_source；计划状态由主 agent 在独立复核后更新。工作日期跨 2026-09-22/23（Asia/Tokyo）。

当前源码在门口屏已部分采用 remaining_ms，但忽略缓存年龄、重复读取会延长本地截止点；DBRouter 的持久化住户恢复仍将 NSDate 与 expires_at_ms 直接比较。恢复事件还可以覆盖当前快照的 state/owner，未知结果会被报告为恢复失败。修改直接覆盖当前调用者，没有回退审查提交或编辑冻结的 ios-legacy。

## 实现与入口

- 新增 `DBCallTiming`：Foundation/ARC 实现。快照持有已复制 JSON、Core 生命周期代次与请求开始的单调时间；用历史系统已有的 mach_absolute_time，减去 snapshot_age_ms 及本地经过时间。根/呼叫代次不一致、年龄未知、非整数/布尔/负值/非有限时长均不生成计时器时长。同一缓存只能缩短原锚，不能重新续时。
- 现有 DBCoreBridge serial queue 仍负责 C 句柄调用、JSON 复制和释放；新 snapshot getter 与恢复上报携带 Core generation。背景请求在 dispatch 前捕获代次，最终主线程同时检查请求代次和当前代次；stop/start 更换代次。没有将现代 T20 方案复制成另一次全桥生命周期重构。
- DBDoorScreen 恢复和倒计时读取一致快照，只有当前 origin/door/state 及有效恢复窗口可恢复等待。到零或未知显示既有“正在检查”翻译并每秒复查 Core，不发取消。timer 同时检查对象身份、Core generation、call ID 和 timer revision；重复刷新不累积多个 timer。
- DBRouter 的恢复事件只选择 call ID，不再覆盖快照 state/owner。实际丢失的本机 in_call 原生会话仍按原约定报告失败；ringing 的未知/过期时间不是失败或取消授权。上报去重包含 Core generation。观察候选前先筛本机门、origin 或 dialog_owner，无关门的候选不能替换单呼叫锚点。
- 持久化住户恢复仍要求既有 targeted 标记，使用当前 Core reading 验证有效性，并复用原 DBCallEventTracker 的 revision/终态去重。不会因设备墙钟偏移重新响铃，也不会把快照中的普通其他呼叫当作 targeted 通知。
- 后台撤销 timer 和异步请求代次并保存快照刷新屏障。前台同 snapshot_generation、同 snapshot_age_ms 不能证明休眠后的新鲜性；等到不同快照或 Core generation 才释放。此前无样本时首次读取只作基线。保持既有 ARC、媒体代次、原生 SIP 无法跨进程恢复、Core 十秒恢复窗口及明确用户取消行为。

精确 path:line、未修改的非恢复用途见 `entrypoints.json`。Info 版本由主 agent 统一递增，未修改 i18n 源/生成资源或计划 progress。

## 反例、测试与构建

原始生产 DBCallEventTracker 的副本来自 `source-before.json` 对应文件（保存在忽略目录 before）。`timing-original-build` 编译该真实副本，`timing-original-red` 仅执行其原 acceptChimeEvent:nowMs:：Core 仍有效的呼叫在设备墙钟快五分钟时被拒绝，业务断言失败、退出 1。额外链接的新 helper 用于同一测试文件的绿分支，红运行没有执行；这不是编译失败、字符串扫描或复制算法的反例。系统时钟没有被实际修改。

最终生产来源为 `source-candidate-r3.json` / `source-final.json`，HEAD 为 b26e0d346df99f2879915241b6e98d8ef1aa0707，dirty；相对本卡开始时文件的真实补丁在 candidate-r3.patch，保留此前所有用户/其他任务修改。

| 验收 | 实际证据与边界 |
| --- | --- |
| T23-01 | 新生产 Foundation 投影与 targeted tracker 在快照墙字段 ±5 分钟时恢复有效呼叫；原生产墙钟反例确实失败。host 控制输入，未改真实设备系统钟。 |
| T23-02 | 缓存年龄/经过时间达到零，未知/非法字段、过期恢复窗口不能接受新 chime；同 revision 重复恢复只接受一次。Door/Router 时间路径没有推导取消命令。 |
| T23-03 | 实际生产 callback identity 对旧 Core、旧 call、旧 timer revision 均拒绝；前台同代次/同年龄旧缓存继续等待，新代次才释放。UIKit queue/main 闭包核对来源并通过实际历史 SDK 编译，但没有伪称在 iOS5 上跑了 UIKit 并发测试。 |
| T23-04 | 干净冻结源，历史 iPhoneOS7.1 SDK + 本地兼容 libc++ 构建 armv7 / 最低 iOS5.1 Core 和 App；符号门禁无新系统禁用依赖、非系统未解析符号为 0。 |

完整 `ios-compat/scripts/test_host.sh` 在独立冻结目录退出 0，含生产时间 helper、实际 tracker 去重及既有 MiniSIP loopback/其他兼容测试。英文源检查无违规，i18n 15 个生成文件保持当前。命令、退出码和原始日志见 `evidence/compat-host-frozen-r3.*`、`ios5-core-frozen-r3.*`、`ios5-app-frozen-r3.*`，四项验收逐条链接在 acceptance.json。

## 输入隔离与产物身份

并行 T26 修改 Store mutex 期间的非冻结 ios5-core-r2/app-r2/app-r3 仅保留开发历史，不作为最终 Core 输入资格。最终使用 596 个文件的独立冻结编译源，Core 从空缓存重建；SDK/runtime 只是本地忽略目录依赖。后续补充的跨平台源码用于完整 host fixture，原 596 输入未覆盖。完成后逐文件 hash 均一致，见 evidence/source-postcheck.json。

最终 App **0.3.49 / 52**，armv7 / minimum 5.1，**ldid-jailbreak** 本地签名。兼容 App 的后端为 **ios_compat_minisip_uac_uas**；Core 自身按既定兼容 profile 关闭 PJSIP，不能将其当作现代 real-PJSIP 构建。App Mach-O、Core 归档、两份 manifest 与 host executable 都有保留副本及 SHA，见 evidence/artifacts-final-r3.json。`--install` 只把验证过的 Core 归档复制到冻结树 ios-kiosk/lib，不是设备安装。

## 限制与下一步

没有安装/重启真实设备，没有改系统时间、触发门锁/SOS、读取秘密、备份设备或部署推送。iOS9 armv7 与 iOS5 共享源文件已检查，实际 iOS9 armv7 资格仍由 T45 单独提供；不能用本次 armv7/iOS5 或此前 arm64 构建替代。新的 Foundation helper 运行在 macOS host；UIKit dispatch 与老系统 runtime 的设备证明仍属于平台资格任务。

现有普通实时 chime 的墙钟检查不是本卡修改的持久化恢复入口；DBIncomingScreen 的旧 autoClose 墙钟代码目前位于互补 return 之后，不参与实际本地 return 倒计时。本次不声称整壳全部 NSDate 已迁走，保留原 UI 功能并提交主 agent 复核范围。最终整合若 Core 后续变化，需重新构建候选产物；本报告的来源是已记录的冻结源。
