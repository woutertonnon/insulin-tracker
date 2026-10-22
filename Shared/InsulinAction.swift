import Foundation

/// How fast each of the two insulins in the log acts, per unit injected, as a
/// fraction of the dose per hour. Multiplied by a dose, each gives **units
/// acting per hour**; integrated over the dose's life, each comes back to the
/// dose.
///
/// Rates, rather than the peak-normalised "units active" the complication
/// shows, because a rate is the only form in which basal and bolus can be
/// added: one unit an hour of glargine and one unit an hour of aspart are the
/// same thing. It is also the unit a pump's basal is prescribed in, so a
/// clinic reads the basal half of the curve without translation.
///
/// Only the doctor's report uses this. The watch and the forecast chart keep
/// the convention described in `InsulinMath`.
enum InsulinAction {

    // MARK: - Rapid-acting: NovoRapid (aspart)

    /// The biexponential curve the forecast chart draws — see
    /// `InsulinMath.exponentialActivityFraction` — rescaled so the area under
    /// it is one rather than its peak.
    static func bolusRate(hours: Double) -> Double {
        guard hours > 0, hours < bolusDuration else { return 0 }
        return InsulinMath.exponentialActivityFraction(hours: hours) / bolusArea
    }

    static var bolusDuration: Double { InsulinMath.exponentialDuration / 3600 }

    private static let bolusArea = integrate(InsulinMath.exponentialActivityFraction, over: bolusDuration)

    // MARK: - Long-acting: Lantus (glargine)

    /// Glargine's standard profile: onset over the first hour or two, then
    /// near-flat — "peakless" is the word on the box — and gone by about
    /// twenty-four hours, with the fall starting a few hours before that.
    /// Clamp studies (Lepore et al., 2000) and *Think Like a Pancreas* both
    /// describe it this way; neither gives it a shape finer than this, so
    /// this is a smooth trapezoid and not a fit.
    static let basalOnset: Double = 2
    static let basalPlateauEnd: Double = 20
    static let basalDuration: Double = 24

    /// On a 0…1 scale: a smooth rise to the plateau, flat, a smooth fall.
    static func basalShape(hours: Double) -> Double {
        guard hours > 0, hours < basalDuration else { return 0 }
        if hours < basalOnset { return ease(hours / basalOnset) }
        if hours <= basalPlateauEnd { return 1 }
        return ease((basalDuration - hours) / (basalDuration - basalPlateauEnd))
    }

    static func basalRate(hours: Double) -> Double {
        basalShape(hours: hours) / basalArea
    }

    private static let basalArea = integrate(basalShape, over: basalDuration)

    // MARK: - Helpers

    /// Smoothstep, so the corners of the trapezoid are not drawn as corners.
    private static func ease(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Trapezoid rule at one-minute steps, done once per curve.
    private static func integrate(_ f: (Double) -> Double, over hours: Double) -> Double {
        let steps = Int(hours * 60)
        guard steps > 0 else { return 1 }
        let width = hours / Double(steps)
        var sum = 0.0
        for i in 0...steps {
            let weight = (i == 0 || i == steps) ? 0.5 : 1.0
            sum += weight * f(Double(i) * width)
        }
        return max(sum * width, .leastNonzeroMagnitude)
    }
}
