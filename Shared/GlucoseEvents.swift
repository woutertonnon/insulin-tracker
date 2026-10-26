import Foundation

/// Low and high glucose events: the stretches of CGM a clinic asks about one
/// by one, each set beside what was going on around it — the insulin, the
/// exercise, and the finger-prick readings taken, corrected for the air they
/// were taken in.
///
/// * **Low** — below 60 mg/dL at any point, or below 70 mg/dL for 30 minutes
///   or longer.
/// * **High** — above 180 mg/dL for an hour or longer.
///
/// Edges are set in mg/dL and converted exactly for a report in mmol/L, so the
/// same CGM trace yields the same events in either unit.
///
/// An event ends once glucose has been back across the line for 15 minutes,
/// as in the international consensus on CGM events — a single reading
/// bouncing over the line does not split one low into two — or at a CGM gap
/// longer than `Report`'s 20 minutes, past which nothing is known.
extension Report {

    struct EventThresholds: Hashable, Sendable {
        /// Below this at any point is a low, however brief.
        let urgentLow: Double
        /// Below this for `lowMinutes` is a low.
        let low: Double
        let lowMinutes: Int
        /// Above this for `highMinutes` is a high.
        let high: Double
        let highMinutes: Int
        let unit: String

        static func standard(unit: String) -> EventThresholds {
            let scale = unit.contains("mol") ? 1 / GlucoseUnit.milligramsPerMillimole : 1
            return EventThresholds(urgentLow: 60 * scale, low: 70 * scale, lowMinutes: 30,
                                   high: 180 * scale, highMinutes: 60, unit: unit)
        }

        /// "< 3.3 mmol/L, or < 3.9 mmol/L for ≥ 30 min"
        var lowDefinition: String {
            "< \(format(urgentLow)) \(unit) at any point, or < \(format(low)) \(unit) for ≥ \(lowMinutes) min"
        }

        /// "> 10.0 mmol/L for ≥ 60 min"
        var highDefinition: String {
            "> \(format(high)) \(unit) for ≥ \(highMinutes) min"
        }

        func format(_ value: Double) -> String { InsulinStats.formatGlucose(value, unit: unit) }
    }

    enum EventKind: Hashable, Sendable {
        case low
        case high
    }

    /// A finger-prick reading near an event, as taken and as corrected.
    struct MeterReading: Hashable, Sendable {
        let date: Date
        /// mmol/L, as stored.
        let value: Double
        /// Outside air, °C, when the reading was taken outdoors and the
        /// weather is known.
        let celsius: Double?
        /// The value corrected for `celsius`, mmol/L. Nil indoors, or when the
        /// temperature is not known.
        let adjusted: Double?
    }

    struct GlucoseEvent: Identifiable, Hashable, Sendable {
        let id: Int
        let kind: EventKind
        let start: Date
        let end: Date
        /// The lowest reading of a low, the highest of a high — CGM unit.
        let extreme: Double
        let extremeAt: Date
        /// Whether a low went under the urgent line, as opposed to qualifying
        /// on duration alone.
        let reachedUrgent: Bool

        /// What the event's chart shows, in time order.
        let context: ClosedRange<Date>
        let cgm: [GlucosePoint]
        /// Boluses in the four hours before through the end, and the last
        /// basal in the 30 hours before.
        let doses: [Event]
        /// Rapid-acting insulin still working at the start [5].
        let bolusOnBoard: Double
        /// Workouts that overlap the six hours before through the end. A low
        /// can follow exercise by hours.
        let workouts: [Workout]
        /// Finger-pricks from an hour before to an hour after.
        let meter: [MeterReading]

        var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    }

    /// The window an event is read in.
    private static let doseLookBack: TimeInterval = InsulinMath.duration
    private static let basalLookBack: TimeInterval = 30 * 3600
    private static let workoutLookBack: TimeInterval = 6 * 3600
    private static let meterMargin: TimeInterval = 3600
    private static let chartAfter: TimeInterval = 3600

    /// Back across the line for this long ends an event.
    private static let recovery: TimeInterval = 15 * 60

