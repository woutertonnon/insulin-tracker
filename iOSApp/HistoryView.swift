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

    /// Rapid-acting boluses still working at `date`. Basal is excluded — its
    /// action profile isn't described by this curve.
    private func activeDoses(at date: Date) -> [InsulinMath.Dose] {
        let cutoff = date.addingTimeInterval(-InsulinMath.duration)
        return entries
            .filter { $0.kind == .insulin && $0.timestamp > cutoff && $0.timestamp <= date }
            .map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
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
                        let doses = activeDoses(at: now)
                        if !doses.isEmpty {
                            Section("Insulin activity — next 4 hours") {
                                InsulinForecastChart(doses: doses, now: now)
                            }
                        }

                        ForEach(groupedByDay, id: \.day) { group in
                            Section(header: Text(group.title)) {
                                ForEach(group.entries) { entry in
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
            .onReceive(ticker) { now = $0 }
        }
    }

    private func delete(_ entry: LogEntry) {
        context.delete(entry)
        try? context.save()
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let entries: [LogEntry]
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.timestamp) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day,
                     title: Self.dayFormatter.string(from: day),
                     entries: grouped[day]!.sorted { $0.timestamp > $1.timestamp })
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
        if let entry {
            entry.kindRaw = kind.rawValue
            entry.amount = value
            entry.timestamp = timestamp
        } else {
            context.insert(LogEntry(timestamp: timestamp, kind: kind, amount: value))
        }
        try? context.save()
        dismiss()
    }

    private func deleteEntry() {
        if let entry {
            context.delete(entry)
            try? context.save()
        }
        dismiss()
    }
}
