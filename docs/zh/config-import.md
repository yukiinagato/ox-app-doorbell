# 配置暂存导入

导入复用管理员认证、配置校验、LWW 和 SQLite 事务，不扩大普通 batch 的 256 项限制，
也不接受外部文件路径。

`POST /api/config/import/{stage,preflight,commit,cancel,query}` 每次均要求有效管理员会话、
可信 Origin 和 `X-Doorbell-CSRF`。新增 ABI `db_core_config_import_json_v2` 同样要求
会话与 CSRF；返回 JSON 由调用者使用 `db_free` 释放。暂存令牌本身不是认证凭据。

stage 接受 `{schema_version:2,expected_revision,document:{schema_version:2,config}}`。
config 表示希望恢复的完整可变配置，省略字段会删除；合法未知字段保留。应从不含凭据摘要
的管理员 snapshot 开始。现有 admin 配置保留，导入不能更改 admin 或恢复密码摘要。
未知 schema、重复字段、保留的变更记录命名空间和非法 JSON 被拒绝。
旧文件格式由调用方明确转换；旧 import API 保留原兼容行为和限制。

成功返回 stage_token、digest、expected_revision、expires_in_ms。令牌为随机 128 位；
digest 是包含 envelope 的完整上传请求原始字节的 SHA-256。暂存绑定当前管理员凭据身份、
发起会话、节点本次启动身份、基准 revision 和固定十分钟单调时钟期限。共享管理员只保留
一个暂存，预检不延期。取消、到期、提交成功释放内存；重启使暂存失效。用户原文件不变。

preflight/cancel 接受 `{schema_version:2,stage_token,digest}`，commit 另需稳定 operation_id，
即表示随机 128 位的 32 位小写十六进制字符串。其他已认证会话也不能接管活动暂存。
暂存后配置变化返回 config_conflict，须重新获取 snapshot、暂存并核对。

预检不修改运行配置，报告每个变化字段的 JSON Pointer、前后存在状态和脱敏值、展开数量、
校验问题、缺少的 secret: 引用和本地 asset。任何问题使 can_commit:false。
秘密值与资源实体通过原平台服务分别恢复，commit 再次检查。普通 JSON export 不等于
完整灾难恢复备份。

上限为整个请求 4 MiB、config 内嵌套深度 16、解析节点 65,536、变化叶子 4,096 项及物理
CRDT 修改 4,096 项。数组按整体替换。既有子记录在同一事务协调，设备 UI 仍经过原语义元素校验。

每个变动实体保存一条整体意图，保留[冲突历史](config-conflicts.md)的每条 64 KiB 和总预算。
未解决冲突或历史容量超限会在预检报告并拒绝提交；4 MiB 上传上限不保证每份文件均能放入
现有历史预算。设备内存与最大文件的实机资格仍是独立发布门槛。

配置、变更记录和成功回执在一个本地 SQLite 事务中保存，成功后才更新内存和复制。
失败不会发布半份导入；崩溃恢复只得到完整旧版或新版。这是本节点原子持久化，其他节点
按既有复制状态逐步收敛，不能理解为全网同时切换。

回执保存上传摘要、令牌摘要、管理员凭据身份及原结果（含 committed_revision）。同一
operation_id、token、digest 重复提交只返回原结果；重启后同一管理员重新认证也可取得，
不会再次写入。该 revision 表示原提交，不是新 snapshot。不匹配返回 operation_conflict；
凭据更换后访问失效。每节点永久保留最多 128 份回执，不静默淘汰；达到上限拒绝后续导入，
返回 receipt_capacity_exceeded。没有自动重试、重放或破坏性回执清理。

query 接受与 commit 相同的参数，只读取回执。成功返回
`{ok:true,schema_version:2,state:"committed",result:<原结果>}`，未知操作返回
operation_not_found，不会执行活动暂存。支持重启后使用相同管理员凭据重新认证查询。
没有收到响应不能视为成功或失败。持久回执经过严格校验，损坏时返回 receipt_store_invalid，
不会继续写入。预检提前报告回执损坏或容量已满；回执损坏时仍可取消并释放活动暂存。
