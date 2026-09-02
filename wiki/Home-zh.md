# ox-app-doorbell Wiki

> English: [Home](Home) / 日本語: [Home-ja](Home-ja) / **繁體中文** (本頁)

目前功能狀態與限制以 [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md) 為準。

這是具備複製 mesh state 的 multi-node doorbell/intercom；HA、Telegram、Asterisk/PSTN、go2rtc 與
HomeKit 都是 optional integration。已 commission 的 exact client 與 real SIP artifact 所構成的
mesh-native path 可在 integration outage 時繼續；依賴故障 integration 的 action 則無法運作。

本 Wiki 不是 [docs/](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/overview.md)
的复制品，而是一座「可以当读物看的知识库」。操作步骤的逐条细节以仓库中的 docs 为准，
背景、思路与使用技巧则请以本 Wiki 为入口。

## 先读哪里 —— 按目的索引的地图

| 你是…… | 想做什么 | 该读的页面 |
|---|---|---|
| 初次接触的人 | 想知道这套系统是什么 | 本页 + [设计理念](Design-Philosophy-zh) |
| 正在考虑的人 | 查看 supported 與 conditional capability | [功能总览](Features-zh) + [status matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md) |
| 住户（家人） | 想知道如何应答来客 | [住户使用指南](Usage-Residents-zh) |
| 住户（家人） | 想在外面查看、通话 | [住户使用指南](Usage-Residents-zh) 的「外出时」 |
| 管理员 | 想要设置界面导览和配方 | [管理员指南](Usage-Admin-zh) |
| 管理员 | 想添加新设备 | [管理员指南](Usage-Admin-zh) 的「添加设备」 |
| 部署者 | 想设计访客（快递员、来客）的体验 | [访客体验](Usage-Visitors-zh) |
| 开发者 | 想了解 mesh / CRDT / SIP 的内部 | [架构](Architecture-zh) |
| 开发者 | 想知道「为什么是这样的设计」 | [决策记录](Decisions-zh) |
| 遇到问题的人 | 铃不响、恢复不了、被偷了 | [FAQ](FAQ-zh) |

## 30 秒看懂全貌

- **裝置**: native door/indoor shell、visual TV client、browser panel。role 或 OS target 不代表
  hardware certification。
- **按鈴後**: rule engine dispatch 已配置的 local 與 optional-integration action。
- **接聽**: 可用方式取決於 target shell、real SIP backend、media hardware 與 commissioned integration。
- **配置**: native node 複製 CRDT，但仍須 export；複製不能替代 backup 或 secret recovery。

## 仓库的主要入口

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) —— 三语言枢纽
- [docs/zh/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/overview.md) —— 系统全貌
- [docs/zh/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/deployment.md) —— 实际住宅部署清单
- [docs/zh/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/config-schema.md) —— 配置的规范参考
- [docs/zh/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/network-ports.md) —— 端口总表
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) —— Asterisk + 光纤电话
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) —— Home Assistant / go2rtc / HomeKit

## 关于语言

無後綴 English 頁面為正本，日文 (`-ja`) 與繁體中文 (`-zh`) 為同步翻譯。應用 UI 支援
日/英/中三种语言，在门口机上访客可以自行切换语言
（参见[访客体验](Usage-Visitors-zh)）。
