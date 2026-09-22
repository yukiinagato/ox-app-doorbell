# T35 Web 访客门口机子报告

状态：**PASS_IN_WEB_UI_PROFILE_SCOPE / INDEPENDENTLY_APPROVED**。本子报告只涵盖 Web visitor 页面；不会关闭 T35 的 iOS、Android、Windows 或兼容壳，也不把浏览器证据称为真机资格。

## 改动与语义

`webui/panel/door.html` 采用独立滚动内容区与底部动作区。取消、结束、目的先行的返回始终位于底部左侧；现有 SOS 按钮移入独立右侧位置，其事件处理器、两秒按住、键盘取消和辅助技术零 detail 激活继续由未修改的 runtime.js 管理。没有新增访客清除警报或开锁入口。

首页以现有 i18n 的“呼叫”为主动作，门名称为次级文本，语言选择使用现有 catalog；没有新硬编码 UI 文案，也移除了禁止用户缩放的 viewport 设置。目的选择内容可滚动；100%/150% semantic font_scale 与长英文/中文不会推走底部动作。

`purpose_first` 仍等用户选择后才创建呼叫，“返回”不创建或取消 Core 呼叫；`ring_then_purpose` 仍先响铃，再发送指定目的，“跳过目的”不取消呼叫。修复 idle 后台快照错误禁用 preflight 返回的问题。目的按钮内容未变时保留原 DOM 和键盘焦点，跳过后不会被后续 purpose_pending 快照重新打开。

已接通使用“通话中”，继续以当前 call_id 调用既有 hangup；未接通取消继续调用 cancel。已接通或终态隐藏目的选择并拒绝迟到目的动作；终态禁用动作。恢复中与无人应答使用已有本地化状态，不捏造 Core 状态或重置呼叫身份。

普通离线采用中性色。经主任务授权，仅精准修改 `baseWebUiManifestJson()` 的 `status.offline` 默认背景为 `#26313C`，与页面 fallback 一致；保留用户的 semantic 覆盖，不使用 `!important`。没有修改其他 Node 区域或 runtime/call-flow.js。

## 实际基线

`baseline-source.json` 保留修改前页面、runtime、call-flow、三语言 catalog、Node manifest 源与 i18n。实际 IAB 在 320×480、844×390、768×1024、1024×768 检查了英文长门名与 150% semantic 字体，截图和 AX/DOM 记录在工具交互中；不是设计稿。小屏出现横向溢出，目的内容将返回/取消挤出可视区域，固定 SOS 覆盖原内容。

最终基线测试 24 项为 7 PASS / 17 FAIL，见 `evidence/baseline-browser.json`。失败包括 preflight 返回被后台快照禁用、answered 仍显示 Calling、大小屏主要动作裁切/移位、普通故障红色、缺语言选择、恢复状态标题缺失。原始 22 项基线另保留为 `baseline-initial-browser.json`。

## 候选与证据归属

- 开发 r1 为 22 项 21 PASS / 1 FAIL。其 AT 测试继承了同 fixture origin 的旧持久 operation，生产控制器正确走 query，测试却期待一次新 execute。测试夹具随后只在专用测试页清理该测试 operation，以保证每个用例的独立前置。历史失败记录与输入保留；没有把它当成生产 SOS 重复执行缺陷。
- r1 布局断言仅检查 viewport，视觉复查发现 scroll 容器仍能裁切主按钮；r2 加入实际容器边界，再调整小屏字号和间距。r2 的 24/24 实际通过保存在 `final-r2-browser.json`。
- static i18n 检查曾拒绝语言 key 动态前缀，已改为显式引用三个既有 catalog key，保留首次失败记录，不弱化检查。
- 历史 `source-final-r3.json` 指向 `final-source-r3`：在上述候选上增加终态目的隐藏与迟到动作 guard。r3 的 24 项仍保留原测试身份，但 No-answer 用例新增终态目的断言；因此不会宣称其 case hash 与较早基线完全相同。
- 主任务独立复核 R1 发现 Cancel 按下到松开之间接通会改发 hangup。新增实际 mouse/pointer/touch/keyboard DOM 事件、Back→purpose、取消/移出、旧呼叫→下一呼叫共 7 项；原 r3 源出现 7 FAIL，原 24 项仍 PASS，保留 `gesture-red-browser.json` 与 `gesture-red-source.json`。第 7 项首先暴露终态 reset 被每次 poll 延后；计时已改为一次排队，不再反复续期。
- r4 按下时固定 currentCall 对象、call_id、preflight/inCall/terminal，松开时若任一语义变化则不发送；重复键不覆盖原意图，取消/移出标记失效，新的无手势零 detail 辅助激活按当前明确动作执行。真实候选 31/31 PASS，见 `gesture-green-candidate-browser.json`；历史 `source-final-r4.json` 冻结至 `final-source-r4` 并重跑完整浏览器与既有 host 回归。
- 主任务独立复核 R2 继续发现取消手势遗留 intent 会吞掉下一通呼叫首次辅助激活。新增 4 个真实 DOM 用例，r4 为 3 FAIL / 1 PASS；如实保留 `gesture-retirement-red-browser.json`（touch 用例未复现，不称为已复现）。r5 的非键盘取消立即销毁意图，缺少起始意图的 detail=1 仍拒绝；键盘取消记录对应按键，到 keyup 阻止默认激活且拒绝同一事件周期的旧 release，之后新 AT 激活可用。触摸改用明确的事件监听器，并为 4 类输入逐一增加新的同输入 End 正向验证，避免“全部拒绝也通过”。r5 中 35 项为 34 PASS / 1 FAIL：加强后的键盘正向测试误用没有 key 的通用 keyup Event，生产按键匹配正确拒绝；保留 `final-r5-browser.json`。仅修测试为真实 KeyboardEvent 后冻结 r6，生产页面与 r5 完全相同。历史 `source-final-r6.json` 指向 `final-source-r6`，**35/35 实际 PASS**，见 `evidence/final-r6-browser.json`。
- R2 后续独立审查进一步指定“终态禁用按钮后松开，没有 click，下一通首次 AT”序列。对相同 r6 页面新增四类输入及仍按住旧键盘跨通话共 5 个真实 DOM 反例，全部 FAIL；保存 `release-without-click-red-browser.json/source.json`。r7 在 resetCall 退休所有旧非按住意图，只有仍按住的键盘等待对应 keyup；禁用/错目标释放立即清理，键盘释放阻止默认激活及当前事件周期的旧 detail=0。最终 `source-final.json` 指向 `final-source-r7`，**40/40 实际 PASS**，见 `evidence/final-browser.json`；前 35 项保持通过，新增 5 个释放序列也全部通过。
- fixture 从冻结 Node 源提取实际 base/web-only semantic manifest JSON；该源是基线加唯一中性默认值，未混入并行 T29 开发。这里不声称编译或执行了新的 Core C++ 二进制。

