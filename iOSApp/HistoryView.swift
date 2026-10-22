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
    /// eight hours, and the long-run averages and the trends charts three
    /// months.
    ///
    /// The doctor's report covers whole days ending yesterday, so its ninety
    /// days start up to a day before a window measured back from the clock.
    private var healthWindow: Date {
        min(now.addingTimeInterval(-InsulinStats.longestWindow), Report.queryStart(now: now))
    }

    /// How far back workouts are listed in the history. Health is queried
    /// three months back for the charts, but three months of workout rows
    /// interleaved with the log would be a side effect of a chart, not a
    /// decision anyone made about this list.
    private static let listedWorkoutWindow: TimeInterval = 28 * 24 * 3600

    /// Finger-prick readings, drawn as dots on the glucose card so a meter
    /// check sits on the same chart as the sensor it was checking.
    private var fingerReadings: [LogEntry] {
        entries.filter { $0.kind == .glucose }
    }

    /// Every reading marked inside or outside by hand, with where it was —
    /// what teaches the app which places are indoors.
    private var marks: [Temperature.Mark] {
        entries.compactMap(\.mark)
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

    /// Glucose and insulin averaged over 3, 7, 30 and 90 days.
    ///
    /// Only injections feed this — a reading says nothing about how much
    /// insulin a day took. Unlike the other readouts it does not depend on
    /// `now`: every window ends at the newest glucose reading instead, so the
    /// minute ticker does not recompute it.
    private var insulinStats: InsulinStats.Summary {
        let doses: [InsulinStats.Dose] = entries.compactMap { entry in
            switch entry.kind {
            case .insulin:
                return InsulinStats.Dose(date: entry.timestamp, units: entry.amount, isBasal: false)
            case .basal:
                return InsulinStats.Dose(date: entry.timestamp, units: entry.amount, isBasal: true)
            case .glucose: return nil
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
            case .glucose:
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
                                GlucoseCard(health: health,
                                            latest: latest,
                                            readings: fingerReadings,
                                            now: now)
                            }
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
                                            EntryRow(entry: entry,
                                                     unit: health.glucoseUnitPreference,
                                                     outings: health.outings,
                                                     marks: marks)
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
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Destination.report) {
                        Image(systemName: "doc.text")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Destination.settings) {
                        Image(systemName: "gearshape")
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
                               weightUnit: health.weightUnitLabel,
                               weightPadding: health.weightAxisPadding)
                case .report:
                    ReportView(entries: entries, health: health)
                case .settings:
                    SettingsView()
                }
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(entry: entry, unit: health.glucoseUnitPreference, outings: health.outings, marks: marks)
            }
            .sheet(isPresented: $addingNew) {
                EntryEditView(entry: nil, unit: health.glucoseUnitPreference, outings: health.outings, marks: marks)
            }
            .onReceive(ticker) { instant in
                now = instant
                Task {
                    await health.refresh(since: healthWindow)
                    await WeatherBackfill.run(in: context)
                }
            }
            .task {
                await health.requestAccess()
                await health.refresh(since: healthWindow, force: true)
                await WeatherBackfill.run(in: context, force: true)
            }
        }
    }

    private func delete(_ entry: LogEntry) {
        let id = entry.id
        context.delete(entry)
        try? context.save()
        // Tell the watch, so its store — and the complication's IOB — drop it too.
        ConnectivityManager.shared.sendDelete(id: id)
        ConnectivityManager.shared.pushSnapshot()
    }

    /// Screens reachable from here. An enum rather than a bare marker so the
    /// next one is a case, not a second mechanism.
    private enum Destination: Hashable {
        case trends
        case report
        case settings
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
        let listedWorkouts = health.workouts.filter {
            $0.start > now.addingTimeInterval(-Self.listedWorkoutWindow)
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
        case .glucose: return "drop.fill"
        case .insulin: return "syringe"
        case .basal: return "syringe"
        }
    }

    var tint: Color {
        switch self {
        case .glucose: return .pink
        case .insulin: return .blue
        case .basal: return .indigo
        }
    }

    var title: String {
        switch self {
        case .glucose: return "Blood sugar"
        case .insulin: return "Insulin"
        case .basal: return "Basal"
        }
    }
}

private struct EntryRow: View {
    let entry: LogEntry
    let unit: GlucoseUnit
    let outings: [Temperature.Outing]
    let marks: [Temperature.Mark]

