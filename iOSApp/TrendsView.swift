import SwiftUI
import Charts
import UIKit

/// Six day-by-day charts stacked on one shared, scrolling time axis.
///
/// Stacked rather than overlaid because the six quantities share no scale, and
/// small multiples on a common axis are the honest way to read one series
/// against another: a training block and the notch it puts in insulin a day
/// later line up vertically, without pretending kilocalories and millimoles
/// belong on the same y.
///
/// Three pieces of state are shared by every chart, which is the whole trick —
/// scroll position, zoom, and the selected day. Each chart reads all three, so
/// dragging, pinching or tapping any one of them moves all six together and
/// the columns stay aligned down the screen.
///
/// Nothing here is a dosing instruction. It describes what already happened.
struct TrendsView: View {
    let days: [DailySeries.Day]
    let glucoseUnit: String
    let weightUnit: String
    /// Three kilograms in the unit weight is displayed in — the pad either side
    /// of the weight range, so a two-kilo drift is a visible slope rather than
    /// a flat line across an axis scaled to include zero.
    let weightPadding: Double

    /// Shared by every chart: this is what makes them move as one.
    @State private var scrollX = Date.distantPast
    @State private var visibleDays: Double = Self.defaultVisibleDays
    @State private var selectedDate: Date?

    /// `visibleDays` when the current pinch began, so the gesture scales from
    /// where it started rather than compounding every frame.
    @State private var zoomAnchor: Double?
    @State private var didPosition = false

    /// Four weeks reads as a block of training or a run of missed basal rather
    /// than as individual days.
    private static let defaultVisibleDays: Double = 28
    /// Closest zoom. Below about three days the charts are one bar wide.
    private static let minimumVisibleDays: Double = 3

    private static let secondsPerDay: TimeInterval = 24 * 3600

