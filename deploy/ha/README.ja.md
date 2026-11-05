# Home Assistant 連携 (go2rtc / MQTT / HomeKit)

このディレクトリの配布物:

- `go2rtc.yaml` — 門口機のライブ映像を HA へ取り込む go2rtc のストリーム定義例
- `configuration-snippets.yaml` — generic camera / HomeKit Bridge / 必須の自動化の断片

## MQTT で登録されるエンティティ

`integrations.mqtt.host` を設定すると、`mqtt_bridge` のリーダー端末が MQTT Discovery で
次のエンティティを登録する。entity_id は ASCII の object_id から決まる (例は門 `d_front`)。
名前は `integrations.ha.language` (未設定ならUI の第一言語) の ja / en / zh で付く。

| エンティティ | 状態 topic | 内容 |
|---|---|---|
| `event.doorbell_d_front` | `doorbell/d_front/event` | event_type `press` / `answered` / `missed` / `replied` / `cancelled`。press は purpose・visitor_lang・call_id、replied は text を持つ |
| `sensor.doorbell_d_front_call_state` | `doorbell/d_front/call_state` | `idle` / `ringing` / `in_call` (retain) |
| `sensor.doorbell_d_front_last_call` | `doorbell/d_front/last_call` (+ `/attrs`) | 直近に終わった呼び出しの結果 (`none` / `answered` / `missed` / `replied` / `cancelled`)。属性: time, ts, purpose, visitor_lang, call_id, answered_by, duration_s, reply_text, seen, image_last_updated |
| `sensor.doorbell_d_front_missed_calls` | `doorbell/d_front/missed` | この門の未確認の不在着信数。端末ローカルの既読ウォーターマークと同じ数え方 |
| `image.doorbell_d_front_snapshot` | `doorbell/d_front/snapshot` | 按鈴の瞬間の JPEG (200 KiB 以下のみ、retain しない)。HTTP 認証に依存しない |
| `select.doorbell_d_front_quick_reply` | command: `doorbell/d_front/reply/select` | クイック返信の選択肢 (quick_replies のラベル)。進行中の呼び出しにだけ送られる |
| `binary_sensor.doorbell_d_front_motion` | `doorbell/d_front/motion` | 動体検知 (30 秒で off) |
| `sensor.doorbell_d_front_visitor_lang` | `doorbell/d_front/attrs` | 訪客が選んだ言語。属性に image_last_updated |
| `binary_sensor.doorbell_emergency` | `doorbell/emergency` (+ `/attrs`) | SOS。属性: active, source, source_name, door, via, triggered_at(_iso), cleared_at(_iso), cleared_via |
| `button.doorbell_sos_clear` / `button.doorbell_sos_trigger` | command: `doorbell/emergency/set` (`OFF` / `ON`) | `integrations.ha.allow_sos_control: true` のときだけ登録 |
| `text.doorbell_notice` | `doorbell/notice`, command: `doorbell/notice/set` | 全体のお知らせ。空文字で解除。`integrations.ha.allow_notice_control: true` のときだけ登録 |
| `binary_sensor.doorbell_node_<id8>` / `binary_sensor.doorbell_bridge_online` | — | 端末とブリッジの死活 |

従来の `doorbell/<door>/reply/set` (reply_id か自由文、または call_id/stage_revision 付き JSON)
もそのまま使える。

### MQTT コマンドの認可

MQTT で届くコマンドは**ブローカーの認証が境界**になる。`doorbell/` 以下へ publish できる
クライアントは誰でもクイック返信を送れる。クラスタの状態を変える SOS 発報/解除と
お知らせは既定で無効で、管理者が上記 2 つのフラグを明示的に true にしたときだけ受け付ける。
ブローカーには必ずユーザー認証と ACL を設定し、門口機ブリッジ以外が `doorbell/#` に
publish できないようにすること。retain 付きで届いたコマンドは再接続時の再実行を防ぐため
無視する。

## 映像ソースの選び方 (codec 設定とトランスコードの関係)

子機ごとの設定 `devices.<id>.local.camera.codec` (管理画面 → デバイス → 映像コーデック)
でライブ映像の出方が変わる:

| codec | 子機が出すストリーム | go2rtc ソース例 | HA 側トランスコード |
|---|---|---|---|
| `h264` / `auto` (対応機) | `/stream.mp4` (fMP4, 子機 HW エンコード) | `ffmpeg:https://<user>:<pass>@<子機>:47443/stream.mp4#video=copy` | **不要** (copy) |
| `mjpeg` / `auto` (ハードウェアエンコード非対応の旧機) | `/stream.mjpeg` (MJPEG) | `ffmpeg:https://<user>:<pass>@<子機>:47443/stream.mjpeg#video=h264#hardware` | 必要 |

- **セキュリティ v3 の連携用資格情報が必要**: v3 から映像と静止画は認証必須で、LAN 側は
  HTTPS (47443) でだけ配信される (47180 の平文 HTTP は LAN からはリダイレクトのみ)。
  管理画面の「パネル」で「状態の表示」だけを許可した資格情報を発行し、Basic 認証の
  パスワードとして使う (ユーザー名は任意)。URL に `?k=<token>` を付ける旧方式は使えない。
- 門口機の証明書は自己署名。ffmpeg は既定で証明書を検証しないため通信は暗号化されるが、
  相手が本物の門口機かは確かめない。HA ホストは信頼できる LAN に置くこと。
  管理画面に表示される証明書指紋で確認できる。
- **codec=h264 のときは HA 側のトランスコードは不要**: 子機 (Android MediaCodec / Windows
  Media Foundation) が H.264 を作り、core が fMP4 に箱詰めして配るだけなので、
  go2rtc は `#video=copy` でコンテナを詰め替えるだけになる (HA ホストの CPU ほぼゼロ・
  720p でも滑らか)。
- go2rtc の `ffmpeg:` ソースを使う (http 直接源は fMP4 ライブの扱いが版によって
  異なるため、`ffmpeg:...#video=copy` の形が確実)。
- `/stream.mp4` は**購読者が付いてから**子機のエンコーダが起動する省電力設計
  (無視聴時はエンコードゼロ)。初回は起動 + 初期化で数秒かかるため、HomeKit 通知の
  初動を最速にしたい主玄関は常駐消費を推奨 (go2rtc の consumer を常設)。
- `auto` は「ハードウェアエンコード対応なら h264、なければ mjpeg」— ハードウェアエンコード非対応の子機の `/stream.mp4` は
  503 を返すので、その子機は mjpeg の行で書くこと。

按鈴時の静止画は MQTT の `image.doorbell_<door>_snapshot` を使うのが簡単 (認証不要)。
generic camera で `/snapshot.jpg` を取る場合と HomeKit の設定は `configuration-snippets.yaml`
を参照。端末間通話画面 (室内機⇔門口機) は HA 連携とは独立。
