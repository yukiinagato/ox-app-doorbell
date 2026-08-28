# iPad 1 (A1219, iOS 5.1.1) を門铃ノードにする

初代 iPad (2010, A4, 256MB, **カメラ・マイク無し**) を、越獄 + 自前ビルドの
ネイティブ app で**門铃メッシュの一等ノード**にする手順。完全な C++17 コア
(doorbell-core) が armv7/iOS5.1 で動く — これは本当に動く (A0/B で実証済み)。

## この端末でできること / できないこと (ハードウェア上限)

| | 可否 | 理由 |
|---|---|---|
| 門口のライブ映像を見る | ✅ | MJPEG 受信・A4 でデコード |
| 門口の音声を聞く | ✅ | ミニ SIP で門口機へ直接呼、スピーカー再生 |
| クイック返信・開錠 (画面操作) | ✅ | C ABI + SIP DTMF `*1` |
| メッシュノードとして設定同期・イベント | ✅ | core 全載せ |
| **自分の声を送る (対講)** | ⚠️ 外付けマイク必須 | 内蔵マイク無し。イヤホン端子(TRRS)/dock マイクを挿せば可 |
| **自分の映像を送る** | ❌ 不可 | カメラが物理的に無い |

## 0. 前提 (母艦 Mac 側)

ビルド成果物と工具链はリポジトリの `tools/` `ios-legacy/` に用意済み:
- `tools/sdk/iPhoneOS7.1.sdk` — Xcode 5.1 DMG から抽出 (sysroot。gitignore)
- `tools/toolchain/ios5-armv7/` — 自前ビルドの現代 libc++/libc++abi/libunwind (`tools/build_libcxx_ios5.sh` で再生成)
- `ios-legacy/lib/libdoorbell_all.a` — armv7/iOS5.1 版 core (`ios-legacy/scripts/build_core_ios5.sh`)
- `ldid` (`brew install ldid`)

SDK を作り直す場合: Xcode 5.1 (または 4.x) の DMG を `hdiutil attach` し、
`.../iPhoneOS.platform/Developer/SDKs/iPhoneOS7.1.sdk` を `tools/sdk/` へコピー。

## 1. iPad 1 を越獄 (untethered)

**Legacy iOS Kit** (LukeZGD) — 現代 macOS で動く、iPad 1 対応の untethered 越獄ツール。
1. `git clone https://github.com/LukeZGD/Legacy-iOS-Kit && cd Legacy-iOS-Kit`
2. iPad 1 を USB 接続 → `./restore.sh` → メニューから **Jailbreak (untethered)**。
   (必要なら先に 5.1.1 へ復元 — メニューの Restore/Downgrade。NVRAM クリア手順は
   Kit の wiki 参照)
3. 完了後 iPad に **Cydia** が入る。
- 代替: Absinthe 2.0 / redsn0w 0.9.12b1 (当時の untethered ツール、動く母艦があれば)。

## 2. 越獄後の下ごしらえ

1. Cydia で **OpenSSH** を入れる (SSH で app を送るため)。
2. **AppSync Unified** を入れる (ldid 伪署名の app を許可)。
   - ソース `https://cydia.akemi.ai/` を追加 → AppSync Unified をインストール。
   - ソースが落ちている場合は Kit の App Management 経由 or .deb を `dpkg -i` で手動導入。
3. iPad の IP を控える (設定 > Wi-Fi)。既定 SSH: `root@<ip>` / パスワード `alpine`
   (**必ず `passwd` で変更する**)。

## 3. app をビルドして送る (母艦 Mac)

```bash
cd app-doorbell
bash ios-legacy/scripts/build_core_ios5.sh   # core .a (初回/更新時)
bash ios-legacy/scripts/build_app.sh          # Doorbell.app を生成 + ldid 伪署名
# 送る (どちらか)
scp -r ios-legacy/build/Doorbell.app root@<ipad-ip>:/Applications/
ssh root@<ipad-ip> "uicache"                  # ホーム画面に反映
#   ── または Legacy iOS Kit の Install IPA を使う
```

## 4. iPad 側の初期設定

1. ホーム画面の「ドアホン」を起動。
2. 初回設定 (アプリ内 or `/var/mobile/.../boot.plist`):
   - `role` = `indoor_panel`
   - `seed_peers` = 既存ノードの `IP:47172` を 1 つ以上 (同一 L2 なら 1 つで全網に繋がる)
   - `psk_hex` = クラスタ PSK (管理画面「デバイスを追加」で発行された値、または既存と同じ)
   - 門口機の direct SIP 目標 = `<門口機IP>:47190`
   - 外付けマイクの有無
3. メッシュに合流すると設定 (テーマ・クイック返信・用件・言語) が自動同期される。

## 5. 外付けマイク (対講したい場合のみ)

内蔵マイクが無いので、**話す**には外部マイクが要る:
- イヤホン端子: マイク付きヘッドセット (TRRS)。iPad 1 の 3.5mm がヘッドセットマイクを
  受けるかは個体/アクセサリ依存 — 認識すれば RemoteIO が入力を拾う。
- dock コネクタ: マイク対応 dock アクセサリ。
マイクが無い/認識しない場合は「聞く専用」(門口の声は聞こえる、こちらの声は無音) で動作する。

## 6. 動作確認

- 押鈴 → iPad が全画面で門口映像を表示し、門口の音声が聞こえる。
- クイック返信ボタン → 門口機で大字表示＋読み上げ。
- 開錠ボタン → 門口機経由で HA の錠が開く (DTMF `*1`)。
- LAN ケーブル/Wi-Fi を切る → 数十秒でメッシュから離脱、復帰で再合流。
- 外付けマイク有り: こちらの声が門口スピーカーから出る。

## 注意

- 越獄端末はこの門铃専用・LAN 内運用を前提 (外部公開しない)。SSH パスワードは必ず変更。
- 常時給電・常時点灯 (app が idleTimer を無効化)。電池の膨張に注意 (可能なら電池を外し直結給電)。
- OS 更新はしない (5.1.1 固定)。app 更新は §3 を再実行。
