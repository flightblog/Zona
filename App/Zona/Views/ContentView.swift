import SwiftUI
import ZonaKit

/// Top-level router: setup screen until we're riding, then the live ride view.
struct ContentView: View {
    @Environment(TrainerController.self) private var controller

    var body: some View {
        NavigationStack {
            Group {
                if controller.connection.isReady {
                    RideView()
                } else {
                    SetupView()
                }
            }
            .navigationTitle("Zona")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // History is reachable pre-ride; hidden while riding to avoid
                // navigating away from a live session.
                if !controller.connection.isReady {
                    ToolbarItem {
                        NavigationLink {
                            HistoryView()
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }
    }
}

#Preview("Setup") {
    ContentView()
        .environment(TrainerController())
        .environment(RideSettings())
}
