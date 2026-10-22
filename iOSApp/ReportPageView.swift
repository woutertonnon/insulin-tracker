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
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insulin & glucose report")
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
            sectionTitle("Every dose, reading and workout" + (continued ? " (continued)" : ""))
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
