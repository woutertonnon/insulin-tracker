import SwiftUI
import Charts

/// One page of the doctor's report, at paper size.
///
/// Printed, quite possibly in black and white, and read by someone who has
/// never seen the app — so every figure carries its unit, every chart says in
/// words what its bands and bars are, and nothing is said by colour alone.
/// Type is small because a clinic reads this across a desk, not on a phone.
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
        case .charts:
            charts
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
                Text("Generated \(Self.longDate.string(from: document.generated))")
                Text("Glucose in \(document.unit)")
            }
            .font(.system(size: 8))
            .foregroundStyle(ReportStyle.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("Recorded by the patient with Insulin Tracker. Describes what happened; not a dosing recommendation.")
            Spacer()
            Text("Page \(number) of \(count)")
        }
        .font(.system(size: 7.5))
        .foregroundStyle(ReportStyle.muted)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
            if let detail {
                Text(detail)
                    .foregroundStyle(ReportStyle.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .italic()
            .foregroundStyle(ReportStyle.secondary)
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 4) {
                    Text("•")
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Page 1: summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glucose from a continuous glucose monitor, via Apple Health. Insulin, carbohydrate and meals as logged by the patient on an Apple Watch at the time of each dose. Exercise and weight from Apple Health. No figure here has been reviewed by a clinician.")
                .foregroundStyle(ReportStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sectionTitle("Glucose", detail: glucoseDetail)
            if let glucose = document.glucose {
                glucoseTiles(glucose)
                HStack(alignment: .top, spacing: 16) {
                    TimeInRangeBar(summary: glucose)
                    bandTable(glucose)
                    Spacer(minLength: 0)
                }
                profileChart
            } else {
                emptyNote("No CGM readings in this period.")
            }

            sectionTitle("Insulin and food", detail: insulinDetail)
            insulinTiles

            if !caveats.isEmpty {
                sectionTitle("Read with")
                bullets(caveats)
                    .foregroundStyle(ReportStyle.secondary)
            }
        }
    }

    private var glucoseDetail: String? {
        guard let glucose = document.glucose else { return nil }
        return "\(glucose.count) readings · CGM active \(Report.formatPercent(glucose.coverage)) of the period"
    }

    private var insulinDetail: String {
        let insulin = document.insulin
        return insulin.loggedDays == document.days.count
            ? "logged on all \(insulin.loggedDays) days"
            : "the log covers \(insulin.loggedDays) of the \(document.days.count) days"
    }

    private func glucoseTiles(_ glucose: Report.GlucoseSummary) -> some View {
        let unit = document.unit
        return HStack(spacing: 6) {
            StatTile(title: "Mean glucose",
                     value: InsulinStats.formatGlucose(glucose.mean, unit: unit),
                     unit: unit)
            StatTile(title: "GMI",
                     value: A1c.gmi(fromMeanGlucose: glucose.mean, unit: unit).map(A1c.format) ?? "—",
                     unit: "% · Bergenstal 2018")
            StatTile(title: "Estimated A1c",
                     value: A1c.fromMeanGlucose(glucose.mean, unit: unit).map(A1c.format) ?? "—",
                     unit: "% · ADAG 2008")
            StatTile(title: "SD",
                     value: glucose.sd.map { InsulinStats.formatGlucose($0, unit: unit) } ?? "—",
                     unit: unit)
            StatTile(title: "CV",
                     value: glucose.cv.map { String(format: "%.0f", $0) } ?? "—",
                     unit: "% · goal ≤ 36%")
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
                tableHeader("Goal")
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
            GridRow {
                Text("")
                Text("Goals are the international consensus for most adults with type 1 or type 2 diabetes. Targets are individual.")
                    .foregroundStyle(ReportStyle.muted)
                    .font(.system(size: 7.5))
                    .gridCellColumns(5)
            }
        }
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(ReportStyle.secondary)
    }

    /// The AGP's central chart: every reading folded onto one day.
    private var profileChart: some View {
        let bins = document.profilePlot
        let targets = document.targets
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Daily profile")
                    .font(.system(size: 10, weight: .semibold))
                Text("every reading in the period by time of day · dark line the median, mid band 25–75%, light band 5–95% · shaded strip the target range")
                    .foregroundStyle(ReportStyle.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

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
                    "5–95%": ReportStyle.profileOuter,
                    "25–75%": ReportStyle.profileInner,
                    "Median": ReportStyle.profileMedian,
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: 0.0...24.0)
                .chartXAxis {
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
                .frame(height: 170)
            } else {
                emptyNote("Too few readings to draw a profile.")
            }
        }
    }

    private var insulinTiles: some View {
        let insulin = document.insulin
        let food = document.food
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
            StatTile(title: "Carbs logged",
                     value: food.carbsPerLoggedDay.map { String(Int($0.rounded())) } ?? "—",
                     unit: food.daysWithCarbs > 0 ? "g per day, on \(food.daysWithCarbs) days" : "g per day")
        }
    }

    /// Everything that makes a figure above mean less than it looks like it
    /// means, said on the page rather than left for the clinic to notice.
    private var caveats: [String] {
        var notes: [String] = []
        let insulin = document.insulin
        let total = document.days.count

        if insulin.loggedDays == 0 {
            notes.append("No insulin or food was logged in this period, so the insulin figures are blank.")
        } else if insulin.loggedDays < total {
            notes.append("The log begins \(Self.mediumDate.string(from: document.days[total - insulin.loggedDays].date)); per-day insulin is divided by the \(insulin.loggedDays) days it covers, not by \(total).")
        }
        if insulin.basalGapDays > 0 {
            notes.append("\(insulin.basalGapDays) of the \(insulin.loggedDays) logged days have no basal entry. A missed entry and a missed injection look the same here, and both lower the per-day figures.")
        }
        if let glucose = document.glucose, glucose.coverage < 0.8 {
            notes.append("The CGM covered \(Report.formatPercent(glucose.coverage)) of the period; the glucose figures describe the covered part only.")
        }
        if document.food.mealsBySize > 0 {
            notes.append("\(document.food.mealsBySize) meals were logged by size only (snack, small, medium…) and carry no gram figure, so carbohydrate per day understates what was eaten.")
        }
        return notes
    }

    // MARK: - Page 2: day by day

    private var charts: some View {
        let chartCount = 2 + (document.hasCarbs ? 1 : 0) + (document.hasEnergy ? 1 : 0) + (document.hasWeight ? 1 : 0)
        // Share the page between however many charts there are, within reason.
        let available = ReportPDF.pageSize.height - 2 * ReportPDF.margin - 150
        let height = min(150, available / CGFloat(chartCount) - 22)

        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Day by day", detail: "one mark per calendar day; a missing mark is a day with nothing recorded")

            dayChart("Mean glucose",
                     unit: document.unit,
                     note: "dashed lines at the edges of the target range",
                     height: height) {
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

            dayChart("Insulin",
                     unit: "U per day",
                     note: "dark part basal, light part bolus",
                     height: height) {
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

            if document.hasCarbs {
                dayChart("Carbohydrate logged",
                         unit: "g per day",
                         note: "only meals entered in grams; meals logged by size carry no figure",
                         height: height) {
                    ForEach(document.days) { day in
                        if let carbs = day.carbs {
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Grams", carbs))
                                .foregroundStyle(ReportStyle.carbs)
                        }
                    }
                }
            }

            if document.hasEnergy {
                dayChart("Active energy",
                         unit: "kcal per day",
                         note: "all movement, from Apple Health; the dark part was inside a recorded workout",
                         height: height) {
                    ForEach(document.days) { day in
                        if let energy = day.activeEnergy {
                            let workout = min(energy, day.workouts.reduce(0.0) { $0 + ($1.kilocalories ?? 0) })
                            if workout > 0 {
                                BarMark(x: .value("Day", day.date, unit: .day), y: .value("kcal", workout))
                                    .foregroundStyle(by: .value("Source", "Workouts"))
                            }
                            if energy - workout > 0 {
                                BarMark(x: .value("Day", day.date, unit: .day), y: .value("kcal", energy - workout))
                                    .foregroundStyle(by: .value("Source", "Other"))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "Workouts": ReportStyle.workout,
                    "Other": ReportStyle.otherActivity,
                ])
            }

            if document.hasWeight {
                dayChart("Weight",
                         unit: document.weightUnit,
                         note: "dots on the days it was recorded; the line between them is interpolation",
                         height: height,
                         yDomain: weightDomain) {
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

    private func dayChart<Content: ChartContent>(
        _ title: String,
        unit: String,
        note: String,
        height: CGFloat,
        yDomain: ClosedRange<Double>? = nil,
        @ChartContentBuilder content: () -> Content
    ) -> some View {
        let chart = Chart {
            content()
        }
        .chartXScale(domain: document.start...document.end)
        .chartLegend(.hidden)
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
        .frame(height: height)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text(unit)
                    .foregroundStyle(ReportStyle.secondary)
                Text("· \(note)")
                    .foregroundStyle(ReportStyle.muted)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

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

    // MARK: - Page 3: notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Basal")
            Text(basalText)
                .fixedSize(horizontal: false, vertical: true)

            sectionTitle("Insulin-to-carb ratio", detail: "last 28 days, measured from logged meals — the app's own estimate")
            carbRatioBlock

            sectionTitle("How the figures were made")
            bullets(definitions)

            sectionTitle("Limits")
            bullets(limits)
        }
    }

    private var basalText: String {
        let insulin = document.insulin
        guard insulin.daysWithBasal > 0, let dose = insulin.basalDose else {
            return "No long-acting insulin was logged in this period."
        }
        var text = "Long-acting insulin was logged on \(insulin.daysWithBasal) of \(insulin.loggedDays) days"
        if insulin.basalGapDays > 0 {
            text += " — \(insulin.basalGapDays) without an entry"
        }
        text += ". The usual dose was \(Report.formatUnits(dose)) U"
        if let range = insulin.basalDoseRange, range.lowerBound != range.upperBound {
            text += " (from \(Report.formatUnits(range.lowerBound)) to \(Report.formatUnits(range.upperBound)))"
        }
        if let minute = insulin.basalMinuteOfDay {
            text += ", typically around \(Report.formatMinuteOfDay(minute))"
        }
        text += "."
        return text
    }

    @ViewBuilder
    private var carbRatioBlock: some View {
        if let estimate = document.carbRatio, let isf = estimate.isf {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    tableHeader("No exercise")
                    tableHeader("With exercise")
                }
                ForEach(CarbRatio.Daypart.allCases, id: \.self) { part in
                    GridRow {
                        Text(part.rawValue)
                            .foregroundStyle(ReportStyle.secondary)
                        carbRatioCell(estimate, part: part, exercise: false)
                        carbRatioCell(estimate, part: part, exercise: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let pooled = estimate.pooled {
                    Text("All meals together: \(CarbRatio.format(pooled)).")
                }
                Text("Sensitivity measured from \(estimate.isfSampleCount) correction dose\(estimate.isfSampleCount == 1 ? "" : "s") taken with no food near them: 1 U moved glucose by about \(String(format: "%.1f", isf)) \(document.unit).")
                Text("Morning 04:00–11:00, lunch 11:00–17:00, dinner 17:00–04:00. Each figure is the median over its meals, from glucose at the meal against four hours later, with the miss converted into the insulin that was missing. Cells with fewer than \(CarbRatio.minimumEpisodes) meals are left blank.")
                    .foregroundStyle(ReportStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            emptyNote("Not enough clean correction doses in the last 28 days to measure sensitivity, so no ratio could be derived.")
        }
    }

    private func carbRatioCell(_ estimate: CarbRatio.Estimate,
                               part: CarbRatio.Daypart,
                               exercise: Bool) -> some View {
        let cell = estimate.cells.first { $0.daypart == part && $0.withExercise == exercise }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let ratio = cell?.ratio {
                Text(CarbRatio.format(ratio))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Text("\(cell?.episodeCount ?? 0) meals")
                    .foregroundStyle(ReportStyle.muted)
            } else {
                Text("—")
                    .foregroundStyle(ReportStyle.muted)
                Text("\(cell?.episodeCount ?? 0) of \(CarbRatio.minimumEpisodes) meals")
                    .foregroundStyle(ReportStyle.muted)
            }
        }
    }

    private var definitions: [String] {
        let targets = document.targets
        return [
            "Time in range is the share of CGM readings in each band. The bands — \(targets.range(.inRange)) \(document.unit) in range, below \(InsulinStats.formatGlucose(targets.veryLow, unit: document.unit)) very low, above \(InsulinStats.formatGlucose(targets.veryHigh, unit: document.unit)) very high — and the goals beside them are the 2019 international consensus on time in range (Battelino et al.).",
            "CGM active is the share of the period with a reading no more than 20 minutes from the next. Gaps are sensor warm-ups, lost signal, or data the Dexcom app had not yet uploaded.",
            "Mean and SD are over every reading in the period; CV is SD divided by mean. The daily profile folds every reading onto one day in half-hour bins; a bin with fewer than five readings is left blank.",
            "GMI is the glucose management indicator (Bergenstal et al., 2018) and estimated A1c the ADAG regression (Nathan et al., 2008), both from the mean glucose of this period alone. They are estimates from a population fit, not a laboratory result, and they can differ from each other by a few tenths.",
            "Insulin per day is the units logged divided by the days the log covers, counted from the first entry ever made. Basal and bolus are as entered by the patient; a dose taken but not logged is absent here.",
            "Carbohydrate counts only amounts entered in grams. Meals logged by size (snack, small, medium, large, very large) are counted but carry no gram figure.",
            "Active energy is all movement for the day as Apple Health records it, with the part inside a recorded workout shown separately. Weight is as entered in Apple Health, in its unit.",
        ]
    }

    private var limits: [String] {
        [
            "Insulin and food are logged by hand on a watch. The CGM trace is the only series here that does not depend on anyone remembering anything.",
            "The insulin-to-carb ratio is a description of how logged meals turned out, not a setting. It is only as good as the meals behind it and is listed with their count.",
            "Nothing in this report is a dose recommendation. It describes what already happened.",
        ]
    }

    // MARK: - Pages 4+: the day table

    private struct Column {
        let title: String
        let unit: String
        let width: CGFloat
        let value: (Report.Day) -> String?
    }

    private static let dateWidth: CGFloat = 54

    private var columns: [Column] {
        let unit = document.unit
        return [
            Column(title: "CGM", unit: "%", width: 26) { day in
                day.glucose.map { Report.formatPercent($0.coverage) }
            },
            Column(title: "Mean", unit: unit, width: 30) { day in
                day.glucose.map { InsulinStats.formatGlucose($0.mean, unit: unit) }
            },
            Column(title: "SD", unit: unit, width: 26) { day in
                day.glucose?.sd.map { InsulinStats.formatGlucose($0, unit: unit) }
            },
            Column(title: "Low", unit: "%", width: 26) { day in
                day.glucose.map { Report.formatPercent($0.belowRange) }
            },
            Column(title: "In range", unit: "%", width: 34) { day in
                day.glucose.map { Report.formatPercent($0.fraction(.inRange)) }
            },
            Column(title: "High", unit: "%", width: 26) { day in
                day.glucose.map { Report.formatPercent($0.aboveRange) }
            },
            Column(title: "Basal", unit: "U", width: 28) { day in
                day.basalCount > 0 ? Report.formatUnits(day.basal) : nil
            },
            Column(title: "Bolus", unit: "U", width: 28) { day in
                day.bolusCount > 0 ? Report.formatUnits(day.bolus) : nil
            },
            Column(title: "Total", unit: "U", width: 28) { day in
                day.total.map(Report.formatUnits)
            },
            Column(title: "Doses", unit: "bolus", width: 28) { day in
                day.bolusCount > 0 ? String(day.bolusCount) : nil
            },
            Column(title: "Carbs", unit: "g", width: 28) { day in
                day.carbs.map { String(Int($0.rounded())) }
            },
            Column(title: "Meals", unit: "by size", width: 30) { day in
                day.mealsBySize > 0 ? String(day.mealsBySize) : nil
            },
            Column(title: "Workout", unit: "min", width: 32) { day in
                day.workoutMinutes > 0 ? String(day.workoutMinutes) : nil
            },
            Column(title: "Active", unit: "kcal", width: 30) { day in
                day.activeEnergy.map { String(Int($0.rounded())) }
            },
            Column(title: "Weight", unit: document.weightUnit, width: 34) { day in
                day.weight.map { String(format: "%.1f", $0) }
            },
        ]
    }

    private func dayTable(_ days: ArraySlice<Report.Day>, continued: Bool) -> some View {
        let rows = Array(days)
        let columns = self.columns
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Day by day" + (continued ? " (continued)" : ""),
                         detail: "a dash is a day with nothing recorded for that column")
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

    // MARK: - Appendix: every entry

    private func logTable(_ lines: ArraySlice<Report.LogLine>, continued: Bool) -> some View {
        let all = Array(lines)
        let half = (all.count + 1) / 2
        let left = Array(all.prefix(half))
        let right = Array(all.dropFirst(half))
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Every entry" + (continued ? " (continued)" : ""),
                         detail: "insulin, food and workouts in time order")
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
/// because a page of tiles is read one at a time, not left to right.
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

    private static let height: CGFloat = 150

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
    static let carbs = color(0xeb6834)
    static let workout = color(0x0f6b4a)
    static let otherActivity = color(0x1baf7a)
    static let weight = color(0x6250d6)

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