    private var outdoors: Bool { entry.isOutdoors(outings: outings, marks: marks) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(entry.timestamp, style: .time)
                    // The weather matters only to a reading taken in it.
                    if entry.kind == .glucose, outdoors {
                        if let temperature = entry.temperature {
                            Text("· outdoors, \(Temperature.format(celsius: temperature))")
                        } else if entry.hasLocation {
                            // Stamped, waiting on the phone's next lookup.
                            Text("· outdoors")
                            Image(systemName: "thermometer.medium")
                        } else {
                            Text("· outdoors")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.displayAmount(in: unit))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(entry.kind.tint)
                // The reading corrected for the cold or heat it was taken in,
                // beside the reading and never instead of it.
                if let adjusted = entry.adjustedAmount(outings: outings, marks: marks) {
                    Text("adjusted \(unit.format(adjusted))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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
///
/// Blood sugar is taken in the unit Health is in and stored in mmol/L, the
/// conversion happening at the edges of this view and nowhere else.
private struct EntryEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let entry: LogEntry?
    /// The unit readings are shown and typed in.
    let unit: GlucoseUnit
    /// For the outdoors switch's starting position.
    let outings: [Temperature.Outing]
    let marks: [Temperature.Mark]

    @State private var kind: EntryKind
    /// In the unit on screen — mmol/L or mg/dL for a reading, units for a dose.
    @State private var amount: Double
    @State private var timestamp: Date
    /// Starts at the badge as saved, or for a new reading at what the
    /// workouts around now say. Saving writes it down either way — it is
    /// the truth from then on — and notes whether it was moved, since only a
    /// switch moved by hand teaches the app a place.
    @State private var outdoors: Bool
    private let initialOutdoors: Bool

    init(entry: LogEntry?, unit: GlucoseUnit, outings: [Temperature.Outing], marks: [Temperature.Mark]) {
        self.entry = entry
        self.unit = unit
        self.outings = outings
        self.marks = marks
        let kind = entry?.kind ?? .glucose
        _kind = State(initialValue: kind)
        _amount = State(initialValue: Self.shown(entry?.amount ?? 0, as: kind, in: unit))
        _timestamp = State(initialValue: entry?.timestamp ?? .now)
        // A new entry has no location, so no place can speak for it.
        let initial = entry?.isOutdoors(outings: outings, marks: marks)
            ?? Temperature.isOutdoors(at: .now, marked: nil, knownIndoors: false,
                                      outings: outings, moving: nil)
        _outdoors = State(initialValue: initial)
        initialOutdoors = initial
    }

    private var isNew: Bool { entry == nil }
    private var unitLabel: String { kind == .glucose ? unit.label : "U" }

    private var stepSize: Double {
        switch kind {
        case .glucose: return unit.step
        case .insulin: return 0.5
        case .basal: return 1
        }
    }

    private var amountTitle: String {
        kind == .glucose ? "Reading (\(unit.label))" : "Amount (units)"
    }

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

                Section(amountTitle) {
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

                Section("Time") {
                    DatePicker("Time", selection: $timestamp)
                        .datePickerStyle(.graphical)
                }

                if kind == .glucose {
                    Section {
                        Toggle("Taken outdoors", isOn: $outdoors)
                        if let temperature = entry?.temperature {
                            LabeledContent("Outside air", value: Temperature.format(celsius: temperature))
                        }
                    } footer: {
                        Text("A meter reads low in the cold and high in the heat. Outdoors, the reading is shown with the outside temperature and a value adjusted for it; indoors the strip is at room temperature and nothing is adjusted. As the badge stood on the watch when the reading saved, or for a reading added here, as any workout around now suggests. What you set here is final.")
                    }
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
                        .disabled(amount <= 0)
                }
            }
            .onChange(of: kind) { _, newKind in
                // Snap to the grid of the new kind: a bolus to 0.5 U, basal to
                // whole units, a reading to the unit's own precision.
                switch newKind {
                case .insulin: amount = (amount * 2).rounded() / 2
                case .basal: amount = amount.rounded()
                case .glucose: amount = (amount / unit.step).rounded() * unit.step
                }
            }
        }
    }

    /// A stored amount as it is shown: readings converted, doses as they are.
    private static func shown(_ stored: Double, as kind: EntryKind, in unit: GlucoseUnit) -> Double {
        kind == .glucose ? unit.display(stored) : stored
    }

    private func save() {
        // Readings go back into mmol/L; doses are stored as typed.
        let value = kind == .glucose ? unit.stored(max(0, amount)) : max(0, amount)
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
        if kind == .glucose {
            saved.outdoors = outdoors
            if outdoors != initialOutdoors { saved.chosen = true }
        }
        try? context.save()
        // Mirror the change onto the watch so the complication stays correct.
        ConnectivityManager.shared.send(saved)
        ConnectivityManager.shared.pushSnapshot()
        dismiss()
    }

    private func deleteEntry() {
        if let entry {
            let id = entry.id
            context.delete(entry)
            try? context.save()
            ConnectivityManager.shared.sendDelete(id: id)
            ConnectivityManager.shared.pushSnapshot()
        }
        dismiss()
    }
}
