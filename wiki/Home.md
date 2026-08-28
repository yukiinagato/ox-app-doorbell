# ox-app-doorbell Wiki

> **日本語** (このページ) / English: [Home-en](Home-en) / 中文: [Home-zh](Home-zh)

自宅 (複数棟・複数玄関) 向けの**サーバレス自愈ドアホンシステム**です。旧型の Windows タブレット
(Toughpad)・Android・iOS 端末を玄関の門口機や室内機として再利用します。真実源は P2P メッシュ —
Home Assistant や Asterisk が落ちても、呼出・対講・通知は動き続けます。ひかり電話経由で
外出先の携帯 (PSTN) にも着信し、Telegram のボタン 1 つで訪客への返答まで完結します。

この Wiki は [docs/](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md)
の複製ではなく、「読み物としての知識庫」です。手順の正確な逐条はリポジトリの docs を正、
背景・考え方・使いこなしはこの Wiki を入口にしてください。

## まずどこを読むか — 目的別の地図

| あなたは… | したいこと | 読むページ |
|---|---|---|
| はじめての方 | このシステムが何者か知りたい | このページ + [Design-Philosophy](Design-Philosophy) |
| 検討中の方 | 何ができるのか一覧したい | [Features](Features) |
| 住民 (家族) | 来客にどう応答するか知りたい | [Usage-Residents](Usage-Residents) |
| 住民 (家族) | 外出先から見たい・話したい | [Usage-Residents](Usage-Residents) の「外出時」 |
| 管理者 | 設定画面の歩き方・レシピが欲しい | [Usage-Admin](Usage-Admin) |
| 管理者 | 新しい端末を追加したい | [Usage-Admin](Usage-Admin) の「端末追加」 |
| 設置者 | 訪客 (宅配員・来客) の体験を設計したい | [Usage-Visitors](Usage-Visitors) |
| 開発者 | mesh / CRDT / SIP の中身を知りたい | [Architecture](Architecture) |
| 開発者 | 「なぜこの設計なのか」を知りたい | [Decisions](Decisions) |
| 困っている方 | 鳴らない・戻らない・盗まれた | [FAQ](FAQ) |

## 30 秒でわかる全体像

- **端末**: 門口機 (玄関に固定した Toughpad/Android/iOS) + 室内機 (タブレット/PC/スマホ) +
  Android TV / ブラウザ (iPad 1 の Safari まで)。全端末が共有 C++ コア (doorbell-core) を積みます。
- **押鈴すると**: ルールエンジンが SIP 発呼 (内線 + 外出先携帯の同時呼) / Telegram 写真付き通知 /
  Home Assistant イベント / 室内チャイムを並行実行します。
- **応答は**: 室内機で出る・電話で出る・Telegram のボタンで定型文を返す・TV のリモコンで返す、の
  どれでも。返信は門口機に大きな文字で表示され、読み上げられます。
- **設定は**: どのノードの管理画面 (`http://<ip>:47180/admin/`) で書いても、CRDT が
  全端末へミリ秒で同期します。1 台生きていれば設定は失われません。

## リポジトリの主な入口

- [README.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/README.md) — 三言語ハブ
- [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) — システム全体像
- [docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) — 実宅ロールアウトのチェックリスト
- [docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md) — 設定の正準リファレンス
- [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md) — ポート総表
- [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) — Asterisk + ひかり電話
- [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md) — Home Assistant / go2rtc / HomeKit

## 言語について

文書は日本語が正本で、英語 (-en) と中文 (-zh) は同期訳です。アプリの UI 自体は
日/英/中の三言語に対応し、門口機では訪客が自分で言語を切り替えられます
([Usage-Visitors](Usage-Visitors) 参照)。
