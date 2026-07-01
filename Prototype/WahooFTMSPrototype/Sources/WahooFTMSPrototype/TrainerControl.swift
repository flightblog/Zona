import CoreBluetooth
import Foundation

/// Drives a single FTMS trainer (Kickr Core 2) over Bluetooth LE:
/// scan → connect → request control → ERG set-watts → stream live data.
///
/// This class is the prototype of the app's control layer. In the SwiftUI app
/// it becomes an `@Observable` published to the UI; here it prints to stdout.
final class TrainerControl: NSObject {
    // Callbacks kept simple for the CLI prototype.
    var onLiveData: ((IndoorBikeData) -> Void)?
    var onReady: (() -> Void)?
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager!
    private var trainer: CBPeripheral?
    private var controlPoint: CBCharacteristic?
    private var bikeData: CBCharacteristic?

    private let queue = DispatchQueue(label: "ftms.central")

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func log(_ s: String) {
        onLog?(s) ?? print(s)
    }

    // MARK: Commands (safe to call after onReady fires)

    func setTargetPower(watts: Int) {
        guard let cp = controlPoint, let t = trainer else { return }
        log("→ Set Target Power: \(watts) W")
        t.writeValue(FTMS.setTargetPowerCommand(watts: watts), for: cp, type: .withResponse)
    }

    func stop() {
        guard let cp = controlPoint, let t = trainer else { return }
        log("→ Stop")
        t.writeValue(FTMS.stopCommand(), for: cp, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension TrainerControl: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth ready. Scanning for FTMS trainers…")
            central.scanForPeripherals(withServices: [FTMS.service])
        case .unauthorized:
            log("⚠️  Bluetooth permission denied. Grant it in System Settings › Privacy › Bluetooth.")
        case .poweredOff:
            log("⚠️  Bluetooth is off.")
        default:
            log("Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        log("Found trainer: \(name) (RSSI \(RSSI)). Connecting…")
        central.stopScan()
        trainer = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "trainer"). Discovering services…")
        peripheral.discoverServices([FTMS.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
    }
}

// MARK: - CBPeripheralDelegate

extension TrainerControl: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == FTMS.service }) else {
            log("⚠️  FTMS service not found on this device.")
            return
        }
        peripheral.discoverCharacteristics(
            [FTMS.controlPoint, FTMS.indoorBikeData, FTMS.machineStatus],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case FTMS.controlPoint:
                controlPoint = char
                peripheral.setNotifyValue(true, for: char) // indications for command results
            case FTMS.indoorBikeData:
                bikeData = char
                peripheral.setNotifyValue(true, for: char)
            case FTMS.machineStatus:
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        // Take control of the machine before issuing ERG commands.
        if let cp = controlPoint {
            log("→ Request Control")
            peripheral.writeValue(FTMS.requestControlCommand(), for: cp, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case FTMS.indoorBikeData:
            if let parsed = IndoorBikeData(data) { onLiveData?(parsed) }

        case FTMS.controlPoint:
            guard let resp = FTMS.parseControlResponse(data) else { return }
            let opName = FTMS.OpCode(rawValue: resp.requested)
                .map { "\($0)" } ?? String(format: "0x%02X", resp.requested)
            if resp.result.isSuccess {
                log("✓ \(opName) acknowledged")
                // Once Request Control succeeds, start the session, then signal ready.
                if resp.requested == FTMS.OpCode.requestControl.rawValue {
                    peripheral.writeValue(FTMS.startCommand(), for: characteristic, type: .withResponse)
                }
                if resp.requested == FTMS.OpCode.startOrResume.rawValue {
                    onReady?()
                }
            } else {
                log("✗ \(opName) failed: \(resp.result)")
            }

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { log("Write error: \(error.localizedDescription)") }
    }
}
