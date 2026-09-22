# T20 执行报告

日期：2026-09-22（Asia/Tokyo）
执行者：t01_evidence_review；独立审查者：t02_contract_inventory；补充调用者审查：t02_translation。
任务状态：VERIFIED_IN_SCOPE（native_lifecycle / iOS Simulator；计划 progress 由主 agent 统一更新）。

## 来源与范围

审查参照、执行前 HEAD、验证来源 SHA：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。
工作区为 dirty；最终文件清单、各文件 SHA256 与未提交 diff 摘要见 `source-manifest-final.json`。该 diff 包含保留的先前工作区改动，不能视为仅 T20 的独立提交。
最终受影响范围 diff SHA256：`0202f65a8b2f6c4943aaae606dd7089ade16f08564ae9a6d86a5925037ee673f`。

现代 iOS 构建产物为 **0.1.36 / 37**，最低 iOS 12.0；tvOS 为 **0.1.13 / 14**，最低 tvOS 15.0。版本由主 agent 同批统一更新，本子任务未改版本文件。共享 Swift 的 iOS 9 arm64 通道由主 agent 单独增量构建，不用本报告的 iOS 26.5 Simulator 结果代替旧系统设备资格。

已有 AppDelegate 的 XCTest 启动保护、MainViewController 的 UI/内存压力改进和其他并行工作均保留；未修改 ios-legacy、C 公共 ABI、i18n 或其他任务进度。

## 真实生产入口与线程方向

`entrypoints.json` 列出 **53 个使用真实 Core 句柄的 Swift 方法**，覆盖呼叫/SOS/SIP、配置和鉴权、配对/取消配对、时钟、日志、音量、原始摄像头帧与编码帧。raw handle 只存于 CoreBridge，除创建/销毁外仅在不逃逸的 lease 闭包内使用；动态解析的 C 函数同样经过租约。C 返回 JSON/字符串在租约结束前复制和释放。

- 主线程/UI、时钟 utility 队列、camera 队列、VT 回调 → CoreBridge acquire（状态锁内判 running，必要时同锁比对 expected generation，inFlight 加一）→ 解锁 → 完整真实 C 调用与结果复制 → defer release。
- Core worker → 借用 callback registration → 同步复制事件 → main async；main 投递前检查注册代次。注册对象保留至 C stop/destroy 完毕，Core 不拥有 Swift 对象。
- stop 调用方 → 状态锁内改 stopping、拒绝新调用并使旧 UI 代次失效 → teardown 串行队列等待 startup/inFlight 归零 → 注销并排空 C 回调、stop、destroy 一次 → main completion。
- AppDelegate 身份重启/配对重置和 TVAppDelegate 重置只在 stop completion 内擦除持久化或启动下一代。AppDelegate transition token 使重置优先于旧的已排队/已等待重启。

## 改动与恢复语义

1. CoreBridge 生命周期改为 stopped/starting/running/stopping；C 调用期间不持状态锁，stop 不在主线程等待读者。重复 stop 合并等待，同一 handle 只销毁一次；启动期间 stop 与真实启动失败都能清理后重试。
2. Core UI/TTS、异步时钟及 peer-frame 响应过滤旧 Core generation。摄像头按实际 AVCaptureOutput 绑定捕获时的 Core generation，VT 输出闭包传原帧 generation；Core acquire 同锁拒绝旧帧，当前代次帧继续受理。
3. CameraFeeder 停止接收后异步停止设备队列，encoder 引用有锁保护；不再从主线程 queue.sync 摄像头队列。摄像头 stop 与 begin 分别更新本地 session generation，旧 observer 和排队状态不能污染新会话。
4. VideoEncoderVT 的旧失败回调在同一 session 锁内校验代次再写 failed；状态到 main 时再次校验 session/Core generation。同一 Core 内重新创建 encoder/camera 也得到保护。
5. 在现有 DoorbellTests 目标新增 13 个生产路径测试，DEBUG 屏障只控制执行窗口，不复制 CoreBridge 状态机。AppDelegate 测试只在真实 stop 完成后的持久化/启动副作用处截获，避免擦除测试宿主配置；摄像头状态测试使用真实 AVCaptureSession 通知，未启动物理摄像头。
6. 更新原有 recovery_safe_mode_contract_test 的关闭链路检查，使其检查异步停止与实际 lease 测试，不再要求会阻塞 main 的旧 camera.stopAndWait。

## 验证

所有命令 cwd 均为 `/Users/ox/Documents/project/app-doorbell`。准确 argv、退出码、时间、来源 manifest、日志路径见 `evidence/*.json`；Xcode `.xcresult` 保留于忽略目录 `build/remediation-t20-20260922/`。

