[日本語] | [English](ipad1-jailbreak.en.md) | [繁體中文](ipad1-jailbreak.zh.md)

# iPad 1 compatibility node の配備

iOS 5.1.1 の越獄済み iPad 1 (A1219/A1337) を controlled node として扱う手順です。実機認証済みを
意味しません。[maintainer runbook](../../../docs/ja/ios-compat-maintainer.md) に従い、端末、artifact、
package、jailbreak 環境、試験結果を記録します。

## hardware 制限

iPad 1 は内蔵マイクとスピーカを持ち、camera を持ちません。内蔵マイクは、その端末で MiniSIP/
RemoteIO input と双方向 audio が合格した後に使用します。映像は明示した外部 MJPEG/snapshot/RTSP
camera または no-video mode を使います。bounded RTSP/RTP-over-TCP H.264 ingest と Annex-B 転送は
SDP/sprop、single NAL/STAP-A/FU-A、loss 後の next-IDR recovery を含む host/loopback contract に合格済みです。
runtime は DESCRIBE、SETUP、実 IDR accept まで degraded のままで、iPad 1 + 実 camera qualification は未完了です。

別の Core fMP4 playback path は bounded 実機 smoke に合格しました。Android 14 door station の映像を
foreground iPad 1 が 15～16 fps で表示し、Wi-Fi rejoin と post-safe-mode recheck も合格しています。
external-camera RTSP ingest と crash 後の unattended foreground video resume は未 qualification です。
`docs/evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md` を参照してください。

shell は HTTP(S) MJPEG/snapshot を direct playback します。camera credential は `secret_ref` の背後に
置き、ephemeral Basic/Bearer request header にだけ解決します。URL credential は拒否し platform TLS
validation を維持します。この JPEG path は local preview のみ (`jpeg_core_forwarding:false`) で、
Core/mesh camera feed ではありません。

屋外対応品ではありません。入口設置には防水、防露、温度管理、連続給電した enclosure と battery/
cable/thermal 点検が必要です。

## controlled install

1. jailbreak の upstream 文書に従い、固有の host access credential を設定します。共通/default credential
   を使用・記載しません。
2. controlled host で次を実行します。

   ```sh
   ios-compat/scripts/test_host.sh
   ios-compat/scripts/build_core_ios5.sh
   ios-compat/scripts/build_core_ios5.sh --install
   ios-compat/scripts/build_app_ios5.sh
   ios-compat/scripts/build_deb.sh
   ```

3. manifest、package 内容/digest、rollback package を確認し `ios-compat/scripts/install_deb.sh` で
   install します。SSH direct copy は保守用 fallback です。この fallback は app を停止する前に
   root-owned maintenance-restart marker を書き、意図した update を crash-loop failure として数えません。
4. app から pair し、Core が Keychain に `mesh.psk` を保存してから
   `{t:"paired", psk_ref:"secret:mesh.psk"}` だけを通知することと、`boot.json` の reference を確認します。
   `pairing_persistence_error` は not-ready のままにし、PSK を file に貼りません。
5. 外部 camera は `ios-compat/profiles/` の例を使い、credential は `secret_ref` に置きます。URL
   userinfo と seed peer からの camera 推定は禁止です。RTSP は IDR accept まで degraded のままか、
   packet loss 後に next-IDR recovery へ戻るかを検証します。

cold boot、targeted ring、duplicate/stale/cancel、内蔵 mic/speaker、MiniSIP/DTMF、media/RTSP/no-video、
Wi-Fi/peer/process/memory/power/rollback、kiosk maintenance、enclosure 内 long soak を合格させます。
optional root keepalive helper は実装・host test 済みで、再現可能な armv7/iOS 5.1 staged DEB も生成
できます。package は binary と無効な launchd template のみを配置し、通常の app provisioning では
`ios-compat/scripts/install_helper_ios5.sh --stage` までにして有効化しません。iPad helper qualification は
まだ未完了です。明示承認した `DB_CONFIRM_ROOT_HELPER=YES ... --enable` で root-owned plist、UID/GID/socket
permission、maintenance lease、crash/hang safe mode、rollback、soak が実機合格するまで依存しません。
隔離した trusted LAN で運用し、SSH/MiniSIP/mesh/HTTP/camera を Internet に公開しません。
