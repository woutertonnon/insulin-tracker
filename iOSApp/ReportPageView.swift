import SwiftUI
import Charts

/// One page of the doctor's report, at paper size.
///
/// Titles, labels, values, legends and numbered references — and nothing
/// else. No explanatory prose: the page is read across a desk by someone who
/// knows what time in range is, and every sentence would be between them and
/// the number. Anything a caveat would have said is a label with a value
/// beside it instead ("Days logged: 84 of 90"); anything a method note would
/// have said is a reference.
///
/// Printed, quite possibly in black and white, so every multi-series chart
/// carries a legend and every figure its unit.
struct ReportPageView: View {
    let page: ReportPDF.Page
    let title: String
    let document: Report.Document
    let number: Int
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(ReportStyle.rule)
                .frame(height: 0.5)
                .padding(.vertical, 8)
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(ReportPDF.margin)
        .font(.system(size: 9))
        .foregroundStyle(ReportStyle.ink)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .summary:
            summary
        case .glucoseOverTime:
            glucoseOverTime
        case .insulinAndBody:
            insulinAndBody
        case .notes:
            notes
        case .days(let days, let continued):
            dayTable(days, continued: continued)
        case .log(let lines, let continued):
            logTable(lines, continued: continued)
        case .events(let kind, let events, let first):
            eventsPage(kind, events, first: first)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: number == 1 ? 18 : 12, weight: .bold))
                Text("\(rangeText) · \(document.days.count) days")
                    .font(.system(size: 10))
                    .foregroundStyle(ReportStyle.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Generated: \(Self.longDate.string(from: document.generated))")
                Text("Glucose: \(document.unit)")
            }
            .font(.system(size: 8))
            .foregroundStyle(ReportStyle.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("Page \(number) of \(count)")
        }
        .font(.system(size: 7.5))
        .foregroundStyle(ReportStyle.muted)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .padding(.top, 2)
    }

    private func chartTitle(_ title: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
            Text(unit)
                .foregroundStyle(ReportStyle.secondary)
        }
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(ReportStyle.secondary)
    }

    private func dash() -> some View {
        Text("—")
            .foregroundStyle(ReportStyle.muted)
    }

    /// One entry of a legend: a swatch and what it stands for.
    private struct LegendItem {
        let color: Color
        let label: String
        var dashed = false
    }

    /// Drawn here rather than left to the chart library, so it is on the page
    /// whatever the renderer makes of the library's own legend.
    private func legend(_ items: [LegendItem]) -> some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 3) {
                    if items[index].dashed {
                        Rectangle()
                            .fill(items[index].color)
                            .frame(width: 4, height: 2)
                        Rectangle()
                            .fill(items[index].color)
                            .frame(width: 4, height: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(items[index].color)
                            .frame(width: 9, height: 7)
                    }
                    Text(items[index].label)
                        .foregroundStyle(ReportStyle.secondary)
                }
            }
        }
        .font(.system(size: 7.5))
        .lineLimit(1)
    }

    private static let insulinLegend = [
        LegendItem(color: ReportStyle.basal, label: "Basal · Lantus, long-acting"),
        LegendItem(color: ReportStyle.bolus, label: "Bolus · NovoRapid, rapid-acting"),
    ]

    /// "14-day average: 7.4 mmol/L · 30-day average: … · 90-day average: …"
    private func averages(_ value: @escaping (Report.Window) -> String?) -> some View {
        HStack(spacing: 8) {
            ForEach(document.windows) { window in
                HStack(spacing: 3) {
                    Text("\(window.title):")
                        .foregroundStyle(ReportStyle.secondary)
                    Text(value(window) ?? "—")
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
        }
        .font(.system(size: 8))
        .lineLimit(1)
    }

    // MARK: - Page 1: summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Glucose")
            if let glucose = document.glucose {
                glucoseTiles(glucose)
                HStack(alignment: .top, spacing: 16) {
                    TimeInRangeBar(summary: glucose)
                    bandTable(glucose)
                    Spacer(minLength: 0)
                }
                profileChart
            } else {
                dash()
            }

            sectionTitle("Insulin")
            insulinTiles
            activityChart
        }
    }

    private func glucoseTiles(_ glucose: Report.GlucoseSummary) -> some View {
        let unit = document.unit
        return HStack(spacing: 6) {
            StatTile(title: "Mean glucose",
                     value: InsulinStats.formatGlucose(glucose.mean, unit: unit),
                     unit: unit)
            StatTile(title: "GMI",
                     value: A1c.gmi(fromMeanGlucose: glucose.mean, unit: unit).map(A1c.format) ?? "—",
                     unit: "% [3]")
            StatTile(title: "Estimated A1c",
                     value: A1c.fromMeanGlucose(glucose.mean, unit: unit).map(A1c.format) ?? "—",
                     unit: "% [4]")
            StatTile(title: "SD",
                     value: glucose.sd.map { InsulinStats.formatGlucose($0, unit: unit) } ?? "—",
                     unit: unit)
            StatTile(title: "CV",
                     value: glucose.cv.map { String(format: "%.0f", $0) } ?? "—",
                     unit: "% · goal ≤ 36% [1]")
            StatTile(title: "CGM active",
                     value: Report.formatPercent(glucose.coverage),
                     unit: "of the period")
        }
    }

    /// The five bands, very high at the top, as the AGP prints them — so the
    /// table reads top to bottom the way the bar beside it does.
    private func bandTable(_ glucose: Report.GlucoseSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                Text("")
                tableHeader("Band")
                tableHeader(document.unit)
                tableHeader("Time")
                tableHeader("Per day")
                tableHeader("Goal [1]")
            }
            ForEach(Report.Band.allCases.reversed(), id: \.self) { band in
                GridRow {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ReportStyle.color(band))
                        .frame(width: 8, height: 8)
                    Text(band.title)
                        .fontWeight(band == .inRange ? .semibold : .regular)
                    Text(document.targets.range(band))
                        .foregroundStyle(ReportStyle.secondary)
                    Text(Report.formatPercent(glucose.fraction(band)))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .gridColumnAlignment(.trailing)
                    Text(Report.formatShareOfDay(glucose.fraction(band)))
                        .foregroundStyle(ReportStyle.secondary)
                    Text(band.goal)
                        .foregroundStyle(ReportStyle.muted)
                }
            }
        }
    }

    /// Axis marks for a 24-hour day, shared by the two profile charts.
    private var hourAxis: some AxisContent {
        AxisMarks(values: [0.0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
            AxisGridLine().foregroundStyle(ReportStyle.grid)
            AxisValueLabel {
                if let hour = value.as(Double.self) {
                    Text(String(format: "%02d:00", Int(hour)))
                        .font(.system(size: 7))
                        .foregroundStyle(ReportStyle.secondary)
                }
            }
        }
    }

    /// The AGP's central chart: every reading folded onto one day.
    private var profileChart: some View {
        let bins = document.profilePlot
        let targets = document.targets
        return VStack(alignment: .leading, spacing: 3) {
            chartTitle("Daily profile [2]", unit: document.unit)
            legend([
                LegendItem(color: ReportStyle.profileMedian, label: "Median"),
                LegendItem(color: ReportStyle.profileInner, label: "25–75%"),
                LegendItem(color: ReportStyle.profileOuter, label: "5–95%"),
                LegendItem(color: ReportStyle.color(.inRange).opacity(0.25), label: "Target range"),
            ])
            if bins.count >= 2 {
                Chart {
                    RectangleMark(xStart: .value("Start", 0.0),
                                  xEnd: .value("End", 24.0),
                                  yStart: .value("Low", targets.low),
                                  yEnd: .value("High", targets.high))
                        .foregroundStyle(ReportStyle.color(.inRange).opacity(0.12))

                    ForEach(bins) { bin in
                        AreaMark(x: .value("Time", bin.hour),
                                 yStart: .value("5%", bin.p5),
                                 yEnd: .value("95%", bin.p95))
                            .foregroundStyle(by: .value("Band", "5–95%"))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(bins) { bin in
                        AreaMark(x: .value("Time", bin.hour),
                                 yStart: .value("25%", bin.p25),
                                 yEnd: .value("75%", bin.p75))
                            .foregroundStyle(by: .value("Band", "25–75%"))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(bins) { bin in
                        LineMark(x: .value("Time", bin.hour),
                                 y: .value("Median", bin.p50))
                            .foregroundStyle(by: .value("Band", "Median"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }

                    RuleMark(y: .value("Low", targets.low))
                        .foregroundStyle(ReportStyle.color(.inRange).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                    RuleMark(y: .value("High", targets.high))
                        .foregroundStyle(ReportStyle.color(.inRange).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                }
                .chartForegroundStyleScale([
                    "Median": ReportStyle.profileMedian,
                    "25–75%": ReportStyle.profileInner,
                    "5–95%": ReportStyle.profileOuter,
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: 0.0...24.0)
                .chartXAxis { hourAxis }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(ReportStyle.grid)
                        AxisValueLabel {
                            if let glucose = value.as(Double.self) {
                                Text(InsulinStats.formatGlucose(glucose, unit: document.unit))
                                    .font(.system(size: 7))
                                    .foregroundStyle(ReportStyle.secondary)
                            }
                        }
                    }
                }
                .font(.system(size: 7.5))
                .frame(height: 130)
            } else {
                dash()
            }
        }
    }

    private var insulinTiles: some View {
        let insulin = document.insulin
        return HStack(spacing: 6) {
            StatTile(title: "Basal",
                     value: insulin.basalPerDay.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "U per day")
            StatTile(title: "Bolus",
                     value: insulin.bolusPerDay.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "U per day")
            StatTile(title: "Total",
                     value: insulin.totalPerDay.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "U per day")
            StatTile(title: "Bolus share",
                     value: insulin.bolusShare.map(Report.formatPercent) ?? "—",
                     unit: "of daily insulin")
            StatTile(title: "Boluses",
                     value: insulin.bolusesPerDay.map { String(format: "%.1f", $0) } ?? "—",
                     unit: "per day")
            StatTile(title: "Days logged",
                     value: "\(insulin.loggedDays) of \(document.days.count)",
                     unit: "\(insulin.daysWithBasal) with basal")
        }
    }

    /// Units acting per hour through a typical day: basal under the Lantus
    /// profile, bolus under the NovoRapid one, stacked.
    private var activityChart: some View {
        let bins = document.activityPlot
        return VStack(alignment: .leading, spacing: 3) {
            chartTitle("Insulin acting through the day [5] [6]", unit: "U per hour")
            legend(Self.insulinLegend)
            if bins.count >= 2 {
                Chart {
                    ForEach(bins) { bin in
                        AreaMark(x: .value("Time", bin.hour), y: .value("U/h", bin.basal))
                            .foregroundStyle(by: .value("Kind", "Basal"))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Time", bin.hour), y: .value("U/h", bin.bolus))
                            .foregroundStyle(by: .value("Kind", "Bolus"))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale([
                    "Basal": ReportStyle.basal,
                    "Bolus": ReportStyle.bolus,
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: 0.0...24.0)
                .chartXAxis { hourAxis }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(ReportStyle.grid)
                        AxisValueLabel {
                            Text(Self.axisLabel(value))
                                .font(.system(size: 7))
                                .foregroundStyle(ReportStyle.secondary)
                        }
                    }
                }
                .font(.system(size: 7.5))
                .frame(height: 115)
            } else {
                dash()
            }
        }
    }

    // MARK: - Page 2: glucose over time

    private var glucoseOverTime: some View {
        let unit = document.unit
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Glucose over time")

            dayChart("Estimated A1c [4] and GMI [3]",
                     unit: "%",
                     height: 190,
                     legend: [
                         LegendItem(color: ReportStyle.a1c, label: "Estimated A1c"),
                         LegendItem(color: ReportStyle.gmi, label: "GMI", dashed: true),
                     ],
                     averages: { window in
                         guard let mean = window.glucose?.mean else { return nil }
                         let a1c = A1c.fromMeanGlucose(mean, unit: unit).map(A1c.format) ?? "—"
                         let gmi = A1c.gmi(fromMeanGlucose: mean, unit: unit).map(A1c.format) ?? "—"
                         return "A1c \(a1c)%, GMI \(gmi)%"
                     }) {
                ForEach(document.days) { day in
                    if let mean = day.glucose?.mean {
                        if let a1c = A1c.fromMeanGlucose(mean, unit: unit) {
                            LineMark(x: .value("Day", plotX(day)), y: .value("A1c", a1c))
                                .foregroundStyle(by: .value("Series", "Estimated A1c"))
                                .lineStyle(StrokeStyle(lineWidth: 1.2))
                                .interpolationMethod(.monotone)
                        }
                        if let gmi = A1c.gmi(fromMeanGlucose: mean, unit: unit) {
                            LineMark(x: .value("Day", plotX(day)), y: .value("GMI", gmi))
                                .foregroundStyle(by: .value("Series", "GMI"))
                                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 2]))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            .chartForegroundStyleScale([
                "Estimated A1c": ReportStyle.a1c,
                "GMI": ReportStyle.gmi,
            ])
            .chartLegend(.hidden)

            dayChart("Mean glucose",
                     unit: unit,
                     height: 190,
                     averages: { window in
                         window.glucose.map { "\(InsulinStats.formatGlucose($0.mean, unit: unit)) \(unit)" }
                     }) {
                ForEach(document.days) { day in
                    if let glucose = day.glucose {
                        LineMark(x: .value("Day", plotX(day)), y: .value("Mean", glucose.mean))
                            .foregroundStyle(ReportStyle.glucose)
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Day", plotX(day)), y: .value("Mean", glucose.mean))
                            .foregroundStyle(ReportStyle.glucose)
                            .symbolSize(8)
                    }
                }
                RuleMark(y: .value("Low", document.targets.low))
                    .foregroundStyle(ReportStyle.color(.inRange).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                RuleMark(y: .value("High", document.targets.high))
                    .foregroundStyle(ReportStyle.color(.inRange).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            }
        }
    }

    // MARK: - Page 3: insulin, activity and weight

    private var insulinAndBody: some View {
        // Three charts when Health has both, taller when it has less.
        let chartCount = 1 + (document.hasEnergy ? 1 : 0) + (document.hasWeight ? 1 : 0)
        let height: CGFloat = chartCount == 3 ? 150 : (chartCount == 2 ? 200 : 260)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Insulin, activity and weight")

            dayChart("Insulin",
                     unit: "U per day",
                     height: height,
                     legend: Self.insulinLegend,
                     averages: { window in
                         window.insulin.totalPerDay.map { String(format: "%.1f U", $0) }
                     }) {
                ForEach(document.days) { day in
                    if day.basal > 0 {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Units", day.basal))
                            .foregroundStyle(by: .value("Kind", "Basal"))
                    }
                    if day.bolus > 0 {
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Units", day.bolus))
                            .foregroundStyle(by: .value("Kind", "Bolus"))
                    }
                }
            }
            .chartForegroundStyleScale([
                "Basal": ReportStyle.basal,
                "Bolus": ReportStyle.bolus,
            ])
            .chartLegend(.hidden)

            if document.hasEnergy {
                dayChart("Active energy",
                         unit: "kcal per day",
                         height: height,
                         legend: [
                             LegendItem(color: ReportStyle.workout, label: "Workouts"),
                             LegendItem(color: ReportStyle.otherActivity, label: "Other activity"),
                         ],
                         averages: { window in
                             window.activeEnergyPerDay.map { "\(Int($0.rounded())) kcal" }
                         }) {
                    ForEach(document.days) { day in
                        if let energy = day.activeEnergy {
                            let workout = min(energy, day.workouts.reduce(0.0) { $0 + ($1.kilocalories ?? 0) })
                            if workout > 0 {
                                BarMark(x: .value("Day", day.date, unit: .day), y: .value("kcal", workout))
                                    .foregroundStyle(by: .value("Source", "Workouts"))
                            }
                            if energy - workout > 0 {
                                BarMark(x: .value("Day", day.date, unit: .day), y: .value("kcal", energy - workout))
                                    .foregroundStyle(by: .value("Source", "Other activity"))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "Workouts": ReportStyle.workout,
                    "Other activity": ReportStyle.otherActivity,
                ])
                .chartLegend(.hidden)
            }

            if document.hasWeight {
                dayChart("Weight",
                         unit: document.weightUnit,
                         height: height,
                         yDomain: weightDomain,
                         averages: { window in
                             window.weight.map { "\(String(format: "%.1f", $0)) \(document.weightUnit)" }
                         }) {
                    ForEach(document.days) { day in
                        if let weight = day.weight {
                            LineMark(x: .value("Day", plotX(day)), y: .value("Weight", weight))
                                .foregroundStyle(ReportStyle.weight)
                                .lineStyle(StrokeStyle(lineWidth: 1.2))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", plotX(day)), y: .value("Weight", weight))
                                .foregroundStyle(ReportStyle.weight)
                                .symbolSize(10)
                        }
                    }
                }
            }
        }
    }

    /// Title, the three window averages, and a chart over the period's days.
    private func dayChart<Content: ChartContent>(
        _ title: String,
        unit: String,
        height: CGFloat,
        yDomain: ClosedRange<Double>? = nil,
        legend items: [LegendItem] = [],
        averages value: @escaping (Report.Window) -> String?,
        @ChartContentBuilder content: () -> Content
    ) -> some View {
        let chart = Chart {
            content()
        }
        .chartXScale(domain: document.start...document.end)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(ReportStyle.grid)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 7))
                    .foregroundStyle(ReportStyle.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(ReportStyle.grid)
                AxisValueLabel {
                    // Fixed width so every chart's plot starts at the same x
                    // and the days line up down the page.
                    Text(Self.axisLabel(value))
                        .font(.system(size: 7))
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(ReportStyle.secondary)
                }
            }
        }
        .font(.system(size: 7.5))
        .frame(height: height)

        return VStack(alignment: .leading, spacing: 3) {
            chartTitle(title, unit: unit)
            if !items.isEmpty {
                legend(items)
            }
            averages(value)
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

    /// Midday, so a line lands in the middle of the bar for the same day.
    private func plotX(_ day: Report.Day) -> Date {
        Calendar.current.date(byAdding: .hour, value: 12, to: day.date) ?? day.date
    }

    private var weightDomain: ClosedRange<Double>? {
        let values = document.days.compactMap(\.weight)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low - document.weightAxisPadding)...(high + document.weightAxisPadding)
    }

    // MARK: - Page 4: basal and references

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Basal")
            basalTiles

            sectionTitle("References")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.references.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 4) {
                        Text("[\(index + 1)]")
                            .frame(width: 16, alignment: .leading)
                        Text(Self.references[index])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(ReportStyle.secondary)
        }
    }

    private var basalTiles: some View {
        let insulin = document.insulin
        var range = "—"
        if let bounds = insulin.basalDoseRange {
            range = bounds.lowerBound == bounds.upperBound
                ? Report.formatUnits(bounds.lowerBound)
                : "\(Report.formatUnits(bounds.lowerBound))–\(Report.formatUnits(bounds.upperBound))"
        }
        return HStack(spacing: 6) {
            StatTile(title: "Days with basal",
                     value: "\(insulin.daysWithBasal) of \(insulin.loggedDays)",
                     unit: "days logged")
            StatTile(title: "Usual dose",
                     value: insulin.basalDose.map(Report.formatUnits) ?? "—",
                     unit: "U · median")
            StatTile(title: "Dose range",
                     value: range,
                     unit: "U")
            StatTile(title: "Usual time",
                     value: insulin.basalMinuteOfDay.map(Report.formatMinuteOfDay) ?? "—",
                     unit: "median")
        }
    }

    /// Numbered as the pages cite them.
    private static let references: [String] = [
        "Battelino T, Danne T, Bergenstal RM, et al. Clinical targets for continuous glucose monitoring data interpretation: recommendations from the International Consensus on Time in Range. Diabetes Care. 2019;42(8):1593–1603.",
        "Bergenstal RM, Ahmann AJ, Bailey T, et al. Recommendations for standardizing glucose reporting and analysis to optimize clinical decision making in diabetes: the Ambulatory Glucose Profile (AGP). Diabetes Technol Ther. 2013;15(3):198–211.",
        "Bergenstal RM, Beck RW, Close KL, et al. Glucose Management Indicator (GMI): a new term for estimating A1C from continuous glucose monitoring. Diabetes Care. 2018;41(11):2275–2280.",
        "Nathan DM, Kuenen J, Borg R, et al. Translating the A1C assay into estimated average glucose values. Diabetes Care. 2008;31(8):1473–1478.",
        "Rapid-acting (NovoRapid) action curve: the exponential insulin activity model of OpenAPS, Loop and AndroidAPS, peak 75 min, duration 4 h.",
        "Long-acting (Lantus) action curve: Lepore M, Pampanelli S, Fanelli C, et al. Pharmacokinetics and pharmacodynamics of subcutaneous injection of long-acting human insulin analog glargine, NPH insulin, and ultralente human insulin and continuous subcutaneous infusion of insulin lispro. Diabetes. 2000;49(12):2142–2148.",
        "Meter readings adjusted for outside temperature: adjusted = reading − 0.0928 mmol/L per °C × (T − 22.5 °C). Riding the Glucose Trail, \"BG & temperatures\", fitted on a Contour Next One, mostly between 0 and 15 °C. ridingtheglucosetrail.com/p/bg-temperatures",
        "Outside temperature at each reading: weather data by Open-Meteo.com, CC BY 4.0, downscaled to the reading's altitude.",
    ]

    // MARK: - The day table

    private struct Column {
        let title: String
        let unit: String
        let width: CGFloat
        let value: (Report.Day) -> String?
    }

    private static let dateWidth: CGFloat = 56

    private var columns: [Column] {
        let unit = document.unit
        return [
            Column(title: "CGM", unit: "%", width: 28) { day in
                day.glucose.map { Report.formatPercent($0.coverage) }
            },
            Column(title: "Mean", unit: unit, width: 32) { day in
                day.glucose.map { InsulinStats.formatGlucose($0.mean, unit: unit) }
            },
            Column(title: "SD", unit: unit, width: 28) { day in
                day.glucose?.sd.map { InsulinStats.formatGlucose($0, unit: unit) }
            },
            Column(title: "Low", unit: "%", width: 28) { day in
                day.glucose.map { Report.formatPercent($0.belowRange) }
            },
            Column(title: "In range", unit: "%", width: 36) { day in
                day.glucose.map { Report.formatPercent($0.fraction(.inRange)) }
            },
            Column(title: "High", unit: "%", width: 28) { day in
                day.glucose.map { Report.formatPercent($0.aboveRange) }
            },
            Column(title: "Basal", unit: "U", width: 30) { day in
                day.basalCount > 0 ? Report.formatUnits(day.basal) : nil
            },
            Column(title: "Bolus", unit: "U", width: 30) { day in
                day.bolusCount > 0 ? Report.formatUnits(day.bolus) : nil
            },
            Column(title: "Total", unit: "U", width: 30) { day in
                day.total.map(Report.formatUnits)
            },
            Column(title: "Boluses", unit: "n", width: 32) { day in
                day.bolusCount > 0 ? String(day.bolusCount) : nil
            },
            Column(title: "Workout", unit: "min", width: 34) { day in
                day.workoutMinutes > 0 ? String(day.workoutMinutes) : nil
            },
            Column(title: "Active", unit: "kcal", width: 32) { day in
                day.activeEnergy.map { String(Int($0.rounded())) }
            },
            Column(title: "Weight", unit: document.weightUnit, width: 36) { day in
                day.weight.map { String(format: "%.1f", $0) }
            },
        ]
    }

    private func dayTable(_ days: ArraySlice<Report.Day>, continued: Bool) -> some View {
        let rows = Array(days)
        let columns = self.columns
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Day by day" + (continued ? " (continued)" : ""))
                .padding(.bottom, 6)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeader("Date")
                    Text(" ").font(.system(size: 6.5))
                }
                .frame(width: Self.dateWidth, alignment: .leading)
                ForEach(columns.indices, id: \.self) { index in
                    VStack(alignment: .trailing, spacing: 0) {
                        tableHeader(columns[index].title)
                        Text(columns[index].unit)
                            .font(.system(size: 6.5))
                            .foregroundStyle(ReportStyle.muted)
                    }
                    .frame(width: columns[index].width, alignment: .trailing)
                }
            }
            .lineLimit(1)
            .padding(.vertical, 3)

            Rectangle()
                .fill(ReportStyle.rule)
                .frame(height: 0.5)

            ForEach(rows.indices, id: \.self) { index in
                let day = rows[index]
                HStack(spacing: 0) {
                    Text(Self.shortDay.string(from: day.date))
                        .frame(width: Self.dateWidth, alignment: .leading)
                    ForEach(columns.indices, id: \.self) { column in
                        let text = columns[column].value(day)
                        Text(text ?? "–")
                            .foregroundStyle(text == nil ? ReportStyle.muted : ReportStyle.ink)
                            .frame(width: columns[column].width, alignment: .trailing)
                    }
                }
                .font(.system(size: 8).monospacedDigit())
                .lineLimit(1)
                .frame(height: ReportPDF.rowHeight)
                .background(index.isMultiple(of: 2) ? Color.clear : ReportStyle.surface)
            }
        }
    }

    // MARK: - Appendix: every dose, reading and workout

    private func logTable(_ lines: ArraySlice<Report.LogLine>, continued: Bool) -> some View {
        let all = Array(lines)
        let half = (all.count + 1) / 2
        let left = Array(all.prefix(half))
        let right = Array(all.dropFirst(half))
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Every dose, reading and workout" + (continued ? " (continued)" : "") + " · temperature [8], adj. [7]")
                .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 16) {
                logColumn(left)
                logColumn(right)
            }
        }
    }

    private func logColumn(_ lines: [Report.LogLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                let newDay = index == 0
                    || !Calendar.current.isDate(line.date, inSameDayAs: lines[index - 1].date)
                HStack(spacing: 0) {
                    Text(newDay ? Self.shortDay.string(from: line.date) : "")
                        .foregroundStyle(ReportStyle.secondary)
                        .frame(width: Self.dateWidth, alignment: .leading)
                    Text(Self.time.string(from: line.date))
                        .frame(width: 36, alignment: .leading)
                    Text(line.title)
                        .foregroundStyle(line.isWorkout ? ReportStyle.secondary : ReportStyle.ink)
                        .frame(width: 56, alignment: .leading)
                    Text(line.amount)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: 8).monospacedDigit())
                .lineLimit(1)
                .frame(height: ReportPDF.rowHeight)
                .overlay(alignment: .top) {
                    if newDay && index > 0 {
                        Rectangle()
                            .fill(ReportStyle.rule)
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Low and high events

    private func eventsPage(_ kind: Report.EventKind,
                            _ events: ArraySlice<Report.GlucoseEvent>,
                            first: Bool) -> some View {
        let all = kind == .low ? document.lows : document.highs
        let thresholds = document.eventThresholds
        let name = kind == .low ? "Low events" : "High events"
        return VStack(alignment: .leading, spacing: 10) {
            if first {
                sectionTitle(name)
                HStack(spacing: 3) {
                    Text("Definition:")
                        .foregroundStyle(ReportStyle.secondary)
                    Text(kind == .low ? thresholds.lowDefinition : thresholds.highDefinition)
                    Text("· from CGM · ends 15 min back across the line, or at a CGM gap > 20 min"
                         + (kind == .high ? " · highs within 3 h of each other are one" : ""))
                        .foregroundStyle(ReportStyle.secondary)
                }
                .font(.system(size: 8))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                eventTiles(kind, all)
                legend(Self.eventLegend(kind))
                eventReferences
                if all.isEmpty {
                    Text("None in this period.")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.top, 8)
                }
            } else {
                sectionTitle(name + " (continued)")
            }
            ForEach(Array(events)) { event in
                eventPanel(event)
            }
        }
    }

    private func eventTiles(_ kind: Report.EventKind, _ events: [Report.GlucoseEvent]) -> some View {
        let unit = document.unit
        // Time across the line, so merged highs do not count the gaps
        // between them.
        let minutes = events.map(\.minutesBeyond).sorted()
        let total = minutes.reduce(0, +)
        let median = minutes.isEmpty ? nil : minutes[minutes.count / 2]
        let overnight = events.filter {
            (Calendar.current.dateComponents([.hour], from: $0.start).hour ?? 12) < 6
        }.count
        let extreme = kind == .low ? events.map(\.extreme).min() : events.map(\.extreme).max()
        let weeks = Double(document.days.count) / 7
        return HStack(spacing: 6) {
            StatTile(title: "Events",
                     value: String(events.count),
                     unit: weeks > 0 ? String(format: "%.1f per week", Double(events.count) / weeks) : "")
            StatTile(title: "Time in events",
                     value: Self.formatMinutes(total),
                     unit: "total")
            StatTile(title: "Usual length",
                     value: median.map(Self.formatMinutes) ?? "—",
                     unit: "median")
            StatTile(title: "Overnight",
                     value: String(overnight),
                     unit: "starting 00:00–06:00")
            StatTile(title: kind == .low ? "Lowest" : "Highest",
                     value: extreme.map { InsulinStats.formatGlucose($0, unit: unit) } ?? "—",
                     unit: unit)
        }
    }

    private static func eventLegend(_ kind: Report.EventKind) -> [LegendItem] {
        [
            LegendItem(color: kind == .low ? ReportStyle.color(.low) : ReportStyle.color(.high), label: "Event"),
            LegendItem(color: ReportStyle.profileMedian, label: "CGM"),
            LegendItem(color: ReportStyle.ink, label: "Meter ●"),
            LegendItem(color: ReportStyle.a1c, label: "Meter, temperature-adjusted ◆ [2]"),
            LegendItem(color: ReportStyle.bolus, label: "Bolus · dose, U/h acting"),
            LegendItem(color: ReportStyle.basal, label: "Basal · dose, U/h acting"),
            LegendItem(color: ReportStyle.workout, label: "Workout"),
        ]
    }

    /// What the event pages cite, numbered for these pages.
    private static let eventReferenceList: [String] = [
        "Bolus on board: Scheiner G. Think Like a Pancreas, Table 7-8, \"IOB based on time since bolus was given\", 4 h duration.",
        references[6],
        references[7],
    ]

    private var eventReferences: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.eventReferenceList.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 4) {
                    Text("[\(index + 1)]")
                        .frame(width: 14, alignment: .leading)
                    Text(Self.eventReferenceList[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 6.5))
        .foregroundStyle(ReportStyle.muted)
    }

    private func eventPanel(_ event: Report.GlucoseEvent) -> some View {
        let unit = document.unit
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Self.shortDay.string(from: event.start)) \(Self.time.string(from: event.start))–\(Self.time.string(from: event.end))")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(Self.formatMinutes(event.minutes))
                    .foregroundStyle(ReportStyle.secondary)
                if event.parts > 1 {
                    Text("· \(event.parts) highs, \(Self.formatMinutes(event.minutesBeyond)) above")
                        .foregroundStyle(ReportStyle.secondary)
                }
                if event.reachedUrgent {
                    Text("below \(document.eventThresholds.format(document.eventThresholds.urgentLow))")
                        .foregroundStyle(ReportStyle.color(.veryLow))
                }
                Spacer()
                Text("\(event.kind == .low ? "Lowest" : "Highest") \(InsulinStats.formatGlucose(event.extreme, unit: unit)) \(unit) at \(Self.time.string(from: event.extremeAt))")
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
            }
            eventChart(event)
                .frame(height: 120)
            detailLine("Insulin", insulinText(event))
            detailLine("Exercise", exerciseText(event))
            detailLine("Meter", meterText(event))
        }
        .padding(6)
        .background(ReportStyle.surface, in: RoundedRectangle(cornerRadius: 4))
    }

    private func detailLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(ReportStyle.secondary)
                .frame(width: 42, alignment: .leading)
            Text(text)
                .font(.system(size: 8).monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A time, with its day when it is not the event's.
    private func when(_ date: Date, in event: Report.GlucoseEvent) -> String {
        Calendar.current.isDate(date, inSameDayAs: event.start)
            ? Self.time.string(from: date)
            : "\(Self.shortDay.string(from: date)) \(Self.time.string(from: date))"
    }

    private func insulinText(_ event: Report.GlucoseEvent) -> String {
        var parts = event.doses.map { dose in
            "\(Report.title(for: dose.kind)) \(Report.formatAmount(kind: dose.kind, amount: dose.amount, unit: GlucoseUnit(label: document.unit))) \(when(dose.date, in: event))"
        }
        if parts.isEmpty { parts = ["no bolus in the 4 h before, no basal in the 30 h before"] }
        parts.append("bolus on board at start \(Report.formatUnits((event.bolusOnBoard * 10).rounded() / 10)) U [1]")
        return parts.joined(separator: " · ")
    }

    private func exerciseText(_ event: Report.GlucoseEvent) -> String {
        guard !event.workouts.isEmpty else { return "none in the 6 h before or during" }
        return event.workouts.map { workout in
            var text = "\(workout.name) \(when(workout.start, in: event))–\(Self.time.string(from: workout.end)), \(workout.minutes) min"
            if let kilocalories = workout.kilocalories { text += ", \(Int(kilocalories.rounded())) kcal" }
            if !workout.outdoors { text += ", indoors" }
            return text
        }.joined(separator: " · ")
    }

    private func meterText(_ event: Report.GlucoseEvent) -> String {
        guard !event.meter.isEmpty else { return "none from an hour before to an hour after" }
        let unit = GlucoseUnit(label: document.unit)
        return event.meter.map { reading in
            var text = "\(when(reading.date, in: event)) \(unit.format(reading.value))"
            if let celsius = reading.celsius, let adjusted = reading.adjusted {
                text += " outdoors \(Temperature.format(celsius: celsius)) [3] → adj. \(unit.format(adjusted)) [2]"
            }
            return text
        }.joined(separator: " · ") + " \(unit.label)"
    }

    private func eventChart(_ event: Report.GlucoseEvent) -> some View {
        let meterUnit = GlucoseUnit(label: document.unit)
        let thresholds = document.eventThresholds
        let lines = event.kind == .low ? [thresholds.urgentLow, thresholds.low] : [thresholds.high]
        let meterValues = event.meter.flatMap { reading in
            [meterUnit.display(reading.value)] + (reading.adjusted.map { [meterUnit.display($0)] } ?? [])
        }
        let values = event.cgm.map(\.value) + meterValues + lines
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.08, meterUnit.step * 2)
        let glucoseTop = high + pad
        let glucoseBottom = max(0, low - pad)

        // Insulin acting sits in a band of its own beneath the glucose, on
        // its own scale, read off the right-hand axis: the glucose axis on
        // the left stops where the band begins.
        let band = (glucoseTop - glucoseBottom) * 0.45
        let rateScale = Self.niceRateCeiling(event.activity.map(\.total).max() ?? 0)
        let bandBottom = glucoseBottom - band
        let bandHeight = band * 0.9
        let y: (Double) -> Double = { bandBottom + $0 / rateScale * bandHeight }
        let rateTicks = [0, rateScale / 2, rateScale]

        let shown = event.doses.filter { event.context.contains($0.date) }
        let workouts = event.workouts.filter { $0.end > event.context.lowerBound && $0.start < event.context.upperBound }
        let tint = event.kind == .low ? ReportStyle.color(.low) : ReportStyle.color(.high)

        return Chart {
            RectangleMark(xStart: .value("Start", event.start), xEnd: .value("End", event.end))
                .foregroundStyle(tint.opacity(0.15))
            ForEach(workouts.indices, id: \.self) { index in
                RectangleMark(xStart: .value("Start", max(workouts[index].start, event.context.lowerBound)),
                              xEnd: .value("End", min(workouts[index].end, event.context.upperBound)))
                    .foregroundStyle(ReportStyle.workout.opacity(0.12))
            }
            ForEach(event.activity.indices, id: \.self) { index in
                let sample = event.activity[index]
                AreaMark(x: .value("Time", sample.date),
                         yStart: .value("Rate", y(0)),
                         yEnd: .value("Rate", y(sample.basal)))
                    .foregroundStyle(by: .value("Insulin", "Basal"))
                AreaMark(x: .value("Time", sample.date),
                         yStart: .value("Rate", y(sample.basal)),
                         yEnd: .value("Rate", y(sample.total)))
                    .foregroundStyle(by: .value("Insulin", "Bolus"))
            }
            RuleMark(y: .value("Band", glucoseBottom))
                .foregroundStyle(ReportStyle.rule)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
            ForEach(lines.indices, id: \.self) { index in
                RuleMark(y: .value("Line", lines[index]))
                    .foregroundStyle(tint.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
            }
            ForEach(event.cgm.indices, id: \.self) { index in
                LineMark(x: .value("Time", event.cgm[index].date),
                         y: .value("Glucose", event.cgm[index].value),
                         series: .value("Series", "CGM"))
                    .foregroundStyle(ReportStyle.profileMedian)
                    .lineStyle(StrokeStyle(lineWidth: 1.1))
            }
            ForEach(shown.indices, id: \.self) { index in
                let dose = shown[index]
                RuleMark(x: .value("Dose", dose.date))
                    .foregroundStyle(dose.kind == .basal ? ReportStyle.basal : ReportStyle.bolus)
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
                    .annotation(position: .trailing, alignment: .top, spacing: 1) {
                        Text("\(Report.formatUnits(dose.amount)) U")
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(dose.kind == .basal ? ReportStyle.basal : ReportStyle.bolus)
                    }
            }
            ForEach(event.meter.indices, id: \.self) { index in
                let reading = event.meter[index]
                let raw = meterUnit.display(reading.value)
                if let adjusted = reading.adjusted.map(meterUnit.display) {
                    RuleMark(x: .value("Time", reading.date),
                             yStart: .value("Meter", raw),
                             yEnd: .value("Adjusted", adjusted))
                        .foregroundStyle(ReportStyle.a1c.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 0.8))
                    PointMark(x: .value("Time", reading.date), y: .value("Adjusted", adjusted))
                        .symbol(.diamond)
                        .symbolSize(22)
                        .foregroundStyle(ReportStyle.a1c)
                }
                PointMark(x: .value("Time", reading.date), y: .value("Meter", raw))
                    .symbol(.circle)
                    .symbolSize(18)
                    .foregroundStyle(ReportStyle.ink)
            }
        }
        .chartForegroundStyleScale([
            "Basal": ReportStyle.basal.opacity(0.4),
            "Bolus": ReportStyle.bolus.opacity(0.5),
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: event.context)
        .chartYScale(domain: bandBottom...glucoseTop)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(ReportStyle.grid)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 7))
                    .foregroundStyle(ReportStyle.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Self.niceTicks(glucoseBottom...glucoseTop)) { value in
                AxisGridLine().foregroundStyle(ReportStyle.grid)
                AxisValueLabel {
                    Text(Self.axisLabel(value))
                        .font(.system(size: 7))
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(ReportStyle.secondary)
                }
            }
            AxisMarks(position: .trailing, values: rateTicks.map(y)) { value in
                AxisValueLabel {
                    Text(Self.rateLabel(value, bandBottom: bandBottom, bandHeight: bandHeight, scale: rateScale))
                        .font(.system(size: 6.5))
                        .foregroundStyle(ReportStyle.secondary)
                }
            }
        }
        .font(.system(size: 7.5))
    }

    /// The top of the insulin band: the smallest round rate at or over the
    /// highest, so the band's axis reads in whole steps.
    private static func niceRateCeiling(_ rate: Double) -> Double {
        let steps: [Double] = [0.5, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50]
        return steps.first { $0 >= rate } ?? (rate / 10).rounded(.up) * 10
    }

    /// A tick of the insulin band's axis, back in units per hour; the unit
    /// on the top one only.
    private static func rateLabel(_ value: AxisValue,
                                  bandBottom: Double,
                                  bandHeight: Double,
                                  scale: Double) -> String {
        let rate = ((value.as(Double.self) ?? bandBottom) - bandBottom) / bandHeight * scale
        let rounded = (rate * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return rounded >= scale - 0.05 ? text + " U/h" : text
    }

    /// About four round values inside `range`, for an axis that must not
    /// run on into the insulin band below it.
    private static func niceTicks(_ range: ClosedRange<Double>) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return [range.lowerBound] }
        let raw = span / 4
        let magnitude = pow(10, log10(raw).rounded(.down))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        let first = (range.lowerBound / step).rounded(.up) * step
        return Array(stride(from: first, through: range.upperBound, by: step))
    }

    /// "45 min", "2 h 05 min"
    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    // MARK: - Formatting

    private var rangeText: String {
        "\(Self.mediumDate.string(from: document.start)) – \(Self.mediumDate.string(from: document.lastDay))"
    }

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// "Mon 14 Jul" in the phone's own order of day and month.
    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Pieces

