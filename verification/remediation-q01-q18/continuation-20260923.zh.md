# 工作现场：2026-09-23 02:21 JST

用户要求完成两个 ZIP 的全部 50 卡、iPad/iPhone 门口机 UI、多门同时呼叫室内机 UX 和设备验证，已授权并行。条件暂停：仅在 Codex 额度重置时保存所有工作并暂停全部代理和动作，不兑换额度、不自动恢复。最新检查已用 84%，重置时间仍为 9 月 26 日 18:54 JST，没有观察到重置；详见 quota-pause-state.json。

当前修改与证据均在工作区，无提交、推送或本批部署。HEAD b26e0d346df99f2879915241b6e98d8ef1aa0707。唯一进度表 /Users/ox/Documents/project/ox-doorbell-execution-plan-2026-09-22/progress.json。工作区大量既有改动，禁止重置覆盖。

限定范围已验证 24/50：T00–T14、T19–T27。T15 IMPLEMENTED，最后 iOS 重复帧测试已编译，但 Mac 锁屏阻止真实 Simulator 运行，等待用户解锁；不要将旧 17 项通过或编译成功替代最后候选测试。T16/T31 按严格依赖尚未开始实现。release_gate NOT_READY。

当前分工：root 实施 T28 持久化跨节点配置冲突；t01_evidence_review 已完成 T35-ios-modern r3 编译，现复核 T28 Web、13 项真实 IAB 已通过，双 Node HTTP 夹具等待 r5；t02_translation 已完成 T35-ios-compat r4 host/历史 SDK 构建，现独立复核 T28 Core 并编写反例；t02_contract_inventory 完成 T35 Android r5 实际 API35 UI 后正在补无人接听固定提示 r6，随后修 iOS modern inCallTitle 与按钮可能重叠。T35-Web/Windows 仍未实施；T36 多呼叫协调器仍待依赖完成，只已有设计。

最新完成：T07 签名 actuator ACK，普通及 ASan 11 项与 86 项回归、独立复核通过，物理门状态仍 unconfirmed；T12 Web SOS operation 生产控制器与 Core panel 身份/CSRF/ownership，Core 36/2917 和 Web 21 suites、独立复核通过；T27 实际 IAB 12/12、草稿 9/9、Web 21 suites、Core companion 13/509 通过，R1 typed ancestor 复核修复后关闭。每项目录保留真实失败、冻结源码和资格边界。

T27 Core companion 添加公告条件提交/Core 时间生成、remove_fields 语义重置以及 materialized notice 校验修复。T25 一条历史 JSON 被测试夹具误覆盖，已保留覆盖记录并用原冻结生产源码真实重跑 9/9；T25 报告与 acceptance 明确新时间替代证据，未伪造原始日志。

T15 解锁后命令见 T15/evidence/ios-resume-command.json，xctestrun 在 build/remediation-t15-20260923/xcode/Build/Products。脚本 fat archive 架构排序修复已实际 arm64+x86_64 构建通过，不替代 UIKit 测试。根任务当前无运行中构建；各代理有独立进程，暂停时通知各自保存与清理。

版本本批已提升：Android 0.3.21/22；现代 iOS 0.1.37/38；tvOS 0.1.14/15；iOS5 kiosk 0.3.49/52；iOS9 armv7 0.4.3/403；Windows 0.1.14 / 0.1.14.11。不要逐卡提升。字符串统一 i18n/strings.yaml 生成；ios-legacy 归档不得改。

设备与工具链资料：/Users/ox/.codex/memories/doorbell-device-access.md、/Users/ox/.claude/projects/-Users-ox-Documents-project-app-doorbell/memory/MEMORY.md。Java21、Android SDK/分 NDK、历史 iOS5 SDK 已实际使用。Air1/iPad1 SSH 可达，mini3 SSH 拒绝且禁止重启 iOS，iPhone17 已配对；Android/Windows/tvOS/iOS9 armv7 完整硬件资格仍缺。不得实际触发开门/SOS。

继续工作必须逐卡遵守依赖、真实目标层验证、独立复核和报告，不能以软件子项或环境缺失声称全项完成。剩余 T15–T18、T28–T49 仍需完成。

T28 冻结 r4 相关 Core 18 项/660 断言通过，独立复核发现 R1 严格记录格式与脱敏、R2 原生 setter/公告/旧 HTTP import 绕过、R3 devices 根删除、R4 子字段 delete 不得解决全实体冲突；生产修复已写但尚未冻结验证 r5。独立新增 test_config_conflicts_review.cpp 正在跑 r4 RED。不得使用 r4 PASS 替代当前候选。文档已写 en/ja/zh config-conflicts，链接与资格报告仍待补。T35 modern/compat 均仅 IMPLEMENTED，UIKit runtime 尚未通过；Android 当前各构建/386 单测/lint 已通过，真实 API35 portrait/landscape 各 5 项通过，r6 新提示仍待验证。

