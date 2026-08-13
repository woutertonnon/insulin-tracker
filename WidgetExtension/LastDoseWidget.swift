import WidgetKit
import SwiftUI
import Charts
import UIKit

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

    /// The longest string the timer can show, and the IOB line it is sized to
    /// match. Both are references, not live values — that is the whole point:
    /// the timer's point size must not move when the elapsed time ticks past
    /// an hour, or when the IOB figure gains a digit.
    private static let timerReference = "9:00:00"
    private static let iobReference = "8 U IOB"

    /// Point size at which `timerReference` in monospaced digits is exactly as
    /// wide as `iobReference` in the IOB line's font.
    ///
    /// Measured from the live font metrics rather than hardcoded, so it stays
    /// correct across watch sizes and Dynamic Type settings. Monospaced-digit
    /// advance scales linearly with point size, so one probe measurement gives
    /// the ratio. Falls back to the probe size if metrics come back empty.
    /// Computed per render — two text measurements is nothing, and it keeps
    /// the value from freezing at whatever Dynamic Type was set on launch.
    private static var timerFontSize: CGFloat {
        let probeSize: CGFloat = 10

        let caption2 = UIFont.preferredFont(forTextStyle: .caption2)
        let iobFont = UIFont.systemFont(ofSize: caption2.pointSize, weight: .semibold)
        let targetWidth = (iobReference as NSString)
            .size(withAttributes: [.font: iobFont]).width

        let probeFont = UIFont.monospacedDigitSystemFont(ofSize: probeSize, weight: .regular)
        let probeWidth = (timerReference as NSString)
            .size(withAttributes: [.font: probeFont]).width

        guard probeWidth > 0, targetWidth > 0 else { return probeSize }
        return probeSize * targetWidth / probeWidth
    }

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
            if let last = lastBolus {
                // The chart takes the whole complication…
                chart
                // …and the readouts sit in the top-right corner, which the
                // curve never reaches: every dose is under 4 h old, so activity
                // has always decayed to zero by the right edge of the window.
                // Right-aligned so they hug the emptiest part of the plot.
                VStack(alignment: .trailing, spacing: -1) {
                    Text("\(InsulinMath.format(iob)) U IOB")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    // Time since the last bolus — ticks on its own. Fixed
                    // point size, so "59:00" and "1:59:00" render identically;
                    // no minimumScaleFactor here, or the text would resize
                    // itself the moment it crossed the hour.
                    Text(last.date, style: .timer)
                        .font(.system(size: Self.timerFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                // Sizes the stack to its widest line rather than to the whole
                // complication, so the timer right-aligns under the IOB label.
                .fixedSize(horizontal: true, vertical: false)
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
