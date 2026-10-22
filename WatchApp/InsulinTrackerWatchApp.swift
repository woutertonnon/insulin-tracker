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
        // Rows of kinds this build no longer has — carbohydrate and meal-size
        // entries from earlier versions — are dropped before anything reads.
        LogEntry.purgeRetiredKinds(in: container.mainContext)
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
