# T29 磁盘崩溃独立子项

状态：**真实生产路径测试 PASS（本机持久化范围）**。只新增 `core/tests/test_config_import_crash.cpp`，不改生产；绑定主任务 `T29/source-green-r2.json` 的完整冻结输入。独立审查与整卡关闭由主任务执行。

测试通过 posix_spawn 启动同一真实测试程序，创建磁盘 Node，经真实 HTTP 登录、stage、preflight 和 commit，导入 320 处变化叶、16 条实际配置记录。子进程屏障通过 pipe 通知父进程；父进程 SIGKILL 并用 waitpid 确认信号死亡，未运行 Node/Store 析构。重启新 Node、新管理员会话读取整份公开配置并重放相同 operation_id。

| 强制终止屏障 | 同连接事务 / 新配置行 / 回执行 | 重启后 |
|---|---|---|
| HTTP commit 前 | autocommit=1 / 0 / 0 | 完整旧配置、无回执、stage_expired |
| receipt BEFORE INSERT | autocommit=0 / 16 / 0 | 完整旧配置、无回执、stage_expired |
| receipt AFTER INSERT，COMMIT 前 | autocommit=0 / 16 / 1 | 完整旧配置、无回执、stage_expired |
| HTTP commit 成功、独立连接已读取回执后 | autocommit=1 / 16 / 1 | 完整新配置、回执存在、重放原结果 |

`normal-r1.log`：1 case、159 assertions、exit 0，4 个真实 SIGKILL 子进程/4 次新 Node 重启。整份配置使用 cJSON_Compare 与预期快照比较并排除相反快照；回执与配置必须同存同失。屏障读的是实际 SQLite 连接 autocommit 和实际行数，不伪造 Store 结果。SQLite auto_extension 仅给测试子进程注册函数，触发器仅在唯一临时数据库中存在；重启前删除测试触发器，没有生产后门或等待轮询来猜中断时刻。

精确命令、原始日志、输入/二进制/编译参数 SHA、每屏障机器化记录与清理证据位于 evidence。主任务 green-r2 的 12625 个输入逐一匹配，新增测试自身也与冻结源一致。英文源码与 whitespace 检查通过。

本测试运行 macOS arm64、Debug、SIP stub、未签名主机测试，未启用 sanitizer。覆盖操作系统仍运行时的进程崩溃，不声称物理断电/存储控制器故障、真实设备资格或全网原子切换。SimClock 只控制时钟，HTTP、Node、Store、SQLite WAL 与进程终止均为实际路径。未联网控制设备、未部署、未触发门锁/SOS。4 个临时数据库目录已按精确归属清理，子进程均已回收，无残留测试进程。
