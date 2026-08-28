# FAQ — よくある質問と現実的な答え

> English: [FAQ-en](FAQ-en) / 中文: [FAQ-zh](FAQ-zh)

## 障害・トラブル

### Q1. チャイムが鳴らない。どこから見ればいい?

順に切り分けます: (1) 管理画面のダッシュボードで門口機・室内機が**オンライン**か、
時刻同期警告が出ていないか。(2) イベント履歴に press が**記録されているか** —
記録されていれば「押鈴は届いている、アクションの問題」、無ければ端末/mesh の問題。
(3) 呼出ルールが有効か、対象ドアに合っているか、quiet_hours にチャイムが抑制されて
いないか。(4) 電話だけ鳴らないなら Asterisk 側 (`pjsip show endpoints` /
`pjsip show registrations`) を確認します。

### Q2. Home Assistant が落ちたらどうなる?

**ドアホンは全部動き続けます。** 押鈴表示・チャイム・室内対講・Telegram・電話は無傷です。
失われるのは HA 経由の機能 (HomeKit 通知・HA 自動化・go2rtc 映像) だけ。HA が戻れば
MQTT ブリッジが自動再接続し、discovery と状態を全再発行します。

### Q3. Asterisk が落ちたら?

対講・監聴は Asterisk 非経由の直接 SIP なので**そのまま動きます**。死ぬのは電話腿
(内線・携帯への発呼・DTMF 開錠) と網頁ブラウザ通話だけです。→ [Architecture](Architecture)

### Q4. 停電から復帰した後、何かする必要は?

原則ありません。各端末は自動起動 (シェル置換 / Device Owner / SAM) し、mesh に再合流し、
設定は CRDT なので勝手に一致します。NTP 同期が済むまで時刻依存機能 (スケジュール・
夜間モード) がずれる可能性はあります — ダッシュボードの「時刻未同期」警告が消えるのを
確認してください。HGW/Asterisk の復帰が遅い場合、電話腿の再登録は retry (60 秒間隔) 頼みです。

### Q5. 押鈴から通知まで妙に遅い

Telegram/MQTT はリーダーだけが送ります。リーダー交代直後は数秒の空白があり得ます。
恒常的に遅いなら、リーダーが電池駆動の弱い端末に載っていないか確認し、常時給電の端末に
`caps_override: { "mains_power": true }` を付けてリーダー資格を寄せてください。

### Q6. 訪客言語が日本語に戻らない / 勝手に戻る

仕様です: 無操作 `ui.visitor_lang_revert_s` 秒 (既定 60) で日本語に自動復帰し、押鈴で
タイマーが延びます。戻らない場合は押鈴やタッチが続いていないか、設定値が極端に
大きくないかを見てください。訪客が `lang=ja` を選ぶと即時復帰します。

### Q7. H.264 (滑らか映像) にしたのに映らない

その端末に硬編が無い可能性があります。`codec: auto` は硬編探測に失敗すると MJPEG に
降りており、`/stream.mp4` は 503 を返します。go2rtc のソース行を mjpeg 用
(`#video=h264#hardware`) に書き換えてください。また `/stream.mp4` は購読者が付いてから
エンコーダが起動するため、初回は数秒かかります。
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

### Q8. 通話中に *1 を押しても錠が開かない

PSTN→HGW の腿は DTMF が inband のことが多く、機種依存です。Asterisk の DSP 検出
(現設定) で拾えるか実測し、駄目なら rfc4733 を試します。
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md) の注意点

## 運用

### Q9. 録画はしているの?

**していません。** 常時録画は設計の境界外です ([Design-Philosophy](Design-Philosophy))。
残るのはイベント時のスナップショットとイベント履歴だけ。録画が欲しければ go2rtc/HA 側で
`/stream.mjpeg` または `/stream.mp4` を録ってください — システムはそれを妨げません。

### Q10. Windows Update はどうすればいい?

