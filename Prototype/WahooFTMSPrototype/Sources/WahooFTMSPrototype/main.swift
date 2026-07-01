import Foundation

// MARK: - Zona FTMS prototype
//
// Proves the risky part of the app: real-time ERG control of a Kickr Core 2
// over Bluetooth FTMS, plus live power/cadence readout, plus the FTP → Zone
// watt math. Run against your actual trainer.
//
// Usage:
//   swift run WahooFTMSPrototype [FTP] [zone]
//   e.g. swift run WahooFTMSPrototype 220 2      # hold mid-Zone-2 off a 220 W FTP
//
// Defaults: FTP 200, Zone 2. Ctrl-C to stop (sends Stop to the trainer first).

let args = CommandLine.arguments
let ftp = args.count > 1 ? (Int(args[1]) ?? 200) : 200
let zoneNumber = args.count > 2 ? (Int(args[2]) ?? 2) : 2
let zone = PowerZone(rawValue: zoneNumber) ?? .z2Endurance

let engine = ZoneEngine(ftp: ftp)
let range = engine.wattRange(for: zone)
let target = engine.steadyTarget(for: zone)

print("""
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Zona — steady Zone \(zone.rawValue) ride
 FTP: \(ftp) W
 \(zone.name): \(range.lowerBound)–\(range.upperBound) W
 ERG target (steady): \(target) W
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")

let trainer = TrainerControl()

trainer.onReady = {
    print("\n✓ In control — entering ERG mode.\n")
    trainer.setTargetPower(watts: target)
}

var lastPrint = Date.distantPast
trainer.onLiveData = { data in
    // Throttle to ~1 Hz so the console stays readable.
    guard Date().timeIntervalSince(lastPrint) > 1.0 else { return }
    lastPrint = Date()

    let power = data.instantaneousPowerW.map { "\($0) W" } ?? "—"
    let cadence = data.instantaneousCadenceRpm.map { String(format: "%.0f rpm", $0) } ?? "—"
    let speed = data.instantaneousSpeedKph.map { String(format: "%.1f km/h", $0) } ?? "—"
    let liveZone = data.instantaneousPowerW.map { engine.zone(forPower: $0).name } ?? "—"
    print("  power \(power)   cadence \(cadence)   speed \(speed)   → \(liveZone)")
}

// Graceful Ctrl-C: tell the trainer to stop before we exit.
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    print("\nStopping trainer…")
    trainer.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
sigintSource.resume()

trainer.start()
RunLoop.main.run()
