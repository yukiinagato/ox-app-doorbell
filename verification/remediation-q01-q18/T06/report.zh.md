# T06 · 动作 API、查询与跨节点权威

状态：VERIFIED_IN_SCOPE，独立复核 PASS_IN_PRODUCTION_TEST_SCOPE；验证范围：production_test / 本机真实 Core + HTTP/TCP/认证 mesh + MQTT 协议接收器。

本卡不代表全部 50 张任务卡完成。旧 UI、旧 ABI、规则及 SIP 特征码的兼容调用仍在 caller map 中明确登记为较弱的一次性语义；T12、T31、T36 的迁移不能由本卡代为关闭。

## 实施

新增 `POST /api/operations/prepare`、`POST /api/operations/<id>/execute` 和 `GET /api/operations/<id>`，以及三个 additive JSON v2 C ABI。返回字符串沿用 `db_free`，公开 platform/callback 结构体布局不变。

当前管理员会话在 HTTP 工作线程初筛、在 Core loop 实际处理时再次检查，POST 检查准确 Origin 和 CSRF。原生主体由节点身份产生，mesh 主体由已认证 SecureChannel 的 peer ID 产生，客户端不能挑选主体。新增持久化 `devices.<node>.operations` 显式门/SOS 权限，缺省拒绝，最多 64 个不重复门 ID，拒绝未知安全字段与错误类型。接收权威独立重新检查当前凭据和权限版本；管理员声明也不能跳过设备权限。execute 仅创建者，query 在返回任何操作详情前检查实际持久化目标的当前权限。

每个动作固定到配置的门权威或独立全局 SOS 权威。不可达、不支持或不符合当前活动 bridge 条件时明确失败，页面节点不接管。全配置 `config_generation` 使用 T26 的同一 opaque revision helper。配置/权限改变不会把已有意图改到另一把锁。

`OperationDispatcher` 将等待留在 HTTP/native 工作线程，32 个等待者和 32 个异步 mesh 转发分别有界，四秒截止；排队→运行和过期在同一把锁内决定。stop 先拒绝/取消排队并唤醒工作线程，再退出 HTTP workers；请求、完成回调不捕获连接和调用者栈。旧 T04 runOnLoop/Pending 状态机保持不变，新路由显式使用 routeWorker。

权威通过 T05 的已提交 Store transaction 唯一取得 dispatch 资格。新开门直接向当前 MQTT adapter 入队，携带 operation/authority ID，不写会导致重放副作用的 `dtmf_action`。冻结命令和 broker host/port/topic 摘要，活动 adapter 必须匹配；新入队要求已连接、队列少于 256 包、合计包字节不超过 1 MiB。这里证明的是 adapter 入队，不是 broker ACK 或真实门已打开；旧 MQTT 队列整体不在新增容量承诺内。

SOS 只追加一条带 operation/authority ID 的持久化意图事件，保持 `dispatched` 或 unknown，不将本地事件提交冒充真实执行器 ACK。未知结果只查询同一个 ID。

真实 Node 借用 loop 的销毁测试另抓到了旧 `scheduleSnapshotRefresh` 裸 this 延迟回调：Node 销毁后 pump 报 `mutex lock failed: Invalid argument`。新增现有 alive 弱令牌检查后同一个反例通过。没有得到可用调试栈，不能宣称已观察到 ASan UAF；最终 ASan 没有诊断。此相邻修复保留在最终候选。

## 可复现证据

最终源：`source-final.json`，SHA256 `5cc445041f114abd9d9abc27fc5dbccbd67578a38a349f55a6b7f6047eac7217`。16 个拥有的输入逐文件匹配独立 build snapshot；全部实际 build 输入另有 `source-inputs-final.json`。共享 Node/Store 包含主任务的 T26 配置改动，本报告不将其归为 T06 独立成果。

