import Foundation

/// Everything the trends view plots, reduced to one row per calendar day.
///
/// Deliberately separate from `InsulinStats`, which answers a different
/// question: that one averages over long windows to smooth a trend out of the
/// noise, this one keeps every day intact so the noise itself is visible. A day
/// where the basal never got logged should show up as a notch here, not be
/// quietly folded into a 30-day mean.
///
/// Days are calendar days in the phone's own time zone, and their length is
/// asked of the calendar rather than assumed to be 86,400 seconds, so the two
/// clock-change days a year are not scored as under-covered.
enum DailySeries {

    // MARK: - Inputs

    struct GlucosePoint: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    struct Dose: Hashable, Sendable {
        let date: Date
        let units: Double
        let isBasal: Bool
    }

    /// A day's active energy, already summed by Health.
    struct Energy: Hashable, Sendable {
        let day: Date
        let kilocalories: Double
    }

    /// One workout's energy, used to split deliberate training out of the day's
    /// total movement rather than to replace it.
    struct WorkoutEnergy: Hashable, Sendable {
        let date: Date
        let kilocalories: Double
    }

    struct Weight: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    // MARK: - Parameters

    /// Least of a day that must have CGM behind it before its mean is plotted.
    ///
    /// Glucose has a strong daily shape, so a mean over a third of a day is not
    /// a noisy version of that day's average — it is an average of whichever
    /// third the sensor happened to be awake for, which is a different quantity.
    private static let minimumGlucoseCoverage = 0.5

    /// Longest gap between readings still counted as covered.
    private static let maximumGap: TimeInterval = 20 * 60

    // MARK: - Output

    struct Day: Identifiable, Sendable {
        let date: Date

        let meanGlucose: Double?
        let glucoseCoverage: Double

        let basal: Double
        let bolus: Double
        /// Distinguishes a day with no insulin logged from one totalling zero.
        let hasInsulin: Bool

        let activeEnergy: Double?
        /// The part of `activeEnergy` spent inside a logged workout.
        let workoutEnergy: Double

        let weight: Double?

        /// The last day in the range, which is still being lived — its totals
        /// are running, not final.
        let isPartial: Bool

        var id: Date { date }

        var totalInsulin: Double? { hasInsulin ? basal + bolus : nil }

        /// The day's own insulin-per-glucose. Far noisier than the windowed
        /// figure — one late dinner moves it — but it is what a trend is made of.
        var insulinPerGlucose: Double? {
            guard let totalInsulin, let meanGlucose, meanGlucose > 0 else { return nil }
            return totalInsulin / meanGlucose
        }

        /// Active energy that fell outside any logged workout — the cleaning,
        /// shopping and walking the book counts as physical activity too.
        var otherEnergy: Double { max(0, (activeEnergy ?? 0) - workoutEnergy) }
    }

    // MARK: - Building

    static func build(dayCount: Int,
                      endingAt anchor: Date,
                      glucose: [GlucosePoint],
                      doses: [Dose],
                      energy: [Energy],
                      workouts: [WorkoutEnergy],
                      weights: [Weight],
                      calendar: Calendar = .current) -> [Day] {
        guard dayCount > 0 else { return [] }

        let lastDay = calendar.startOfDay(for: anchor)
        guard let firstDay = calendar.date(byAdding: .day,
                                           value: -(dayCount - 1),
                                           to: lastDay) else { return [] }

        // Bucketed once rather than filtered per day: ninety days against three
        // months of CGM is otherwise ninety scans of the same array.
        var glucoseByDay: [Date: [GlucosePoint]] = [:]
        for point in glucose where point.date >= firstDay {
            glucoseByDay[calendar.startOfDay(for: point.date), default: []].append(point)
        }

        var dosesByDay: [Date: [Dose]] = [:]
        for dose in doses where dose.date >= firstDay {
            dosesByDay[calendar.startOfDay(for: dose.date), default: []].append(dose)
        }

        var energyByDay: [Date: Double] = [:]
        for entry in energy {
            energyByDay[calendar.startOfDay(for: entry.day), default: 0] += entry.kilocalories
        }

        var workoutByDay: [Date: Double] = [:]
        for workout in workouts where workout.date >= firstDay {
            workoutByDay[calendar.startOfDay(for: workout.date), default: 0] += workout.kilocalories
        }

        // Last reading of the day wins: people weigh themselves more than once
        // and the later one is the one they settled on.
        var weightByDay: [Date: Weight] = [:]
        for reading in weights where reading.date >= firstDay {
            let day = calendar.startOfDay(for: reading.date)
            if let existing = weightByDay[day], existing.date >= reading.date { continue }
            weightByDay[day] = reading
        }

        return (0..<dayCount).compactMap { offset -> Day? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            // Ask the calendar rather than adding 86,400: on the two clock-change
            // days a year this is 23 or 25 hours, and a fixed denominator would
            // score one of them as short of readings.
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(24 * 3600)
            let length = next.timeIntervalSince(day)

            let readings = (glucoseByDay[day] ?? []).sorted { $0.date < $1.date }
            let cover = coverage(readings, over: length)
            let values = readings.map(\.value)

            let dayDoses = dosesByDay[day] ?? []
            let basal = dayDoses.filter(\.isBasal).reduce(0.0) { $0 + $1.units }
            let bolus = dayDoses.filter { !$0.isBasal }.reduce(0.0) { $0 + $1.units }

            return Day(
                date: day,
                meanGlucose: cover >= minimumGlucoseCoverage && !values.isEmpty
                    ? values.reduce(0.0, +) / Double(values.count)
                    : nil,
                glucoseCoverage: cover,
                basal: basal,
                bolus: bolus,
                hasInsulin: !dayDoses.isEmpty,
                activeEnergy: energyByDay[day],
                workoutEnergy: workoutByDay[day] ?? 0,
                weight: weightByDay[day]?.value,
                isPartial: offset == dayCount - 1
            )
        }
    }

    // MARK: - Helpers

    /// Fraction of `length` with readings behind it. Requires `readings` sorted.
    ///
    /// Gaps across midnight are not counted, so a fully covered day reads one
    /// sample interval short of 100% — 0.3% at five-minute cadence, nowhere near
    /// the half-day threshold anything is decided on.
    private static func coverage(_ readings: [GlucosePoint], over length: TimeInterval) -> Double {
        guard length > 0, readings.count > 1 else { return 0 }
        var covered: TimeInterval = 0
        for (previous, next) in zip(readings, readings.dropFirst()) {
            covered += min(next.date.timeIntervalSince(previous.date), maximumGap)
        }
        return min(1, covered / length)
    }
}
