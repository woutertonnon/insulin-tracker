import Foundation

/// Tiny shared store (App Group) so the watch complication can read the recent
/// bolus history that the watch app writes. Widgets run in a separate process,
/// so this is how the data crosses over.
enum SharedStore {
    static let appGroup = "group.com.woutertonnon.insulintracker"

    /// Flat `[timestamp, units, timestamp, units, …]` — UserDefaults stores
    /// plist primitives, and a flat `[Double]` is the simplest thing that works.
    private static let dosesKey = "recentBolusDoses"

    /// Boluses older than this are dropped on write. Well past the 4 h duration
    /// of insulin action, so the "time since last dose" timer keeps working
    /// long after the insulin itself is gone.
    private static let retention: TimeInterval = 24 * 3600

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Replace the stored bolus history. Basal doses must not be passed in —
    /// they are not part of the IOB model.
    static func setBolusDoses(_ doses: [InsulinMath.Dose], now: Date = .now) {
        guard let d = defaults else { return }
        let cutoff = now.addingTimeInterval(-retention)
        let flat = doses
            .filter { $0.date > cutoff }
            .sorted { $0.date < $1.date }
            .flatMap { [$0.date.timeIntervalSince1970, $0.units] }
        d.set(flat, forKey: dosesKey)
    }

    /// Stored boluses, oldest first.
    static func bolusDoses() -> [InsulinMath.Dose] {
        guard let d = defaults, let flat = d.array(forKey: dosesKey) as? [Double] else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            InsulinMath.Dose(units: flat[$0 + 1], date: Date(timeIntervalSince1970: flat[$0]))
        }
    }

    /// The most recent bolus, for the "last dose" line.
    static func lastBolus() -> InsulinMath.Dose? {
        bolusDoses().last
    }
}
