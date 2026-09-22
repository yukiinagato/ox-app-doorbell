# 保留配置编辑冲突

同节点通过 revision 比较保护并发写入。断网节点继续使用既有 LWW 复制，重连时生效配置可能改变。升级后的配置写入会额外保存编辑意图，在后台显示未解决候选；不会自动合并或反复写回胜出值。

## 记录与原子提交

普通配置和不可变的 `_config_changes.<change_id>.<sha256>` 记录写入同一个 SQLite 事务。任一失败则都不发布。SHA-256 固定记录内容，认证与保密由既有 Mesh SecureChannel 提供。记录不参与普通配置、导出、规则和可执行事件。未知字段、重复、循环、作者或摘要不符、无效父版本会拒绝整批数据，且不推进持久化复制进度。

schema 1 包含随机 128-bit change_id、author_node、entity、base_entity_version、parents、typed ops、candidate_exists、candidate、requires_reentry。每项操作包含 set/delete、key，以及最多两个 base_versions：最近的既有祖先和同键 LWW 记录，以 `{key,hlc,author,seq,deleted}` 表示，seq 为十进制字符串。缺少父记录表示原先不存在。实体基准摘要覆盖修改前该实体的全部 LWW 记录身份。每条记录最多 256 项操作、64 KiB。

entity 默认按顶层配置部分划分，devices 则按 `devices.<id>` 划分。拒绝整体 devices 写入与删除。不同分支修改同部分的不同字段，也保守标为冲突。公开的单项、batch、CAS、import、公告配置入口共用记录边界。启动、运行时内部维护及凭据服务维持各自既有契约。旧节点自身的编辑没有此记录，因此混合版本集群不具备完整冲突保护。

## 显示与解决

`/api/config/snapshot` 及现有 native ABI 返回 edit_conflicts 与 edit_journal。每项冲突包含实体、全部当前 head、生效值和保留的分支记录。candidate_exists=false 表示删除；true 与 null 表示真实 null 值。

对未解决实体的普通编辑返回 unresolved_config_conflict。管理员通过现有会话、CSRF、可信 Origin 和条件提交，发送 `resolves:{"entity":["全部当前head"]}`，并对同一实体执行 set/delete。解决冲突的 set 是完整替换，会删除省略字段和被取代的子记录，仍需通过既有配置校验。同一事务同时比较当前 revision 和完整 head 集合；过期选择不覆盖新值。新记录引用全部候选，重复同步不产生额外记录。

受保护的值替换成 requires_reentry 标记；有效 secret: 引用保留，密码等明文及带凭据 URL 不进入候选。不完整候选不能直接提交恢复，必须使用现有安全存储与引用流程重新填写。解决冲突不会恢复平台中已经缺失的秘密。

## 有界保留

本地最多 512 条、每实体 64 条、总记录编码 512 KiB；远端合并预留 1024 条、每实体 128 条、1 MiB。本地满额返回 config_history_capacity_exceeded，配置不发布。远端记录无效或超量则保留前一个状态，并在 runtime.config_store 显示错误；条件解决后可重新同步。

普通事件清理和 tombstone 清理不会删除编辑记录。首版也保留已解决祖先，尚无经过全节点覆盖证明的历史压缩。因此容量可能阻止后续编辑乃至冲突解决，不会靠丢弃候选继续写入。提高预算或加入安全归档、压缩，需要另行验证资源和恢复行为。普通配置导出不含此历史及平台秘密，不能当作完整灾难恢复备份。
