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

    /// Devices found by the current browse scan (see `startBrowsing`). Empty
    /// unless a browse is active. Deduped by identifier, most-recently-seen RSSI.
    public private(set) var discovered: [DiscoveredSensor] = []
    /// The kind currently being browsed, if any.
    public private(set) var browsingKind: SensorKind?

    /// Called (on the main actor) after any sensor state change, so an owner can
    /// react — e.g. `TrainerController` latching the ride as started.
    @ObservationIgnored public var onStateChange: (() -> Void)?
    /// Called (on the main actor) after live metrics change, so an owner can
    /// republish them as its own observed state for SwiftUI.
    @ObservationIgnored public var onMetricsChange: ((RideMetrics) -> Void)?
    /// Called (on the main actor) after the browse `discovered` list changes, so
    /// an owner can republish it as its own observed state for SwiftUI.
    @ObservationIgnored public var onDiscoveryChange: (([DiscoveredSensor]) -> Void)?

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

    // MARK: - Device browsing & preferred selection

    /// Start a discovery scan for `kind`, surfacing every matching device into
    /// `discovered` without connecting/committing any of them. Use this to let
    /// the user pick a preferred device. Call `stopBrowsing()` when done (e.g.
    /// on sheet dismiss). Browse only from an idle/setup state, never mid-ride.
    public func startBrowsing(_ kind: SensorKind) {
        browsingKind = kind
        discovered = []
        onDiscoveryChange?(discovered)
        ble.startBrowsing(kind)
    }

    /// Stop the browse scan and clear the discovered list.
    public func stopBrowsing() {
        browsingKind = nil
        discovered = []
        onDiscoveryChange?(discovered)
        ble.stopBrowsing()
    }

    /// The user's pinned device for `kind`, if any.
    public func preferredIdentifier(for kind: SensorKind) -> UUID? {
        memory.preferredIdentifier(for: kind)
    }

    /// Pin (or clear, with nil) the preferred device for `kind`. If a *different*
    /// device currently holds the slot, it's dropped and the preferred one is
    /// connected in its place. Safe to call while connected or idle.
    public func setPreferred(_ identifier: UUID?, for kind: SensorKind) {
        memory.setPreferred(identifier, for: kind)
        ble.applyPreferredChange(identifier, for: kind)
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

    /// A browse scan found (or re-found) a device. Dedupe by identifier and keep
    /// the latest RSSI. Ignored unless a browse is active for this kind.
    fileprivate func reportDiscovered(_ sensor: DiscoveredSensor) {
        guard browsingKind == sensor.kind else { return }
        if let idx = discovered.firstIndex(where: { $0.id == sensor.id }) {
            discovered[idx] = sensor
        } else {
            discovered.append(sensor)
        }
        onDiscoveryChange?(discovered)
    }

    fileprivate func apply(_ reading: SensorReading) {
        if let p = reading.powerW { metrics.powerW = p }
        if let c = reading.cadenceRpm { metrics.cadenceRpm = c }
        if let s = reading.speedKph { metrics.speedKph = s }
        if let hr = reading.heartRateBpm { metrics.heartRateBpm = hr }
        // Power meter watts are tracked separately from the trainer's power (see
        // `powerMeterW`); only the ride screen's secondary readout reads them.
        if let pm = reading.powerMeterW { metrics.powerMeterW = pm }
        // R-R is bursty and must not stick across seconds: attach it only for the
        // publish that carried it, then clear it so a later reading (e.g. the next
        // Indoor Bike Data with no R-R) doesn't re-record the same beats.
        metrics.rrIntervalsSec = reading.rrIntervalsSec
        onMetricsChange?(metrics)
        metrics.rrIntervalsSec = nil
    }

    fileprivate func setTrainerReady() {
        trainerReady = true
        append("✓ Trainer in control (ERG ready)")
        onStateChange?()
    }

    /// Append a line to the ride event log. `fileprivate` callers (BLE shim) and
    /// the app (via `TrainerController.note`) share it.
    public func note(_ line: String) { append(line) }

    #if DEBUG
    /// Test seam: fold a reading into `metrics` exactly as a live sensor would,
    /// without a CoreBluetooth central. Used to assert power-meter isolation.
    func applyForTesting(_ reading: SensorReading) { apply(reading) }
    #endif

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

    // MARK: Browse (discovery) mode
    // When set, we scan to enumerate devices of this kind WITHOUT committing any
    // to `peripherals`. A device whose kind we can't tell from its advertisement
    // is connected just far enough to read its GATT services, reported, then
    // disconnected. Browse is independent of `desired`/connect mode.
    private var browsing: SensorKind?
    // Peripherals connected solely to resolve their kind for a browse.
    private var browseProbes: Set<UUID> = []
    // Identifiers already surfaced to the browse list (dedupe advert floods).
    private var reportedBrowseIDs: Set<UUID> = []
    // Names captured at advertisement time, for browse probes (peripheral.name
    // can be nil until connected; the advert name is often richer).
    private var advertisedNames: [UUID: String] = [:]

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

    func startBrowsing(_ kind: SensorKind) {
        queue.async {
            self.browsing = kind
            self.browseProbes.removeAll()
            self.reportedBrowseIDs.removeAll()
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            } else if self.central?.state == .poweredOn {
                // Unfiltered scan (see beginScan) so non-advertising straps show.
                self.central?.scanForPeripherals(withServices: nil)
            }
        }
    }

    func stopBrowsing() {
        queue.async {
            self.browsing = nil
            // Drop any probe connections opened purely to identify a device.
            for id in self.browseProbes {
                if let p = self.central?.retrievePeripherals(withIdentifiers: [id]).first {
                    self.central?.cancelPeripheralConnection(p)
                }
            }
            self.browseProbes.removeAll()
            self.reportedBrowseIDs.removeAll()
            // Only stop the radio if we're not also mid-connect for a real ride.
            if self.desired.isEmpty { self.central?.stopScan() }
        }
    }

    /// React to the user pinning/clearing a preferred device mid-session. If a
    /// different device currently holds the kind's slot, drop it so the preferred
    /// one (or, when cleared, the next candidate) can take over.
    func applyPreferredChange(_ preferred: UUID?, for kind: SensorKind) {
        queue.async {
            guard self.desired.contains(kind), let current = self.peripherals[kind] else {
                self.rescanForMissing()
                return
            }
            if let preferred, current.identifier == preferred { return }  // already right
            if preferred == nil { return }  // no pin: keep whatever's connected
            // Pinned a different device: release the current one and rescan.
            self.central?.cancelPeripheralConnection(current)
            self.peripherals[kind] = nil
            self.kindForPeripheral[current.identifier] = nil
            self.connectingIdentifiers.remove(current.identifier)
            if kind == .trainer { self.trainerControlPoint = nil }
            self.toOwner { $0.setState(.scanning, for: kind) }
            self.beginScan()
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
            self.browsing = nil
            self.browseProbes.removeAll()
            self.reportedBrowseIDs.removeAll()
            self.advertisedNames.removeAll()
        }
    }

    private func toOwner(_ body: @escaping @MainActor (SensorHub) -> Void) {
        Task { @MainActor [weak owner] in if let owner { body(owner) } }
    }

    private func beginScan() {
        guard let central else { return }

        // Connect directly (no scan) to a known device: the user's pinned
        // preferred device wins; otherwise the last-remembered one.
        for kind in desired {
            if let id = memory.preferredIdentifier(for: kind) ?? memory.rememberedIdentifier(for: kind),
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

            // A browse probe that never finished identifying: drop it quietly.
            // It's not a ride sensor, so don't rescan for missing kinds.
            if self.browseProbes.contains(id) {
                self.browseProbes.remove(id)
                self.pendingByIdentifier[id] = nil
                if let p = self.central?.retrievePeripherals(withIdentifiers: [id]).first {
                    self.central?.cancelPeripheralConnection(p)
                }
                return
            }

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
            if !desired.isEmpty { beginScan() }
            if browsing != nil { central.scanForPeripherals(withServices: nil) }
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
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // Advert name is often set before peripheral.name resolves; keep it for
        // browse reporting and connecting-state labels.
        if let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            advertisedNames[id] = advName
        }
        let name = advertisedNames[id] ?? peripheral.name

        // Browse mode: enumerate matching devices WITHOUT committing them to a
        // connection slot. Report kind-known devices straight away; for
        // name-plausible unknowns, probe-connect just to read GATT services.
        if let browseKind = browsing {
            guard !browseProbes.contains(id),
                  !reportedBrowseIDs.contains(id) else { return }
            if advertised.contains(browseKind.serviceUUID) {
                report(id: id, name: name ?? browseKind.displayName,
                       kind: browseKind, rssi: RSSI.intValue)
            } else if let name, nameLooksLikeDesiredSensor(name) {
                // Kind unknown from the advert — probe its GATT to confirm.
                browseProbes.insert(id)
                pendingByIdentifier[id] = peripheral
                peripheral.delegate = self
                central.connect(peripheral)
                armConnectTimeout(id)
            }
            return
        }

        // Connect mode. Skip anything already connected, connecting, or pending.
        guard !connectingIdentifiers.contains(id),
              pendingByIdentifier[id] == nil,
              !peripherals.values.contains(where: { $0.identifier == id }) else { return }

        // If the user pinned a preferred device for a kind, only that exact
        // device may take the slot; ignore other candidates for that kind.
        let matchedKind = desired.first {
            peripherals[$0] == nil && advertised.contains($0.serviceUUID)
                && shouldAttach(candidate: id, forKind: $0, preferred: memory.preferredIdentifier(for: $0))
        }

        if let kind = matchedKind {
            // Advertised a desired service — connect and set the kind now.
            attach(peripheral, as: kind)
            toOwner { $0.setState(.connecting(name: name ?? kind.displayName), for: kind) }
        } else {
            // Scanning with nil surfaces every device. Only pursue ones whose
            // NAME plausibly matches something we still want (Garmin/Wahoo/HR/
            // power straps broadcast a recognizable name), so we don't dial up a
            // neighbour's headphones. Identify the kind from GATT after connect.
            // Preferred gating happens post-resolution in didDiscoverServices.
            guard let name, nameLooksLikeDesiredSensor(name) else { return }
            pendingByIdentifier[id] = peripheral
            peripheral.delegate = self
        }
        connectingIdentifiers.insert(id)
        central.connect(peripheral)
        armConnectTimeout(id)
    }

    private func report(id: UUID, name: String, kind: SensorKind, rssi: Int) {
        reportedBrowseIDs.insert(id)
        let sensor = DiscoveredSensor(id: id, name: name, kind: kind, rssi: rssi)
        toOwner { $0.reportDiscovered(sensor) }
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
        if browseProbes.contains(peripheral.identifier), let browseKind = browsing {
            // Browse probe: read only the browsed kind's service to confirm it.
            peripheral.discoverServices([browseKind.serviceUUID])
        } else if let kind = kindForPeripheral[peripheral.identifier] {
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
        let id = peripheral.identifier
        // A browse probe finished (or failed) — just forget it; the browse scan
        // keeps running to surface more devices.
        if browseProbes.contains(id) {
            browseProbes.remove(id)
            pendingByIdentifier[id] = nil
            connectingIdentifiers.remove(id)
            return
        }
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
            // Re-arm the connect watchdog: CoreBluetooth's connect() never times
            // out, and this reconnect can stall just like the initial one (the
            // Kickr's "connection timed out unexpectedly" drop). Without this a
            // stalled trainer reconnect hangs the ride at "Preparing" forever —
            // the trainer is nominally connected but its FTMS handshake, which
            // runs off characteristic discovery, never completes and nothing
            // cancels-and-retries. On timeout `armConnectTimeout` cancels + rescans.
            connectingIdentifiers.insert(peripheral.identifier)
            armConnectTimeout(peripheral.identifier)
            rescanForMissing()             // also catch it via a fresh scan
        } else {
            peripherals[kind] = nil
            toOwner { $0.setState(.disconnected, for: kind) }
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        let id = peripheral.identifier

        // Browse probe: we connected only to learn the kind. If it exposes the
        // browsed kind's service, report it to the list; then disconnect either
        // way (browsing never holds a connection).
        if browseProbes.contains(id), let browseKind = browsing {
            if services.contains(where: { $0.uuid == browseKind.serviceUUID }) {
                let name = advertisedNames[id] ?? peripheral.name ?? browseKind.displayName
                report(id: id, name: name, kind: browseKind, rssi: 0)
            }
            browseProbes.remove(id)
            pendingByIdentifier[id] = nil
            connectingIdentifiers.remove(id)
            central?.cancelPeripheralConnection(peripheral)
            return
        }

        // Resolve the kind: known from advertisement, or inferred from the
        // actual services this peripheral exposes (the pending path).
        var kind = kindForPeripheral[peripheral.identifier]
        if kind == nil, pendingByIdentifier[peripheral.identifier] != nil {
            // Match a still-open kind whose service this device exposes — and,
            // if the user pinned a preferred device for that kind, require this
            // to BE it (otherwise a non-preferred strap could grab the slot).
            let resolved = desired.first { k in
                peripherals[k] == nil && services.contains { $0.uuid == k.serviceUUID }
                    && shouldAttach(candidate: id, forKind: k,
                                    preferred: memory.preferredIdentifier(for: k))
            }
            pendingByIdentifier[peripheral.identifier] = nil
            guard let resolved else {
                // Not a device we want (or not the preferred one) — let it go.
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            attach(peripheral, as: resolved)
            memory.remember(peripheral.identifier, for: resolved)
            let name = peripheral.name ?? resolved.displayName
            toOwner { $0.setState(.connecting(name: name), for: resolved) }
            kind = resolved
        }

        if let error {
            let msg = error.localizedDescription
            toOwner { $0.note("Service discovery error: \(msg)") }
        }
        let deviceName = peripheral.name ?? "device"
        guard let kind else {
            toOwner { $0.note("Discovered services but kind unresolved for \(deviceName)") }
            return
        }
        guard let service = services.first(where: { $0.uuid == kind.serviceUUID }) else {
            let found = services.map { $0.uuid.uuidString }.joined(separator: ",")
            toOwner { $0.note("\(kind.displayName): service \(kind.serviceUUIDString) not among [\(found)]") }
            return
        }
        // Trainer needs its control point AND the Fitness Machine Status char
        // (0x2ADA): the Kickr Core 2 firmware won't return control-point
        // indications unless the client is subscribed to machine status. The
        // verified single-sensor prototype subscribed to it; the multi-sensor
        // rewrite dropped it, which is why Request Control got acked but never
        // answered. Others just need the measurement char.
        var chars = [kind.measurementUUID]
        if kind == .trainer {
            chars.append(FTMS.controlPointUUID)
            chars.append(FTMS.machineStatusUUID)
        }
        peripheral.discoverCharacteristics(chars, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let kind = kindForPeripheral[peripheral.identifier] else { return }
        // Connection fully established — disarm the connect watchdog.
        connectingIdentifiers.remove(peripheral.identifier)

        if let error {
            let msg = error.localizedDescription
            toOwner { $0.note("\(kind.displayName): characteristic discovery error: \(msg)") }
        }

        let found = (service.characteristics ?? []).map { $0.uuid.uuidString }
        for char in service.characteristics ?? [] {
            if char.uuid == kind.measurementUUID {
                peripheral.setNotifyValue(true, for: char)
            }
            if kind == .trainer, char.uuid == FTMS.controlPointUUID {
                trainerControlPoint = char
                peripheral.setNotifyValue(true, for: char)
                // Log the control point's GATT properties: it must expose
                // .write + .indicate, and a Kickr missing either would leave
                // Request Control forever "awaiting indication".
                let props = FTMS.describe(char.properties)
                toOwner { $0.note("Control point 2AD9 props: \(props)") }
            }
            // The Kickr requires an active Fitness Machine Status subscription
            // before it will answer control-point commands (see didDiscoverServices).
            if kind == .trainer, char.uuid == FTMS.machineStatusUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }

        let name = peripheral.name ?? kind.displayName
        toOwner { $0.setState(.connected(name: name), for: kind) }

        // Stop the (unfiltered) scan only once every desired kind is actually
        // connected — not merely in flight — so a slow strap isn't abandoned.
        if desired.allSatisfy({ peripherals[$0] != nil }) { central?.stopScan() }

        // FTMS handshake: write Request Control immediately after subscribing,
        // in THIS callback — byte-for-byte identical to the verified single-sensor
        // prototype (Prototype/WahooFTMSPrototype). Do NOT defer this to
        // didUpdateNotificationStateFor: that callback fires once per subscribed
        // characteristic (we subscribe to three), so deferring risks sending
        // Request Control before the machine-status subscription is active, which
        // the Kickr requires. The prototype issues all three setNotifyValue calls
        // then writes — restoring exactly that.
        if kind == .trainer {
            if let cp = trainerControlPoint {
                toOwner { $0.note("→ Request Control (handshake start)") }
                peripheral.writeValue(FTMS.requestControlCommand(), for: cp, type: .withResponse)
            } else {
                toOwner { $0.note("⚠️ Trainer control point 2AD9 not found; chars=[\(found.joined(separator: ","))]") }
            }
        }
    }

    /// Surfaces a failed control-point write (`.withResponse`): a silent write
    /// failure — rather than a missing indication — would otherwise look like a
    /// stuck handshake.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == FTMS.controlPointUUID, let error else { return }
        let msg = error.localizedDescription
        toOwner { $0.note("⚠️ Control-point write failed: \(msg)") }
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
            let reading = SensorReading(heartRateBpm: hr.heartRateBpm,
                                        rrIntervalsSec: hr.rrIntervals.isEmpty ? nil : hr.rrIntervals)
            toOwner { $0.apply(reading) }

        case (.powerMeter, _):
            guard let p = CyclingPowerMeasurement(data) else { return }
            // Route to `powerMeterW`, NOT `powerW`: the power meter is a
            // display-only secondary readout and must not overwrite the trainer's
            // power (which drives ERG, recording, and the Strava export). The
            // meter's watts read differently from the trainer's by design — see
            // `RideMetrics.powerMeterW` for why (direct crank torque vs. the
            // trainer's flywheel estimate; the drivetrain loss between them).
            let reading = SensorReading(powerMeterW: p.instantaneousPowerW)
            toOwner { $0.apply(reading) }

        default:
            break
        }
    }

    /// The FTMS request-control → start → ready chain, identical to the original.
    private func handleTrainerControlResponse(_ data: Data, peripheral: CBPeripheral) {
        guard let resp = FTMS.parseControlResponse(data) else {
            toOwner { $0.note("Trainer: unparsable control response \(Array(data))") }
            return
        }
        let requested = resp.requested
        let succeeded = resp.result.isSuccess
        let summary = "op 0x\(String(requested, radix: 16)) → \(succeeded ? "OK" : "FAIL(\(resp.result))")"
        toOwner { $0.note("Trainer response: \(summary)") }

        if succeeded, let cp = trainerControlPoint {
            if requested == FTMS.OpCode.requestControl.rawValue {
                peripheral.writeValue(FTMS.startCommand(), for: cp, type: .withResponse)
            } else if requested == FTMS.OpCode.startOrResume.rawValue {
                toOwner { $0.setTrainerReady() }
            }
        }
    }
}
