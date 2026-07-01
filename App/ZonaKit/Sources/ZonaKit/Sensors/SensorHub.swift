import CoreBluetooth
import Foundation
import Observation

/// Manages several independent BLE fitness sensors at once (trainer, HR strap,
/// power meter) over a single `CBCentralManager`, and drives the FTMS trainer's
/// ERG control. Replaces the original single-peripheral manager.
///
/// Concurrency (Swift 6): identical model to the original design — every
/// CoreBluetooth object lives inside the private `MultiBLEManager` on a
/// dedicated queue; only `Sendable` values cross to this `@MainActor` type.
///
/// The FTMS trainer handshake (request control → start → ERG → Indoor Bike Data)
/// is preserved byte-for-byte; only the surrounding device management changed.
@MainActor
@Observable
public final class SensorHub {
    /// Which sensor kinds this session cares about (set by `connect`).
    public private(set) var desiredKinds: Set<SensorKind> = []
    /// Per-kind connection state.
    public private(set) var states: [SensorKind: SensorConnectionState] = [:]
    /// Latest merged live values across all connected sensors.
    public private(set) var metrics = RideMetrics()
    /// Whether the trainer has completed the FTMS handshake and accepts ERG.
    public private(set) var trainerReady = false
    public private(set) var log: [String] = []

    /// Called (on the main actor) after any sensor state change, so an owner can
    /// react — e.g. `TrainerController` latching the ride as started.
    @ObservationIgnored public var onStateChange: (() -> Void)?
    /// Called (on the main actor) after live metrics change, so an owner can
    /// republish them as its own observed state for SwiftUI.
    @ObservationIgnored public var onMetricsChange: ((RideMetrics) -> Void)?

    @ObservationIgnored private let memory: SensorMemory
    @ObservationIgnored private lazy var ble = MultiBLEManager(owner: self, memory: memory)

    public init(memory: SensorMemory = EphemeralSensorMemory()) {
        self.memory = memory
    }

    public func state(for kind: SensorKind) -> SensorConnectionState {
        states[kind] ?? .disconnected
    }

    // MARK: - Control surface

    /// Begin scanning for the given sensor kinds and connect them.
    public func connect(_ kinds: Set<SensorKind>) {
        desiredKinds = kinds
        for kind in kinds where states[kind] == nil { states[kind] = .scanning }
        ble.start(kinds: kinds)
    }

    /// ERG: command the trainer to hold `watts`. No-op until the trainer is ready.
    public func setTargetPower(_ watts: Int) {
        guard trainerReady else { return }
        metrics.targetW = watts
        onMetricsChange?(metrics)
        append("→ Set Target Power: \(watts) W")
        ble.writeToTrainer(FTMS.setTargetPowerCommand(watts: watts))
    }

    /// Stop the ERG session and disconnect all sensors. Fully resets to idle so
    /// the UI returns to setup and stays there (no auto-rescan / auto-restart).
    public func stop() {
        append("→ Stop")
        ble.writeToTrainer(FTMS.stopCommand())
        ble.disconnectAll()
        trainerReady = false
        metrics = RideMetrics()
        // Clear desiredKinds so `connection` reports `.idle` — otherwise a
        // lingering desired set makes it report `.scanning`, dropping the user
        // back onto setup with a live scan running.
        desiredKinds = []
        states.removeAll()
    }

    // MARK: - Callbacks from the BLE shim (already on the main actor)

    fileprivate func setState(_ state: SensorConnectionState, for kind: SensorKind) {
        states[kind] = state
        switch state {
        case .connecting(let name): append("\(kind.displayName): connecting to \(name)…")
        case .connected(let name):  append("\(kind.displayName): connected (\(name))")
        case .disconnected:         append("\(kind.displayName): disconnected")
        case .scanning:             append("\(kind.displayName): scanning…")
        }
        onStateChange?()
    }

    fileprivate func setUnavailable(_ reason: String) {
        append("⚠️ \(reason)")
        for kind in desiredKinds { states[kind] = .disconnected }
    }

    fileprivate func apply(_ reading: SensorReading) {
        if let p = reading.powerW { metrics.powerW = p }
        if let c = reading.cadenceRpm { metrics.cadenceRpm = c }
        if let s = reading.speedKph { metrics.speedKph = s }
        if let hr = reading.heartRateBpm { metrics.heartRateBpm = hr }
        onMetricsChange?(metrics)
    }

    fileprivate func setTrainerReady() {
        trainerReady = true
        append("✓ Trainer in control (ERG ready)")
        onStateChange?()
    }