/// A figure, its name above and its unit below. The unit is on every tile
/// because a row of tiles is read one at a time, not left to right.
private struct StatTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(ReportStyle.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
            Text(unit)
                .font(.system(size: 7))
                .foregroundStyle(ReportStyle.muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(ReportStyle.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The AGP's stacked bar: the five bands as a column, very high at the top.
/// It carries no numbers of its own — the table beside it does — and a
/// two-point gap keeps adjacent bands apart when printed in grey.
private struct TimeInRangeBar: View {
    let summary: Report.GlucoseSummary

    private static let height: CGFloat = 120

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Report.Band.allCases.reversed(), id: \.self) { band in
                let fraction = summary.fraction(band)
                if fraction > 0 {
                    Rectangle()
                        .fill(ReportStyle.color(band))
                        .frame(height: max(1.5, Self.height * fraction))
                }
            }
        }
        .frame(width: 44)
    }
}

/// Print colours. Fixed rather than dynamic — paper has one appearance — and
/// chosen so each pair that sits side by side stays apart for colour-blind
/// readers and in greyscale.
enum ReportStyle {
    static let ink = color(0x0b0b0b)
    static let secondary = color(0x52514e)
    static let muted = color(0x8a8984)
    static let rule = color(0xc9c8c2)
    static let grid = color(0xe1e0d9)
    static let surface = color(0xf4f3ef)

    static let glucose = color(0xd55181)
    static let profileMedian = color(0x184f95)
    static let profileInner = color(0x86b6ef)
    static let profileOuter = color(0xcde2fb)
    /// Two steps of one blue: basal the darker, as the larger and steadier half.
    static let basal = color(0x104281)
    static let bolus = color(0x5598e7)
    static let workout = color(0x0f6b4a)
    static let otherActivity = color(0x1baf7a)
    static let weight = color(0x6250d6)
    static let a1c = color(0xb35a3e)
    static let gmi = color(0x184f95)

    static func color(_ band: Report.Band) -> Color {
        switch band {
        case .veryLow: return color(0xa11a14)
        case .low: return color(0xe66767)
        case .inRange: return color(0x008300)
        case .high: return color(0xeda100)
        case .veryHigh: return color(0xb85a10)
        }
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255)
    }
}
