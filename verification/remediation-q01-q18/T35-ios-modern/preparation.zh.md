# T35-ios-modern 只读准备

尚未修改生产 UI，等待 T12 关闭及主任务明确开工。T19/T21/T22/T23/T24 当前均为 VERIFIED_IN_SCOPE；T12 仍 IN_PROGRESS。本子报告仅针对现代共享 Swift 的 iPad/iPhone 门口机，不代表 Android、Windows、iOS5 或 tvOS 已完成 T35。

## 已有语义与布局

- `call_primary` 调用 `onCallClick` → `pressV2`，purpose_first 的目的卡直接带 purpose 发起，ring_then_purpose 先发起再弹目的选择。语言为次级操作。
- `purpose_choice_skip` 只关闭弹层；`purpose_choice_cancel` 在响铃后调用访客取消，不能合并为“忽略”。目的回调已绑定 choiceCallId，晚到回调须继续守住当前呼叫。
- 呼叫页 `calling_cancel` 在居中的垂直栈下方；接通后 endCallButton 在安全区底部，动作位置会移动。取消实际调用 `cancelCall`，结束实际调用 `sipHangup`，不能用视觉复用引入开门或静默切换权限。
- T21 的 Core 单调快照和前台新鲜度屏障已生效；零/未知时间只显示核实中，不允许 UI 自行到期取消。
- 普通 offline 使用中性背景，SOS 独立红色覆盖层。offline 栈目前缺左右边界约束，长文本存在布局风险。
- 目的选择弹层底部固定 68 pt、高度布局没有跟随文字放大；目的卡固定下限和标题高度需要在长中英文与横屏下实测。
- SosSlideControl 保留滑动 + 可取消倒计时，但当前没有 accessibilityActivate，iOS 也没有 primaryActionTriggered 对等入口；该缺口应在同一倒计时路径补齐，不另造绕过确认的入口。

以上是源码核实，不充当实际语义树或截图。原始 runtime baseline 和按钮实际调用验证仍待执行。

## 有界方案与拥有范围

1. 保留首页主呼叫/次级目的和语言，沿用现有 UIKit、主题、semantic manifest。
2. 呼叫和通话使用相同安全区底部动作位置，状态正文单独滚动；明确展示正在呼叫、已接通、无人接听、正在核实/恢复连接。动作标题及权限由实际状态决定，旧访客取消不得隐藏新的 in_call。
3. 修目的选择和 offline 的安全边界、字体放大与纵横排版；普通连接错误仍为中性层级。
4. SOS 的 VoiceOver/键盘激活复用同一可取消倒计时，真实 Core SOS/管理员清除规则保持原语义。

拟拥有：`VisitorScreenView.swift`、MainViewController 的门口机布局/目的弹层/对应动作小段、`SosSlideControl.swift`，必要的 iOS9 兼容排版 helper、`VisitorScreenLayoutTests.swift` 与实际 MainViewController 动作测试。Core、AppDelegate、IncomingViewController、媒体身份/生命周期代码不在 UI 范围。需要的新文案只报给主任务写入 i18n 来源；版本与生成资源由主任务统一处理。

## 基线环境

已按项目记忆只读验证 `ssh doorbell-ipad-air1`，返回 iPad4,2、现有 Doorbell 安装路径和 /var/mobile 容器。未复制应用/数据备份、未安装、启动、重启设备或触发业务操作。该登记不证明屏幕或应用当前版本。

T15 最新资格记录仍说明 Mac 锁屏造成 simulator 测试无法启动；只读设备清单看到 T15 专用 simulator 已 Booted，未操作或关闭它。优先为本卡使用独立 simulator 和真实 UIKit 截图/语义树/按钮测试。若锁屏仍阻止运行，应明确 BLOCKED_ENV，不能用纯源码断言替代 UI 验收。SSH 设备只允许基线读取，本阶段不安装新候选或触发 SOS。
