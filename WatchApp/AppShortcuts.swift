import AppIntents

/// An App Intent that simply brings the app to the foreground. Because
/// `openAppWhenRun` is true, running it (e.g. from the Action Button via a
/// Shortcut) launches the watch app straight to the dial.
struct OpenInsulinIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Insulin Watcher"

    /// Launch the app when this intent runs.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
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
