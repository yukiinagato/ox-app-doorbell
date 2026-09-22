# T04 执行报告

日期：2026-09-22（Asia/Tokyo）  
执行者：`/root/t01_evidence_review`；独立审查者：`/root/t02_contract_inventory`  
任务状态：VERIFIED_IN_SCOPE（production_test；主任务统一更新计划进度和平台版本）

## 来源与范围

审查参照、执行前 HEAD 与验证来源 HEAD 均为 `b26e0d346df99f2879915241b6e98d8ef1aa0707`；工作区为 dirty。本任务源码清单见 [source-candidate-r3.json](source-candidate-r3.json)，对应差异已保留为 [candidate-r3.patch](candidate-r3.patch)。差异 SHA256 为 `7ef16201d73f3a7bdb2d296fe85da04cd8a1aed2d5c49e0937584293690e3d98`。清单包含五个本任务拥有的 HTTP/Runloop/测试文件，以及共享 CMake 文件；CMake 的视频探针两行属于之前并行工作，本任务仅在 `DB_BUILD_TESTS` 内增加测试屏障编译定义。

修改前五个本任务源码文件无已有差异。保留了共享工作区其他 Core、UI、平台版本、文档及资源修改；未覆盖、回退、提交或部署。公共 native ABI 无改动。受影响交付物为链接 Core 的 Android、现代 iOS/tvOS、iOS 5 兼容应用；应用语义版本/build 由主任务统一递增，本报告不把 host 可执行文件当作应用发布或设备验证。报告时 iOS 为 0.1.37/38，Android 为 0.3.21+revision/22，iOS 5 为 0.3.49/52，均为工作区值而非本任务设备报告。

## 真实生产入口

真实 loopback TCP 请求经 CivetWeb `requestHandlerImpl` → `runOnLoop` → 实际注册 handler；测试使用生产 `Httpd`、`Runloop` 和 socket，没有复制状态机。请求状态由 `Httpd::Impl::Pending` 持有。认证 gate 和媒体 provider 仍运行于 HTTP worker；路由 handler 在 Runloop 上执行。认证时间点的增强归 T08，本任务没有越界代替实现。

## 改动

- `httpd.cpp/.h`：复制请求和 handler 到共享上下文；deadline 继续使用 `steady_clock` 与原 5000 ms 上限。`queued → running` 及 `queued → expired` 使用同一互斥锁，loop 在取得运行资格的同一锁内检查 deadline。未开始返回 HTTP 503 的 `err/error_code=not_started`；已开始而结果尚未完成返回 `outcome_unknown`。已存在 503 状态文字，无新增状态码。
- loop 回调只捕获共享请求上下文，不捕获 HTTP connection、worker 栈或 `Httpd::Impl`。handler 在状态锁之外执行；HTTP 超时或关闭不会伪装取消已经运行的动作，最终完成仍只有一次。
- 关闭入口先关闭准入、使排队状态过期并唤醒所有 waiter，再由 CivetWeb join worker。关闭不等待 handler/Runloop 屏障。实际 Node teardown 顺序与 lifetime 经独审核对。
- `runloop.cpp/.h`：新增 `cancelQueued(id)`，只移除仍在队列中的任务；已经弹出或完成则无操作，也不建立无界取消墓碑。HTTP waiter 退出使用 RAII 清除排队任务及注册记录。CivetWeb worker 池仍为 16，注册 waiter 不超过 16；串行 Runloop 至多一个已开始的 handler，超时请求不再因 loop 长期阻塞而累计排队 payload。现有 8 MiB HTTP body 上限未改。
- `test_httpd.cpp`：8 个新增测试覆盖排队、运行、重复顺序、loop 自己检查截止时间、关闭/请求所有权及取消阶段；保留 6 个原 HTTP 和 6 个原 Runloop 回归。截止边界屏障只在 `DB_BUILD_TESTS` 下可用，处于所有生产锁之外；它暂停 waiter，不替换时钟、资格竞争或 handler。`DB_BUILD_TESTS=OFF` 配置生成的 Core flags 不含该 hook，见 [artifacts-r3.json](evidence/artifacts-r3.json)。该配置检查不冒充另一次 release 构建。

## 验证

所有命令工作目录为 `/Users/ox/Documents/project/app-doorbell`，目标为 macOS Darwin 25.5.0 / arm64，SIP stub，unsigned host。命令 JSON 包含完整参数、时间、exit、日志、源码清单 hash 与实际二进制 hash。