    fileprivate func note(_ line: String) { append(line) }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - Multi-peripheral CoreBluetooth shim
//
// Owns the central and a dictionary of peripherals keyed by SensorKind. All
// GATT I/O happens here on the BLE queue; only Sendable values are forwarded to
// the @MainActor hub. Mirrors the original single-peripheral shim's structure.

private final class MultiBLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private weak var owner: SensorHub?
    private let memory: SensorMemory
    private let queue = DispatchQueue(label: "zona.sensors")

    private var central: CBCentralManager?
    private var desired: Set<SensorKind> = []
    // Connected/connecting peripherals and their control point (trainer only).
    private var peripherals: [SensorKind: CBPeripheral] = [:]
    private var trainerControlPoint: CBCharacteristic?
    // Reverse lookup while a connection is in flight.
    private var kindForPeripheral: [UUID: SensorKind] = [:]
    // Connected peripherals whose kind isn't known until GATT services are
    // discovered (device didn't advertise its service UUID).
    private var pendingByIdentifier: [UUID: CBPeripheral] = [:]
    // Peripherals with an in-flight connect (watchdog armed, not yet discovered).
    private var connectingIdentifiers: Set<UUID> = []

    init(owner: SensorHub, memory: SensorMemory) {
        self.owner = owner
        self.memory = memory
    }

    func start(kinds: Set<SensorKind>) {
        queue.async {
            self.desired.formUnion(kinds)
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else if self.central?.state == .poweredOn {
                self.beginScan()
            }
        }
    }

    func writeToTrainer(_ data: Data) {
        queue.async {
            guard let cp = self.trainerControlPoint,
                  let t = self.peripherals[.trainer] else { return }
            t.writeValue(data, for: cp, type: .withResponse)
        }
    }

    func disconnectAll() {
        queue.async {
            // Clear `desired` FIRST so the resulting didDisconnect callbacks are
            // treated as intentional teardown — otherwise `handleDrop` sees the
            // kind still wanted and auto-reconnects, restarting the ride.
            self.desired.removeAll()
            self.central?.stopScan()
            for p in self.peripherals.values { self.central?.cancelPeripheralConnection(p) }
            self.peripherals.removeAll()
            self.kindForPeripheral.removeAll()
            self.pendingByIdentifier.removeAll()
            self.connectingIdentifiers.removeAll()
            self.trainerControlPoint = nil
        }
    }

    private func toOwner(_ body: @escaping @MainActor (SensorHub) -> Void) {
        Task { @MainActor [weak owner] in if let owner { body(owner) } }
    }

    private func beginScan() {
        guard let central else { return }

        // Prefer devices we remembered: connect directly without scanning.
        for kind in desired {
            if let id = memory.rememberedIdentifier(for: kind),
               let known = central.retrievePeripherals(withIdentifiers: [id]).first,
               peripherals[kind] == nil {
                attach(known, as: kind)
                let name = known.name ?? kind.displayName
                toOwner { $0.setState(.connecting(name: name), for: kind) }
                connectingIdentifiers.insert(known.identifier)
                central.connect(known)
                armConnectTimeout(known.identifier)
            }
        }

        // Scan for any not-yet-connected kinds. We scan with `nil` services
        // (all peripherals) rather than filtering by service UUID: the Garmin
        // HRM 200 does not advertise its 0x180D service in the advertisement
        // packet, so a service-filtered scan never surfaces it. We identify each
        // discovered device by connecting and inspecting its GATT services (the
        // pending path). Duplicate-advertisement floods are harmless — we guard
        // against re-grabbing an in-flight device.
        let anyMissing = desired.contains { peripherals[$0] == nil }
        if anyMissing {
            central.scanForPeripherals(withServices: nil)
        }
    }

    private func attach(_ peripheral: CBPeripheral, as kind: SensorKind) {
        peripheral.delegate = self
        peripherals[kind] = peripheral
        kindForPeripheral[peripheral.identifier] = kind
    }

