import Foundation

/// Running estimate of the insulin-to-carb ratio, derived from what actually
/// happened after each meal.
///
/// The method, end to end:
///
/// 1. Find meals with carbs **in grams** and a bolus in the hour before them.
/// 2. Read glucose at the meal and again four hours later.
/// 3. Convert the glucose miss into the insulin that was missing, and back out
///    the ratio that *would* have landed flat.
///
/// Step 3 needs to know how far one unit moves glucose — the insulin
/// sensitivity factor. Rather than assume it, ISF is measured from **correction
/// boluses**: insulin taken with no food near it, where the whole glucose fall
/// is attributable to the dose. Both inputs are things this app records
/// reliably; neither depends on meals being logged faithfully.
///
/// Estimates are split by time of day and by whether exercise overlapped,
/// because both genuinely change the answer — the book notes most people need
/// their lowest ratio in the morning.
///
/// Nothing here is a dosing instruction. It describes what already happened.
enum CarbRatio {

    // MARK: - Inputs

    struct GlucosePoint: Hashable, Sendable {
        let date: Date
        let value: Double
    }

    /// A workout. Not an exclusion any more — meals overlapping one are
    /// estimated separately, since that is its own ratio.
    struct Exclusion: Hashable, Sendable {
        let start: Date
        let end: Date
    }