| test_id | 证据层 | 实际命令概要 | exit | 实际结果 | 日志 |
|---|---|---|---:|---|---|
| red-queued-expiry | production_test | `normal/doorbell_tests --test-case=httpd: scheduling expired queued write never reaches handler --no-skip` | 1（预期） | 修复前 1 用例失败；9 断言中 2 个业务断言失败 | [RED](evidence/red-queued-expiry.log) |
| green-httpd-r2 | production_test | `normal/doorbell_tests --test-case=httpd:* --no-skip` | 1 | 保留的中间失败，13 用例中关闭测试 2 例因错误的传输/2秒假设失败，不作为通过证据 | [r2](evidence/green-httpd-r2.log) |
| green-httpd-r3 | production_test | `normal/doorbell_tests --test-case=httpd:*,runloop* --no-skip` | 0 | 20/20 用例，289/289 断言通过 | [normal](evidence/green-httpd-r3.log) |
| asan-httpd-r3 | production_test + ASan | `asan/doorbell_tests --test-case=httpd:*,runloop* --no-skip` | 0 | 20/20 用例，290/290 断言通过；无 ASan 报错 | [ASan](evidence/asan-httpd-r3.log) |

修复前真实观察：HTTP 在 5000 ms 超时；释放 loop 后 handler 次数为 **1**，而期望为 0；响应缺少 `not_started`。RED 命令记录里的 PASS 仅表示“预期 exit 1 得到满足”，不表示该测试通过。未观察或声称复现 UAF。

修复后四项映射：

| 验收 | 实际生产时序和结果 |
|---|---|
| T04-01 | loop 被屏障持住超过真实 deadline；HTTP 收到 503/not_started；排队 task 已移除；释放 loop 后 handler 为 0。 |
| T04-02 | handler 先取得运行资格后持住；HTTP 收到 503/outcome_unknown；释放后完成次数恰好 1，请求正文仍有效。 |
| T04-03 | 两轮分别强制 waiter 先过期及 handler 先开始，结果只能为未开始/0 次或未知/1 次；额外暂停 HTTP waiter 到真实 deadline 后释放 loop，证明 loop 自身也拒绝迟到 handler。 |
| T04-04 | 排队时并发停止 HTTP/Runloop，HTTP 在 4 秒上限内退出，无永久等待，弱引用证明排队 owner 释放，队列清空、handler 为 0；已经运行时销毁 HTTP，owner 和请求活到 handler 完成后释放。正常及 C/C++ ASan 下均通过。 |

CivetWeb `mg_stop` 先设置 stop flag，`push_all` 在该 flag 下可以停止发送，所以关闭可能仅表现为 socket 断开。空响应是传输结果未知；测试不据此声称 `not_started`，而检查真实 handler 次数、生命周期、任务清理与有界停机。两个最终运行的断言数相差 1 来自此合法传输分支，均通过。4 秒停机断言容纳 CivetWeb 约 2 秒退出轮询，仍短于真实 5 秒 HTTP deadline。

普通和 ASan 使用独立 build 目录。ASan 的 Core、third-party C/C++ 及 test 编译/链接 flags 均包含 `-fsanitize=address`；不是仅 Swift/测试壳插桩。没有全局 LeakSanitizer 资格声明；本任务请求上下文释放由 weak owner 断言和 ASan 生命周期检查支持。完整 Core 全套、旧 SDK、设备/签名/实际锁和 SOS 验证不属于这次 host 验收，未在本报告声称通过。最终 binary 已保留，见 artifacts-r3.json。所有本任务测试/服务进程正常退出，无后台服务或设备资源需要回收；未创建模拟器。

## 独立复核

复核记录：[evidence/review.json](evidence/review.json)，结论 `PASS_IN_SCOPE`，SHA256 `b8e4bb2fd34aebbc463b4e44dba2117604d151fe0e66073647dd352f9e4d9b79`。重点包括锁序、task ID 发布、deadline 原子资格、停机与 Node lifetime、无取消墓碑、hook 仅测试构建及真实 RED/最终二进制身份。验收引用采用单向 hash 链，不让 review 与 acceptance 循环引用。

## 下一步

T04 已完成独立复核，依赖满足的下一张为 T05 动作持久化台账；先实现 Store 层，T06 再接入 Node。T08 的执行时认证复核由主任务实施。本报告不授权 push/tag/release/部署。
