# T12 执行报告

日期：2026-09-23（JST）  
执行者：t02_translation（Web）；root（Core会话适配、翻译和版本）  
状态：IMPLEMENTED；Web指定范围已验证，Core适配证据与交叉独立复核仍待汇合，未改progress。

## 来源与范围

审查参照及执行前HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。工作区有其他任务和用户修改，使用精确增量修改。T09请求通道、T10轮询、T11租约及T15媒体实现保持原样。

Web独立冻结目录：`build/remediation-t12-20260923/web-final-source`。源码、环境、版本和资源SHA见 `evidence/web-source.json`，修改前来源见 `before-source.json`。只含本卡Web变动的补丁为 `web-production-diff.patch`，SHA256：`02bc5d229b8904b872585b57b178e19594f26261b651294e218841b8728ac28b`。

本卡随本轮共享Core/Web版本交付；冻结时现代iOS为0.1.37/38、iOS5 kiosk为0.3.49/52，其余受影响应用版本由root统一记录。Web资源验证不等于各平台已嵌入、签名、安装或真机运行。

## 真实生产入口与修改

1. `webui/panel/runtime.js` 的实际 `installEmergencyOverlay` 使用同一内部SOS控制器，经 `GET /api/panel/session` 取得会话CSRF，调用正式 `POST /api/operations/prepare`、`POST /api/operations/<id>/execute`、`GET /api/operations/<id>`。操作为schema2的 `sos_start`；不提交任意principal、不使用Bearer，不回退旧SOS端点。查询也携带CSRF。
2. 每个请求通过T09真实XHR deadline和watchdog限制为4秒；控制器最多一个在途请求，句柄和代次只归其自身。准备成功后执行同一ID。执行超时、网络断开、500或无法解析的响应显示结果未知；恢复按钮先查询原ID，不能自动prepare新呼救。
3. 查询权威记录为`prepared`时提供普通按钮显式执行同一ID；记录为明确未执行的终态时，才允许新用户动作重新准备。403、401和validation错误显示原因，按钮可继续操作。未知执行后的查询被拒绝，仍保留原ID和结果未知，不谎称原呼救从未执行。
4. 三页面共享可见结果框，区分准备中、发送中、查询中、系统受理、明确未发送、拒绝、结果未知，并始终提供其他求助方式说明。“系统已受理”不声称通知送达。只有复制状态或有效Push决定active SOS展示，不用HTTP成功制造active状态。
5. 页面离开取消本页请求和长按计时器；晚旧回调不改变新请求。只将operation ID、authority和固定action写入tab sessionStorage，保存过程不含凭据/CSRF。重载后保持未知并先查询，避免door页面正常刷新变成新呼救。存储不可用时仍保证当前页面生命周期内的单意图恢复，不声称跨重载恢复。
6. `call.html`、`door.html`、`monitor.html` 各最小接入翻译函数及语言更新；共同结果框使用16个由root统一生成的三语key。现有2秒长按保留；辅助技术的零detail按钮起动及普通查询/重试按钮走同一控制器，不以隐藏SOS或无限禁用规避重复。
7. SOS复制active/clear、raw状态优先级、Push/规则TTL、零接收者策略及原管理/kiosk清除权限没有重写。明确active→clear后，已受理的旧意图可结束，后续新SOS仍可发起。英文和日文panel API紧急操作说明已同步。

## Web验收和回归

实际环境：macOS26.5.1 arm64，Node v25.9.0。测试执行生产runtime和真实overlay，网络/时钟/DOM为可控fixture；三页面测试执行各自真实 `installEmergency`、`applyEmergencyI18n`，不是仅检查源码字符串。