    /// Events that start in `period`, in time order. `glucose` sorted
    /// ascending; it may reach outside the period, and does, so an event
    /// can be read from before it began and to after it ended.
    static func glucoseEvents(_ kind: EventKind,
                              thresholds: EventThresholds,
                              glucose: [GlucosePoint],
                              period: Range<Date>,
                              events: [Event],
                              workouts: [Workout],
                              outings: [Temperature.Outing],
                              marks: [Temperature.Mark]) -> [GlucoseEvent] {
        let inside: (Double) -> Bool = kind == .low
            ? { $0 < thresholds.low }
            : { $0 > thresholds.high }
        let qualifies: (_ minutes: Double, _ extreme: Double) -> Bool = kind == .low
            ? { $0 >= Double(thresholds.lowMinutes) || $1 < thresholds.urgentLow }
            : { minutes, _ in minutes >= Double(thresholds.highMinutes) }

        var found: [GlucoseEvent] = []
        var i = 0
        while i < glucose.count {
            guard inside(glucose[i].value) else { i += 1; continue }
            let first = i
            var last = i
            var recoveredAt: Int?
            var j = i + 1
            while j < glucose.count {
                if glucose[j].date.timeIntervalSince(glucose[j - 1].date) > maximumGap { break }
                if inside(glucose[j].value) {
                    last = j
                    recoveredAt = nil
                } else {
                    if recoveredAt == nil { recoveredAt = j }
                    if let r = recoveredAt, glucose[j].date.timeIntervalSince(glucose[r].date) >= recovery { break }
                }
                j += 1
            }
            i = max(j, last + 1)

            let start = glucose[first].date
            // Ends at the first reading back across the line, when there is
            // one before the gap; otherwise at the last reading inside it.
            let end = recoveredAt.map { glucose[$0].date } ?? glucose[last].date
            let span = glucose[first...last]
            let extremePoint = kind == .low
                ? span.min { $0.value < $1.value }!
                : span.max { $0.value < $1.value }!
            guard period.contains(start),
                  qualifies(end.timeIntervalSince(start) / 60, extremePoint.value) else { continue }

            found.append(event(kind: kind, id: found.count, start: start, end: end,
                               extreme: extremePoint, thresholds: thresholds,
                               glucose: glucose, events: events, workouts: workouts,
                               outings: outings, marks: marks))
        }
        return found
    }

    private static func event(kind: EventKind,
                              id: Int,
                              start: Date,
                              end: Date,
                              extreme: GlucosePoint,
                              thresholds: EventThresholds,
                              glucose: [GlucosePoint],
                              events: [Event],
                              workouts: [Workout],
                              outings: [Temperature.Outing],
                              marks: [Temperature.Mark]) -> GlucoseEvent {
        let boluses = events.filter {
            $0.kind == .insulin && $0.date >= start.addingTimeInterval(-doseLookBack) && $0.date <= end
        }
        let basal = events.last {
            $0.kind == .basal && $0.date >= start.addingTimeInterval(-basalLookBack) && $0.date <= end
        }
        let doses = (boluses + [basal].compactMap { $0 }).sorted { $0.date < $1.date }

        let onBoard = InsulinMath.insulinOnBoard(
            boluses.filter { $0.date <= start }.map { InsulinMath.Dose(units: $0.amount, date: $0.date) },
            at: start
        )

        let nearby = workouts.filter {
            $0.end >= start.addingTimeInterval(-workoutLookBack) && $0.start <= end
        }

        let meter = events
            .filter {
                $0.kind == .glucose
                    && $0.date >= start.addingTimeInterval(-meterMargin)
                    && $0.date <= end.addingTimeInterval(meterMargin)
            }
            .map { reading -> MeterReading in
                let celsius = outsideAir(reading, outings: outings, marks: marks)
                return MeterReading(date: reading.date,
                                    value: reading.amount,
                                    celsius: celsius,
                                    adjusted: celsius.map { Temperature.adjustedGlucose(reading.amount, celsius: $0) })
            }

        // The four hours a bolus acts for before the start, to an hour after
        // the end.
        let from = start.addingTimeInterval(-doseLookBack)
        let to = end.addingTimeInterval(chartAfter)

        return GlucoseEvent(id: id,
                            kind: kind,
                            start: start,
                            end: end,
                            extreme: extreme.value,
                            extremeAt: extreme.date,
                            reachedUrgent: kind == .low && extreme.value < thresholds.urgentLow,
                            context: from...to,
                            cgm: glucose.filter { $0.date >= from && $0.date <= to },
                            doses: doses,
                            bolusOnBoard: onBoard,
                            workouts: nearby,
                            meter: meter)
    }

    /// The outside air a finger-prick was taken in, when it was taken outside
    /// and the weather is known — the badge as saved, or for a row from before
    /// the badge, decided the way the watch would have.
    static func outsideAir(_ event: Event,
                           outings: [Temperature.Outing],
                           marks: [Temperature.Mark]) -> Double? {
        guard event.kind == .glucose, let celsius = event.temperature else { return nil }
        var outdoors = event.outdoors ?? false
        if event.outdoors == nil {
            var knownIndoors = false
            if let latitude = event.latitude, let longitude = event.longitude {
                knownIndoors = Temperature.isKnownIndoors(latitude: latitude, longitude: longitude, marks: marks)
            }
            outdoors = Temperature.isOutdoors(at: event.date, marked: nil, knownIndoors: knownIndoors,
                                              outings: outings, moving: event.moving)
        }
        return outdoors ? celsius : nil
    }
}
