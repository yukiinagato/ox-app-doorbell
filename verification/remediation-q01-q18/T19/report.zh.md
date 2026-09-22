# T19 执行报告

状态：VERIFIED_IN_SCOPE（production_test）。范围为 Core 生产状态快照，不代表客户端迁移或设备资格已完成。

在现有 active_calls JSON 上新增 snapshot_generation、recovery_required、recovery_eligible、recovery_remaining_ms。身份、阶段、状态、Core 校正时间和恢复窗口在同一 loop 内采样。每个 Core 生命周期使用随机代次前缀，各次采样递增序号；缓存读取不会产生新代次。remaining_ms 用无符号正差及 JSON 精确整数上限安全计算。

状态 ABI 仍读取缓存、不会等待 loop；读取时仅补充 Core 单调时钟计算的 snapshot_age_ms，保留整份业务快照一致性。客户端必须减去年龄并识别重复代次，不能重复读取旧 remaining_ms 后重新开始计时；旧 Core 缺字段时显示核实中。没有修改现有十秒恢复规则或增加 UI 自动取消。公共头文件和英、日、中文 schema 同步。

来源：source-final.json；修复前来源：source-red.json。真实反例 t19-red.log 退出 1，缺少代次导致两个业务用例失败；修复后 t19-green.json/log 退出 0，5 项生产 Node 用例、388 断言通过。

| 验收 | 实际证据 |
| --- | --- |
| T19-01 | 原始系统时钟 ±5 分钟、Core 校正到同一真实时间，剩余时长相同；NTP 偏移改变后仅新快照改变剩余时长 |
| T19-02 | 同一 Node 20 次呼叫/取消转换期间并发读取缓存，逐条核对代次、身份、状态及同一采样时刻的剩余时长 |
| T19-03 | loop 暂停跨越呼叫截止时仍保留原代次且年龄超出时长；恢复执行后呼叫移除；持久化恢复/进程重建取得新代次 |
| T19-04 | 重复已结束查询/恢复不产生第二次取消；现有持久化失败重试测试仍仅提交一次终止事件 |

所有验收对应 evidence/t19-green.json 和原始日志；既有耐久恢复测试覆盖 10 秒窗口以及存储失败后的有界重试。测试使用实际 Node/Store/Runloop，网络与时钟使用仓库原有确定性边界。SIP stub，未测真实通话或物理设备。T21/T22/T23 负责各客户端采用新快照，不能将本卡视为这些任务完成。

本轮共享 Core/Web 版本已统一递增：Android 0.3.21/22，iOS 0.1.37/38，tvOS 0.1.14/15，iOS5 0.3.49/52，iOS9 armv7 0.4.3/403，Windows 0.1.14/0.1.14.11。最终嵌入构建及设备实际版本另由平台门禁记录。
