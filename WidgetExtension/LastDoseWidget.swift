import WidgetKit
import SwiftUI

struct LastDoseEntry: TimelineEntry {
    let date: Date
    let units: Double?
    let doseDate: Date?
}

struct LastDoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastDoseEntry {
        LastDoseEntry(date: .now, units: 3.5, doseDate: .now.addingTimeInterval(-3600))
    }

    func getSnapshot(in context: Context, completion: @escaping (LastDoseEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastDoseEntry>) -> Void) {
        // The elapsed time ticks on its own via Text(style: .timer); we just
        // refresh periodically as a fallback in case data changed elsewhere.
        let entry = currentEntry()
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> LastDoseEntry {
        if let last = SharedStore.lastInsulin() {
            return LastDoseEntry(date: .now, units: last.units, doseDate: last.date)
        }
        return LastDoseEntry(date: .now, units: nil, doseDate: nil)
    }
}

struct LastDoseView: View {
    var entry: LastDoseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Last insulin", systemImage: "syringe")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)

            if let units = entry.units, let doseDate = entry.doseDate {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(unitsString(units))
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    Text("U")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                // Full-width own line so the elapsed time never truncates.
                Text(doseDate, style: .timer)
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("No dose logged yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }

    private func unitsString(_ u: Double) -> String {
        u == u.rounded() ? String(Int(u)) : String(format: "%.1f", u)
    }
}

struct LastDoseWidget: Widget {
    let kind = "LastDoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LastDoseProvider()) { entry in
            LastDoseView(entry: entry)
        }
        .configurationDisplayName("Last Insulin")
        .description("Units and ticking time since your last insulin dose.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct InsulinWidgetBundle: WidgetBundle {
    var body: some Widget {
        LastDoseWidget()
    }
}