    /// CoreBluetooth `connect(_:)` never times out. Arm a watchdog so a stalled
    /// connection (e.g. a stale remembered peripheral that no longer responds)
    /// is cancelled and retried via a fresh scan, instead of hanging forever at
    /// "Connecting…". Cleared once the peripheral finishes discovery.
    ///
    /// Captures only the `UUID` (Sendable); the runs on `queue`, so we look the
    /// peripheral back up from `peripherals`/`pendingByIdentifier` there.
    private func armConnectTimeout(_ id: UUID) {
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.connectingIdentifiers.contains(id) else { return }
            self.connectingIdentifiers.remove(id)

            if let kind = self.kindForPeripheral[id], let p = self.peripherals[kind] {
                self.central?.cancelPeripheralConnection(p)
                self.peripherals[kind] = nil
                self.kindForPeripheral[id] = nil
                self.toOwner { $0.note("\(kind.displayName): connect timed out, rescanning") }
            } else if let p = self.pendingByIdentifier[id] {
                self.central?.cancelPeripheralConnection(p)
                self.pendingByIdentifier[id] = nil
                self.toOwner { $0.note("Sensor connect timed out, rescanning") }
            }
            self.rescanForMissing()
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .unauthorized:
            toOwner { $0.setUnavailable("Bluetooth permission denied. Enable it in Settings › Privacy › Bluetooth.") }
        case .poweredOff:
            toOwner { $0.setUnavailable("Bluetooth is off.") }
        case .unsupported:
            toOwner { $0.setUnavailable("Bluetooth LE is unsupported on this device.") }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // We scan filtered by service UUID, so iOS only surfaces peripherals
        // that match a desired kind. Try to name the kind from the advertised
        // service list — but MANY devices (Garmin straps, some trainers) omit
        // their service UUID from the advertisement packet. In that case we
        // can't tell the kind yet, so we connect and confirm from the actual
        // GATT services in `didDiscoverServices`. (The earlier code REQUIRED the
        // UUID in the advertisement and silently dropped such devices — that's
        // why the HR strap sat "searching" forever.)
        let id = peripheral.identifier
        // Skip anything already connected, connecting, or pending.
        guard !connectingIdentifiers.contains(id),
              pendingByIdentifier[id] == nil,
              !peripherals.values.contains(where: { $0.identifier == id }) else { return }

        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matchedKind = desired.first { peripherals[$0] == nil && advertised.contains($0.serviceUUID) }

        if let kind = matchedKind {
            // Advertised a desired service — connect and set the kind now.
            attach(peripheral, as: kind)
            let name = peripheral.name ?? kind.displayName
            toOwner { $0.setState(.connecting(name: name), for: kind) }
        } else {
            // Scanning with nil surfaces every device. Only pursue ones whose
            // NAME plausibly matches something we still want (Garmin/Wahoo/HR/
            // power straps broadcast a recognizable name), so we don't dial up a
            // neighbour's headphones. Identify the kind from GATT after connect.
            guard let name = peripheral.name,
                  nameLooksLikeDesiredSensor(name) else { return }
            pendingByIdentifier[id] = peripheral
            peripheral.delegate = self
        }
        connectingIdentifiers.insert(id)
        central.connect(peripheral)
        armConnectTimeout(id)
    }

    /// Heuristic name filter for the nil-service scan: does this device name look
    /// like a trainer / HR strap / power meter we might want?
    private func nameLooksLikeDesiredSensor(_ name: String) -> Bool {
        let n = name.lowercased()
        let hints = ["kickr", "wahoo", "hrm", "heart", "tickr", "polar", "garmin",
                     "quarq", "sram", "power", "cadence", "whoop"]
        return hints.contains { n.contains($0) }
    }

