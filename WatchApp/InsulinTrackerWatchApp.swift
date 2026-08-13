import SwiftUI
import SwiftData

@main
struct InsulinTrackerWatchApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: LogEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        // Same store the dial writes to, so edits pushed from the iPhone land
        // here and the complication picks them up.
        ConnectivityManager.shared.modelContainer = container
        ConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            DialView()
                .modelContainer(container)
        }
    }
}
