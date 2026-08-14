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

    /// How long the complication may show data read before it was rebuilt —
    /// the backstop for a reload request that watchOS declines.
    ///
    /// Not shorter than this on purpose. watchOS budgets complication refreshes
    /// per day, and asking too often gets requests dropped rather than served,
    /// which would make staleness worse rather than better. Thirty minutes is
    /// ~48 a day. Entries *within* the timeline are free, so IOB still moves
    /// every five minutes between refreshes.
    private let maxStaleness: TimeInterval = 30 * 60

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

        // `doses` is read once here and baked into every entry below, so the
        // whole timeline is a snapshot of the App Group at this instant. An
        // explicit reload is what normally refreshes it — but watchOS throttles
        // those, so the horizon doubles as the guaranteed staleness bound and
        // must stay short. It is deliberately NOT stretched to keep idle
        // reloads rare: that trade buys nothing and costs correctness.
        // Generate out to whichever is later: the end of the current activity
        // curve, or the refresh horizon. Entries inside a timeline are free, so
        // covering the full decay means IOB keeps moving correctly even if
        // every reload request in between is declined.
        let active = InsulinMath.lastActiveUntil(doses, at: now) ?? now
        let horizon = now.addingTimeInterval(maxStaleness)
        let end = max(active, horizon)

        var entries: [InsulinEntry] = []
        var t = now
        while t <= end && entries.count < 100 {
            entries.append(InsulinEntry(date: t, doses: doses))
            t = t.addingTimeInterval(sampleInterval)
        }
        if entries.isEmpty {
            entries = [InsulinEntry(date: now, doses: doses)]
        }

        // Always ask again by the horizon, even with nothing on board — a dose
        // logged on the phone must not wait on the next explicit reload.
        completion(Timeline(entries: entries, policy: .after(horizon)))
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
    private static let timerReference = "0:00:00"
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

    /// Time since the last bolus, ticking every second.
    ///
    /// `Text(timerInterval:showsHours:)` looked ideal — a constant `H:MM:SS`
    /// that the system still animates — but on a real watch face it renders
    /// without seconds, so it is not usable here whatever the signature
    /// suggests. `style: .timer` does tick seconds, at the cost of dropping the
    /// hours field under an hour: `12:34` rather than `0:12:34`. The width
    /// calibration below therefore lands exactly only once an hour has passed;
    /// before that the timer sits narrower than the line above it. Seconds were
    /// the explicit priority, so that is the trade.
    private func timerText(since date: Date) -> Text {
        Text(date, style: .timer)
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

    /// TEMPORARY DIAGNOSTIC — remove once the staleness is understood.
    ///
    /// Shows the clock time of the timeline entry currently on screen. If this
    /// tracks the real time, WidgetKit is running the provider and the fault is
    /// in the data it reads; if it sits in the past, the provider is not being
    /// run at all and the fault is the reload, not the App Group.
    private static let showsGenerationTime = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if Self.showsGenerationTime {
                Text(entry.date, style: .time)
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
            }

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
                    timerText(since: last.date)
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
