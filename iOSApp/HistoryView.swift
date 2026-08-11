import SwiftUI
import SwiftData

/// History of everything logged, newest first, grouped by day.
/// Tap an entry to edit it; use ＋ to add one manually; swipe to delete.
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var entries: [LogEntry]

    @State private var editingEntry: LogEntry?
    @State private var addingNew = false

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

private struct EntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .carbs ? "fork.knife" : "syringe")
                .foregroundStyle(entry.kind == .carbs ? .orange : .blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind == .carbs ? "Carbs" : "Insulin")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.displayAmount)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.kind == .carbs ? .orange : .blue)
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
    @State private var timestamp: Date

    init(entry: LogEntry?) {
        self.entry = entry
        _kind = State(initialValue: entry?.kind ?? .carbs)
        _amount = State(initialValue: entry?.amount ?? 0)
        _timestamp = State(initialValue: entry?.timestamp ?? .now)
    }

    private var isNew: Bool { entry == nil }
    private var unitLabel: String { kind == .carbs ? "g" : "U" }
    private var stepSize: Double { kind == .carbs ? 1 : 0.5 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Label("Carbs", systemImage: "fork.knife").tag(EntryKind.carbs)
                        Label("Insulin", systemImage: "syringe").tag(EntryKind.insulin)
                    }
                    .pickerStyle(.segmented)
                }

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
                        .disabled(amount <= 0)
                }
            }
            .onChange(of: kind) { _, newKind in
                // Snap insulin to a clean 0.5 grid when switching type.
                if newKind == .insulin {
                    amount = (amount * 2).rounded() / 2
                } else {
                    amount = amount.rounded()
                }
            }
        }
    }

    private func save() {
        let value = max(0, amount)
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
