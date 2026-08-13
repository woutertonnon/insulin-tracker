import Foundation

/// Insulin-on-board and insulin-activity math for **rapid-acting** insulin
/// (NovoRapid / Humalog / Apidra class).
///
/// Source: Gary Scheiner, *Think Like a Pancreas*, ch. 7, **Table 7-8 —
/// "IOB Based on Time Since Bolus Was Given"**:
///
///     hours since bolus   0.5    1    1.5    2    2.5    3    3.5    4
///     insulin used up     10%   30%   50%   65%   80%   90%   95%  100%
///     still working (IOB) 90%   70%   50%   35%   20%   10%    5%    0%
///
/// Long-acting **basal** insulin is deliberately not modelled here — it has a
/// completely different action profile. Callers pass bolus doses only.
enum InsulinMath {

    /// A single rapid-acting bolus.
    struct Dose: Hashable, Sendable {
        let units: Double
        let date: Date
    }

    /// Duration of insulin action. Past this a bolus contributes nothing.
    static let duration: TimeInterval = 4 * 3600

    // MARK: - Table 7-8

    /// Hours since the bolus, matching the columns of Table 7-8 (plus t = 0).
    private static let curveHours: [Double] = [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4]

    /// Fraction of the bolus still working at each of those times.
    private static let curveRemaining: [Double] = [1.00, 0.90, 0.70, 0.50, 0.35, 0.20, 0.10, 0.05, 0.00]

    /// Fraction of a bolus still working `hours` after it was given, linearly
    /// interpolated between the published half-hour values. 1.0 at injection,
    /// 0.0 from 4 h onwards.
    static func remainingFraction(hours: Double) -> Double {
        interpolate(hours, x: curveHours, y: curveRemaining)
    }

    // MARK: - Activity ("insulin intensity")

    /// How fast the insulin is being consumed, sampled at the *midpoint* of each
    /// half-hour interval of Table 7-8. Each value is the table's own
    /// "insulin used up" over that interval, expressed per hour:
    /// e.g. 90% → 70% between 0.5 h and 1 h is 0.40 of the dose per hour.
    ///
    /// Sampling at midpoints (rather than differentiating the interpolated IOB
    /// curve directly) avoids the step-shaped, wobbling derivative that the
    /// table's coarse half-hour resolution would otherwise produce.
    private static let activityHours: [Double] = [0, 0.25, 0.75, 1.25, 1.75, 2.25, 2.75, 3.25, 3.75, 4]
    private static let activityRates: [Double] = [0, 0.20, 0.40, 0.40, 0.30, 0.30, 0.20, 0.10, 0.10, 0]

    /// Peak of `activityRates` — used to normalise so the peak reads 1.0.
    private static let peakRate: Double = 0.40

    /// How active a bolus is `hours` after it was given, on a 0…1 scale where
    /// **1.0 is the peak of the action curve** (roughly 0.75–1.25 h in).
    ///
    /// Multiplied by the dose, this answers "how many units are working on me
    /// right now": 1 U at its peak reads 1.0, and 0 from 4 h onwards.
    static func activityFraction(hours: Double) -> Double {
        interpolate(hours, x: activityHours, y: activityRates) / peakRate
    }

    // MARK: - Exponential model (OpenAPS / Loop)

    /// Time of peak activity for rapid-acting insulin — the OpenAPS/Loop
    /// default for aspart/lispro/glulisine.
    static let exponentialPeak: TimeInterval = 75 * 60

    /// Duration used by the exponential model. Held at `duration` (4 h) so the
    /// forecast agrees with the IOB shown elsewhere in the app. OpenAPS's own
    /// default is 300 min; raising this to `5 * 3600` switches to it.
    static var exponentialDuration: TimeInterval { duration }

    /// Activity `hours` after a bolus under the biexponential model used by
    /// OpenAPS, Loop and AndroidAPS (Dragan Maksimovic):
    ///
    ///     τ = tp·(1 − tp/td) / (1 − 2·tp/td)
    ///     Ia(t) = (S/τ²)·t·(1 − t/td)·e^(−t/τ)
    ///
    /// Returned on the same 0…1 peak-normalised scale as `activityFraction`,
    /// so multiplying by the dose gives units working right now. The model is
    /// built so the peak lands exactly on `tp`, which lets the constant `S/τ²`
    /// cancel in the normalisation.
    static func exponentialActivityFraction(hours: Double) -> Double {
        let td = exponentialDuration / 3600
        let tp = exponentialPeak / 3600
        guard hours > 0, hours < td, tp > 0, td > 2 * tp else { return 0 }

        let tau = tp * (1 - tp / td) / (1 - 2 * tp / td)
        func shape(_ t: Double) -> Double { t * (1 - t / td) * exp(-t / tau) }

        let peak = shape(tp)
        guard peak > 0 else { return 0 }
        return shape(hours) / peak
    }

    /// Units acting at `now` under the exponential model, across stacked boluses.
    static func exponentialActivity(_ doses: [Dose], at now: Date = .now) -> Double {
        doses.reduce(0.0) { $0 + $1.units * exponentialActivityFraction(hours: hours(of: $1, at: now)) }
    }

    // MARK: - Forecast

    /// One sampled point on the activity forecast.
    struct ForecastPoint: Identifiable, Hashable, Sendable {
        let date: Date
        let units: Double
        var id: Date { date }
    }

    /// Project insulin activity forward from `start`, sampling every `step`.
    /// Used by the iPhone's "next 4 hours" chart.
    static func forecast(_ doses: [Dose],
                         from start: Date = .now,
                         span: TimeInterval = duration,
                         step: TimeInterval = 5 * 60) -> [ForecastPoint] {
        guard step > 0, span > 0 else { return [] }
        return Swift.stride(from: 0, through: span, by: step).map { offset in
            let t = start.addingTimeInterval(offset)
            return ForecastPoint(date: t, units: exponentialActivity(doses, at: t))
        }
    }

    // MARK: - Stacked doses

    /// Total insulin on board across every bolus still working — this is what
    /// makes stacked doses visible.
    static func insulinOnBoard(_ doses: [Dose], at now: Date = .now) -> Double {
        doses.reduce(0.0) { $0 + $1.units * remainingFraction(hours: hours(of: $1, at: now)) }
    }

    /// Total units currently *acting*, summed across stacked boluses.
    static func activity(_ doses: [Dose], at now: Date = .now) -> Double {
        doses.reduce(0.0) { $0 + $1.units * activityFraction(hours: hours(of: $1, at: now)) }
    }

    /// When the last of these doses finishes working, or nil if none are active.
    static func lastActiveUntil(_ doses: [Dose], at now: Date = .now) -> Date? {
        doses.map { $0.date.addingTimeInterval(duration) }.filter { $0 > now }.max()
    }

    private static func hours(of dose: Dose, at now: Date) -> Double {
        now.timeIntervalSince(dose.date) / 3600
    }

    // MARK: - Helpers

    /// Piecewise-linear interpolation, clamped to the end values outside the range.
    private static func interpolate(_ v: Double, x: [Double], y: [Double]) -> Double {
        guard let first = x.first, let last = x.last else { return 0 }
        if v <= first { return y[0] }
        if v >= last { return y[y.count - 1] }
        for i in 0..<(x.count - 1) where v <= x[i + 1] {
            let t = (v - x[i]) / (x[i + 1] - x[i])
            return y[i] + t * (y[i + 1] - y[i])
        }
        return y[y.count - 1]
    }

    /// "2.4", "3" — one decimal, trailing ".0" dropped.
    static func format(_ units: Double) -> String {
        let rounded = (units * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
