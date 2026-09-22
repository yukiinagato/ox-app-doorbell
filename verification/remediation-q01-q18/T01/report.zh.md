# T01 执行报告

日期：2026-09-22（Asia/Tokyo）  
执行者：Codex；独立证据复核：并行 agent `t01_evidence_review`  
任务状态：VERIFIED_IN_SCOPE；验证范围：host_harness

## 来源与范围

审查参照、执行前后 HEAD、验证来源均为完整提交
`b26e0d346df99f2879915241b6e98d8ef1aa0707`。
开始时工作区已经 dirty，包含上一轮修复和用户已有报告。
原有 tracked diff 的 SHA256 为
`4b3c164a85fd749fe6640e44c4b8b0b0b8fe3124fe4213fb9866e0763e7c91f0`，本轮保持不变。
Git diff 不包含未跟踪文件，因此另存 source-manifests 中的逐文件哈希。
开始时 1216 个非忽略文件全部保持原字节；未修改 ios-legacy、ABI 或生产代码。

未修改基线从当前 HEAD 导出至独立目录，不回退用户工作区。
当前候选使用进入 T01 时已有的修复；它与原始 HEAD 的测试数量差异不是本轮新增业务修复。
本轮只增加测试工具和证据，不新增应用版本。
实际补跑产物：Android `0.3.19+b26e0d3` / build 20（legacy19 带对应后缀）；
iOS 5 兼容应用 `0.3.47` / build 50。未安装到设备。

## 真实生产入口与改动

- `tools/verification/record_command.py`：记录命令、来源、退出码和原始日志；超时清理整个进程组，包括父进程先退出的后代。
- `tools/verification/check_mutation_sensitivity.py`：在临时副本中对真实 video-session.js 注入故障，运行已有行为测试；最后恢复并移除副本。
- `tools/verification/browser_fixture.cpp`：链接真实 Node、Runloop、SQLite 和 HTTP 嵌入页面，注入 InMemNet；没有复制业务逻辑。
- `tools/verification/README.md`、本目录 command-map.json / fault-map.json / environment.json：记录可重跑入口、确定性控制及真实环境配置。

已有夹具使用 SimClock、固定丢包种子、网络分区和条件变量屏障。
存储反例通过真实 SQLite 写失败验证事务回滚；Web runner 加载真实模块和页面脚本。
具体函数、文件和限制见 fault-map.json。没有修改系统时间，也没有连接真实门锁。

## 验证结果

每条完整 command / cwd / exit_code / 来源 / 原始日志位于 command-map.json 及 evidence 中同名记录。

| 检查 | 退出码 | 实际结果 | 证据 |
|---|---:|---|---|
| 未修改 HEAD Core | 0 | 415 用例、10666 断言通过 | evidence/baseline-core.log |
| 当前候选 Core | 0 | 417 用例、10708 断言通过；CTest 是 1 个包装测试 | evidence/candidate-ctest.log |
| 按实际名称定向执行 | 0 | 7 用例、64 断言通过，属于上列用例的重复验证 | evidence/candidate-targeted.log |
| 原始 / 候选 Web | 0 / 0 | 分别 12 / 13 个 runner 文件通过 | evidence/baseline-web.log、candidate-web.log |
| compatibility host | 0 | 现有 host 合同检查通过 | evidence/candidate-compat.log |
| 生产故障注入 | 0（编排） | 原始通过 → 故障副本退出 1 → 恢复通过 | evidence/mutation-sensitivity.log |
| Chrome 真实 HTTP 页面 | 服务退出 0 | 错误密码反馈、正确登录、页面往返及刷新会话验证通过 | evidence/browser-smoke.json |
| Android modern | 0 | APK、377 个 JVM 测试、lint 通过 | evidence/android-modern-configured.log、android-results.json |
| Android legacy19 | 0 | APK、377 个 JVM 测试、lint 通过 | evidence/android-legacy19-configured.log、android-results.json |
| iOS 5 Core / App | 0 / 0 | armv7 核心库、链接、兼容检查和 ldid 签名通过 | evidence/ios5-core.log、ios5-app.log、对应 manifest |
| i18n / English / diff | 0 | 生成资源、英文源和空白检查通过 | evidence/i18n.log、english-source.log、diff-check.log |
| 超时及资源释放 | 预期 124 / 检查通过 | 后代进程结束、临时端口可重用、数据库独占重开且完整 | evidence/runner-timeout.json、runner-cleanup.json、cleanup.json |

故障副本删除生产分支中的 `stopTracks(stream)` 后，已有测试因
“a stream resolving after stop is immediately released” 的行为断言失败，
不是编译错误或源码字符串检查。恢复同一生产文件后测试重新通过。

浏览器使用 Chrome 153.0.8010.53 和候选 Core 的实际嵌入资源。
admin/app.js、runtime.js、video-session.js 与源文件字节一致；locale 与 YAML 生成器的压缩结果一致。
最初探测 `/panel/call.html` 返回 404：生成器真实入口是 `/panel/call`，该探测路径错误不作为产品缺陷。
真实通话页控制器另由 Node runner 执行。本轮浏览器未验证视频解码、bfcache 或真实多节点通话。

## 环境纠正与未运行项

首次 Android 命令因未设置 JAVA_HOME 失败。用户提醒后读取项目记忆，确认
Homebrew JDK 21 与 Android SDK/NDK 均存在，用已记录环境补跑两档均通过。
本机 iPhoneOS 7.1 SDK 与兼容 libc++ 也存在，iOS 5 Core 和 App 均构建通过。
不能把首次命令失败概括成“Java 或旧版 iOS SDK 不存在”。environment.json 保存实际路径与来源。

首次浏览器夹具编译缺少 cJSON 头文件目录；修正编译命令后通过。失败日志保留，归类为夹具配置错误。
iOS 9 armv7 正式流程停在 SDK 许可确认配置门槛；尚未找到已配置的 Xcode 7 / iOS 9.x lane，记 BLOCKED_ENV。
这与已经通过的 iOS 5 lane 不同，也不等于已证明其他位置没有 SDK。
Windows 本机目标执行仍为 BLOCKED_ENV；现代 iOS、tvOS、iOS9 arm64 本轮仅发现入口，构建标 NOT_RUN。
此前轮次的模拟器结果不冒充本轮重新运行。

所有设备运行、真实 SIP/音视频、跨节点安全和物理执行器资格仍未由本卡证明。
Core host 使用 SIP stub；iOS 5 应用使用兼容 MiniSIP；Android 为 Debug APK。
Android 原生缓存经核实分离：modern API21 / NDK27 与 legacy19 API19 / NDK25 不共用目录。
新夹具的进程、端口、数据库及 mutation 临时目录已清理；既有测试留下的诊断文件按证据保留。

## 逐项验收与复核

T01-01、T01-02、T01-03、T01-04 的判定及证据索引见 evidence/acceptance.json。
T01-04 的 PASS 表示正确识别并记录环境状态，不代表被阻塞平台通过。
独立复核通过，见 evidence/review.json；发现的目标架构元数据误标已修正。

本卡仅建立后续任务可用的测试基础。现有 C 回调屏障不证明 Q10 的 Swift acquire/stop 安全；
现有 Web 超时测试不证明 Q05 的 HTTP 队列写入取消。这些仍需对应任务实现和验证。

## 下一步

T02：冻结公共契约与兼容映射。完成独立设计复核后才能进入依赖它的修复任务。
release_gate 保持 NOT_READY；未 push、tag、release 或部署。
