import SwiftUI
import Charts
import UIKit

/// Five day-by-day charts stacked on one shared, scrolling time axis.
///
/// Stacked rather than overlaid because the five quantities share no scale, and
/// small multiples on a common axis are the honest way to read one series
/// against another: a training block and the notch it puts in insulin a day
/// later line up vertically, without pretending kilocalories and millimoles
/// belong on the same y.
///
/// Scrolling is bound to one shared position, so dragging any chart moves all
/// five and the columns stay aligned.
///
/// Nothing here is a dosing instruction. It describes what already happened.
struct TrendsView: View {
    let days: [DailySeries.Day]
    let glucoseUnit: String
    let weightUnit: String

    /// Shared by every chart — this is what makes them scroll as one.
    @State private var scrollX = Date.distantPast
    @State private var didPosition = false

    /// How much of the range is on screen at once. Four weeks reads as a block
    /// of training or a run of missed basal rather than as individual days.
    private static let visibleDays = 28

    var body: some View {
        Group {
            if plottableDays.isEmpty {
                ContentUnavailableView(
                    "Nothing to plot yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Needs glucose in Health and some insulin logged.")
                )
            } else {
                charts
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
                footnotes
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear(perform: positionAtToday)
    }

    /// Start at the most recent day rather than three months ago.
    private func positionAtToday() {
        guard !didPosition, let last = plottableDays.last?.date else { return }
        didPosition = true
        let calendar = Calendar.current
        scrollX = calendar.date(byAdding: .day, value: -Self.visibleDays, to: last) ?? last
    }

    // MARK: - The panels

    private var glucosePanel: some View {
        panel("Average glucose", unit: glucoseUnit, latest: latest(\.meanGlucose).map {
            InsulinStats.formatGlucose($0, unit: glucoseUnit)
        }) {
            ForEach(points(\.meanGlucose)) { point in
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
        panel("Total insulin", unit: "U", latest: latest(\.totalInsulin).map {
            InsulinStats.formatUnits($0)
        }) {
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
              latest: latest(\.insulinPerGlucose).map {
                  InsulinStats.formatIndex($0, unit: glucoseUnit)
              }) {
            ForEach(points(\.insulinPerGlucose)) { point in
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
        panel("Exercise calories", unit: "kcal", latest: latest(\.activeEnergy).map {
            String(Int($0.rounded()))
        }) {
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

    /// Points as well as a line: weight is recorded when someone remembers to,
    /// and the line between two readings a week apart is interpolation, not
    /// measurement. The dots say which days were actually stood on.
    private var weightPanel: some View {
        panel("Weight", unit: weightUnit, latest: latest(\.weight).map {
            String(format: "%.1f", $0)
        }) {
            ForEach(points(\.weight)) { point in
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

    // MARK: - Panel chrome

    /// Title, current value, and a chart that scrolls in step with every other.
    private func panel<Content: ChartContent>(
        _ title: String,
        unit: String,
        latest: String?,
        @ChartContentBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let latest {
                    Text(latest)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Chart(content: content)
                .chartXScale(domain: domain)
                .chartXVisibleDomain(length: visibleLength)
                .chartScrollableAxes(.horizontal)
                .chartScrollPosition(x: $scrollX)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                        AxisGridLine().foregroundStyle(Self.grid)
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Self.grid)
                        AxisValueLabel {
                            // Fixed width so every chart's plot area starts at
                            // the same x — otherwise "1200" and "8.4" would
                            // offset the panels from each other and the columns
                            // would no longer line up down the screen.
                            Text(Self.axisLabel(value))
                                .font(.system(size: 9))
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 92)
        }
    }

    private static func axisLabel(_ value: AxisValue) -> String {
        guard let number = value.as(Double.self) else { return "" }
        if abs(number) >= 100 { return String(Int(number.rounded())) }
        if abs(number) >= 10 { return String(format: "%.0f", number) }
        return String(format: "%.1f", number)
    }

    // MARK: - Series

    /// A day that has at least one thing worth plotting.
    private var plottableDays: [DailySeries.Day] {
        days.filter {
            $0.meanGlucose != nil || $0.totalInsulin != nil
                || $0.activeEnergy != nil || $0.weight != nil
        }
    }

    private var domain: ClosedRange<Date> {
        guard let first = days.first?.date, let last = days.last?.date, first < last else {
            let now = Date.now
            return now.addingTimeInterval(-24 * 3600)...now
        }
        // A day wide on the end, so the last bar is not clipped in half.
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var visibleLength: TimeInterval {
        Double(Self.visibleDays) * 24 * 3600
    }

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private func points(_ metric: KeyPath<DailySeries.Day, Double?>) -> [Point] {
        days.compactMap { day in
            day[keyPath: metric].map { Point(date: day.date, value: $0) }
        }
    }

    /// Newest non-nil value of a metric, for the readout beside the title.
    private func latest(_ metric: KeyPath<DailySeries.Day, Double?>) -> Double? {
        for day in days.reversed() {
            if let value = day[keyPath: metric] { return value }
        }
        return nil
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
                StackedBar(date: day.date, kind: "Basal", units: day.basal),
                StackedBar(date: day.date, kind: "Bolus", units: day.bolus),
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
                EnergyBar(date: day.date, source: "Workouts", kilocalories: day.workoutEnergy),
                EnergyBar(date: day.date, source: "Other activity", kilocalories: day.otherEnergy),
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
            "Drag any chart — all five scroll together, so a day lines up down the screen.",
        ]

        let thin = days.filter { $0.meanGlucose == nil && $0.glucoseCoverage > 0 }.count
        if thin > 0 {
            notes.append("\(thin) day\(thin == 1 ? "" : "s") had CGM for under half the day, so no average is plotted for \(thin == 1 ? "it" : "them") — glucose has a strong daily shape, and a mean over part of a day is a mean of that part, not a noisier version of the whole.")
        }

        let noBasal = days.filter { $0.hasInsulin && $0.basal == 0 }.count
        if noBasal > 0 {
            notes.append("\(noBasal) day\(noBasal == 1 ? "" : "s") logged insulin but no basal. A missed log and a missed injection look the same from here, and both pull that day's total — and its index — down.")
        }

        notes.append("Exercise calories are active energy from Health, with the part spent inside a logged workout drawn darker. Weight is plotted only on days it was actually recorded; the line between dots is interpolation.")
        notes.append("The index is total daily insulin per unit of glucose: it rises as sensitivity falls. A single day of it is noisy — one late dinner moves it. Read the shape over weeks, not the day-to-day.")
        return notes
    }

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

    private static let grid = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2a / 255, alpha: 1)
            : UIColor(red: 0xe1 / 255, green: 0xe0 / 255, blue: 0xd9 / 255, alpha: 1)
    })
}
