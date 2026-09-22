# T02 执行报告

日期：2026-09-22；状态：VERIFIED_IN_SCOPE；范围：contract_review。
执行：主 agent；源码盘点：`t02_contract_inventory`；翻译：`t02_translation`；
独立复核：`t01_evidence_review`。用户本轮明确要求并行，因此将互不重叠的文档与复核工作分开执行。

## 来源与保护

执行前后 HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。
工作区 dirty，tracked diff SHA256：
`4b3c164a85fd749fe6640e44c4b8b0b0b8fe3124fe4213fb9866e0763e7c91f0`。
本轮没有改变生产源码；进入执行时的 1216 个已有文件仍逐字节一致。
新文档和规范示例未包含在 tracked diff，精确内容由 source-manifest.json 记录。
应用版本/build 不变；没有新增应用产物或设备部署。

## 交付与真实入口

- 英文源：`docs/en/remediation-contracts-adr.md`；同步中文：`docs/zh/remediation-contracts-adr.md`。
- existing-symbol-map.json：C01–C09、HTTP/C ABI/mesh/HA/SIP 和全部原生壳入口；139 个当前源码位置；33 组字段/语义唯一归属。
- protocol-fixtures.json：15 个规范场景，供依赖任务实现和测试使用，不是已运行的生产 API。

复用现有 db_platform_v2、Core call identity、LWW 记录身份、panel binding、Core 时间快照、
Store 事务和 SecureChannel 加密基础。缺少的操作台账、CAS、媒体授权等明确标为新增能力。
实际 HTTP reader 是 8 MiB 阈值，SNAP 是 300 KiB，BLOB 是 3 MiB；没有将它们写成已满足新媒体/导入协议。

## 契约与独立复核

| 验收 | 结果 | 证据与含义 |
|---|---|---|
| T02-01 | PASS | 所有任务复用同一 operation_id、权威节点、持久状态和重试规则 |
| T02-02 | PASS | 缺身份/能力不默认授权；旧 ABI 语义保留并明确弱保证 |
| T02-03 | PASS | 发送、执行器 ACK、门磁观察分层；没有物理 exactly-once 承诺 |
| T02-04 | PASS | 本地 CAS 不等于全网事务；分区改密不承诺瞬间全局撤销 |

证据：evidence/review.json、protocol-fixtures.json、英文 ADR。
独立复核发现并已修正：SOS 必须保留无门的全局作用域；终态记录也需要总容量和保留规则；
媒体/面板/配置字段须定义过期、重启和续期；字段编码与唯一归属统一。
这属于设计反例复核，不冒充运行中的 red→green 业务测试。

文档检查退出码 0：139 个源码行锚点存在，33 组归属不重复，15 个场景覆盖四项验收，
英文/中文所有字段与数值一致，原有文件哈希未变，英文源策略通过。
实际检查说明、cwd、时间、来源与日志见 evidence/validation.json、validation.log。
因为没有修改可运行代码，没有重复上一张卡已通过的完整平台测试。

## 仍未完成的资格

跨节点媒体的有界 worker、授权委托和销毁隔离必须在 T15/T16 实现并复核；当前通道仍不能宣称符合这些要求。
跨节点冲突记录的存储预算与保留实现属于 T28；现有只保留赢家的 LWW 不足以关闭 Q12。
ADR 中数值是接纳上限，不是旧设备内存实测；各实现任务和目标平台任务仍需边界与实际设备证据。
这些门槛继续限制功能声明与发布，不由 T02 的文档通过代替。

## 下一步

按计划顺序，下一张为 T03。T04/T08/T09/T20 的前置也已满足，可以按用户要求在不冲突的修改范围内并行。
release_gate 保持 NOT_READY；两份 ZIP 中的问题仍未全部修复，未 push/tag/release/部署。
