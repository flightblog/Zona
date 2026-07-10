import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Keeps the display awake for as long as the modified view is on screen.
///
/// A ride is glanceable, not touched — the rider watches the dials but rarely
/// taps. Left alone, iOS dims and then locks the screen after the idle timer
/// fires, and on macOS the display sleeps; either way the live metrics vanish
/// mid-workout (and a locked iPhone can get the app suspended, stalling ERG
/// updates and recording). This modifier suppresses that sleep while the view
/// lives, and restores normal power management the moment it disappears.
///
/// Platform mechanics differ:
///   - iOS: `UIApplication.isIdleTimerDisabled`. Setting it false again (or the
///     app backgrounding) restores the timer, so we always clear it on
///     disappear.
///   - macOS: there's no idle timer to flip; the *display* is what sleeps. We
///     hold a `ProcessInfo` activity assertion (`.idleDisplaySleepDisabled`)
///     and release its token on disappear. Holding the token is what keeps the
///     display awake; dropping it lets normal sleep resume.
///
/// Applied to `RideView`, which is on screen exactly when a ride is live (see
/// `ContentView` gating on `connection.isReady`), so "awake while riding" needs
/// no extra state — it's the view's own lifetime.
private struct KeepAwake: ViewModifier {
    #if os(macOS)
    // The activity token; holding it asserts "don't sleep the display", and
    // releasing it (on disappear) resumes normal power management. Optional so
    // we only ever end an assertion we actually began.
    @State private var assertion: NSObjectProtocol?
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear(perform: begin)
            .onDisappear(perform: end)
    }

    private func begin() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        assertion = ProcessInfo.processInfo.beginActivity(
            options: .idleDisplaySleepDisabled,
            reason: "Live ride in progress")
        #endif
    }

    private func end() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let assertion {
            ProcessInfo.processInfo.endActivity(assertion)
            self.assertion = nil
        }
        #endif
    }
}

extension View {
    /// Keep the display awake while this view is on screen. See `KeepAwake`.
    func keepAwake() -> some View { modifier(KeepAwake()) }
}
