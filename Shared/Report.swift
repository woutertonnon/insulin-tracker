import Foundation

/// What a clinic visit wants on paper, computed once from the same records the
/// screens are built from.
///
/// Modelled on the Ambulatory Glucose Profile (AGP) report, which is the form
/// clinicians already read CGM data in: time in range against the standard
/// bands, mean and variability, a glucose management indicator, and the
/// median-and-percentile shape of a day. The things a CGM report cannot know —
/// insulin, food, exercise, weight — are set beside it, as per-day figures and
/// as a day-by-day table.
///
/// Days are **whole calendar days ending yesterday**. A report generated at
/// eleven in the morning should not carry a day with a third of its readings
/// in it, and a dated range reads more easily across a desk than "the last 90
/// days from 10:42".
///
/// Nothing here is a dosing instruction. It describes what already happened.
enum Report {

    // MARK: - Inputs

    struct GlucosePoint: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    struct Event: Hashable, Sendable {
        let date: Date
        let kind: EntryKind
        let amount: Double
        /// Outside air at a reading, °C, where known.
        var temperature: Double? = nil
        /// The badge as saved; nil only on a row from before it existed, which
        /// is decided from the place, the workouts and the wrist.
        var outdoors: Bool? = nil
        /// Whether the person set it themselves.
        var chosen: Bool? = nil
        /// What the wrist saw just before: cycling or running.
        var moving: Bool? = nil
        /// Where, for the places marked inside before.
        var latitude: Double? = nil
        var longitude: Double? = nil

        /// This reading as a lesson about its place, if the person chose.
        var mark: Temperature.Mark? {
            guard kind == .glucose, chosen == true, let outdoors, let latitude, let longitude else { return nil }
            return Temperature.Mark(latitude: latitude, longitude: longitude, outdoors: outdoors)
        }
    }

    struct Workout: Hashable, Sendable {
        let start: Date
        let end: Date
        let name: String
        let kilocalories: Double?
        /// Which side of the door, as Health has it.
        var outdoors: Bool = true

        var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    }

    struct Energy: Hashable, Sendable {
        let day: Date
        let kilocalories: Double
    }

    struct Weight: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    // MARK: - Periods

    /// Fourteen days is what an AGP covers; ninety is the span between visits.
    enum Period: Int, CaseIterable, Identifiable, Sendable {
        case fortnight = 14
        case month = 30
        case quarter = 90

        var id: Int { rawValue }
        var days: Int { rawValue }

        var title: String {
            switch self {
            case .fortnight: return "14 days"
            case .month: return "30 days"
            case .quarter: return "90 days"
            }
        }
    }

    static let longestPeriod = Period.allCases.map(\.days).max() ?? 0