門口機の Windows Update は provision で封鎖済みです (弾窗も watchdog が押し戻します)。
放置せず、**保守日に手動適用**してください (`deploy/provision/windows/provision.cmd` §6)。
「勝手に更新して玄関が文鎮化」と「永遠に未パッチ」の間の運用解です。

### Q11. iOS 端末のアプリが急に起動しなくなった

ほぼ確実に **Ad Hoc プロファイルの年次失効**です。再署名した ipa を Apple Configurator で
入れ直してください。期限はアプリ内表示と Telegram の 30 日前警告で予告されます。
恒久対策は App Store (unlisted) 上架 (Phase 7 計画)。
→ [deploy/provision/ios/provision.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md)

### Q12. 端末が盗まれた/紛失した。何をすべき?

(1) 管理画面「システム」で **PSK を再発行** → 残りの全端末を再配対 (盗まれた端末は
mesh に入れなくなります)。(2) SIP パスワードと Telegram bot token を回転。
(3) パネル token をローテート。なお端末内の秘密は secure store (DPAPI/Keystore/Keychain)
保管で、設定 CRDT に平文はありません。盗難自体は「⚠ オフライン」通知 (30 秒以内) で
気付けます。

### Q13. バックアップはどう取る? 何台まで増やせる?

管理画面「システム」→ エクスポートでどのノードからでも全量 JSON が出ます。ただし
日常の生存性は分散が担保 — 1 台生きていれば設定は復元できます。台数の実用上の制約は
むしろ Asterisk/HGW の同時通話数 (通常 2) と Ad Hoc の UDID 上限 (100 台/年) です。

## 端末・互換性

### Q14. iPad 1 (iOS 5) で何ができる?

Safari で網頁パネルを開き Web クリップ化すれば: `door.html` = 押鈴パネル (音声なし・
通知のみ)、`monitor.html` = 受鈴モニタ。双方向通話 (`call.html`) は現代ブラウザ +
WebRTC ゲートウェイが必要なので不可。自動ロックを「なし」にして常時給電で使います。

### Q15. 対応する最低 OS は?

Windows 7 SP1 (要 .NET Framework 4.8 + TLS1.2 パッチ — provision が設定) / Android 5.0
(4.4 は legacy 経路) / iOS 12 (9 は legacy) / ブラウザは iOS 5 Safari まで。
→ [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md) の端末別対応表

### Q16. Apple TV で監視できる?

Apple TV は HomeKit 経由 (家庭 App のカメラ表示・ホームハブ) が基本です。tvOS ネイティブ
アプリは映像表示に対応済み、SIP 監聴は未実装 (TODO)。フル機能の TV 監視端が欲しければ
Android TV を使ってください (来鈴全画面 + 直接監聴 + D-pad 返信)。

### Q17. ブラウザから通話したいのにマイクが使えない

ブラウザの getUserMedia は **HTTPS ページ限定**です。子機のパネルは平文 HTTP なので、
Caddy 等のリバースプロキシ + 内部 CA を立てるか、家庭内の決まった端末だけ Chrome の
insecure-origin 例外を設定します。
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. 夜間はチャイムを消したのに Asterisk の夜間分岐とずれる

quiet_hours は**アプリ側の補正済み時計**、dialplan の GotoIfTime は **Asterisk サーバの
時計**で判定されます。両方に夜間設定を書くなら時刻を揃え、NTP を確認してください。

### Q19. SOS を押したら警察に通報される?

**されません。** 通知先は家族 (Telegram/全端末警報) と、設定した場合のユーザー定義
電話先だけです。通報の判断は人が行う設計です。解除は kiosk PIN が必要です。
→ [Usage-Residents](Usage-Residents) / [Design-Philosophy](Design-Philosophy)

### Q20. 複数玄関で同時に押鈴されたら?

HGW 内線の同時通話数 (通常 2) がボトルネックです。アプリ側はリーダー仲裁で外呼を
直列化し、必要なら dialplan の Queue でも制御できます。宅内側 (チャイム・室内機・
Telegram) は全玄関ぶん並行して普通に動きます。
