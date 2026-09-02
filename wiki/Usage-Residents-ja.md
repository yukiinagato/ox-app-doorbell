# 住民向け使い方 — 来客への応答

> 日本語 (this page) / English: [Usage-Residents](Usage-Residents) / 中文: [Usage-Residents-zh](Usage-Residents-zh)

家族の日常目線で「こういう時どうするか」をシナリオで説明します。どの電話、app、integration、
device が反応するかは commissioning 済み hardware と matching rule で決まります。設定の変え方は
[Usage-Admin](Usage-Admin-ja)、機能の一覧は [Features](Features-ja) へ。

## シナリオ 1: 在宅中にチャイムが鳴った

matching rule が commissioned indoor station を target にすると、**玄関・用件・訪客言語**と、
source/playback path が available な場合の映像を表示できます。次の 4 経路は conditional capability で、
全設置がすべて持つという保証ではありません。

1. **室内機で出る** — real SIP/audio path が commissioned なら、「応答」で実装済み
   audio/media profile を使えます。
2. **電話で出る** — matching SIP/PSTN rule と commissioning 済み PBX path が使える場合、内線や
   登録した携帯を鳴らせます。普通に電話に出れば門口と話せます。
3. **クイック返信で返す** — 「少々お待ちください」等のボタンを押すだけ。門口機に
   大きな文字で表示され、読み上げられます。手が離せない料理中などに便利です。
4. **TV のリモコンで返す** — rule が選んだ commissioned Android TV path で incoming UI と
   D-pad quick reply を使えます。media は実測 profile が available な時だけ始まります。

電話で出た後に「やっぱり室内機で話したい」となったら、室内機の「応答」を押せば
電話側が切れて室内対講に切り替わります (応答接管)。

### 様子だけ見たい (出たくない)

室内機や TV の「モニタ」で、門口の映像と音声を**一方向で**確認できます。こちらの音は
一切送られません。営業らしき相手なら、そのまま「結構です」のクイック返信で完結です。

## シナリオ 2: 外出中に来客があった

- **matching Telegram rule が有効なら**、写真、用件、言語 badge、設定済み quick reply button を
  通知に含められます。
- **matching SIP/PSTN rule と commissioning 済み PBX path が使える場合**、携帯も鳴らせます。
  出れば門口と通話でき、設定済み DTMF action (例: *1) で開錠できる場合があります。
- **iPhone の家庭 App** (HomeKit 連携設定済みの場合) にも門鈴通知が出て、ライブ映像を
  確認できます。外出先から見るには Apple TV / HomePod のホームハブが必要です。
- **VPN を張れる人**は、宅内 LAN に入れば網頁パネル・管理画面・ブラウザ通話まで
  全機能がそのまま使えます。

どの経路で応答しても、他の家族の画面には「応答済み」が表示され、二重対応を防ぎます。

## シナリオ 3: 荷物だけ受け取りたい日

管理者に頼んで (または自分で管理画面から)「宅配便は自動で『置き配をお願いします』を
読み上げ、電話は鳴らさない」ルールにできます。宅配員が用件ボタンを押した瞬間に
門口機が答えるので、誰も何も操作しません。詳細は [Usage-Admin](Usage-Admin-ja) のレシピ集へ。

## シナリオ 4: 緊急のとき (SOS)

室内機の**緊急ボタンを 3 秒長押し**すると発報します (誤操作防止のための長押しです)。

- SOS active 状態は全 Core node に複製され、node が再接続すると復元されます。
- visual alarm、sound、system notification、Web Push、Telegram、MQTT、SIP 宛先、Home Assistant
  action は、matching rule が選択した場合だけ実行されます。rule は意図的に recipient 0 件または
  silent presentation にできます。
- 開いている Web page では `emergency.web_active_page_alerts` の既定値が `true` なので、recipient
  0 件や Push-only rule でも SOS active/clear 状態を描画します。管理者が無効にしても、正に match
  した `device_alert` または実際に配信された Push は表示できます。有効中は rule TTL で custom
  sound/color decoration が終了しても、安全な赤い SOS overlay は clear まで残ります。page は管理者が
  指定した `?group=` を poll と Push の両方に使います。

**clear** は設定済み PIN/permission を使う権限付き操作です。clear 状態は全 Core node に複製されます。
各 device が clear を表示するか、別の clear 通知を送るかは引き続き rule と Web switch に依存します。

管理画面の delivery diagnostics で `delivery_result` が示すのは Core が dispatch を試みたことだけです。
screen、sound、system notification が実際に出た証拠は client runtime の channel 別 presentation report です。

大事なこと: **警察や消防へ自動発信はされません**。通報するかどうかの判断は必ず人が行う
設計です ([Design-Philosophy](Design-Philosophy-ja) 参照)。必要なら設定でユーザー定義の
電話先 (家族の携帯など) への SIP 発呼を追加できます。

## 夜間の挙動

- **quiet_hours** (既定 23:00–07:00): matching rule はこの時間帯を使って選択した action を抑制・変更
  できます。phone、Telegram、HA など他 channel の実行を保証する設定ではありません。管理画面で
  active rule を確認してください。
- **夜間モード** (既定 22:00–06:00): 門口機・室内機の画面が減光し、赤みがかった表示に
  なります。廊下がまぶしくならないための機能です。
- 夜間の動体検知だけ Telegram に流す、といったルールも組めます ([Usage-Admin](Usage-Admin-ja))。

## 覚えておくと便利な小ネタ

- 室内機からテーマ (門口機の背景) や文言を「推送」できます — 季節の挨拶に変えるなど。
  変更は全端末にミリ秒で反映されます。
- 応答しそこねた来客は event history に残り、選択 camera path が生成できた場合だけ snapshot が付きます。
- offline-device rule が設定されていれば、node が LAN から消えた時に Telegram など選択した alert を
  送れます。delivery はその rule と integration に依存します。
