# 修复复核与全平台对齐：执行报告

报告日期：2026-09-22
仓库/分支：`yukiinagato/ox-app-doorbell` / `codex/repair-r1-r6`
开始完整 SHA：`0955c3088c0fc3f95a39c3b05ddc9ed4585170ca`
结束完整 SHA：未提交工作区；`git diff --binary HEAD` SHA-256 为 `b3ac547d47c0b8ca64e1469420354dff204ecd29aa5172ba6ee484a3ef1013fb`
本轮审查参考 SHA：`0955c3088c0fc3f95a39c3b05ddc9ed4585170ca`
开始时已有脏文件及归属：无。
提交/push/合并/发布/部署动作：none。

## 1. 每组问题

### C01 + C03

实现状态：IMPLEMENTED。

`UiCallbackSlot` 现在由 Core 保存退休 slot；自注销后的后续外部注销会排空仍在执行的 slot。活动回调身份改用 pthread key 的线程私有栈，不使用 `thread_local`，从而保留 iOS 5 armv7 编译兼容性。生产路径在 `core/src/capi/doorbell_capi.cpp`；回归在 `core/tests/test_capi_abi.cpp` 的 `[R2]` 场景，覆盖回调内部注销、外部二次注销必须等待、普通注销排空。

实际命令与结果：`build/review3-host/doorbell_tests --test-case='[R2]*,[V01]*,[B3]*,[R3]*' --no-skip --duration=true`，退出码 0，日志见 `verification/logs/core-repair-targeted.log`。`DB_ALLOW_DIRTY=1 DB_BUILD_ID=review-20260922-c03 ios-compat/scripts/build_core_ios5.sh`，退出码 0，日志见 `verification/logs/ios5-armv7-core-build.log`。

限制：后者仅为 iOS 5 armv7、PJSIP-off 的 Core 静态库；不是 iOS 5 App/miniSIP 通话，也不是设备验证。

### C02

实现状态：IMPLEMENTED。

`CoreBridge` 为每个 Core 生命周期创建 `CoreEventDispatchGate` generation。C 回调复制 JSON 后排入主队列时携带该 generation；`stop()` 先失效 gate，因此 A 生命周期迟到的 UI 闭包无法分派到 B。注册对象保留到 C ABI 注销排空后才释放。生产实现为 `ios/Doorbell/CoreEventDispatchGate.swift` 与 `ios/Doorbell/CoreBridge.swift`；host 回归直接编译生产 gate，测试 stop/start 后旧 token 被拒绝。

实际命令与结果：`DB_SKIP_HELPER_HOST_TESTS=1 ios-compat/scripts/test_host.sh`，退出码 0，日志见 `verification/logs/ios-compat-host.log`。

限制：未编译现代 iOS App，也未在 iOS9 arm64 或用户 iPad mini 1 / iOS 9.3.6 / armv7 上运行。

### W01–W03

实现状态：IMPLEMENTED。

`webui/admin/app.js` 以显式 runtime context 约束请求完成、副作用、配对 polling 和后续 POST；boot 成功初始化前不标记 authenticated，失败会清理上下文，`pageshow` 重新探测并初始化。XHR 把 timeout intent 先固定，再 abort；`readyState=4,status=0`、abort、同步 open/send 失败均只完成一次且带正确 reason。

生产 `app.js` 由可控延迟 XHR/timer harness 直接加载。新增场景覆盖初始化失败后的 pageshow、旧 pairing completion 不得发新 POST、timeout 优先于 status=0/abort、同步 send 失败。实际命令为 `for test in webui/tests/*.test.js; do node "$test"; done`，退出码 0，日志见 `verification/logs/webui-node-tests.log`。

限制：这是 Node VM 中运行的生产脚本，不是已认证真实浏览器或设备浏览器。

### W04

实现状态：IMPLEMENTED。

扫码 detect 调用被 try/catch 覆盖；busy 在每条成功/失败路径释放；连续检测失败三次会关闭本 session 及其 timer/stream。每个 async 边界检查 pairing runtime identity，旧 A 的权限/检测结果不会影响 B。回归包含迟到 stream 停止和同步 detect throw 的有界关闭，结果同 `verification/logs/webui-node-tests.log`。

限制：未使用真实摄像头、权限 UI 或浏览器 BarcodeDetector。

### V01 + B3

实现状态：IMPLEMENTED。

`VideoTrack` 分离待编码器消费的请求和已交给编码器、等待真实 IDR 的请求；真实 IDR（不是调用者 key hint）满足 in-flight 状态。Reader 用自身已核算序列水位统计真正未交付的片段，重复空 pull 不重复计数。PPS-only 或 SPS 变化都会令旧 generation 结束并产生新 init；不完整参数集更新不会替换现有配置。

生产回归在 `core/tests/test_fmp4.cpp`，覆盖两 Reader 与一次 encoder take、IDR 后再次请求、seq1→缺2/3/4→IDR5 计三、PPS-only init replacement；R3 demux 回归仍通过。实际结果见 `verification/logs/core-repair-targeted.log`，退出码 0。

