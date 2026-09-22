# T26 · 本地配置原子基准校验

状态：VERIFIED_IN_SCOPE（production_test）。这只关闭单节点 CAS，不代表跨节点分区冲突、管理编辑器或导入迁移完成。

新增 `/api/config/snapshot`、`/api/config/commit` 与两个 additive v2 C ABI；旧 batch 对象可选携带 expected_revision 进入相同入口。快照去除管理员密码摘要，HTTP no-store；新 HTTP 写入要求当前会话、准确 Origin 和会话 CSRF。公开结构体 ABI 不变，返回值仍由 db_free 释放。Core 宣告已实测的 config_cas_v1。

版本由运行期 epoch 和可见 CRDT 记录版本构成，节点内有效，重启/副本重置失效。Core loop 串行执行版本比较、字段意图合成、物化候选 schema 校验、SQLite 持久化。Store 使用同一递归互斥锁承接外层事务与原有 commit hook；持久化成功前不发布新配置或新 revision，失败恢复旧 CRDT 状态。

对象补丁保留未知字段；数组/标量整体替换，null 与显式 delete 区分。为处理原有父子 CRDT 记录并存，事务同步受影响的已有子记录并对被替换后代写墓碑；不改原 CRDT 存储或复制模型。显式父子重叠操作明确拒绝，展开后同样受 256 项上限约束。请求最多 256 KiB、32 层容器；版本过期返回 409/config_conflict，不带秘密差异，不自动重试。

## 证据

最终源 `source-green-r4.json`；完整冻结源码 `build/remediation-t26-20260923/green-source-r4`。`artifacts-r4.json` 记录 clang 工具链、host arm64、二进制与 manifest 散列。SIP stub、unsigned host；没有物理动作、设备部署或目标平台运行资格。

- `evidence/stale-base-red.json/.log`：旧真实 Node/HTTP 条件批次仍接受过期写，业务反例失败；不是编译错误。
- `evidence/config-cas-r4.json/.log`：10/10 测试、333/333 断言 PASS。包括同基准竞争、未知字段/null/删除/父子记录、真实 SQLite 写失败及重开读取、HTTP 会话/CSRF/Origin、C ABI before-start/after-stop、config_cas_v1。
- T26-03 用真实 SQLite BEFORE INSERT trigger 暂停在比较之后、提交之前；确认进入屏障后将竞争原生写排入同一生产 Core loop，并断言此时仍可见旧配置、竞争尚未执行。释放后第一笔成功，竞争笔 config_conflict。未用 sleep 猜测窗口。
- T26-04 四轮各 12 个并发 HTTP/原生写入，每轮仅一个胜出者；另外两个 v2 C ABI 在真实 Core 上调用并释放所有返回内存。
- `evidence/admin-store-regression-r4.json/.log`：63/63 相关回归、19357/19357 断言 PASS，包含真实操作台账/SQLite WAL 故障及管理员、存储回归。
- `evidence/review.json`：独立审查 `/root/t02_contract_inventory` 最终 PASS；初审和 r3 复核均保留。

## 保留的失败与修正

r1 新批次测试误用了未定义的 doors.front.call.return_s；真实 schema 的已定义路径是 call.indoor.return_s。修正夹具后验证真实拒绝，没有修改产品校验来迎合错误字段。初审另发现三项产品缺口：旧标量子 CRDT 记录覆盖父补丁、深层字段绕过父类型、启动前新 ABI 解引用空 Core。三项均补生产路径测试并修复。

r3 广回归 47/49，两个旧认证夹具失败：双节点在管理员凭据尚未收敛时登录，及 unpair 后仍期望旧会话可用。前者在不含 T15 的源上也复现；最终夹具先等待同一凭据收敛，后者新增旧会话必须拒绝并重新登录后继续原配对断言。r4 63 项全部通过。所有失败日志保留，未降低安全行为断言。

英文、日文和中文 config-schema 已同步说明 revision 范围、条件入口、字段语义、边界及旧调用者迁移。受影响应用本批版本已统一提升；本卡未重复提升。旧无条件 batch、单键写入/删除、导入及专用编辑动作的后续迁移分别由 T27/T29/T30/T34 承担。T28 仍需持久化且可见的跨节点并发意图，本地 CAS 不替代它。
