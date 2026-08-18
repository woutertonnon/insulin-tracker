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

    /// Why a bolus was not usable for measuring sensitivity. Surfaced so an
    /// overnight correction that quietly failed a filter is visible rather than
    /// simply absent.
    enum CorrectionRejection: String, Hashable, Sendable {
        case foodLogged = "food logged in the 4 h before"
        case windowTooShort = "another dose or meal within 2 h"
        case noGlucose = "no glucose at the dose or at the window end"
        case glucoseRose = "glucose rose — something was absorbing"
        case fallTooSmall = "glucose barely moved"
        case doseTooSmall = "dose under 0.5 U"
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
        /// Boluses considered for sensitivity but discarded, and why.
        let correctionRejections: [CorrectionRejection: Int]
        let cells: [Cell]
        /// All usable meals together — shown when a cell is too thin on its own.
        let pooled: Double?
        let episodes: [Episode]
        let rejections: [Rejection: Int]
    }

    // MARK: - Parameters

    /// Four weeks. Six cells split three ways by daypart and two by exercise
    /// leave a seven-day window with almost nothing in the exercise column;
    /// four weeks fills it while still tracking a real change in sensitivity.
    static let window: TimeInterval = 28 * 24 * 3600

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

    /// Rises before this are ignored. Insulin takes 15–20 minutes to bite, and
    /// people correct when they are high *and climbing*, so glucose going up
    /// straight after a correction is the normal case rather than evidence of
    /// food. Only a rise once the dose should be working means something is
    /// absorbing.
    private static let insulinBiteDelay: TimeInterval = 90 * 60

    /// Shortest usable window. Less than this and too little of the dose has
    /// acted for the extrapolation below to mean anything.
    private static let minimumCorrectionWindow: TimeInterval = 2 * 3600

    /// Minimum fall, as a fraction of the starting value, for a correction to
    /// carry signal rather than sensor noise.
    private static let minimumFall = 0.05

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

        // Sorted once: `nearest` binary-searches, and four weeks of CGM is
        // thousands of points scanned for every dose considered.
        let series = glucose.sorted { $0.date < $1.date }

        let (isfSamples, correctionRejections) = correctionSensitivities(recent: recent,
                                                                         glucose: series)
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
                        correctionRejections: correctionRejections,
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
    private static func correctionSensitivities(
        recent: [Event],
        glucose: [GlucosePoint]
    ) -> (samples: [Double], rejections: [CorrectionRejection: Int]) {
        var samples: [Double] = []
        var rejections: [CorrectionRejection: Int] = [:]
        func reject(_ r: CorrectionRejection) { rejections[r, default: 0] += 1 }

        for bolus in recent where bolus.kind == .bolus && bolus.amount > 0 {
            let from = bolus.date.addingTimeInterval(-InsulinMath.duration)
            let to = bolus.date.addingTimeInterval(outcomeDelay)

            // A bolus paired with a meal is a meal episode, not a correction,
            // and is silently skipped rather than reported as a failure — it
            // was never a candidate.
            let mealBolus = recent.contains {
                guard $0.kind == .carbsInGrams || $0.kind == .mealWithoutAmount else { return false }
                let offset = $0.date.timeIntervalSince(bolus.date)
                return offset >= -bolusTrail && offset <= bolusLead
            }
            if mealBolus { continue }

            if recent.contains(where: {
                ($0.kind == .carbsInGrams || $0.kind == .mealWithoutAmount)
                    && $0.date > from && $0.date <= bolus.date
            }) {
                reject(.foodLogged)
                continue
            }

            // Anything after the dose truncates the window rather than voiding
            // it. A morning correction followed by breakfast still has a clean
            // couple of hours in it, and throwing that away discards most real
            // corrections.
            let nextEvent = recent
                .filter { $0 != bolus && $0.kind != .basal && $0.date > bolus.date }
                .map(\.date)
                .min()
            let horizon = min(to, nextEvent ?? to)
            let span = horizon.timeIntervalSince(bolus.date)
            guard span >= minimumCorrectionWindow else {
                reject(.windowTooShort)
                continue
            }

            guard let g0 = nearest(glucose, to: bolus.date),
                  let g1 = nearest(glucose, to: horizon) else {
                reject(.noGlucose)
                continue
            }

            // Only look for a food hump once the dose should be biting; before
            // that a rise is just insulin lag on a climbing glucose.
            let peak = glucose
                .filter { $0.date >= bolus.date.addingTimeInterval(insulinBiteDelay)
                          && $0.date <= horizon }
                .map(\.value)
                .max() ?? g0.value
            guard peak <= g0.value * (1 + unloggedFoodRise) else {
                reject(.glucoseRose)
                continue
            }

            guard bolus.amount >= minimumCorrectionUnits else {
                reject(.doseTooSmall)
                continue
            }

            let drop = g0.value - g1.value
            guard drop >= g0.value * minimumFall else {
                reject(.fallTooSmall)
                continue
            }

            // The window may end before the dose has finished, so scale by how
            // much of it had acted by then — the same action curve the rest of
            // the app uses. Without this, a truncated window would understate
            // sensitivity in proportion to how early it was cut.
            let actedFraction = 1 - InsulinMath.remainingFraction(hours: span / 3600)
            guard actedFraction >= 0.4 else {
                reject(.windowTooShort)
                continue
            }

            samples.append(drop / (bolus.amount * actedFraction))
        }
        return (samples, rejections)
    }

    // MARK: - Helpers

    /// Closest reading to `date`, or nil if none is close enough.
    ///
    /// Binary search, not a scan: four weeks of CGM is thousands of points and
    /// this runs for every dose and meal considered. Requires `points` sorted
    /// ascending, which `estimate` guarantees.
    private static func nearest(_ points: [GlucosePoint], to date: Date) -> GlucosePoint? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }

        // The insertion point straddles the answer: check either side of it.
        var best: GlucosePoint?
        for index in [low - 1, low] where index >= 0 && index < points.count {
            let candidate = points[index]
            let gap = abs(candidate.date.timeIntervalSince(date))
            guard gap <= glucoseTolerance else { continue }
            if let current = best, abs(current.date.timeIntervalSince(date)) <= gap { continue }
            best = candidate
        }
        return best
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
