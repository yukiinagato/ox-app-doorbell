# Bluetooth PM2.5 sensors

A door station or indoor panel can show the reading of a Bluetooth LE PM2.5 sensor on its home
screen. Whether a device shows a reading, and which sensor's, is an administrator decision made
per device. The supported sensor is the MOPS·VIDA PM2.5 Watchdog (model AD520-P001, advertised as
`测霾单品`); its protocol is documented by
[CursedHardware/mops-vida-pm-watchdog](https://github.com/CursedHardware/mops-vida-pm-watchdog).

## How it works

1. **Host.** An administrator turns on `devices.<id>.local.air_quality.host` for a device near the
   sensor. That device scans in short bursts for peripherals advertising service `0x7676` and
   reports what it finds.
2. **Bind.** The administrator registers a found peripheral as `air_sensors.<sensor id>` with that
   device as its `host`. The host keeps one GATT link to it: notifications on the Nordic UART TX
   characteristic, and one Set-RTC command written to RX after connecting.
3. **Gossip.** The host shell passes each notification unchanged to Core
   (`db_core_air_sensor_packet`). Core validates the frame and checksum, stamps the reading with
   the cluster's corrected wall clock, and publishes the latest value per sensor in the Core-owned
   `air_sensors` section of its peer runtime, at most once every 30 seconds unless the link state
   changes. Readings are never written to the replicated configuration.
4. **Display.** Each device resolves `devices.<self>.local.air_quality` = `{show, sensor}` against
   whichever peer hosts that sensor and receives `db_core_air_quality_json` plus an
   `air_quality_changed` hint when the result changes.

A reading older than fifteen minutes, or from a host that is not currently alive, is reported as
`stale`. The level is computed in Core using the US EPA 2024 PM2.5 breakpoints: good ≤ 9,
moderate ≤ 35, sensitive groups ≤ 55, unhealthy ≤ 125, very unhealthy ≤ 225, hazardous above
(µg/m³).

The sensor's PMS7003 runs continuously while connected, which drains its 350 mAh battery quickly.
Keep it on USB power.

## Configuration

```jsonc
"air_sensors": {
  "s_1a2b3c4d": {
    "name": "Entrance",               // 1–40 characters
    "host": "<node id>",              // the device that connects to it
    "address": "AA:BB:CC:DD:EE:FF",   // host-local identifier from discovery
    "kind": "mops_vida_pm25",         // optional; the only supported kind
    "enabled": true                   // optional; false releases the link
  }
},
"devices": { "<node id>": { "local": {
  "air_quality": {
    "host": false,                    // search for and connect Bluetooth sensors
    "show": false,                    // show a reading on the home screen
    "sensor": "s_1a2b3c4d"            // which sensor; null or absent shows a placeholder
  }
} } }
```

Sensor IDs are 1–32 characters of letters, digits, `_` or `-`; a cluster holds at most 16 sensors.
`address` is a MAC address on Android and a `CBPeripheral` identifier on iOS, so it is meaningful
only on the host that discovered it. Moving a sensor to another host means registering it again
from that host's discovery list.

## Platform support

| Shell | Display (`air_quality_display_v1`) | Host (`ble_air_sensor_v1`) |
|---|---|---|
| Android modern and API 19 | Yes | Yes, when the device has Bluetooth LE |
| iOS/iPadOS 12+ and iOS 9 arm64 | Yes | Yes |
| iOS 5.1 compatibility | Yes | Yes on Bluetooth LE hardware (iPad mini, iPad 3 and later); not the first-generation iPad or iPad 2 |
| Windows | Yes | No |
| tvOS | No | No |
| Web panels | No | No |

A host requests Bluetooth permission only after `host` is turned on for it or a sensor is bound to
it. The admin Devices tab explains a toggle that a device's app does not advertise. Android, iOS, and iOS 5 devices also have the same controls in their own settings; the iOS 5 app has a dedicated "PM2.5 sensors" category that registers and removes sensors.

## Status and ABI

`GET /api/status` includes `air_quality.sensors` (each registered sensor with its latest reading
and whether its host is alive) and `air_quality.hosts` (each scanning host's Bluetooth state and
discovered peripherals). The native contract is documented above `db_core_air_quality_json` in
`core/include/doorbell/doorbell.h`.

This feature is implemented and host-tested in Core. Bluetooth behaviour on each hardware model
still requires device qualification; see the [capability matrix](capability-matrix.md).
