# T27 后台三方合并与可见冲突

状态：实现与目标层验收已通过；等待主任务最终独立复核及 canonical 状态更新。本子任务未更新 progress、版本或发布状态。

## 修改与行为

13 个弹窗编辑入口以及 inline 设置、raw key/value、当前导入入口均从一致的 Core 配置快照捕获原值和 revision。普通保存只提交 typed diff。遇到 409 后重新读取当前快照，比较原值、草稿和服务器值；互不冲突的字段可以自动合并，同字段不同值必须明确选择。一次保存最多自动重比一次、最多发出三次 commit，不会无限追写。

原表单 DOM、焦点和滚动在失败后保留；部分冲突未选择时，已作出的选择不丢失。登录恢复保留非敏感 modal/inline 草稿及原始 base/revision，重新保存仍走比较。密码、敏感输入和原始 JSON 输入在认证失效时清空，不将草稿写入 localStorage。

缺失、null、删除和数组分别处理。原有 lossless builder 清除已知字段时转换成显式删除；raw/import 的省略字段仍是保留。semantic UI 在一次 set 中使用 `remove_fields` 清除属性并修改其他属性。该字段由主任务实现 Core 原子比较/校验/提交，避免分两次写入。数组按整体冲突，不推断实体身份。

公告编辑仍调用专用接口，附带 expected_revision；只发送相对 ttl_s 或 expiry="today"。Core 生成 created_ms/expires_ms 和作者。客户端不再从本机墙钟生成公告写入时间。选择保留服务器敏感引用时，清理旧凭据延后，避免把仍被使用的引用删除。

入口清单见 `caller-inventory.md`。未将配置 CAS 解释为跨节点共识；T28 的持久冲突记录、T29/T30 的 staged import 尚未由本卡完成。

## 真实反例与验收

修复前生产 app SHA 为 `ecfa4cac230ac7091c9cf6fb6e467590122bc5f7be9c3f2c827ae4065a669005`。原生 Codex 浏览器运行相同用例，T27-01 观察到整对象覆盖并发通知修改；T27-02 观察到同字段被静默覆盖；T27-03 观察到提交包含未改字段；T27-04 没有冲突选择。完整记录见 `evidence/browser-red.json`，初始四例记录另保留 `browser-red-initial.json`。

最终生产 app SHA 为 `c79e255147ef018aec84cfcfeb09bb4d8c2e36d37fe00ff860d98aff8d13da4a`，完整输入在 `source-final.json`。最终 red/green 使用相同用例 SHA `668877ead3d8610e3911189bd0903b9e92d6956999d5e7a46fc79aeb559f8219`。

| 验收 | 实测结果 | 证据 |
| --- | --- | --- |
| T27-01 不同字段交错保存 | PASS；名称和并发通知开关都保留 | `evidence/browser-green.json` |
| T27-02 同字段不同值 | PASS；服务器值未覆盖，原表单显示三方选择 | 同上 |
| T27-03 未知字段和 null | PASS；保留未知/null/数组，提交不含未改字段 | 同上 |
| T27-04 解决期间再次变化 | PASS；显示更新后的值，再次比较，提交次数有界 | 同上 |

同一实际 Chromium 153 浏览器另通过 8 项：modal 登录恢复、数组整体选择、不完整选择保留、inline 原 revision、公告 Core 时间 payload、显式 delete、semantic mixed reset、inline 登录回到原表单。合计 12/12 PASS。`draft-final-green.json` 用最终 app 重跑 T25 的 9 项失败/超时/慢保存/旧回调/凭据结果回归，9/9 PASS。

主任务执行的 Core companion 测试末行实测 13/13、509 assertions、exit 0，覆盖 notice conditional HTTP/native 入口以及 remove_fields 的原子校验。见 `evidence/core-companions-green.log`、对应 metadata 和 `core-source-green.json`；此处不把这些 Core 测试冒充浏览器端到端部署测试。

最终 `web-regression-final.json/.log`：21 个 Web 测试 suite 加 i18n/source-language 两项检查，全部 exit 0。新增 `admin_config_merge.test.js` 调用真实生产函数验证 typed null/delete/arrays、引用脱敏、明确字段清除、semantic remove_fields，以及祖先类型变化。

## 独立复核修正

主任务 R1 发现父级 missing 与 null、两个不同 scalar/array 都可能被简化成 object=false。已改为非对象祖先保存并比较完整 typed value；对象到对象仍允许合并不同子字段。新增 missing→null、scalar 1→2、array [1]→[2] 三个真实生产函数反例，全都必须出现冲突。修正前的源码清单和通过记录另存 `source-candidate-r1-complete.json`、`*-before-ancestor-fix.*`；最终浏览器和 Web 记录均重新匹配修正后的源码。

## 证据事故与边界

复用 T25 fixture 的第一轮开发回归曾错误覆盖 T25 的 browser-green.json。覆盖内容已保存为本卡 `draft-browser-development-r1.json` 并立即通知主任务。未伪造旧时间或手写 PASS 恢复：使用 T26 r4 冻结目录中与 T25 原报告完全一致的 app/cases 实际重跑 9/9，生成新时间的 `t25-revalidation-green.json`。主任务负责将 T25 历史审计与替代证据明确关联。fixture 已支持独立输出目录和前缀，本卡之后的运行均写本卡目录。

浏览器测试在原生浏览器执行生产 app.js、真实 DOM、XHR 回调和编辑器；XHR 服务端由受控 fixture 提供并发版本/失败，不是真实双设备或物理门锁。Core 服务单独用其真实 HTTP/native 测试验证。未测试 Safari/iOS 硬件、未部署、未声称 T28、未触发真实开门/SOS。独立 browser skill 的 IAB discovery 失败后，依其回退规则改用可用的 CUA IAB；浏览器版本和时间保存在每次记录。冲突窗口已实际截图检查，原值/我的值/当前值、两个明确选择及返回编辑按钮可读。

版本与生成资源由主任务统一管理。没有修改归档 ios-legacy，未推送或发布。

## 最终独立复核

主任务已核对最终 11 项源码输入和验收引用的全部证据摘要，独立运行生产 typed merge 测试通过；R1 已修复，复核 PASS。Core companion metadata 已注明真实 macOS arm64、stub、unsigned、产物摘要及 13/509 实测。T27 关闭于限定 production_test 范围，不代表 T28 或硬件资格完成。

Android 可移植性跟进：公告到期时间传入 json::set 前显式转为 int64_t，避免 NDK 平台 long/long long 与 double 重载歧义。T35 Android r7 的现代/legacy19 实际 native 构建已验证该表达式；其 Core 输入为记录的 T12 freeze 加此修正，不代表全套 T27–T29 最终集成。证据见 evidence/android-portability-followup.json。
