# T05 执行报告

日期：2026-09-22 至 2026-09-23（Asia/Tokyo）  
执行者：`/root/t01_evidence_review`；独立审查者：主任务 `/root`  
任务状态：VERIFIED_IN_SCOPE（production_test；主任务已完成独审并统一更新计划进度）

## 来源与范围

审查参照、执行前 HEAD 与验证来源 HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。工作区 dirty；[source-candidate-r2.json](source-candidate-r2.json) 固定六个实现/测试输入；[candidate-r2.patch](candidate-r2.patch) 的 SHA256 为 `227d6e639873da6594919090ed0d0b3740ed41f4911ebaede16b232d1d1f613e`。该差异相对专用 build 目录保留的 Store 起点，起点已包含 T03 和应主任务要求提供给 T08 的 `configPutBatchWithMeta`；不把这些既有改动算作 T05。

本任务只拥有 `core/src/store/store.h/.cpp`、新增 `operation_ledger.h/.cpp` 和 `test_operations.cpp`、`test_operations_disk.cpp`。单独的 ledger 实现是 Store SQLite 持久化职责的一部分，避免把动作状态、恢复和容量逻辑继续堆到 Node；没有引入数据库、库、服务器或独立线程。全部 Node/HTTP/壳绑定和版本、资源生成、计划进度由主任务分别维护；未改公共 native ABI、CMake、UI、现有锁/SOS入口或发布 capability。

受影响交付物是链接 Core 的 Android、现代 iOS/tvOS、iOS 5 兼容应用；主任务统一递增应用版本/build。这里的 host 二进制没有应用版本或设备运行资格，未签名安装、部署或触发真实锁/SOS。

## 真实生产入口与改动

现有生产存储是 `core/src/store/Store`，单个 SQLite WAL 连接由原 `mu_` 串行保护。新增 API 均执行实际 SQLite 事务，不复制状态机。表 schema 从 7 升到 8，并显式使用 `synchronous=FULL`；事务成功提交后才返回分发资格。原 metadata、config、event、call projection 表和 T03/T08 API 保留，19 个已有 Store 回归通过。

- `operationStart(authority, wall)` 生成 32 字节加密随机 boot generation，事务恢复旧 prepared 为 `expired_not_started`、accepted 为 `failed_before_dispatch`，dispatching/dispatched 为 `unknown_after_dispatch`。未解决 unknown 保留。两个固定 active authority/boot metadata 键约束旧连接，避免为历次 authority 产生无界 boot 键。
- `operationPrepare` 无物理效果，生成 16 字节随机、32 个小写十六进制字符的 operation ID，冻结创建主体、authority、全局/门作用域、动作、规范化参数及 SHA-256 指纹、凭据/授权/配置版本、确切执行器与不含秘密的适配器目标、当前 boot 和 30 秒单调截止时间。三个动作当前参数仅允许空对象；SOS 不能夹带门作用域，门操作必须有门和执行器。
- `operationAccept` 持久化 accepted；`operationAcquireDispatch` 原子持久化 dispatching 与不可逆 `dispatch_acquired`，冻结的目标行就是本地发送意图。只有 COMMIT 成功才返回一次 `dispatch_acquired=true`。相同 ID 不复活、不同门/动作参数为 `idempotency_conflict`；未开始记录的凭据、授权或配置变化转为拒绝，不能悄悄改目标。
- mark/query API 保留 dispatched 和 unknown 的区别。重启不自动补发；真实适配器是否收到了命令、物理是否动作必须分开。只有已鉴权且 authority/operation/配置执行器匹配的 ACK 能把未知变为 `actuator_ack`；不会据 MQTT 发送成功、事件或未关联门磁承诺物理 exactly-once。
- 每 authority 准备最多 128 条，accepted/active/unknown 最多 2048 条；所有状态总计最多 4096 条。每条为参数、结果、metadata 各预留 4 KiB，总逻辑上限 48 MiB。metadata 包含索引身份与固定数值字段预留；结果最多 4096 字节，查询页最多 32 条，SQL 有界查询而不是启动加载全部记录。新准备在容量满时明确失败，旧查询保留。
- 清理仅允许终态超过 24 小时且 Core 明确确认墙钟可信；刚好 24 小时、时钟不可信、未解决 unknown 均不删除。清理后迟到 execute 仍返回 unknown operation，不建新记录。

授权输入是可信 Core 的当前上下文，不是请求 JSON 可选字段。Store 再查创建主体/管理员与未开始记录版本；T06 必须在权威路由及返回每条 query/list 记录前完成当前门/动作权限核对，不能把内部 Store 结果直接暴露为已鉴权网络响应。本任务没有声称旧 one-shot 调用已具备新操作身份。

## 验证

工作目录 `/Users/ox/Documents/project/app-doorbell`；Darwin 25.5.0 / arm64；host unsigned；SIP stub。普通与 ASan 独立 build 目录及保存二进制见 [artifacts-r2.json](evidence/artifacts-r2.json)。完整参数、时间、exit、实际行为、来源和二进制 SHA 均记录于命令 JSON。

