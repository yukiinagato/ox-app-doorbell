# T35 — Android 访客端子报告

状态：**PASS_IN_API35_UI_AND_HOST_BUILD_SCOPE**。不关闭 T35 总卡。API35 arm64 原生界面已执行；API19 与物理 Android UI 未取得资格。前置 T12/T19/T21/T22/T23/T24 在 canonical progress 均已 VERIFIED_IN_SCOPE。

## 实际变更

呼叫、取消、结束共享底部固定动作区域。时钟、公告、目的和语言为可滚动的次级内容，长文字按实际宽度换行，大字体时目的按钮改为单列。普通离线为中性背景；已有呼叫恢复时显示“正在恢复连接”，暂停动作等待 Core。无人接听及呼叫被拒绝的提示位于固定动作上方，避免在滚动内容里不可见。隐藏维护入口缩到其实际触控范围，不再覆盖次级按钮。

目的先行和先响铃两种模式保留原 CallFlow 行为；跳过目的、取消呼叫、结束通话保持不同含义。新 VisitorActionLatch 在按下时冻结 call_id 和阶段，抬起前变成另一呼叫或阶段时不执行，避免同次手势由取消变成结束。既有 in_call 权限仍由真实 callFlow/Core 负责。

SOS 辅助技术点击和键盘进入原生确认，确认后复用滑动的可取消倒计时。真正离开界面或暂停时取消本地待触发动作；已有告警显示与管理员清除入口没有改动。i18n 使用单一来源已生成的 visitor.restoring、sos.accessibility_*，本子项没有新键。版本由本批统一递增；实际 APK 报告 **0.3.21+b26e0d3 / build 22**，未重复增加。

独占变更为 MainActivity、Dashboard 的 SOS label 接线、VisitorLayout、activity_main.xml、SosSlideView/State、新 VisitorActionLatch 与测试。build.gradle.kts 仅增加专用 instrumentation runner。未更改 canonical Core、Web、Windows、进度表或 archival ios-legacy。原有用户与其他任务修改已保留。

## 可复核来源与基线

`source-before.json` 保存修改前输入；源码树记录明确不是运行证据。随后从保存的原始 UI 输入重建基线，在同一专用 API35 模拟器实际运行并保留 `evidence/baseline-r4-portrait-1.0/` 的截图、真实 View 树、命令与结果。基线可见呼叫和取消按钮位于不同位置，以及目的卡窄屏裁切。`source-baseline-runtime-r4.json` 将这次基线绑定到精确输入及测试运行器。

最终 `source-candidate-r6.json` 冻结整套输入；`owned-inputs-r6.json` 为本卡十个文件。`final-owned-input-check.json` 确认 canonical 十项与冻结构建均一致。构建使用主任务指定的 **T12 green Core**，仅叠加已授权的公告期限 `int64_t` 类型转换，避免混入并行 T28 事务开发。该类型转换也已由主任务修入 canonical；本卡未自行改 canonical Core。后续 Core 集成仍需重建。

## 已执行验证

- modern r6：完整 armeabi-v7a、arm64-v8a、x86_64 APK 及测试 APK，**386/386 JVM 测试、lint、构建通过**；Java21、NDK27.1.12297006。
- legacy19 r6：独立项目和 native cache，armeabi-v7a API19 APK，**386/386 JVM 测试、lint、构建通过**；NDK25.2.9519653。
- 实际 API35/Android15 arm64 模拟器：竖屏/横屏 × 字体1.0/2.0，**4组各5项，共20项通过**。每组保存截图、真实 View 树、instrumentation 原始日志、命令、APK hash 和来源标识。横屏与竖屏大字体的主要按钮、无人接听提示和 SOS 确认截图已人工查看，无裁切或重叠。
- `gen_i18n.py --check`、`check_english_source.py` 与 Android 范围 diff whitespace 检查通过。

`evidence/artifacts-final.json` 记录 APK、各 ABI 动态库、PJSIP 依赖与 JUnit 来源 hash。独立保存 JUnit XML，APK 为 debug 签名且已验证签名；两条 lane 均链接 real PJSIP。不能以链接成功声称本次测试执行了 SIP。

| 验收 | 实际证据 | 限制 |
| --- | --- | --- |
| T35-01 | 实际 MainActivity target listener + 生产 CallFlowController，在两种模式断言 press/select/skip/cancel 的记录 | gateway 为测试记录器，Core 未创建 |
| T35-02 | 真实 View down/up 跨 ringing→established 后零误操作；新点击恰好一次 hangup；前后按钮 bounds 相同 | 未接真实 SIP 或门锁 |
| T35-03 | 中性恢复层、禁用待恢复动作、Accessibility ACTION_CLICK/键盘确认、滑动同倒计时、取消均真实执行 | **Core 活跃 SOS overlay/管理员清除未执行**；既有入口未修改，不将此项扩大为真实告警全流程资格 |
| T35-04 | 两语言长按钮、四屏幕字体组合；实际屏幕坐标触摸 call/cancel；可见 bounds/最小尺寸；执行生产 timeout Runnable 后固定无人接听提示 | API19 UI 与物理辅助设备未执行 |

测试使用 Android 真正的 MainActivity、framework View、AlertDialog、UiAutomation 截图和 View 树。运行器在 App 正常初始化后以测试替身接管 call gateway/SOS 回调，始末断言 Core 保持未创建。没有连接真实门锁、触发真实 SOS 或部署到物理设备。

## 历史失败与清理

历史 r1 构建暴露公告期限 long long 的 Android 重载歧义，已由主任务确认修复。初期运行器在 Application 初始化前读取状态、等待持续动画 idle、以及在原生 AlertDialog 异步回调前立即断言，属于保留日志中的测试问题；最终改为初始化屏障、frame 同步与异步回调后断言，不将这些结果改写为产品缺陷 RED。r6 增加固定无人接听 strip 和生产 timeout 路径；最终证据全部来自 r6，未用 r5 的通过代替。

专用 AVD `doorbell-t35-api35` 已停止，字体设置恢复1.0，测试 app 已 force-stop。标准 SDK runtime 与该独立 AVD 保留便于后续验收；没有操作物理设备、重启用户设备或删除其他任务产物。`acceptance.json` 是本子项验收索引；最终资格范围和未完成项以其明确限制为准。
