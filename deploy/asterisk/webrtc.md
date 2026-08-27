# ブラウザ通話 (WebRTC) — Asterisk 側設定 (**任意機能**)

**位置づけ**: 室内機アプリ (Windows/Android/iOS/TV) ⇔ 門口機の対講は Asterisk を
経由しない直接 SIP (UDP 47190) で行う — PBX が落ちても対講は生きる。
この文書は「**ブラウザ (網頁面板) から通話したい場合だけ**」必要な追加設定。
ブラウザは SIP/UDP を直接話せないため WebRTC ゲートウェイとして Asterisk を使う。
網頁通話を使わないならこの設定は不要。

網頁面板の双方向音声は「ブラウザ = Asterisk の内線」方式 (JsSIP + WebSocket)。
門口機側は変更不要 — ブラウザから門口機の内線 (8001 等) へ普通に発呼するだけ。

## 1. 重要な前提: セキュアコンテキスト

**ブラウザの getUserMedia (マイク) は HTTPS ページでしか動かない** (localhost を除く)。
子機の管理/パネルページは平文 HTTP なので、次のどちらかが必要:

- **推奨: HA ホストで Caddy 等のリバースプロキシ + 内部 CA**
  `https://doorbell.home` → 子機 47180 へプロキシ、`wss://` → Asterisk 8089。
  各端末に内部 CA を一度インストール。
- **簡易: ブラウザ毎の例外設定** — Chrome:
  `chrome://flags/#unsafely-treat-insecure-origin-as-secure` に `http://<子機IP>:47180` を追加。
  家庭内の決まった端末だけなら現実的。

## 2. http.conf (Asterisk 内蔵 HTTP — WebSocket 用)

```ini
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
; wss を使う場合 (Caddy で終端するなら不要):
;tlsenable=yes
;tlsbindaddr=0.0.0.0:8089
;tlscertfile=/etc/asterisk/keys/asterisk.pem
```

## 3. pjsip.conf 追記 (ws transport + ブラウザ内線テンプレート)

```ini
[transport-ws]
type=transport
protocol=ws                 ; Caddy/wss 終端なら ws のまま; 直 wss なら protocol=wss
bind=0.0.0.0

[browser](!)
type=endpoint
context=from-internal
disallow=all
allow=opus,ulaw             ; ブラウザは opus が既定。無ければ ulaw
webrtc=yes                  ; use_avpf/ice_support/dtls 一式の短縮 (Asterisk 15+)
dtls_auto_generate_cert=yes ; 自己署名 DTLS 証明書を自動生成
dtmf_mode=rfc4733

;---- 網頁面板用内線 (端末台数ぶん増やす) ----
[260](browser)
auth=260
aors=260
callerid="Web Panel" <260>
[260](door-auth)
username=260
password=CHANGE_ME_260
[260](door-aor)
max_contacts=3              ; 複数ブラウザ同時ログイン許容
```

- `webrtc=yes` は Asterisk 15+ (20 は OK)。opus は codec_opus モジュール
  (標準バンドル、`module show like opus` で確認)。ブラウザ⇔門口機は
  opus⇔ulaw を Asterisk が転码する (サーバ負担、通話 1-2 本なら無視できる)。
- extensions.conf は変更不要 — 260 は from-internal で `8001` (門口機直呼) や
  `0…` (光電話出局) をそのまま拨れる。

## 4. 動作確認

```
asterisk -rx "pjsip show transports"     ; ws が居る
asterisk -rx "pjsip show endpoint 260"
```
ブラウザ側 (パネルの通話ページ) は JsSIP で
`wss://<host>:8089/ws` (または Caddy 経由 `wss://doorbell.home/asterisk/ws`) に REGISTER。

## 5. ビデオについて

- ブラウザ←門口機の映像は WebRTC ではなく MJPEG (`/stream.mjpeg`) を並置表示 —
  Asterisk のビデオ設定は不要。
- ブラウザ→門口機 (双方向ビデオ時) は getUserMedia → canvas → JPEG を門口機の
  `/call-frame` へ POST する方式 (app 側実装)。WebRTC ビデオ協商はしない。
