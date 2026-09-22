# T25 执行报告

日期：2026-09-23 JST（原始日志使用 UTC）。执行：`/root/t02_translation`。
状态：IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务独立复核。本任务未修改 progress。

## 来源与范围

生产修改仅 `webui/admin/app.js`。9 个 openForm 保存入口与 4 个直接 openModal 保存入口均已盘点、逐一迁移，详见 `caller-inventory.md`。本卡未修改 Node、全局 i18n、版本、生成物、progress 或现有 API 路径；翻译及受影响产物版本由主任务整合。T08 的 CSRF 请求头、GET/session 获取及认证/page epoch 保护保留。

开始前 app.js SHA-256：`50834004c39680a1649f831de8af0df7c5e5d90842ec6163afaf224c51656978`。
最终 app.js SHA-256：`ecfa4cac230ac7091c9cf6fb6e467590122bc5f7be9c3f2c827ae4065a669005`。
本卡生产差异 `evidence/production-diff.patch` SHA-256：`4f6a9181a1a1c998bdce46bae5fb38420ab643c1b7102f7ac68ac7bccf305b06`。

完整来源见 `evidence/before-source.json`、`after-source.json`。原文件保存在 `build/remediation-t25-20260923/before-app.js`，用于相同浏览器用例复跑 red。测试加载完整生产后台页面与生产 app.js，只通过既有 opt-in 测试钩子额外暴露编辑入口，不复制保存状态机。

## 行为

- 保持 ES5 显式 completion，不引入 Promise 要求。弹窗保存状态区分 editing/submitting/failed/succeeded；只有所属请求明确成功才关闭。同步校验错误不发请求，失败不刷新配置覆盖草稿。
- 提交期间禁用该弹窗的输入及保存/取消按钮，防止重复提交和意外丢弃；完成后恢复原 disabled 状态。失败保留原 DOM、字段、焦点和滚动位置，并在弹窗中显示错误；原已保存结果和可读性警告仍显示。
- 每次保存绑定弹窗、尝试序号和 page epoch。旧保存成功既不关闭新弹窗，也不在其下方触发旧配置刷新；成功后的刷新继续检查页面及弹窗代次。
- 会话失效或页面生命周期停止时保留非敏感的原表单 DOM，清除 password/data-sensitive 字段及临时 panel token，暂停弹窗以让登录可达。重新登录并完成现有初始化后恢复原草稿，提示重新输入密码/密钥。草稿不进入 localStorage，也不写入诊断包。
- 配置/secret/notice 保存使用 10000 ms deadline；既配置原生 XHR timeout，也保留 watchdog 与一次结算。timeout、网络断开和不能确认的提交结果提示未知，保留草稿，不自动重试。迟到成功不能把已恢复编辑的弹窗关闭。
- 配置提交结果未知时不回滚删除新 secret：该配置可能已经引用它。只有明确拒绝才允许清理未引用的暂存凭据；成功后仍按原流程清理旧 reference。修正公告预设在失败重试时重复追加草稿项的问题。

四个新键由主任务加入并生成：`admin.saving`、`admin.save_unknown`、`admin.draft_sign_in`、`admin.draft_restored`。

## 实际验证

运行 `node webui/tests/admin_modal_browser_fixture.js`，服务在 `127.0.0.1:18764`。通过 `cua_repl` 操作 Codex IAB 原生 Chromium 153，访问 `/?phase=red&lang=en` 和 `/?phase=green&lang=en`，点击 Run four admin draft tests。测试使用完整真实管理 DOM、真实规则/语音/公告/楼栋编辑入口和实际保存辅助函数，在 XHR 边界注入响应、慢请求和 timeout 事件。

最终 red/green 使用相同用例 SHA-256 `3bcf026f917d757cb4187392e117eea6fb2d552bee9112b2b29cf9e0032f929d`。来源、浏览器版本、时间和逐项结果见 `browser-red.json`、`browser-green.json`。

| 验收 | 修改前实际失败 | 修改后实际结果 |
| --- | --- | --- |
| T25-01 | 规则保存 500 后弹窗关闭 | 原字段节点、值、checked、焦点、非零滚动位置全部保持；无失败后配置刷新 |
| T25-02 | 慢请求连续点击产生多次提交 | 仅一个写请求，提交期间无法重复保存或取消，服务器确认成功后才关闭 |
| T25-03 | 401 后明文 secret 留在表单 | 登录可达，非敏感语音配置原 DOM 保持，secret 清空且未进入 localStorage；登录后恢复，旧响应不能关闭草稿 |
| T25-04 | 旧成功在新弹窗下刷新配置 | 新弹窗、字段、焦点不变；旧成功不触发配置刷新 |

五项补充测试也通过：同步校验不发送请求；公告专用 API 失败保留编辑；失败预设重试不重复；secret 配置提交 outcome_unknown 不发 DELETE；原生 timeout 事件及迟到成功只结算一次。最终 **9/9 浏览器用例 PASS**。其中同步校验是已有正确行为，red 也通过，其余补充业务反例在旧源上失败。

开发中滚动用例曾因窗口足够高而初始 scrollTop 为 0，归类为夹具问题，记录于 `browser-fixture-scroll-diagnostic.json`。夹具随后明确约束可滚动编辑区域并要求初始滚动非零，再以相同最终用例对旧源和新源重跑；没有降低滚动断言。

全部 **18 个** `webui/tests/*.test.js` 实际运行退出 0，命令、时间、退出码、原始日志见 `web-suite.json` 和相应 `.log`。第一轮仅翻译尚未生成导致 admin_logic 的新键检查失败；主任务完成生成后最终整套通过。生产/夹具语法、限定差异空白、i18n 一致性和英文源检查通过，见 `checks.json`。验收汇总为 `acceptance.json`。

## 限制与后续

XHR 响应和 timeout 事件由受控夹具注入，本卡不声称对运行中的 Core 执行过管理写入，也没有真实 secret、设备动作或外部服务调用。原生浏览器 DOM 验收与主机回归不替代设备、嵌入 Core 页面、签名安装或实际网络资格。综合候选的嵌入资源和应用版本由主任务继续核对。

本卡仍使用既有 `/api/config/batch` 弱并发语义。T26 的 C08 snapshot/commit 合同与 T27 的管理 UI CAS 迁移尚属独立任务，未提前声称已完成。未知结果的 secret 保守保留也不等于完整崩溃恢复台账。

## 主任务独立复核

/root 已核对最终 app.js SHA、13 个编辑保存入口、状态和敏感字段生命周期及 9 项同源浏览器反例/通过证据，并独立执行 admin_logic 与 admin_runtime，均通过。复核记录 evidence/review.json；T25 在 production_test 范围关闭。当前并行 T15 页面变更引入的 T10-04 关闭后计时器回归已单独记录并交 T15 修复，不改写 T25 冻结候选的原始 18 套 PASS 证据。

## 证据路径更正（2026-09-23 01:19 JST）

T27 开发夹具误把新候选运行写到了本卡原 browser-green.json。该次覆盖内容已保存在 T27/evidence/draft-browser-development-r1.json，原路径标记为 SUPERSEDED_EVIDENCE，不再作为 T25 原始运行证据。未能逐字恢复原 JSON，因此实际重新加载 T26 r4 留存的同一 T25 app.js（ecfa4cac…）与同一原用例（3bcf026f…），在真实 IAB 重新运行 9/9 PASS；新记录为 T27/evidence/t25-revalidation-green.json，时间 2026-09-22T16:19:20.824Z。acceptance 已引用新记录。历史 root review 保留；此次重验不伪称恢复了原始运行时间。夹具现在显式指定输出目录及文件前缀。
