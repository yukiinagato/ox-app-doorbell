# T22 Windows Core 时间快照

状态：VERIFIED_IN_SCOPE（native_source）。来源及7个文件哈希见 source-final.json。Windows本批版本0.1.14 / 0.1.14.11，公有原生 ABI 布局未变。

呼叫页停止用 DateTimeOffset.UtcNow 比较校正期限；读取真实 Core 的 remaining_ms、recovery_remaining_ms、snapshot_generation 和 snapshot_age_ms，Stopwatch 仅减少显示时长。重复缓存样本不重新授予时长，零或未知只核实当前状态；Core明确无活动通话后才收起页面。恢复需要当前所有者、Core可恢复标记及剩余恢复窗口，不使用旧事件推翻当前快照。前台/休眠恢复有新样本屏障，避免旧单调时钟不计休眠时重新显示已过期呼叫。

Core实例代次随启动/停止改变；原生JSON复制在现有互斥区完成，带代次回到 UI。Dispatcher 状态事件及捕获通话/代次/页面修订的 timer 闭包拒绝过期回调。恢复上报按Core代次+call ID去重。Dispose先在互斥区摘除句柄、排尽当前持锁调用，再在锁外停止原生回调，避免销毁与快照复制交错。

安装可用的Mono主机工具链后实际编译并执行生产 CallTiming.cs 与未改布局的 CoreInterop.cs：32个断言通过。其中真实PInvoke创建并启动本机Core、press返回身份、读取真实JSON快照交给生产时间投影，最后取消仅本机测试呼叫并销毁。±5分钟校正墙字段、缓存年龄、重复样本、未知/零、恢复上限、前台相同样本、旧call/Core/UI修订、大整数和ABI布局均覆盖。分别编译x86和x64 PE绑定测试产物成功，文件头见evidence/artifacts.json。现有70项Windows源码契约全部通过；其中两条要求旧错误墙钟算法的检查已更新，原失败日志保留。

T22-01至04映射见evidence/acceptance.json和实际命令日志。初次新增测试错误把ABI指针字段数写成11，实际为10；按未改过的公有结构核实后纠正，此失败不算产品red。原始产品缺陷来源为修改前 MainWindow 的 expires_at_ms - DateTimeOffset.UtcNow 和timeout主动cancel路径。

限制：实际托管及原生执行在macOS arm64、64位指针；x86/x64为实际交叉编译产物，未声称32位Windows进程运行。没有完整WPF应用构建或Windows真机资格；T47/T48保留独立门禁。原生测试动态库为T08冻结主机候选、SIP stub，不是Windows DLL或发布包。未改设备时间，未执行物理门锁或SOS。

后续多门恢复复核补充（r2）：先用当前Core快照筛选door/origin/dialog_owner及recovery_required，再更新单呼叫锚点；无关候选无法刷新旧恢复窗口。生产OwnedRecovery helper及三个异门/异owner回归新增9断言，最终41断言通过，70条源码契约再次通过，x86/x64绑定测试再次编译。最终依据 source-final-r2.json、evidence/acceptance-r2.json、artifacts-r2.json；r1记录保留为历史。
