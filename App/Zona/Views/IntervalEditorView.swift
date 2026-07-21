import SwiftUI
import ZonaKit

/// Setup-side library of rider-authored interval sessions: a small preset list
/// (e.g. "4x30/30 VO2") built ahead of time here, then triggered mid-ride from
/// `RideView`. v1 only supports the uniform `repeats × (work, rest)` shape, so
/// the editor is just a reps stepper and two zone/duration rows.
struct IntervalEditorView: View {
    @Environment(RideSettings.self) private var settings
    @Environment(IntervalLibrary.self) private var library

    @State private var editingSession: IntervalSession?
    @State private var showingNewSession = false

    var body: some View {
        List {
            if library.sessions.isEmpty {
                ContentUnavailableView(
                    "No interval sessions",
                    systemImage: "timer",
                    description: Text("Add a session to trigger mid-ride, typically near the end of a Z2 ride."))
            } else {
                ForEach(library.sessions) { session in
                    Button {
                        editingSession = session
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name).font(.headline)
                            Text(session.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("Interval sessions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSession = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSession) {
            IntervalSessionForm(ftp: settings.ftp) { library.add($0) }
        }
        .sheet(item: $editingSession) { session in
            IntervalSessionForm(ftp: settings.ftp, session: session) { library.update($0) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            library.remove(id: library.sessions[index].id)
        }
    }
}

/// Add/edit form for one session. Shared by both the "+" (new) and row-tap
/// (edit) entry points — `session` is nil for a new one, in which case a fresh
/// id is minted on save.
private struct IntervalSessionForm: View {
    @Environment(\.dismiss) private var dismiss

    let ftp: Int
    let session: IntervalSession?
    let onSave: (IntervalSession) -> Void

    @State private var name: String
    @State private var repeats: Int
    @State private var workDuration: Int
    @State private var workZone: PowerZone
    @State private var restDuration: Int
    @State private var restZone: PowerZone

    init(ftp: Int, session: IntervalSession? = nil, onSave: @escaping (IntervalSession) -> Void) {
        self.ftp = ftp
        self.session = session
        self.onSave = onSave
        _name = State(initialValue: session?.name ?? "")
        _repeats = State(initialValue: session?.repeats ?? 4)
        _workDuration = State(initialValue: session?.work.durationSeconds ?? 30)
        _workZone = State(initialValue: session?.work.zone ?? .z5VO2Max)
        _restDuration = State(initialValue: session?.rest.durationSeconds ?? 30)
        _restZone = State(initialValue: session?.rest.zone ?? .z1Recovery)
    }

    private var engine: ZoneEngine { ZoneEngine(ftp: ftp) }

    // The editor enforces valid ranges, not the scheduler — steppers below pin
    // repeats/durations to their minimums, and this gate covers the one field a
    // stepper can't (an empty name).
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var totalDuration: Int { repeats * (workDuration + restDuration) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. 4x30/30 VO2", text: $name)
                }

                Section("Repeats") {
                    Stepper(value: $repeats, in: 1...20) {
                        LabeledContent("Repeats", value: "\(repeats)")
                    }
                }

                stepSection(title: "Work", duration: $workDuration, zone: $workZone)
                stepSection(title: "Rest", duration: $restDuration, zone: $restZone)

                Section {
                    LabeledContent("Total block time", value: durationText(totalDuration))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(session == nil ? "New session" : "Edit session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
        }
    }

    private func stepSection(title: String, duration: Binding<Int>, zone: Binding<PowerZone>) -> some View {
        Section(title) {
            Picker("Zone", selection: zone) {
                ForEach(PowerZone.allCases) { z in
                    Text(z.name).tag(z)
                }
            }
            Stepper(value: duration, in: 1...3600, step: 5) {
                LabeledContent("Duration", value: durationText(duration.wrappedValue))
            }
            LabeledContent("Watts", value: "\(engine.steadyTarget(for: zone.wrappedValue)) W")
        }
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func save() {
        let newSession = IntervalSession(
            id: session?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            repeats: repeats,
            work: IntervalStep(durationSeconds: workDuration, zone: workZone),
            rest: IntervalStep(durationSeconds: restDuration, zone: restZone))
        onSave(newSession)
        dismiss()
    }
}

#Preview {
    NavigationStack { IntervalEditorView() }
        .environment(RideSettings())
        .environment(IntervalLibrary())
}
