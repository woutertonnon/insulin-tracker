import SwiftUI
import SwiftData
import WatchKit
import WidgetKit

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

    private let autoSaveDelay: Duration = .seconds(3)

    /// Carb amounts (g), finer at the low end where precision matters:
    /// 1…10 by 1, then 15/20/25/30, then by 10 up to 200.
    private static let carbLadder: [Int] =
        Array(1...10)
        + Array(stride(from: 15, through: 30, by: 5))
        + Array(stride(from: 40, through: 200, by: 10))

    /// Insulin: 40 half-unit steps = up to 20 U.
    private let insulinMaxSteps = 40

    private var step: Int { Int(index.rounded()) }

    /// Carbs (g) for a positive crown step, using the fine-grained ladder.
    private func carbs(for positiveStep: Int) -> Int {
        let i = min(max(positiveStep, 1), Self.carbLadder.count)
        return Self.carbLadder[i - 1]
    }

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
            from: -Double(insulinMaxSteps),
            through: Double(Self.carbLadder.count),
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
        .onAppear {
            resetToNeutral()
            syncWidgetFromHistory()
        }
    }

    /// Seed the complication from existing data so it's populated even before
    /// the next dose is logged in this session.
    private func syncWidgetFromHistory() {
        if let last = lastInsulin {
            SharedStore.setLastInsulin(units: last.amount, date: last.timestamp)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Subviews

    @ViewBuilder
    private var dialContent: some View {
        if step > 0 {
            valueView(title: "CARBS",
                      value: "\(carbs(for: step))",
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
            entry = LogEntry(timestamp: .now, kind: .carbs, amount: Double(carbs(for: s)))
        } else {
            entry = LogEntry(timestamp: .now, kind: .insulin, amount: Double(-s) * 0.5)
        }

        context.insert(entry)
        try? context.save()
        ConnectivityManager.shared.send(entry)
        WKInterfaceDevice.current().play(.success)

        if entry.kind == .insulin {
            SharedStore.setLastInsulin(units: entry.amount, date: entry.timestamp)
        }
        WidgetCenter.shared.reloadAllTimelines()

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
