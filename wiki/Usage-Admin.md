# 管理者向けガイド — 管理画面の歩き方とレシピ集

> English: [Usage-Admin-en](Usage-Admin-en) / 中文: [Usage-Admin-zh](Usage-Admin-zh)

管理画面は**どのノードでも同じ**です: `http://<任意の端末IP>:47180/admin/`。
どこで書いても CRDT が全端末へミリ秒で同期します。初回アクセス時のログインが
管理パスワードの設定になります。導入そのものの手順は
[docs/ja/deployment.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/deployment.md) を正としてください。

## 13 タブの地図

| タブ | 何をする所か |
|---|---|
| ダッシュボード | ノード一覧 (リーダー / オンライン / 時刻同期)・ライブ映像・同期状態 |
| デバイス | 端末毎の名前・役割 (門口機/室内機/TV)・担当ドア・カメラ (codec/解像度/fps)・動体・表示言語 |
| ドア／建物 | 玄関と棟の登録、日英中ラベル |
| 呼出ルール | 「いつ・どこで・何が起きたら・何をするか」(押鈴/動体/離線 × スケジュール × アクション) |
| 通知先 | households — 家族の Telegram chat_id と SIP 内線 |
| クイック返信 | 定型文の編集 (多言語・読み上げ・カスタム音声・並び順) |
| 統合 | MQTT (HA) / Telegram / SIP (Asterisk) / WebRTC / タイムゾーン |
| イベント履歴 | press / motion / reply / offline… の時系列、種別絞り込み |
| 資産 | 背景画像・カスタム音声のアップロードとノード毎キャッシュ被覆率 |
| テーマ | 門口機の背景色・背景画像 (プレビュー付き)・明るさ・夜間モード |
| 文言 | 実行時の文言上書き (i18n_overrides) — 空欄なら既定文言 |
| 用件 | 訪客の用件ボタン (ラベル・アイコン・並び順) の編集 |
| システム | パネル token・追加 PIN 発行・設定エクスポート/インポート・ログ・生 JSON |

## よく使うレシピ集

### 宅配便だけ自動「置き配」応答 (電話を鳴らさない)

1. クイック返信タブに `置き配をお願いします` を追加 (必要なら英/中も。カスタム音声も可)。
2. 呼出ルールタブで新ルール: 条件 = 呼出ボタン、用件 = 宅配便 (p_delivery) のみ。
3. アクション = auto_reply (作成した返信を指定) + Telegram (記録用)。SIP 発呼は入れない。
4. 既存の汎用ルール側で宅配便を除外するか、優先順を確認して完了です。

### 夜間はチャイムを消音 (通知は残す)

統合 → 静音時間帯 (quiet_hours) で時間帯 (例 23:00–07:00) を設定し、「抑制する」に
チャイムだけを入れます。SIP / Telegram / HA は「常に許可」のままに — 来客を漏らしません。
なお Asterisk 側の夜間分岐 (dialplan の GotoIfTime) は**別の時計**で動くことに注意
([FAQ](FAQ) 参照)。

### 端末別の背景を設定する

資産タブで画像 (jpeg/png ≤3MB) をアップロード → テーマタブで全体既定を設定、
端末別にしたい場合はデバイスタブの該当端末の local.theme を上書きします。アップロード後、
各門口機が能動的に前取りするので、被覆率が揃ってから表示されます (数秒)。

### 文言の季節替え

文言タブで例えば `idle.touch_to_call` を「タッチして呼び出してください 🎍」に上書き。
保存した瞬間に全門口機が再描画します。空欄に戻せば既定文言に戻ります。
プレースホルダ ({name} 等) は保存時に整合検証されます。

### 新しい端末の追加 (PIN 手順)

1. システムタブ →「デバイスを追加」→ 追加 PIN が発行されます (**10 分有効**)。
2. 新端末でアプリを起動し、初期設定画面で既存ノードの IP とこの PIN を入力。
3. PSK と設定が自動配布され、mesh に合流します。
4. デバイスタブで名前・役割・担当ドアを割り当てて完了。
   平台別の kiosk 化は [Android](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/android/provision.ja.md) /
   [iOS](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md) /
   Windows (`deploy/provision/windows/provision.cmd`) を参照。

### パネル token の配布

網頁パネル (door/monitor/call.html) と映像 URL は `?k=<token>` で認証します。
token はシステムタブで確認・ローテートできます。**ローテートすると旧 token は即時無効**
なので、配布済みの Web クリップ (iPad 1 等) や go2rtc の URL も更新してください。

## バックアップとリストア

- **エクスポート**: システムタブ → エクスポート。どのノードで実行しても全量が出ます
  (secrets の実体は含まれません — secure store は端末ローカルです)。
- **インポート**: エクスポートした JSON を貼り付けるとフラット化して逐項書き込まれます。
- 日常の生存性は分散が担保します — 1 台生きていれば設定は残っています。エクスポートは
  「全端末を同時に失う」災害向けの保険です。

## 更新の当て方

- **Windows**: GitHub Actions の `doorbell-windows` artifact を配布。watchdog が
  停止 → 差替 → 再起動を許容します。
- **Android**: Device Owner なら静默インストールできます。
- **iOS**: Ad Hoc 署名は**年 1 回の再署名が必須**です。アプリ内の期限表示と
  Telegram の 30 日前警告に従ってください ([FAQ](FAQ) も参照)。
- 更新前にリポジトリへタグを打っておくと戻しやすくなります。
- Windows Update は provision で封鎖済み — 保守日に手動適用します。

## セキュリティ運用のチェックリスト

- kiosk 退出 PIN を既定 (000000) から必ず変更する。
- パネル token を控え、不要になった配布先が出たらローテート。
- 端末盗難時: システムタブで PSK 再発行 → 全端末を再配対、SIP パスワードと
  Telegram bot token も回転します ([FAQ](FAQ) の該当項参照)。
