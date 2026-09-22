# T35 兼容端真实 iPad UIKit 验证

2026-09-23 JST，t02_translation。结论：**PASS_IN_ISOLATED_IPAD_UIKIT_SCOPE，四项共 95/95 检查通过**。生产冻结为 r8，完整 SHA、测试程序与每张图片/语义记录的 SHA 见 `evidence/uikit-summary.json`。不据此关闭所有平台或正式应用端到端资格。

## 运行对象与隔离

- 真机：iPad1,1，iOS 5.1.1；基线系统 build 9B206。通过已授权的内网 SSH 安装独立 `jp.ox.doorbell.t35uitest`。设备结果直接报告 bundle、版本、build、进程 ID、系统版本和生产来源 manifest。
- 测试程序：1.0.0，四项设备 build 分别为 10、11、12、14。编译的 DBDoorScreen、DBWidgets、DBDoorVisitorLayout、DBTexts 等全部来自冻结生产源码，未改写方法体。
- Core、Router 的外部动作、音频、网络为边界替身；不链接 Core 库、生产 CoreBridge/Router、SIP 或音频实现。fixture 使用 `videoSource=none`，无外部 URL、设备凭据或秘密。测试触发只记录在进程内，没有真实呼叫、SOS、开门或家庭通知。
- 正式 Doorbell bundle/data/config 未替换、未备份；只读回收测试程序自己生成的 JSON、日志和 PNG。未重启 OS/SpringBoard。正式进程曾由系统/keepalive 生命周期重新启动，因此不声称 PID 不变。
- 最后已请求正式 `doorbell://` 前台、收到维护 lease end 的 `ok:true`，再结束测试包的精确 UIKit 进程。见 `evidence/uikit-green-case4/device-actions.log`。

## 实际验收

| test_id | 真机检查 | 数量 | 结果 |
|---|---|---:|---|
| T35-01 | purpose_first 目的选择、禁用目的隐藏、取消；ring_then_purpose 实际 UIAlert 跳过与选择、保留既有通话 | 15 | PASS |
| T35-02 | call/cancel/end 固定区域；按下 ringing、接通后松手不得结束；新操作可结束；无 visitor ID 的 SIP 通话可结束、旧手势不能跨新 SIP 会话 | 10 | PASS |
| T35-03 | 普通失败保持中性页面；真实 emergency 事件控制覆盖层、清除经过 PIN 边界；实际 SOS 替代 UIButton → UIAlert 确认 → 原倒计时 → 边界只触发一次 | 10 | PASS |
| T35-04 | 中英日 × 768×1024/1024×768 × scale/font_scale=2；真实字体测量、主操作 hitTest、固定取消区域、明确标签/按钮辅助属性、对比度、取消返回 | 60 | PASS |

关键原始记录为 `evidence/uikit-green-case1` 至 `uikit-green-case4`。截图通过真机 UIKit CALayer 渲染；JSON 是相同实际 UIView 层级的 frame/bounds、文本、可见性、辅助属性、target/action 和滚动尺寸。它们不是宿主几何截图，也不是系统辅助功能树。

## 发现及红绿证据

1. 冻结 r6 在 `display.theme.bg_color=#111820`、白天默认 light appearance 时，把浅色 `palette.surface` 绘为背景，却按深色配置计算白色提示文字。实际截图显示提示难以看清。r8 在无摄像头/背景图时调用既有 `setRenderedFlatBackgroundHex:`，让实际底色、前景计算一致；safe mode 仍忽略配置背景。
2. 旧系统在 VoiceOver 关闭时，custom UIButton 的默认 `isAccessibilityElement` 为 false；独立标准按钮显式设 YES 的探针返回 true。访客实际按钮及 SOS 替代按钮现在显式设置 element 和 button trait；没有改变目标方法、确认或权限。

`evidence/uikit-red-case4` 使用 r6 生产，单个英语竖屏大字场景 10 项中对比度/辅助按钮两项失败；r8 的六组尺寸语言 60/60 通过。此前完整 runner build 6 的 76 项/6 个辅助属性组合失败保存在 `uikit-device-r8`，没有覆盖旧失败。

早期测试器存在 UIAlert 搜索范围、KVC 字段名、倒计时 fixture 路径错误，修正测试后再采集。部分多场连续挂载的测试进程中断，无对应 own CrashReporter 文件；其中一次是收集后过早恢复正式前台，另一次原因未确定。这些不算通过。最终四场分别独立启动并等待本场 `result.json`，结果、设备 build 和来源 manifest 逐项一致；没有靠复用旧结果补全缺失场景。

## 构建与复现

测试构建入口 `ios-compat/tests/uikit_visitor_runner/build.py` 接收冻结 source、source-manifest、case 和测试 build-number。实际命令及编译输入/二进制 SHA 在各 `build/remediation-t35-compat/uikit-runner-green-case*/manifest.json`；测试器自身源码副本也保留在对应忽略目录，manifest 中的源码 SHA 与副本逐字一致。

设备操作入口 `device.py` 的 install/wait/collect/restore/stop 命令与退出码记录在各场 `commands.json`。只操作测试包自己的目录和控制必要的前台/维护 lease。正式候选历史 app 未在设备安装；历史 SDK r8 App 构建 exit 0，完整 r8 host exit 0（42 visitor selector、631 layout/SOS model、15 SOS selector 及原兼容回归）。冻结的 1084 个输入在完成后逐项 SHA 无变化。

## 明确未覆盖

- UIControl 事件通过真实 UIKit `sendActionsForControlEvents:` 派发，并非物理 HID 注入；对 UIView 执行实际 hitTest。
- 横竖覆盖为实际 view 的两种 bounds，不声称设备物理旋转、系统 orientation 生命周期通过。
- VoiceOver 运行时关闭。实际替代按钮/确认/计时器与辅助属性已测，系统 VoiceOver 导航、焦点顺序、朗读未测。
- 无真实外部 Core/SIP/音视频动作；正式应用与最新 Core 的完整集成、长时间驻留，以及 iOS 9 armv7 专用签名/硬件资格仍独立保留。