限制：fMP4/Annex-B 参考测试通过；没有真实编码器、目标播放器首帧或设备解码资格。

### B1 + B2

实现状态：IMPLEMENTED。

通话页将实际摄像头上传生命周期放到 `webui/panel/video-session.js`：请求开始即保留 session/door/target binding；权限、timer、toBlob、上传前均检查 binding；停止会清理全部 track，即使一个 track 的 stop 抛错。`pagehide` 也停止视频。`DoorbellCallFlow.projectDoor()` 保留且严格校验 boolean `recovery_required`，并保留 call_id/revision/owner/expiry。

回归 `webui/tests/video_session.test.js` 直接运行生产 helper，覆盖迟到 stream、A/B 反序完成、blob 迟到零上传和多 track stop；`webui/tests/call_flow.test.js` 覆盖 recovery projection。结果见 `verification/logs/webui-node-tests.log`。

限制：没有运行完整 HTML 于真实浏览器/WebRTC 后端；已发出的真实 POST 不可撤回，测试验证的是停止后不新增上传。

### B4

实现状态：IMPLEMENTED。

Core 动态 batch 符号缺失时，`ConfigBatchFallbackPolicy` 只允许一个操作走旧 set/delete；两项及以上在任何写入前返回 `batch_unavailable`。`ConfigWriter` 收到该 outcome 不会再 HTTP 回退。生产 policy 和 host 回归分别为 `ios/Doorbell/ConfigBatchFallbackPolicy.swift`、`ios-compat/tests/config_batch_fallback_policy_test.swift`，结果见 `verification/logs/ios-compat-host.log`。

限制：尚未在缺 batch 动态符号的真实 iOS App 与真实持久层注入第二项失败。

## 2. 验证矩阵

| 层级或平台 | 状态 | 命令/日志 | 范围与限制 |
| --- | --- | --- | --- |
| Core targeted regression | PASS | `core-repair-targeted.log` | R2/V01/B3/R3 host 测试 |
| Full aggregate ctest | FAIL | `ctest-review3-host.log` | 411 case 中 410 通过；`test_time.cpp:724` 的既有 NTP request 断言失败，未归因于本轮修改 |
| Web actual app runtime | PASS | `webui-node-tests.log` | Node VM 直接加载生产 JS |
| Web real browser | NOT RUN | none | 无浏览器/相机/WebRTC 后端验收 |
| Actual VideoTrack decode | PARTIAL | `core-repair-targeted.log` | demux 参考链通过，非目标播放器 |
| TSan / ASan/UBSan | NOT RUN | none | 未配置本轮 sanitizer |
| Android modern / legacy19 / TV | NOT RUN | none | 未运行 Gradle、SKU 或遥控资格 |
| iOS modern | BLOCKED | `ios-modern-simulator-build.log` | Xcode 编译尝试被真实 PJSIP simulator artifact 门禁阻断 |
| iOS9 arm64 | NOT RUN | none | 未编译或运行 App |
| iOS9 armv7 static gates | PASS | `ios9-armv7-static.log` | 不受信 CI/profile 检查通过；不是签名 App 或设备运行 |
| iOS9 armv7 / iPad mini1 9.3.6 | BLOCKED | `ios9-armv7-build.log` | 正式构建要求用户选择 stock/jailbreak 签名 lane；指定设备未连接，不能由 static gate 代替 |
| iOS5 armv7 Core | PASS | `ios5-armv7-core-build.log` | PJSIP-off Core 静态库；非 App/设备/miniSIP 通话 |
| iOS5 compat host | PASS | `ios-compat-host.log` | helper host tests 明确跳过 |
| tvOS / Windows x86 / Windows x64 | NOT RUN | none | 未运行各自产物 |
| i18n / English source | PASS | `i18n-check.log`, `english-source-check.log` | 生成资源与英文源检查 |

## 3. 功能盘点与补齐

新增并保留 `feature-parity.json` 的 44 功能、12 profile 起始矩阵和 `verification/r1-r6-traceability.json` 的原 55 场景。新增 `verification/production-entrypoints.json` 映射已复核的 ABI、HTTP、配置、Web panel、iOS bridge 与能力入口到 F03/F04/F10/F18/F20/F34/F40。

盘点状态仍为 `PARTIAL_M0_BASELINE`：完整 ABI/HTTP/配置 schema/UI/capability 枚举尚未完成，故未映射项没有被标为 unsupported。F12 没有新增 `db_core_sip_set_mic_muted`；实际发送音频静音验收仍为 NOT RUN。

## 4. 最终结论

本轮 M1 的 C01–C03、W01–W04、V01、B1–B4 已有生产实现和针对性回归。完整 host ctest 未通过，原因记录为 NTP 测试失败；不能写成全套通过。没有目标 App、真实浏览器、真实 SIP/媒体、Android、Windows、tvOS 或指定 iPad mini 1 的 PASS。本仓库距离全平台功能对齐仍需完成完整生产入口映射、各 profile 的实现/能力审计、目标构建、真实媒体/音频/静音与跨端设备资格。
