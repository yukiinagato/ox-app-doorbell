# T28 Web 冲突查看与解决子报告

状态：**PASS_IN_PRODUCTION_HTTP_BROWSER_SCOPE**。本子报告不关闭 T28 总卡；Core 历史、复制顺序、容量和持久性由主任务及其独立复核报告负责。

## 生产修改与真实反例

本次独立检查主任务新增的 `renderConfigConflictBanner` / `reviewConfigConflict`。当前值、各作者候选和完整自定义 JSON 均明确展示；管理员必须选择后才能提交。请求携带 snapshot revision 和该实体全部当前 heads；409 不自动重写，敏感候选要求重输，401 清空任意 JSON 输入而保留非敏感选择。

发现并修正三个问题：

1. 选择控件没有可访问名称。真实 IAB DOM 观察和新增测试出现 12 PASS / 1 FAIL；补现有 i18n 标签的 `aria-label` 后 13/13 PASS。
2. 已打开页面的原后台轮询只读取 status/events，新远端冲突不会主动显示。真实浏览器定时反例出现 13 PASS / 1 FAIL；已有单飞轮询加入 `refreshConfig`，保留认证代次和超时，全部 14/14 PASS。它不调用 `renderTab`、不替换 `editorBase` 或正在编辑的 DOM。新增用例确认手动 JSON 原样保留且没有自动提交。

3. 主任务独立复核 R7 发现重复 banner 渲染会移除 Review 键盘焦点。新增实际定时反例 14 PASS / 1 FAIL；稳定 markup 保留 DOM，点击按 entity 读取最新候选，列表变化后恢复同一实体焦点。三轮实际后台刷新验证，最终 15/15 PASS。

生产改动仅以上新 T28 UI 与后台轮询相邻段，没有改写 T27 三方合并算法。五秒轮询现在读取完整有界 snapshot；没有增加 Core fingerprint 接口，本次不宣称已测大配置持续轮询成本。r5 真实 HTTP 联测在焦点修正之前执行；最终 focus patch 由独立的新浏览器证据绑定，不改写旧运行身份。随后用完整 r6 重做真实 HTTP/IAB 链路，最终结果同样 PASS。

## 已完成证据

- `evidence/controlled-browser-red.json`：选择控件反例。
- `evidence/controlled-browser-green.json`：首轮 13/13。
- `evidence/controlled-browser-poll-red.json`：后台发现反例。
- `evidence/controlled-browser-poll-green.json`：最终 14/14。
- `source-web-final.json`：最终焦点修正后的 Web、测试夹具与两节点 fixture 输入。r5 对照保留为 `source-web-r5.json`，原快照目录未覆盖。
- `evidence/controlled-browser-focus-red.json` / `controlled-browser-focus-green.json`：R7 的 14/15 → 15/15。
- `evidence/web-focus-targeted-regression.json/.log`：最终焦点修正源的三个 suite 再次 PASS。
- `evidence/web-targeted-regression.json/.log`：最终冻结源码的 3 个 Node.js suite PASS，包含 admin runtime、typed merge 和 admin logic。

上述浏览器用例在真实 Codex IAB / Chromium 153 中执行生产 app.js、真实 DOM、事件回调和定时器；XHR 服务端受控，明确不是真实 Core HTTP 端到端。覆盖显式当前值/head/custom/delete、完整替换而非静默字段混合、敏感候选拒绝、刷新保留草稿并更新 revision/heads、409 单次失败、401 旧回调隔离、非法 JSON、HTML 转义和容量提示。实际 1280×720 视图截图已在工具交互中检查，弹窗文字与动作可读；不是 iPad/UIKit 截图或物理设备资格。

## 真实 Core 联测准备

`tools/verification/config_conflict_fixture.cpp` 使用实际 RealClock、Runloop 和两个 Node，生产配置 CAS / Store / 认证 InMemNet 复制 / Httpd。只用专用目录、PSK 和测试密码，无外部 SIP 或执行器。HTTP 沿用生产 wildcard listener，浏览器客户端访问 127.0.0.1；不能将其描述为只绑定 loopback。

开发 r4 静态库已实际完成共同祖先、分区分别写入 A/B 意图、heal 后双方一致可见冲突，并干净退出。开发库的内嵌 Web 尚未包含本卡最终修改，因此不将它冒充最终 UI/Core 联测。首轮改用主任务 `source-green-r5.json` 的冻结源码、内嵌 Web 和静态库编译，完整输入和二进制哈希见 `core-http-fixture-build.json`。

可选 `--deferred` 在浏览器先登录后，通过专用数据目录 marker 触发分区编辑，便于验证页面不刷新也会显示实际远端冲突。最终联测实际执行：先在 A 的真实后台登录，打开 Quick replies 新建弹窗，输入未保存草稿；再触发真实分区 A/B 写入与重连。没有刷新页面，后台自行出现 Review 提示，草稿文字和输入焦点保持。取消该未保存草稿，查看真实冲突候选，明确选择原先 LWW 未生效的 A intent 后保存。弹窗和 banner 消失。

双方最终 snapshot 都为 A intent，未解决冲突数为 0；只读查询实际 SQLite 日志，双方仅有一条相同的新 resolution，其 parents 精确包含原冲突两 heads。`core-http-final/resolution-check.json` 保存实际检查结果；`real-core-browser.json` 明确记录人工 CUA 操作、观察和范围，不能当作自动 Playwright 日志。此链路完全使用生产 HTTP，没有 XHR 替换。它补充 T28-01 的可见性和 T28-04 的显式解决；T28-02/03 和更广 Core 故障覆盖仍由主报告负责。

## 环境与边界

browser skill 的独立 IAB discovery 未找到 backend 后，使用其可用 CUA IAB 回退成功执行。Mac 锁屏未阻止 IAB；它仍影响另一个 T35 原生 UI 任务，二者不混淆。未绕过系统锁屏、未安装应用、未触发实际开门或 SOS。版本、i18n 和计划进度由主任务统一管理。

最终真实 fixture 收到 SIGTERM 后 exit 0；18766/18767 无监听。独立受控服务 18768 已停止，两张本任务 IAB 页已关闭。源快照、构建产物和测试数据库保留用于审计。开发轮与最终轮分目录，没有回退或覆盖用户文件。

本子任务最初作为新 Web 主体的独立审查；R5/R6/R7 三项纠正由本子任务实施，纠正本身的独立确认交主任务。没有把自审冒充独立复核，也没有覆盖 Core 高风险独立报告。

## 最终 r6 集成与独立复核

R5/R6/R7 已由主任务独立签署，见 `evidence/root-corrections-review.json`。本子任务的主体独立审查与该纠正复核在 `independent-web-review.json` 单向关联，没有自审循环。

最终 r6 使用包含焦点修正的同一 app.js 和新的 Core 冻结源重新编译本夹具，实际重复了“已打开页面 + 未保存草稿 → 双 Node 分区编辑/heal → 自动出现冲突 → 显式选 A → 两端相同 resolution”的完整链路。`core-http-r6-{build,run}.json` 均 exit 0；`real-core-browser-r6.json` 和 `core-http-r6/resolution-check.json` 绑定最终候选。r5 源、旧二进制与实际运行记录保留，没有改名冒充 r6。

最终 fixture 已干净停止，18766/18767/18768 均无监听，三轮本任务浏览器页均关闭。`acceptance.json` 只引用已完成实际记录。
