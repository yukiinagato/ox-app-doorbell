# T07：认证执行器反馈与诚实结果状态

状态：VERIFIED_IN_PRODUCTION_TEST_SCOPE；最终验证与独立复核通过。范围为 production_test；无真实门锁动作、真实 Home Assistant 执行器资格、传感器因果证明或设备部署。

## 合同与实现

先冻结 `docs/en/operation-ack-protocol.md` 及日中译文，再实现默认关闭的 `doors.<door>.operations.ack`。现有 Ed25519 库完成签名验证；公钥、执行器 ID、固定 authority、门、冻结命令及 broker/topic 摘要必须同时匹配当前配置与 prepare 时的记录。签名使用域分隔、字段已严格校验的确定字节；不签 JSON 序列化。消息最多 2048 字节，恰好八个字符串字段，重复/未知字段、retained 消息、错误目标、伪造签名均无权限更新结果。

自检发现既有 Monocypher 的余因子方程允许低阶公钥，并通过实际恒等签名反例确认。配置验证因此补充 canonical y < 2^255−19 与八个低阶点拒绝；sign bit 两种编码均覆盖。固定坐标与 libsodium 1.0.18 官方实现核对，未新增曲线算法。原合同与修订分别保留于 `contract-freeze.json`、`contract-amendment.json`。

只有已取得持久唯一 dispatch 权的原台账记录可进入 `actuator_ack`。该状态表示执行器报告处理了命令；API 同时明确 `physical_state=unconfirmed`。普通门磁、旧 unsigned ACK、准备但未发送的操作均不能升级。重复、乱序与迟到 ACK 不重发命令，也不更新其他 ID/门的记录；未知操作在重启后仍能通过原 ID 的真实签名结果恢复。

配置 ACK 的发送在 4000 ms 单调时间后仍未获确认时变为 `unknown_after_dispatch/ack_unavailable`。MQTT 断线、换端点或撤销 bridge 将待确认发送转为 `transport_ambiguous`；重连不重发。无 ACK 能力的成功发送仅为 `dispatched/ack_unavailable`。反馈观察集合最多 2048 条，断线每次回调最多持久化 32 条；停止取消定时器与扫描，回调保留弱生命周期检查。

测试执行器用独立编码器、测试专用密钥和真实 MQTT 包；参考去重表在模拟动作前持久化 ID，并另存 pending/completed。模拟崩溃留下 pending 时既不重做动作也不发送成功 ACK。它是有界参考测试契约，不是已部署的执行器，不证明端到端严格一次完成。

## 原始反例

`evidence/red-ack.json/.log` 链接冻结的 T06 生产静态库，并用真实双 Node、HTTP、mesh、MQTT 路径发送操作和带签名的包。旧实现发出的命令缺 ACK 协议字段，台账也不进入 `actuator_ack`；两项预期失败，退出 1。这证明此前没有该认证反馈能力，不声称观察到真实门锁误动作。

原始测试源码随后抽出复用并扩展；`evidence/red-provenance.json` 保存逐字重建且与 red manifest 完全匹配的副本与二进制，原 manifest 未覆盖。

## 验收映射

| 卡编号 | 真实验证 | 范围 |
| --- | --- | --- |
| T07-01 | 无 ACK 配置，MQTT 实际接收一包，响应为 sent/unconfirmed；unsigned/sensor-like 包无效 | Core、HTTP 与本机 MQTT 接收器 |
| T07-02 | 两 ID 乱序/重复有效签名 ACK，只更新匹配记录；再次 execute 不发送第二包 | 实际生产台账与网络路径 |
| T07-03 | 从 front 切换到 rear 后投递 front 迟到 ACK；rear ID 保持 dispatched，错误 scope 查询 409 | 操作状态隔离已测；各壳 UI handle 绑定在 T36 继续验收 |
| T07-04 | 发送后断 socket、恢复连接、再次 execute；同 ID 仍只收到一包并显示未知 | 实际 MqttClient 断线/重连路径 |

另测签名/目标/公钥轮换、无效消息、四秒超时后迟到确认、实际磁盘台账重启恢复、准备态不可被确认，以及参考执行器持久去重和未完成记录。

## 来源、验证与限制

最终测试从 `source-final.json` 指向的独立源码快照构建，普通构建与 ASan 构建目录分离。共享 Node/service 在冻结时含主线 T12 panel 认证及已落地配置/notice 工作；它们的内容身份被记录，但不计为本卡成果。之后主线继续修改共享段不会回写已经测试的 source manifest。

最终普通测试 11/11、1370 断言通过；ASan 11/11、1352 断言通过；相关操作台账、HTTP、MQTT、Store 和 C ABI 回归 86/86、17953 断言通过，三次均退出 0。HTTP 轮询包含实际断言，所以不同运行的断言总数随时序变化。命令、退出码、源码与产物 SHA 分别见 `evidence/normal-final.json`、`asan-final.json`、`regression-final.json` 及各自 artifacts 文件。ASan 使用本次 C/C++ Core、第三方 C 库和测试的实际插桩；关闭 leak 检查，不宣称 TSan、设备或历史 SDK 验证。

旧 API/规则/原有多端按钮的迁移仍按 T06 caller-map 及 T36/T12 任务推进；本卡没有把尚未迁移的 UI 宣称为已使用新操作句柄。未实现传感器因果证明或原生执行器固件，未宣称门已打开。版本/资源/总体计划由主任务统一同步，本卡未自行改动。

本轮清理了由日志中本卡 Node ID 前缀确认的 85 个空 assets 临时目录；只用 rmdir，没有递归清理无关路径。所有专用测试/接收器进程已退出，源码快照和证据产物保留。`evidence/post-freeze-mainline.json` 将冻结后主线 T12 认证相邻修改单独列出，没有覆盖测试来源。

独立复核见 `independent-review.md` 与 `evidence/review.json`（SHA256 `d3baaf824a7d06495ccf9dde63fd2d1c405e8008c143386b6a28b594a4ddbc10`）。审查者额外执行已固定产物的三项测试，3/3、160 断言通过；未发现生产阻断，T36 的多壳 UI gate 保持可见。验收只单向引用 review，不形成相互 hash 依赖。

## 主任务范围确认

/root 核对独立复核、全部最终命令记录和当前工作区。T07 冻结后的唯一生产差异为 T12 双 cookie 时选择匹配 panel CSRF 的身份，已另经真实 HTTP 测试和独立复核；差异保存在 evidence/root-post-freeze-diff.patch。T07 在 Core 协议/持久台账 production_test 范围关闭；T36 各壳旧 ACK 不能更新新门界面的渲染验证仍未执行，不作为本卡已测 UI 声明。