    /// The earliest instant Health has to be queried from for the longest
    /// period to be complete — the longest period of whole days before today.
    static func queryStart(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -longestPeriod, to: today) ?? today
    }

    // MARK: - Glucose bands

    /// The five bands of the international consensus on time in range
    /// (Battelino et al., 2019), which is what a clinic will compare against.
    enum Band: CaseIterable, Hashable, Sendable {
        case veryLow
        case low
        case inRange
        case high
        case veryHigh

        var title: String {
            switch self {
            case .veryLow: return "Very low"
            case .low: return "Low"
            case .inRange: return "In range"
            case .high: return "High"
            case .veryHigh: return "Very high"
            }
        }

        /// The consensus goal for adults with type 1 or type 2 diabetes, as a
        /// share of time. The low and high goals are cumulative in the source —
        /// "under 4%" is everything below range, the very-low band included.
        var goal: String {
            switch self {
            case .veryLow: return "< 1%"
            case .low: return "< 4%"
            case .inRange: return "> 70%"
            case .high: return "< 25%"
            case .veryHigh: return "< 5%"
            }
        }
    }

    /// The band edges, in whichever unit Health reports glucose in.
    struct Targets: Hashable, Sendable {
        let veryLow: Double
        let low: Double
        let high: Double
        let veryHigh: Double
        let unit: String

        /// 3.9–10.0 mmol/L or 70–180 mg/dL in range; below 3.0 / 54 and above
        /// 13.9 / 250 the "very" bands. Not configurable: a report meant to be
        /// read against the published targets should use the published edges.
        static func standard(unit: String) -> Targets {
            unit.contains("mol")
                ? Targets(veryLow: 3.0, low: 3.9, high: 10.0, veryHigh: 13.9, unit: unit)
                : Targets(veryLow: 54, low: 70, high: 180, veryHigh: 250, unit: unit)
        }

        func band(of value: Double) -> Band {
            if value < veryLow { return .veryLow }
            if value < low { return .low }
            if value <= high { return .inRange }
            if value <= veryHigh { return .high }
            return .veryHigh
        }

        /// The display precision — what separates "3.8" from "3.9".
        private var step: Double { unit.contains("mol") ? 0.1 : 1 }

        /// "3.9–10.0", "< 3.0", "> 13.9"
        func range(_ band: Band) -> String {
            func f(_ value: Double) -> String { InsulinStats.formatGlucose(value, unit: unit) }
            switch band {
            case .veryLow: return "< \(f(veryLow))"
            case .low: return "\(f(veryLow))–\(f(low - step))"
            case .inRange: return "\(f(low))–\(f(high))"
            case .high: return "\(f(high + step))–\(f(veryHigh))"
            case .veryHigh: return "> \(f(veryHigh))"
            }
        }
    }

    // MARK: - Glucose summary

    struct GlucoseSummary: Hashable, Sendable {
        let count: Int
        /// Fraction of the span with readings behind it.
        let coverage: Double
        let mean: Double
        /// Sample standard deviation (n − 1), the usual CGM convention.
        let sd: Double?
        /// Share of readings in each band.
        let fractions: [Band: Double]

        /// Coefficient of variation, in percent. The consensus marker of
        /// stable glucose is 36% or under.
        var cv: Double? {
            guard let sd, mean > 0 else { return nil }
            return sd / mean * 100
        }

        func fraction(_ band: Band) -> Double { fractions[band] ?? 0 }

        /// Below range, both bands together — the figure the "< 4%" goal is
        /// held against.
        var belowRange: Double { fraction(.veryLow) + fraction(.low) }
        var aboveRange: Double { fraction(.high) + fraction(.veryHigh) }
    }

    /// Longest gap between readings still counted as covered, as everywhere
    /// else in the app.
    static let maximumGap: TimeInterval = 20 * 60

    /// Requires `readings` sorted ascending. Nil when there are none, which is
    /// not the same claim as a zero.
    static func summarise(_ readings: [GlucosePoint],
                          over span: TimeInterval,
                          targets: Targets) -> GlucoseSummary? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map(\.value)
        let count = Double(values.count)
        let mean = values.reduce(0.0, +) / count

        var sd: Double?
        if values.count > 1 {
            let squares = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            sd = (squares / (count - 1)).squareRoot()
        }

        var counts: [Band: Int] = [:]
        for value in values { counts[targets.band(of: value), default: 0] += 1 }
        var fractions: [Band: Double] = [:]
        for band in Band.allCases { fractions[band] = Double(counts[band] ?? 0) / count }

        return GlucoseSummary(count: values.count,
                              coverage: coverage(readings, over: span),
                              mean: mean,
                              sd: sd,
                              fractions: fractions)
    }

    private static func coverage(_ readings: [GlucosePoint], over span: TimeInterval) -> Double {
        guard span > 0, readings.count > 1 else { return 0 }
        var covered: TimeInterval = 0
        for (previous, next) in zip(readings, readings.dropFirst()) {
            covered += min(next.date.timeIntervalSince(previous.date), maximumGap)
        }
        return min(1, covered / span)
    }

    // MARK: - The daily profile

    /// Every reading in the period folded onto one 24-hour day and summarised
    /// per half hour: where glucose usually sits at that time, and how widely
    /// it varies. This is the AGP's central chart, and the one a clinic uses
    /// to see a pattern — an overnight rise, a post-lunch peak — rather than
    /// a number.
    struct ProfileBin: Identifiable, Hashable, Sendable {
        let minuteOfDay: Int
        let p5: Double
        let p25: Double
        let p50: Double
        let p75: Double
        let p95: Double
        let count: Int

        var id: Int { minuteOfDay }
        var hour: Double { Double(minuteOfDay) / 60 }
    }

    static let profileBinMinutes = 30

    /// A half hour with fewer readings than this is left blank rather than
    /// drawn from a handful of points.
    private static let minimumBinReadings = 5

    static func profile(_ readings: [GlucosePoint], calendar: Calendar = .current) -> [ProfileBin] {
        var bins: [Int: [Double]] = [:]
        for reading in readings {
            let parts = calendar.dateComponents([.hour, .minute], from: reading.date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            bins[minute / profileBinMinutes * profileBinMinutes, default: []].append(reading.value)
        }
        return bins.keys.sorted().compactMap { minute -> ProfileBin? in
            let sorted = (bins[minute] ?? []).sorted()
            guard sorted.count >= minimumBinReadings else { return nil }
            return ProfileBin(minuteOfDay: minute,
                              p5: percentile(sorted, 0.05),
                              p25: percentile(sorted, 0.25),
                              p50: percentile(sorted, 0.5),
                              p75: percentile(sorted, 0.75),
                              p95: percentile(sorted, 0.95),
                              count: sorted.count)
        }
    }

    /// Linear interpolation between order statistics. `sorted` ascending and
    /// non-empty.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    // MARK: - Days

    struct Day: Identifiable, Hashable, Sendable {
        let date: Date
        let glucose: GlucoseSummary?
        let basal: Double
        let bolus: Double
        let basalCount: Int
        let bolusCount: Int
        let workouts: [Workout]
        let activeEnergy: Double?
        let weight: Double?

        var id: Date { date }

        var hasInsulin: Bool { basalCount + bolusCount > 0 }
        var total: Double? { hasInsulin ? basal + bolus : nil }
        var workoutMinutes: Int { workouts.reduce(0) { $0 + $1.minutes } }
    }

    // MARK: - Insulin and food over the period

    struct InsulinSummary: Hashable, Sendable {
        /// Days of the period the log reaches across — the denominator of
        /// every per-day figure. Counted from the first entry ever logged, so a
        /// log that began mid-period is not read as a period of half doses.
        let loggedDays: Int
        let daysWithInsulin: Int
        let daysWithBasal: Int
        let basalPerDay: Double?
        let bolusPerDay: Double?
        /// Injections of rapid-acting insulin per day.
        let bolusesPerDay: Double?
        /// The usual basal dose — the median over the period — and its spread.
        let basalDose: Double?
        let basalDoseRange: ClosedRange<Double>?
        /// The usual time of day basal is taken, as minutes after midnight.
        let basalMinuteOfDay: Int?

        var totalPerDay: Double? {
            guard let basalPerDay, let bolusPerDay else { return nil }
            return basalPerDay + bolusPerDay
        }

        /// Bolus as a share of the day's insulin. Roughly half is the usual
        /// expectation; a long way from it is worth a conversation.
        var bolusShare: Double? {
            guard let bolusPerDay, let totalPerDay, totalPerDay > 0 else { return nil }
            return bolusPerDay / totalPerDay
        }

        /// Logged days with no basal on them. A missed log and a missed
        /// injection look the same from here.
        var basalGapDays: Int { max(0, loggedDays - daysWithBasal) }
    }

    /// The same figures over a fixed look-back, so a change shows up as a
    /// column that no longer matches the ones beside it. Every window ends
    /// yesterday; the one matching the chosen period is the one the rest of
    /// the report describes.
    struct Window: Identifiable, Sendable {
        let period: Period
        let start: Date
        let glucose: GlucoseSummary?
        let insulin: InsulinSummary
        /// Mean over the days in the window that have a figure.
        let activeEnergyPerDay: Double?
        let weight: Double?

        var id: Int { period.days }
        var days: Int { period.days }

        /// "14-day average"
        var title: String { "\(period.days)-day average" }
    }

    // MARK: - Insulin acting through the day

    /// Units acting per hour at one time of day, averaged over the days logged.
    struct ActivityBin: Identifiable, Hashable, Sendable {
        let minuteOfDay: Int
        let basal: Double
        let bolus: Double

        var id: Int { minuteOfDay }
        var hour: Double { Double(minuteOfDay) / 60 }
    }

    static let activityStepMinutes = 10

    /// The action rate of every logged dose at each ten minutes of each day
    /// the log covers — doses from the day before included, since an evening
    /// basal acts through the next day — averaged across those days.
    ///
    /// A mean rather than a median, so the area under the curve is the average
    /// daily dose and agrees with the per-day tiles. A bolus given at one on
    /// some days and at two on others shows as a wider, lower bump, which is
    /// the truth of it; a median would lose it altogether.
    static func activityProfile(doses: [Event],
                                days: [Day],
                                firstEvent: Date?,
                                calendar: Calendar) -> [ActivityBin] {
        guard let firstEvent else { return [] }
        let firstDay = calendar.startOfDay(for: firstEvent)
        let logged = days.filter { $0.date >= firstDay }
        guard !logged.isEmpty else { return [] }

        let sorted = doses
            .filter { $0.kind == .basal || $0.kind == .insulin }
            .sorted { $0.date < $1.date }
        let stepsPerDay = 24 * 60 / activityStepMinutes
        var basal = [Double](repeating: 0, count: stepsPerDay)
        var bolus = [Double](repeating: 0, count: stepsPerDay)

        for day in logged {
            // Nothing acts for longer than a day, so yesterday's doses are the
            // oldest that can matter to today.
            let from = calendar.date(byAdding: .day, value: -1, to: day.date) ?? day.date
            let to = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
            let relevant = sorted.filter { $0.date >= from && $0.date < to }
            guard !relevant.isEmpty else { continue }

            for step in 0..<stepsPerDay {
                let instant = day.date.addingTimeInterval(Double(step * activityStepMinutes) * 60)
                for dose in relevant where dose.date <= instant {
                    let hours = instant.timeIntervalSince(dose.date) / 3600
                    if dose.kind == .basal {
                        basal[step] += dose.amount * InsulinAction.basalRate(hours: hours)
                    } else {
                        bolus[step] += dose.amount * InsulinAction.bolusRate(hours: hours)
                    }
                }
            }
        }

        let count = Double(logged.count)
        return (0..<stepsPerDay).map { step in
            ActivityBin(minuteOfDay: step * activityStepMinutes,
                        basal: basal[step] / count,
                        bolus: bolus[step] / count)
        }
    }

    // MARK: - A line of the appendix

    /// A dose, a finger-prick reading or a workout, in time order, spelled out
    /// for the page.
    struct LogLine: Identifiable, Hashable, Sendable {
        /// Position in the appendix. Two entries can share a second and a kind,
        /// so nothing about the entry itself is unique enough to be the id.
        let id: Int
        let date: Date
        let title: String
        let amount: String
        let isWorkout: Bool
    }

    // MARK: - The document

    struct Document: Sendable {
        let period: Period
        /// Midnight at the start of the first day.
        let start: Date
        /// Midnight at the end of the last day — exclusive.
        let end: Date
        let generated: Date
        let targets: Targets
        let weightUnit: String
        let weightAxisPadding: Double

        /// Over the chosen period.
        let glucose: GlucoseSummary?
        let profile: [ProfileBin]
        let days: [Day]
        let insulin: InsulinSummary
        /// Over 14, 30 and 90 days, whatever the period chosen.
        let windows: [Window]
        /// Insulin acting through a typical day of the chosen period.
        let activity: [ActivityBin]
        let workouts: [Workout]
        let log: [LogLine]
        /// Low and high events starting in the period — see `GlucoseEvents`.
        let eventThresholds: EventThresholds
        let lows: [GlucoseEvent]
        let highs: [GlucoseEvent]

        var unit: String { targets.unit }

        /// The last day covered, for display.
        var lastDay: Date { end.addingTimeInterval(-1) }

        /// The profile with its first bin repeated at 24:00, so the curve
        /// closes the day instead of stopping at half past eleven.
        var profilePlot: [ProfileBin] {
            guard let first = profile.first, first.minuteOfDay == 0 else { return profile }
            return profile + [ProfileBin(minuteOfDay: 24 * 60,
                                         p5: first.p5, p25: first.p25, p50: first.p50,
                                         p75: first.p75, p95: first.p95, count: first.count)]
        }

        /// Closed at 24:00 with the midnight bin, like the glucose profile.
        var activityPlot: [ActivityBin] {
            guard let first = activity.first, first.minuteOfDay == 0 else { return activity }
            return activity + [ActivityBin(minuteOfDay: 24 * 60, basal: first.basal, bolus: first.bolus)]
        }

        var hasEnergy: Bool { days.contains { $0.activeEnergy != nil } }
        var hasWeight: Bool { days.contains { $0.weight != nil } }

        /// "Insulin report 2026-07-22 to 2026-10-19.pdf",
        /// "Low events 2026-07-22 to 2026-10-19.pdf"
        func fileName(_ name: String) -> String {
            "\(name) \(Report.isoDay.string(from: start)) to \(Report.isoDay.string(from: lastDay)).pdf"
        }
    }

    // MARK: - Building

    static func build(period: Period,
                      now: Date,
                      glucoseUnit: String,
                      weightUnit: String,
                      weightAxisPadding: Double,
                      glucose: [GlucosePoint],
                      events: [Event],
                      workouts: [Workout],
                      energy: [Energy],
                      weights: [Weight],
                      calendar: Calendar = .current) -> Document {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -period.days, to: end) ?? end
        // Everything is bucketed once over the longest window; the chosen
        // period and the three averaging windows are then suffixes of it.
        let longestStart = calendar.date(byAdding: .day, value: -longestPeriod, to: end) ?? end
        let targets = Targets.standard(unit: glucoseUnit)
        let unit = GlucoseUnit(label: glucoseUnit)

        let readings = glucose
            .filter { $0.date >= longestStart && $0.date < end }
            .sorted { $0.date < $1.date }
        let inPeriod = events
            .filter { $0.date >= longestStart && $0.date < end }
            .sorted { $0.date < $1.date }
        let periodWorkouts = workouts
            .filter { $0.start >= longestStart && $0.start < end }
            .sorted { $0.start < $1.start }

        // Bucketed once rather than filtered per day — ninety days against
        // three months of CGM is otherwise ninety scans of the same array.
        var glucoseByDay: [Date: [GlucosePoint]] = [:]
        for point in readings {
            glucoseByDay[calendar.startOfDay(for: point.date), default: []].append(point)
        }
        var eventsByDay: [Date: [Event]] = [:]
        for event in inPeriod {
            eventsByDay[calendar.startOfDay(for: event.date), default: []].append(event)
        }
        var workoutsByDay: [Date: [Workout]] = [:]
        for workout in periodWorkouts {
            workoutsByDay[calendar.startOfDay(for: workout.start), default: []].append(workout)
        }
        var energyByDay: [Date: Double] = [:]
        for entry in energy {
            energyByDay[calendar.startOfDay(for: entry.day), default: 0] += entry.kilocalories
        }
        // Last reading of the day wins, as on the trends chart.
        var weightByDay: [Date: Weight] = [:]
        for reading in weights where reading.date >= longestStart && reading.date < end {
            let day = calendar.startOfDay(for: reading.date)
            if let existing = weightByDay[day], existing.date >= reading.date { continue }
            weightByDay[day] = reading
        }

        var allDays: [Day] = []
        var cursor = longestStart
        while cursor < end {
            // Asked of the calendar, so a clock-change day is 23 or 25 hours
            // and is not scored as short of readings.
            let next = calendar.date(byAdding: .day, value: 1, to: cursor)
                ?? cursor.addingTimeInterval(24 * 3600)
            let dayEvents = eventsByDay[cursor] ?? []
            let basalDoses = dayEvents.filter { $0.kind == .basal }
            let bolusDoses = dayEvents.filter { $0.kind == .insulin }

            allDays.append(Day(
                date: cursor,
                glucose: summarise(glucoseByDay[cursor] ?? [],
                                   over: next.timeIntervalSince(cursor),
                                   targets: targets),
                basal: basalDoses.reduce(0.0) { $0 + $1.amount },
                bolus: bolusDoses.reduce(0.0) { $0 + $1.amount },
                basalCount: basalDoses.count,
                bolusCount: bolusDoses.count,
                workouts: workoutsByDay[cursor] ?? [],
                activeEnergy: energyByDay[cursor],
                weight: weightByDay[cursor]?.value
            ))
            cursor = next
        }

        // Earliest entry of any age: it is what says how far the log reaches.
        let firstEvent = events.map(\.date).min()

        let windows = Period.allCases.map { window -> Window in
            let windowStart = calendar.date(byAdding: .day, value: -window.days, to: end) ?? end
            let windowDays = allDays.filter { $0.date >= windowStart }
            return Window(
                period: window,
                start: windowStart,
                glucose: summarise(readings.filter { $0.date >= windowStart },
                                   over: end.timeIntervalSince(windowStart),
                                   targets: targets),
                insulin: summariseInsulin(days: windowDays,
                                          basalEvents: inPeriod.filter { $0.kind == .basal && $0.date >= windowStart },
                                          firstEvent: firstEvent,
                                          calendar: calendar),
                activeEnergyPerDay: mean(windowDays.compactMap(\.activeEnergy)),
                weight: mean(windowDays.compactMap(\.weight))
            )
        }
        // The chosen period is one of the windows, so its figures are the
        // same ones as in that column of the averages table, by construction.
        let current = windows.first { $0.period == period } ?? windows[0]

        let chosenEvents = inPeriod.filter { $0.date >= start }
        let chosenWorkouts = periodWorkouts.filter { $0.start >= start }
        // Every workout in the longest window, not just the period's: a
        // reading on the period's first morning may follow a ride the
        // evening before. And every mark ever made, for the places.
        let outings = periodWorkouts.compactMap {
            $0.start <= $0.end ? Temperature.Outing(span: $0.start...$0.end, outdoors: $0.outdoors) : nil
        }
        let marks = events.compactMap(\.mark)
        let log = (chosenEvents.map { line($0, unit: unit, outings: outings, marks: marks) } + chosenWorkouts.map(line))
            .sorted { $0.date < $1.date }
            .enumerated()
            .map { LogLine(id: $0.offset,
                           date: $0.element.date,
                           title: $0.element.title,
                           amount: $0.element.amount,
                           isWorkout: $0.element.isWorkout) }

        // Read from the whole CGM record, not the period's slice of it, so an
        // event that starts on the last evening is followed past midnight
        // and its chart has the hours before the first morning.
        let allGlucose = glucose.sorted { $0.date < $1.date }
        let allEvents = events.sorted { $0.date < $1.date }
        let allOutings = workouts.compactMap {
            $0.start <= $0.end ? Temperature.Outing(span: $0.start...$0.end, outdoors: $0.outdoors) : nil
        }
        let thresholds = EventThresholds.standard(unit: glucoseUnit)
        func glucoseEvents(_ kind: EventKind) -> [GlucoseEvent] {
            Report.glucoseEvents(kind,
                                 thresholds: thresholds,
                                 glucose: allGlucose,
                                 period: start..<end,
                                 events: allEvents,
                                 workouts: workouts.sorted { $0.start < $1.start },
                                 outings: allOutings,
                                 marks: marks)
        }

        return Document(period: period,
                        start: start,
                        end: end,
                        generated: now,
                        targets: targets,
                        weightUnit: weightUnit,
                        weightAxisPadding: weightAxisPadding,
                        glucose: current.glucose,
                        profile: profile(readings.filter { $0.date >= start }, calendar: calendar),
                        days: allDays.filter { $0.date >= start },
                        insulin: current.insulin,
                        windows: windows,
                        activity: activityProfile(doses: inPeriod,
                                                  days: allDays.filter { $0.date >= start },
                                                  firstEvent: firstEvent,
                                                  calendar: calendar),
                        workouts: chosenWorkouts,
                        log: log,
                        eventThresholds: thresholds,
                        lows: glucoseEvents(.low),
                        highs: glucoseEvents(.high))
    }

    private static func summariseInsulin(days: [Day],
                                         basalEvents: [Event],
                                         firstEvent: Date?,
                                         calendar: Calendar) -> InsulinSummary {
        var logged: [Day] = []
        if let firstEvent {
            let firstDay = calendar.startOfDay(for: firstEvent)
            logged = days.filter { $0.date >= firstDay }
        }
        let loggedDays = logged.count
        let usable = loggedDays > 0 && logged.contains { $0.hasInsulin }
        let denominator = Double(max(loggedDays, 1))

        let basalDoses = basalEvents.map(\.amount)
        let basalMinutes = basalEvents.map { event -> Int in
            let parts = calendar.dateComponents([.hour, .minute], from: event.date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }

        var range: ClosedRange<Double>?
        if let low = basalDoses.min(), let high = basalDoses.max() { range = low...high }

        return InsulinSummary(
            loggedDays: loggedDays,
            daysWithInsulin: logged.filter { $0.hasInsulin }.count,
            daysWithBasal: logged.filter { $0.basalCount > 0 }.count,
            basalPerDay: usable ? logged.reduce(0.0) { $0 + $1.basal } / denominator : nil,
            bolusPerDay: usable ? logged.reduce(0.0) { $0 + $1.bolus } / denominator : nil,
            bolusesPerDay: usable ? Double(logged.reduce(0) { $0 + $1.bolusCount }) / denominator : nil,
            basalDose: median(basalDoses),
            basalDoseRange: range,
            basalMinuteOfDay: median(basalMinutes.map(Double.init)).map { Int($0.rounded()) }
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0.0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private static func line(_ event: Event,
                             unit: GlucoseUnit,
                             outings: [Temperature.Outing],
                             marks: [Temperature.Mark]) -> LogLine {
        var amount = formatAmount(kind: event.kind, amount: event.amount, unit: unit)
        // A reading taken outside carries the air it was taken in and the
        // value corrected for it — see `Temperature`. Indoors, neither.
        if let celsius = outsideAir(event, outings: outings, marks: marks) {
            let adjusted = Temperature.adjustedGlucose(event.amount, celsius: celsius)
            amount += " · \(Temperature.format(celsius: celsius)) · adj. \(unit.format(adjusted))"
        }
        return LogLine(id: 0,
                       date: event.date,
                       title: title(for: event.kind),
                       amount: amount,
                       isWorkout: false)
    }

    private static func line(_ workout: Workout) -> LogLine {
        var amount = "\(workout.minutes) min"
        if let kilocalories = workout.kilocalories {
            amount += " · \(Int(kilocalories.rounded())) kcal"
        }
        return LogLine(id: 0,
                       date: workout.start,
                       title: workout.name,
                       amount: amount,
                       isWorkout: true)
    }

    // MARK: - Formatting

    /// "Bolus" rather than "Insulin": on a page that also carries basal, the
    /// word a clinic uses for the rapid-acting dose is the clearer one.
    static func title(for kind: EntryKind) -> String {
        switch kind {
        case .glucose: return "Meter"
        case .insulin: return "Bolus"
        case .basal: return "Basal"
        }
    }

    static func formatAmount(kind: EntryKind, amount: Double, unit: GlucoseUnit) -> String {
        switch kind {
        case .glucose: return "\(unit.format(amount)) \(unit.label)"
        case .insulin: return "\(formatUnits(amount)) U"
        case .basal: return "\(Int(amount.rounded())) U"
        }
    }

    /// "3", "2.5" — one decimal only where there is one.
    static func formatUnits(_ units: Double) -> String {
        units == units.rounded() ? String(Int(units)) : String(format: "%.1f", units)
    }

    static func formatPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// A share of the day as hours and minutes — "16 h 48 min" — which is how
    /// an AGP prints it beside the percentage.
    static func formatShareOfDay(_ fraction: Double) -> String {
        let minutes = Int((fraction * 24 * 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    /// "22:05"
    static func formatMinuteOfDay(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
