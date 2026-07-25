import SwiftUI
import ZonaKit

/// Setup-side library of rider-authored interval sessions: a small preset list
/// (e.g. "4x30/30 VO2") built ahead of time here, then triggered mid-ride from
/// `RideView`. Sessions are free-form step lists, so warmups, ramps and pyramids
/// are authorable — the form is an add/remove/reorder list of steps, with an
/// "Add repeats…" shortcut that expands the common `n × (work, rest)` shape into
/// ordinary steps.
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
    @State private var steps: [IntervalStep]
    @State private var showingRepeatBuilder = false

    init(ftp: Int, session: IntervalSession? = nil, onSave: @escaping (IntervalSession) -> Void) {
        self.ftp = ftp
        self.session = session
        self.onSave = onSave
        _name = State(initialValue: session?.name ?? "")
        // A new session starts as the classic 4×30/30 rather than empty — it's
        // still the most common thing to author, and an empty list is a worse
        // starting point than one you can edit down.
        _steps = State(initialValue: session?.steps ?? IntervalSession(
            name: "",
            repeats: 4,
            work: IntervalStep(durationSeconds: 30, zone: .z5VO2Max),
            rest: IntervalStep(durationSeconds: 30, zone: .z1Recovery)).steps)
    }

    private var engine: ZoneEngine { ZoneEngine(ftp: ftp) }

    // The editor enforces valid ranges, not the scheduler — the per-step stepper
    // pins durations to their minimum, and this gate covers what it can't: an
    // empty name, and a session with no steps at all (which would schedule
    // nothing and finish instantly).
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !steps.isEmpty
    }

    private var totalDuration: Int { steps.reduce(0) { $0 + $1.durationSeconds } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. 4x30/30 VO2", text: $name)
                }

                Section {
                    // Steps are edited in place: each row carries its own zone
                    // picker and duration stepper, and the list supports reorder
                    // and delete so a warmup/ramp/pyramid is authorable without
                    // rebuilding the session.
                    ForEach($steps) { $step in
                        StepEditorRow(step: $step, engine: engine)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        // New steps copy the last one's shape: authoring a ramp
                        // means tweaking each new row, not filling it from zero.
                        steps.append(IntervalStep(
                            durationSeconds: steps.last?.durationSeconds ?? 60,
                            zone: steps.last?.zone ?? .z2Endurance))
                    } label: {
                        Label("Add step", systemImage: "plus")
                    }

                    Button {
                        showingRepeatBuilder = true
                    } label: {
                        Label("Add repeats…", systemImage: "repeat")
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    if steps.isEmpty {
                        Text("A session needs at least one step.")
                    }
                }

                Section {
                    LabeledContent("Steps", value: "\(steps.count)")
                    LabeledContent("Total block time", value: durationText(totalDuration))
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
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
            .sheet(isPresented: $showingRepeatBuilder) {
                RepeatBuilderForm(engine: engine) { steps.append(contentsOf: $0) }
            }
        }
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func save() {
        onSave(IntervalSession(
            id: session?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            steps: steps))
        dismiss()
    }
}

/// One editable step: zone, duration, and the watts that zone resolves to at the
/// rider's FTP — the same `steadyTarget` the scheduler will drive ERG with, so
/// the preview here matches what the ride actually holds.
private struct StepEditorRow: View {
    @Binding var step: IntervalStep
    let engine: ZoneEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Zone", selection: $step.zone) {
                    ForEach(PowerZone.allCases) { z in
                        Text(z.shortName).tag(z)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer()

                Text("\(engine.steadyTarget(for: step.zone)) W")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Stepper(value: $step.durationSeconds, in: 1...3600, step: 5) {
                LabeledContent("Duration",
                               value: String(format: "%d:%02d",
                                             step.durationSeconds / 60,
                                             step.durationSeconds % 60))
                    .font(.caption)
            }
        }
    }
}

/// Builds a `repeats × (work, rest)` run of steps and appends it to the list —
/// the shape the old editor authored directly. The model no longer stores
/// repeats, so this is purely an authoring shortcut that expands into steps;
/// once added they're ordinary rows and can be edited or reordered individually.
private struct RepeatBuilderForm: View {
    @Environment(\.dismiss) private var dismiss

    let engine: ZoneEngine
    let onAdd: ([IntervalStep]) -> Void

    @State private var repeats = 4
    @State private var workDuration = 30
    @State private var workZone: PowerZone = .z5VO2Max
    @State private var restDuration = 30
    @State private var restZone: PowerZone = .z1Recovery

    var body: some View {
        NavigationStack {
            Form {
                Section("Repeats") {
                    Stepper(value: $repeats, in: 1...20) {
                        LabeledContent("Repeats", value: "\(repeats)")
                    }
                }
                stepSection(title: "Work", duration: $workDuration, zone: $workZone)
                stepSection(title: "Rest", duration: $restDuration, zone: $restZone)
                Section {
                    LabeledContent("Adds", value: "\(repeats * 2) steps")
                    LabeledContent("Total time",
                                   value: durationText(repeats * (workDuration + restDuration)))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add repeats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd((0..<repeats).flatMap { _ in
                            [IntervalStep(durationSeconds: workDuration, zone: workZone),
                             IntervalStep(durationSeconds: restDuration, zone: restZone)]
                        })
                        dismiss()
                    }
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
}

#Preview {
    NavigationStack { IntervalEditorView() }
        .environment(RideSettings())
        .environment(IntervalLibrary())
}
