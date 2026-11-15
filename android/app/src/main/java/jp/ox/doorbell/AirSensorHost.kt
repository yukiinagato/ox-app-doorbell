// Bluetooth LE plumbing for the PM2.5 sensors Core assigns to this device. Core parses every
// frame; this class only scans, keeps one GATT link per sensor, and forwards notifications.
package jp.ox.doorbell

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import android.os.Process
import android.util.Log
import org.json.JSONObject

/**
 * Owned by [RuntimeSupervisor] and started only while Core runs. Every method hops onto one
 * dedicated thread; GATT and scan callbacks arrive on Binder threads and are posted there too, so
 * the link table is only touched from that thread. Core's air-sensor entry points are thread-safe
 * and never block, but they still stay off the UI thread.
 *
 * Bluetooth permission checks are made explicitly before every call (see [permitted]), which lint
 * cannot follow across methods; hence the class-level MissingPermission suppression.
 */
@SuppressLint("MissingPermission")
internal class AirSensorHost(private val app: App) {

    private val thread = HandlerThread("doorbell-air-ble", Process.THREAD_PRIORITY_BACKGROUND)
        .apply { start() }
    private val handler = Handler(thread.looper)

    private var coreReady = false
    @Volatile private var plan = AirSensorPlan.NONE
    private var connectCommand = ByteArray(0)
    private val links = LinkedHashMap<String, Link>()
    private var lastBle = ""
    private var receiverRegistered = false

    private var scanActive = false
    private var scanFiltered = true
    private val found = LinkedHashMap<String, AirDiscovered>()
    private var scanner21: AirScannerApi21? = null

