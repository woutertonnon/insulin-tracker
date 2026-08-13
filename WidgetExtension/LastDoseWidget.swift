import WidgetKit
import SwiftUI
import Charts

/// The timeline entry carries the doses rather than a pre-computed curve —
/// the view derives everything, which keeps the archived timeline small.
struct InsulinEntry: TimelineEntry {
    let date: Date
    let doses: [InsulinMath.Dose]
}

struct InsulinProvider: TimelineProvider {
    /// IOB and the curve move continuously, so the timeline is pre-computed in
    /// small steps rather than relying on refreshes.
    private let sampleInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> InsulinEntry {
        InsulinEntry(date: .now,
                     doses: [InsulinMath.Dose(units: 3.5, date: .now.addingTimeInterval(-2400))])
    }

    func getSnapshot(in context: Context, completion: @escaping (InsulinEntry) -> Void) {
        completion(InsulinEntry(date: .now, doses: SharedStore.bolusDoses()))
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
            entries.append(InsulinEntry(date: t, doses: doses))
            t = t.addingTimeInterval(sampleInterval)
        }
        if entries.isEmpty {
            entries = [InsulinEntry(date: now, doses: doses)]
        }

        let next = max(end, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

struct InsulinOnBoardView: View {
    var entry: InsulinEntry

    /// Fixed scales so the shape means the same thing at every glance.
    private static let unitsCeiling: Double = 5
    private static let span: TimeInterval = 4 * 3600

    private var iob: Double {
        InsulinMath.insulinOnBoard(entry.doses, at: entry.date)
    }

    private var lastBolus: InsulinMath.Dose? {
        entry.doses.last
    }

    /// Activity projected forward over the fixed 4-hour window, using the same
    /// exponential model as the iPhone chart.
    private var forecast: [InsulinMath.ForecastPoint] {
        InsulinMath.forecast(entry.doses, from: entry.date, span: Self.span, step: 10 * 60)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if lastBolus != nil {
                // The chart takes the whole complication…
                chart
                // …and IOB sits in the top-right corner, which the curve never
                // reaches: every dose is under 4 h old, so activity has always
                // decayed to zero by the right edge of the window.
                Text("\(InsulinMath.format(iob)) U IOB")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Label("No dose logged yet", systemImage: "syringe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var chart: some View {
        Chart {
            ForEach(forecast) { p in
                AreaMark(
                    x: .value("Time", p.date),
                    y: .value("Units active", min(p.units, Self.unitsCeiling))
                )
                .foregroundStyle(Color.blue.opacity(0.25))
                .interpolationMethod(.monotone)
            }
            ForEach(forecast) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Units active", min(p.units, Self.unitsCeiling))
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }
        }
        // Fixed axes: 0–5 U vertically, a 4-hour window horizontally, so the
        // curve's height and slope are comparable between glances.
        .chartYScale(domain: 0...Self.unitsCeiling)
        .chartXScale(domain: entry.date...entry.date.addingTimeInterval(Self.span))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
    }
}

struct InsulinOnBoardWidget: Widget {
    let kind = "LastDoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InsulinProvider()) { entry in
            InsulinOnBoardView(entry: entry)
        }
        .configurationDisplayName("Insulin on Board")
        .description("Insulin still working, with the next four hours of insulin activity.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct InsulinWidgetBundle: WidgetBundle {
    var body: some Widget {
        InsulinOnBoardWidget()
    }
}
