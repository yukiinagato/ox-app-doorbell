# Bluetooth PM2.5 センサー

室外機・室内機のホーム画面に Bluetooth LE PM2.5 センサーの値を表示できます。どのデバイスに表示するか、どのセンサーの値を表示するかは、管理者がデバイスごとに決めます。対応センサーは MOPS·VIDA PM2.5 Watchdog（型番 AD520-P001、アドバタイズ名 `测霾单品`）で、プロトコルは [CursedHardware/mops-vida-pm-watchdog](https://github.com/CursedHardware/mops-vida-pm-watchdog) に記載されています。

## 仕組み

1. **ホスト**：管理者がセンサーの近くにあるデバイスで `devices.<id>.local.air_quality.host` をオンにします。そのデバイスはサービス `0x7676` をアドバタイズする機器を短時間ずつスキャンし、見つかったものを報告します。
2. **登録**：管理者は見つかった機器を `air_sensors.<センサー ID>` として、そのデバイスを `host` に指定して登録します。ホストは GATT 接続を 1 本維持し、Nordic UART の TX 通知を受け取り、接続後に RX へ Set-RTC コマンドを 1 回書き込みます。
3. **共有**：ホストのアプリは通知をそのまま Core に渡します（`db_core_air_sensor_packet`）。Core がフレームとチェックサムを検証し、クラスタの補正済み時刻で値に時刻を付け、センサーごとの最新値を Core 所有のピア runtime セクション `air_sensors` で公開します。リンク状態が変わらない限り公開は最大 30 秒に 1 回です。値は複製設定には書き込まれません。
4. **表示**：各デバイスは `devices.<自分>.local.air_quality` = `{show, sensor}` を、そのセンサーをホストしているピアと照合し、`db_core_air_quality_json` と、結果が変わったときの `air_quality_changed` を受け取ります。

15 分より古い値、または現在生存していないホストの値は `stale` になります。レベルは Core が US EPA 2024 の PM2.5 区分で計算します：良好 ≤ 9、普通 ≤ 35、敏感な方は注意 ≤ 55、悪い ≤ 125、非常に悪い ≤ 225、それ以上は危険（µg/m³）。

接続中はセンサー内の PMS7003 が動き続けるため、350 mAh の電池はすぐに減ります。USB 給電のままにしてください。

## 設定

```jsonc
"air_sensors": {
  "s_1a2b3c4d": {
    "name": "玄関",                    // 1〜40 文字
    "host": "<node id>",              // 接続するデバイス
    "address": "AA:BB:CC:DD:EE:FF",   // 検索で得たホスト固有の識別子
    "kind": "mops_vida_pm25",         // 省略可。対応する種類はこれだけ
    "enabled": true                   // 省略可。false で接続を解放
  }
},
"devices": { "<node id>": { "local": {
  "air_quality": {
    "host": false,                    // Bluetooth センサーを検索して接続する
    "show": false,                    // ホーム画面に値を表示する
    "sensor": "s_1a2b3c4d"            // 表示するセンサー。null/省略時はプレースホルダー
  }
} } }
```

センサー ID は英数字・`_`・`-` の 1〜32 文字で、クラスタあたり最大 16 個です。`address` は Android では MAC アドレス、iOS では `CBPeripheral` の識別子なので、検出したホストでのみ意味を持ちます。別のホストに移すときは、そのホストの検索結果から登録し直してください。

## 対応状況

| アプリ | 表示（`air_quality_display_v1`） | ホスト（`ble_air_sensor_v1`） |
|---|---|---|
| Android modern / API 19 | 対応 | Bluetooth LE 搭載機で対応 |
| iOS/iPadOS 12+ / iOS 9 arm64 | 対応 | 対応 |
| iOS 5.1 互換版 | 対応 | Bluetooth LE 搭載機（iPad mini、iPad 第 3 世代以降）で対応。初代 iPad と iPad 2 は非対応 |
| Windows | 対応 | 非対応 |
| tvOS | 非対応 | 非対応 |
| Web パネル | 非対応 | 非対応 |

ホストが Bluetooth の権限を求めるのは、`host` がオンになったか、センサーが割り当てられた後だけです。管理画面のデバイスタブは、アプリが対応していないトグルについて説明を表示します。Android・iOS・iOS 5 の各アプリの設定にも同じ項目があり、iOS 5 版には登録と削除ができる専用の「PM2.5 センサー」カテゴリがあります。

## ステータスと ABI

`GET /api/status` には `air_quality.sensors`（登録済みセンサーごとの最新値とホストの生存状態）と `air_quality.hosts`（検索中ホストごとの Bluetooth 状態と検出機器）が含まれます。ネイティブ契約は `core/include/doorbell/doorbell.h` の `db_core_air_quality_json` の上にあるコメントを参照してください。

この機能は Core で実装・ホストテスト済みです。各ハードウェアでの Bluetooth 動作は実機での検証が別途必要です。[機能状況表](capability-matrix.md) を参照してください。
