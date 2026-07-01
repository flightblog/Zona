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
        }
        .formStyle(.grouped)
    }
}

/// A live connection-status row for one sensor kind.
private struct SensorRow: View {
    @Environment(TrainerController.self) private var controller
    let kind: SensorKind

    var body: some View {
        let state = controller.sensorState(kind)
        HStack {
            Image(systemName: icon)
                .foregroundStyle(state.isConnected ? .green : .secondary)
            Text(kind.displayName)
            Spacer()
            Text(statusText(state))
                .font(.subheadline)
                .foregroundStyle(state.isConnected ? .green : .secondary)
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
