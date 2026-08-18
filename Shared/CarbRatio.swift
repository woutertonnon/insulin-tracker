import Foundation

/// Running estimate of the insulin-to-carb ratio — grams of carbohydrate
/// covered by one unit of rapid-acting insulin.
///
/// Built around one asymmetry: **insulin logging is reliable, meal logging is
/// not.** So the headline estimate uses no meal data whatever, and meals are
/// used only where an episode can be shown to have gone well.
///
/// Both methods come from Gary Scheiner, *Think Like a Pancreas*, ch. 7:
///
/// * **The 500 Rule** — `I:C = 500 / TDI`, on the assumption that a person
///   consumes and produces roughly 500 g of carbohydrate a day. Needs only
///   total daily insulin, basal included.
/// * **Empirical verification** — "if glucose levels are often above or below
///   target three to four hours after a meal, the I:C ratio is usually to
///   blame." Inverted here: a meal whose glucose *did* come back to where it
///   started is evidence the ratio used on it worked.
///
/// Nothing here is a dosing instruction. It describes what has already
/// happened.
enum CarbRatio {

    // MARK: - Inputs

    /// A glucose reading, in whatever unit the caller is working in.
    struct GlucosePoint: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    /// A period to exclude — a workout. Exercise changes insulin sensitivity by
    /// an unknown amount, so any meal overlapping one is not evidence.
    struct Exclusion: Hashable, Sendable {
        let start: Date
        let end: Date
    }