    struct Event: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case bolus
            case basal
            /// Carbohydrate in grams — the only food that can carry evidence.
            case carbsInGrams
            /// Logged by size only. No gram figure, so unusable, and never
            /// guessed at.
            case mealWithoutAmount
        }
        let date: Date
        let kind: Kind
        let amount: Double
    }

    // MARK: - Segmentation

    /// Three parts of the day, covering all 24 hours so nothing is discarded.
    enum Daypart: String, CaseIterable, Sendable {
        case morning = "Morning"
        case lunch = "Lunch"
        case dinner = "Dinner"

        /// Morning 04:00–11:00, lunch 11:00–17:00, dinner 17:00–04:00. A late
        /// snack lands in dinner rather than in a fourth bucket too sparse to
        /// estimate anything from.
        static func of(_ date: Date, calendar: Calendar = .current) -> Daypart {
            switch calendar.component(.hour, from: date) {
            case 4..<11: return .morning
            case 11..<17: return .lunch
            default: return .dinner
            }
        }
    }

    // MARK: - Outputs

    struct Episode: Hashable, Sendable, Identifiable {
        let date: Date
        let carbs: Double
        let units: Double
        let glucoseStart: Double
        let glucoseEnd: Double
        let daypart: Daypart
        let withExercise: Bool

        var id: Date { date }
        /// Positive means it finished high — the dose was short.
        var glucoseDelta: Double { glucoseEnd - glucoseStart }

        /// The dose that would have landed flat, given how far a unit moves
        /// this person's glucose.
        func idealUnits(isf: Double) -> Double { units + glucoseDelta / isf }

        /// Ratio implied by this meal. Nil when the correction implies a
        /// nonsensical dose, or a ratio outside anything physiological.
        func ratio(isf: Double) -> Double? {
            let ideal = idealUnits(isf: isf)
            guard ideal >= 0.2 else { return nil }
            let r = carbs / ideal
            return (plausibleRatios ~= r) ? r : nil
        }
    }

    /// One time-of-day × exercise combination.
    struct Cell: Identifiable, Sendable {
        let daypart: Daypart
        let withExercise: Bool
        let ratio: Double?
        let episodeCount: Int

        var id: String { "\(daypart.rawValue)-\(withExercise)" }
    }

    enum Rejection: String, Hashable, Sendable {
        case noBolusBefore = "no bolus in the hour before"
        case insulinStacked = "other insulin within 4 h"
        case otherFood = "other food within 4 h"
        case sizeOnly = "logged as a size, no grams"
        case noGlucose = "no glucose at the meal or 4 h later"
        case implausible = "implied an impossible ratio"
    }

    struct Estimate: Sendable {
        /// Glucose moved per unit, measured from corrections. Nil when too few
        /// clean corrections exist, which disables the whole method.
        let isf: Double?
        let isfSampleCount: Int
        let cells: [Cell]
        /// All usable meals together — shown when a cell is too thin on its own.
        let pooled: Double?
        let episodes: [Episode]
        let rejections: [Rejection: Int]
    }

    // MARK: - Parameters

    static let window: TimeInterval = 7 * 24 * 3600

    /// A bolus this far before the meal counts as covering it. The small tail
    /// after exists because the watch logs one value per turn of the crown, so
    /// dose and meal land seconds apart in whichever order they were dialled.
    static let bolusLead: TimeInterval = 60 * 60
    static let bolusTrail: TimeInterval = 15 * 60

    /// How long after the meal the outcome is read.
    static let outcomeDelay: TimeInterval = 4 * 3600

    /// A workout anywhere in this span around the meal makes it an
    /// exercise meal — sensitivity is already shifted beforehand.
    static let exerciseLead: TimeInterval = 2 * 3600

    private static let glucoseTolerance: TimeInterval = 20 * 60

    /// Ratios outside this are a logging error, not a physiology.
    private static let plausibleRatios: ClosedRange<Double> = 2...60

    /// A rise this far above the starting value, as a fraction, means food was
    /// absorbing — whether or not it was logged.
    private static let unloggedFoodRise = 0.10

    /// Minimum fall, as a fraction of the starting value, for a correction to
    /// carry signal rather than sensor noise.
    private static let minimumFall = 0.08

    /// Doses below this make the division too sensitive to be worth it.
    private static let minimumCorrectionUnits = 0.5

    static let minimumEpisodes = 3
    static let minimumCorrections = 2

    // MARK: - Estimating

    static func estimate(events: [Event],
                         glucose: [GlucosePoint],
                         exclusions: [Exclusion],
                         now: Date = .now) -> Estimate {
        let since = now.addingTimeInterval(-window)
        let recent = events.filter { $0.date > since && $0.date <= now }

        let isfSamples = correctionSensitivities(recent: recent, glucose: glucose)
        let isf = isfSamples.count >= minimumCorrections ? median(isfSamples) : nil

        var episodes: [Episode] = []
        var rejections: [Rejection: Int] = [:]
        func reject(_ r: Rejection) { rejections[r, default: 0] += 1 }

        for meal in recent where meal.kind == .mealWithoutAmount { reject(.sizeOnly) }

        for meal in recent where meal.kind == .carbsInGrams && meal.amount > 0 {
            // A bolus in the hour before the meal, or moments after it.
            let covering = recent.filter {
                guard $0.kind == .bolus else { return false }
                let offset = meal.date.timeIntervalSince($0.date)
                return offset >= -bolusTrail && offset <= bolusLead
            }
            guard covering.count == 1, let bolus = covering.first, bolus.amount > 0 else {
                reject(.noBolusBefore)
                continue
            }

            let from = meal.date.addingTimeInterval(-InsulinMath.duration)
            let to = meal.date.addingTimeInterval(outcomeDelay)

            if recent.contains(where: { $0.kind == .bolus && $0 != bolus && $0.date > from && $0.date < to }) {
                reject(.insulinStacked)
                continue
            }
            if recent.contains(where: {
                ($0.kind == .carbsInGrams || $0.kind == .mealWithoutAmount)
                    && $0 != meal && $0.date > from && $0.date < to
            }) {
                reject(.otherFood)
                continue
            }

            // Anchored at the bolus, not the meal. With a pre-bolus the insulin
            // has already been pulling glucose down before the first bite, and
            // reading from the meal would miss that fall and credit the dose
            // with less work than it did.
            guard let g0 = nearest(glucose, to: bolus.date),
                  let g1 = nearest(glucose, to: meal.date.addingTimeInterval(outcomeDelay)) else {
                reject(.noGlucose)
                continue
            }

            let exercised = exclusions.contains {
                $0.end > meal.date.addingTimeInterval(-exerciseLead) && $0.start < to
            }

            let episode = Episode(date: meal.date,
                                  carbs: meal.amount,
                                  units: bolus.amount,
                                  glucoseStart: g0.value,
                                  glucoseEnd: g1.value,
                                  daypart: Daypart.of(meal.date),
                                  withExercise: exercised)

            if let isf, episode.ratio(isf: isf) == nil {
                reject(.implausible)
                continue
            }
            episodes.append(episode)
        }

        let ratioOf: (Episode) -> Double? = { episode in
            guard let isf else { return nil }
            return episode.ratio(isf: isf)
        }

        var cells: [Cell] = []
        for daypart in Daypart.allCases {
            for exercised in [false, true] {
                let matching = episodes.filter { $0.daypart == daypart && $0.withExercise == exercised }
                let ratios = matching.compactMap(ratioOf)
                cells.append(Cell(daypart: daypart,
                                  withExercise: exercised,
                                  ratio: ratios.count >= minimumEpisodes ? median(ratios) : nil,
                                  episodeCount: matching.count))
            }
        }

        let allRatios = episodes.compactMap(ratioOf)

        return Estimate(isf: isf,
                        isfSampleCount: isfSamples.count,
                        cells: cells,
                        pooled: allRatios.count >= minimumEpisodes ? median(allRatios) : nil,
                        episodes: episodes.sorted { $0.date > $1.date },
                        rejections: rejections)
    }

    // MARK: - ISF from corrections

    /// Glucose moved per unit, from boluses taken with no food near them.
    ///
    /// With nothing eaten, the whole fall over the action window is the dose's
    /// doing, which is what makes these usable where meals are not.
    ///
    /// The catch is that "no food" cannot be established from the log — the
    /// premise of this whole feature is that meals often go unlogged, and an
    /// unlogged meal with its bolus is indistinguishable from a correction by
    /// the log alone. It would drag ISF down and distort every ratio derived
    /// from it.
    ///
    /// So the CGM curve is the arbiter instead, because it does not depend on
    /// anyone remembering anything: carbohydrate absorbing pushes glucose
    /// *above* where it started, and a dose acting alone never does. Any window
    /// containing such a rise is discarded, logged meal or not.
    private static func correctionSensitivities(recent: [Event],
                                                glucose: [GlucosePoint]) -> [Double] {
        var samples: [Double] = []
        for bolus in recent where bolus.kind == .bolus && bolus.amount > 0 {
            let from = bolus.date.addingTimeInterval(-InsulinMath.duration)
            let to = bolus.date.addingTimeInterval(outcomeDelay)

            let foodNearby = recent.contains {
                ($0.kind == .carbsInGrams || $0.kind == .mealWithoutAmount)
                    && $0.date > from && $0.date < to
            }
            if foodNearby { continue }

            let otherInsulin = recent.contains {
                $0.kind == .bolus && $0 != bolus && $0.date > from && $0.date < to
            }
            if otherInsulin { continue }

            guard let g0 = nearest(glucose, to: bolus.date),
                  let g1 = nearest(glucose, to: to) else { continue }

            // A rise above the starting value means something was absorbing.
            // Expressed as a fraction so it holds in mmol/L and mg/dL alike —
            // both are ratio scales, so a percentage is unit-free where any
            // absolute margin would not be.
            let peak = glucose
                .filter { $0.date >= bolus.date && $0.date <= to }
                .map(\.value)
                .max() ?? g0.value
            guard peak <= g0.value * (1 + unloggedFoodRise) else { continue }

            // A fall too small to separate from sensor noise divides badly.
            let drop = g0.value - g1.value
            guard drop >= g0.value * minimumFall else { continue }
            guard bolus.amount >= minimumCorrectionUnits else { continue }
            samples.append(drop / bolus.amount)
        }
        return samples
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
