import AppIntents
import Foundation

extension Notification.Name {
    /// Posted each time the Action Button runs the app's intent. The dial
    /// listens: with a reading on screen, a press flips its inside / outside
    /// badge.
    static let insulinActionButton = Notification.Name("insulinActionButton")
}

/// An App Intent that brings the app to the foreground. Because
/// `openAppWhenRun` is true, running it — from the Action Button, assigned
/// to this Shortcut — launches the watch app straight to the dial.
///
/// It runs on **every** press, not just the one that opens the app, and that
/// is the point: the first press opens the dial, and a press while a reading
/// is on screen flips its badge, with no touch. A press with a dose on screen
/// does nothing.
struct OpenInsulinIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Insulin"

    /// Launch the app when this intent runs.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .insulinActionButton, object: nil)
        return .result()
    }
}

/// Publishes the intent as an App Shortcut so it shows up by name in the
/// Shortcuts app and — importantly — in the Watch's Action Button → Shortcut
/// picker, with no manual shortcut-building required.
struct InsulinAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenInsulinIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Log with \(.applicationName)",
            ],
            shortTitle: "Open Insulin",
            systemImageName: "syringe"
        )
    }
}
