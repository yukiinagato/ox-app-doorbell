# FAQ — よくある質問と現実的な答え

> 日本語 (this page) / English: [FAQ](FAQ) / 中文: [FAQ-zh](FAQ-zh)

platform・hardware の回答は [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md) と [recovery](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/recovery.md) が優先します。

## 障害・トラブル

### Q1. チャイムが鳴らない。どこから見ればいい?

順に切り分けます: (1) 管理画面のダッシュボードで門口機・室内機が**オンライン**か、
時刻同期警告が出ていないか。(2) イベント履歴に press が**記録されているか** —
記録されていれば「押鈴は届いている、アクションの問題」、無ければ端末/mesh の問題。
(3) 呼出ルールが有効か、対象ドアに合っているか、quiet_hours にチャイムが抑制されて
いないか。(4) 電話だけ鳴らないなら Asterisk 側 (`pjsip show endpoints` /
`pjsip show registrations`) を確認します。

### Q2. Home Assistant が落ちたらどうなる?

実装済みの mesh-local path は継続できます。HA automation、HA/HomeKit 通知、HA が配信する
media は停止します。Telegram と PBX にもそれぞれ別の依存先があります。全機能が動くと
仮定せず、実際の配備構成で試験してください。

### Q3. Asterisk が落ちたら?

設定済みの direct SIP は Asterisk を経由しないため、実 artifact が real SIP を使用し、peer が
到達可能なら継続できます。PBX 経由の内線・携帯発呼と browser WebRTC は停止します。
→ [Architecture](Architecture-ja)

### Q4. 停電から復帰した後、何かする必要は?

各 node が実際に再起動して mesh に再参加し、secure-store 参照を解決して、期待する capability を
報告しているか確認します。その後に押鈴、audio、media、integration を試験し、
[recovery guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/recovery.md) に従ってください。

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

**していません。** 常時録画は設計の境界外です ([Design-Philosophy](Design-Philosophy-ja))。
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
保管で、設定 CRDT に平文はありません。offline 通知は、それを選択する rule と利用可能な
integration がある場合にだけ送られます。

### Q13. バックアップはどう取る? 何台まで増やせる?

管理画面の export は複製設定を保存しますが、秘密値は意図的に含みません。artifact の
manifest/package も保存し、device-local secret は別途復旧できるようにしてください。収容台数は
commissioning 済みの端末と integration に依存します。

## 端末・互換性

### Q14. iPad 1 (iOS 5) で何ができる?

2 通りあります。

**(A) compatibility native shell**: iPad 1 は内蔵マイクとスピーカを持ち、camera はありません。
shell、MiniSIP、direct HTTP(S) MJPEG/snapshot、bounded RTSP-over-TCP H.264、no-video profile は
実装されていますが、audio、recovery、最終 enclosure は端末ごとの commissioning が必要です。H.264 ingest と
Annex-B 転送は host/loopback contract 合格済みですが、DESCRIBE/SETUP と実 IDR accept までは capability
が degraded で、実 camera iPad qualification はありません。別の bounded Android→Core fMP4→iPad
smoke は foreground renderer で 15～16 fps を確認済みですが、crash 後の unattended foreground video
resume は未完了です。optional
root helper は実装・host test 済みで、iOS 5 lane には launchd を無効のままにする再現可能な staged
DEB がありますが、iPad 実機 qualification は未完了です。
[配備手順](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.ja.md)。

初代 iPad は屋外仕様ではありません。実 camera、audio、thermal、耐候 enclosure、power、recovery、
helper の組み合わせが実機 commissioning に合格するまで、qualified outdoor station として扱わないでください。

**(B) 越獄したくない → 従来の網頁パネル (best-effort)**: Safari で網頁パネルを開き
Web クリップ化すれば `door.html` = 押鈴パネル (音声なし・通知のみ)、`monitor.html` =
受鈴モニタとして使えます。双方向通話 (`call.html`) は現代ブラウザ + WebRTC ゲートウェイが
必要なので不可。いずれの場合も自動ロックを「なし」にして常時給電で使います。

### Q15. 対応する最低 OS は?

build target と qualification は別です。
[capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md)
を参照してください。特に Android API 19 の production allowlist は現在空で、**supported SKU は 0 台**です。
tracked Android job は debug-contract build であり、release artifact や hardware qualification ではありません。

### Q16. Apple TV で監視できる?

Apple TV に microphone がないため、tvOS の product boundary は listen-only です。現在 tracked されている
証拠は **real PJSIP を link した unsigned Debug arm64 simulator build** だけです。Release build、署名済み
device artifact、Apple TV での実行、hardware/audio qualification はありません。したがって tvOS monitor を
release-supported として配備しないでください。HomeKit の camera/home hub は別 integration です。

### Q17. ブラウザから通話したいのにマイクが使えない

ブラウザの getUserMedia は **HTTPS ページ限定**です。子機のパネルは平文 HTTP なので、
Caddy 等のリバースプロキシ + 内部 CA を立てるか、家庭内の決まった端末だけ Chrome の
insecure-origin 例外を設定します。
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. 夜間はチャイムを消したのに Asterisk の夜間分岐とずれる

quiet_hours は**アプリ側の補正済み時計**、dialplan の GotoIfTime は **Asterisk サーバの
時計**で判定されます。両方に夜間設定を書くなら時刻を揃え、NTP を確認してください。

### Q19. SOS を押したら警察に通報される?

**されません。** SOS が警察や消防へ自動発信することはありません。`emergency_on` と
`emergency_off` の状態は全 Core node に複製されますが、recipient と presentation はすべて rule が
選びます。device、role、Web subscription group、Telegram、MQTT、ユーザー定義 SIP 宛先を対象にでき、
意図的に recipient 0 件または silent にすることもできます。

開いている Web page では `emergency.web_active_page_alerts` の既定値が `true` で、rule が recipient 0 件
または Push-only でも active/clear 状態を描画します。管理者が無効にしても、正に match した
`device_alert` または実際に配信された Push は Web が処理します。有効中、rule TTL は custom
decoration/sound を止めても安全な赤い overlay は clear まで残ります。明示 native-only target は Web
へ届かず、page の保存済み `?group=` が poll/Push delivery の両方を選びます。clear には設定済み
PIN/permission が必要です。diagnostics の `delivery_result` は Core の dispatch attempt だけを示し、visual、sound、system
notification が実際に出た証拠は client runtime の channel 別 report です。
→ [Usage-Residents](Usage-Residents-ja) / [Design-Philosophy](Design-Philosophy-ja)

### Q20. 複数玄関で同時に押鈴されたら?

HGW 内線の同時通話数 (通常 2) がボトルネックです。アプリ側はリーダー仲裁で外呼を
直列化し、必要なら dialplan の Queue でも制御できます。mesh-local と外部 action は match した rule
だけが選ぶため、全玄関で chime、indoor display、Telegram が必ず動くとは仮定しないでください。
