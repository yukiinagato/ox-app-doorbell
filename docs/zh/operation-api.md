# 持久化动作 API

`operations_v1` 仅声明 Core 已实现并验证 prepare/execute/query；不表示旧平台 UI 已迁移、执行器已确认或物理动作恰好执行一次。完整字段与限制对应 [英文源](../en/operation-api.md)。

每扇门配置 `doors.<door>.operations.authority_node`，全局 SOS 配置 `cluster.operations.sos_authority_node`，值为 32 位小写十六进制节点 ID。未配置、失联或旧节点不支持时明确拒绝，不改由页面节点或其他节点执行。变更权威前必须人工处理所有未决操作；不支持分区自动接管。

`devices.<node>.operations` 保存显式权限，例如 `{"doors":["front"],"sos_start":true,"sos_clear":false}`。省略字段即无权限；门权限不包含 SOS。门列表最多 64 项且不可重复；门 ID 为 1–128 位 ASCII 字母、数字、下划线或连字符。未知安全字段、错误类型、重复字段及无效节点 ID 均拒绝，包括整对象内嵌写入。权限和权威按已有版本化配置持久化并复制。

HTTP 必须有当前管理员会话；POST 还须准确 Origin 和非空 `X-Doorbell-CSRF`。Core 在线程内执行前重查。原生主体取本节点，mesh 主体取认证通道对端；权威重新检查当前凭据版本、权限版本和具体目标权限。管理员声明不能跳过节点权限。execute 仅创建者可用；query 允许创建者或仍有目标权限的管理员。请求不能指定主体。Web SOS 额外允许有效 dbpanel 会话仅调用 sos_start。POST 必须携带该会话的CSRF与准确可信Origin；GET query也须CSRF，若有Origin则必须可信，同源浏览器GET可以省略Origin。有效panel CSRF优先选择panel主体，即使同时存在管理员cookie。主体绑定已认证页面节点与服务器生成的该会话哈希，仅同一会话可执行或查询；共享Bearer本身不能使用此适配。页面每次检查会话期限和凭据绑定，权威独立检查已复制的panel凭据元数据及页面节点的显式SOS权限。分区期间尚未收到的撤销不能立即生效。这是会话身份，不表示独立面板或SIP账号已开通。

prepare：`POST /api/operations/prepare`，JSON 为 `{"schema_version":2,"action":"door_open","door":"front","parameters":{}}`。动作还支持 `sos_start`、`sos_clear`，SOS 不带门。参数只能省略或为空对象。可选 `request_id` 为 32 位小写十六进制，仅关联一次请求，不能去重。prepare 返回随机 `operation_id`、固定 `authority_node`、`config_generation`、`prepared` 和最多 30000 毫秒的剩余有效期。再次 prepare 会创建新意图，不得在响应丢失后自动重做。

execute：`POST /api/operations/<id>/execute`，携带原动作、门、参数及返回的操作 ID、权威 ID。query：`GET /api/operations/<id>?authority_node=<node>&action=door_open&door=front`；SOS 省略门。查询范围只是路由提示，返回前还会检查持久化目标及当前权限。未知/重复字段、超过 8 KiB 的正文被拒绝。

新增 ABI 为 `db_core_operation_prepare_json_v2`、`db_core_operation_execute_json_v2`、`db_core_operation_query_json_v2`，使用相同 JSON，返回字符串以 `db_free` 释放。须在工作线程调用，最长等待四秒；Core 主循环内拒绝阻塞。旧 ABI 布局不变。

结果包含版本、请求 ID、状态及重试建议；已知操作还包含操作 ID、权威和与配置快照相同语义的 opaque 配置代次。query 为 200，已接受/分发/未知 execute 为 202。`dispatched` 仅表示适配器接受，明确 `ack_unavailable`，不表示门已开；`unknown_after_dispatch` 只可查询原 ID，不能再次分发。排队未开始返回 503 `not_started`，已经开始但无响应返回 503 `outcome_unknown`。其他错误：401 认证失效、403 无权限、409 配置/参数冲突、400 无效请求、501 协议不支持、404 未知操作、503 权威不可达或容量/存储故障；正文超限为 413。

本地等待及发出 mesh 请求分别最多 32 项、四秒截止。同一把锁决定开始或过期；工作线程等待，主循环异步处理网络结果。停机先取消排队并唤醒等待者，再等待 HTTP 工作线程退出。回调拥有请求数据，不引用连接或已退出栈；外借循环继续运行也不访问已销毁 Node。

新开门仅在固定权威持久化取得唯一分发资格后直接入 MQTT 队列，不发布可重放的开门事件。冻结命令及 broker/端口/topic 摘要，活动适配器必须匹配；权威也必须符合当前 MQTT bridge 活动条件。新入队需已连接，队列少于 256 包且总包字节不超过 1 MiB；旧 MQTT 路径不在这个新增限额承诺内。入队并非 broker 或物理 ACK；无执行器去重不能保证端到端恰好一次。

SOS 仅追加一个带操作/权威 ID 的持久化意图事件，重试不会追加第二次；`dispatched` 不证明远端提醒已送达。T07 补适配器证据，T12/T36 迁移 SOS/UI。旧 ABI、旧 HTTP、原生壳、SIP 特征码和规则保持明确的一次性尽力提交语义，不承诺跨调用去重、不自动重试未知结果；剩余调用者与迁移归属在 T06 caller map 中登记。
