import WidgetKit
import SwiftUI

struct InsulinEntry: TimelineEntry {
    let date: Date
    /// Insulin still working, summed across every stacked bolus.
    let iob: Double
    /// Units currently acting — 1 U at its peak reads 1.0.
    let activity: Double
    /// The most recent bolus, for the ticking "time since" line.
    let lastBolus: InsulinMath.Dose?
}

struct InsulinProvider: TimelineProvider {
    /// IOB moves continuously, so the timeline is pre-computed in small steps
    /// rather than relying on refreshes.
    private let sampleInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> InsulinEntry {
        let dose = InsulinMath.Dose(units: 3.5, date: .now.addingTimeInterval(-3600))
        return entry(at: .now, doses: [dose])
    }

    func getSnapshot(in context: Context, completion: @escaping (InsulinEntry) -> Void) {
        completion(entry(at: .now, doses: SharedStore.bolusDoses()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InsulinEntry>) -> Void) {
        let doses = SharedStore.bolusDoses()
        let now = Date.now

        // Cover the decay of everything still on board; if nothing is active,
        // one entry is enough until the next dose triggers a reload.
        let end = InsulinMath.lastActiveUntil(doses, at: now) ?? now
        var entries: [InsulinEntry] = []
        var t = now
        while t <= end && entries.count < 100 {
            entries.append(entry(at: t, doses: doses))
            t = t.addingTimeInterval(sampleInterval)
        }
        if entries.isEmpty {
            entries = [entry(at: now, doses: doses)]
        }

        let next = max(end, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private func entry(at date: Date, doses: [InsulinMath.Dose]) -> InsulinEntry {
        InsulinEntry(
            date: date,
            iob: InsulinMath.insulinOnBoard(doses, at: date),
            activity: InsulinMath.activity(doses, at: date),
            lastBolus: doses.last
        )
    }
}

struct InsulinOnBoardView: View {
    var entry: InsulinEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let last = entry.lastBolus {
                // Insulin on board — the headline number, stacked doses included.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "syringe")
                        .font(.caption2)
                    Text(InsulinMath.format(entry.iob))
                        .font(.system(size: 21, weight: .bold, design: .rounded).monospacedDigit())
                    Text("U on board")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                // Insulin intensity: how many units are actually working now.
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("\(InsulinMath.format(entry.activity)) U active")
                        .font(.caption2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.teal)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                // Last dose + ticking time since, on its own line so the timer
                // never truncates.
                HStack(spacing: 3) {
                    Text("\(InsulinMath.format(last.units)) U")
                    Text("·")
                    Text(last.date, style: .timer)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } else {
                Label("Insulin", systemImage: "syringe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("No dose logged yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct InsulinOnBoardWidget: Widget {
    let kind = "LastDoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InsulinProvider()) { entry in
            InsulinOnBoardView(entry: entry)
        }
        .configurationDisplayName("Insulin on Board")
        .description("Insulin still working from all recent doses, how much is active right now, and time since the last one.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct InsulinWidgetBundle: WidgetBundle {
    var body: some Widget {
        InsulinOnBoardWidget()
    }
}
