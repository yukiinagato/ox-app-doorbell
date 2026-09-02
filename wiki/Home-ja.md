# ox-app-doorbell Wiki

> **日本語** (このページ) / English: [Home](Home) / 中文: [Home-zh](Home-zh)

機能の現在状態と制限は [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md) が優先します。

複製 mesh state を持つ multi-node doorbell/intercom で、HA、Telegram、Asterisk/PSTN、go2rtc、
HomeKit は optional integration です。commission 済みの exact client と real SIP artifact の
mesh-native path は integration outage 中も継続できますが、停止した integration に依存する action は
動きません。

この Wiki は [docs/](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md)
の複製ではなく、「読み物としての知識庫」です。手順の正確な逐条はリポジトリの docs を正、
背景・考え方・使いこなしはこの Wiki を入口にしてください。

## まずどこを読むか — 目的別の地図

| あなたは… | したいこと | 読むページ |
|---|---|---|
| はじめての方 | このシステムが何者か知りたい | このページ + [Design-Philosophy](Design-Philosophy-ja) |
| 検討中の方 | 対応済み・条件付き capability を確認したい | [Features](Features-ja) + [status matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md) |
| 住民 (家族) | 来客にどう応答するか知りたい | [Usage-Residents](Usage-Residents-ja) |
| 住民 (家族) | 外出先から見たい・話したい | [Usage-Residents](Usage-Residents-ja) の「外出時」 |
| 管理者 | 設定画面の歩き方・レシピが欲しい | [Usage-Admin](Usage-Admin-ja) |
| 管理者 | 新しい端末を追加したい | [Usage-Admin](Usage-Admin-ja) の「端末追加」 |
| 設置者 | 訪客 (宅配員・来客) の体験を設計したい | [Usage-Visitors](Usage-Visitors-ja) |
| 開発者 | mesh / CRDT / SIP の中身を知りたい | [Architecture](Architecture-ja) |
| 開発者 | 「なぜこの設計なのか」を知りたい | [Decisions](Decisions-ja) |
| 困っている方 | 鳴らない・戻らない・盗まれた | [FAQ](FAQ-ja) |

## 30 秒でわかる全体像

- **端末**: native door/indoor shell、visual TV client、browser panel。role や OS target だけでは
  hardware certification を意味しません。
- **押鈴すると**: rule engine が設定済み local/optional-integration action を dispatch します。
- **応答は**: target shell、real SIP backend、media hardware、commission 済み integration に依存します。
- **設定は**: native node が CRDT を複製します。export も必要で、複製は backup や secret recovery の
  代わりではありません。

## リポジトリの主な入口

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) — 三言語ハブ
- [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) — システム全体像
- [docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) — 実宅ロールアウトのチェックリスト
- [docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md) — 設定の正準リファレンス
- [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md) — ポート総表
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) — Asterisk + ひかり電話
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) — Home Assistant / go2rtc / HomeKit

## 言語について

無 suffix の English page が正本で、日本語 (`-ja`) と繁體中文 (`-zh`) は同期訳です。アプリの UI 自体は
日/英/中の三言語に対応し、門口機では訪客が自分で言語を切り替えられます
([Usage-Visitors](Usage-Visitors-ja) 参照)。
