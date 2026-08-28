# 導入手順 (自宅への実ロールアウトのチェックリスト)

順序どおりに進めれば、既存の HA / Asterisk / ひかり電話環境に全端末が組み込まれる。
各節の詳細は括弧内の文書へ。

## 0. 事前準備

- [ ] HA ホスト (x86 iGPU or RPi4+) に Mosquitto アドオン + go2rtc が動いている
- [ ] Asterisk に `deploy/asterisk/pjsip.conf` / `extensions.conf` を取り込み
      (`CHANGE_ME_*` と携帯番号を書換、ひかり電話 HGW の内線番号を設定) — 手順は
      `deploy/asterisk/README.ja.md`
- [ ] Telegram bot (@ox_doorbell_bot) の token と家族の chat_id 一覧
- [ ] 各端末の電池点検 (膨張チェック)。可能なら電池を外して直結給電

## 1. 最初の 1 台 (管理の起点)

任意のプラットフォームで良いが、常時給電の門口機 (Toughpad 推奨) が適する。

- [ ] Windows: GitHub Actions の `doorbell-windows` artifact を展開 →
      `deploy/provision/windows/provision.cmd` (管理者) → kiosk ユーザーで
      `kiosk-enable.cmd` → 再ログイン (詳細: `win-build-env.md` §実機)
- [ ] 初回起動で `%ProgramData%\Doorbell\boot.json` が生成される — `name` / `role` /
      `door` / `psk_hex` (64hex を自作) / `seed_peers` を編集して再起動
- [ ] ブラウザで `http://<端末IP>:47180/admin/` → 初回ログイン = 管理パスワード設定
- [ ] **セキュリティ初期化**: kiosk 退出 PIN を変更 (`exit_pin.txt`、既定 000000)、
      「システム」タブでパネル token を控える

## 2. 設定の骨格 (管理画面で)

- [ ] ドア／建物: 各玄関 (d_front 等) と棟を登録、日英中ラベル
- [ ] 統合: MQTT (HA の Mosquitto)、Telegram (token + poll_updates ON)、SIP
      (Asterisk IP + 各端末の内線/パスワード)、tz
- [ ] 通知先: households に家族の chat_id / 内線
- [ ] 呼出ルール: ボタン押下 → SIP 600 + Telegram + チャイム。宅配 (p_delivery) だけ
      auto_reply「置き配」+ 電話なし、などはお好みで
- [ ] テーマ / 文言 / 用件 / クイック返信 / 資産 (背景画像・カスタム音声) を調整

## 3. 端末の追加 (何台でも)

- [ ] 管理画面「システム」→「デバイスを追加」で PIN 発行 (10 分有効)
- [ ] 新端末でアプリ起動 → 初期設定で 既存ノード IP + PIN → PSK/設定が自動配布
      (または boot.json に psk_hex/seed_peers を直書きでも可)
- [ ] デバイスタブで名前・担当ドア・役割 (door_station / indoor_panel / TV) を割当
- Android: `deploy/provision/android/provision.ja.md` (Device Owner 化 = 完全 kiosk、TV 節あり)
- iOS: `deploy/provision/ios/provision.ja.md` (監督 + Single App Mode、Ad Hoc 署名と年次更新)
- iPad 1 等の legacy: Safari で `http://<任意ノード>:47180/panel/door?k=<token>` を
  Web クリップ化 (`monitor` も同様)。自動ロック=なし に設定
- iPad 1 (A1219, iOS5.1.1) を越獄して原生ノード化する場合は
  `deploy/provision/ios/ipad1-jailbreak.md` (完全 core・音声・開錠、外付けマイクで対講) を参照

## 4. HA / HomeKit

- [ ] Mosquitto へ接続された時点で HA に実体が自動出現 (呼び鈴 event / 動体 /
      端末オンライン / 緊急 / 来訪者言語 sensor)
- [ ] `deploy/ha/go2rtc.yaml` を各門口機の IP に合わせて取り込み
      (codec=h264 の端末は `#video=copy` — トランスコード不要)
- [ ] `deploy/ha/configuration-snippets.yaml` の HomeKit Bridge / ウォッチドッグ /
      actionable 通知 / 開錠 automation を取り込み、entity_id を実物に合わせる
- [ ] iPhone のホーム App にドアホン通知+ライブが出ることを確認。外出先から見るには
      Apple TV / HomePod をホームハブに

## 5. 動作検証 (端末追加のたび)

- [ ] 呼出 → 内線+携帯が鳴る / Telegram 写真+ボタン / HA 通知 / 室内チャイム
- [ ] Telegram のボタンで返信 → 門口機に大きな文字+読み上げ
- [ ] 室内機から「応答」→ 電話レッグが切れて双方向通話 (映像含む)
- [ ] 通話中に携帯から *1 → HA の錠が開く
- [ ] 端末の LAN ケーブルを抜く → 30 秒以内に Telegram/HA へオフライン通知
- [ ] **HA と Asterisk を止めても**: 呼出表示・チャイム・室内通話・パネルが動き続ける

## 6. 運用

- 更新: GitHub Actions の artifact を配布 (Windows は watchdog が停止→差替→再起動を
  許容。Android は DO サイレントインストール)。更新前にタグを打つと戻しやすい
- iOS Ad Hoc 署名は **年 1 回の再署名が必須** — アプリ内の期限表示と Telegram の
  30 日前警告に従う (恒久化は App Store 公開 = 計画 Phase 7)
- 設定バックアップ: 管理画面「システム」→ エクスポート (どのノードでも全量)
- 端末盗難時: 管理画面で PSK 再発行 → 全端末再ペアリング、SIP パスワード・bot token を回転
- Windows Update は封鎖済み — 保守日に手動適用 (`provision.cmd` §6 参照)
