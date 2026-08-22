import SwiftUI
import SwiftData
import Combine

/// History of everything logged, newest first, grouped by day, with a live
/// forecast of insulin activity on top.
/// Tap an entry to edit it; use ＋ to add one manually; swipe to delete.
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var entries: [LogEntry]

    @State private var editingEntry: LogEntry?
    @State private var addingNew = false

    /// Drives the forecast chart forward without a data change.
    @State private var now: Date = .now
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Workouts and glucose, read from Health. Kept out of SwiftData — Health
    /// stays the source of truth for both.
    @StateObject private var health = HealthStore()

    /// How far back Health is queried.
    ///
    /// Driven by the longest averaging window, not the chart's: the chart needs
    /// eight hours, the carb ratio four weeks, and the long-run averages and
    /// the trends charts three months.
    private var healthWindow: Date { now.addingTimeInterval(-InsulinStats.longestWindow) }

    /// Glucose from the carb-ratio window only.
    ///
    /// `CarbRatio` sorts whatever it is handed, and it only ever looks at meals
    /// from the last four weeks — so handing it three months of readings would
    /// sort tens of thousands of points every tick to reach the same answer.
    private var carbRatioGlucose: [CarbRatio.GlucosePoint] {
        let since = now.addingTimeInterval(-CarbRatio.window)
        return health.glucose
            .filter { $0.date > since }
            .map { .init(date: $0.date, value: $0.value) }
    }

    /// Rapid-acting boluses relevant to the chart at `date`. Basal is excluded —
    /// its action profile isn't described by this curve.
    ///
    /// The window is twice the duration of insulin action because the chart can
    /// be scrolled back four hours: a dose given six hours ago contributes
    /// nothing now, but was at its peak on the part of the curve you scroll to.
    private func chartDoses(at date: Date) -> [InsulinMath.Dose] {
        let cutoff = date.addingTimeInterval(-2 * InsulinMath.duration)
        return entries
            .filter { $0.kind == .insulin && $0.timestamp > cutoff && $0.timestamp <= date }
            .map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
    }

    /// The 7-day carb-ratio estimate.
    ///
    /// Meals logged by size carry no gram figure, so they are passed through as
    /// `mealWithoutAmount` and counted as rejected rather than guessed at.
    private var carbRatio: CarbRatio.Estimate {
        let events: [CarbRatio.Event] = entries.compactMap { entry in
            let kind: CarbRatio.Event.Kind
            switch entry.kind {
            case .insulin: kind = .bolus
            case .basal: kind = .basal
            case .carbs: kind = .carbsInGrams
            case .meal: kind = .mealWithoutAmount
            }
            return CarbRatio.Event(date: entry.timestamp, kind: kind, amount: entry.amount)
        }

        return CarbRatio.estimate(
            events: events,
            glucose: carbRatioGlucose,
            exclusions: health.workouts.map { .init(start: $0.start, end: $0.end) },
            now: now
        )
    }

    /// Glucose and insulin averaged over 3, 7, 30 and 90 days.
    ///
    /// Only injections feed this — carbs and meal sizes say nothing about how
    /// much insulin a day took. Unlike the other readouts it does not depend on
    /// `now`: every window ends at the newest glucose reading instead, so the
    /// minute ticker does not recompute it.
    private var insulinStats: InsulinStats.Summary {
        let doses: [InsulinStats.Dose] = entries.compactMap { entry in
            switch entry.kind {
            case .insulin:
                return InsulinStats.Dose(date: entry.timestamp, units: entry.amount, isBasal: false)
            case .basal:
                return InsulinStats.Dose(date: entry.timestamp, units: entry.amount, isBasal: true)
            case .carbs, .meal: return nil
            }
        }

        return InsulinStats.summarise(
            glucose: health.glucose.map { .init(date: $0.date, value: $0.value) },
            doses: doses
        )
    }

    /// One row per calendar day for the trends charts, over the same three
    /// months Health is queried for.
    private var dailySeries: [DailySeries.Day] {
        guard let anchor = health.latestGlucose?.date else { return [] }

        let doses: [DailySeries.Dose] = entries.compactMap { entry in
            switch entry.kind {
            case .insulin:
                return DailySeries.Dose(date: entry.timestamp, units: entry.amount, isBasal: false)
            case .basal:
                return DailySeries.Dose(date: entry.timestamp, units: entry.amount, isBasal: true)
            case .carbs, .meal:
                return nil
            }
        }

        return DailySeries.build(
            dayCount: Int(InsulinStats.longestWindow / (24 * 3600)),
            endingAt: anchor,
            glucose: health.glucose.map { .init(date: $0.date, value: $0.value) },
            doses: doses,
            energy: health.dailyEnergy.map { .init(day: $0.day, kilocalories: $0.kilocalories) },
            workouts: health.workouts.compactMap { workout in
                workout.kilocalories.map {
                    DailySeries.WorkoutEnergy(date: workout.start, kilocalories: $0)
                }
            },
            weights: health.weights.map { .init(date: $0.date, value: $0.value) }
        )
    }

    /// Whether anything is still working — decides if the chart is shown at all.
    private func hasActiveInsulin(_ doses: [InsulinMath.Dose], at date: Date) -> Bool {
        InsulinMath.insulinOnBoard(doses, at: date) > 0.005
    }

    var body: some View {
        NavigationStack {
            Group {
                // Health data alone is enough to have something worth showing,
                // so this cannot key off logged entries only.
                if entries.isEmpty && health.workouts.isEmpty && health.glucose.isEmpty {
                    ContentUnavailableView(
                        "No entries yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Log from your Apple Watch, or tap ＋ to add one manually.")
                    )
                } else {
                    List {
                        // Live forecast of how much insulin is working, now and
                        // over the next four hours. Only shown while something
                        // is still active; `now` ticks so it disappears on its
                        // own once the last dose runs out.
                        // Built once and reused: the visibility check and the
                        // chart need the same list, and this runs on every tick.
                        let doses = chartDoses(at: now)
                        if hasActiveInsulin(doses, at: now) {
                            Section("Insulin activity") {
                                InsulinForecastChart(doses: doses,
                                                     workouts: health.workouts,
                                                     now: now)
                            }
                        }

                        if let latest = health.latestGlucose {
                            Section("Glucose") {
                                GlucoseCard(health: health, latest: latest, now: now)
                            }
                        }

                        Section("Carb ratio · last 28 days") {
                            CarbRatioCard(estimate: carbRatio,
                                          glucoseUnit: health.glucoseUnitLabel)
                        }

                        Section("Averages") {
                            InsulinStatsCard(summary: insulinStats,
                                             glucoseUnit: health.glucoseUnitLabel)
                        }

                        ForEach(groupedByDay, id: \.day) { group in
                            Section(header: Text(group.title)) {
                                ForEach(group.items) { item in
                                    switch item {
                                    case .entry(let entry):
                                        Button {
                                            editingEntry = entry
                                        } label: {
                                            EntryRow(entry: entry)
                                        }
                                        .buttonStyle(.plain)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                delete(entry)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    case .workout(let workout):
                                        // No tap, no swipe: this row belongs to
                                        // Health and is edited there.
                                        WorkoutRow(workout: workout)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Value-based, not a destination closure: SwiftUI builds a
                    // `NavigationLink(destination:)` eagerly, which would run
                    // the ninety-day bucketing on every tick of the minute
                    // ticker whether or not anyone opened the charts.
                    NavigationLink(value: Destination.trends) {
                        Image(systemName: "chart.xyaxis.line")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .trends:
                    TrendsView(days: dailySeries,
                               glucoseUnit: health.glucoseUnitLabel,
                               weightUnit: health.weightUnitLabel)
                }
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(entry: entry)
            }
            .sheet(isPresented: $addingNew) {
                EntryEditView(entry: nil)
            }
            .onReceive(ticker) { instant in
                now = instant
                Task { await health.refresh(since: healthWindow) }
            }
            .task {
                await health.requestAccess()
                await health.refresh(since: healthWindow, force: true)
            }
        }
    }

    private func delete(_ entry: LogEntry) {
        let id = entry.id
        context.delete(entry)
        try? context.save()
        // Tell the watch, so its store — and the complication's IOB — drop it too.
        ConnectivityManager.shared.sendDelete(id: id)
        ConnectivityManager.shared.pushBolusSnapshot()
    }

    /// Screens reachable from here. An enum rather than a bare marker so the
    /// next one is a case, not a second mechanism.
    private enum Destination: Hashable {
        case trends
    }

    /// A row in the history: something logged here, or a workout read from
    /// Health. Workouts are shown but never stored — Health owns them, and
    /// copying them in would mean reconciling edits made in the Fitness app.
    private enum HistoryItem: Identifiable {
        case entry(LogEntry)
        case workout(HealthStore.Workout)

        var id: String {
            switch self {
            case .entry(let e): return "e-\(e.id.uuidString)"
            case .workout(let w): return "w-\(w.id.uuidString)"
            }
        }

        var date: Date {
            switch self {
            case .entry(let e): return e.timestamp
            case .workout(let w): return w.start
            }
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let items: [HistoryItem]
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        // Health is queried three months back for the trends charts, but the
        // list keeps the span it always had — three months of workout rows
        // interleaved with the log would be a side effect of a chart, not a
        // decision anyone made about this list.
        let listedWorkouts = health.workouts.filter {
            $0.start > now.addingTimeInterval(-CarbRatio.window)
        }
        let items = entries.map(HistoryItem.entry) + listedWorkouts.map(HistoryItem.workout)
        let grouped = Dictionary(grouping: items) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day,
                     title: Self.dayFormatter.string(from: day),
                     items: grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()
}

/// Icon, colour and title for each kind, shared by the row and the editor.
extension EntryKind {
    var symbolName: String {
        switch self {
        case .carbs: return "fork.knife"
        case .meal: return "fork.knife.circle"
        case .insulin: return "syringe"
        case .basal: return "syringe"
        }
    }

    var tint: Color {
        switch self {
        case .carbs, .meal: return .orange
        case .insulin: return .blue
        case .basal: return .indigo
        }
    }

    var title: String {
        switch self {
        case .carbs: return "Carbs"
        case .meal: return "Meal"
        case .insulin: return "Insulin"
        case .basal: return "Basal"
        }
    }
}

private struct EntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.displayAmount)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.kind.tint)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A workout read from Health. Styled like an entry row but visibly not one —
/// no chevron, since there is nothing here to open.
private struct WorkoutRow: View {
    let workout: HealthStore.Workout

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.run")
                .foregroundStyle(.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(workout.start, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(workout.durationText)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.teal)
        }
        .padding(.vertical, 2)
    }
}

/// Add (entry == nil) or edit an existing entry: kind, amount, and time.
private struct EntryEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let entry: LogEntry?

    @State private var kind: EntryKind
    @State private var amount: Double
    @State private var mealSize: MealSize
    @State private var timestamp: Date

    init(entry: LogEntry?) {
        self.entry = entry
        _kind = State(initialValue: entry?.kind ?? .carbs)
        _amount = State(initialValue: entry?.amount ?? 0)
        _mealSize = State(initialValue: entry?.mealSize ?? .medium)
        _timestamp = State(initialValue: entry?.timestamp ?? .now)
    }

    private var isNew: Bool { entry == nil }
    private var unitLabel: String { kind == .carbs ? "g" : "U" }
    private var stepSize: Double { kind == .insulin ? 0.5 : 1 }

    /// A meal has no number attached — only a size.
    private var isMeal: Bool { kind == .meal }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(EntryKind.allCases, id: \.self) { k in
                            Label(k.title, systemImage: k.symbolName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if isMeal {
                    Section("Meal size") {
                        Picker("Size", selection: $mealSize) {
                            ForEach(MealSize.allCases) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } else {
                    Section("Amount (\(kind == .carbs ? "grams" : "units"))") {
                        HStack {
                            TextField("Amount", value: $amount, format: .number)
                                .keyboardType(.decimalPad)
                            Text(unitLabel)
                                .foregroundStyle(.secondary)
                        }
                        Stepper(value: $amount, in: 0...1000, step: stepSize) {
                            Text("Adjust")
                        }
                    }
                }

                Section("Time") {
                    DatePicker("Time", selection: $timestamp)
                        .datePickerStyle(.graphical)
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            deleteEntry()
                        } label: {
                            Label("Delete Entry", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Entry" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isMeal && amount <= 0)
                }
            }
            .onChange(of: kind) { _, newKind in
                // Snap bolus insulin to a clean 0.5 grid when switching type;
                // carbs and basal are whole numbers.
                switch newKind {
                case .insulin: amount = (amount * 2).rounded() / 2
                case .carbs, .basal: amount = amount.rounded()
                case .meal: break
                }
            }
        }
    }

    private func save() {
        // For meals the stored amount is the size ordinal, not a quantity.
        let value = isMeal ? Double(mealSize.rawValue) : max(0, amount)
        let saved: LogEntry
        if let entry {
            entry.kindRaw = kind.rawValue
            entry.amount = value
            entry.timestamp = timestamp
            saved = entry
        } else {
            saved = LogEntry(timestamp: timestamp, kind: kind, amount: value)
            context.insert(saved)
        }
        try? context.save()
        // Mirror the change onto the watch so the complication stays correct.
        ConnectivityManager.shared.send(saved)
        ConnectivityManager.shared.pushBolusSnapshot()
        dismiss()
    }

    private func deleteEntry() {
        if let entry {
            let id = entry.id
            context.delete(entry)
            try? context.save()
            ConnectivityManager.shared.sendDelete(id: id)
            ConnectivityManager.shared.pushBolusSnapshot()
        }
        dismiss()
    }
}
