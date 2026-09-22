# T30 配置导入/导出界面

状态：IMPLEMENTED / INTEGRATION_PENDING。尚未独立审查或关闭任务。

管理页系统区域使用 stage → preflight → 明确确认 → commit。默认合并到最新快照；完整替换为显式选项，预览列出删除数量与每项差异。缺 secret/asset 或预检不通过不能提交。阶段/摘要/配置版本响应绑定，丢响应只读查询同一 operation，不自动重发或创建新导入。

导出版本 2 envelope 包含来源版本、范围与 excluded_paths，剔除遗留密码、令牌、私钥、携带凭据的 URL，保留合法 secret: 引用与无关文本，不生成可被当作凭据的脱敏占位符。缺失字段在再次导入时明确显示，三语文档指引通过安全存储/集成/资源页分别恢复。

恢复记录只包含 schema_version、operation_id、stage_token、digest、node_id，发送前保存在该标签页 sessionStorage。401 清除文件内容，旧响应不可把新登录标为成功；页面刷新只恢复查询入口。查询未找到结果仍未知；用户必须明确确认保存旧引用后才能开始新预检，旧引用仍显示，不会自动提交。成功仅指此节点持久提交，其他节点同步未经验证；连接在线数量另列，不作为收敛证明。

## 证据

- source-final-r1.json：118 个冻结 Web、资源、生成工具、夹具与文档输入，build/remediation-t30-20260923/final-source-r1。
- helper-red.log：原基线没有导入转换/脱敏 helper 的真实失败；helper-green.log 和 admin_import.log 为实际通过。
- controlled-browser-fixture-r1.json：14 项失败，测试夹具在 boot 完成前切页导致超时，保留历史。
- controlled-browser-r2.json：12/14 通过，两项夹具文字断言/异步切页等待失败；修正后 r3 17/17 真实 IAB 通过。
- controlled-browser-r3.json：生产 DOM、实际按钮/checkbox/File API 与受控 XHR；明确不是 Core HTTP E2E。覆盖 257 条、完整替换删除预览、缺 secret/asset、摘要绑定、严格 JSON、容量、stale revision、丢响应 query、重复点击、401、重载恢复、导出脱敏与旧未知引用确认。
- host-regressions.json：admin_import / admin_logic / admin_config_merge / admin_runtime / panel_i18n 全部 exit 0。
- i18n-check.log 与 english-check.log：通过。
- visual-review.json：实际 IAB 1280×720 预览语义/截图审阅；截图在工具会话，无虚构导出图片。

## 待完成

root 使用 T29 green-r4 原生 Core 与冻结 Web 构建独立真实 HTTP/SQLite 夹具（port18771）并联合验证，独立审查、验收引用和清理；这些不由受控 XHR 替代。硬件最大内存、全网特定 revision ACK、平台完整灾难恢复备份不属于当前通过范围。