| test_id | 证据层/实际路径 | 当前结果 | 证据 |
|---|---|---|---|
| T20-01 | 生产 afterAcquire 屏障卡在真实 C 读取前，stop 的 destroy 等待 release | PASS | CoreBridgeLifecycleTests.testLeaseHeldBetweenAcquireAndCReadDelaysDestroy；xcode-full-final.log |
| T20-02 | stopping 后状态/时钟/配置/音量/视频读取与两个帧入口拒绝；旧帧跨重启拒绝，新代次正例受理两次 | PASS | testStoppingRejectsNewReadsAndCameraCalls、testOldCameraAndEncodedFramesCannotAcquireRestartedCore |
| T20-03 | 真实 C UI 回调等待 main 工作，main 同时 stop，回调和 teardown 均结束 | PASS | testCoreCallbackCanReachMainWhileMainRequestsStop |
| T20-04 | 真实旧 UI 投递、clock 结果、摄像头/编码器帧及状态通知不进入新代次 | PASS | old UI/clock/frame/encoder/capture 五个用例；xcode-full-final.log |
| T20-05 | 两个 stop、启动中 stop、启动失败后重试；reset 先于 queued identity 及 identity 已在 stop 两种交错 | PASS | concurrent/start/failure/reset 五个用例；xcode-full-final.log |
| 全现代 iOS 测试 | iPhone 17 / iOS 26.5 Simulator / arm64 / Debug / SIP stub | 143 tests，0 failures，exit 0 | xcode-full-final.json、xcode-full-final.log |
| tvOS 目标构建 | tvOS Simulator SDK 26.5 / Debug / real PJSIP | BUILD SUCCEEDED，exit 0 | xcode-tvos-final.json、xcode-tvos-final.log |
| ThreadSanitizer 最终 | 独立 xcode-tsan DerivedData；生产 Bridge 专项 | 13 tests，0 failures，exit 0；未观察到检查器诊断 | xcode-tsan-final.json/log、xcode-tsan-final-artifacts.json |
| AddressSanitizer 最终 | 独立 xcode-asan DerivedData；生产 Bridge 专项 | 13 tests，0 failures，exit 0；未观察到检查器诊断 | xcode-asan-final.json/log、xcode-asan-final-artifacts.json |
| 关联恢复源契约 | host source contract，不冒充设备行为 | 27 tests，0 failures | recovery-contract-r3.log |

修复前没有运行一个已观察到 UAF 的崩溃用例，因此**不声称复现过 UAF**。原始裸指针风险由当前生产调用者与 stop 时序审查识别，修复后的顺序由真实 Core 调用屏障验证。r2/r3 的失败来自测试触发/测量窗口，不能冒充修复前 UAF 证据；r6 的摄像头状态测试实际抓到了 stop/begin 共用代次使旧 stopped 投递通过，修复为分别换代后 r7 为 13/13，全套最终为 143/143。

### 检查器、来源与产物身份的边界

Xcode sanitizer 选项插桩 Swift/Objective-C 测试宿主，**自定义 CMake Core 静态库没有传播这些选项**：CMakeCache 的 CMAKE_C_FLAGS/CMAKE_CXX_FLAGS 为空。这里不能声称整个 C++ Core 已通过 ASan/TSan；真实 C Core 仍被调用，但内存访问没有全库插桩。

`source-manifest.json` 保留首轮 11 项测试时的来源；`source-manifest-final.json` 标识最后 13 项测试来源。后者的 `native_archives` 是命令前观察值，**不是各运行实际链接的归档身份**。`evidence/*-artifacts.json` 在每次最终命令完成后、下一次相同 native key 构建前记录 App Mach-O SHA/UUID、版本、native artifact-manifest 与归档 SHA；相应归档固定副本保留在 `build/remediation-t20-20260922/artifact-snapshots/`。不会用当前归档 hash 反填历史测试。构建脚本每次重新合并归档；不同 hash 的具体来源不从文件名推断。

首次未设置 DB_ALLOW_SIP_STUB 的 Simulator 构建因该 target/min-OS 的真实 PJSIP 产物缺失退出 65（xcode-normal-r1.log）。后续明确采用仓库允许的 Debug SIP stub，实际 Core/Runloop/Store/C ABI 没有换成模拟模型。此限制不等于缺 Java/历史 iOS SDK，也不覆盖真实 SIP、硬件摄像头/VT、设备签名安装或旧 iOS/tvOS 实机资格。

## 独立复核

记录：`independent-review.md` 与 `independent-review.json`，最终判定 **PASS_IN_SCOPE**。初审要求补齐旧帧原子准入、reset/identity continuation 竞争；补充调用者审查要求 producer 状态通知也按本机会话换代。相关修复和新增反例均已完成，独立复审代码为 PASS，并核对实际测试日志及产物身份。5 条任务卡验收与 13 个专项测试的映射见 `acceptance.json`；重复运行不扩大唯一用例数量。主 agent 已另行通过最终兼容 host、iOS 9 arm64/min9/real PJSIP unsigned Release 增量、i18n、English 与 whitespace 检查，详见主线证据，不混入本卡 Simulator 检查器范围。

## 清理与下一步

测试只创建自有临时目录和 Core 实例，tearDown 在 stop completion 后删除数据。专用 Simulator `5675591C-491D-4232-9887-B2ECBB030C10` 已由 Xcode 停机；额外 shutdown 返回 149（已 Shutdown），simctl 回读确认。自有测试临时目录剩余 0 个，未触碰其他模拟器或设备；见 `evidence/cleanup.json`。xcresult、最终 App 与归档副本保留供复核；未运行 push/tag/release/真实设备部署。下一张候选为已满足 T01/T02 前置的 T21；不能据本卡关闭真实设备资格。
