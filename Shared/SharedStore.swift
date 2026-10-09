import Foundation

/// Tiny shared store (App Group) so the watch complication can read the recent
/// bolus history that the watch app writes. Widgets run in a separate process,
/// so this is how the data crosses over.
enum SharedStore {
    static let appGroup = "group.com.woutertonnon.insulintracker"

    /// Flat `[timestamp, units, timestamp, units, …]` — UserDefaults stores
    /// plist primitives, and a flat `[Double]` is the simplest thing that works.
    private static let dosesKey = "recentBolusDoses"

    /// The basal reminder, as minutes after local midnight. Absent means no
    /// reminder. The phone owns this value and pushes it over
    /// WatchConnectivity — this is where the complication reads it.
    private static let basalReminderKey = "basalReminderMinuteOfDay"

    /// When basal was last logged, as a Unix timestamp. The complication needs
    /// it to know today's dose has been taken; it feeds no insulin math, since
    /// long-acting insulin is not described by the curve in `InsulinMath`.
    private static let lastBasalKey = "lastBasalDose"

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

    // MARK: - Basal reminder

    /// Replace the stored reminder; nil clears it.
    static func setBasalReminder(_ reminder: BasalSchedule.Reminder?) {
        guard let d = defaults else { return }
        if let reminder {
            d.set(reminder.minuteOfDay, forKey: basalReminderKey)
        } else {
            d.removeObject(forKey: basalReminderKey)
        }
    }

    static func basalReminder() -> BasalSchedule.Reminder? {
        guard let d = defaults, let minute = d.object(forKey: basalReminderKey) as? Int else {
            return nil
        }
        return BasalSchedule.Reminder(minuteOfDay: minute)
    }

    /// Replace the newest-basal timestamp; nil clears it, which is what a
    /// deleted basal entry has to do.
    ///
    /// Not subject to `retention` like the boluses: an old timestamp is not
    /// stale data here, it is the correct answer to "when was the last one",
    /// and the reminder rule compares against its own window anyway.
    static func setLastBasal(_ date: Date?) {
        guard let d = defaults else { return }
        if let date {
            d.set(date.timeIntervalSince1970, forKey: lastBasalKey)
        } else {
            d.removeObject(forKey: lastBasalKey)
        }
    }

    static func lastBasal() -> Date? {
        guard let d = defaults, let t = d.object(forKey: lastBasalKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}
