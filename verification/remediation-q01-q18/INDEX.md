# Remediation evidence index (2026-09 T01–T35)

The raw evidence (command logs, source manifests, patches, screenshots) was removed from the
working tree on 2026-11-06. It is preserved in git at commit `0a6d02c`:

```sh
git show 0a6d02c:verification/remediation-q01-q18/<task>/<file>
git archive 0a6d02c verification/remediation-q01-q18 | tar -x -C /tmp/evidence
```

Human-readable task reports and the files still referenced by `verification/progress.json`
remain here. These results describe the pre-v3 codebase; security protocol v3
(`docs/en/security-v3.md`) supersedes the pairing, transport and media-authentication
behavior they qualified.

| Task | Title | Recorded status | Files at archive | Reports kept |
|---|---|---|---:|---|
| T01 | T01 执行报告 | VERIFIED_IN_SCOPE；验证范围：host_harness | 171 | report.zh.md |
| T02 | T02 执行报告 | VERIFIED_IN_SCOPE；范围：contract_review | 7 | report.zh.md |
| T03 | T03 执行报告 | VERIFIED_IN_SCOPE（production_test）；主任务已完成本卡范围内的综合验证和独立复核 | 31 | independent-review.md, report.zh.md |
| T04 | T04 执行报告 | VERIFIED_IN_SCOPE（production_test；主任务统一更新计划进度和平台版本） | 25 | report.zh.md |
| T05 | T05 执行报告 | VERIFIED_IN_SCOPE（production_test；主任务已完成独审并统一更新计划进度） | 28 | report.zh.md |
| T06 | T06 · 动作 API、查询与跨节点权威 | VERIFIED_IN_SCOPE，独立复核 PASS_IN_PRODUCTION_TEST_SCOPE；验证范围：production_test / 本机真实 Core + HTTP/TCP/认证 mesh + MQTT 协议接收器 | 45 | report.zh.md |
| T07 | T07：认证执行器反馈与诚实结果状态 | VERIFIED_IN_PRODUCTION_TEST_SCOPE；最终验证与独立复核通过 | 37 | independent-review.md, report.zh.md |
| T08 | T08 管理员会话执行报告 | VERIFIED_IN_SCOPE（production_test），独立复核通过 | 30 | report.zh.md |
| T09 | T09 执行报告 | VERIFIED_IN_SCOPE（production_test）；四项验收及主任务发现的集成退化回归通过 | 50 | independent-review.md, report.zh.md |
| T10 | T10 执行报告 | VERIFIED_IN_SCOPE；本任务 `production_test` 四项验收通过 | 50 | report.zh.md |
| T11 | T11 执行报告 | VERIFIED_IN_SCOPE；`production_test` 四项验收通过，等待主任务独立复核及最终候选整合 | 62 | report.zh.md |
| T12 | T12 执行报告 | IMPLEMENTED；Web指定范围已验证，Core适配证据与交叉独立复核仍待汇合，未改progress | 82 | core-independent-review.md, report.zh.md |
| T13 | T13 执行报告 | IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务复核 | 29 | report.zh.md |
| T14 | T14 执行报告 | IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务独立复核 | 52 | report.zh.md |
| T15 | T15 执行报告 | VERIFIED_IN_SCOPE；最终 iOS 严格重复帧断言已由独立 Air 1 UIKit runner 完成，23/23 PASS，详见 `device-uikit-report.zh.md` 与 `evidence/device- | 142 | device-uikit-report.zh.md, report.zh.md, windows-independent-review.md |
| T16 | T16 当前实施断点 | — | 33 | preparation.zh.md, relay-implementation.ja.md, relay-implementation.md, relay-implementation.zh.md |
| T19 | T19 执行报告 | VERIFIED_IN_SCOPE（production_test） | 8 | report.zh.md |
| T20 | T20 执行报告 | VERIFIED_IN_SCOPE（native_lifecycle / iOS Simulator；计划 progress 由主 agent 统一更新） | 43 | caller-audit.md, independent-review.md, report.zh.md |
| T21 | T21 执行报告 | IMPLEMENTED_AND_TESTED；等待主 agent 独立复核，不由本子任务修改计划完成状态 | 58 | report.zh.md |
| T22 | T22 Windows Core 时间快照 | VERIFIED_IN_SCOPE（native_source） | 29 | report.zh.md |
| T23 | T23 执行报告 | IMPLEMENTED_AND_TESTED_PENDING_INDEPENDENT_REVIEW | 63 | report-r3-history.zh.md, report.zh.md |
| T24 | T24 执行报告 | VERIFIED_IN_SCOPE（native_source） | 9 | report.zh.md |
| T25 | T25 执行报告 | IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务独立复核 | 31 | caller-inventory.md, report.zh.md |
| T26 | T26 · 本地配置原子基准校验 | VERIFIED_IN_SCOPE（production_test） | 51 | report.zh.md |
| T27 | T27 后台三方合并与可见冲突 | 实现与目标层验收已通过；等待主任务最终独立复核及 canonical 状态更新 | 51 | caller-inventory.md, report.zh.md |
| T28 | T28 执行报告 | VERIFIED_IN_SCOPE | 75 | design.md, independent-review.md, report.zh.md |
| T28-Web | T28 Web 冲突查看与解决子报告 | PASS_IN_PRODUCTION_HTTP_BROWSER_SCOPE** | 65 | report.zh.md |
| T29 | T29 执行报告 | VERIFIED_IN_SCOPE；最终定向、崩溃、完整 Core 回归、历史 SDK 构建及独立复核均已通过 | 74 | independent-review-initial.md, independent-review.md, report.zh.md |
| T29-crash | T29 磁盘崩溃独立子项 | 真实生产路径测试 PASS（本机持久化范围）** | 17 | report.zh.md |
| T30 | T30 配置导入/导出界面 | IMPLEMENTED / INTEGRATION_PENDING | 21 | checkpoint.zh.md, preparation.zh.md, report.zh.md |
| T31 | T31 implementation boundary proposal | read-only inventory. T15 has been accepted by the parent; implementation awaits agreement on the shared T16 helper contr | 17 | read-only-plan.md |
| T35-Web | T35 Web 访客门口机子报告 | PASS_IN_WEB_UI_PROFILE_SCOPE / INDEPENDENTLY_APPROVED** | 66 | report.zh.md |
| T35-android | T35 — Android 访客端子报告 | PASS_IN_API35_UI_AND_HOST_BUILD_SCOPE** | 461 | report-r6.zh.md, report.zh.md |
| T35-ios-compat | T35-ios-compat 执行报告 | PASS_IN_ISOLATED_IPAD_UIKIT_SCOPE；生产动作/布局宿主与历史 SDK 构建通过，真实 iPad 1 独立 UIKit 测试包四项共 95/95 通过；完整正式应用集成及系统 VoiceOver/物理旋转资格仍 | 311 | report.zh.md, uikit-report.zh.md |
| T35-ios-modern | T35 — iPad / iPhone 门口机子报告 | IMPLEMENTED_PENDING_UI_RUNTIME** | 577 | preparation.zh.md, report-r3.zh.md, report.zh.md |
| T35-windows | T35 Windows 子项报告 | IMPLEMENTED，WPF 目标运行验收 NOT_RUN / BLOCKED_ENV** | 70 | independent-review.md, report-r2.zh.md, report.zh.md |
| device-inventory-20260922 | Physical device availability inventory | — | 5 | report.md |
| parallel-batch | 2026-09-22 并行修复批次报告 | T03/T09 已在 production_test 范围验证，T20 已在 native_lifecycle 范围验证；三张卡的计划状态均已更新为 VERIFIED_IN_SCOPE | 68 | concurrent-ui-design-review.md, report.zh.md |
