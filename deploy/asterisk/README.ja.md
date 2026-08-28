# Asterisk 側セットアップ (参考設定)

このディレクトリはユーザー自身が管理する Asterisk への**参考設定**。app 側は
「SIP サーバ/アカウント/呼出先分機」しか知らない — 分配 (誰を鳴らすか・夜間の扱い・
携帯へ出局するか) はすべて dialplan で自由に変えられる。

## 構成

```
[門口機 8001/8002] --SIP--> [Asterisk] --内線REGISTER--> [ひかり電話 HGW] --> NTT網 --> 携帯(PSTN)
                               |--> [内線話機 201], [スマホSIP 202 (VPN)]
按鈴: 門口機 → 600/601   逆呼び(モニタ): 内線 → 8001..
```

## 手順

1. HGW (PR-400/500/RX-600 系) 管理画面 →「電話設定 > 内線設定」で内線番号を 1 つ有効化
   (例: 内線 4)。ユーザー名/パスワードを控え、`pjsip.conf` の `hgw-*` に写す。
   MAC 認証や偽装は不要 — 普通の SIP REGISTER で登録できる。
2. `pjsip.conf` / `extensions.conf` を取り込み、`CHANGE_ME_*` と `MOBILE` を書き換え、
   `pjsip reload; dialplan reload`。
3. 門口機 app の管理画面で SIP サーバ IP・アカウント (8001..)・呼出先分機 (600/601) を設定。
4. 検証: `pjsip show registrations` (HGW 登録 OK)、`pjsip show endpoints` (門口機 8001 Avail)。
   門口機の按鈴 → 内線 + 携帯が鳴る → 応答して双方向通話・エコー確認。

## 注意点 (機種依存)

- **HGW 内線の同時通話数は少ない** (通常 2)。複数玄関の同時按鈴で携帯出局が競合し得る —
  app 側は leader 仲裁で外呼を直列化するが、dialplan 側でも Queue 等で制御可能。
- **DTMF**: PSTN→HGW 腿は inband が多い。通話中の機能碼 (開錠 *1 等) が門口機まで届くかは
  実測すること。届かない場合: `[hgw] dtmf_mode=inband` のまま Asterisk の DSP 検出に任せる
  (現設定)、または rfc4733 に変えて試す。門口機側は RFC2833 受信のみ対応。
- 発信者番号通知・国際/市外プレフィックスは HGW の拨号規則に従う (話機で拨るのと同じ形式)。
- HGW 再起動後の復帰は `retry_interval=60` 頼み。長期間 UNREACHABLE なら HGW 側設定を確認。
- 夜間分岐 (extensions.conf の GotoIfTime) は **Asterisk サーバの時計** で判定される。
  app 側の quiet_hours (チャイム抑制) とは独立 — 管理画面のドキュメントにも同旨を記載。

## SIP ビデオ (Phase 6)

Tier A 門口機の endpoint に `allow=ulaw,h264` + `max_video_streams=1` を追記。
Asterisk はビデオを**転码しない** (passthrough) — 受け側クライアント (Groundwire/Linphone) も
H.264 (baseline, packetization-mode=1) に揃えること。PSTN 腿は音声のみで共存できる。