## 验收映射

| 验收 | 实测入口/断言 | 范围 |
| --- | --- | --- |
| T35-01 两种 flow | purpose-first press 的 purpose/call_id；ring-first 首次 press、跳过不写、明确 cancel；preflight Back 无 press/cancel | 生产页面真实 DOM 与实际 XHR 回调，服务端受控 |
| T35-02 动作位置与权限 | 16 组合的 ringing/end 底部位置；无 unlock；answered 使用 hangup；16 项按下/松开意图、无 click 释放、手势清理与跨呼叫时序；迟到 purpose 拒绝；终态动作禁用 | 真实 Chromium layout 与生产事件函数 |
| T35-03 普通故障/SOS | 实际轮询失败达到阈值，中性 offline；独立 alert overlay；无访客清除；短键盘按住取消、AT 到既有 operation prepare/execute | 控制网络/状态，没有真实 SOS |
| T35-04 长文本/方向/字号 | 4 尺寸 × 英/中 × 100%/150% semantic 字体；主动作位于 viewport 及 scroll clip 内，至少 44px；取消不被 SOS 覆盖 | 固定尺寸真实浏览器 iframe；另有独立顶层页面截图检查 |

实际顶层 IAB 另外点按了 320×480 英文 purpose-first 的呼叫→选择目的，以及中文 ring-first 的呼叫→跳过目的→取消；可见状态与两个独立动作吻合。最终 calling 视图在四尺寸实际截图检查，中文小屏也检查；测试脚本中的 `.click()` 同样运行真实生产 DOM 事件处理器，不复制客户端模型。

`final-host-regression-r7.json/.log`：4 个 Node.js suite PASS，包含 call-flow、panel i18n、runtime 和全部既有 SOS operation 用例。工作树 English source、i18n 生成一致性和拥有文件 whitespace 检查均 PASS；这些是观察性检查，不冒充整个并行工作树的最终发布资格。

## 限制与清理

所有浏览器测量来自 Codex IAB / Chromium 153。网络与配置快照受控，不能声称真实 Core 呼叫、SIP 音频、iPad Safari、VoiceOver 或 iOS 5 硬件资格；两个真实 iOS 壳的原生任务仍独立。辅助技术用例使用浏览器标准按钮 activation event，键盘用例使用 DOM keyboard event，不冒充真人屏幕阅读器测试。

截图在工具交互中实际查看；当前 IAB 不支持 content export，未声称生成本地 PNG/DOM 文件。`evidence` 中 JSON 是实际浏览器执行结果和明确标注的观察摘要。

r7 专用 fixture 已停止并回收（exit 143 为主动 SIGTERM）；TCP 18769 无监听，全部本任务 IAB 标签已关闭、viewport 已复位，见 `evidence/cleanup.json`。主任务已在 `evidence/root-review-r7.json` 独立签署通过；原 r3 CHANGES_REQUESTED 保留，R1/R2 红绿记录均未覆盖。版本与生成资源由主任务统一管理。本任务不部署设备、不触发实际开锁/SOS、不修改 ios-legacy，也没有 push/tag/release。

最终独审：root-review-r7.json 已签 APPROVED_IN_RECORDED_WEB_UI_SCOPE。root 提出的 held Cancel 变 End、取消手势残留和 disabled release 无 click 三类问题都有实际反例及最终40项通过的闭环；仅关闭本Web子范围，整个T35仍保留其他平台实际验证门槛。
