import Foundation

/// The standard time of day the long-acting basal injection is taken, and the
/// rule that decides when the watch complication should be shouting about it.
///
/// Basal is the one dose nothing else in the day reminds you of. A bolus has a
/// meal attached to it; a missed basal announces itself only hours later, and
/// by then the evidence is indistinguishable from a bad day. It is also the
/// largest single error in everything else this app computes — see **Averages**,
/// where a day with no basal on it divides an average without contributing to
/// it.
///
/// Deliberately **not** a notification. A notification is dismissed by the same
/// reflex that dismisses every other notification, and what is wanted here is
/// something that is simply *there* the next time the wrist goes up. So the
/// complication gives itself over to the reminder instead, and keeps it until
/// the dose is logged.
enum BasalSchedule {

    /// A time of day in the local calendar.
    ///
    /// Stored as hour and minute rather than as a `Date` because the time of
    /// day *is* the setting — the instant it lands on is derived per day, so it
    /// follows the wall clock across a time zone change or a clock change,
    /// which is what "I take it at ten" means.
    struct Reminder: Hashable, Sendable {
        let hour: Int
        let minute: Int

        /// Minutes after local midnight — the form it crosses to the watch in
        /// and is stored in, one integer being the smallest thing that survives
        /// both `UserDefaults` and a WatchConnectivity payload unambiguously.
        var minuteOfDay: Int { hour * 60 + minute }

        init(hour: Int, minute: Int) {
            self.hour = min(max(hour, 0), 23)
            self.minute = min(max(minute, 0), 59)
        }

        /// Fails rather than clamping. A value this initialiser rejects came
        /// off the wire or out of the App Group, and a reminder that quietly
        /// relocated itself to midnight would be worse than no reminder at all.
        /// `reminderOff` is routed through here on purpose.
        init?(minuteOfDay: Int) {
            guard (0..<(24 * 60)).contains(minuteOfDay) else { return nil }
            self.init(hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        }
    }

    /// How long the alert stays up after its time.
    ///
    /// Bounded on purpose. The alert replaces the whole complication, so a
    /// version that waited indefinitely for a basal entry would destroy the IOB
    /// readout for the rest of any day the injection was taken but not logged —
    /// and a complication that always says BASAL! is not a signal, it is
    /// wallpaper. Two hours survives a glance missed in a meeting and gives up
    /// before it starts lying.
    static let alertWindow: TimeInterval = 2 * 3600

    /// How far *before* its time a logged basal still counts as that day's dose.
    ///
    /// Without this, taking it early — which happens whenever the evening isn't
    /// the usual one — would still have the complication demanding it at the
    /// scheduled minute, which is to say asking for a second dose of
    /// long-acting insulin. That is the only failure mode here with a real
    /// consequence, so the allowance is generous.
    static let earlyGrace: TimeInterval = 3 * 3600

    /// The `minuteOfDay` that means "no reminder" when the setting is sent over
    /// WatchConnectivity. A sentinel rather than an absent key so that turning
    /// the reminder *off* is itself a message — an absent key means the sender
    /// said nothing about the reminder, which is not the same thing.
    static let reminderOff = -1

    // MARK: - Where the setting lives

    /// The phone owns this setting and keeps it here, in its own defaults.
    ///
    /// The watch keeps its copy in the App Group (`SharedStore`) instead, which
    /// is the only store a widget process can read, and gets it over
    /// WatchConnectivity — App Groups do not cross between devices.
    enum Defaults {
        static let enabledKey = "basalReminderEnabled"
        static let minuteOfDayKey = "basalReminderMinuteOfDay"

        /// Ten in the evening. A common long-acting time and nothing more than
        /// a starting position for the picker.
        static let defaultMinuteOfDay = 22 * 60

        /// The reminder as currently set on this device, or nil when off.
        static func current(_ defaults: UserDefaults = .standard) -> Reminder? {
            guard defaults.bool(forKey: enabledKey) else { return nil }
            let minute = defaults.object(forKey: minuteOfDayKey) as? Int ?? defaultMinuteOfDay
            return Reminder(minuteOfDay: minute)
        }
    }

    // MARK: - Resolving the time of day onto actual days