    /// One logged event, reduced to what the estimator needs.
    struct Event: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// Rapid-acting bolus, in units.
            case bolus
            /// Long-acting basal, in units. Counts toward TDI, never toward a meal.
            case basal
            /// Carbohydrate in grams — a real number, usable as evidence.
            case carbsInGrams
            /// A meal logged by size only. Deliberately unusable: there is no
            /// gram figure, and inventing one would poison the estimate.
            case mealWithoutAmount
        }
        let date: Date
        let kind: Kind
        let amount: Double
    }

    // MARK: - Outputs

    /// A meal that survived every filter: one bolus, nothing else nearby, no
    /// exercise, and glucose back to where it started.
    struct Episode: Hashable, Sendable, Identifiable {
        let date: Date
        let carbs: Double
        let units: Double
        let glucoseStart: Double
        let glucoseEnd: Double

        var id: Date { date }
        var ratio: Double { carbs / units }
    }

    /// Why a meal was not counted. Shown so the number is never a bare
    /// assertion — a ratio from two meals should not look like one from twenty.
    enum Rejection: String, Hashable, Sendable, CaseIterable {
        case noBolus = "no bolus near the meal"
        case insulinStacked = "other insulin within 4 h"
        case otherFood = "other food within 4 h"
        case sizeOnly = "logged as a size, no grams"
        case exercise = "exercise overlapped"
        case noGlucose = "no glucose either side"
        case glucoseMoved = "glucose did not return to baseline"
    }

    struct Estimate: Sendable {
        /// From the 500 Rule. Nil when there is too little insulin history.
        let fromTotalInsulin: Double?
        /// Median across accepted episodes. Nil below `minimumEpisodes`.
        let fromMeals: Double?
        /// Average units per day over the window, basal included.
        let totalDailyInsulin: Double?
        /// Days in the window that carried any insulin at all.
        let daysCovered: Int
        let episodes: [Episode]
        let rejections: [Rejection: Int]
        /// True when no basal was logged, which makes TDI — and therefore the
        /// 500 Rule figure — too low, and the ratio it yields too high.
        let basalMissing: Bool
    }

    // MARK: - Parameters

    /// The running window. Long enough to average out single odd days, short
    /// enough to follow a real change in sensitivity.
    static let window: TimeInterval = 7 * 24 * 3600

    /// Carb entry and bolus must be within this of each other to be one meal.
    static let pairingWindow: TimeInterval = 20 * 60

    /// The book's "three to four hours after a meal" — where the ratio shows.
    static let outcomeDelay: TimeInterval = 3.5 * 3600

    /// A glucose reading must be this close to the moment it stands for.
    private static let glucoseTolerance: TimeInterval = 20 * 60

    /// Below this many clean meals the meal-based figure is not shown at all.
    static let minimumEpisodes = 3

    /// Below this many days the 500 Rule figure is not shown either.
    static let minimumDays = 3

    // MARK: - Estimating

    static func estimate(events: [Event],
                         glucose: [GlucosePoint],
                         exclusions: [Exclusion],
                         glucoseReturnTolerance: Double,
                         now: Date = .now) -> Estimate {
        let since = now.addingTimeInterval(-window)
        let recent = events.filter { $0.date > since && $0.date <= now }

        // ---- 500 Rule: insulin only, so meal logging cannot affect it.
        let insulinEvents = recent.filter { $0.kind == .bolus || $0.kind == .basal }
        let totalUnits = insulinEvents.reduce(0.0) { $0 + $1.amount }
        let calendar = Calendar.current
        let days = Set(insulinEvents.map { calendar.startOfDay(for: $0.date) }).count
        let tdi = days > 0 ? totalUnits / Double(days) : nil
        let fromInsulin = (days >= minimumDays && (tdi ?? 0) > 0) ? 500 / tdi! : nil

        // ---- Meal episodes, each of which must earn its place.
        var episodes: [Episode] = []
        var rejections: [Rejection: Int] = [:]
        func reject(_ r: Rejection) { rejections[r, default: 0] += 1 }

        for meal in recent where meal.kind == .mealWithoutAmount {
            reject(.sizeOnly)
        }

        for meal in recent where meal.kind == .carbsInGrams && meal.amount > 0 {
            let boluses = recent.filter {
                $0.kind == .bolus && abs($0.date.timeIntervalSince(meal.date)) <= pairingWindow
            }
            guard boluses.count == 1, let bolus = boluses.first, bolus.amount > 0 else {
                reject(.noBolus)
                continue
            }

            // Nothing else may be acting across the window, or the outcome
            // cannot be attributed to this meal.
            let from = meal.date.addingTimeInterval(-InsulinMath.duration)
            let to = meal.date.addingTimeInterval(InsulinMath.duration)
            let otherInsulin = recent.contains {
                $0.kind == .bolus && $0 != bolus && $0.date > from && $0.date < to
            }
            if otherInsulin { reject(.insulinStacked); continue }

            let otherFood = recent.contains {
                ($0.kind == .carbsInGrams || $0.kind == .mealWithoutAmount)
                    && $0 != meal && $0.date > from && $0.date < to
            }
            if otherFood { reject(.otherFood); continue }

            let outcomeAt = meal.date.addingTimeInterval(outcomeDelay)
            let overlapped = exclusions.contains {
                $0.end > meal.date.addingTimeInterval(-3600) && $0.start < outcomeAt
            }
            if overlapped { reject(.exercise); continue }

            guard let g0 = nearest(glucose, to: meal.date),
                  let g1 = nearest(glucose, to: outcomeAt) else {
                reject(.noGlucose)
                continue
            }

            // The whole point: only a meal that ended where it started shows a
            // ratio that actually worked.
            guard abs(g1.value - g0.value) <= glucoseReturnTolerance else {
                reject(.glucoseMoved)
                continue
            }

            episodes.append(Episode(date: meal.date,
                                    carbs: meal.amount,
                                    units: bolus.amount,
                                    glucoseStart: g0.value,
                                    glucoseEnd: g1.value))
        }

        // Median, not mean: one mis-logged meal should not drag the figure.
        let fromMeals = episodes.count >= minimumEpisodes
            ? median(episodes.map(\.ratio))
            : nil

        return Estimate(fromTotalInsulin: fromInsulin,
                        fromMeals: fromMeals,
                        totalDailyInsulin: tdi,
                        daysCovered: days,
                        episodes: episodes.sorted { $0.date > $1.date },
                        rejections: rejections,
                        basalMissing: !insulinEvents.contains { $0.kind == .basal })
    }

    // MARK: - Helpers

    private static func nearest(_ points: [GlucosePoint], to date: Date) -> GlucosePoint? {
        points
            .filter { abs($0.date.timeIntervalSince(date)) <= glucoseTolerance }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// "1 U per 12 g"
    static func format(_ ratio: Double) -> String {
        "1 U per \(Int(ratio.rounded())) g"
    }
}