    private val scanBurstEnd = Runnable { finishScanBurst() }
    private val scanTick = Runnable { startScanBurst(filtered = true) }

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            handler.post { reconcile() }
        }
    }

    /** Whether this hardware can host a sensor at all; the capability is published from this. */
    val supported: Boolean = hasBleFeature(app)

    fun onCoreReady() = handler.post {
        coreReady = true
        reloadPlan()
    }

    fun onCoreStopped() = handler.post {
        coreReady = false
        plan = AirSensorPlan.NONE
        reconcile()
    }

    fun onPlanChanged() = handler.post { reloadPlan() }

    fun onPermissionsChanged() = handler.post { reconcile() }

    /** Runtime permissions still to grant, and only while Core asks this device to host. */
    fun missingPermissions(): List<String> {
        val current = plan
        if (!current.host || !supported || Build.VERSION.SDK_INT < 23) return emptyList()
        return AirSensorPlans.runtimePermissions(Build.VERSION.SDK_INT)
            .filter { app.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
    }

    // ---------- plan ----------

    private fun reloadPlan() {
        if (!coreReady) return
        val previous = plan
        plan = AirSensorPlans.parse(app.core.airSensorPlan())
        connectCommand = AirSensorPlans.hexBytes(app.core.airSensorConnectCommandHex())
        reconcile()
        if (plan.host && missingPermissions().isNotEmpty()) {
            app.activityListener?.onUiEvent(JSONObject().put("t", PERMISSIONS_EVENT))
        }
        // A plan change asks for a fresh look straight away rather than at the next tick.
        if (plan.scan && (plan != previous || !previous.scan)) {
            handler.removeCallbacks(scanTick)
            handler.post(scanTick)
        }
    }

    /** Bring links, scanning, and the adapter receiver in line with the plan and the adapter. */
    private fun reconcile() {
        if (!coreReady || !plan.host) {
            stopEverything()
            return
        }
        registerReceiver()
        val ble = bleState()
        if (ble != lastBle) {
            lastBle = ble
            report(AirSensorPlans.report(ble, null, null))
        }
        if (ble != BLE_READY) {
            stopScan()
            handler.removeCallbacks(scanTick)
            for (link in links.values) link.close()
            for (target in plan.sensors) links.getOrPut(target.id) { Link(target) }
            for (link in links.values) link.state = LINK_DISCONNECTED
            dropUnplanned()
            reportLinks()
            return
        }
        val current = links.mapValues { it.value.target.address }
        val changes = AirSensorPlans.linkChanges(current, plan.sensors)
        for (id in changes.close) links.remove(id)?.close()
        dropUnplanned()
        for (target in plan.sensors) {
            val link = links.getOrPut(target.id) { Link(target) }
            if (link.gatt == null && !link.retryPending) link.connect()
        }
        reportLinks()
        if (!plan.scan) {
            stopScan()
            handler.removeCallbacks(scanTick)
        }
    }

    private fun dropUnplanned() {
        val wanted = plan.sensors.map { it.id }.toSet()
        val iterator = links.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.key !in wanted) {
                entry.value.close()
                iterator.remove()
            }
        }
    }

    private fun stopEverything() {
        stopScan()
        handler.removeCallbacks(scanTick)
        for (link in links.values) link.close()
        links.clear()
        lastBle = ""
        unregisterReceiver()
    }

    // ---------- adapter state ----------

    private fun adapter(): BluetoothAdapter? =
        (app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun permitted(): Boolean = Build.VERSION.SDK_INT < 23 ||
        AirSensorPlans.runtimePermissions(Build.VERSION.SDK_INT)
            .all { app.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun bleState(): String {
        if (!supported) return "unsupported"
        val adapter = adapter() ?: return "unsupported"
        if (!permitted()) return "unauthorized"
        return try {
            if (adapter.isEnabled) BLE_READY else "off"
        } catch (_: SecurityException) {
            "unauthorized"
        }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        app.registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        try { app.unregisterReceiver(adapterReceiver) } catch (_: IllegalArgumentException) {}
        receiverRegistered = false
    }

    // ---------- scanning ----------

    /**
     * One short burst. The first is filtered on the advertised 16-bit service; when it finds
     * nothing a second, unfiltered burst matches the service or the advertised name itself,
     * because some stacks drop 16-bit service filters.
     */
    private fun startScanBurst(filtered: Boolean) {
        handler.removeCallbacks(scanTick)
        if (!coreReady || !plan.host || !plan.scan || bleState() != BLE_READY) return
        stopScan()
        found.clear()
        scanFiltered = filtered
        val adapter = adapter() ?: return
        val started = try {
            if (Build.VERSION.SDK_INT >= 21) {
                val scanner = AirScannerApi21 { address, name, rssi, services, parsed ->
                    handler.post { onScanResult(address, name, rssi, services, parsed) }
                }
                scanner21 = scanner
                scanner.start(adapter, if (filtered) plan.advertisedServiceUuid else null)
            } else {
                @Suppress("DEPRECATION")
                adapter.startLeScan(legacyScanCallback)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "scan start failed", e)
            false
        }
        if (!started) {
            scanner21 = null
            handler.postDelayed(scanTick, SCAN_INTERVAL_MS)
            return
        }
        scanActive = true
        handler.postDelayed(scanBurstEnd, SCAN_BURST_MS)
    }

    private fun finishScanBurst() {
        val wasFiltered = scanFiltered
        stopScan()
        if (!coreReady || !plan.host || !plan.scan) return
        report(AirSensorPlans.report(bleState(), found.values.toList(), null))
        if (found.isEmpty() && wasFiltered) {
            startScanBurst(filtered = false)
            return
        }
        handler.postDelayed(scanTick, SCAN_INTERVAL_MS)
    }

    private fun stopScan() {
        handler.removeCallbacks(scanBurstEnd)
        if (!scanActive) return
        scanActive = false
        val adapter = adapter() ?: return
        try {
            if (Build.VERSION.SDK_INT >= 21) scanner21?.stop(adapter)
            else {
                @Suppress("DEPRECATION")
                adapter.stopLeScan(legacyScanCallback)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "scan stop failed", e)
        }
        scanner21 = null
    }

    @Suppress("DEPRECATION")
    private val legacyScanCallback = BluetoothAdapter.LeScanCallback { device, rssi, record ->
        val address = device?.address ?: return@LeScanCallback
        val fields = AirSensorPlans.advertising(record)
        val name = fields.name.ifEmpty { deviceName(device) }
        handler.post { onScanResult(address, name, rssi, fields.services16, true) }
    }

    /** [parsed] is false when [services16] came from a filter rather than the record itself. */
    private fun onScanResult(address: String, name: String, rssi: Int, services16: Set<Int>,
                             parsed: Boolean) {
        if (!scanActive) return
        if (parsed && !AirSensorPlans.matches(plan, services16, name)) return
        val shown = name.ifEmpty { plan.advertisedName }.take(64)
        found[address] = AirDiscovered(address, shown, rssi)
    }

    private fun deviceName(device: BluetoothDevice): String = try {
        device.name.orEmpty()
    } catch (_: SecurityException) {
        ""
    }

    // ---------- links ----------

    private fun reportLinks() {
        if (!coreReady || !plan.host) return
        report(AirSensorPlans.report(bleState(), null, links.mapValues { it.value.state }))
    }

    private fun report(document: JSONObject) {
        if (coreReady) app.core.airSensorReport(document)
    }

    private inner class Link(val target: AirSensorTarget) {
        var gatt: BluetoothGatt? = null
        var state = LINK_CONNECTING
        var attempt = 0
        var retryPending = false
        private var everConnected = false
        private var generation = 0
        private val retry = Runnable {
            retryPending = false
            if (links[target.id] === this && plan.host && bleState() == BLE_READY) connect()
        }

        fun connect() {
            val adapter = adapter() ?: return
            val device = try {
                adapter.getRemoteDevice(target.address)
            } catch (_: IllegalArgumentException) {
                null
            }
            if (device == null) {
                updateState(LINK_NOT_FOUND)
                return
            }
            generation++
            everConnected = false
            updateState(LINK_CONNECTING)
            gatt = try {
                if (Build.VERSION.SDK_INT >= 23)
                    GattApi23.connect(device, app, callback(generation))
                else device.connectGatt(app, false, callback(generation))
            } catch (e: RuntimeException) {
                Log.w(TAG, "connectGatt failed for ${target.id}", e)
                null
            }
            if (gatt == null) scheduleRetry(LINK_DISCONNECTED)
        }

        fun close() {
            handler.removeCallbacks(retry)
            retryPending = false
            generation++
            val current = gatt ?: return
            gatt = null
            try {
                current.disconnect()
                current.close()
            } catch (e: RuntimeException) {
                Log.w(TAG, "gatt close failed for ${target.id}", e)
            }
        }

        private fun updateState(value: String) {
            if (state == value) return
            state = value
            reportLinks()
        }

        private fun scheduleRetry(failureState: String) {
            generation++
            val current = gatt
            gatt = null
            if (current != null) try { current.close() } catch (_: RuntimeException) {}
            updateState(failureState)
            handler.removeCallbacks(retry)
            retryPending = true
            handler.postDelayed(retry, AirSensorPlans.reconnectDelayMs(attempt))
            attempt++
        }

        private fun callback(expected: Int) = object : BluetoothGattCallback() {
            private fun onThread(block: () -> Unit) {
                handler.post {
                    if (generation == expected && links[target.id] === this@Link) block()
                }
            }

            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) =
                onThread {
                    if (newState == BluetoothProfile.STATE_CONNECTED &&
                        status == BluetoothGatt.GATT_SUCCESS) {
                        everConnected = true
                        if (!g.discoverServices()) scheduleRetry(LINK_DISCONNECTED)
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED ||
                        status != BluetoothGatt.GATT_SUCCESS) {
                        scheduleRetry(if (everConnected) LINK_DISCONNECTED else LINK_NOT_FOUND)
                    }
                }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onThread {
                val tx = g.getService(plan.service)?.getCharacteristic(plan.tx)
                if (status != BluetoothGatt.GATT_SUCCESS || tx == null) {
                    g.disconnect()
                    scheduleRetry(LINK_DISCONNECTED)
                    return@onThread
                }
                val cccd = tx.getDescriptor(AirSensorPlans.CCCD)
                if (!g.setCharacteristicNotification(tx, true) || cccd == null ||
                    !writeDescriptor(g, cccd)) {
                    g.disconnect()
                    scheduleRetry(LINK_DISCONNECTED)
                }
            }

            override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor,
                                           status: Int) = onThread {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    g.disconnect()
                    scheduleRetry(LINK_DISCONNECTED)
                    return@onThread
                }
                attempt = 0
                updateState(LINK_CONNECTED)
                val rx = g.getService(plan.service)?.getCharacteristic(plan.rx)
                if (rx != null && connectCommand.isNotEmpty()) writeCommand(g, rx, connectCommand)
            }

            @Deprecated("Called before API 33")
            override fun onCharacteristicChanged(g: BluetoothGatt,
                                                 c: BluetoothGattCharacteristic) {
                @Suppress("DEPRECATION")
                val value = c.value ?: return
                deliver(c, value.copyOf())
            }

            override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic,
                                                 value: ByteArray) = deliver(c, value.copyOf())

            private fun deliver(c: BluetoothGattCharacteristic, value: ByteArray) {
                if (c.uuid != plan.tx || value.isEmpty()) return
                onThread { app.core.airSensorPacket(target.id, value) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor): Boolean {
        if (Build.VERSION.SDK_INT >= 33)
            return GattApi33.writeDescriptor(g, d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return g.writeDescriptor(d)
    }

    @Suppress("DEPRECATION")
    private fun writeCommand(g: BluetoothGatt, rx: BluetoothGattCharacteristic, bytes: ByteArray) {
        val type = if (rx.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        if (Build.VERSION.SDK_INT >= 33) {
            GattApi33.writeCharacteristic(g, rx, bytes, type)
            return
        }
        rx.writeType = type
        rx.value = bytes
        g.writeCharacteristic(rx)
    }

    companion object {
        private const val TAG = "doorbell-air"
        const val PERMISSIONS_EVENT = "air_sensor_permissions"
        private const val BLE_READY = "ready"
        private const val LINK_CONNECTING = "connecting"
        private const val LINK_CONNECTED = "connected"
        private const val LINK_DISCONNECTED = "disconnected"
        private const val LINK_NOT_FOUND = "not_found"
        private const val SCAN_BURST_MS = 10_000L
        private const val SCAN_INTERVAL_MS = 3 * 60_000L

        fun hasBleFeature(context: Context): Boolean =
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
    }
}

@TargetApi(21)
@SuppressLint("MissingPermission")
private class AirScannerApi21(
    private val onResult: (String, String, Int, Set<Int>, Boolean) -> Unit,
) {
    private var filtered = false

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = handle(result)

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            for (result in results) handle(result)
        }
    }

    private fun handle(result: ScanResult) {
        val address = result.device?.address ?: return
        val record = result.scanRecord
        val fields = AirSensorPlans.advertising(record?.bytes)
        val name = record?.deviceName.orEmpty().ifEmpty { fields.name }
        // A filtered result already matched the service; an unfiltered one is matched by the host.
        onResult(address, name, result.rssi, fields.services16, !filtered)
    }

    fun start(adapter: BluetoothAdapter, service: java.util.UUID?): Boolean {
        val scanner = adapter.bluetoothLeScanner ?: return false
        filtered = service != null
        val filters = if (service != null)
            listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(service)).build())
        else emptyList()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(filters, settings, callback)
        return true
    }

    fun stop(adapter: BluetoothAdapter) {
        adapter.bluetoothLeScanner?.stopScan(callback)
    }
}

@TargetApi(23)
@SuppressLint("MissingPermission")
private object GattApi23 {
    fun connect(device: BluetoothDevice, context: Context, callback: BluetoothGattCallback):
        BluetoothGatt? = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
}

@TargetApi(33)
@SuppressLint("MissingPermission")
private object GattApi33 {
    fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor, value: ByteArray): Boolean =
        g.writeDescriptor(d, value) == android.bluetooth.BluetoothStatusCodes.SUCCESS

    fun writeCharacteristic(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray,
                            type: Int) {
        g.writeCharacteristic(c, value, type)
    }
}
