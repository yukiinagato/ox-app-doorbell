# T15 现代 iOS 真实 UIKit 补充资格

状态：**PASS_IN_REAL_UIKIT_DEVICE_SCOPE**。本补充取代原报告中“最后严格重复帧断言尚未执行”的阻塞结论；不替代整套生命周期、真实媒体网络或发布资格。主 agent 负责最终独审及总进度。

## 设备与独立产物

实际设备为 iPad Air 1（iPad4,2、arm64），设备报告 iOS 12.5.8、build 16H88。测试应用为独立 bundle `jp.ox.doorbell.t15uitest`，版本 `1.0.0 (2)`，最低部署目标 9.0。安装后的 Info.plist 与运行结果均确认该版本；没有将部署目标 9.0 写成实际运行了 iOS 9。

已配对 iPhone 17 的新鲜状态返回 `passcodeRequired=true`，因此没有在其上启动 XCTest、终止正式应用或绕过锁屏。Mac Simulator 的历史阻塞仍保留。Air 1 使用设备记忆中既有 SSH 和应用注册能力安装独立 runner，实际运行 Swift、UIKit、生产 CoreBridge 与 MainViewController。

仅修改冻结副本的 UIApplication 入口、测试 bundle 身份和原生库复用构建阶段。正式生产 AppDelegate 的入口不运行；生产 CoreBridge、MainViewController 和原 XCTest 源文件逐字不变。现有 DEBUG 网络完成与快照钩子提供受控响应；既有媒体禁止钩子阻止相机启动。真实 CoreBridge 在测试独有空目录启动，实际 Core UI 回调在边界截断；没有真实 SIP 呼叫、通知、SOS 或门锁操作。

测试安装不覆盖正式 bundle、数据或配置；没有备份设备文件。读取设备版本及复制 runner 自己产生的 JSON/PNG 仅为测试证据。结束后恢复 `jp.ox.doorbell` 前台，停止测试 PID 1318；最终进程列表不含测试应用。设备没有 OS 重启。

## 来源与构建

- 最后 T15 patch SHA-256：`dd34191170651e9fca4753925a6d6cb43fcd8dbf8dee9774538acf2d19b41b90`。
- 采用 T35-modern r4 冻结树，manifest SHA-256：`92ed542708ffa474244241f9a07ee2933a5c3bd6e74b92204b01f03242d32b7f`，所有列出输入均核对。它含最后严格 `sequence > peerFrameSequence`。
- MainViewController SHA-256：`215b493176ba05cfba69c7dcca31926835c0a8837974c2960d02ad4a765118fc`。
- CoreBridge SHA-256：`6fa79deaaa1f8e83d11837769973374074f95122949f7e2a9c8ad5b7666b85f6`。
- 原测试文件 SHA-256：`cdf68f823c25f8ef093b5b41ff0778b6dad71d0723bce921161fa964f3c8a706`。
- 原生静态库复用该冻结树的 T12 Core、真实 PJSIP、iphoneos/arm64/min-9.0 产物，SHA-256：`2cab55041127a1b9b5927ff0fb95f38f26c9a83cdd9db2b76ec262aeea821811`。未把并行 T28/T29 Core 混入此资格；未声称本轮重新编译原生 Core。
- Xcode 26.6 / SDK 26.5 Debug 设备构建成功。测试 runner 用既有设备支持的 ldid 签名，独立 keychain access group，不作为 App Store/正式发布签名资格。

实际命令及结果位于 `evidence/device-uikit/air1-runner-build-r3.{json,log}`。最终来源、完整签名后产物文件哈希分别在 `source-manifest.json`、`artifact-manifest.json`。可复现工具在 `tools/verification/ios_peer_frame_runner/`，冻结生成树在 ignored build 目录。

## 实际行为结果

**23/23 断言通过，0 失败。** 原 `testPeerFrameLateCallCannotDisplayOrClearSuccessorBusy` 的全部业务断言逐项保留，以异步分步 UIKit runner 驱动原生产方法；额外检查真实 Core 启停、请求存在及 UIImage 已附着可见 window/hierarchy。

| 原测试行为 | 真实设备结果 |
|---|---|
| A 请求绑定 call_id 和 revision；B 创建后继请求 | PASS |
| A 迟到不能显示，也不能清除 B 的 busy | PASS |
| B 响应 owner 不匹配不能显示，且只结束自己的 busy | PASS |
| B 序号 10 正常显示 | PASS，真实 UIImage 非空且在实际可见 UIKit hierarchy 中 |
| 再到序号 10 不重绘 | PASS，UIImage 对象身份保持相同 |
| 随后序号 9 不能替换 10 | PASS，UIImage 对象身份保持相同 |
| 通话结束清图，迟到 11 不能重新显示 | PASS |

`air1-results/result.json` 为设备原始断言；三组 PNG 与 JSON 由真实 UIKit view layer / UIView hierarchy 采集。正常帧是刻意生成的红色测试图片。重复/乱序后 PNG 与接受 10 时逐字同哈希；结束后的 PNG 已清图。此处是实际 UIKit layer capture，不冒称物理摄像机拍摄屏幕或系统级截图，也不把 UIView 树叫作完整辅助技术语义树。

## 保留的失败与限制

首次 runner 构建暴露测试代码误用低部署目标不可用 API，修正仅在 runner，原始编译失败保留。第一次设备运行 29 项中 13 项失败，是 runner 在主 Dispatch block 内嵌 RunLoop 等待，阻塞生产主队列完成回调；其失败原文、截图、manifest 保存在 `air1-attempt-r1/`。这是测试夹具失败，不作为产品业务红灯。build 2 改为每步返回主队列再继续，未修改生产逻辑或放宽业务断言。

本轮不是标准 XCTest runner，也没有重跑全部 17 个 CoreBridge 生命周期测试。既有 17 项 Simulator 证据仍单独保留；本补充只完成最后变更所需真实生产 UIImage/busy/帧身份资格。未验证实时网络传输、相机、真实来电、iPhone 17 实机、现代 T35 全部访客 UI 或后续集成 Core。T16/T31 的权限、资源与跨节点边界仍按原报告保留。

可机器核对摘要：`evidence/device-uikit/qualification.json`。
