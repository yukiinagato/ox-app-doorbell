# ox-app-doorbell Wiki

> 日本語: [Home](Home) / English: [Home-en](Home-en) / **中文** (本页)

这是一套面向自家住宅（多栋楼、多个玄关）的**无服务器自愈门铃系统**。它把旧式 Windows 平板
（Toughpad）、Android、iOS 设备重新利用为玄关的门口机和室内机。真实源是 P2P mesh ——
即使 Home Assistant 或 Asterisk 宕机，呼叫、对讲、通知依然照常运转。通过光纤电话（ひかり電話）
还能呼入外出时的手机（PSTN），并且只需按一下 Telegram 的按钮即可完成对访客的答复。

本 Wiki 不是 [docs/](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md)
的复制品，而是一座「可以当读物看的知识库」。操作步骤的逐条细节以仓库中的 docs 为准，
背景、思路与使用技巧则请以本 Wiki 为入口。

## 先读哪里 —— 按目的索引的地图

| 你是…… | 想做什么 | 该读的页面 |
|---|---|---|
| 初次接触的人 | 想知道这套系统是什么 | 本页 + [设计理念](Design-Philosophy-zh) |
| 正在考虑的人 | 想一览它能做什么 | [功能总览](Features-zh) |
| 住户（家人） | 想知道如何应答来客 | [住户使用指南](Usage-Residents-zh) |
| 住户（家人） | 想在外面查看、通话 | [住户使用指南](Usage-Residents-zh) 的「外出时」 |
| 管理员 | 想要设置界面导览和配方 | [管理员指南](Usage-Admin-zh) |
| 管理员 | 想添加新设备 | [管理员指南](Usage-Admin-zh) 的「添加设备」 |
| 部署者 | 想设计访客（快递员、来客）的体验 | [访客体验](Usage-Visitors-zh) |
| 开发者 | 想了解 mesh / CRDT / SIP 的内部 | [架构](Architecture-zh) |
| 开发者 | 想知道「为什么是这样的设计」 | [决策记录](Decisions-zh) |
| 遇到问题的人 | 铃不响、恢复不了、被偷了 | [FAQ](FAQ-zh) |

## 30 秒看懂全貌

- **设备**: 门口机（固定在玄关的 Toughpad/Android/iOS）+ 室内机（平板/PC/手机）+
  Android TV / 浏览器（最低支持 iPad 1 的 Safari）。所有设备都搭载共享 C++ 核心 (doorbell-core)。
- **按铃后**: 规则引擎并行执行 SIP 呼叫（内线 + 外出手机同时振铃）/ Telegram 带照片通知 /
  Home Assistant 事件 / 室内门铃声。
- **应答方式**: 在室内机接听、用电话接听、按 Telegram 按钮回复预设短语、用 TV 遥控器回复——
  任选其一。回复会以大字显示在门口机上并被朗读出来。
- **配置**: 在任意节点的管理界面（`http://<ip>:47180/admin/`）修改，CRDT 都会在
  毫秒级同步到所有设备。只要还有 1 台设备存活，配置就不会丢失。

## 仓库的主要入口

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) —— 三语言枢纽
- [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) —— 系统全貌
- [docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) —— 实际住宅部署清单
- [docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md) —— 配置的规范参考
- [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md) —— 端口总表
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) —— Asterisk + 光纤电话
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) —— Home Assistant / go2rtc / HomeKit

## 关于语言

文档以日语为正本，英语 (-en) 与中文 (-zh) 为同步译文。应用的 UI 本身支持
日/英/中三种语言，在门口机上访客可以自行切换语言
（参见[访客体验](Usage-Visitors-zh)）。
