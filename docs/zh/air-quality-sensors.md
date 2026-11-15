# 蓝牙 PM2.5 传感器

门口机或室内机可以在主屏幕上显示蓝牙低功耗 PM2.5 传感器的读数。是否显示、显示哪个传感器，由管理员按设备决定。支持的传感器是 MOPS·VIDA PM2.5 Watchdog（忻风随身 PM2.5 检测仪，型号 AD520-P001，广播名 `测霾单品`），协议见 [CursedHardware/mops-vida-pm-watchdog](https://github.com/CursedHardware/mops-vida-pm-watchdog)。

## 工作方式

1. **宿主**：管理员为传感器附近的设备打开 `devices.<id>.local.air_quality.host`。该设备分段短时扫描广播服务 `0x7676` 的外设，并报告扫描结果。
2. **绑定**：管理员把发现的外设登记为 `air_sensors.<传感器 ID>`，并以该设备为 `host`。宿主与它保持一条 GATT 连接：订阅 Nordic UART TX 特征的通知，连接后向 RX 写入一次 Set-RTC 命令。
3. **传播**：宿主应用把每条通知原样交给 Core（`db_core_air_sensor_packet`）。Core 校验帧头与校验和，用集群校正后的时钟给读数打时间戳，并在 Core 所有的对等 runtime 段 `air_sensors` 中发布每个传感器的最新值；除非连接状态变化，最多每 30 秒发布一次。读数从不写入复制配置。
4. **显示**：每台设备根据 `devices.<自身>.local.air_quality` = `{show, sensor}`，从宿主该传感器的对等节点取值，得到 `db_core_air_quality_json`，结果变化时收到 `air_quality_changed`。

超过 15 分钟的读数，或宿主当前不在线时，状态为 `stale`。等级由 Core 按 US EPA 2024 PM2.5 分档计算：优 ≤ 9、良 ≤ 35、敏感人群注意 ≤ 55、不健康 ≤ 125、非常不健康 ≤ 225、以上为危险（µg/m³）。

连接期间传感器内的 PMS7003 持续运行，350 mAh 电池会很快耗尽，请保持 USB 供电。

## 配置

```jsonc
"air_sensors": {
  "s_1a2b3c4d": {
    "name": "玄关",                    // 1–40 个字符
    "host": "<node id>",              // 负责连接的设备
    "address": "AA:BB:CC:DD:EE:FF",   // 扫描得到的宿主本地标识
    "kind": "mops_vida_pm25",         // 可省略；目前唯一支持的类型
    "enabled": true                   // 可省略；false 释放连接
  }
},
"devices": { "<node id>": { "local": {
  "air_quality": {
    "host": false,                    // 搜索并连接蓝牙传感器
    "show": false,                    // 在主屏幕显示读数
    "sensor": "s_1a2b3c4d"            // 显示哪个传感器；null 或省略时显示占位
  }
} } }
```

传感器 ID 为 1–32 个字母、数字、`_` 或 `-`，每个集群最多 16 个。`address` 在 Android 上是 MAC 地址，在 iOS 上是 `CBPeripheral` 标识符，因此只对发现它的宿主有意义。要换宿主，请从新宿主的扫描结果重新登记。

## 平台支持

| 应用 | 显示（`air_quality_display_v1`） | 宿主（`ble_air_sensor_v1`） |
|---|---|---|
| Android modern / API 19 | 支持 | 设备有低功耗蓝牙时支持 |
| iOS/iPadOS 12+ / iOS 9 arm64 | 支持 | 支持 |
| iOS 5.1 兼容版 | 支持 | 有低功耗蓝牙的机型支持（iPad mini、iPad 第 3 代及以后）；初代 iPad 与 iPad 2 不支持 |
| Windows | 支持 | 不支持 |
| tvOS | 不支持 | 不支持 |
| Web 面板 | 不支持 | 不支持 |

只有在为设备打开 `host` 或给它绑定传感器之后，宿主才会请求蓝牙权限。管理页的设备标签会对设备应用不支持的开关给出说明。Android、iOS 与 iOS 5 应用的设置里也有相同的项目；iOS 5 版另有可登记和删除传感器的专用「PM2.5 传感器」分类。

## 状态与 ABI

`GET /api/status` 包含 `air_quality.sensors`（每个已登记传感器的最新读数与宿主是否在线）和 `air_quality.hosts`（每个扫描中宿主的蓝牙状态与发现的外设）。原生接口契约见 `core/include/doorbell/doorbell.h` 中 `db_core_air_quality_json` 上方的注释。

该功能已在 Core 中实现并通过主机测试。各硬件上的蓝牙行为仍需真机验证，见[能力矩阵](capability-matrix.md)。
