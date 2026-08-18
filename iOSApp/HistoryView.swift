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

    /// How far back Health is queried. Matches the chart's scrollable range.
    private var healthWindow: Date { now.addingTimeInterval(-2 * InsulinMath.duration) }

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
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
        let items = entries.map(HistoryItem.entry) + health.workouts.map(HistoryItem.workout)
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
