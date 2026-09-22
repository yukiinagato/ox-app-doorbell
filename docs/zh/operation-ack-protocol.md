# 认证动作确认协议 v1

这是[动作 API](operation-api.md)的可选扩展，默认关闭，使用仓库现有 Monocypher 的标准 Ed25519 验签；不自创加密算法、密钥交换、共识协议、Broker 或自动重发。

在 `doors.<door>.operations.ack` 配置完整对象：`{"protocol":"ed25519-v1","actuator_id":"front-lock","public_key":"64位小写十六进制公钥"}`。公钥为 32 字节；私钥仅属于执行器，不进入配置复制、日志或备份。缺失/不完整时不启用 ACK。拒绝未知/重复字段、其他协议、非法或全零公钥、非 1–64 位 ASCII 字母/数字/下划线/连字符的执行器 ID。逐叶编辑在完整有效前保持禁用。删除或替换配置即可撤销；当前配置与 prepare 冻结的身份/公钥必须同时一致，换钥不能确认旧操作。门、命令、broker/topic 或固定权威变更后不能沿旧绑定确认。

配置只指定谁有资格签名，不代表真实执行器、去重能力或门磁已经验证。本机测试执行器不能代替实际设备资格。

发给已配置执行器的 MQTT 命令在 operation_id/authority_node/door 外增加 `ack_protocol:"ed25519-v1"`、actuator_id、command_digest。命令摘要为 UTF-8 字节 `ox-doorbell/operation-command/v1`、door、command、已有冻结 broker-binding SHA256，按上述顺序各一行，包含最后换行，再做 SHA256。所有字段都禁止换行，摘要使用小写十六进制。

执行器在 `<base_topic>/cmd/ack` 发布非 retained 的扁平 JSON，严格包含八个字符串：protocol、operation_id、authority_node、actuator_id、door、command_digest、result、signature。protocol 固定 `ed25519-v1`，result 仅允许 `command_processed`；两个 ID 各 32 位小写十六进制，摘要 64 位、签名 128 位。正文最多 2048 字节，拒绝未知/重复字段、retained ACK、未签名旧 ACK 和普通门磁消息。

签名输入为以下字段按顺序各一行的准确 UTF-8 字节，包含最后换行：`ox-doorbell/operation-ack/v1`、operation_id、authority_node、actuator_id、door、command_digest、`command_processed`。先检查每个字段的严格编码，再构建域分隔输入；不签名 JSON 序列化，JSON 排序/空白不影响签名。参考测试执行器独立按照该格式签名，使用显式测试私钥。

Core 在状态 loop 验证当前授权来源、公钥、固定权威、门、命令与 endpoint 是否匹配冻结意图，并检查该 ID 已经持久化取得 dispatch。仅有合法签名仍不足以更新其他目标。重复 ACK 只结算原操作，不再次分发；迟到但仍有效的 ACK 可以将原 unknown 结算，包括重启后，不影响新门操作。

`actuator_ack` 仅表示认证执行器报告已处理命令，不证明门已打开，也不证明普通门磁变化由这次命令导致。UI 必须同时匹配 operation_id 与 authority_node。没有实测门磁时物理状态仍不可确认；本任务不虚构门磁发布 API。

有 ACK 配置时，从适配器接受后等待四秒，超时将原行置 `unknown_after_dispatch`、原因为 `ack_unavailable`。断线将未决发送置为 `transport_ambiguous`，重连不重发。无 ACK 配置仍保持 `dispatched/ack_unavailable`，断线后同样未知。反馈观察最多 2048 项，断线清扫每个 loop turn 最多持久化 32 行；停机取消 timer/清扫，重启沿用台账恢复规则，未知记录不被静默驱逐。

执行器要去重必须先持久化操作 ID 再执行副作用；测试执行器只是有限参考契约，不是向现有 Home Assistant 部署的新实现。Core 即使看到去重能力也只发送一次；未经过设备资格验证时不承诺端到端物理恰好一次。

验证公钥必须使用规范 Edwards 编码，并拒绝八个低阶点，避免既有余因子验证器对这类公钥无法建立认证。固定坐标是 [libsodium](https://github.com/jedisct1/libsodium/blob/1.0.18/src/libsodium/crypto_core/ed25519/ref10/ed25519_ref10.c#L966) 同样检查的标准 Ed25519 点；签名验证仍使用既有 Monocypher。

参考执行器分别持久化 pending/completed。取得 ID 后、记录完成前崩溃时，不发送成功 ACK，也不重试模拟动作；结果保持未知，不承诺严格一次完成。
