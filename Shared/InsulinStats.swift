import Foundation

/// Insulin and glucose averaged over fixed look-back windows, so a change in
/// sensitivity shows up as a trend rather than as a feeling.
///
/// Every window **ends at the newest glucose reading**, not at the clock. Dexcom
/// uploads to Health in batches, so "now" is regularly an hour ahead of the last
/// sample; anchoring on the clock would leave each window with a ragged empty
/// tail that moves the averages around for no reason.
///
/// The headline figure is total daily insulin divided by mean glucose: how much
/// insulin it took to hold a given glucose. Holding diet roughly constant, that
/// rises when you need more insulin for the same result — so it goes **up as
/// sensitivity goes down**. It is a resistance index, not a sensitivity one.
///
/// Nothing here is a dosing instruction. It describes what already happened.
enum InsulinStats {

    // MARK: - Inputs

    struct GlucosePoint: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    /// One injection. Basal and bolus are kept apart because they answer
    /// different questions — background need versus what food and corrections
    /// cost — and because basal is the half that goes unlogged.
    struct Dose: Hashable, Sendable {
        let date: Date
        let units: Double
        let isBasal: Bool
    }

    // MARK: - Parameters

    /// Look-back lengths, in days. Short windows catch a change, long ones say
    /// whether it is real.
    static let windowLengths = [3, 7, 30, 90]

    private static let day: TimeInterval = 24 * 3600

    /// How far back Health has to be queried to fill the longest window.
    static var longestWindow: TimeInterval { Double(windowLengths.max() ?? 0) * day }

    /// Shortest run of logging a per-day average may be divided by. Below this
    /// the division is dominated by whether today happens to have a basal in it
    /// yet.
    private static let minimumCoverage: Double = 1

    /// Longest gap between consecutive readings still counted as covered. A
    /// sensor writing every five minutes clears it easily; a warm-up or a lost
    /// transmitter does not.
    private static let maximumGap: TimeInterval = 20 * 60

    // MARK: - Outputs

    struct Window: Identifiable, Sendable {
        let days: Int
        let start: Date
        /// The newest glucose reading. Shared by every window.
        let end: Date

        /// Mean of the readings in the window. Sample mean, not time-weighted:
        /// with a CGM writing on a fixed cadence the two agree, and where they
        /// do not — a gap — `glucoseCoverage` says so outright.
        let meanGlucose: Double?
        /// Sample standard deviation (n − 1), the usual CGM convention.
        let sdGlucose: Double?
        let glucoseCount: Int
        /// Fraction of the window with CGM data behind it. A mean over 30% of a
        /// window is a mean of those 30%, whatever the label says.
        let glucoseCoverage: Double

        let basalPerDay: Double?
        let bolusPerDay: Double?
        let basalCount: Int
        let bolusCount: Int
        /// Distinct days carrying at least one basal entry, and one bolus entry.
        /// Not denominators — a warning. See `basalIsSpotty`.
        let basalDays: Int
        let bolusDays: Int
        /// Days of insulin log the per-day figures were divided by — the window
        /// length, or less if logging does not reach back that far.
        ///
        /// Elapsed time rather than a count of days with entries, because a
        /// window ends mid-afternoon: it holds the tail of its first day and the
        /// head of its last, which together make one day but touch two. Counting
        /// days would divide three days of doses by four dates.
        ///
        /// > On a window longer than the log, this measures from the first entry,
        /// > so a daily basal has its first dose sitting on the very start of the
        /// > span — worth about one day in N. Those windows are marked partial.
        let loggedDays: Double

        var id: Int { days }

        var totalPerDay: Double? {
            guard let basalPerDay, let bolusPerDay else { return nil }
            return basalPerDay + bolusPerDay
        }

        /// Units per day per unit of glucose. Its size depends on whether Health
        /// is set to mmol/L or mg/dL, so it is comparable across windows and
        /// across time — never against someone else's number.
        var insulinPerGlucose: Double? {
            guard let totalPerDay, let meanGlucose, meanGlucose > 0 else { return nil }
            return totalPerDay / meanGlucose
        }

        var hasDoses: Bool { basalCount + bolusCount > 0 }

        /// The log does not reach back across the whole window, so the per-day
        /// figures cover less ground than the heading claims.
        var isPartial: Bool { hasDoses && loggedDays < Double(days) - 0.5 }

        /// No basal logged at all. Basal is usually the larger half of the daily
        /// total, so this does not make the total slightly low — it makes it
        /// wrong, and the index with it.
        var missingBasal: Bool { basalCount == 0 && bolusCount > 0 }

        /// Whole days of the window with no basal on them.
        ///
        /// A missed *log* and a missed *injection* look identical from here, and
        /// either way the average is divided by days it has no insulin for. This
        /// is the larger error in practice — forgetting five days in thirty
        /// takes a sixth off the total and off the index with it — and unlike a
        /// missing sensor there is nothing on screen that would otherwise show
        /// it.
        var basalGapDays: Int { max(0, Int(loggedDays.rounded()) - basalDays) }

        /// One day's slack for the partial day at either end of the window.
        var basalIsSpotty: Bool { basalCount > 0 && basalGapDays > 1 }
    }

