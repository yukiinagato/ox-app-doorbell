# Asterisk 側セットアップ (参考設定)

このディレクトリはユーザー自身が管理する Asterisk への**参考設定**。app 側は
「SIP サーバ/アカウント/呼出先内線」しか知らない — 振り分け (誰を鳴らすか・夜間の扱い・
携帯へ外線発信するか) はすべて dialplan で自由に変えられる。

## 構成

```
[門口機 8001/8002] --SIP--> [Asterisk] --内線REGISTER--> [ひかり電話 HGW] --> NTT網 --> 携帯(PSTN)
                               |--> [内線電話機 201], [スマホSIP 202 (VPN)]
呼出: 門口機 → 600/601   逆呼び(モニタ): 内線 → 8001..
```

## 手順

1. HGW (PR-400/500/RX-600 系) 管理画面 →「電話設定 > 内線設定」で内線番号を 1 つ有効化
   (例: 内線 4)。ユーザー名/パスワードを控え、`pjsip.conf` の `hgw-*` に写す。
   MAC 認証や偽装は不要 — 普通の SIP REGISTER で登録できる。
2. `pjsip.conf` / `extensions.conf` を取り込み、`CHANGE_ME_*` と `MOBILE` を書き換え、
   `pjsip reload; dialplan reload`。
3. 門口機 app の管理画面で SIP サーバ IP・アカウント (8001..)・呼出先内線 (600/601) を設定。
4. 検証: `pjsip show registrations` (HGW 登録 OK)、`pjsip show endpoints` (門口機 8001 Avail)。
   門口機の呼出 → 内線 + 携帯が鳴る → 応答して双方向通話・エコー確認。

## 注意点 (機種依存)

- **HGW 内線の同時通話数は少ない** (通常 2)。複数玄関の同時呼出で携帯への外線発信が競合し得る —
  app 側は leader 仲裁で外線発信を直列化するが、dialplan 側でも Queue 等で制御可能。
- **DTMF**: PSTN→HGW レッグは inband が多い。通話中の機能コード (開錠 *1 等) が門口機まで届くかは
  実測すること。届かない場合: `[hgw] dtmf_mode=inband` のまま Asterisk の DSP 検出に任せる
  (現設定)、または rfc4733 に変えて試す。門口機側は RFC2833 受信のみ対応。
- 発信者番号通知・国際/市外プレフィックスは HGW のダイヤル規則に従う (電話機でかけるのと同じ形式)。
- HGW 再起動後の復帰は `retry_interval=60` 頼み。長期間 UNREACHABLE なら HGW 側設定を確認。
- 夜間分岐 (extensions.conf の GotoIfTime) は **Asterisk サーバの時計** で判定される。
  app 側の quiet_hours (チャイム抑制) とは独立 — 管理画面のドキュメントにも同旨を記載。

## 電話側の音声メニュー (応答・返事・応答しない)

門口機の呼出に最初に出た電話 (内線・携帯) で音声メニューが流れる。

- **1**: 来客と通話する。ここで初めて門口機側の通話が応答済みになる。
- **2**: 返事を選ぶ。クイック返信を表示順に読み上げる (1〜9、0 で戻る)。選んだ返事は門口機の画面と音声で来客に伝わり、通話履歴は「返事済み」になる。
- **9**: この電話では応答しない。ほかの室内機は鳴り続け、誰も出なければ不在着信になる。
- 何も押さないまま `MENU_TRIES` 回終わると `MENU_TIMEOUT_ACTION` を実行する。携帯の留守番電話が出ても来客とつながらないよう、既定は `decline`。

仕組み: 門口機の呼は `Progress()` の早期メディアのまま応答しない。返事・応答しないを選ぶと Asterisk が門口機へ RFC 4733 DTMF (`#21`〜`#29` / `#90`) を送り、呼を解放する。メニュー本体は `doorbell-menu.conf` (`extensions.conf` から `#include`)。

設定:

1. Mac で音声を生成する: `tools/gen_asterisk_prompts.sh --config <管理画面から書き出した設定.json>`。`deploy/asterisk/sounds/<言語>/` を PBX の `/var/lib/asterisk/sounds/<言語>/doorbell/` へコピーする。
2. スクリプトが表示する `REPLY_COUNT` を `[globals]` に書く。
3. 同じく表示される `sip.dtmf_actions` を管理画面で門口機に設定する。例:
   `{"#21":{"type":"quick_reply","reply_id":"qr_away"},"#22":{"type":"quick_reply","reply_id":"qr_no"},"#90":{"type":"decline"}}`
4. クイック返信の順番や文言を変えたら 1〜3 をやり直す。

光電話経由の携帯は DTMF が inband になることが多い。`[hgw] dtmf_mode=inband` のままなら Asterisk が検出する。門口機へ送る DTMF は Asterisk と門口機の間の RFC 4733 なので影響しない。

開発環境での確認: `deploy/dev/asterisk` で `tools/dev_ivr_test.sh` を実行すると、SIPp が門口機役、Asterisk 内のスクリプトが電話役になり、返事・通話・応答しない・留守電の 4 通りを自動で確かめる。実機の門口機では内線 620 (ソフトフォン 201 でメニュー) と 621〜624 を呼出先に設定して試せる。

## SIP ビデオ (Phase 6)

Tier A 門口機の endpoint に `allow=ulaw,h264` + `max_video_streams=1` を追記。
Asterisk はビデオを**トランスコードしない** (passthrough) — 受け側クライアント (Groundwire/Linphone) も
H.264 (baseline, packetization-mode=1) に揃えること。PSTN レッグは音声のみで共存できる。