    /// Resume scanning if any desired kind is still missing. Uses a nil-service
    /// scan (see `beginScan`) so non-advertising straps are still found.
    private func rescanForMissing() {
        guard let central, central.state == .poweredOn else { return }
        let anyMissing = desired.contains { peripherals[$0] == nil }
        if !anyMissing {
            central.stopScan()
        } else {
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let kind = kindForPeripheral[peripheral.identifier] {
            // Kind already known from the advertisement.
            memory.remember(peripheral.identifier, for: kind)
            peripheral.discoverServices([kind.serviceUUID])
        } else if pendingByIdentifier[peripheral.identifier] != nil {
            // Kind unknown — discover every desired service so we can identify
            // this device from what it actually exposes.
            peripheral.discoverServices(desired.map(\.serviceUUID))
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleDrop(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDrop(peripheral, error: error)
    }

    private func handleDrop(_ peripheral: CBPeripheral, error: Error?) {
        // A peripheral that dropped before we could identify its kind: just
        // forget it and keep scanning.
        guard let kind = kindForPeripheral[peripheral.identifier] else {
            if pendingByIdentifier[peripheral.identifier] != nil {
                pendingByIdentifier[peripheral.identifier] = nil
                rescanForMissing()
            }
            return
        }
        kindForPeripheral[peripheral.identifier] = nil
        connectingIdentifiers.remove(peripheral.identifier)
        if kind == .trainer { trainerControlPoint = nil }

        let reason = error?.localizedDescription
        toOwner {
            $0.note("\(kind.displayName) dropped\(reason.map { ": \($0)" } ?? "")")
        }

        // HR straps (and many sensors) disconnect on idle to save battery, then
        // re-advertise. If we still want this kind, keep a standing reconnect
        // request open (CoreBluetooth reconnects whenever the device reappears)
        // and fall back to scanning, rather than giving up.
        if desired.contains(kind) {
            // Keep holding the peripheral so `connect` retains it, and re-arm.
            peripherals[kind] = peripheral
            kindForPeripheral[peripheral.identifier] = kind
            toOwner { $0.setState(.scanning, for: kind) }
            central?.connect(peripheral)   // fires again when it re-advertises
            rescanForMissing()             // also catch it via a fresh scan
        } else {
            peripherals[kind] = nil
            toOwner { $0.setState(.disconnected, for: kind) }
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []

        // Resolve the kind: known from advertisement, or inferred from the
        // actual services this peripheral exposes (the pending path).
        var kind = kindForPeripheral[peripheral.identifier]
        if kind == nil, pendingByIdentifier[peripheral.identifier] != nil {
            let resolved = desired.first { k in
                peripherals[k] == nil && services.contains { $0.uuid == k.serviceUUID }
            }
            pendingByIdentifier[peripheral.identifier] = nil
            guard let resolved else {
                // Not a device we want after all — let it go.
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            attach(peripheral, as: resolved)
            memory.remember(peripheral.identifier, for: resolved)
            let name = peripheral.name ?? resolved.displayName
            toOwner { $0.setState(.connecting(name: name), for: resolved) }
            kind = resolved
        }

        guard let kind,
              let service = services.first(where: { $0.uuid == kind.serviceUUID }) else { return }
        // Trainer needs its control point too; others just the measurement char.
        var chars = [kind.measurementUUID]
        if kind == .trainer { chars.append(FTMS.controlPointUUID) }
        peripheral.discoverCharacteristics(chars, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let kind = kindForPeripheral[peripheral.identifier] else { return }
        // Connection fully established — disarm the connect watchdog.
        connectingIdentifiers.remove(peripheral.identifier)

        for char in service.characteristics ?? [] {
            if char.uuid == kind.measurementUUID {
                peripheral.setNotifyValue(true, for: char)
            }
            if kind == .trainer, char.uuid == FTMS.controlPointUUID {
                trainerControlPoint = char
                peripheral.setNotifyValue(true, for: char)
            }
        }

        let name = peripheral.name ?? kind.displayName
        toOwner { $0.setState(.connected(name: name), for: kind) }

        // Stop the (unfiltered) scan only once every desired kind is actually
        // connected — not merely in flight — so a slow strap isn't abandoned.
        if desired.allSatisfy({ peripherals[$0] != nil }) { central?.stopScan() }

        // FTMS handshake — unchanged from the verified single-peripheral path.
        if kind == .trainer, let cp = trainerControlPoint {
            peripheral.writeValue(FTMS.requestControlCommand(), for: cp, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let kind = kindForPeripheral[peripheral.identifier] else { return }

        switch (kind, characteristic.uuid) {
        case (.trainer, FTMS.indoorBikeDataUUID):
            guard let d = IndoorBikeData(data) else { return }
            let reading = SensorReading(powerW: d.instantaneousPowerW,
                                        cadenceRpm: d.instantaneousCadenceRpm.map { Int($0.rounded()) },
                                        speedKph: d.instantaneousSpeedKph)
            toOwner { $0.apply(reading) }

        case (.trainer, FTMS.controlPointUUID):
            handleTrainerControlResponse(data, peripheral: peripheral)

        case (.heartRate, _):
            guard let hr = HeartRateMeasurement(data) else { return }
            let reading = SensorReading(heartRateBpm: hr.heartRateBpm)
            toOwner { $0.apply(reading) }

        case (.powerMeter, _):
            guard let p = CyclingPowerMeasurement(data) else { return }
            let reading = SensorReading(powerW: p.instantaneousPowerW)
            toOwner { $0.apply(reading) }

        default:
            break
        }
    }

    /// The FTMS request-control → start → ready chain, identical to the original.
    private func handleTrainerControlResponse(_ data: Data, peripheral: CBPeripheral) {
        guard let resp = FTMS.parseControlResponse(data) else { return }
        let requested = resp.requested
        let succeeded = resp.result.isSuccess

        if succeeded, let cp = trainerControlPoint {
            if requested == FTMS.OpCode.requestControl.rawValue {
                peripheral.writeValue(FTMS.startCommand(), for: cp, type: .withResponse)
            } else if requested == FTMS.OpCode.startOrResume.rawValue {
                toOwner { $0.setTrainerReady() }
            }
        }
    }
}