    private static func components(_ reminder: Reminder) -> DateComponents {
        var c = DateComponents()
        c.hour = reminder.hour
        c.minute = reminder.minute
        c.second = 0
        return c
    }

    /// The most recent occurrence of the reminder at or before `date`.
    static func mostRecentDue(at date: Date,
                              reminder: Reminder,
                              calendar: Calendar = .current) -> Date? {
        // `nextDate` is strictly after its anchor, so search back from a second
        // past `date`: the widget puts a timeline entry on the due instant
        // itself, and that entry has to read as due rather than as one tick
        // early.
        calendar.nextDate(after: date.addingTimeInterval(1),
                          matching: components(reminder),
                          matchingPolicy: .nextTime,
                          repeatedTimePolicy: .first,
                          direction: .backward)
    }

    /// The next occurrence of the reminder strictly after `date`.
    static func nextDue(after date: Date,
                        reminder: Reminder,
                        calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: date,
                          matching: components(reminder),
                          matchingPolicy: .nextTime,
                          repeatedTimePolicy: .first,
                          direction: .forward)
    }

    // MARK: - The rule

    /// What the reminder is doing at `date`.
    ///
    /// One function, because the complication and the phone's settings screen
    /// must not be able to disagree about whether the dose is outstanding.
    enum Status: Equatable {
        /// No reminder set.
        case off
        /// Overdue since this instant — the complication shows BASAL!
        case due(since: Date)
        /// This window's dose is logged, at this time.
        case taken(at: Date)
        /// Nothing outstanding; next one at this instant.
        case waiting(until: Date)
    }

    static func status(at date: Date,
                       reminder: Reminder?,
                       lastBasal: Date?,
                       calendar: Calendar = .current) -> Status {
        guard let reminder else { return .off }

        if let due = overdue(at: date, reminder: reminder, lastBasal: lastBasal, calendar: calendar) {
            return .due(since: due)
        }

        // Not overdue, but still inside a window: the only way that happens is
        // that the dose has been logged for it.
        if let due = mostRecentDue(at: date, reminder: reminder, calendar: calendar),
           date < due.addingTimeInterval(alertWindow),
           let lastBasal {
            return .taken(at: lastBasal)
        }

        if let next = nextDue(after: date, reminder: reminder, calendar: calendar) {
            return .waiting(until: next)
        }
        return .off
    }

    /// The scheduled instant the dose is outstanding from, or nil if it isn't.
    private static func overdue(at date: Date,
                                reminder: Reminder,
                                lastBasal: Date?,
                                calendar: Calendar) -> Date? {
        guard let due = mostRecentDue(at: date, reminder: reminder, calendar: calendar),
              date < due.addingTimeInterval(alertWindow)
        else { return nil }

        // Already taken — either after its time, or early enough to count.
        if let lastBasal, lastBasal >= due.addingTimeInterval(-earlyGrace) { return nil }
        return due
    }

    // MARK: - For the widget's timeline

    /// The instants between `start` and `end` at which the alert turns on or off.
    ///
    /// WidgetKit renders only at the dates it is handed, and it budgets
    /// timeline *refreshes* per day — so without an entry sitting on the due
    /// minute itself, "ten o'clock" would mean "some time after ten". These are
    /// the dates that make the flip land when it says it will.
    static func transitions(from start: Date,
                            to end: Date,
                            reminder: Reminder,
                            calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []

        // The end of a window that is already running at `start`.
        if let current = mostRecentDue(at: start, reminder: reminder, calendar: calendar) {
            let off = current.addingTimeInterval(alertWindow)
            if off > start && off <= end { result.append(off) }
        }

        // Then each occurrence ahead, with its own end. The iteration cap is a
        // backstop against a calendar that fails to advance, not a real bound:
        // a day of lookahead is two dates.
        var cursor = start
        for _ in 0..<8 {
            guard let due = nextDue(after: cursor, reminder: reminder, calendar: calendar),
                  due <= end
            else { break }
            result.append(due)
            let off = due.addingTimeInterval(alertWindow)
            if off <= end { result.append(off) }
            cursor = due
        }

        return result.sorted()
    }
}