最新续接：T28 r5 26/836定向+21Web全过，独立Core8/168通过。真实两Node HTTP/IAB E2E通过。全Core r5 506中504过、2失败（delete原成功响应兼容、call-log旧schema=7断言）。已恢复delete原响应，断言改当前schema8；其余迁移数据断言未改。Web R7定时重绘丢Review焦点经真实15th red-green修复，root纠正独审通过。r6冻结diff b8ef3946cdf448923aa75d5e77af82b2b8943fb2e5b6be352fdfa30411336227，构建及21Web通过，全Core session78680正在运行；agent1正做r6最终HTTP/IAB后转T35-Web。T28已IMPLEMENTED，未关闭。
Android r7修复旧SOS确认消息在cancel/detach/替换后执行，真实32UIcases与双lane386tests/lint/build通过，root-review-r7.json已签只限实际范围。agent3转现代iOS title可滚动R1并尝试标准XCTest新Simulator，不绕过Mac锁屏；若可运行通知root恢复T15。Compat r5手势绑定40checks通过但root发现nil-ID SIP正常结束被拒绝，agent2正修r6+UI动作代次，并准备独立bundle ID的iPad1真实UIKit测试runner；不备份或改正式数据、不触发真实门锁/SOS。Root仅只读Windows访客源，未开始修改。最新额度86%、未重置，17:28:49 UTC检查。

续接更新：T28 r6现已关闭VERIFIED_IN_SCOPE，累计25/50。Core506/506、31490/31490断言，Web21/21，真实双Node HTTP/IAB及历史iOS5 Core构建全部通过，独立复核及报告齐全。T29 IN_PROGRESS，尚未实现，root负责暂存/预检/原子导入。agent1负责T35-Web及node.cpp webUiManifest中offline默认颜色单值改动；agent2负责iPad1独立真实UIKit runner，初轮生产动作与布局通过、正在修runner查找错误并跑完整用例；agent3完成modern r4源码/3编译lane（UIKit启动超时），已转T35-Windows。Android r7真实API35 32项与双lane构建/386单测/lint通过。modern r4 root源码复核通过，runtime未完成。最新额度89%，没有重置。所有正式设备禁止备份，iPad1只安装独立测试bundle，无正式app数据改动；正式进程可能因系统/keepalive更换，不声称PID不变。

03:05 JST续接：额度92%，未重置，Mac仍IOConsoleLocked Yes。T29生产已实现config_import.h/.cpp和Node内service.inc、HTTP四阶段及additive CABI。green-r1真实255/256/257往返1case84assertions通过；green-r2完整5cases384assertions中4过，失败是重复键测试误用会替换同名键的json::addObj（夹具问题），已改真实cJSON_AddObjectToObject并添加4096/4097边界待r3。生产r2编译通过，未改Store/schema。agent3已结束Windows候选r2（host guard15、静态70、API引用编译通过，但无真实WPF），开始T29真实posix_spawn+SIGKILL事务屏障崩溃恢复。agent1 Web r3 24/24后root发现按住Cancel接通变Hangup，R1正在补实际DOM反例与手势语义绑定；结束后T29独审。agent2 compat r8真实iPad1 UIKit95/95通过，新增浅色背景白字/AX按钮明确属性修复；host/SDK通过，恢复正式前台与结束lease，正在整理报告，之后独审Windows。root已补T29 EN/JA/ZH文档，完整任务依旧25/50已验收，不声称全部完成。

03:22 JST续接：额度95%、重置时间未变，未观察到重置。T29 green-r3完整Core 513/513、31949断言通过；真实SIGKILL四阶段崩溃恢复1case159断言通过（green-r2生产）。独立复核2case45断言4个失败证明device.local祖先UI恢复/doors根公告事件缺陷；SIP根未reapply是源发现。root已写修复以及receipt严格恢复校验、预检容量报告、cancel不依赖坏receipt、新只读query恢复接口，尚未最终冻结测试，不能关闭T29。回执原生产RED为1case113断言10失败已保存。T35-Web冻结r6实际35/35及4host suites通过，待root最终独审。Compat r8实际iPad1隔离UIKit95/95与root独审完成，Android r7实际32 UI通过；Windows r3 host19/静态70/引用编译及独审通过但WPF实际UI未运行；modern r4实际UIKit未运行。agent2正在尝试内网Air1独立Swift UIKit runner用于T15最后帧测试，无正式数据备份或覆盖。T29独审agent3等待最终冻结，agent1T30只读准备已保存，严格等待T29关闭。全部任务25/50已验收，release NOT_READY，无推送提交。

