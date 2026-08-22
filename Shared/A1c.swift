import Foundation

/// Estimated HbA1c from mean glucose, by the regression the ADAG study fitted.
///
/// > A1C-Derived Average Glucose (ADAG) Study — Nathan et al., 2008
/// >
/// >     eAG (mg/dL)  = 28.7 × A1c − 46.7
/// >     eAG (mmol/L) = 1.59 × A1c − 2.59
///
/// Read backwards, since what this app has is the glucose and what it wants is
/// the A1c.
///
/// Applied to **one day at a time**, which answers a question worth asking:
/// *if every day looked like this one, what would the A1c be?* On those terms
/// the chart is a straight rescaling of average glucose — the formula is
/// linear, so the two curves have the same shape — and it earns its place by
/// being in the units people actually hold a target in, not by carrying
/// information the glucose chart lacks.
///
/// What it is **not** is a prediction of a lab result. Haemoglobin carries its
/// glycation for the life of the red cell, so a real A1c answers for roughly
/// the previous three months, weighted towards the recent end of them. A single
/// day cannot say what a blood test will. Read the level, not the point.
///
/// Two further limits on the number itself:
///
/// * ADAG fitted a straight line to a population. Individuals sit off it —
///   red-cell lifespan varies, and the same mean glucose genuinely gives
///   different people different A1cs.
/// * CGM software more often reports **GMI** (Bergenstal, 2018), a different
///   fit over a fourteen-day window, which is why an app's number and this one
///   can disagree by a few tenths. This uses ADAG because that is the formula
///   asked for.
enum A1c {

    /// Anything outside this is arithmetic on bad input, not a person's A1c.
    private static let plausible: ClosedRange<Double> = 3...20

    /// Estimated A1c, in DCCT/NGSP percent, from a mean glucose expressed in
    /// whatever unit Health is set to.
    ///
    /// Unit is decided the same way as everywhere else in the app — mmol/L is
    /// the one whose name contains "mol".
    static func fromMeanGlucose(_ mean: Double, unit: String) -> Double? {
        let estimate = unit.contains("mol")
            ? (mean + 2.59) / 1.59
            : (mean + 46.7) / 28.7
        return plausible.contains(estimate) ? estimate : nil
    }

    /// The IFCC form, for labs that report mmol/mol rather than percent.
    static func millimolesPerMole(_ percent: Double) -> Double {
        (percent - 2.15) * 10.929
    }

    /// "6.8"  — the percent sign lives in the panel's unit label.
    static func format(_ percent: Double) -> String {
        String(format: "%.1f", percent)
    }
}
