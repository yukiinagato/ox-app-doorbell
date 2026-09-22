# T35 — iPad / iPhone 门口机子报告

状态：**IMPLEMENTED_PENDING_UI_RUNTIME**。本子任务没有关闭 T35 总卡，也没有取得真机或 tvOS UI 资格。Mac 锁屏仍阻止受支持的 UI 访问，下面的 XCTest 目前仅编译，不能当作已执行的按钮、截图或可访问性验收。

## 当前变更

- 首页保留主呼叫入口，目的和语言保留次级位置；`purpose_first` 和 `ring_then_purpose` 的 Core 调用与选择时机保持原合同。
- 呼叫取消、通话结束采用同一安全区底部位置。状态内容独立滚动；动作字号跟随可访问性字体，并按实际标签长度增加高度。接通前后不会把访客取消替换成开门。
- 访客取消先检查本地通话状态，再尊重实际 Core 返回值；Core 已拒绝的迟到取消不会把界面渲染成 idle。隐藏的通话结束入口不能结束响铃。
- 首页目的卡按实际宽度测量文字高度。目的选择页标题、提示和卡片可滚动；窄屏的“跳过用途”留在滚动内容内，“取消呼叫”固定在底部，两者保持不同回调。普通离线页仍使用中性背景；真正 SOS 使用独立警示层。
- 不可靠或正在恢复的通话快照使用 `visitor.restoring`。继续沿用 T21 的 Core 单调时间和前台新鲜度屏障，零/未知时间不是 UI 自行取消的指令。
- SOS 的 VoiceOver / primary action 先显示确认，再进入原有可取消倒计时。键盘入口复用该操作。过期确认有 revision 检查，控制被禁用或真正离开窗口后取消待处理动作；同一布局帧的重挂不会误取消正在进行的倒计时。Core SOS/管理员清除合同没有改变，原生 operation API 迁移仍属于 T36。
- iOS 11 以上使用 `UIFontMetrics`，iOS 9 使用可用字体适配；没有提高 deployment target，也没有复制另一套 iOS UI。

本卡拥有五个文件：`MainViewController.swift` 的门口机 UI/按钮段、`VisitorScreenView.swift`、`SosSlideControl.swift`、`IOSAvailability.swift` 的字体 helper、现有 `VisitorScreenLayoutTests.swift`。CoreBridge、摄像头/编码器生命周期、AppDelegate、IncomingViewController 未修改。版本和四个 i18n keys 由主任务统一管理。

## 基线与环境

实施前的五个源码、相关测试、工程和 i18n 源已保留，见 `evidence/baseline-source.json`。该文件明确记录没有获得运行截图或 AX 树，源码不是视觉证据。后续解锁时应先由这份保留基线生成实际 UIKit 基线，再与候选对比。

通过项目记忆规定的 SSH alias 只读查询现有 iPad Air 1：iPad4,2，已安装 `0.1.36 (37)`，其 bundle 最低系统为 12.0。见 `evidence/air1-readonly-profile.json`。这只是已安装版本盘点，不是本候选部署或当前屏幕验证。没有备份应用/数据、安装、启动、重启设备，也没有触发真实开锁或 SOS。

CUA 请求 Simulator 返回 Mac locked 且无法自动解锁，记录在 `evidence/ui-environment.json`。没有尝试绕过锁屏，也没有接管 T15 专用 simulator。

## 编译证据的范围

- `compile-r1` 是工作树开发编译；Core 当时有并行改动，不作为最终源资格。
- `source-r2.json` 冻结 **T12 已通过 Core / Web / assets**，叠加本卡 Swift 与当前生成资源。正常 iOS test bundle、iOS 9 arm64 Release、tvOS simulator 三项均编译成功；每项有命令 JSON、日志及 App Mach-O / native archive / manifest 哈希。两条非 iOS 测试 lane 使用 real PJSIP；iOS simulator 测试 bundle 使用明确允许的 Debug stub。
- `source-r3.json` 是最终拥有范围候选：在 r2 上补同帧 SOS 重挂与真正拆离边界，及对应 UIKit 测试。最终三项构建结果见各 `*-r3.json`，运行测试仍未执行。
- 固定 Core 避免把并行 T28 半成品混入 UI 构建。后续主线合并必须重做集成构建；不能用本卡冻结构建为随后 Core 改动背书。

## T35 验收映射

| 验收 | 新增真实生产入口 XCTest | 当前证据与缺口 |
| --- | --- | --- |
| T35-01 两种模式语义不变 | `testPurposeFirstButtonSendsPurposeAndCancelEndsOnlyThatCall`；`testRingThenPurposeSkipPreservesCallAndCancelRemainsSeparate` | 调用实际 UIKit target-action 与新临时目录中的真实 Core，测试已编译，**NOT RUN** |
| T35-02 动作位置/权限稳定 | `testAnsweredCoreRejectsQueuedVisitorCancelBeforeSIPUIArrives`；`testCancelAndEndKeepTheSamePositionAcrossProfilesAndLargeText` | 实际 Core answered/rejected cancel；SIP UI 事件受控注入，不声称真实 SIP 对话，**NOT RUN** |
| T35-03 普通错误/SOS层级与无障碍护栏 | `testOfflineAndSosAreDifferentLayersWithoutClearingCoreEmergency`；`testSosAccessibleActivationRequiresReviewAndCanCancelTheSameCountdown`；`testDetachedSosCannotActivateAndLosesPendingCountdown`；`testResponsiveReparentingKeepsTheExistingCancellableCountdown` | 实际 UIView/UIAlert/倒计时，SOS 仅 UI 输入和本地回调计数，不向物理设备发送，**NOT RUN**。UIAlert 确认按钮实际交互及 VoiceOver/键盘焦点仍待 runtime 验收 |
| T35-04 中英文长文/大小屏/大字体 | `testLongPurposeLabelsAndLargeTextKeepCancelVisibleInBothOrientations` 及位置测试 | 320×480、844×390、768×1024、1024×768；最大可访问性文字档，**NOT RUN**。约束可满足性必须由执行测试确认，源码审查不能替代 |

现有 VisitorScreenLayoutTests、PurposeChoiceLayoutTests、Clock/CallTiming/CoreBridgeLifecycleTests 也需在解锁后回归。不得把以前 T20/T21 已通过的运行计数搬到本次候选上。

## 待完成与清理

1. 解锁后先保存保留基线的真实截图和语义证据；再运行候选完整 DoorbellTests、观察真实按钮动作、记录原生视图树及 VoiceOver/键盘交互。
2. **R1 / 未解决的布局验收风险**：`inCallTitle` 仍使用顶部约束；最小横屏 + 最大字体时，其下缘与固定结束按钮可能重叠。当前位置测试只证明按钮边界，尚未断言标题与按钮不相交。解锁后实际执行并补该断言；若重叠，将标题放入结束按钮上方的滚动区后冻结/复验。source-only 审查不能签署完整布局通过。
3. 汇合主线最新 Core 后重建受影响 target；物理设备验收按主任务授权和现有设备规则执行。
4. 本卡没有创建/启动新 simulator、没有设备部署，没有后台服务或网络测试执行器。构建产物、日志及冻结源保留供复核；不删除其他任务的设备或产物。
