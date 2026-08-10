import SwiftUI
import SwiftData
import WatchKit

/// The single-screen logging UI.
///
/// One Digital Crown dial:
///   • crown UP   → carbs, in steps of 10 g  (10, 20, 30, …)
///   • crown DOWN → insulin, in steps of 0.5 U (0.5, 1.0, 1.5, …)
///   • center (0) → neutral, shows time since last insulin
///
/// After you stop turning for `autoSaveDelay` seconds, the current value is
/// saved automatically with the current date/time. If you never leave the
/// neutral position, nothing is saved.
struct DialView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// Most recent insulin entry, used for the "time since last insulin" timer.
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var allEntries: [LogEntry]

    /// Crown position as a discrete index. 0 = neutral.
    @State private var index: Double = 0
    @State private var pendingSave: Task<Void, Never>?
    @State private var justSaved: SavedInfo?

    private let autoSaveDelay: Duration = .seconds(5)

    // Dial range: up to 400 g carbs (40 * 10) and 20 U insulin (40 * 0.5).
    private let maxSteps = 40.0

    private var step: Int { Int(index.rounded()) }

    private var lastInsulin: LogEntry? {
        allEntries.first { $0.kind == .insulin }
    }

    var body: some View {
        ZStack {
            if let saved = justSaved {
                savedView(saved)
            } else {
                dialContent
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $index,
            from: -maxSteps,
            through: maxSteps,
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: index) { _, _ in
            scheduleSave()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resetToNeutral() }
        }
        .onAppear { resetToNeutral() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var dialContent: some View {
        if step > 0 {
            valueView(title: "CARBS",
                      value: "\(step * 10)",
                      unit: "g",
                      color: .orange,
                      systemImage: "fork.knife")
        } else if step < 0 {
            valueView(title: "INSULIN",
                      value: insulinString(-step),
                      unit: "U",
                      color: .blue,
                      systemImage: "syringe")
        } else {
            neutralView
        }
    }

    private var neutralView: some View {
        VStack(spacing: 8) {
            if let last = lastInsulin {
                VStack(spacing: 2) {
                    Text("Last insulin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(last.timestamp, style: .timer)
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                        .foregroundStyle(.blue)
                    Text("\(last.displayAmount) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No insulin logged yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            VStack(spacing: 2) {
                Label("Carbs", systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Label("Insulin", systemImage: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func valueView(title: String,
                           value: String,
                           unit: String,
                           color: Color,
                           systemImage: String) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text("saving in a moment…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
    }

    private func savedView(_ info: SavedInfo) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(info.text)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Logic

    private func insulinString(_ steps: Int) -> String {
        let units = Double(steps) * 0.5
        return units == units.rounded() ? String(Int(units)) : String(format: "%.1f", units)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard step != 0 else { return }
        pendingSave = Task {
            try? await Task.sleep(for: autoSaveDelay)
            if Task.isCancelled { return }
            await MainActor.run { save() }
        }
    }

    @MainActor
    private func save() {
        let s = step
        guard s != 0 else { return }

        let entry: LogEntry
        if s > 0 {
            entry = LogEntry(timestamp: .now, kind: .carbs, amount: Double(s * 10))
        } else {
            entry = LogEntry(timestamp: .now, kind: .insulin, amount: Double(-s) * 0.5)
        }

        context.insert(entry)
        try? context.save()
        ConnectivityManager.shared.send(entry)
        WKInterfaceDevice.current().play(.success)

        justSaved = SavedInfo(text: "Saved \(entry.displayAmount)")

        // Show confirmation briefly, then return to neutral.
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            await MainActor.run { resetToNeutral() }
        }
    }

    private func resetToNeutral() {
        pendingSave?.cancel()
        pendingSave = nil
        justSaved = nil
        index = 0
    }
}

private struct SavedInfo: Equatable {
    let text: String
}
