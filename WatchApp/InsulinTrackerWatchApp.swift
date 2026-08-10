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
        ConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            DialView()
                .modelContainer(container)
        }
    }
}
