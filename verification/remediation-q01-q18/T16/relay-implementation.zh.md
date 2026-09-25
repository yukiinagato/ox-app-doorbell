# T16 同源、鉴权、资源有界的视频回传实现

状态：**IMPLEMENTED_CANDIDATE；完整生产验收 BLOCKED_ENV / NOT_RUN**。
基线：`39b57222b45d83e2116a65b3d5242718d56fac79`。发布门禁保持 **NOT_READY**。
未 push、部署、开门或触发真实 SOS；不因此关闭 T16、T17、T18 或 T31。

## 已编写的代码

保留浏览器现有相对路径 `/api/panel/media-authorize`、`/call-frame`，通过 `Httpd::routeWorker` 接入独立限额的既有 OperationDispatcher。JPEG 不再被调度器作为 JSON 解析；不建立任意 HTTP 代理或额外线程池。

A 根据 door 解析唯一已配置的门口机。无目标、多目标（含离线竞争目标）、已移除或未连接的非可信 peer 均拒绝。入口只收固定身份字段，拒绝 URL、host、port、path、重定向及重复/编码重复字段。继续执行 Cookie、CSRF 和已有 trusted-Origin 约束，不增加携带凭据的通配 CORS。反向代理必须使用既有明确可信原点配置，不能靠任意转发头绕过。

A 验证原面板会话、凭据/权限版本、door 范围、media.publish、发布者 WebDialogLease，以及当前 call/revision/owner。跨节点必须使用 T31 独立面板身份；旧共享身份仅保留本机回传兼容。B 不需要持有 A 的浏览器凭据。

经既有认证加密 Mesh 临时命令传输授权、帧、结果和撤销。只委托公开 principal 字段；不传 Cookie、CSRF、长期 Bearer、secret 或 secret 引用；不把 JPEG 写入 CRDT 或持久事件。

B 发放 generation，并以 B 的单调时钟固定授权期限，绑定来源 peer/epoch、目标、principal、通话身份与授权请求。重复授权请求不续期；退休请求进入有上限的防重放记录，满额拒绝而非淘汰有效记录。A 收回复时重新验证原会话/租约/通话；错误请求 ID、peer、代次、响应类别、序号无法完成其他请求；不跟随 3xx。

A 发帧前校验，B 在有界 JPEG 校验后、写入既有 peer_frame 返回视频槽前再次校验完整权限及通话身份、序号、期限。跨节点不直接比较两个单调时钟的绝对值。成功只表示 `remote_core_accepted`，**不表示屏幕已经显示**。

每个发布者一帧在途加一帧最新待发；替换待发项明确丢弃旧项。超时/撤权/换通话/换代次/peer 变化清理队列与缓存，旧回复不得复活授权。停机先唤醒 HTTP waiter，再在 loop 清理 RPC/队列；不在 Core loop 内等待网络或 join HTTP/传输线程。敏感 `/peer-frame.jpg` 仅供原本机发布会话或无浏览器凭据的 loopback 原生接收端；其他合法面板即使经 loopback 也不能读取。原有 LAN-public 摄像头 feed 不改。

## 限额与兼容性

HTTP 总池仍为 16；授权与帧共用最多 4 个媒体请求。授权 form/query 2 KiB；JPEG 1 MiB；8 个授权/速率记录；4 个 RPC/队列发布者；每发布者一在途一最新待发。发布者 10 帧/秒、突发 2，全局 20 帧/秒、突发 4。读完 body 后处理等待 3000 ms，RPC 2500 ms，50 ms 清扫；原有 body 读取 5 秒上限单独计算，不能称总 HTTP 时长恒为 3 秒。授权最多 10 秒，跨节点预留 RPC 行程预算；防重放记录最多 64。保留基线 TCP 输出队列上限。

JPEG 限制为 baseline、单扫描、8 位灰度或三分量；单边不超过 1024，像素不超过 307200。渐进式/多扫描 JPEG 明确拒绝。base64 在解码前校验规范编码及解码长度，Mesh JSON 仅允许有界扁平字段。有界 JPEG 解码仍消耗 Core CPU；不能由队列上限推导整个进程 RSS，也没有证明老设备上的解码延迟、真实 HTTP 公平性或慢 peer 性能。

## 实际验证与尚未验证

本环境严格 C++14 编译、生产 bounds 测试 **50085 条断言**、生产 relay 组件 **9 组/40309 条断言**通过。包含确定性随机输入及 10000 次陈旧提交的循环，不是 90394 个独立集成场景。两类测试在 AddressSanitizer、UndefinedBehaviorSanitizer 与泄漏检测下均通过。命令、退出码、源码摘要、日志随交付包保存，可用 `local-tests/run.py` 在注明的 Linux 依赖环境复现。

组件直接包含新增生产 `.inc`，但外围 Node 权限、HTTP 调度、时钟/loop、Mesh 为明确的夹具；JPEG 测试适配器使用 libjpeg，不是仓库 stb。它们不能证明真实 Node、TCP、SecureChannel 或 HTTPS 浏览器整合。

已增加供真实仓库运行的 bounds 测试、既有发布测试中的严格目标/form/JPEG 子项，以及两个真实 Node 经 HTTP→Mesh→B 返回槽的集成测试。**本环境未编译、未运行完整 Node 测试。** 未削弱 T15 原有会话/代次/读取隐私断言；仅将不再适用的“其他目标一律未实现 501”改为“未知目标拒绝 409”。

应用器在合成锚点仓库上验证了完整预检查、生成 Git patch、应用/暂存、并发编辑拒绝、重复应用与符号链接拒绝；这不是对完整仓库应用成功的证明。真正应用前会在用户机器检查基线 SHA、所有锚点及工作区；不回退更新的提交，不覆盖用户改动。

T16-01 的真实 HTTPS/浏览器用例、T16-03 的慢 peer 与连续上传并行 status/SOS/内存测量，以及 T16-02/04/05 的完整生产层用例均保持 **NOT_RUN**；对应组件覆盖仅作部分证据。完整 Core 回归、真实 SIP 构建、历史 SDK/设备、独立复核也未完成，因此不能将整卡写成 VERIFIED_IN_SCOPE。

本地命令在提交前执行 Core/SIP stub 构建及全部 doorbell_tests、i18n 一致性与英文源检查；stub 通过不代表可发布。保留 T17/T18、T31 及设备资格门禁。

版本递增：Android 0.3.21/22→0.3.22/23；现代 iOS 0.1.37/38→0.1.38/39；iOS-kiosk 0.3.49/52→0.3.50/53。未改 ios-legacy、公有原生 C ABI，也未增加用户可见字符串、SDK、签名材料或编译产物。

`relay-progress.json` 仅记录本候选的 T16 状态，不覆盖未核实的全局进度表，也不升级其他任务状态。
