import SwiftUI
import ZonaKit

/// Pre-ride: enter FTP, pick the zone to hold, see the computed watt target,
/// and connect to the trainer.
struct SetupView: View {
    @Environment(TrainerController.self) private var controller
    @Environment(RideSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Your fitness") {
                Stepper(value: $settings.ftp, in: 50...500, step: 5) {
                    LabeledContent("FTP", value: "\(settings.ftp) W")
                }
            }

            Section("Ride zone") {
                Picker("Hold zone", selection: $settings.zone) {
                    ForEach([PowerZone.z1Recovery, .z2Endurance], id: \.self) { zone in
                        Text(zone.name).tag(zone)
                    }
                }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif

                let range = settings.engine.wattRange(for: settings.zone)
                LabeledContent("Zone band", value: "\(range.lowerBound)–\(range.upperBound) W")

                VStack(alignment: .leading) {
                    LabeledContent("Steady target") {
                        Text("\(settings.target) W").font(.headline.monospacedDigit())
                    }
                    Slider(value: $settings.bandPosition, in: 0...1) {
                        Text("Position in band")
                    } minimumValueLabel: {
                        Text("easy").font(.caption2)
                    } maximumValueLabel: {
                        Text("hard").font(.caption2)
                    }
                }
            }

            Section("Heart rate") {
                Stepper(value: $settings.lthr, in: 100...220, step: 1) {
                    LabeledContent("LTHR", value: "\(settings.lthr) bpm")
                }
                Picker("Target HR zone", selection: $settings.hrZone) {
                    ForEach([HRZone.z1Recovery, .z2Endurance, .z3Tempo], id: \.self) { z in
                        Text(z.name).tag(z)
                    }
                }
                let band = settings.targetHRBand
                LabeledContent("Target band", value: "\(band.lowerBound)–\(band.upperBound) bpm")
            }

            Section("Sensors") {
                SensorRow(kind: .trainer)
                SensorRow(kind: .heartRate)
            }

            Section {
                ConnectButton()
            } footer: {
                ConnectionStatusText()
            }

            DiagnosticsSection()
        }
        .formStyle(.grouped)
    }
}

/// Collapsible event log — surfaces the BLE connection/HR diagnostics so issues
/// can be seen on-device instead of guessed at.
private struct DiagnosticsSection: View {
    @Environment(TrainerController.self) private var controller

    var body: some View {
        Section {
            DisclosureGroup("Diagnostics") {
                if controller.log.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controller.log.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// A live connection-status row for one sensor kind. Tapping it opens a picker
/// to choose which physical device to use for this kind (useful when you own
/// more than one — e.g. a Garmin strap and a WHOOP band both broadcasting HR).
private struct SensorRow: View {
    @Environment(TrainerController.self) private var controller
    let kind: SensorKind
    @State private var showingPicker = false

    var body: some View {
        let state = controller.sensorState(kind)
        let pinned = controller.preferredIdentifier(for: kind) != nil
        Button {
            showingPicker = true
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(state.isConnected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                    if pinned {
                        Label("Pinned device", systemImage: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(statusText(state))
                    .font(.subheadline)
                    .foregroundStyle(state.isConnected ? .green : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .sheet(isPresented: $showingPicker) {
            DevicePickerSheet(kind: kind)
        }
    }

    private var icon: String {
        switch kind {
        case .trainer:    return "bicycle"
        case .heartRate:  return "heart.fill"
        case .powerMeter: return "bolt.fill"
        }
    }

    private func statusText(_ state: SensorConnectionState) -> String {
        switch state {
        case .disconnected:         return "Not connected"
        case .scanning:             return "Searching…"
        case .connecting(let name): return "Connecting \(name)…"
        case .connected(let name):  return name
        }
    }
}

/// Browse-and-pin sheet: scans for devices of one kind and lets the rider pick
/// which to use. Generic over `SensorKind`, so it serves HR, trainer, or power.
private struct DevicePickerSheet: View {
    @Environment(TrainerController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let kind: SensorKind

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        controller.setPreferred(nil, for: kind)
                        dismiss()
                    } label: {
                        HStack {
                            Text("Use whatever connects first")
                            Spacer()
                            if controller.preferredIdentifier(for: kind) == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("Pin a specific device to always use it for \(kind.displayName.lowercased()), even if another is nearby.")
                }

                Section("Nearby") {
                    if controller.discovered.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(controller.discovered) { device in
                            Button {
                                controller.setPreferred(device.id, for: kind)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    if let rssi = device.rssi, rssi != 0 {
                                        Text("\(rssi) dBm")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    if controller.preferredIdentifier(for: kind) == device.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("\(kind.displayName) device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            controller.startBrowsing(kind)
        }
        .onDisappear {
            controller.stopBrowsing()
        }
    }
}

private struct ConnectButton: View {
    @Environment(TrainerController.self) private var controller

    var body: some View {
        Button {
            controller.connect()
        } label: {
            HStack {
                if controller.connection.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(controller.connection.isBusy)
    }

    private var buttonTitle: String {
        switch controller.connection {
        case .scanning:      return "Scanning…"
        case .connecting:    return "Connecting…"
        case .preparing:     return "Preparing…"
        default:             return "Connect sensors"
        }
    }
}

private struct ConnectionStatusText: View {
    @Environment(TrainerController.self) private var controller

    var body: some View {
        switch controller.connection {
        case .bluetoothUnavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .disconnected(let error?):
            Label(error, systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .connecting(let name):
            Text("Connecting to \(name)…")
        case .preparing:
            Text("Waiting for the trainer to enter ERG and your heart-rate strap to connect. The ride starts once both are ready.")
        default:
            Text("Wake the trainer (spin the cranks), put on your HR strap, and make sure no other app holds them.")
        }
    }
}

#Preview {
    NavigationStack { SetupView() }
        .environment(TrainerController())
        .environment(RideSettings())
}
