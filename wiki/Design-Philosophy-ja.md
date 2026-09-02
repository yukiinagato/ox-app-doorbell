# 設計理念 — なぜこういうドアホンなのか

> 日本語 (this page) / English: [Design-Philosophy](Design-Philosophy) / 中文: [Design-Philosophy-zh](Design-Philosophy-zh)

理念上の目標と現在の release 状態は別です。現在状態は [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/capability-matrix.md) を参照してください。

このプロジェクトは「市販ドアホンの置き換え」ではなく、**家というインフラの一部**として
設計されています。根底にあるのはいくつかの信念です。順に物語として読んでください。

## 1. サーバに命を預けない — サーバレス自愈

mesh state の真実源は P2P mesh にあります。native Core node は gossip し、設定と event を複製します。
optional integration はそれぞれ独立した failure boundary です。

- Home Assistant が落ちても実装済み mesh-local action は継続できますが、HA、HomeKit、HA-hosted
  media action は継続しません。
- Asterisk が落ちても commissioning 済み direct-SIP path は継続できますが、PBX/PSTN/WebRTC path は停止します。
- 生存している正常な native node は複製設定の復元に役立ちますが、backup と device-local secret の
  復旧手段は引き続き必要です。

外部への通知 (Telegram / MQTT) だけは重複を防ぐため「リーダー」ノードが代表して送りますが、
リーダーは決定的アルゴリズムで自動選出され、倒れれば別のノードが引き継ぎます。

## 2. 旧端末を見捨てない — 降級の階梯

玄関に置く端末に最新機は要りません。むしろ「引き出しに眠っている端末」こそ適材です。
このシステムは意図的に長い降級の階梯を持ちます。

- Windows: WPF + .NET Framework 4.8 — **Windows 7 SP1 の Toughpad** まで動きます。
- Android: minSdk 21 (Android 5.0)。4.4 向けの API 19 legacy path はありますが、production SKU
  allowlist は現在空です。tracked debug-contract build は release や hardware qualification の主張ではありません。
- iOS: iOS 12 以降 (9 向け legacy)。廃品 iPhone/iPad が門口機・室内機になります。
- **iPad 1 (A1219/A1337, iOS 5.1.1)** には compatibility shell があります。内蔵マイクと
  スピーカを持ちますが、camera はなく、屋外仕様でもありません。audio、外部 MJPEG/snapshot/no-video、
  recovery、thermal/耐候 enclosure、power
  を実機 commissioning する必要があります。bounded RTSP/RTP-over-TCP H.264 と Annex-B path は
  SDP/sprop、single NAL/STAP-A/FU-A、next-IDR recovery を含む host/loopback test 済みですが、実 IDR
  accept までは degraded で、実 camera iPad qualification はありません。optional root helper も
  実装・host test 済みですが、実機 commissioning が必要です
  ([配備手順](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.ja.md))。
- 映像も同じ思想です: 基調は「どこでも映る」MJPEG。H.264 は対応機だけが使う上位档で、
  非対応機は黙って MJPEG に降りるだけです ([Decisions](Decisions-ja) 参照)。

## 3. 各平台ネイティブ — Electron を選ばなかった

低スペック旧端末で Electron/Web ラッパは重すぎ、カメラ・音声・kiosk・電源制御のような
OS 深部の機能に届きません。そこで**共有 C++ コア (doorbell-core) + 各平台の薄いネイティブ殻**
(WPF / Android / Swift) という構成にしました。ロジックは 1 箇所、UI と OS 統合だけが平台別です。
殻は [core/include/doorbell/doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
の C ABI だけを見ます。

## 4. 電話網という最強の冗長

app push が使えない状況でも利用できる可能性がある電話網は、昔から家にあります。commissioning 済みの
Asterisk/ひかり電話 HGW path と matching rule があれば、押鈴で宅内内線と外出先の携帯 (PSTN) を
並行して鳴らせます。通話中は設定済み DTMF code で開錠などを実行できます。これは「スマートホームの
上に電話を載せる」のではなく、独立して試験した電話 path を別の防衛線として組み込む発想です。

## 5. 「宁重勿漏」— 漏らすくらいなら重ねて知らせる

来客を 1 回逃すコストは、通知が 2 回鳴る煩わしさよりずっと大きいため、rule engine は SIP、
Telegram、HA、chime の独立 action を並行 dispatch できます。ただし action は常に rule-driven です。
管理者は recipient を絞り、channel を silent にし、action 自体を削除できます。`quiet_hours` は使用可能な
condition の一つであり、その他すべての channel が必ず動くという保証ではありません。

## 6. 安全境界 — 警察・消防へは自動発信しない

SOS の active/clear 状態は常に全 Core node へ複製され、再接続後にも復元されます。各 device が
何を表示・再生するか、Web Push、Telegram、MQTT、ユーザー定義 SIP 宛先を使うかはすべて
rule-driven であり、管理者は意図的に recipient 0 件または silent presentation にできます。誤報リスクと
人間の判断が必要なため、警察・消防への自動発信は実装していません。

開いている Web page には独立した安全用 switch があります。`emergency.web_active_page_alerts` は既定で
`true` なので、rule が recipient 0 件または Push-only でも複製された SOS active/clear 状態を描画します。
無効にしても、正に match した `device_alert` または実際に配信された Push は妨げません。運用上、Core の
`delivery_result` は dispatch attempt の証拠だけで、presentation の証拠は client runtime の channel 別 report です。

raw-state path が on の間、rule TTL は custom sound/decoration を終了できますが、SOS active 中の安全な
赤い overlay は消せず、clear または switch-off だけが消します。明示 target は surface を越えて漏れず、
native-only selector は Web、Web-only group は native shell を対象にしません。`targets` がない legacy
action だけが all-target compatibility を維持します。Web page は 1 つの保存済み `?group=` を poll/Push
に共用します。

## 7. 秘密の置き場所と trusted-LAN 境界

- bot token・SIP パスワードなどの秘密は設定 CRDT に**平文では載せません**。
  `secret:` 参照だけを複製し、実体は各端末の secure store (DPAPI / Keystore / Keychain) に
  保管します。管理画面でも書込のみ・表示不可です。
- Push subscription は complete opaque value のまま扱うため、endpoint と `p256dh`/`auth` key を
  mesh-PSK-derived key と XChaCha20-Poly1305 で schema-v2 CRDT record に一括 seal します。
  config/export に plaintext は出ず、起動時は旧 raw record を再 seal または fail-closed で削除します。
- node HTTP/video は trusted LAN interface で Internet security 境界ではありません。Internet に
  公開せず、保守済み VPN または認証付き TLS reverse proxy を使います。panel URL/token を秘密として
  扱い log・公開 config に載せません ([security](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/security.md))。

## 8. 録画しない

このシステムは監視カメラではなくドアホンです。常時録画はせず、イベント時の
スナップショットと、必要な人が見るライブ映像だけを扱います。録画が欲しい場合は
go2rtc/HA 側で好きに録れます — 境界の外に置いてあるだけです。

---

次: 機能の全体像は [Features](Features-ja)、実装の中身は [Architecture](Architecture-ja)、
個々の設計判断の経緯は [Decisions](Decisions-ja) へ。
