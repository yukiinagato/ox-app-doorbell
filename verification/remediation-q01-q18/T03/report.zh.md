# T03 执行报告

日期：2026-09-22
执行者：并行子任务 /root/t02_contract_inventory
任务状态：VERIFIED_IN_SCOPE（production_test）；主任务已完成本卡范围内的综合验证和独立复核。

## 来源与范围

- 执行前与验证 HEAD：`b26e0d346df99f2879915241b6e98d8ef1aa0707`。
- 工作区：dirty；本报告记录时完整 tracked diff SHA256：`1eecaae3d3d9368f64c0669e62677594ebbc52c78c7952d6418ca8b7f82961fe`。
- 修复前后的每条命令记录独立保存当时的 source/diff 与相关文件 SHA256；共享工作区另有主任务版本资源更新、T09/T20 及此前用户修改。
- 只修改本卡的开锁解析、后台表单、3条翻译、相关测试及三语配置说明；没有改 ABI、真正的 SIP DTMF 处理或 ios-legacy。
- `source-manifest.json` 核对 `onSipDtmf/execDtmfAction` 函数段与 HEAD 字节相同。
- 应用版本、翻译生成与综合目标构建由主任务统一负责。本子任务未改版本/生成文件。观察到 Android 0.3.20/build21，现代 iOS 0.1.36/build37，iOS5 kiosk 0.3.48/build51，iOS9 armv7 0.4.2/build402；不将版本读取当成设备验收。

## 真实生产入口

`Node::unlockCommandFor` 同时服务 `doorUnlockDoc` 与 `openDoorOnLoop`。`POST /api/doors/<id>/open` 调用该入口；原生 `db_core_open_door` 读取同一状态并调用 `Node::openDoor`。真正 DTMF 仍由 `onSipDtmf → execDtmfAction` 独立处理。

新增 HTTP 测试使用真实 Node、Core HTTP 路由、配置存储和事件日志。读取真实 `/api/events?type=dtmf_action` 验证命令/门和数量；原生测试直接调用 C ABI 并计数 Core 实际发出的分发事件。测试不连接 MQTT 或门锁。

## 改动

- 删除遍历通用 `sip.dtmf_actions` 选首个 HA 命令的回退；只认本门的 `doors.<id>.unlock.command`。
- 手工显示按钮仅影响可见性，不产生授权；未配置 HTTP 返回409/`unlock_not_configured`，原生ABI返回-3。
- 后台开锁表单提供显式命令输入和已配置 HA 命令的输入候选。候选不预选，不自动保存；未绑定时显示迁移提示。命令格式与Core已有校验一致：1–32个ASCII字母、数字、下划线、连字符；留空删除绑定。
- 2个旧Core用例由错误fallback前提改为显式绑定，保留原有成功/可见性/校验断言并增加未绑定拒绝断言。
- 三语schema提供管理员确认迁移步骤和保留开灯特服码的示例；配置升级不猜测锁的含义。

## 验证

| 运行 | 退出码 | 实际结果 |
|---|---:|---|
| [red-configure](evidence/red-configure.json) | 0 | 通过。 |
| [red-build](evidence/red-build.json) | 0 | 通过。 |
| [red-unlock](evidence/red-unlock.json) | 1 | 真实反例失败：1个用例/4个子场景，118断言中17条业务失败。 |
| [green-build](evidence/green-build.json) | 2 | 新增测试回调参数顺序错误导致编译失败；已修正。此失败仅归类为夹具错误。 |
| [green-build-r2](evidence/green-build-r2.json) | 0 | 通过。 |
| [green-test-list](evidence/green-test-list.json) | 0 | 列出4个实际定向用例。 |
| [green-unlock](evidence/green-unlock.json) | 0 | 4个生产用例通过，250/250断言；包含4项验收子场景及原生ABI。 |
| [web-unlock](evidence/web-unlock.json) | 0 | 生产Admin helper回归通过，包含候选不自动绑定、明确保存、解绑、非法命令拒绝。 |
| [web-admin-runtime](evidence/web-admin-runtime.json) | 0 | 现有生产后台登录/配对/生命周期套件通过。 |

所有命令 cwd 均为 `/Users/ox/Documents/project/app-doorbell`。JSON记录包含实际 argv、原始日志路径、开始结束时间、源文件哈希和测试二进制哈希。定向 Core 命令：

```sh
build/remediation-t03-20260922/doorbell_tests --test-case="T03:*,doors: the unlock*,admin API: the cluster-wide notice*" --success=true
```

修复前仅配置 `light_on` 时，Node与HTTP调用错误地都成功，产生2个开灯动作意图；删除A绑定和强制显示时也错误地产生动作。修复后这三类拒绝路径均为零意图，正确显式绑定的单次HTTP调用只产生A命令一次。

| 验收 | 状态 | 生产证据 |
|---|---|---|
| T03-01 | PASS（host生产路径） | [命令/结果/日志](evidence/T03-01.json)：Production Node and authenticated HTTP refuse the door with only a light_on SIP HA action; configured/show_button are false and zero durable dtmf_action intents are emitted. |
| T03-02 | PASS（host生产路径） | [命令/结果/日志](evidence/T03-02.json)：After deleting the front door command, opening front returns 409 unlock_not_configured and emits zero intents even though back_gate and light_on remain configured. |
| T03-03 | PASS（host生产路径） | [命令/结果/日志](evidence/T03-03.json)：One authenticated HTTP front-door request emits exactly one durable dtmf_action whose door is d_front and command is front_gate; neither back_gate nor light_on is emitted. |
| T03-04 | PASS（host生产路径） | [命令/结果/日志](evidence/T03-04.json)：show_button=true remains visible in authoritative status, while the backend still returns 409 unlock_not_configured with zero intents; native ABI additionally returns -3 and emits no event. |

## 限制与未完成

- 本卡结果只证明 Core/HTTP/C ABI 的开锁目标解析和本地持久分发意图；没有声明 MQTT送达、执行器ACK、物理锁打开或exactly-once。T05–T07负责操作台账/权威/物理结果语义。
- 新表单真实浏览器操作为 BLOCKED_ENV：IAB 未连接，Chrome 被已打开的扩展 UI 阻止自动化。当前表单行为证据是执行生产 app.js 的主机测试；不冒充浏览器实测。
- 主任务已生成三语资源并检查一致性；全 Core 419 用例/10852 断言、全部 14 套 Web 测试通过。Android modern/legacy19 构建与 lint 通过（各 43 套/377 条 JVM 结果复用 Gradle 有效缓存），iOS5 Core/App 历史 SDK 构建通过；产物和版本见 ../parallel-batch/evidence/artifacts.json。后续 T09 集成补修后重建了这些嵌入资源目标。
- /root/t02_translation 独立复核 PASS_IN_SCOPE，见 independent-review.md；主任务删除了其指出的陈旧配置注释。T20 的 Swift 测试和其他平台设备资格独立记录，不由本卡代替。
- 没有实际设备安装、运行或真实SIP/门锁测试；SIP后端为stub。
- 首轮green构建的夹具编译错误保留原始日志，不混入修复前业务反例或隐去。

## 下一步

本卡的四项生产路径验收均通过，按已满足依赖的任务卡继续推进；新浏览器表单的现场检查仍明确未完成。本报告不授权发布、推送或部署。