    struct Summary: Sendable {
        /// Newest glucose reading; every window ends here. Nil when Health has
        /// returned no glucose at all, which disables the whole thing.
        let anchor: Date?
        let windows: [Window]
    }

    // MARK: - Summarising

    static func summarise(glucose: [GlucosePoint], doses: [Dose]) -> Summary {
        // Sorted once, then sliced. The four windows share an end and differ
        // only in where they start, so a binary search per window beats four
        // scans of three months of CGM — and this recomputes on every redraw of
        // the view holding it.
        let series = glucose.sorted { $0.date < $1.date }
        guard let anchor = series.last?.date else {
            return Summary(anchor: nil, windows: [])
        }

        // Earliest dose of any age, not just in the window: it is what says how
        // far the log actually reaches back.
        let logStart = doses.map(\.date).min()

        let windows = windowLengths.map { days -> Window in
            let span = Double(days) * day
            let start = anchor.addingTimeInterval(-span)

            // Everything from here to the end: `anchor` is the last element, so
            // the upper bound needs no search.
            let readings = series[firstIndex(of: series, after: start)...]
            let (mean, sd) = moments(readings)

            let inWindow = doses.filter { $0.date > start && $0.date <= anchor }
            let basal = inWindow.filter(\.isBasal)
            let bolus = inWindow.filter { !$0.isBasal }

            // Divide by how long the log runs inside this window, not by the
            // window length. Ninety days of denominator against thirty days of
            // logging would read as a third of the insulin actually taken, and
            // the index would inherit the same error.
            let from = max(start, logStart ?? anchor)
            let covered = min(Double(days), anchor.timeIntervalSince(from) / day)
            let usable = covered >= minimumCoverage && !inWindow.isEmpty

            return Window(
                days: days,
                start: start,
                end: anchor,
                meanGlucose: mean,
                sdGlucose: sd,
                glucoseCount: readings.count,
                glucoseCoverage: coverage(readings, over: span),
                basalPerDay: usable ? basal.reduce(0.0) { $0 + $1.units } / covered : nil,
                bolusPerDay: usable ? bolus.reduce(0.0) { $0 + $1.units } / covered : nil,
                basalCount: basal.count,
                bolusCount: bolus.count,
                basalDays: distinctDays(basal),
                bolusDays: distinctDays(bolus),
                loggedDays: covered
            )
        }

        return Summary(anchor: anchor, windows: windows)
    }

    // MARK: - Helpers

    /// Index of the first reading after `date`, or `endIndex` if there is none.
    /// Requires `series` sorted ascending, which `summarise` guarantees.
    private static func firstIndex(of series: [GlucosePoint], after date: Date) -> Int {
        var low = 0
        var high = series.count
        while low < high {
            let mid = (low + high) / 2
            if series[mid].date <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// How many separate days the doses fall on.
    private static func distinctDays(_ doses: [Dose],
                                     calendar: Calendar = .current) -> Int {
        Set(doses.map { calendar.startOfDay(for: $0.date) }).count
    }

    /// Mean, and sample standard deviation (n − 1) about it — the usual CGM
    /// convention. Two passes over the slice rather than a running sum of
    /// squares: it allocates nothing either way, and subtracting a known mean
    /// does not lose precision the way squaring raw glucose values would.
    private static func moments(_ readings: ArraySlice<GlucosePoint>) -> (mean: Double?, sd: Double?) {
        let count = readings.count
        guard count > 0 else { return (nil, nil) }

        var sum = 0.0
        for reading in readings { sum += reading.value }
        let mean = sum / Double(count)

        guard count > 1 else { return (mean, nil) }
        var squares = 0.0
        for reading in readings {
            let deviation = reading.value - mean
            squares += deviation * deviation
        }
        return (mean, (squares / Double(count - 1)).squareRoot())
    }

    /// Fraction of `span` with readings behind it.
    ///
    /// Measured from the gaps between consecutive readings rather than from an
    /// assumed sample rate, so it stays honest whatever cadence the sensor
    /// writes at — and a run of missing days reads as missing rather than as a
    /// thinner average. Requires `readings` sorted ascending.
    ///
    /// > N readings bound only N − 1 gaps, so a fully covered window reads a
    /// > sample interval short of 100%. At five-minute cadence that is 0.1% of
    /// > three days, well under the threshold anything is reported at.
    private static func coverage(_ readings: ArraySlice<GlucosePoint>,
                                 over span: TimeInterval) -> Double {
        guard span > 0, readings.count > 1 else { return 0 }
        var covered: TimeInterval = 0
        for (previous, next) in zip(readings, readings.dropFirst()) {
            covered += min(next.date.timeIntervalSince(previous.date), maximumGap)
        }
        return min(1, covered / span)
    }

    // MARK: - Formatting

    /// mmol/L wants a decimal, mg/dL does not.
    static func formatGlucose(_ value: Double, unit: String) -> String {
        unit.contains("mol") ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    static func formatUnits(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// The insulin-per-glucose index. Roughly 3–6 in mmol/L and roughly 0.2–0.4
    /// in mg/dL, so the decimals follow the unit rather than being fixed.
    static func formatIndex(_ value: Double, unit: String) -> String {
        unit.contains("mol") ? String(format: "%.2f", value) : String(format: "%.3f", value)
    }
}
