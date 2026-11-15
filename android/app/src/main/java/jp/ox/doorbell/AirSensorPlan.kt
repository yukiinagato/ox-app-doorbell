// What Core asks this device to do over Bluetooth for air sensors (db_core_air_sensor_plan_json),
// plus the pure helpers the Bluetooth host uses: link diffing, advertisement matching, the
// report document, and the runtime permissions each API level needs.
package jp.ox.doorbell

import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal data class AirSensorTarget(val id: String, val address: String, val kind: String)

internal data class AirSensorPlan(
    val host: Boolean,
    val scan: Boolean,
    val sensors: List<AirSensorTarget>,
    val advertisedService: String,
    val advertisedName: String,
    val service: UUID,
    val rx: UUID,
    val tx: UUID,
) {
    /** The advertised 16-bit service as a full Bluetooth base UUID, or null when malformed. */
    val advertisedServiceUuid: UUID? get() = AirSensorPlans.uuid16(advertisedService)

    val advertisedService16: Int get() = advertisedService.toIntOrNull(16) ?: -1

    companion object {
        val NONE = AirSensorPlan(
            host = false, scan = false, sensors = emptyList(),
            advertisedService = AirSensorPlans.DEFAULT_ADVERTISED_SERVICE,
            advertisedName = AirSensorPlans.DEFAULT_ADVERTISED_NAME,
            service = AirSensorPlans.DEFAULT_SERVICE,
            rx = AirSensorPlans.DEFAULT_RX,
            tx = AirSensorPlans.DEFAULT_TX,
        )
    }
}

internal data class AirLinkChanges(val close: Set<String>, val open: List<AirSensorTarget>)

/** One peripheral seen during a scan burst. */
internal data class AirDiscovered(val address: String, val name: String, val rssi: Int)

/** The 16-bit service UUIDs and local name carried by one raw advertisement. */
internal data class AdvertisingFields(val services16: Set<Int>, val name: String)

internal object AirSensorPlans {
    const val DEFAULT_ADVERTISED_SERVICE = "7676"
    const val DEFAULT_ADVERTISED_NAME = "测霾单品"
    val DEFAULT_SERVICE: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    val DEFAULT_RX: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    val DEFAULT_TX: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private const val SUPPORTED_KIND = "mops_vida_pm25"

    fun parse(document: JSONObject?): AirSensorPlan {
        if (document == null) return AirSensorPlan.NONE
        val ble = document.optJSONObject("mops_vida_pm25")
        val sensors = ArrayList<AirSensorTarget>()
        val list = document.optJSONArray("sensors")
        if (list != null) for (i in 0 until list.length()) {
            val s = list.optJSONObject(i) ?: continue
            val id = s.optString("id")
            val address = s.optString("address").trim()
            val kind = s.optString("kind").ifEmpty { SUPPORTED_KIND }
            if (id.isEmpty() || kind != SUPPORTED_KIND) continue
            sensors.add(AirSensorTarget(id, address.uppercase(Locale.US), kind))
        }
        return AirSensorPlan(
            host = document.optBoolean("host", false),
            scan = document.optBoolean("scan", false),
            sensors = sensors,
            advertisedService = ble?.optString("advertised_service").orEmpty()
                .ifEmpty { DEFAULT_ADVERTISED_SERVICE },
            advertisedName = ble?.optString("advertised_name").orEmpty()
                .ifEmpty { DEFAULT_ADVERTISED_NAME },
            service = uuid(ble?.optString("service"), DEFAULT_SERVICE),
            rx = uuid(ble?.optString("rx"), DEFAULT_RX),
            tx = uuid(ble?.optString("tx"), DEFAULT_TX),
        )
    }

    private fun uuid(value: String?, fallback: UUID): UUID = try {
        if (value.isNullOrEmpty()) fallback else UUID.fromString(value)
    } catch (_: IllegalArgumentException) {
        fallback
    }

