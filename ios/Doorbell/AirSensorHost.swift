import CoreBluetooth
import Foundation

/// GATT plumbing for the Bluetooth PM2.5 sensors Core assigns to this device. Core owns the plan,
/// the protocol and the readings; this class only scans, keeps one link per listed sensor, and
/// forwards raw notifications.
///
/// Threading: every CoreBluetooth callback, timer and Core call runs on `queue`. Core's plan and
/// connect-command reads wait on its loop, which is why none of this touches the main thread.
/// No CBCentralManager exists until Core names this device a host, because creating one is what
/// raises the Bluetooth permission prompt.
final class AirSensorHost: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    struct Sensor: Equatable {
        let id: String
        let address: String
        let kind: String
    }

    struct Plan: Equatable {
        var host = false
        var scan = false
        var sensors: [Sensor] = []
        var advertisedService = "7676"
        var service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        var rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        var tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

        static func from(_ doc: [String: Any]?) -> Plan {
            var plan = Plan()
            guard let doc = doc else { return plan }
            plan.host = (doc["host"] as? Bool) ?? false
            plan.scan = (doc["scan"] as? Bool) ?? false
            for entry in doc["sensors"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String, !id.isEmpty else { continue }
                plan.sensors.append(Sensor(id: id, address: entry["address"] as? String ?? "",
                                           kind: entry["kind"] as? String ?? ""))
            }
            if let gatt = doc["mops_vida_pm25"] as? [String: Any] {
                func uuid(_ key: String, _ fallback: String) -> String {
                    guard let value = gatt[key] as? String, !value.isEmpty else { return fallback }
                    return value
                }
                plan.advertisedService = uuid("advertised_service", plan.advertisedService)
                plan.service = uuid("service", plan.service)
                plan.rx = uuid("rx", plan.rx)
                plan.tx = uuid("tx", plan.tx)
            }
            return plan
        }
    }

    private final class Link {
        let sensor: Sensor
        var peripheral: CBPeripheral?
        var rx: CBCharacteristic?
        var state = "disconnected"
        var failures = 0
        var commandSent = false
        var retry: DispatchWorkItem?

        init(sensor: Sensor) { self.sensor = sensor }
    }

    static let scanBurstS: TimeInterval = 10
    static let scanEveryS: TimeInterval = 180
    static let tickS: TimeInterval = 30
    static let retryDelaysS: [TimeInterval] = [2, 5, 10, 30, 60, 120]
    private static let handlerKey = "air_sensor_host"

    private let core: CoreBridge
    private let queue = DispatchQueue(label: "jp.ox.doorbell.air-sensor")
    private var running = false
    private var plan = Plan()
    private var central: CBCentralManager?
    private var links: [String: Link] = [:]
    private var discovered: [String: [String: Any]] = [:]
    private var scanning = false
    private var scanStop: DispatchWorkItem?
    private var lastScanStart: TimeInterval = -.greatestFiniteMagnitude
    private var ticker: DispatchSourceTimer?

    init(core: CoreBridge) {
        self.core = core
        super.init()
    }

    func start() {
        core.addHandler(AirSensorHost.handlerKey) { [weak self] ev in
            guard ConfigUtil.evStr(ev, "t") == "air_sensor_plan_changed" else { return }
            self?.queue.async { self?.refreshPlan() }
        }
        queue.async {
            guard !self.running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + AirSensorHost.tickS,
                           repeating: AirSensorHost.tickS)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.ticker = timer
            self.refreshPlan()
        }
    }

    func stop() {
        core.removeHandler(AirSensorHost.handlerKey)
        queue.async {
            self.running = false
            self.ticker?.cancel()
            self.ticker = nil
            self.release()
        }
    }

    /// Re-read the plan on demand, for example after Core has started.
    func planMayHaveChanged() {
        queue.async { self.refreshPlan() }
    }

    // MARK: - Plan

    /// The plan is re-read on every tick as well as on the event, so a plan published before
    /// this host registered its handler is still picked up.
    private func tick() {
        refreshPlan()
        guard running, plan.host, plan.scan,
              ProcessInfo.processInfo.systemUptime - lastScanStart >= AirSensorHost.scanEveryS
        else { return }
        startScanBurst()
    }

    private func refreshPlan() {
        guard running else { return }
        let next = Plan.from(core.airSensorPlan())
        guard next.host else {
            if central != nil { release() }
            plan = next
            return
        }
        let previous = plan
        plan = next
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        reconcileLinks()
        if next.scan && (!previous.scan || next != previous) {
            startScanBurst()
        } else if !next.scan {
            stopScan()
            discovered.removeAll()
        }
        if next != previous { report() }
    }

    private func reconcileLinks() {
        let wanted = Dictionary(plan.sensors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, link) in links where wanted[id] != link.sensor {
            drop(link)
            links.removeValue(forKey: id)
        }
        for (id, sensor) in wanted where links[id] == nil {
            let link = Link(sensor: sensor)
            links[id] = link
            connect(link)
        }
    }

    /// Releases every link, the scan and the central manager.
    private func release() {
        stopScan()
        for link in links.values { drop(link) }
        links.removeAll()
        discovered.removeAll()
        central?.delegate = nil
        central = nil
    }

    private func drop(_ link: Link) {
        link.retry?.cancel()
        link.retry = nil
        if let peripheral = link.peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        link.peripheral = nil
        link.rx = nil
    }

    private var poweredOn: Bool {
        guard let central = central else { return false }
        return IOSAvailability.bluetoothState(central) == "ready"
    }

    // MARK: - Scanning

    private func startScanBurst() {
        guard plan.scan, poweredOn, let central = central else { return }
        lastScanStart = ProcessInfo.processInfo.systemUptime
        discovered.removeAll()
        scanStop?.cancel()
        central.scanForPeripherals(withServices: [CBUUID(string: plan.advertisedService)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        let work = DispatchWorkItem { [weak self] in
            self?.stopScan()
            self?.report()
        }
        scanStop = work
        queue.asyncAfter(deadline: .now() + AirSensorHost.scanBurstS, execute: work)
    }

    private func stopScan() {
        scanStop?.cancel()
        scanStop = nil
        if scanning, poweredOn { central?.stopScan() }
        scanning = false
    }

    // MARK: - Links

    private func connect(_ link: Link) {
        link.retry?.cancel()
        link.retry = nil
        guard running, links[link.sensor.id] === link, poweredOn, let central = central else {
            return
        }
        guard let uuid = UUID(uuidString: link.sensor.address),
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            // Only a peripheral this device has seen can be retrieved; a later scan may find it.
            setState(link, "not_found")
            scheduleRetry(link)
            return
        }
        link.peripheral = peripheral
        link.rx = nil
        link.commandSent = false
        peripheral.delegate = self
        setState(link, "connecting")
        central.connect(peripheral, options: nil)
    }

    private func scheduleRetry(_ link: Link) {
        link.retry?.cancel()
        let delays = AirSensorHost.retryDelaysS
        let delay = delays[min(link.failures, delays.count - 1)]
        link.failures += 1
        let work = DispatchWorkItem { [weak self, weak link] in
            guard let self = self, let link = link else { return }
            self.connect(link)
        }
        link.retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func linkLost(_ link: Link) {
        if let peripheral = link.peripheral {
            peripheral.delegate = nil
            if peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
        }
        link.peripheral = nil
        link.rx = nil
        setState(link, "disconnected")
        scheduleRetry(link)
    }

    private func link(for peripheral: CBPeripheral) -> Link? {
        return links.values.first { $0.peripheral === peripheral }
    }

    private func setState(_ link: Link, _ state: String) {
        guard link.state != state else { return }
        link.state = state
        report()
    }

    // MARK: - Report

    private func report() {
        guard running, plan.host else { return }
        var doc: [String: Any] = [
            "ble": central.map { IOSAvailability.bluetoothState($0) } ?? "unknown",
            "links": Dictionary(links.map { ($0.key, $0.value.state) },
                                uniquingKeysWith: { a, _ in a }),
        ]
        if plan.scan {
            doc["discovered"] = discovered.keys.sorted().compactMap { discovered[$0] }
        }
        core.airSensorReport(doc)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if poweredOn {
            for link in links.values where link.peripheral == nil {
                link.failures = 0
                connect(link)
            }
            if plan.scan { startScanBurst() }
        } else {
            // Peripherals handed out before the adapter went away are invalid afterwards.
            scanning = false
            scanStop?.cancel()
            scanStop = nil
            for link in links.values {
                link.retry?.cancel()
                link.retry = nil
                link.peripheral?.delegate = nil
                link.peripheral = nil
                link.rx = nil
                link.state = "disconnected"
            }
        }
        report()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, plan.scan else { return }
        let address = peripheral.identifier.uuidString
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let isNew = discovered[address] == nil
        discovered[address] = ["address": address, "name": name, "rssi": RSSI.intValue]
        if isNew { report() }
        // A sensor that was assigned before this device had ever seen it becomes retrievable now.
        for link in links.values where link.sensor.address.caseInsensitiveCompare(address)
            == .orderedSame && link.state == "not_found" {
            link.failures = 0
            connect(link)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, link(for: peripheral) != nil else { return }
        peripheral.discoverServices([CBUUID(string: plan.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard central === self.central, let link = link(for: peripheral) else { return }
        linkLost(link)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard central === self.central, let link = link(for: peripheral) else { return }
        linkLost(link)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = link(for: peripheral) else { return }
        let serviceId = CBUUID(string: plan.service)
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == serviceId }) else {
            linkLost(link)
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: plan.rx), CBUUID(string: plan.tx)],
                                           for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        let rxId = CBUUID(string: plan.rx)
        let txId = CBUUID(string: plan.tx)
        let characteristics = service.characteristics ?? []
        guard error == nil,
              let rx = characteristics.first(where: { $0.uuid == rxId }),
              let tx = characteristics.first(where: { $0.uuid == txId }) else {
            linkLost(link)
            return
        }
        link.rx = rx
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = link(for: peripheral),
              characteristic.uuid == CBUUID(string: plan.tx) else { return }
        guard error == nil, characteristic.isNotifying else {
            linkLost(link)
            return
        }
        if !link.commandSent, let rx = link.rx, let command = core.airSensorConnectCommand() {
            let type: CBCharacteristicWriteType =
                rx.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(command, for: rx, type: type)
            link.commandSent = true
        }
        link.failures = 0
        setState(link, "connected")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let link = link(for: peripheral),
              characteristic.uuid == CBUUID(string: plan.tx),
              let value = characteristic.value else { return }
        core.airSensorPacket(sensorId: link.sensor.id, data: value)
    }
}
