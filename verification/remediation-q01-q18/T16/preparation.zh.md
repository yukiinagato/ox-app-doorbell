# T16 当前实施断点

T15已在2026-09-23完成指定范围验收，本卡IN_PROGRESS。以下仅是尚未实现部分的续接设计，不是已验证能力。

已完成真实HTTP body红→绿：core/tests/test_media_http_bounds.cpp对T29 r4旧生产库编译/链接成功，三个subcase（声明超1MiB、截断、chunked超1MiB）合计6业务断言失败；修后与15个既有HTTP tests一起16/16 cases、289/289 assertions通过。证据evidence/body-red-r1.json、body-green-r1.json及各原始log。真实测试为macOS arm64/CivetWeb，无模拟body读取。生产Httpd将header解析和body读取分开，先通用认证；读取严格长度与媒体1MiB、普通8MiB上限，超限/截断在route之前拒绝；同时最多4个媒体上传占16个HTTP worker，5秒请求读取超时。

OperationDispatcher添加可选Limits（capacity/body_bytes/timeout_ms/failure响应），默认保持既有32/8192/4000ms；准备给media复用所有权/超时/停机逻辑而不再创建线程池。独立构建与既有dispatcher四用例47断言已实际全部通过，见evidence/dispatcher-green-r1.json。尚未接Node媒体路线，不把参数扩展当实际媒体转发完成。

跨节点实施设计：

- 浏览器始终POST当前origin的/api/panel/media-authorize和/call-frame，不接受自由host/port/path/redirect。目标只从配置中的door_station+door以及当前可信Mesh peer确定，多个匹配站点应显式拒绝歧义。
- A以真实panelMutationSession+T31 panelSessionAllowed(session,door,"media.publish")、WebDialogLease.publisher_session和当前call/revision/owner验证；owner的节点前缀必须A。只发送服务端推导的PanelPrincipal公共字段，不传Cookie/CSRF/长期bearer。
- 远端授权必须先RPC到B，由B发128bit随机media_generation并以B单调时钟限定短TTL。不能只在A发token、每帧将remaining_ms重新变成B期限，否则延迟旧帧可复活授权。B的授权记录绑定SecureChannel来源A、principal、door/call/revision/owner；B校验dialogOwnerNode(owner)==A及T31 panelPrincipalAllowed，后者明确拒legacy_shared/缺ID。A收到授权响应仍需检查原会话/租约/当前call及代次。
- 每帧A先验证本地session/grant/currentlease；经现有认证加密Mesh transient command发送JPEG（有界base64），禁止写CRDT/event。B仅按已有B授权generation接收，TTL不延期，每次写peer_frame前再次查当前call、来源与principal/grants及严格递增sequence。回复只表示B Core接受，不表示屏幕显示。
- 复用有界dispatcher，媒体总请求/接收body限制4，超时约3秒，RPC约2.5秒；每publisher最多1在途+1最新待发，替换待发项应明确丢弃旧项。晚回复按rpc/source/授权代次拒绝。stop先唤醒dispatcher，再在loop取消RPC/清队列，最后停HTTP/mesh，不能持锁join loop。
- TcpTransport的outbox目前无字节上限，必须增加可验证上限及溢出断开；不能仅靠HTTP队列限定连续超时后的底层累积。需要实际慢接收/不回复测试与status/SOS响应并行验证。
- 敏感/peer-frame.jpg仅loopback原生接收端或同一发布session读取；不能任意合法panel读取他人通话回传。T31明确保留原LAN-public门口摄像头feed的产品边界，本卡不临时将所有公开camera endpoint变私有。

分工：root独占MediaAuthorization/mediaAuthorityCurrent、media routes/peer-frame/RPC/Httpd/TCP；agent3 T31拥有PanelSession/identity辅助、session/bootstrap、非媒体权限/operation panel分支、call-info SIP和door过滤。公共helper已落panel_identity.h/service.inc，使用前确认agent3最终冻结/编译状态。

待完成：实际跨节点生产红→绿、伪造目标/peer/权限/redirect、慢网队列与停止、切call晚帧、媒体大小/类型边界完整验收；独立复核、历史SDK/相关回归、三语文档和最终报告。不得将HTTP子项PASS写成整卡已完成。

04:02 JST：TCP outbox实际非读取peer与单个超8MiB帧RED1case32assert4fail已保存tcp-red-r1。新增8MiB+4字节及1024帧双上限、超限仅I/O线程abort/通知、关闭释放队列；普通有界帧仍实际收到。冻结green-r1与既有真实双TCP Mesh握手/配置同步回归合计2cases38assertions通过（tcp-green-r1.json）。这是实际macOS套接字验证，仍非完整跨节点媒体RPC；继续待独审及最终Core集成。
