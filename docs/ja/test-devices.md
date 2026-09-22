# ローカルテスト端末

## iPad Air 1

2026-09-22 にユーザーが Doorbell のテスト端末として指定しました。既存の
iPad 1、iPad mini 3 とは別の端末です。

| 項目 | 確認済みの値 |
| --- | --- |
| モデル / アーキテクチャ | iPad Air 1 セルラーモデル、`iPad4,2`、arm64 |
| 端末名 / OS | `iPad (2)`、iOS 12.5.8（16H88） |
| USB UDID | `b05d91834431516e147fbc99c8f0bdc34ec38c32` |
| Wi-Fi IPv4 / SSH ポート | `10.10.38.199:44` |
| Wi-Fi MAC | `78:3a:84:a9:13:f3` |
| SSH ユーザー / 認証 | `root`、専用 Ed25519 鍵。LAN のパスワード認証は無効 |
| Mac の SSH 別名 | `doorbell-ipad-air1` |
| 登録時のアプリ | Doorbell 0.1.36、ビルド 37、`jp.ox.doorbell` |

### この Mac からの接続

```sh
ssh doorbell-ipad-air1
ssh doorbell-ipad-air1 'uname -m; ifconfig en0'
scp -O artifact.tar.gz doorbell-ipad-air1:/private/var/tmp/
```

別名は `/Users/ox/.ssh/config`、秘密鍵は
`/Users/ox/.ssh/doorbell_ipad_air1_ed25519` にあります。ホスト鍵は
`/Users/ox/.ssh/known_hosts_doorbell` の `doorbell-ipad-air1` エントリに固定しています。
秘密鍵やパスワードをプロジェクト、ログ、メモリに記録しないでください。他の Mac
には個別の公開鍵登録が必要です。この別名だけでリモートやクラウドの AI が接続
できるわけではありません。

`10.10.38.24` から `10.10.38.199:44` への LAN 接続を、公開鍵認証と厳密なホスト
鍵検証で確認しました。ホスト鍵は確認済みの USB 接続から取得しました。
保存した launchd 設定の再読み込み後も LAN 接続を確認済みです。LAN サービスは
公開鍵認証のみを提供します。

### サービスと復旧

checkra1n 付属の `/binpack/usr/sbin/dropbear` を使用します。独立したサービス
`jp.ox.doorbell.test-ssh-lan` は socket 起動で、上記 Wi-Fi IPv4 のみを待ち受けます。
設定は `/var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist`、
認証用公開鍵は `/var/root/.ssh/authorized_keys` にあります。既存のループバック
ポート 44 は USB 経由で引き続き利用できます。

IP は DHCP によるもので、ルーターで固定割り当てしていません。変更された場合は
USB から `ifconfig en0` を読み、plist の `Sockets.LANListener.SockNodeName` と
Mac の別名の `HostName` を更新し、サービスを再読み込みしてください。
USB 接続の成功だけで LAN 接続を確認済みと判断しないでください。

```sh
iproxy -u b05d91834431516e147fbc99c8f0bdc34ec38c32 2248:44
```

別のターミナルで実行します。

```sh
ssh doorbell-ipad-air1-usb 'ifconfig en0'
ssh doorbell-ipad-air1-usb 'launchctl load /var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist'
```

USB の別名は同じ鍵と固定ホスト鍵を使います。読み込み済みの設定を変更した場合は
同じ plist を `launchctl unload` してから読み込みます。今回は OS を再起動して
いません。完全な再起動では checkra1n の稼働状態が失われるため、再脱獄後に USB
からこの plist を読み直してください。`/var/root` の設定ファイルは永続化して
いますが、システムの LaunchDaemons として自動では読み込まれません。

### アプリの保守

登録時のアプリパスは
`/private/var/containers/Bundle/Application/64FD671A-D11A-464E-8D6B-C2A35A9F31F0/Doorbell.app`
です。更新前に `uicache -l jp.ox.doorbell` で現在のパスを確認してください。
アプリの home は `/var/mobile` と報告されます。起動方法：

```sh
ssh doorbell-ipad-air1 '/binpack/usr/local/bin/lsdtrip.arm64 launch jp.ox.doorbell'
```

この最小構成の脱獄環境ではルートファイルシステムが読み取り専用です。配置済み
アプリは platform-application 署名権限と LaunchServices 登録を使用しています。
付属の `uicache -p` は `/Applications` 以外を受け付けません。iPad mini 3 の
配置パスを流用しないでください。署名設定ごとに成果物を分け、配置後は端末の
バージョンとビルド番号を確認します。起動やプロセスの存在だけでは UI、ペアリング、
SIP、メディア機能の検証にはなりません。

既存のユーザー方針に従い、テスト端末のアプリ、データ、ファイルをバックアップ
しません。通常の保守ではアプリのみの再起動を優先します。
