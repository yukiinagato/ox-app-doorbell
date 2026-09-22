# T28 执行报告

日期：2026-09-23 JST。执行：root；Core 独立复核：t02_translation；Web 主体复核与浏览器联调：t01_evidence_review。

状态：VERIFIED_IN_SCOPE。本卡 Core/生产 HTTP/IAB 指定范围完成；整个计划与各设备发布资格尚未完成。

## 来源与范围

当前 HEAD 为 `b26e0d346df99f2879915241b6e98d8ef1aa0707`，工作区 dirty。最终冻结 Core 候选 `source-green-r6.json` 的输入摘要为 `b8ef3946cdf448923aa75d5e77af82b2b8943fb2e5b6be352fdfa30411336227`，共 271 个输入；具体文件 SHA 与可复现构建在 manifest 和 evidence 中。未回退或覆盖其他任务与用户修改，未提交、推送、安装正式应用。

Core 和 bundled Web 影响本批各应用，版本沿本批统一递增：Android 0.3.21/22、现代 iOS 0.1.37/38、tvOS 0.1.14/15、iOS 5 0.3.49/52、iOS 9 armv7 0.4.3/403、Windows 0.1.14/0.1.14.11。此处不以宿主测试声称这些设备已安装或取得 SIP 资格；ios-legacy 保持归档。

## 生产入口与实现

既有 Node 配置服务、LwwMap 原子提交回调、SQLite config 事务与认证 Mesh SecureChannel 负责保存和复制。新增 config_edit_journal 保存 `_config_changes.<id>.<digest>` 内容绑定的不可变记录，普通 materialize/export 不暴露内部命名空间。没有新增共识或自动合并写入。

每次公开配置写入保存作者、128 位 change_id、实体基准摘要、全部已知父变更、每字段至多两个 LWW 基准身份、set/delete 意图和脱敏候选。配置与记录同事务成功后才发布；失败回滚值、版本和复制进度。实体以顶级配置区为单位，设备以 devices.<id> 分离。未解决实体拒绝普通覆写；显式解决必须同时匹配当前 revision 和全部 heads，并替换/删除完整实体。普通清理不会删除保留记录。

独审修复了远端记录未知字段/父版本验证、原生 setter/公告/旧 import 绕过、devices 集合根删除、子字段 delete 冒充整实体解决四类问题。合法 secret: 引用保留，其余敏感值及带凭据可能性的 URL 使用需重输标记，不把明文候选传播到历史。

管理页展示实际生效值与各分支，允许明确选当前、候选或手工完整值；过期或未知结果不自动覆写。后台轮询发现远端冲突，不重建编辑表单或丢掉未保存草稿。新增文案仅由 i18n/strings.yaml 生成，英文/日文/中文配置文档同步。

## 验证

| 项目 | 真实证据层与结果 | 证据 |
|---|---|---|
| 初始反例 | 旧生产两 Node 路径缺少 edit_conflicts，2 项业务断言失败；编译成功 | evidence/red.json、red.log |
| 独审反例 | r4 生产库上 8 cases / 168 assertions，7 cases / 41 assertions 失败 | evidence/independent-review-red-r3.json |
| T28-01 | 实际 Node/Mesh/SecureChannel/SQLite 的隔离编辑与复连，A/B 意图在所有副本可见 | evidence/green-r5.json、green-r5.log |
| T28-02 | 第三观察节点先接收 A 或先接收 B，再复连全部节点；候选集合一致，重复同步不新增记录 | 同上 |
| T28-03 | SQLite 注入 journal INSERT 失败，值/版本不变；重开存储、事件清理和墓碑清理后冲突保留；远端失败后能重新同步 | 同上、evidence/independent-review-green-r5.json |
| T28-04 | 精确 heads 的整实体解决，所有副本收敛且不再制造冲突；过期/缺少 heads/部分删除拒绝 | 同上 |
| 相关回归 | r5 26/26 cases、836/836 assertions；独立 8/8 cases、168/168 assertions | 同上 |
| Web 原回归 | 冻结 r5 的 21 组测试全部通过 | evidence/web-regression-r5.json |
| 实际浏览器受控网络 | IAB 的 15 项实际 DOM/交互通过，含 401 清敏感稿、409不自动提交、候选/当前/手工/删除、后台发现与草稿保留 | ../T28-Web/evidence/controlled-browser-focus-green.json |
| 实际 Core HTTP + IAB | 非拦截 XHR：先打开草稿，实际 A/B 分区编辑后自动出现冲突，选择原 LWW 输家 A；两 SQLite 副本都保留同一显式解决记录，引用原两个 heads | ../T28-Web/evidence/real-core-browser-r6.json、core-http-r6/resolution-check.json |
| 全部 Core 回归 | 最终 r6 506/506 cases、31,490/31,490 assertions 通过 | evidence/core-regression-r6.json |
| 历史 iOS 5 Core | armv7/min5.1 干净交叉构建与旧系统禁用符号检查通过，未安装 | evidence/ios5-core-r6.json、artifacts-green-r6.json |

所有命令、cwd、起止时间、退出码、二进制及源文件 SHA 见对应 JSON。host 为 macOS arm64、Debug、SIP stub；正式 SIP/旧 OS/硬件行为不在这组证据范围。真实浏览器 E2E 为 IAB Chromium 153 的实际工具操作记录；与受控网络的自动 DOM 断言分开记录。r1 编译失败及 r2/r3 夹具断言纠正保留，不冒充生产缺陷反例。

## 独立复核与限制

Core 独审在 `evidence/review.json` 签署 PASS_IN_REVIEWED_CORE_SCOPE，R1–R4 和脱敏边界已闭环。初始签署时全部 Core 回归尚未结束；最终 r6 完整回归现已通过，增量复核见 evidence/review-r6-addendum.json。Web 主体与纠正分别记录复核人；定时重绘造成 Review 按钮键盘焦点丢失的 R7 已以实际 15th red/green 验证；root 独审 R5–R7 纠正通过。

每记录最多 64 KiB/256 操作；本地 512 条/每实体 64 条/总 512 KiB，远端预留两倍。已解决祖先也保留，当前没有经过覆盖证明的压缩机制，达到容量会阻止后续编辑甚至解决，绝不静默清掉候选。旧节点自行编辑不能提供完整意图保护。旧 import 目前共用普通 256 项限制，合法大备份的独立暂存与原子恢复由后续 T29 处理。

公开 ABI 保持添加式兼容；本卡未宣告设备实际支持此功能或硬件发布已合格。配置可能已按 LWW 生效，而冲突仍未解决，管理提示和三语文档均明确此边界。

## 下一步

T28 已完成指定范围验收，下一张依赖满足的任务为 T29 暂存导入。正式应用集成构建和设备资格仍由后续卡分别验证。

补充回归记录：r5 全部 506 项中 2 项失败（4 条断言），实际删除与数据回放仍成功；删除入口成功响应曾新增 batch 元数据，破坏既有精确响应契约，r6 已恢复原响应；两条迁移版本断言仍期待7，而已验收 operation ledger 使用 schema8，已修正断言并保留全部历史数据回放检查。原失败日志完整保留，未将其改写为PASS。r6最终全部通过。
