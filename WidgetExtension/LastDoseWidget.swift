import WidgetKit
import SwiftUI
import Charts
import UIKit

/// The timeline entry carries the doses rather than a pre-computed curve —
/// the view derives everything, which keeps the archived timeline small.
struct InsulinEntry: TimelineEntry {
    let date: Date
    let doses: [InsulinMath.Dose]

    /// The basal reminder, and the newest basal logged, baked in exactly like
    /// the doses: the view decides from its own `date` whether the reminder is
    /// outstanding, so a single timeline carries both sides of the flip and the
    /// complication changes on the minute without waiting on a refresh.
    let basalReminder: BasalSchedule.Reminder?
    let lastBasal: Date?
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

    /// How far ahead the basal alert's on/off instants are baked in. A day plus
    /// the window itself, so one complete cycle is always present whenever the
    /// timeline happens to be built.
    private let reminderLookahead: TimeInterval = 24 * 3600 + BasalSchedule.alertWindow

    func placeholder(in context: Context) -> InsulinEntry {
        InsulinEntry(date: .now,
                     doses: [InsulinMath.Dose(units: 3.5, date: .now.addingTimeInterval(-2400))],
                     basalReminder: nil,
                     lastBasal: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (InsulinEntry) -> Void) {
        completion(InsulinEntry(date: .now,
                                doses: SharedStore.bolusDoses(),
                                basalReminder: SharedStore.basalReminder(),
                                lastBasal: SharedStore.lastBasal()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InsulinEntry>) -> Void) {
        let doses = SharedStore.bolusDoses()
        let reminder = SharedStore.basalReminder()
        let lastBasal = SharedStore.lastBasal()
        let now = Date.now

        // `doses` is read once here and baked into every entry below, so the
        // whole timeline is a snapshot of the App Group at this instant. An
        // explicit reload is what normally refreshes it — but watchOS throttles
        // those, so the horizon doubles as the guaranteed staleness bound.
        //
        // Generate out to whichever is later: the end of the current activity
        // curve, or that horizon. Entries inside a timeline are free, so
        // covering the full decay means IOB keeps moving correctly even if
        // every reload request in between is declined.
        let active = InsulinMath.lastActiveUntil(doses, at: now) ?? now
        let horizon = now.addingTimeInterval(maxStaleness)
        let end = max(active, horizon)

        // The 100 cap is a backstop, not a real bound: the longest run of
        // samples this can produce is the 4-hour decay at 5-minute steps, 48.
        var dates: [Date] = []
        var t = now
        while t <= end && dates.count < 100 {
            dates.append(t)
            t = t.addingTimeInterval(sampleInterval)
        }
        if dates.isEmpty {
            dates = [now]
        }

        // Then the instants the basal alert turns on and off, which can be a
        // day out — well past the samples above. Added as individual dates
        // rather than by extending the sampling, which at five-minute steps
        // would be hundreds of entries to reach the same two moments.
        if let reminder {
            dates += BasalSchedule.transitions(from: now,
                                               to: now.addingTimeInterval(reminderLookahead),
                                               reminder: reminder)
        }

        // Sorted and de-duplicated: WidgetKit wants strictly increasing dates,
        // and a transition can land exactly on a sample.
        let entries = Set(dates).sorted().map {
            InsulinEntry(date: $0, doses: doses, basalReminder: reminder, lastBasal: lastBasal)
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

    /// Where the horizontal rules go — one per unit, typed so the axis knows
    /// what it is plotting.
    private static let unitGridValues: [Double] = [0, 1, 2, 3, 4, 5]

    /// IOB to one decimal: "0.9 U IOB".
    ///
    /// No padding glyphs. Figure-space padding was an attempt to keep this line
    /// a constant width, but padding with a character the font may not carry is
    /// a poor trade against the text rendering at all.
    private var iobText: String {
        "\(String(format: "%.1f", min(max(iob, 0), 99.9))) U IOB"
    }

    /// Time since the last bolus, ticking every second.
    ///
    /// `Text(timerInterval:showsHours:)` looked ideal — a constant `H:MM:SS`
    /// that the system still animates — but on a real watch face it renders
    /// without seconds, so it is not usable here whatever the signature
    /// suggests. `style: .timer` does tick seconds, at the cost of dropping the
    /// hours field under an hour: `12:34` rather than `0:12:34`.
    private func timerText(since date: Date) -> Text {
        Text(date, style: .timer)
    }

    /// A little smaller than the IOB line above it, tracking Dynamic Type.
    ///
    /// This used to be derived by measuring both strings so their widths would
    /// match exactly. That calibration is gone: it depended on text metrics at
    /// render time, and a bad measurement scales the type badly enough to push
    /// it out of a complication this small.
    private static var timerFontSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .caption2).pointSize * 0.85
    }

    private var iob: Double {
        InsulinMath.insulinOnBoard(entry.doses, at: entry.date)
    }

    private var lastBolus: InsulinMath.Dose? {
        entry.doses.last
    }

    /// The scheduled instant the basal dose is overdue from, or nil if there is
    /// nothing outstanding.
    private var basalDue: Date? {
        if case .due(let since) = BasalSchedule.status(at: entry.date,
                                                       reminder: entry.basalReminder,
                                                       lastBasal: entry.lastBasal) {
            return since
        }
        return nil
    }

    /// The scheduled time, in the watch's own 12/24-hour setting.
    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Activity projected forward over the fixed 4-hour window, using the same
    /// exponential model as the iPhone chart.
    private var forecast: [InsulinMath.ForecastPoint] {
        InsulinMath.forecast(entry.doses, from: entry.date, span: Self.span, step: 10 * 60)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let due = basalDue {
                // Everything else goes. A reminder sharing the complication
                // with the usual readout would be one more small thing among
                // small things — the point is that a glance cannot land on
                // this face and come away thinking it looked normal.
                basalAlert(due: due)
            } else if let last = lastBolus {
                // The chart takes the whole complication…
                chart
                // …and the readouts sit in the top-right corner, which the
                // curve never reaches: every dose is under 4 h old, so activity
                // has always decayed to zero by the right edge of the window.
                readouts(since: last.date)
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

    /// The basal reminder, filling the complication.
    ///
    /// Type size is doing the work here, not colour. Watch faces re-render
    /// complications in whatever mode the face is in — full colour, accented,
    /// or flat — so a bright fill is not something this view can count on,
    /// while a word at three times the height of everything that was here a
    /// moment ago reads the same in every mode, dimmed always-on included.
    /// `widgetAccentable` puts it in the accented group so tinted faces draw it
    /// bright rather than recede it into the background.
    ///
    /// The scheduled time underneath says *which* dose, which matters on the
    /// evening the dose was taken early and the alert should not have fired:
    /// seeing "due 22:00" is what tells you the app disagrees about today
    /// rather than that you have forgotten something.
    private func basalAlert(due: Date) -> some View {
        VStack(spacing: 0) {
            Text("BASAL!")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text("due \(Self.dueFormatter.string(from: due))")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.indigo)
        .widgetAccentable()
    }

    /// IOB over the elapsed time, in the top-right corner.
    ///
    /// Kept out of `body` on purpose. Nesting this inline pushed the body deep
    /// enough that the type-checker gave up on it — an explicit return type is
    /// what stops each added stack compounding the inference cost.
    ///
    /// Deliberately plain, too. Every layout trick that was once here to make
    /// the two lines exactly equal width — measured point sizes, fixedSize,
    /// padding glyphs — turned out to be a way for the text to end up clipped
    /// or unrendered.
    private func readouts(since date: Date) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Each line is pushed right by its own spacer rather than relying
            // on the stack's alignment. Text(style: .timer) is system-drawn and
            // reserves a width of its own choosing, so stack alignment alone
            // leaves it sitting left of the line above it.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(iobText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.blue)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                timerText(since: date)
                    .font(.system(size: Self.timerFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        // Alignment *inside* each text's own frame. Container alignment and
        // spacers only position the frame; when minimumScaleFactor shrinks a
        // line, or when Text(style: .timer) reserves width for a longer form
        // than it is currently showing, the glyphs sit leading within that
        // frame and no amount of outer alignment moves them.
        .multilineTextAlignment(.trailing)
        .padding(.trailing, 1)
        // Keeps the readouts in the accented group on tinted faces, rather than
        // being recoloured into the background.
        .widgetAccentable()
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
        // Faint rules give the curve a scale in both directions: every hour
        // across, every unit up. Gridlines only — there is no room for labels
        // at this size.
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.35))
            }
        }
        // Explicit values rather than .stride: the closure ignores its argument,
        // so nothing here tells Swift the axis is numeric and the stride
        // overload has no type to resolve against.
        .chartYAxis {
            AxisMarks(values: Self.unitGridValues) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.gray.opacity(0.28))
            }
        }
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
        .description("Insulin still working, with the next four hours of insulin activity — and a BASAL! reminder at your basal time.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct InsulinWidgetBundle: WidgetBundle {
    var body: some Widget {
        InsulinOnBoardWidget()
    }
}
