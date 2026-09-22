# T30 工作检查点

状态：IN_PROGRESS，未宣称通过。T29 已 VERIFIED_IN_SCOPE；用户要求额度重置后保存暂停，root 监测，最近通知额度 99% 已使用但未重置。

已落盘：webui/admin/app.js 导出脱敏与 JSON 严格转换 helper；staged/preflight/commit/query UI；i18n import_* 三语 keys 及生成资源；webui/tests/admin_import.test.js 真实 red（缺 helper）→ green，node syntax PASS。基线在 build/remediation-t30-20260923/baseline-source。

浏览器夹具：webui/tests/admin_import_browser_fixture.js / admin_import_cases.js，127.0.0.1:18770，仅生产 DOM + 受控 XHR，不能称 Core E2E。第一轮夹具等待 app visible 过早，boot 完成覆盖 System 标签导致 timeout，正在改为等待 nodeInfo 初始化；这不是产品通过证据。第一轮结果待最终落盘后留存。服务 exec session 48261，IAB tab 17。新增响应绑定/peer status 修正在当前源码，正在准备第二轮。

必须继续：完成真实 IAB 14+ cases（257、删除、缺 secret/asset、丢响应 query 同 operation、401、严格 JSON、导出）并保留失败；导出 excluded_paths 恢复缺项 UI；三语 UX 文档；host 回归；完整 source freeze（Web+资源+生成工具）；通知 root 构建 tools/verification/build_import_fixture.py 真实 T29 green-r4 Core 夹具（port18771）并联测；独审、report/acceptance、清理专用服务/页面。

恢复引用只 sessionStorage {schema_version,operation_id,stage_token,digest,node_id}，无文件内容/秘密；query unknown 不自动创建新 operation。成功仅本节点持久提交，其他节点同步未验证，真实连接状态不能代替收敛。

更新：17/17 真实 IAB 受控 XHR 通过（controlled-browser-r3.json），5 组 host 回归/i18n/English check 通过；三语 config-import-ui.md 完成。r1冻结根 build/remediation-t30-20260923/final-source-r1，manifest SHA7f0294b381fd23f892f2105dde0063a4f8bfdbe1958a4452dbc1e42faf36a9ed，app SHA144af4de97ab5950911a0e8397ff0335ef4cbe8a32d0293fe6f596315cc0da97。Root 已收到用于真实Core联测，未完成独审。当前服务 session45896（18770），IAB临时tab17测试页、18预览。root最新额度100%但未重置，继续授权工作直到重置通知。
