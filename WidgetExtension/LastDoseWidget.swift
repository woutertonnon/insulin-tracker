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

        // Cover the decay of everything still on board — and at least two hours
        // regardless, because the elapsed-time readout is drawn per entry now
        // rather than ticking on its own, so it would otherwise sit frozen
        // whenever no insulin is active.
        let active = InsulinMath.lastActiveUntil(doses, at: now) ?? now
        let end = max(active, now.addingTimeInterval(2 * 3600))

        var entries: [InsulinEntry] = []
        var t = now
        while t <= end && entries.count < 100 {
            entries.append(InsulinEntry(date: t, doses: doses))
            t = t.addingTimeInterval(sampleInterval)
        }
        if entries.isEmpty {
            entries = [InsulinEntry(date: now, doses: doses)]
        }

        completion(Timeline(entries: entries, policy: .after(end)))
    }
}

struct InsulinOnBoardView: View {
    var entry: InsulinEntry

    /// Fixed scales so the shape means the same thing at every glance.
    private static let unitsCeiling: Double = 5
    private static let span: TimeInterval = 4 * 3600

    /// Reference strings for the width calibration. Both lines are rendered at
    /// a **fixed character count** — the IOB figure in a padded 4-wide field,
    /// the elapsed time as zero-padded `HH:MM` — so these are not merely
    /// representative, they are exactly as wide as what gets drawn, always.
    /// That is what lets one calibration hold for every value.
    private static let timerReference = "00:00"
    private static let iobReference = "00.0 U IOB"

    /// Figure space: same advance as a digit, so padding with it keeps the
    /// field width constant without drawing anything.
    private static let figureSpace = "\u{2007}"

    /// IOB to one decimal in a fixed 4-character field: "␣0.9", "12.5".
    private var iobText: String {
        let value = String(format: "%.1f", min(max(iob, 0), 99.9))
        let pad = String(repeating: Self.figureSpace, count: max(0, 4 - value.count))
        return "\(pad)\(value) U IOB"
    }

    /// Time since the last bolus as fixed-width `HH:MM`.
    ///
    /// Rendered rather than using `Text(style: .timer)`: the system timer's
    /// string changes length as it passes an hour, and its content cannot be
    /// observed, so nothing can ever be sized to match it. This updates with
    /// the timeline instead — every five minutes rather than every second.
    private func elapsedText(since date: Date) -> String {
        let seconds = max(0, Int(entry.date.timeIntervalSince(date)))
        let hours = min(seconds / 3600, 99)
        let minutes = (seconds % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

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

        // Must mirror the IOB line exactly, monospaced digits included, or the
        // measurement describes a string that is never actually drawn.
        let caption2 = UIFont.preferredFont(forTextStyle: .caption2)
        let iobFont = UIFont.monospacedDigitSystemFont(ofSize: caption2.pointSize,
                                                       weight: .semibold)
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
                    // Monospaced digits throughout: with proportional figures a
                    // 1 is narrower than an 8, which alone would break the
                    // width match between these two lines.
                    Text(iobText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    // Sized once so this spans the line above exactly. No
                    // minimumScaleFactor — both strings are fixed-width, so
                    // there is nothing left to scale away from.
                    Text(elapsedText(since: last.date))
                        .font(.system(size: Self.timerFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
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
