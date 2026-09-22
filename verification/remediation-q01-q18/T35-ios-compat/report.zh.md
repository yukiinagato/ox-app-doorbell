# T35-ios-compat 执行报告

日期：2026-09-23（JST）  
执行者：t02_translation；独立复核：root 待签署  
任务状态：PASS_IN_ISOLATED_IPAD_UIKIT_SCOPE；生产动作/布局宿主与历史 SDK 构建通过，真实 iPad 1 独立 UIKit 测试包四项共 95/95 通过；完整正式应用集成及系统 VoiceOver/物理旋转资格仍未取得。

## 来源与范围

- 计划：canonical `tasks/T35.zh.md`；前置 T12、T19、T21、T22、T23、T24 由主线验收。
- 执行前/验证 HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`，共享工作区为 dirty；本子任务未提交、推送或发布正式应用；按授权安装单独 bundle ID 的测试包。
- 自有生产差异：`evidence/production-diff.patch`，SHA256 `ecd9ba16b647c528e8ebff84e0702adfcfbf9fbdbe8d6af1cd80595fd75e71a8`。以工作开始时四个生产文件的逐字基线生成，未把此前 T23/T15 的修改算作本次改动。
- 最终来源：`source-frozen-r8.json`，SHA256 `38b3d57366e0f4c574955b726bbe091dc614a616b73932ef82c0e687e126ab00`。1084 个冻结输入在最终运行后逐项未变，自有生产/测试文件与共享工作区一致。
- 受影响应用：共享 Objective-C 壳 `ios-kiosk`，本批版本 `0.3.49 / 52`（由主线统一递增）。iOS 9 armv7 复用相同源码，但其专用构建/签名资格没有通过本报告取得。
- 保护：未修改 `ios-legacy`、现代 Swift UIKit、Core ABI、Router 的 T23 时间/恢复语义、全局版本或 progress。新增四个字符串由 root 在 YAML 中统一加入并生成。
- 最终历史构建采用已验收 T12 `green-source` 的 Core/Web，r2 干净构建的 Core 归档由 r8 复用；Core/Web 输入逐项相同。未把并行 T28 的中间 Core 实现混入 UI 资格。最终集成须重新构建。

## 原始 UI 与真实入口

`evidence/baseline-source.json` 记录生产基线 SHA 与语义；逐字源码位于忽略目录 `build/remediation-t35-compat/baseline-source`。

iPad 1 SSH 可达。只读截屏核实当前安装为 `0.3.23 / 26`，显示 monitor 首页，见 `ipad1-baseline-current-screen.png/json`。获准后仅尝试调试页导航 `visitor`，现装程序没有切页，`ipad1-baseline-visitor.png` 实际仍为 monitor，不能作为访客页截图。导航结束恢复原页面请求的“不存在”状态，并再次截屏核实 monitor 页，见 `ipad1-baseline-navigation.json` 与 `ipad1-baseline-restored.png`。没有触发呼叫、SOS、开门、PIN、配置修改、重启或安装。

生产入口为 `DBDoorScreen` 的实际按钮 targets：`onCall`、`onPurpose:`、`onCancel`、目的选择 UIAlert 委托、`sosSliderDidFire:`、`onEmergencyCancel`。`layoutSubviews` 使用真实生产 `DBDoorVisitorLayoutMake`。`DBSosSlider` 的标准按钮 action/辅助技术 activation 共用实际确认与倒计时函数。

## 改动

1. 呼叫、呼叫中取消、通话中结束共用固定 action rectangle；预留三种 semantic style 中最大的 scale，切换阶段不会移动触控区域。公告、语言、目的、时钟等次级内容独立滚动；语言过多时可横向滚动。目的标题按测量高度排布，目的列表不再在短横屏中被压成零高。
2. 保留 `purpose_first` 的目的按钮/直接呼叫，以及 `ring_then_purpose` 的先呼叫后选择。跳过只关闭选择，不改通话；取消仍调用当前 call ID 的 visitor cancel。Core 拒绝取消时不擅自挂断/退回首页。已接通后的结束仍仅执行原有 SIP 本地结束路径，不发送 visitor cancel，更不调用开门。
3. 取消/结束的物理手势在 TouchDown 时绑定 call ID 与阶段，松手时先清理再核对；接通、换 call 或空闲变为呼叫后的旧手势不执行。TouchUpOutside/TouchCancel 清理捕获。无 TouchDown 的辅助技术激活按当前可见操作执行。
4. 目的弹窗同时绑定准确 UIAlert 实例与原 call ID；接通/回到空闲时撤销弹窗。旧弹窗在新通话或新弹窗出现后返回，不能影响新状态。
5. 恢复检查显示专门的“正在恢复通话状态”文本；已接通、呼叫中、无人接听仍使用已有状态与本地化。取消/结束按钮具有相应辅助技术标识、标签；语言选中状态可读。
6. 普通失败继续使用中性访客界面；只有 Core 的有效 emergency 事件控制 SOS 覆盖层。紧急详情使用 `emergency.active_detail`，不再在缺送达证据时声称家人已经收到通知。原清除权限/PIN 条件与 Core 成功语义保留。
7. SOS 增加辅助技术确认路径。历史 SDK 表明 `accessibilityActivate` 是 iOS 7 API，因此 iOS 5 VoiceOver 使用真实 UIButton 的 `TouchUpInside`；其他支持该方法的系统使用标准 activation。两路均先弹出确认，再进入与滑动完全相同、可取消的 0–10 秒倒计时；0 秒配置仍必须先确认。确认过期、隐藏、脱离窗口或重复回调不会触发。未改为 T36 的操作协议，也不声称该后续卡已完成。

## 验证

所有最终命令的 cwd、环境、起止时间、退出码、日志 SHA 均保存在同名 JSON 中。入口：`python3 verification/remediation-q01-q18/T35-ios-compat/tools/run_build.py <kind> r8`。

| test_id / 证据 | 实际命令或入口 | exit_code | 结果与范围 | 日志 |
|---|---|---:|---|---|
| 旧入口反例 | 实际原生产 selector 编译到 macOS host fakes | 1 | 25 断言中 4 个业务断言失败：拒绝取消仍退出、接通后旧选择、跨 call 旧取消、空闲挂断 | `evidence/selector-red.log` |
| 旧弹窗被新弹窗替换反例 | 精确 production `presentPurposeAlert` 与回调 selector | 1 | 26 断言中 1 个失败，旧 UIAlert A 错用新 B 字段 | `evidence/selector-modal-red.log` |
| 按下/松开阶段竞态反例 | 精确旧 r4 `onCancel` selector 与触控事件 fixture | 1 | 40 断言中 3 个失败：ringing→connected、call A→B、idle→ringing；修复后 40/40 通过 | `evidence/actions-gesture-red.log`、`evidence/actions-gesture-green.log` |
| T35-01 / T35-02 / T35-03 生产动作 | 最终 host 的 visitor selector fixture | 0 | 42 断言；两种流程、跳过/取消/目的、拒绝取消、connected 结束、旧实例隔离、SOS 视觉开关及失败清除状态 | `evidence/host-r8.log` |
| T35-02 / T35-04 布局与模型 | 实际 `DBDoorVisitorLayout.m`、`DBSosSlideModel.m` | 0 | 631 断言；10 种手机/平板横竖屏尺寸、SOS 有无、scale 1/2，action ≥44、次级内容可滚动、状态/action/footer 不相交；滑动与 AT 的 0–10 秒相同行为 | `evidence/host-r8.log` |
| T35-03 辅助动作 | 实际 `DBWidgets` 的确认、按钮 action、arming/tick/reset selector | 0 | 15 断言；首次激活不发出 SOS、确认/取消、一次触发、0 秒显式确认、旧确认/无窗口/隐藏拒绝 | `evidence/host-r8.log` |
| 兼容层原回归 | 冻结 `ios-compat/scripts/test_host.sh`，不跳过 helper 测试 | 0 | 完整脚本通过，含 T23 时间、MiniSIP、媒体、设置、配对、SOS 清除、semantic UI、恢复及 keepalive helper 回归 | `evidence/host-r8.log/json` |
| 历史 Core | `run_build.py ios5-core r2` | 0 | 干净 armv7/iOS 5.1 Core 归档，禁止旧 OS 缺失符号检查通过 | `evidence/ios5-core-r2.log/json` |
| 历史 App | `run_build.py ios5-app r8` | 0 | 变更的 Objective-C 页面重新编译、应用重新链接（复用 r4 已编译且源码未变的其他对象）、armv7/min 5.1、ldid、0 未解析非系统符号，版本 0.3.49/52 | `evidence/ios5-app-r8.log/json` |
| iOS 9 专用 preflight | `build_ios9_armv7.sh --signing jailbreak --preflight-only` | 1 | BLOCKED_ENV；专用许可/SDK/runner 环境未配置，不以 iOS 5 产物代替 | `evidence/ios9-preflight.log/json` |
| i18n / English / diff | 对共享当前源码检查 | 0 | 最终记录见 `evidence/final-checks-r8.json` | 同左 |

旧 footer 回归的局部变量字符串断言因生产几何转移到 helper 而失效；保留失败原日志 `evidence/host.log`，把接线断言改为验证三个真实 layout 绑定，并以可执行生产几何断言保留/加强原“不重叠”要求。r1 Core 曾遇并行 T28 未完成编译；该原日志保留，只是构建历史，未冒充业务 red。

`evidence/final-artifacts.json` 绑定 App、Core、host binary、构建 manifest 的实际 SHA；各次 red 的逐字编译产物及 binary 仍保存在忽略 build 目录，各自 `provenance.json` 记录实际编译命令，可再次执行反例。

## 资格边界与独立复核

本报告的 selector fixture 编译的是未改写的真实生产 Objective-C 方法体，替换的是 UIKit/Core/音频等依赖。它验证分支和实际 API 调用序列，不能证明 UIKit target/action 派发、VoiceOver 朗读/焦点、屏幕阅读顺序或物理触控。

真实 iPad 1（iPad1,1 / iOS 5.1.1）已运行冻结 r8 的实际 DBDoorScreen、DBWidgets、Layout 和本地化代码。测试包 `jp.ox.doorbell.t35uitest` 的设备上报版本为 1.0.0 / builds 10、11、12、14，对应四场 15、10、10、60 个检查，均通过。实际 UIKit 派发、UIAlert 按钮、计时器、字形测量、hitTest 与设备 CALayer 截图证据见 `uikit-report.zh.md` 和 `evidence/uikit-summary.json`。替身仅隔离 Core/外部 Router、音视频和网络边界；正式应用的 bundle/data/config 没有替换，没有真实呼叫、SOS、开门或聊天通知。正式前台与维护 lease 已恢复，测试进程已结束。

横竖屏覆盖为实际 UIView 的横竖尺寸布局，并非物理转动设备。辅助技术覆盖明确属性、标签、实际替代按钮/确认/倒计时，不代表系统 VoiceOver 导航、焦点顺序或语音通过。iOS 9 armv7 及整合最新 Core 的正式应用仍须独立资格；本子报告不关闭整张 T35 或其他平台。

root 已复核 r6 的 R1/R2 手势修复。r8 在真实 UIKit 新增对比度反例后修正无图背景的实际颜色与文字测量不一致，并明确访客/SOS 自定义按钮的 accessibility element/button traits；待 root 对最终差异签署。r4/r6 的旧产物、源和红例均保留。

## 下一步

由 root 整合最终 Core 与各平台资格；本子任务按分工转入 Windows T35 独立复核，不更改全局 progress。

## r6 无访客 call ID 的本地 SIP 手势

两个 nil call ID 可相等，正常本地 SIP 结束继续工作；手势同时捕获本地 action generation，实际 calling/connected/idle 阶段变化时递增，旧手势不能在新 SIP 会话变回相同阶段后执行。r5 真实 selector 新反例为 42 断言中 1 个失败；r6 为 42/42 通过，证据 `actions-nil-call-red.log` / `actions-nil-call-green.log`。完整 host 与历史 App 均 exit 0。iPad 1 独立 UIKit runner 后续验证了实际 miniSipListenerStateChanged → showInCall 的 nil-ID 路径及跨 SIP 会话旧手势拒绝；见目标报告。
