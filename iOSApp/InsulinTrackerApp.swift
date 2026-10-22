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
        // Rows of kinds this build no longer has — carbohydrate and meal-size
        // entries from earlier versions — are dropped before anything reads.
        LogEntry.purgeRetiredKinds(in: container.mainContext)
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