03:41 JST续接：额度97%、reset仍1790416443，未观察重置。T15已VERIFIED_IN_SCOPE：内网Air1独立jp.ox.doorbell.t15uitest1.0.0/build2真实UIKit23/23，生产MainVC/CoreBridge与r4逐字一致，root独审及32证据hash已核验；正式前台恢复、测试PID停止。T29已VERIFIED_IN_SCOPE：r4定向9/647，独审2/45，crash1/159，Core全518/32294（1个专用child worker入口由spawn执行），历史iOS5armv7构建通过；source-green-r4 manifest SHA4a4db9bdd50789476fadb64fc25b07438cd0f707bfa8f45d67efc43a55c1e9e0。累计27/50验收。T35-Web r7实际40/40，root-review-r7签APPROVED；新增disabled释放无click五红例已修，原r6证据保留。
当前并行：root T16，agent1 T30实现后台导入，agent3 T31独立panel身份后端，agent2 T35-modern真实Air1 UIKit独立runner。T16新test_media_http_bounds.cpp真实旧HTTP RED1case15assert6fail，bodyreader可将超大/截断内容当成功dispatch。已改Httpd头部先auth、严格body长度/1MiB媒体上限、4个媒体admission、5秒请求超时，隔离green-r1带原HTTP回归session67689正在跑；T16尚未验收。另OperationDispatcher已添加Limits重用有界异步请求，默认原32/8192/4s不变，此修改尚未编译验证。后续媒体委托RPC/queue/TCPoutbox上限尚未实现。
T31新panel_identity.h/service.inc公共接口已落但整体未编译：PanelPrincipal{panel_id,credential_generation,grant_version,legacy_shared}，panelSessionPrincipal/sessionAllowed/principalAllowed；前两者本地显式legacy兼容，远端principalAllowed拒legacy/missingID。root独占MediaAuthorization/mediaAuthorityCurrent/media routes/peer-frame/RPC/Httpd；agent3拥有PanelSession、identity管理、非媒体route权限、operation_service面板分支、call-info SIP/doorfilter和schema。T16 A使用sessionAllowed，B使用principalAllowed及SecureChannel peer匹配dialog_owner前缀，不能带Cookie/长期bearer。原LAN-public门口camera feed明确保留边界；敏感peer-frame需root收紧仅loopback或同发布session。T30已明确只有本地提交证据，其他节点同步未验证，peer在线只展示连接状态，不能冒称配置已同步。所有代码/证据均在工作区无commit/push、无正式数据备份。

03:55 JST续接：额度99%、reset仍1790416443，未观察重置，条件暂停不等于立即暂停。T16 HTTP body隔离GREEN16/16 cases、289/289 assertions；dispatcher可选Limits默认回归4/4 cases、47/47 assertions通过。仍未实现跨节点媒体RPC与有界TCP队列，不得声称T16完成。T31 agent3已冻结pre-media-grant RED源（source-red.json SHA7fa718c6523b437133c64c48adff2df83473563dcdfc985215b70f9b48a1d284），root现已加media-authorize及mediaAuthorityCurrent两处media.publish权限gate，待实际红绿编译。T30 root准备真实Core本地fixture tools/verification/config_import_fixture.cpp及build_import_fixture.py，使用T29已验证r4库和最终冻结Web资产；尚未编译/运行。agent1准备完成Web源码后在18770受控IAB，root18771真实Core。现代UIKit r4 Air1 runner build3 263/263通过，但root发现Cancel/End同UIButton跨A结束/B建立迟到touchUp可能操作B；agent2正在补真实RED后改生产为r5，并要求T15 peer帧增量回归，不能用263pass关闭最终候选。

04:02 JST续接：额度显示100%已用但ordinaryUsageAllowed仍true，周窗口reset仍1790416443；未观察重置，不能以耗尽伪称触发条件暂停。root T16 TCP新增有界outbox完成真实RED→GREEN：不读取peer及单个超8MiB帧旧实现1case32assert4fail，新实现加既有真实Mesh握手配置同步2cases38assert全过；日志与冻结源在build/remediation-t16-20260923/tcp-{red,green}-r1和T16/evidence。TCP生产已修改但T16整体仍未完成。root当前无运行构建；33113已退出0。agent2 modern实机held RED281checks3fail，证实Cancel/End及nil-ID SIP三类旧动作误作用新通话，正做生产r5。agent3 T31媒体权限实际RED1case32assert2fail已存，新生产等待整体回归；agent1 T30浏览器目前12/14，两个测试等待/文字夹具问题在修，最终Web未冻结。
