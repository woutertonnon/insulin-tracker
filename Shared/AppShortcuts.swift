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
/// to a shortcut that runs it — launches the watch app straight to the dial.
///
/// It runs on **every** press, not just the one that opens the app, and that
/// is the point: the first press opens the dial, and a press while a reading
/// is on screen flips its badge, with no touch. A press with a dose on screen
/// does nothing. It returns no dialog on purpose: with one, the Action
/// Button has been seen to run an intent twice per press, and two flips are
/// no flip.
///
/// Compiled into **both** apps, under the same name. The Action Button only
/// takes a shortcut from the library, the library is built on the iPhone,
/// and the iPhone's Shortcuts app only offers actions of apps installed on
/// the iPhone — so the iPhone app has to carry the intent for the shortcut
/// to exist at all. Run on the watch, the shortcut finds the watch app
/// implementing the same intent and runs it there, in the watch app, which
/// is where the badge is. Run on the phone it merely opens the phone app.
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
