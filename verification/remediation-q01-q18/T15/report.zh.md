# T15 执行报告

日期：2026-09-23 JST。执行者：`/root/t02_translation`；Windows 最小接收端由 `/root` 实施，本 agent 独立审查。
任务状态：VERIFIED_IN_SCOPE；最终 iOS 严格重复帧断言已由独立 Air 1 UIKit runner 完成，23/23 PASS，详见 `device-uikit-report.zh.md` 与 `evidence/device-uikit/qualification.json`。以下保留原执行阶段记录，原 Simulator 锁屏阻塞不再代表最后业务断言未执行。本机服务端/Web/Windows helper 验收通过，主agent最终独审已通过；共享平台集成构建仍属后续资格。

## 来源与范围

- 执行前 HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`，工作区 dirty，已有用户修改及 T03/T08/T09/T10/T11/T13/T14/T19/T20/T21/T22/T25 等变更全部保留。
- 卡片来源：canonical `tasks/T15.zh.md`、冻结 ADR C02/C05/C06/C07；未把附件文字当作额外部署授权。
- 执行前哈希：`evidence/before-source.json`；当前交付范围：`evidence/after-source.json`；实际独立编译输入：`evidence/frozen-source.json`。
- `evidence/production-diff.patch` 仅包含本 agent 的 T15 修改和获授权修正的旧测试初始化步骤。Node 同期的 T06/T26 变更从归属 diff 中剔除；实际冻结编译候选包含其当时已有内容，因此不把它们归为 T15 成果。Windows 单列 `windows-source.json`。
- 主 agent 统一处理版本：现代 iOS `0.1.37 (38)`，iOS 5 kiosk `0.3.49 (52)`，Android `0.3.21+<revision> (22)`。没有覆盖正式设备应用；最终仅在 Air 1 安装独立 `jp.ox.doorbell.t15uitest` 1.0.0 (2) runner。未触发真实 SOS/门锁、未新增 ABI。

## 生产入口与改动

1. Node `POST /api/panel/session` 建立独立随机 HttpOnly 会话和 CSRF；`GET /api/panel/session` 只读取本会话 CSRF。记录单调时间的创建/明确交互时间，30 分钟 idle、8 小时 absolute、最多128会话，先淘汰失效和最久未交互会话，保护新发会话。首次通过 CSRF 的 answered 算明确交互，heartbeat/GET/媒体更新不续 idle。凭据引用、代次及实际 secret 内容身份均参与失效检查，未宣称 T31 独立 panel provisioning 已实现。
2. 初次 `answered` 将独立会话绑定到服务端 `WebDialogLease.publisher_session`。另一个合法会话即使知道相同 dialog_id 也不能接管、续约或申请媒体发布权。旧 Bearer-only 通话和重启后无法证明原会话的恢复通话安全拒绝媒体发布。
3. `POST /api/panel/media-authorize` 只给本节点 door_station 当前 in_call、call/revision/owner 与绑定会话发短期授权，返回随机32位小写hex generation和1..10000毫秒剩余期限，不超过通话/会话期限。更新产生新 generation，旧授权和旧图失效；不替代 heartbeat。
4. `POST /call-frame` 要求 Cookie、随机 session CSRF、完全匹配的可信 Origin，以及 door/call/revision/generation/sequence。入口和最终 transient peer-frame 写入均查当前权威状态；不使用全局 SIP InCall。序号为1..9223372036854775807的规范十进制字符串，拒绝重复、倒退、符号、前导零及指数。
5. 终止/撤销清除授权和缓存；读取再次验证整个元组、会话/凭据和期限，三秒旧图不可读取。授权最多8个。入口验证1 MiB编码大小及JPEG头尺寸（最多307200像素、各边1024）；此处不是T16严格HTTP reader/worker资源边界的完成声明。
6. `/peer-frame.jpg` 要求当前call/revision及本地门，返回五个身份头。iOS与Windows在请求前保存call/revision/owner、Core与UI请求代次，交付时重查身份和五个头、严格递增序号；旧回调不能清新busy或重新绘图。iOS为iOS9保留 `allHeaderFields` 大小写无关读取。
7. Web取得session CSRF后才能开始受保护通话，初次answered确认后才申请媒体授权，所有媒体请求均为同源相对路径，使用T09 deadline和自己的可取消句柄。未授权/跨节点不启动相机，不回退共享Bearer；失败取消勾选并显示新增三语文案。旧相机权限恢复/track释放逻辑保留。完整四态展示/有限重试仍属于T17。
8. 英文与日文 `webui/panel/API.md`、`API.ja.md` 同步新请求/响应契约。`panel.video_unavailable` 由主 agent 写入 YAML 并全平台生成。

## 验证与反例

完整命令、cwd、exit_code、原始输出位于相邻 `evidence/*.json` / `*.log`，未以源码包含字符串作为行为证据。

| 验收/回归 | 真实执行层 | 结果/原始记录 |
|---|---|---|
| T15-01 A最后一帧在B开始后送达 | 实际Node HTTP入口/缓存；实际MainVC异步图像交付 | 旧A上传409，B读取没有A图；旧A回调不显示且不清B busy。`core-final.*`、`ios-peer-frame.*`、`ios-prior-summary.json` |
| T15-02 另一个合法会话冒充owner | 两个真实Cookie会话+Node HTTP | 申请/上传/重报answered均403，原owner仍可发帧。`core-final.*` |
| T15-03 未到TTL但通话已结束 | 实际生命周期结束+上传+读取 | 上传409，缓存404。`core-final.*` |
| T15-04 已接收10后迟到9/重复10 | 实际HTTP序列检查；实际MainVC；Windows生产helper | 服务端/Windows拒绝重复与倒退；最终 iOS 严格重复/倒序断言在 Air 1 真实 UIKit PASS。`core-final.*`、`windows-frame-host.*`、`device-uikit/qualification.json` |
| generation更新/最大序号/CSRF/恶意Origin/缓存过期/凭据撤销/idle不续期/跨节点拒绝 | 实际Node HTTP | 媒体8个分支及原panel测试合计7 cases、850 assertions PASS。`core-final.*` |
| Web媒体入口和所有原Web回归 | Node VM执行实际call.html与实际runtime模块 | 19套全部PASS，含T10页面关闭零遗留timer。`web-suite.json`及各套log |
| iOS晚回调/owner头/重复/倒序帧 + CoreBridge原生命周期回归 | 原17项为 iOS26.5 arm64 simulator；最终变更为 Air 1 iOS12.5.8 真实UIKit/真实PJSIP静态库 | 修复重复帧严格比较之前真实17 tests PASS（`ios-prior-summary.json`与原xcresult）；最终原MainVC业务断言及实际可见UIImage检查由独立runner完成23/23 PASS（`device-uikit/qualification.json`）。受控网络completion，不等同真实媒体链路，也不冒称重跑17项 |
| Windows接收端 | 生产PeerFrameGate实际Mono运行+既有Windows契约 | 36+70 assertions PASS，主agent运行。`windows-frame-*`、`windows-contract-regression.*`；没有完整WPF运行资格 |
| 旧panel凭据复制/轮换/持久化 | 实际3个admin API用例 | 修复首次登录收敛fixture后558 assertions PASS。`core-panel-auth-final.*` |
| 生成资源/英文源/空白检查 | 实际工具 | PASS，`checks.json`及对应log |

原Node反例在新媒体授权入口要求成功时返回404，记录 `core-red.*`，不是编译错误。此红灯证明原服务缺少新授权契约，并不冒充完整真实SIP旧漏洞攻击演示。iOS重复帧原计划用同一个生产MainVC测试对照，但 `ios-duplicate-red.*` 仅记录启动停滞，没有进入测试，不能作为业务红灯或通过证据。

测试开发中发现并保留三个fixture诊断：dialog_id必须32hex、in_call必须通过ended而非visitor cancel结束、token_generation必须32hex。分别保留 `red-fixture-invalid-dialog.log`、`green-fixture-cancel-in-call.log`、`core-invalid-revocation-fixture.log`；均修正输入并重跑，未放宽生产断言。

额外旧panel复制测试最初因两个节点首次登录各自建立不同管理员凭据而失败；不含T15的red冻结源码也复现（`core-panel-auth-red-control.*`）。获主agent授权后，只将此fixture改为A初始化唯一凭据、B等待同一记录复制后再登录，业务断言保留。原始失败未删除。

曾用到iOS13才有的header便捷方法，被真实旧部署目标编译拒绝后改成兼容实现，失败保留 `ios-peer-frame-ios13-accessor-failure.*`。最终候选在原专用模拟器与新专用模拟器均停在启动阶段；CUA读取Simulator明确返回Mac已锁屏、自动解锁失败。未尝试绕过锁屏；已停止本agent悬挂测试进程，原始记录见 `ios-stalled-launch.*`、`ios-duplicate-launch-stall.*`、`ios-duplicate-red.*`。历史资格 `ios-final-qualification.json` 保留当时阻塞；最终未执行的业务断言已由 Air 1 独立UIKit runner补足，见 `device-uikit/qualification.json`。

compile-only 的 generic simulator 首次构建还暴露既有脚本将 `lipo` 架构集合按字符串顺序比较的问题：相同 arm64/x86_64 集合因顺序不同被拒绝。保留 `ios-generic-architecture-order-failure.*` 并通知主agent；本卡使用明确的 arm64 原资格编译，不宣称 universal simulator 构建通过。

## 资格边界与独立复核

- 本卡只关闭本机媒体发布身份/生命周期与接收画面串线风险。T16的严格reader体积/全流量资源边界、worker/停机/受信节点代理及跨节点加密委托尚未实现或测完；当前跨节点返回明确unsupported，不广告完整 `media_publish_v1`。
- 非loopback读取目前仍允许当前有效dbpanel读取本节点当前通话帧，未按T31独立panel门权限进一步收紧；此边界由主agent明确保留在T16/T31，不能称完整端到端媒体授权闭环。
- 当前shared凭据只是过渡会话身份，不提供独立panel凭据、单panel撤销或PBX账号。原生非Web owner无法冒领Web发布授权。
- Windows由本agent独审，记录 `windows-independent-review.md`（PASS，仅源码+真实helper证据，未运行WPF）。Core/Web/iOS由主agent独审；其指出iOS重复序号应严格大于，已修正并增加真实界面断言。主agent最终独立报告/progress及共享平台集成构建另行归档。
- 最终已在物理 Air 1 上检查生产 UIImage 显示及可见UIKit hierarchy，采集实际view layer画面；未在本卡进行物理iPhone、iOS5硬件、Android设备、WPF Windows整窗或跨节点媒体测试。host/simulator开发用SIP stub与Air 1真实PJSIP静态库来源分别记录，均不直接作为发布资格。

## 下一步

真实MainVC最后严格重复帧子资格已完成，交主agent独审关闭T15范围。完整17项生命周期若未来重跑Simulator仍受解锁条件约束，但不能将其历史结果当本轮重跑。T16的独立实现由主agent安排，T17仍须等待T16前置验收。本文不授权push/tag/release/正式应用部署。

## 通用模拟器构建脚本修正

实际 fat archive 含 x86_64 与 arm64，原脚本却把 lipo 的枚举顺序当成架构不匹配。ios/scripts/build_core.sh 现按排序后的完整架构列表比较，不改变平台/最低系统/后端缓存隔离。使用原始失败中同一冻结 Core 重新运行官方构建脚本，arm64+x86_64/min-12.0 真实组合静态库构建通过；证据 evidence/ios-architecture-order-green.json 与原 ios-generic-architecture-order-failure.log。此修正不表示最后一项 Simulator 行为验证已执行；最后业务断言另由 Air 1 实机资格补足。

主任务最终验收：root-review-final.json 已独立签署指定范围通过，Air1 23/23 最终 UI 检查补足旧 Simulator 未执行的严格比较路径。T15 已关闭，T16/T31 前置满足；不扩大到整机发布或跨节点媒体资格。