    fun uuid16(hex: String): UUID? {
        val value = hex.toIntOrNull(16) ?: return null
        if (value !in 0..0xffff) return null
        return UUID.fromString(String.format(Locale.US, "0000%04x-0000-1000-8000-00805f9b34fb", value))
    }

    /** Links to drop (removed, or moved to another address) and links to open. */
    fun linkChanges(current: Map<String, String>, wanted: List<AirSensorTarget>): AirLinkChanges {
        val wantedById = wanted.associateBy { it.id }
        val close = current.filter { (id, address) -> wantedById[id]?.address != address }.keys
        val open = wanted.filter { current[it.id] != it.address }
        return AirLinkChanges(close, open)
    }

    /** "AA01ff" -> bytes; an odd length or a non-hex digit yields an empty array. */
    fun hexBytes(hex: String): ByteArray {
        val clean = hex.trim()
        if (clean.length % 2 != 0) return ByteArray(0)
        val out = ByteArray(clean.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(clean[i * 2], 16)
            val lo = Character.digit(clean[i * 2 + 1], 16)
            if (hi < 0 || lo < 0) return ByteArray(0)
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    /** Parse the AD structures of a legacy advertisement plus scan response. */
    fun advertising(record: ByteArray?): AdvertisingFields {
        if (record == null) return AdvertisingFields(emptySet(), "")
        val services = HashSet<Int>()
        var name = ""
        var i = 0
        while (i < record.size) {
            val length = record[i].toInt() and 0xff
            // Zero length ends the significant part; a structure past the buffer is malformed.
            if (length == 0 || i + 1 + length > record.size) break
            val type = record[i + 1].toInt() and 0xff
            val start = i + 2
            val end = i + 1 + length
            when (type) {
                0x02, 0x03 -> {
                    var j = start
                    while (j + 2 <= end) {
                        services.add((record[j].toInt() and 0xff) or
                            ((record[j + 1].toInt() and 0xff) shl 8))
                        j += 2
                    }
                }
                0x08, 0x09 -> if (name.isEmpty() || type == 0x09)
                    name = String(record, start, end - start, Charsets.UTF_8)
            }
            i = end
        }
        return AdvertisingFields(services, name)
    }

    /** A peripheral is a candidate when it advertises the service or, failing that, the name. */
    fun matches(plan: AirSensorPlan, services16: Set<Int>, name: String): Boolean =
        plan.advertisedService16 in services16 ||
            (name.isNotEmpty() && name == plan.advertisedName)

    fun report(
        ble: String,
        discovered: Collection<AirDiscovered>?,
        links: Map<String, String>?,
    ): JSONObject {
        val out = JSONObject().put("ble", ble)
        if (discovered != null) {
            val list = JSONArray()
            for (d in discovered.sortedBy { it.address })
                list.put(JSONObject().put("address", d.address).put("name", d.name).put("rssi", d.rssi))
            out.put("discovered", list)
        }
        if (links != null) {
            val map = JSONObject()
            for ((id, state) in links) map.put(id, state)
            out.put("links", map)
        }
        return out
    }

    /** Reconnect delay after the [attempt]th consecutive failure: 5 s doubling to 2 min. */
    fun reconnectDelayMs(attempt: Int): Long =
        (5_000L shl attempt.coerceIn(0, 5)).coerceAtMost(120_000L)

    const val PERMISSION_SCAN = "android.permission.BLUETOOTH_SCAN"
    const val PERMISSION_CONNECT = "android.permission.BLUETOOTH_CONNECT"
    const val PERMISSION_FINE_LOCATION = "android.permission.ACCESS_FINE_LOCATION"

    /** Runtime permissions Bluetooth LE scanning and GATT need on [sdk]. */
    fun runtimePermissions(sdk: Int): List<String> = when {
        sdk >= 31 -> listOf(PERMISSION_SCAN, PERMISSION_CONNECT)
        sdk >= 23 -> listOf(PERMISSION_FINE_LOCATION)
        else -> emptyList()
    }
}
