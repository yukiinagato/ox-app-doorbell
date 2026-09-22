# T29 执行报告

日期：2026-09-23 JST。执行：root；独立复核：t02_contract_inventory；崩溃夹具独立复核：root。

状态：VERIFIED_IN_SCOPE；最终定向、崩溃、完整 Core 回归、历史 SDK 构建及独立复核均已通过。

## 来源与范围

HEAD 为 b26e0d346df99f2879915241b6e98d8ef1aa0707，工作区 dirty。最终候选 source-green-r4.json 的输入摘要为 35263b4e965e48f74a73f5b15d318d9773c9b2594dae6396c7f0347a9b416fee，冻结 12,633 个源码、依赖和资源输入。每文件 SHA、命令、cwd、起止时间及退出码均记录于 manifest/evidence。没有覆盖既有改动、提交、推送或安装正式应用；ios-legacy 未改。

沿本批统一递增版本：Android 0.3.21/22、现代 iOS 0.1.37/38、tvOS 0.1.14/15、iOS 5 0.3.49/52、iOS 9 armv7 0.4.3/403、Windows 0.1.14/0.1.14.11。宿主测试不代表这些设备已安装本批正式版本。

## 真实生产入口与改动

Node 的 /api/config/import/{stage,preflight,commit,cancel,query} 和添加式 db_core_config_import_json_v2 复用当前管理员会话、CSRF、Origin、既有配置校验器、LwwMap 及 Store 的单次事务。原 batch 和旧 import 仍限制 256 项，不接受外部文件路径。

stage 接收 schema 2 完整目标配置，保留既有 admin，拒绝凭据摘要恢复、重复字段、未知 schema 和保留命名空间。128 位随机令牌绑定上传原字节 SHA256、管理员凭据身份、发起会话、启动身份、基准 revision 和固定十分钟期限；仅一个活动暂存，取消/超时/成功释放。大小上限 4 MiB、深度 16、节点 65,536、变化叶和物理修改各 4,096；数组整体替换。

预检完整计算差异、脱敏前后值、缺少 secret 引用/资源、校验及历史/回执容量问题，不写运行配置。设备 UI 拆为语义元素记录；既有父记录按对应物理单元投影并按父先子后排序，不能用容器绕过元素校验。提交重检 revision、依赖及所有限制。每变动实体一条意图，配置/历史/回执一次持久化后才发布内存、事件和复制；失败不发布部分配置。doors 根实体更新也通知新旧公告，sip 根实体更新安排重配。

成功回执永久保留最多 128 份，绑定 operation_id、文件摘要、令牌摘要和当前管理员身份；相同提交返回原始结果及当时 revision。元数据严格验证，损坏拒绝写入且仍可取消暂存。query 只读原回执，不执行活动暂存；未知操作明确返回 operation_not_found，重启后同一凭据重新认证可查。原子性只代表本节点持久化；不承诺全网同时切换。

英文、日文和中文 config-import/config-schema 文档已同步。后台导入向导使用这些入口属于后续 T30。

## 验证

| 验收项 | 实际证据与结果 | 记录 |
|---|---|---|
| 初始生产反例 | 编译通过，旧生产无 stage API：1 case / 11 assertions，其中 1 失败 | evidence/baseline-red-r2.json |
| T29-01 | 255/256/257 全量导入、普通 257 batch 拒绝；4,096 边界成功、4,097 拒绝 | evidence/candidate-targeted-r4.json |
| T29-02 | 最后一项无效、缺 secret/asset、receipt INSERT 失败：配置/revision 不变，无部分发布 | 同上 |
| T29-03 | 四个真实子进程在提交前、回执写入前/后、提交后 SIGKILL，四次重启仅完整旧/新配置，回执同存同失 | evidence/candidate-crash-r4.json、crash-root-review-r4.json |
| T29-04 | stage 后另一次配置写入，原 commit 明确 config_conflict | evidence/candidate-targeted-r4.json |
| T29-05 | 超大/重复/过深/未知 schema、错误 CSRF/不同会话、过期/取消/容量，均有界拒绝并可回收 | 同上 |
| 恢复 query | 未提交查询不写、原结果查询、错绑定/CSRF拒绝、重启后原结果及 revision 不变 | 同上 |
| 最终定向 | 9/9 cases、647/647 assertions；真实 HTTP/Node/SQLite | 同上 |
| 最终崩溃 | 1/1 case、159/159 assertions、4 SIGKILL / 4 新 Node | evidence/candidate-crash-r4.json |
| 独立反例 | r3 两条 45 assertions 中 4 失败；r4 相同测试 2/2 cases、45/45 assertions 通过 | evidence/independent/red-r1.json、green-r4.json |
| 历史 iOS 5 | armv7/min5.1 静态 Core 与禁用符号检查通过，archive 9e2267eb912c11ab46a1ec68b9ba6910a2e07e7eee8f3297a9cf289546c7af7e | evidence/ios5-core-r4.json |
| 全部 Core 回归 | 518/518 cases、32,294/32,294 assertions 通过；独立子进程入口由父测试启动，不作为单独普通测试执行 | evidence/core-regression-r4.json |

r3 原生产回执缺陷通过真实 SQLite 元数据替换复现：1 case / 113 assertions，10 失败；修复后纳入 r4 最终通过。r2 重复字段反例原用会替换同名字段的 helper，导致夹具断言失败，已改用真正重复字段；原日志保留。最早编译夹具与历史工具链链接路径错误均记录为环境/夹具错误，未冒充业务反例。

## 独立复核与限制

独立初审保留 CHANGES_REQUESTED：device.local 父记录、doors 根公告副作用和 SIP 根重配。前两条由真实 HTTP/Node 反例确认；SIP 是明确源码发现，不声称 SIP stub 验证真实呼叫重配。最终独审 independent-review.json 已签 PASS_IN_REVIEWED_PRODUCTION_SOURCE_AND_REGRESSION_SCOPE，root 的 crash-root-review-r4.json 独立批准崩溃夹具。

Core 为 macOS arm64 Debug / SIP stub。SIGKILL 证明操作系统仍运行时的进程崩溃恢复，不替代物理断电、存储控制器和设备最大文件内存资格。历史 SDK 只构建，未部署。没有新宣告硬件 capability。已有冲突历史的 64 KiB 单条/512 KiB 总预算和永久回执上限仍可拒绝合法但超容量的输入；不静默清历史，不宣称任意 4 MiB 都能导入。

## 下一步

T29 已关闭，下一张依赖满足的任务为 T30。整个计划和设备发布资格仍未完成。

来源边界补充：r4完整Core二进制为macOS链接器ad-hoc签名，无发布身份。冻结Core中包含当时T35-Web r6资源；并行T35-Web最终r7有独立40项验证，下一次集成构建须合入，不能把此r4声明为全工作区最后产物。