| 验收/保护 | 操作与实际观察 | 结果 |
|---|---|---|
| T12-01 | 已建连execute黑洞；推进4秒，真实XHR abort、计时器清零，结果未知与替代帮助可见，按钮恢复 | PASS |
| T12-02 | 执行已受理但响应丢失；多次恢复仅GET查询同ID，prepare一次、execute一次 | PASS |
| T12-03 | 403、validation 400、401分别显示权限/输入/会话原因，重试按钮可操作 | PASS |
| T12-04 | 双起动、原生timeout、watchdog、晚成功交错，单次结算，旧成功不清新query | PASS |
| 原ID恢复 | query返回prepared需显式执行同ID；unknown_after_dispatch只能继续query | PASS |
| 错误分类 | 500、断网、200畸形JSON不显示未执行 | PASS |
| 生命周期 | pagehide取消自己的请求；重载从tab存储恢复原ID且不自动发送 | PASS |
| 准备响应丢失 | 不execute、不自动重prepare；无句柄时明确显示准备未确认、未发发送请求，用户重试是新一次准备而非找回旧句柄 | PASS |
| 确认未执行 | not_started先查询；权威expired_not_started后才能新prepare | PASS |
| 失效权限 | ambiguous后的403 query保持unknown与原ID，重新取得会话信息后仍查询原ID | PASS |
| 三页面与辅助技术 | 全部显示结果/查询按钮，辅助点击共享一个意图；unknown状态不清既有SOS，显式clear仍有效 | PASS |

新增生产overlay用例共13个，原始最终输出 `evidence/final-sos_operation.test.log`。全Web共21套 `*.test.js` 全部PASS，含T10页面关闭零残留timer、T11 heartbeat、T15媒体和所有原SOS状态回归；生成资源检查、英文源码检查及本卡空白检查PASS。完整命令、cwd、退出码、日志见 `evidence/final-checks.json`。

修复前同一生产overlay仍发送 `/api/panel/emergency`，初始4项验收在协议路径断言真实失败，见 `web-red.log`。开发首轮中三页面函数提取夹具误在对象括号终止，7项业务已通过但第8项夹具语法失败；已修夹具提取边界，未放宽生产行为断言。逐轮命令/结果及分类见 `web-development.json`。随后补充语言重绘不重复交付结果的回归：`web-repaint-red.log`证明旧render路径重复回调，最终测试已通过。

## Core适配与独立复核

root实施最小dbpanel会话主体适配：仅sos_start、现有页面节点明确grant、固定authority、会话CSRF/精确Origin、原会话creator执行/查询；不提前宣称T31独立panel身份或分机provisioning完成。Core真实HTTP记录为 `evidence/panel-red.json/log` 与 `panel-green.json/log`；最终冻结来源 `core-source-green.json`。两个真实Node通过HTTP与SecureChannel覆盖，3 cases/195 assertions PASS；相关Core回归36 cases/2917 assertions PASS，见 `evidence/core-related-regression.json/log`。

t02初审发现同origin有效dbsess与dbpanel共存时，先选admin会导致用panel CSRF校验admin会话而403，并可能中途切换principal。已立即通知root，匹配有效panel CSRF优先选择原panel会话的补丁及实际双Cookie回归已通过；此发现保留在独立报告。

Core适配独立复核PASS，详见 `core-independent-review.md`；Web由root独立复核，整卡关闭仍由root负责。独审对照真实Node响应还发现新Web夹具误用`csrf`，实际合同是`csrf_token`；先改夹具保留`web-session-contract-red.log`，再改生产并重跑全部21套通过，最终源码已一致。

## 限制与下一步

未发送真实SOS，未触发真实门锁、Push或外部联系。未运行真实浏览器视觉/辅助技术设备、平台嵌入包或真机；Mac锁屏仍影响T15最后一项模拟器资格，本卡没有将其改写为PASS。

待Web独立复核通过后由root更新进度，再选择前置满足的任务。本报告不授权push、发布或部署。

## 主任务最终汇合

/root 已独立复核生产 Web 状态机、13 个行为断言、最终 21 套回归及冻结来源；Core由独立实现Web的t02复核。相关 Core 回归 **36/2917 PASS**，新增真实双节点HTTP/mesh **3/195 PASS**，未触发真实求助。二者来源分别冻结并在 source-combined.json 汇合，host二进制完整SHA写入证据。T12 在 production_test 范围 VERIFIED_IN_SCOPE；T15 的最终模拟器运行和后续真机/UI视觉资格没有被此卡覆盖。
