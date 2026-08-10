import SwiftUI
import SwiftData

/// Read-only history of everything logged, newest first, grouped by day.
struct HistoryView: View {
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var entries: [LogEntry]

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No entries yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Log carbs or insulin from your Apple Watch and they'll appear here.")
                    )
                } else {
                    List {
                        ForEach(groupedByDay, id: \.day) { group in
                            Section(header: Text(group.title)) {
                                ForEach(group.entries) { entry in
                                    EntryRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
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
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.displayAmount)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(entry.kind == .carbs ? .orange : .blue)
        }
        .padding(.vertical, 2)
    }
}
