# iOS compatibility maintainer runbook

対象は iOS 5.1/armv7 の共有 `ios-kiosk` Objective-C shell と中立な `ios-compat` tool です。
archive の `ios-legacy` に機能を追加しません。iOS 9 は共有 Swift source と別 build/signing lane を
使います。

## hardware と設置条件

初代 iPad (A1219/A1337) は内蔵マイクとスピーカを持ち、カメラを持ちません。内蔵マイクは
MiniSIP/RemoteIO の実機 commissioning 後に音声入力へ使えます。外付けマイクを必須と記載せず、
試験前に双方向通話成功を主張しません。映像送信には明示的に bind した外部 camera を使うか、
正直な no-video UI を出します。

`door_station` は software role であり屋外規格ではありません。iPad は屋外対応品ではないため、
防水、防露、温度管理、連続給電、strain relief、安全な保守切断を備えた enclosure と battery 点検が
必要です。実際の季節温湿度で認証します。

## controlled build host の準備

licensed local historical Apple SDK と compatibility libc++ を使い、SDK/toolchain binary、署名鍵、
jailbreak package、生成 archive/app を commit しません。iOS 5 armv7、iOS 9 armv7/arm64、modern、
simulator、SIP、signing profile の artifact lane を分離します。

## host と artifact gate

```sh
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_core_ios5.sh --install
ios-compat/scripts/build_app_ios5.sh
```

release は clean tree で実行します。dirty integration build は `DB_ALLOW_DIRTY=1` と固有
`DB_BUILD_ID` の両方が必要で、release 証跡にはなりません。manifest の revision、build identity、
target、architecture、minimum OS、dependency、digest を確認します。package install は
`ios-compat/scripts/build_deb.sh` を使用して rollback package も検証します。direct copy script は
保守経路であり、host access credential は repository、command、URL、文書へ埋め込みません。

## pairing と media

app の pairing flow を使います。Core が `secure_put` で `mesh.psk` を先に保存し、shell には
`{t:"paired", psk_ref:"secret:mesh.psk"}` だけを通知して永続化させます。新しい `psk_hex` は shell に
渡しません。Keychain 保存失敗時は `pairing_persistence_error` とし、client を ready にしません。

外部 camera は `ios-compat/profiles/` を基に `devices.<id>.local.camera.source_ref` と
`media_sources.<id>` を明示します。URL userinfo は禁止し、credential は `secret_ref` の背後に置きます。
seed peer を camera source とみなしません。

現 shell は HTTP(S) MJPEG direct preview、HTTP(S) snapshot polling、および RTSP/RTP interleaved TCP の
bounded baseline H.264 ingest を実装しています。host/loopback contract は SDP/
`sprop-parameter-sets`、single NAL/STAP-A/FU-A depacketization、loss 後の next-IDR recovery、Core への
Annex-B 転送を検証します。RTSP 宣言は `rtsp_ingest_pending` の degraded state から始まり、DESCRIBE と
SETUP が成功し、complete IDR を Core が実際に accept するまで `rtsp_h264_forwarding` を advertise
しません。HTTP camera 認証は request 時だけ `secret_ref` を ephemeral Basic/Bearer header に解決し、
platform TLS validation を維持して URL credential を拒否します。JPEG は local render のみで
`jpeg_core_forwarding:false` を報告し、Core/mesh camera stream にはなりません。RTSP は direct fMP4
playback URL ではありません。iPad 1 + 実 camera qualification は未完了です。

別の Core fMP4 playback route には bounded 実機 evidence があります。Android 14 door station の
`/stream.mp4` を実 iPad 1 foreground renderer が 15～16 fps、観測 latency 20～33 ms で表示し、Wi-Fi
rejoin と post-safe-mode recheck も合格しました。この結果は RTSP ingest や crash 後の unattended
foreground resume を qualification しません。[device-smoke record](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md)。

## 実機 commissioning

model、OS build、jailbreak/tool version、revision、manifest、package digest、enclosure/power を記録し、
cold boot、pairing/secure-store migration、schema-v2 着信、内蔵 mic/speaker、MiniSIP/DTMF、media/RTSP
fallback と IDR capability gate、
reply/cancel/unlock/SOS、Wi-Fi/peer/process/memory/power/rollback、長時間 thermal/memory soak を確認します。

制御された memory-warning qualification では、一時的に `debug.ui_dumps` を `true` にし、app を
foreground に保って device 上で `/usr/bin/uiopen doorbell://memorypressure` を実行します。diagnostics
無効時または background 時は URL が拒否され、許可時は UIKit の実 memory warning と同じ
release/safe-mode handler が動きます。runtime の `memory_pressure.last_source=diagnostic_url`、counter
増加、optional video 解放、bounded JPEG/audio fallback を確認し、終了後は `debug.ui_dumps=false` に
戻します。これは handler の qualification であり、OOM kill や long soak の証明ではありません。

optional root helper は `tools/helper/doorbell_keepalive.c` に実装され、非 root host test がありますが、
`DB_ALLOW_DIRTY=1 DB_BUILD_ID=<reviewed-id> ios-compat/scripts/build_helper_ios5.sh` で再現可能な armv7/iOS 5.1
staged DEB を生成できます。package は binary と無効な launchd template のみを配置し、root service を
有効化しません。確認には `SSHPASS=<commissioned-password> ios-compat/scripts/install_helper_ios5.sh --stage`
を使います。iOS 実機 qualification はまだ未完了です。明示的に opt-in する場合だけ `--enable` に
`DB_CONFIRM_ROOT_HELPER=YES` を要求し、root-owned plist、正確な UID/GID/socket permission、maintenance
lease、hang、2/5/10/30/60 秒 backoff、3 回/5 分の safe mode、rollback、soak を commissioning します。
それまでは helper 無しの復旧を維持します。

## release record

local で未 push の `ios-legacy-0.2.0-final` tag はありますが、この working tree の `ios-compat` は未
tracked で fresh clone に migration tooling が入りません。migration を tracked にし、fresh-clone/
実機 smoke/rollback/docs/tag approval gate が完了するまで `ios-legacy` を保持します。
