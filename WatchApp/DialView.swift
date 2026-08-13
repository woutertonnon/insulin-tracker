import SwiftUI
import SwiftData
import WatchKit
import WidgetKit

/// The single-screen logging UI.
///
/// One Digital Crown dial:
///   • crown UP   → first the five meal sizes, then exact carbs in grams
///   • crown DOWN → first rapid-acting insulin (0.5 U steps, to 20 U),
///                  then long-acting basal insulin (1 U steps, to 60 U)
///   • center (0) → neutral, shows insulin on board + time since last bolus
///
/// After you stop turning for `autoSaveDelay` seconds, the current value is
/// saved automatically with the current date/time. If you never leave the
/// neutral position, nothing is saved.
struct DialView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// Everything logged, newest first. Drives the IOB readout on the neutral
    /// screen and the data pushed to the complication.
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var allEntries: [LogEntry]

    /// Crown position as a discrete index. 0 = neutral.
    @State private var index: Double = 0
    @State private var pendingSave: Task<Void, Never>?
    @State private var justSaved: SavedInfo?

    private let autoSaveDelay: Duration = .seconds(3)

    /// Re-logging the same kind within this window edits the last entry
    /// instead of adding a new one (correcting a mis-entry).
    private let correctionWindow: TimeInterval = 15

    // MARK: - Dial ladders

    /// Crown up, steps 1…5: meal sizes, for when the carb count isn't known.
    private static let mealSizes = MealSize.allCases

    /// Crown up, steps 6+: exact carb amounts (g), finer at the low end where
    /// precision matters: 1…10 by 1, then 15/20/25/30, then by 10 up to 200.
    private static let carbLadder: [Int] =
        Array(1...10)
        + Array(stride(from: 15, through: 30, by: 5))
        + Array(stride(from: 40, through: 200, by: 10))

    private static let carbMaxSteps = mealSizes.count + carbLadder.count

    /// Crown down, steps 1…40: rapid-acting bolus in 0.5 U steps, up to 20 U.
    private static let bolusMaxSteps = 40

    /// Crown down, steps 41+: long-acting basal, restarting at 1 U in 1 U
    /// steps, up to 60 U. Basal has a different action profile and is
    /// deliberately excluded from the IOB / activity math.
    private static let basalMaxUnits = 60

    private static let insulinMaxSteps = bolusMaxSteps + basalMaxUnits

    private var step: Int { Int(index.rounded()) }

    // MARK: - Dial value decoding

    /// What a positive crown step means: a meal size, or exact grams.
    private enum CarbValue {
        case meal(MealSize)
        case grams(Int)
    }

    private func carbValue(for positiveStep: Int) -> CarbValue {
        let s = min(max(positiveStep, 1), Self.carbMaxSteps)
        if s <= Self.mealSizes.count {
            return .meal(Self.mealSizes[s - 1])
        }
        return .grams(Self.carbLadder[s - Self.mealSizes.count - 1])
    }

    /// What a negative crown step means: a rapid-acting bolus, or basal.
    private enum InsulinValue {
        case bolus(Double)
        case basal(Double)
    }

    private func insulinValue(for downSteps: Int) -> InsulinValue {
        let s = min(max(downSteps, 1), Self.insulinMaxSteps)
        if s <= Self.bolusMaxSteps {
            return .bolus(Double(s) * 0.5)
        }
        return .basal(Double(s - Self.bolusMaxSteps))
    }

    // MARK: - Derived insulin state

    private var lastBolus: LogEntry? {
        allEntries.first { $0.kind == .insulin }
    }

    /// Rapid-acting boluses only — basal is not part of the IOB model.
    private var activeDoses: [InsulinMath.Dose] {
        let cutoff = Date.now.addingTimeInterval(-InsulinMath.duration)
        return allEntries
            .filter { $0.kind == .insulin && $0.timestamp > cutoff }
            .map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
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
            from: -Double(Self.insulinMaxSteps),
            through: Double(Self.carbMaxSteps),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: index) { _, _ in
            scheduleSave()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                resetToNeutral()
                // Repair the complication if a push was missed while away.
                syncWidget()
            case .inactive, .background:
                // Wrist-down / screen-off before the 3s timer fired — commit
                // the current value now so it isn't lost.
                flushPendingSave()
            default:
                break
            }
        }
        .onAppear {
            resetToNeutral()
            syncWidget()
        }
    }

    /// Push the recent bolus history into the App Group so the complication can
    /// compute IOB itself, and nudge WidgetKit to rebuild its timeline.
    private func syncWidget(including extra: LogEntry? = nil) {
        var boluses = allEntries.filter { $0.kind == .insulin }
        // A freshly-inserted entry may not be in @Query results yet.
        if let extra, extra.kind == .insulin, !boluses.contains(where: { $0.id == extra.id }) {
            boluses.append(extra)
        }
        SharedStore.setBolusDoses(
            boluses.map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Subviews

    @ViewBuilder
    private var dialContent: some View {
        if step > 0 {
            switch carbValue(for: step) {
            case .meal(let size):
                valueView(title: "MEAL",
                          value: size.shortLabel,
                          unit: nil,
                          color: .orange,
                          systemImage: "fork.knife.circle",
                          large: false)
            case .grams(let g):
                valueView(title: "CARBS",
                          value: "\(g)",
                          unit: "g",
                          color: .orange,
                          systemImage: "fork.knife",
                          large: true)
            }
        } else if step < 0 {
            switch insulinValue(for: -step) {
            case .bolus(let units):
                valueView(title: "INSULIN",
                          value: unitsString(units),
                          unit: "U",
                          color: .blue,
                          systemImage: "syringe",
                          large: true)
            case .basal(let units):
                valueView(title: "BASAL",
                          value: unitsString(units),
                          unit: "U",
                          color: .indigo,
                          systemImage: "syringe",
                          large: true)
            }
        } else {
            neutralView
        }
    }

    private var neutralView: some View {
        // Re-evaluates every 30 s so the IOB figures stay honest while the
        // screen is up.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let doses = activeDoses
            let iob = InsulinMath.insulinOnBoard(doses, at: timeline.date)
            // Exponential model, matching the complication's chart and the
            // iPhone forecast — otherwise this screen would contradict the
            // complication sitting on the same watch face.
            let active = InsulinMath.exponentialActivity(doses, at: timeline.date)

            VStack(spacing: 6) {
                if let last = lastBolus {
                    VStack(spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(InsulinMath.format(iob))
                                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                            Text("U on board")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.blue)

                        Text("\(InsulinMath.format(active)) U active now")
                            .font(.caption2)
                            .foregroundStyle(.teal)

                        Text(last.timestamp, style: .timer)
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Text("No insulin logged yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 1)

                VStack(spacing: 2) {
                    Label("Meal / carbs", systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Label("Insulin / basal", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private func valueView(title: String,
                           value: String,
                           unit: String?,
                           color: Color,
                           systemImage: String,
                           large: Bool) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: large ? 56 : 30, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
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

    private func unitsString(_ units: Double) -> String {
        units == units.rounded() ? String(Int(units)) : String(format: "%.1f", units)
    }

    /// Save immediately if there's a dialed-but-not-yet-saved value. Used when
    /// the app is about to background so a pending entry isn't dropped.
    @MainActor
    private func flushPendingSave() {
        guard step != 0, justSaved == nil else { return }
        pendingSave?.cancel()
        save()
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

        let now = Date.now
        let kind: EntryKind
        let amount: Double

        if s > 0 {
            switch carbValue(for: s) {
            case .meal(let size):
                kind = .meal
                amount = Double(size.rawValue)
            case .grams(let g):
                kind = .carbs
                amount = Double(g)
            }
        } else {
            switch insulinValue(for: -s) {
            case .bolus(let units):
                kind = .insulin
                amount = units
            case .basal(let units):
                kind = .basal
                amount = units
            }
        }

        let entry: LogEntry
        let wasCorrection: Bool
        if let recent = allEntries.first(where: { $0.kind == kind }),
           now.timeIntervalSince(recent.timestamp) <= correctionWindow {
            // Same kind logged moments ago — treat this as a correction.
            recent.amount = amount
            recent.timestamp = now
            entry = recent
            wasCorrection = true
        } else {
            entry = LogEntry(timestamp: now, kind: kind, amount: amount)
            context.insert(entry)
            wasCorrection = false
        }

        try? context.save()
        ConnectivityManager.shared.send(entry)
        WKInterfaceDevice.current().play(.success)

        syncWidget(including: entry)

        justSaved = SavedInfo(text: (wasCorrection ? "Updated " : "Saved ") + entry.displayAmount)

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
