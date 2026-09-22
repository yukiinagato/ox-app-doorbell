# iPad / iPhone 门口机修复记录

日期：2026-09-22。基线：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。

本次按用户选择优先改善 iPad / iPhone 门口机，并修复附件中可复现的相关问题。两个 ZIP 是审查和计划参考，未将其中的代理指令、全部任务或发布步骤视为用户授权。本次修改保留在本地工作区；没有提交、推送或安装到真实设备。原有 T00 报告及日志保持原样。

## 界面变化

- 现代 iOS 门口机按可用宽度排列用途按钮：常见 iPhone 横竖屏为两列，iPad 为三列。
- 内容超出小屏高度时可滚动；版本信息及已启用的 SOS 操作保留在底部。
- 调整时钟、提示、按钮的字号与间距；主按钮限制在所在列内，语言按钮保留足够触摸高度。
- 呼叫等待页增加铃铛和等待说明，取消及挂断按钮约束在安全区域内，并尊重系统“减弱动态效果”。
- 修复相机权限提示在旋转重建布局后消失、以及没有公告时被父容器一起隐藏的问题。
- 新增提示及无障碍文案由 `i18n/strings.yaml` 生成，覆盖英、日、中三种语言。

布局图片来自模拟器内的生产 `VisitorScreenView` / `PurposeButton`，用途和时钟使用测试数据，不是联网真机截图：

- [iPhone 布局预览](../../build/repair-20260922/screenshots/visitor-390-844.png)
- [iPad 横屏布局预览](../../build/repair-20260922/screenshots/visitor-1024-768.png)

## 缺陷修复与证据边界

| 来源 | 本次处理 | 验证范围 |
|---|---|---|
| N01 视频参考帧链断裂 | 拒收带有视频帧的异常参数更新后，停止发送后续依赖帧；合并关键帧请求，收到匹配 IDR 后恢复；新订阅者也遵循屏障。仅有异常参数、没有视频帧的输入不会无故中断旧链。 | 生产 VideoTrack 单元测试；真实编码流经生产输出后由 FFmpeg 解码，正常 20 帧，恢复输出 16 帧，像素摘要逐帧匹配源帧 0、5–19。未代替各目标硬件解码验收。 |
| N03 旧门口状态结束新通话 | 状态请求绑定页面、选择、会话和呼叫身份；跨语言加载后仍复核；旧 call/revision 不得结束当前会话。退休 SIP 回调、页面退出后的轮询也受保护。 | Node VM 执行实际页面控制器，覆盖旧 owner、三种终态、旧修订、语言加载、有效新 owner 及 pagehide。真实 JsSIP / 浏览器返回缓存尚未验收。 |
| N04 配对页入口竞态 | 进入页面立即创建访问身份，状态与配对读取归属该次访问；每次访问只保留一条串行轮询链。 | 实际后台控制器测试，覆盖离开页面、重复进入及响应正反顺序。 |
| N05 登录表单与探测竞态 | 退休登录恢复按钮；新登录使旧探测失效；旧完成结果不影响新尝试。 | 后台测试覆盖返回后重试、旧 200/401 探测、新旧登录交错。 |
| Q09 Apple 呼叫超时 | Core 状态提供同一校准时钟采样的 `server_now_ms` / `remaining_ms`；现代 iOS 和 iOS 5 壳读取该时长，UI 计时器只复查状态，由 Core 决定结束。 | Core 正负五分钟偏移测试、Apple 时间解析及恢复契约测试。Windows 路径未在本轮修改。 |
| 新增按铃时序回归 | `pressV2` 返回前发布完成转换后的状态，避免紧接着读取状态时误判刚建立的呼叫不存在。 | 新增即时读取断言；修复前复现失败，修复后 visitor 测试通过。 |

## 验证结果

| 检查 | 结果 | 日志 / 证据 |
|---|---|---|
| Core 全套 `doorbell_tests` | 417 项、10708 个断言全部通过 | `core-tests-final.log` |
| iOS 模拟器 `Doorbell` 全套测试 | 130 项通过，0 失败 | `ios-release-check.log`、`ios-release-check.xcresult` |
| `webui/tests/*.test.js` | 13 个测试套件全部通过 | `web-tests-final.log` |
| `ios-compat/scripts/test_host.sh` | 通过 | `compat-tests.log` |
| 生产 VideoTrack → 软件解码与像素摘要比对 | 通过 | `media-decode/normal.framemd5`、`media-decode/reject.framemd5` |
| iOS 5 Core / app 交叉构建 | 通过；最低系统 5.1；未解析非系统符号为 0 | `ios5-core.log`、`ios5-app.log` |
| 生成翻译、英文源码规范、差异空白检查 | 15 个生成文件同步，规范和空白检查通过 | `tools/gen_i18n.py --check`、`tools/check_english_source.py`、`git diff --check` |
| Android modern / legacy19 构建、单元测试及 lint | 环境阻塞：缺少 Java runtime | `android-modern.log`、`android-legacy19.log` |

媒体验证可用以下命令复现：

```sh
cmake -S core -B build/repair-20260922 -DDB_WITH_PJSIP=OFF -DDB_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build/repair-20260922 -j4
python3 tools/tests/test_video_track_decode.py --probe build/repair-20260922/doorbell_video_decode_probe --out build/repair-20260922/media-decode
```

完整日志、编译结果、模拟器结果包及解码产物位于 `build/repair-20260922/`。Core 和现代 iOS 模拟器使用 SIP stub，仅作为逻辑和界面测试证据。iOS 5 构建使用兼容 miniSIP 实现，未连接真实 SIP 服务。

## 版本

| 应用 | 版本 | 构建号 |
|---|---|---|
| 现代 iOS | 0.1.35 | 36 |
| iOS 5 kiosk | 0.3.47 | 50 |
| iOS 9 armv7 profile | 0.4.1 | 401 |
| Android | 0.3.19 + Git 后缀 | 20 |
| Windows | 0.1.12 | FileVersion 0.1.12.9 |

共享 Core、Web 资源及生成的翻译会影响其他平台交付物，因此同步递增对应版本；这不表示这些平台均已构建或部署。`ios-legacy` 未修改，Apple SDK、静态库和签名输入未加入源码变更。

## 未关闭项

- N02 完整 PPS / slice 语法与恢复点验证仍未修复；本次 N01 不构成对任意异常 H.264 输入的完整验证保证。
- 执行计划中其余 Q 项及平台统一、认证、配置并发等架构工作没有在本轮全部实现，不能将此次结果视为整个 ZIP 计划完成。
- Android 两条构建与测试命令都因本机缺少 Java runtime 退出，未得到 Gradle 验证结果。
- 未完成 Windows 构建、独立 iOS 9 产物构建，以及真实 iPad / iPhone 的 SIP、双向媒体、设备安装与长时间运行验收。