- `red-http-final.json/.log`：保存的 T05 真实生产库 + 同一 HTTP prepare 验收，实际返回 404，进程 exit 1，1 个断言失败。RED 是安全新接口缺失，不是声称观察到真实重复开锁，也不是复制状态机或编译错误。
- `normal-final.json/.log`：14/14 用例，306 断言，exit 0。
- `asan-final.json/.log`：相同 14/14 用例、306 断言，exit 0，无 ASan 诊断。独立 build 目录，C/C++ Core、SQLite/CivetWeb 和测试均带 `-fsanitize=address`；不是仅壳层插桩。LeakSanitizer 关闭，不声称 TSan 或目标设备验证。
- `regression-final.json/.log`：62/62 相关旧测试、1191 断言，exit 0，涵盖 Httpd deadline/stop、Runloop、Store、C ABI 及管理员会话。
- `green-dev-r5.log`：开发期 13/14，通过新增实际 Node teardown 暴露一个异常；`source-candidate-r5.json` 与 `candidate-r5.patch` 保留，拥有的历史源码已重建并逐个 SHA 验证。
- `borrowed-loop-r6.log`：原 Node teardown 反例 1/1、3 断言通过。最终正常/ASan 14 项均再次包含该用例。
- `artifacts-final.json`：保留正常/ASan binary SHA、实际 compile commands、SIP backend、插桩范围。

## 四项验收映射

| 验收 | 实际生产边界与结果 |
|---|---|
| T06-01 | 两个真实 Node 使用 TCP/SecureChannel；HTTP 页面 A 在 B prepare/execute/retry/query。真实 MqttClient 连接本机协议接收器，记录同 operation ID 仅 1 条开门 packet，多次 execute 仍 202、query 仍同 ID/state。 |
| T06-02 | 另一个已认证 native 节点持有明确目标权限，仍不能 query/execute 创建者 ID，返回 permission_denied 且无 execution_state/config_generation 泄漏。额外验证当前权限撤销、CSRF 缺失拒绝，管理员身份不越过 grant。 |
| T06-03 | B 作为固定门权威停止后，A 重试返回 503，不改由 A 执行；接收器原 operation packet 数保持 1。 |
| T06-04 | 客户端读到 HTTP SOS execute 结果后故意丢弃，不把结果交给调用者；通过原 ID query/retry，B 真实持久化 emergency 意图回调计数始终 1。此 fixture 是应用层丢弃已读结果，不伪称已做网络线缆/链路故障。 |

额外反例：生产 HaBridge 仍配置旧 topic 时，冻结到新 broker/topic 摘要的 dispatch 被拒绝、接收器 0 条；实际重配并连接后，相同生产入口接受且收到 1 条。该测试验证配置已提交但 adapter 尚未应用时的固定目标边界，不是源码字符串检查。

32 容量、queued 截止、running unknown、stop 唤醒、外借 loop 晚到回调、native ABI ownership、字段/权限规范、改配置后 409 与改密后 401 都有最终定向用例。

## 文档、兼容与清理

英文 API 及日/中文译文：`docs/en/operation-api.md`、`docs/ja/operation-api.md`、`docs/zh/operation-api.md`；三语 config-schema 同步追加权威/权限规范。`caller-map.json` 登记新 API、原生壳、旧 HTTP、SIP、自动规则、事件消费者及迁移归属。新 capability 仅声明这些实测 v2 路径；未把旧壳或规则称为已迁移。

没有部署设备、触发真实门锁/SOS、修改平台版本、生成资源或计划进度；版本与计划由主任务统一更新。生产测试均使用 SIP stub，只验证这里的动作/权限/生命周期边界。硬件、旧系统 ABI 运行、真实 HA/执行器 ACK 与离线实际通知不是本卡 host 验证结论。

`cleanup.json` 记录所有本次 test/debug 进程已结束、HTTP/mesh/MQTT listener 随 Node/fixture 退出；仅删除本次日志中的节点 ID 唯一匹配且为空的 57 个 fixture assets 目录，不递归删除不明内容。保留正常/ASan 测试 binary、完整 source snapshot、历史 r5 输入和日志供审查。没有改外部设备文档或部署状态。

## 冻结后的主任务邻接变更

最终测试绑定独立 snapshot，不冒称对后来不同字节的整个工作树做过同一轮测试。主任务随后仅在 Node 的已有能力列表加入 `config_cas_v1`（T26）；精确整文件比较确认除此一处无差异，其余 15 个 T06 输入仍匹配。`post-freeze-t26-delta.json/.patch` 保存当前与已测 SHA 和这一邻接变更。该能力标识由主任务的 T26 验证覆盖。

独立复核：`evidence/review.json`，SHA256 `4f1ad83670ab048f38752bc7f1db14f5d1c2c76616465589a4aaf17ea7867388`，由未参与本卡实现的 t02_contract_inventory 复核；acceptance 单向引用该审查文件，不建立相互 hash 循环。
