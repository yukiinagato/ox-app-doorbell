# 修复执行报告 — 2026-09-22

仓库 / 分支：`app-doorbell` / 基准工作树。基准完整 SHA 为 `0fbeed4720efb25dafb79083f86d4c21c39f5087`；开始前工作区无已有改动，最终仍未提交。

受影响交付物已同步升版：Android `0.3.16` / `17`，现代 iOS `0.1.32` / `33`，iOS kiosk `0.3.44` / `47`，Windows `0.1.11` / `0.1.11.8`。

| 任务 | 实现情况 | 正式回归测试 |
| --- | --- | --- |
| R1 | IMPLEMENTED：认证、迁移、失败计数、锁定和改密均进入同一 Runloop 串行域；拒绝调度返回非成功。 | `[R1]` 并发改密；既有 HTTP 持久化和 C ABI 密码测试。 |
| R2 | IMPLEMENTED：C 回调使用不可变配对 slot、先禁用再分离、等待在途回调排空；头文件说明自注销例外。 | `[R2]` 已进入回调时注销排空。 |
| R3 | IMPLEMENTED：Reader 缺帧后只在恢复屏障后的真实解析 IDR 恢复；调用方 `key` 提示不能伪造恢复点。 | `[R3]` 缺帧/伪 key/IDR 恢复；既有 fMP4 回归。 |
| R4 | IMPLEMENTED：XHR 完成路径唯一、有限超时、上下文 401、响应对象校验及本地化错误。 | 运行时测试执行真实登录 handler 的 401、429 和重复通知路径。 |
| R5 | IMPLEMENTED：认证 generation 防止旧响应写入；幂等运行时只保留一条 timeout 轮询链，停止会释放配对和扫码资源。 | 运行时测试覆盖重复 boot 与 stop。 |
| R6 | IMPLEMENTED：扫码会话拥有独立身份和资源；迟到流立即 stop，关闭为幂等清理。 | 运行时测试覆盖 A 关闭/B 打开后的旧流和当前流回收。 |

实际命令、退出码与日志：Core 构建为 PASS（`build/repair-host/repair-build.log`）；R1–R3 定向测试 PASS、26 条断言（`repair-core-targeted.log`）；相关 HTTP/C ABI/fMP4 测试 PASS、1,776 条断言（`repair-core-related.log`）；全部 WebUI 测试 PASS（`repair-web-all.log`）；i18n、英文源和 diff 检查均 PASS（`repair-i18n.log`、`repair-english.log`、`repair-diff-check.log`）；`ios-compat/scripts/test_host.sh` PASS（`repair-ios-compat-host.log`）。日志位于未纳入版本控制的 `build/repair-host/`。

未验证项：完整聚合 `ctest` 本轮未完成，不能标记 PASS；并发原生/Web 迁移、VideoTrack 恢复后的真实软件解码、TSan、ASan/UBSan 均 NOT RUN。Android modern 和 legacy19 因本机缺少 Java Runtime 为 BLOCKED；现代 iOS、历史 iOS 构建、Windows 构建及真实浏览器/设备均 NOT RUN。尤其 iPad mini 1、iOS 9.3.6、armv7 未验证；iOS 兼容 host 测试通过不代表该实机通过。

额外发现：无。发布、部署、push、PR 和设备操作：均未执行。