| test_id | 命令概要 | exit | 实际结果 | 日志 |
|---|---|---:|---|---|
| development-normal-r1 | `doorbell_tests --test-case=operations:* --no-skip` | 0 | 首批 9 用例/248 断言通过 | [r1](evidence/development-normal-r1.log) |
| development-normal-r2 | 同上 | 1 | 14 用例中 13 通过；磁盘满夹具未命中 macOS 路径，`full_writes=0`，不计作产品反例或成功注入 | [r2](evidence/development-normal-r2.log) |
| development-normal-r3 | 同上 | 0 | 修正唯一测试文件名匹配；14 用例/16821 断言通过，真实 VFS `SQLITE_FULL` 一次 | [r3](evidence/development-normal-r3.log) |
| normal-store-r2 | `normal/doorbell_tests --test-case=operations:*,store:* --no-skip` | 0 | 33/33 用例、17124/17124 断言通过 | [normal](evidence/normal-store-r2.log) |
| asan-store-r2 | `asan/doorbell_tests --test-case=operations:*,store:* --no-skip` | 0 | 同样 33/33、17124/17124，通过且无 ASan 诊断 | [ASan](evidence/asan-store-r2.log) |

最终 r2 修正了自查发现的 C02 格式偏差：r1 曾生成 64 字符 operation ID，现已采用合同规定的 16 随机字节/32 小写 hex，并测试拒绝过长和大写 ID；r1 来源、二进制和日志保留为历史，不作为最终合同通过证据。

修复前 RED 限制：起点没有操作台账或 prepared-ID API，无法在同一接口上运行这些新状态的修复前反例；没有把缺 API 的编译错误、SQLite 缺表检查或临时复制模型称作业务 RED。T04 已有真实 HTTP 迟到执行反例；T05 的新契约直接在实际 Store/SQLite 层验证，T06 仍须补真实网络/Node 入口行为。此限制明确保留。

| 验收 | 真实路径与观察 |
|---|---|
| T05-01 | 20 个线程在共享屏障后对同一个 prepared ID 调用实际 accept/acquire；所有查询状态一致，仅一次 commit 后返回分发资格。 |
| T05-02 | 同 ID 改门或改成 SOS-clear 返回 idempotency_conflict；直接跳过 accept 不给资格；配置、凭据、grant 变化拒绝未执行记录，冻结锁目标未改变。 |
| T05-03 | 子进程实际持久化后，在文件标记适配器发送前/后分别 `_exit`，跳过析构及 SQLite close/checkpoint；父进程重开并恢复为 unknown，均不给第二次资格，发送标记保持 0/1。另验证 prepared/accepted 恢复为未开始终态和迟到已鉴权 ACK 无重发。 |
| T05-04 | 恰在 30 秒过期拒绝；终态 24 小时内不清理，之后按可信时钟清理；已删除和未知 ID 不创建、不复活。 |
| T05-05 | 实际 SQLite 达 128 prepared、2048 active/unknown、4096 总行时失败有界；unknown 不清理，年轻终态不驱逐，分页封顶 32。真实磁盘数据库的 WAL 写入注入 SQLITE_FULL 后不发资格、accepted 不变，恢复写入后只有一次资格。 |

容量测试使用真实 `:memory:` SQLite 以隔离吞吐成本；恢复、事务错误和磁盘满注入使用实际文件数据库。一次有 1 个 ledger 行的 host 采样为 database=4096、WAL=263712 字节、逻辑预留=12288 字节，证明物理开销并不等于逻辑预留；该采样包含原 Store schema，不是全容量旧设备内存/磁盘资格。SQLite VFS 注入是在真实 xWrite 返回 `SQLITE_FULL`，不是填满宿主机磁盘，也不是替换业务返回值。

ASan 编译了 C/C++ Core、SQLite、第三方和测试本身；没有全局 LeakSanitizer 资格声明。进程终止测试是进程崩溃，不是硬件断电；未声称物理执行器 exactly-once、设备通过或发布完成。所有新 ledger 测试的 SQLite 文件/sidecar/标记由 RAII 清理；子进程已 waitpid，Store 连接已关闭，VFS 默认恢复。已有 Store 回归自行创建的历史型 scratch 目录未按名字盲目删除；原始日志与专用 build/artifact 目录保留。

## 独立复核

主任务只读独立审查已通过，记录为 [evidence/review.json](evidence/review.json)，SHA256 `94970510926814a315356ff17b61bd0ca9fdc2308e68601f83f1ce9157606fa3`。重点：commit 与副作用资格顺序、崩溃恢复、已清理 ID、同 ID 冲突、权限上下文边界、容量/retention、SQLite FULL 回滚及原 Store 行为。没有把 T06 未实现部分从计划删除。

## 下一步

T05 已完成独审，下一步推进依赖 T05 的 T06 权威操作路由和 Node 集成；在此之前不广告新协议能力。本报告不授权 push/tag/release/部署。

主任务独立审查 PASS，见 `evidence/review.json`；本卡已标为 VERIFIED_IN_SCOPE，未替代后续集成或设备门禁。
