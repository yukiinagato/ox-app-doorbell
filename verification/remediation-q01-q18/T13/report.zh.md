# T13 执行报告

日期：2026-09-22。执行：`/root/t02_translation`。
状态：IMPLEMENTED_TESTED_PENDING_REVIEW；四项 production_test 验收通过，等待主任务复核。本任务未修改 progress。

## 来源与修改

在 T10/T11 已验证的工作树上修改；修复前 `call.html` SHA-256 为 `0424a27b3c52335fcbe7b1c293f28c5ea9b2d65be11fbb1805c0bef30a1605c6`，修复后为 `01f1bfb5d9d547e74b87c25f9de2228035cf06911a0adf4da0cde60d49e9ae40`。完整文件清单及哈希见 `evidence/before-source.json`、`after-source.json`；本卡生产差异为 `production-diff.patch`。

门标签按稳定 door ID 保存按钮、名称与状态节点。轮询只更新真正变化的文字、选择状态和可用性；重排移动原按钮。按钮的处理器创建一次，读取最新 door 对象，避免旧闭包选中过期配置。移除门时删除映射与节点。

焦点规则为：原按钮仍可用时保持；原按钮移除或不可用时，优先此前顺序中的后邻门，再前邻门，再其他可用门；空列表落到可聚焦的页面标题。移动节点后必要时恢复同一按钮焦点，保留横纵滚动位置。增加键盘焦点轮廓及 `aria-pressed`，门选择组由页面标题命名。通话期间其他门禁用，原有 selectDoor 通话保护保留。不新增周期性 aria-live 播报。

仅修改生产 `webui/panel/call.html` 和相关 Web 测试；未修改 Node、runtime、i18n、版本、生成物或 progress。未增加翻译键，版本由主任务本轮统一递增。

## 验证结果

实际原生浏览器为 Codex IAB / Chromium 153（macOS）。旧 browser-use bootstrap 未发现 IAB 后端后，通过 `cua_repl` 可用 IAB 完成测试，没有用静态扫描代替焦点验收。

夹具命令：`node webui/tests/call_tabs_browser_fixture.js`，监听 `127.0.0.1:18763`。浏览器访问 `/?phase=red&lang=en` 与 `/?phase=green&lang=en`，点击页面上 Run four door focus tests。夹具加载完整生产 call 页面，只抑制自动启动，并替换媒体/网络边界；测试调用真实 renderTabs/selectDoor，焦点、节点身份、DOM MutationObserver 与点击派发来自浏览器。测试结果回传本地服务并保存来源哈希、用例哈希、浏览器标识和时间。

首次四个 red 在生产编辑前记录于 `browser-red-initial.json`。补充无重复 DOM 写入与非零滚动断言后，使用保存的原生产文件再次跑 red，再以相同用例哈希跑最终 green；见 `browser-red.json`、`browser-green.json`。

| 验收 | 修复前实际失败 | 修复后实际结果 |
| --- | --- | --- |
| T13-01 | 连续刷新丢失键盘焦点 | 10 次相同数据刷新，节点与 activeElement 不变；无 DOM 重写，非零滚动位置保持 |
| T13-02 | 排序重建节点 | C/A/B 重排复用全部原节点，B 保持焦点 |
| T13-03 | 删除 B 后焦点丢失 | B 删除到 C，C 删除到 A，清空到标题 |
| T13-04 | 反复增删替换保留按钮 | 20 轮增删保留 B；一次点击只增加一次 selectionRevision，使用最新对象，节点无泄漏且 aria-pressed 正确 |

`node webui/tests/call_tabs.test.js` 以完整生产页面进行可重复主机回归；原生浏览器结果另外记录，不把模拟 DOM 声称为浏览器验收。全部 **17 个** `webui/tests/*.test.js` 实际执行退出 0，含既有轮询、租约、旧请求、媒体、管理页测试。逐命令时间、退出码与原始日志见 `web-suite.json` 和相应 `.log`。限定差异空白、夹具语法和 i18n 一致性检查通过，详见 `checks.json`。聚合结果见 `acceptance.json`。

## 限制

本卡验证桌面真实浏览器 DOM 行为与主机回归，不代表 iPad/iPhone 真机 VoiceOver、触摸、媒体或后台计时资格。页面由本地测试服务直接提供，未声称经过本卡独立 Core 嵌入构建或设备部署；这些由主任务最终候选整合记录。未执行真实呼叫、门锁或 SOS。

主任务独立复核通过（`evidence/review.json`）；四项主机生产渲染器复跑通过，本卡标记 VERIFIED_IN_SCOPE。