    var body: some View {
        Group {
            if plottableDays.isEmpty {
                ContentUnavailableView(
                    "Nothing to plot yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Needs glucose in Health and some insulin logged.")
                )
            } else {
                VStack(spacing: 0) {
                    selectionHeader
                    Divider()
                    charts
                }
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var charts: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                glucosePanel
                insulinPanel
                ratioPanel
                energyPanel
                weightPanel
                a1cPanel
                footnotes
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Simultaneous, not exclusive: the charts own the one-finger drag for
        // scrolling, and this only ever sees the two-finger pinch.
        .simultaneousGesture(zoom)
        .onAppear(perform: positionAtToday)
    }

    // MARK: - Selection

    /// Always present, so the layout does not jump when a day is picked and the
    /// gesture is discoverable before anyone tries it.
    private var selectionHeader: some View {
        HStack(spacing: 6) {
            if let selectedDay {
                Text(Self.dayFormatter.string(from: selectedDay.date))
                    .font(.subheadline.weight(.semibold))
                if selectedDay.isPartial {
                    Text("· today, still running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    selectedDate = nil
                } label: {
                    Text("Clear").font(.caption)
                }
            } else {
                Image(systemName: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tap any chart to read every series on one day. Pinch to zoom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
        .background(.bar)
    }

    /// The day under the tap. Charts hands back wherever on the axis the touch
    /// landed, not a data point, so it is snapped to the day containing it.
    private var selectedDay: DailySeries.Day? {
        guard let selectedDate else { return nil }
        let calendar = Calendar.current
        return days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    // MARK: - Zoom

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomAnchor ?? visibleDays
                zoomAnchor = base
                setVisibleDays(base / max(Double(value.magnification), 0.01))
            }
            .onEnded { _ in zoomAnchor = nil }
    }

    /// Zoom about the middle of what is on screen. Changing the visible length
    /// alone would pin the left edge and slide everything you were looking at
    /// off to the right.
    private func setVisibleDays(_ proposed: Double) {
        let ceiling = max(Self.minimumVisibleDays, Double(days.count))
        let clamped = min(max(proposed, Self.minimumVisibleDays), ceiling)
        guard clamped != visibleDays else { return }

        let midpoint = scrollX.addingTimeInterval(visibleDays * Self.secondsPerDay / 2)
        visibleDays = clamped
        scrollX = clampedScroll(midpoint.addingTimeInterval(-clamped * Self.secondsPerDay / 2))
    }

    /// Keep the leading edge inside the plotted range, so zooming out at the
    /// end of the series does not leave the charts parked past their own data.
    private func clampedScroll(_ proposed: Date) -> Date {
        let latest = domain.upperBound.addingTimeInterval(-visibleLength)
        if proposed < domain.lowerBound { return domain.lowerBound }
        if proposed > latest { return max(domain.lowerBound, latest) }
        return proposed
    }

    /// Start at the most recent day rather than three months ago.
    private func positionAtToday() {
        guard !didPosition, days.last != nil else { return }
        didPosition = true
        scrollX = clampedScroll(domain.upperBound.addingTimeInterval(-visibleLength))
    }

    // MARK: - The panels

    private var glucosePanel: some View {
        panel("Average glucose",
              unit: glucoseUnit,
              value: { $0.meanGlucose },
              format: { InsulinStats.formatGlucose($0, unit: glucoseUnit) },
              tint: Self.glucose) {
            ForEach(points({ $0.meanGlucose })) { point in
                LineMark(x: .value("Day", point.date), y: .value("Glucose", point.value))
                    .foregroundStyle(Self.glucose)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
    }

    /// Split basal from bolus inside the total. The two are logged by different
    /// habits, and a day the basal never got entered reads as a notch in the
    /// dark half rather than as a day of genuinely less insulin.
    private var insulinPanel: some View {
        panel("Total insulin",
              unit: "U",
              value: { $0.totalInsulin },
              format: { InsulinStats.formatUnits($0) },
              tint: Self.bolus,
              marksPoint: false) {
            ForEach(insulinBars) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day),
                        y: .value("Units", bar.units))
                    .foregroundStyle(by: .value("Kind", bar.kind))
            }
        }
        .chartForegroundStyleScale([
            "Basal": Self.basal,
            "Bolus": Self.bolus,
        ])
        .chartLegend(position: .top, alignment: .leading, spacing: 2)
    }

    private var ratioPanel: some View {
        panel("Insulin ÷ glucose",
              unit: "U/day per \(glucoseUnit)",
              value: { $0.insulinPerGlucose },
              format: { InsulinStats.formatIndex($0, unit: glucoseUnit) },
              tint: Self.index) {
            ForEach(points({ $0.insulinPerGlucose })) { point in
                LineMark(x: .value("Day", point.date), y: .value("Index", point.value))
                    .foregroundStyle(Self.index)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
    }

    /// Workout energy drawn dark inside the day's total movement, rather than
    /// instead of it — the book counts cleaning and shopping as physical
    /// activity too, and both halves move insulin sensitivity.
    private var energyPanel: some View {
        panel("Exercise calories",
              unit: "kcal",
              value: { $0.activeEnergy },
              format: { String(Int($0.rounded())) },
              tint: Self.workout,
              marksPoint: false) {
            ForEach(energyBars) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day),
                        y: .value("kcal", bar.kilocalories))
                    .foregroundStyle(by: .value("Source", bar.source))
            }
        }
        .chartForegroundStyleScale([
            "Workouts": Self.workout,
            "Other activity": Self.otherActivity,
        ])
        .chartLegend(position: .top, alignment: .leading, spacing: 2)
    }

    /// Scaled to its own range plus three kilograms either side, not to zero.
    /// On a zero-based axis a fortnight of real change is a flat line.
    ///
    /// Points as well as a line: weight is recorded when someone remembers to,
    /// and the line between two readings a week apart is interpolation, not
    /// measurement. The dots say which days were actually stood on.
    private var weightPanel: some View {
        panel("Weight",
              unit: weightUnit,
              value: { $0.weight },
              format: { String(format: "%.1f", $0) },
              yDomain: weightDomain,
              tint: Self.weight) {
            ForEach(points({ $0.weight })) { point in
                LineMark(x: .value("Day", point.date), y: .value("Weight", point.value))
                    .foregroundStyle(Self.weight)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", point.date), y: .value("Weight", point.value))
                    .foregroundStyle(Self.weight)
                    .symbolSize(18)
            }
        }
    }

    /// That day's mean glucose put through the ADAG regression. Nil when the
    /// day has no mean — which is most of the reason a point goes missing here.
    private func a1c(_ day: DailySeries.Day) -> Double? {
        day.meanGlucose.flatMap { A1c.fromMeanGlucose($0, unit: glucoseUnit) }
    }

    /// A straight rescaling of the glucose chart — the ADAG formula is linear,
    /// so the two curves have the same shape. It earns its place by being in
    /// the units a target is actually held in: *if every day looked like this
    /// one, the A1c would be this.*
    private var a1cPanel: some View {
        panel("Estimated A1c",
              unit: "% · ADAG",
              value: a1c,
              format: A1c.format,
              tint: Self.a1cTint) {
            ForEach(points(a1c)) { point in
                LineMark(x: .value("Day", point.date), y: .value("A1c", point.value))
                    .foregroundStyle(Self.a1cTint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
    }

    private var weightDomain: ClosedRange<Double>? {
        let values = days.compactMap(\.weight)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low - weightPadding)...(high + weightPadding)
    }

    // MARK: - Panel chrome

    /// Title, two readouts, and a chart that scrolls, zooms and selects in step
    /// with every other one.
    ///
    /// One accessor drives all four uses of a series — the header value, the
    /// ninety-day average above it, the reference line at that average, and the
    /// point marking a selected day — so they cannot drift out of agreement
    /// with the marks the caller draws.
    private func panel<Content: ChartContent>(
        _ title: String,
        unit: String,
        value: (DailySeries.Day) -> Double?,
        format: (Double) -> String,
        yDomain: ClosedRange<Double>? = nil,
        tint: Color,
        marksPoint: Bool = true,
        @ChartContentBuilder content: () -> Content
    ) -> some View {
        // Selected day if there is one, newest value otherwise. A selected day
        // with nothing to show stays nil, which the header draws as a dash —
        // falling back to the latest value would answer a question about one
        // day with a number from another.
        var current: Double?
        if let selectedDay {
            current = value(selectedDay)
        } else {
            for day in days.reversed() {
                if let found = value(day) {
                    current = found
                    break
                }
            }
        }
        let mean = average(value)
        let highlight: Double? = marksPoint ? selectedDay.flatMap(value) : nil

        let chart = Chart {
            content()

            if let mean {
                RuleMark(y: .value("90-day average", mean))
                    .foregroundStyle(tint.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            if let selectedDay {
                RuleMark(x: .value("Day", plotX(selectedDay)))
                    .foregroundStyle(Self.rule)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let highlight {
                    PointMark(x: .value("Day", plotX(selectedDay)),
                              y: .value(title, highlight))
                        .foregroundStyle(tint)
                        .symbolSize(60)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartXVisibleDomain(length: visibleLength)
        .chartScrollableAxes(.horizontal)
        .chartScrollPosition(x: $scrollX)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Self.grid)
                AxisValueLabel {
                    // Fixed width so every chart's plot area starts at the same
                    // x — otherwise "1200" and "8.4" would offset the panels
                    // from each other and the columns would no longer line up.
                    Text(Self.axisLabel(value))
                        .font(.system(size: 9))
                        .frame(width: 30, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 92)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let mean {
                    Text("90 d")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(format(mean))
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(current.map(format) ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Six panels of two numbers and a unit on one line: shrink rather
            // than truncate, so "U/day per mmol/L" stays readable.
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            // Applied here rather than always, because handing Charts an
            // explicit domain everywhere would throw away the automatic scaling
            // the other five want.
            if let yDomain {
                chart.chartYScale(domain: yDomain)
            } else {
                chart
            }
        }
    }

    private static func axisLabel(_ value: AxisValue) -> String {
        guard let number = value.as(Double.self) else { return "" }
        if abs(number) >= 100 { return String(Int(number.rounded())) }
        if abs(number) >= 10 { return String(format: "%.0f", number) }
        return String(format: "%.1f", number)
    }

    // MARK: - Series

    /// Marks sit at the middle of their day rather than at midnight, so bars,
    /// lines and the selection rule all land on the same x. A bar binned by day
    /// spans midnight to midnight; a line plotted at midnight would run through
    /// its left edge, and the rule could only ever agree with one of them.
    private func plotX(_ day: DailySeries.Day) -> Date {
        Calendar.current.date(byAdding: .hour, value: 12, to: day.date) ?? day.date
    }

    private var plottableDays: [DailySeries.Day] {
        days.filter {
            $0.meanGlucose != nil || $0.totalInsulin != nil
                || $0.activeEnergy != nil || $0.weight != nil
        }
    }

    private var domain: ClosedRange<Date> {
        guard let first = days.first?.date, let last = days.last?.date, first < last else {
            let now = Date.now
            return now.addingTimeInterval(-Self.secondsPerDay)...now
        }
        // A day wide on the end, so the last bar is not clipped in half.
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var visibleLength: TimeInterval { visibleDays * Self.secondsPerDay }

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// A closure rather than a key path: A1c is derived from a day rather than
    /// stored on one, and a series should not have to be a field to be plotted.
    private func points(_ value: (DailySeries.Day) -> Double?) -> [Point] {
        days.compactMap { day in
            value(day).map { Point(date: plotX(day), value: $0) }
        }
    }

    /// Mean of a series over everything plotted.
    ///
    /// The mean of the *days shown*, so a day with nothing logged neither
    /// raises nor lowers it. That makes the line sit exactly at the average of
    /// the points above and below it, which is the only reading of a reference
    /// line on a chart that cannot mislead — but it is why this can differ from
    /// the ninety-day figure on the Averages card, which divides by elapsed
    /// time instead.
    private func average(_ value: (DailySeries.Day) -> Double?) -> Double? {
        let values = days.compactMap(value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private struct StackedBar: Identifiable {
        let date: Date
        let kind: String
        let units: Double
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
    }

    private var insulinBars: [StackedBar] {
        days.flatMap { day -> [StackedBar] in
            guard day.hasInsulin else { return [] }
            return [
                StackedBar(date: plotX(day), kind: "Basal", units: day.basal),
                StackedBar(date: plotX(day), kind: "Bolus", units: day.bolus),
            ].filter { $0.units > 0 }
        }
    }

    private struct EnergyBar: Identifiable {
        let date: Date
        let source: String
        let kilocalories: Double
        var id: String { "\(date.timeIntervalSince1970)-\(source)" }
    }

    private var energyBars: [EnergyBar] {
        days.flatMap { day -> [EnergyBar] in
            guard day.activeEnergy != nil else { return [] }
            return [
                EnergyBar(date: plotX(day), source: "Workouts", kilocalories: day.workoutEnergy),
                EnergyBar(date: plotX(day), source: "Other activity", kilocalories: day.otherEnergy),
            ].filter { $0.kilocalories > 0 }
        }
    }

    // MARK: - Footnotes

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.self) { text in
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var notes: [String] {
        var notes = [
            "Drag to scroll, pinch to zoom, tap to pick a day — all six charts follow, so a day lines up down the screen.",
        ]

        let thin = days.filter { $0.meanGlucose == nil && $0.glucoseCoverage > 0 }.count
        if thin > 0 {
            notes.append("\(thin) day\(thin == 1 ? "" : "s") had CGM for under half the day, so no average is plotted for \(thin == 1 ? "it" : "them") — glucose has a strong daily shape, and a mean over part of a day is a mean of that part, not a noisier version of the whole.")
        }

        let noBasal = days.filter { $0.hasInsulin && $0.basal == 0 }.count
        if noBasal > 0 {
            notes.append("\(noBasal) day\(noBasal == 1 ? "" : "s") logged insulin but no basal. A missed log and a missed injection look the same from here, and both pull that day's total — and its index — down.")
        }

        notes.append("Weight is scaled to its own range plus three kilograms either side, so a small real drift is a visible slope. The other four start at zero.")
        notes.append("Exercise calories are active energy from Health, with the part spent inside a logged workout drawn darker. Weight is plotted only on days it was actually recorded; the line between dots is interpolation.")
        notes.append("Each chart carries its 90-day average as a dashed line and as the muted figure beside its title. It is the mean of the days plotted, so a day with nothing logged neither raises nor lowers it — which is why it can differ slightly from the same window on the Averages card, which divides by elapsed time instead.")
        notes.append("On the A1c chart that average is worth more than the daily points: the ADAG formula is linear, so the mean of the daily estimates equals the estimate from the 90-day mean glucose exactly. That dashed line is the closest thing here to a real A1c.")
        notes.append("Estimated A1c is that day's mean glucose through the ADAG formula — if every day looked like that one, the A1c would be this. It is the same curve as the glucose chart in different units, and it is not a prediction of a lab result: a real A1c answers for the previous three months, weighted towards the recent end. Read the level, not the point.")
        notes.append("The index is total daily insulin per unit of glucose: it rises as sensitivity falls. A single day of it is noisy — one late dinner moves it. Read the shape over weeks, not the day-to-day.")
        return notes
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    // MARK: - Palette

    private static let glucose = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0xd5 / 255, green: 0x51 / 255, blue: 0x81 / 255, alpha: 1)
            : UIColor(red: 0xe8 / 255, green: 0x7b / 255, blue: 0xa4 / 255, alpha: 1)
    })

    private static let basal = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x4a / 255, green: 0x5a / 255, blue: 0xb8 / 255, alpha: 1)
            : UIColor(red: 0x5b / 255, green: 0x6b / 255, blue: 0xc9 / 255, alpha: 1)
    })

    private static let bolus = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    private static let index = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0xd4 / 255, green: 0x8e / 255, blue: 0x2c / 255, alpha: 1)
            : UIColor(red: 0xc5 / 255, green: 0x7c / 255, blue: 0x1e / 255, alpha: 1)
    })

    private static let workout = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255, alpha: 1)
            : UIColor(red: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255, alpha: 1)
    })

    private static let otherActivity = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x2f / 255, green: 0x5e / 255, blue: 0x4e / 255, alpha: 1)
            : UIColor(red: 0xa8 / 255, green: 0xd8 / 255, blue: 0xc4 / 255, alpha: 1)
    })

    private static let weight = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x9b / 255, green: 0x8a / 255, blue: 0xd4 / 255, alpha: 1)
            : UIColor(red: 0x7d / 255, green: 0x6c / 255, blue: 0xb8 / 255, alpha: 1)
    })

    private static let a1cTint = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0xc2 / 255, green: 0x6b / 255, blue: 0x4f / 255, alpha: 1)
            : UIColor(red: 0xb3 / 255, green: 0x5a / 255, blue: 0x3e / 255, alpha: 1)
    })

    private static let rule = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 0.78, alpha: 1)
            : UIColor(white: 0.32, alpha: 1)
    })

    private static let grid = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2a / 255, alpha: 1)
            : UIColor(red: 0xe1 / 255, green: 0xe0 / 255, blue: 0xd9 / 255, alpha: 1)
    })
}
