# iOS の Bonjour による発見

状態: 設計メモ、未実装。2026-09-06、サンドボックス下で動く最初の iOS ノード
（iPhone 17 / iOS 26、無料の Personal Team 署名）が家庭クラスタに参加したのを受けて作成。
これが入るまでは、ホスト + PIN による手動ペアリングがサポートされる回避策。

## 問題

mesh の発見は `239.255.71.71:47171` の UDP マルチキャストビーコン
（`core/src/mesh/udp_beacon.cpp`）。iOS 14 以降、アプリがマルチキャストを送受信するには
`com.apple.developer.networking.multicast` エンタイトルメントが必要。Apple は有料 Developer
Program のメンバーに申請ベースで付与し、Personal Team は取得できない。カーネルは黙って
パケットを捨てるため、`IP_ADD_MEMBERSHIP` は成功し、Core は失敗を一切記録しない:

```
kernel: necp_check_restricted_multicast_drop: Dropping unentitled multicast (SDK 0x1a0500, min 0xc0000)
```

そのノードでは:

- クラスタから見えず、ピアも見えないため、ペアリング画面には何も並ばない。
- ユニキャストは影響を受けない。`POST /api/pairing/join {host,pin}` は動き、`seed_peers` が
  `boot.json` に保存され、以後の mesh リンクはすべてユニキャスト TCP。失われるのは自動発見だけ。
- ブロードキャスト（`255.255.255.255`）も同じ規則で制限されるため代替にならない。

影響なし: iOS 12 シェル（規則は iOS 14 から）、エンタイトルメントを注入した脱獄シェル、
Windows、Android。

## 設計を決める制約

システム API（`NWListener`、`NWBrowser`、`NetService`）経由の Bonjour は例外扱い。
マルチキャストはアプリではなく `mDNSResponder` が行う。Core が生の mDNS ソケットを開けば
同じく捨てられる。したがって:

- iOS では mDNS トラフィックをプラットフォーム API に通し、
- 他のすべてのプラットフォームも mDNS を話せる必要がある。さもないと iPhone は誰にも届かず、
  誰の声も聞こえない。

## 設計

1. **発見セット。** `IDiscovery`（`core/src/mesh/transport.h`）は既にビーコンを抽象化している。
   `start/announce/stop/setPairAnnounce/setPairFound/setPsk` を複数バックエンドへ扇形に配り、
   コールバックを node id で重複排除して合流させる `DiscoverySet : IDiscovery` を追加する。
   マルチキャストビーコンは残し、遮断される環境では単に何も寄与しない。
2. **ビーコン符号化の共有。** HELLO と pair-announce の符号化/検証を `UdpBeacon` から
   `mesh/beacon_packet.{h,cpp}` へ移す。Bonjour の TXT レコードは同じ MAC 付き JSON を運ぶので、
   クラスタ所属の安全性は変わらず、テストも一箇所で済む。
3. **サービスの形。** 種別 `_doorbell._udp`、インスタンス名 = node id、ポート = mesh の待受ポート。
   TXT: `v=1` と、base64 化したパケットを `p0`、`p1`… に分割（TXT 文字列 1 本は 255 バイト上限。
   HELLO は約 150 バイト、pair-announce は 2 分割が必要な場合あり）。ピアのアドレスは解決した
   SRV/A レコードから取り、パケット内の `addr` も MAC で検証する。
4. **プラットフォーム SPI。** `db_platform_v2` の末尾に追加（フィールドは追加のみ）:
   `int (*discovery_advertise)(user, service_type, instance, txt_json)`、`txt_json` が空なら
   広告停止。`int (*discovery_browse)(user, service_type, on)`。シェルが解決結果
   `{"instance","addrs":[…],"port","txt":{…}}` を返す `db_core_discovery_result(core, json)` を追加。
   Core は `PlatformDiscovery : IDiscovery` で包む。フックを `NULL` のままにしたシェルには
   Bonjour バックエンドは付かない。
5. **iOS シェル。** `NWListener(service:)` で広告、`NWBrowser` で探索と解決、いずれも上記フックへ。
   `Info.plist` に `NSBonjourServices = ["_doorbell._udp"]` を追加（iOS 14+ ではこれがないと
   探索が拒否される）。ローカルネットワーク権限は引き続き必要で、初回利用時にシステムが求める。
6. **それ以外の全員。** Core に最小限の mDNS レスポンダ/ブラウザ（`mesh/mdns.{h,cpp}`）:
   上記サービスの PTR、SRV、TXT、A レコード、3 回の自発的アナウンス後は PTR クエリに応答、
   探索中は数秒ごとに PTR クエリ。`socket_compat.h` のマルチキャスト補助を再利用する。
   Windows、Android、Linux ホスト、脱獄 iPad はシェル側の作業なしに Core 経由で得る。
7. **設定。** `discovery.mdns = on|off`、既定 `on`。トラフィックはノードあたり
   アナウンス間隔ごとに数パケットで、ビーコンと同程度。

## セキュリティ

HELLO はクラスタ PSK による鍵付きのまま。pair-announce は設計上これまで通り非認証で、
現在のビーコンと同一。TXT レコードは LAN 上の誰でも読めるが、それはマルチキャストビーコンが
既に持つ露出と同じ。TXT に秘密が載ることはない。

## 展開

1. Core: 符号化の切り出し、`DiscoverySet`、`PlatformDiscovery`、SPI フィールド、
   インメモリテスト。iOS シェルのバックエンド。Mac 上のホストノードを相手に検証。
2. Core の mDNS バックエンド。家庭 LAN で Windows ↔ iPhone を検証。
3. Android と kiosk は Core 経由で自動的に得る。実機で認定。

却下した代替案: ユニキャストのサブネット走査（遅い、うるさい、大きなネットワークで破綻）、
ブロードキャスト（同じ制限）、マルチキャストエンタイトルメント頼み（有料プログラムと Apple の
承認が必要。App Store 向けビルドでは申請する価値があるが、テストビルドには効かない）。

## 未決事項

- 未ペアリング時にも広告するか。ビーコンは広告する（pair-announce）ので同じにする。
- アプリがサスペンドされると Bonjour も止まる。シェルが持つ他のソケットと同じで、
  キープアライブの方針は変わらない。
- プライベート LAN のサービスなので IANA へのサービス種別登録は任意。
