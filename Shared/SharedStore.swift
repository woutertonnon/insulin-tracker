import Foundation

/// Tiny shared store (App Group) so the watch complication can read the most
/// recent insulin dose that the watch app writes. Widgets run in a separate
/// process, so this is how the data crosses over.
enum SharedStore {
    static let appGroup = "group.com.woutertonnon.insulintracker"

    private static let unitsKey = "lastInsulinUnits"
    private static let dateKey = "lastInsulinDate"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func setLastInsulin(units: Double, date: Date) {
        guard let d = defaults else { return }
        d.set(units, forKey: unitsKey)
        d.set(date.timeIntervalSince1970, forKey: dateKey)
    }

    static func lastInsulin() -> (units: Double, date: Date)? {
        guard let d = defaults, d.object(forKey: dateKey) != nil else { return nil }
        let units = d.double(forKey: unitsKey)
        let ts = d.double(forKey: dateKey)
        return (units, Date(timeIntervalSince1970: ts))
    }
}
