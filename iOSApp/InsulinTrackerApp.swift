import SwiftUI
import SwiftData

@main
struct InsulinTrackerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: LogEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        // Wire up WatchConnectivity so entries pushed from the watch land in
        // this same local store.
        ConnectivityManager.shared.modelContainer = container
        ConnectivityManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HistoryView()
                .modelContainer(container)
        }
    }
}
