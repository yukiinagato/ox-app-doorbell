# Home Assistant 連携 (go2rtc / MQTT / HomeKit)

このディレクトリの配布物:

- `go2rtc.yaml` — 門口機のライブ映像を HA へ取り込む go2rtc のストリーム定義例
- `configuration-snippets.yaml` — generic camera / HomeKit Bridge / 必配自動化の断片

## 映像ソースの選び方 (codec 設定と転码の関係 — Phase 6a)

子機ごとの設定 `devices.<id>.local.camera.codec` (管理画面 → デバイス → 映像コーデック)
でライブ映像の出方が変わる:

| codec | 子機が出す流 | go2rtc ソース例 | HA 側転码 |
|---|---|---|---|
| `h264` / `auto` (対応機) | `/stream.mp4` (fMP4, 子機 HW エンコード) | `ffmpeg:http://<子機>:47180/stream.mp4#video=copy` | **不要** (copy) |
| `mjpeg` / `auto` (硬編なし旧機) | `/stream.mjpeg` (MJPEG) | `ffmpeg:http://<子機>:47180/stream.mjpeg#video=h264#hardware` | 必要 (従来どおり) |

- **codec=h264 のときは HA 側の転码は不要**: 子機 (Android MediaCodec / Windows
  Media Foundation) が H.264 を作り、core が fMP4 に箱詰めして配るだけなので、
  go2rtc は `#video=copy` でコンテナを詰め替えるだけになる (HA 主機の CPU ほぼゼロ・
  720p でも滑らか)。
- go2rtc の `ffmpeg:` ソースを使う (http 直接源は fMP4 ライブの扱いが版によって
  異なるため、`ffmpeg:...#video=copy` の形が確実)。
- `/stream.mp4` は**購読者が付いてから**子機のエンコーダが起動する省電力設計
  (無視聴時はエンコードゼロ)。初回は起動 + 初期化で数秒かかるため、HomeKit 通知の
  初動を最速にしたい主玄関は常駐消費を推奨 (go2rtc の consumer を常設)。
- `auto` は「硬編があれば h264、なければ mjpeg」— 硬編の無い子機の `/stream.mp4` は
  503 を返すので、その子機は mjpeg の行で書くこと。
- 認証 (panel token) を有効にした場合は URL に `?k=<token>` を付ける
  (`/stream.mp4` も `/stream.mjpeg` と同じ公開/トークン規則)。

静止画 (`/snapshot.jpg`) と MQTT/HomeKit の設定は `configuration-snippets.yaml` を参照。
站間通話画面 (室内機⇔門口機) は本 Phase では従来どおり MJPEG のまま (H.264 硬解は
Phase 6b 予定) — HA 連携とは独立。
