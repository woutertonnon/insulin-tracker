import Foundation

/// Outside air temperature at a finger-prick reading, and what it does to the
/// number the meter shows.
///
/// A meter has no thermometer. Its strip's enzyme runs slower in the cold and
/// faster in the heat, and the meter converts the current it sees as if the
/// strip were at room temperature — so a reading taken outside in winter
/// comes out low, and one taken in a heatwave comes out high. *Riding the
/// Glucose Trail*, "BG & temperatures", fitted this on a Contour Next One
/// against readings taken indoors and out over a winter:
///
///     reading = true value + β × (T − 22.5 °C)        β ≈ 0.0928 mmol/L per °C
///
/// read the other way, since the app has the reading and wants the value:
///
///     adjusted = reading − 0.0928 × (T − 22.5 °C)
///
/// At 0 °C a reading of 5 mmol/L adjusts to about 7; at 40 °C, to about 3.4 —
/// the article's own two examples. The article prints its mmol/L shortcut
/// with the sign the other way round, which contradicts both its model and
/// both examples; the model and the examples are followed here.
///
/// It is one person's meter, fitted mostly between 0 and 15 °C. Another meter,
/// another batch of strips, or a reading taken from a warm pocket moments
/// after coming in will sit off it. The adjusted figure is shown beside the
/// reading, never in place of it, and nothing else in the app uses it.
enum Temperature {

    /// mmol/L per degree Celsius.
    static let slope = 0.0928

    /// The temperature the meter is assumed to be calibrated for.
    static let reference: Double = 22.5

    /// The reading corrected for the air it was taken in. Both in mmol/L, as
    /// readings are stored.
    static func adjustedGlucose(_ reading: Double, celsius: Double) -> Double {
        reading - slope * (celsius - reference)
    }

    // MARK: - Indoors or out

    /// The effect is the strip's temperature, and a strip indoors is at room
    /// temperature whatever the weather. So the adjustment applies only to
    /// readings taken outside, and the app has to decide which those are.
    ///
    /// The badge the reading saved with is the truth, and nothing here
    /// changes it. What follows decides only where the badge **starts** —
    /// on the watch for a reading being dialled, on the phone's switch for
    /// one typed there, and for rows from before the badge existed — in
    /// order of how much each witness knows:
    ///
    /// 1. **The place.** A spot the person has put inside often enough — see
    ///    `isKnownIndoors` — is inside, whatever else is going on: the kitchen
    ///    at the end of a ride is still the kitchen.
    /// 2. **Health's workouts**, which know their kind and whether they were
    ///    indoors: a hike, a paddle, a road ride are outside; a trainer
    ///    session, a treadmill, a pool are not. A reading during one, or in
    ///    the quarter hour after it ends while the meter is still cold from
    ///    the pocket, goes with it. The watch does not have these; the phone
    ///    uses them for its switch.
    /// 3. **The wrist's motion coprocessor**, which saw cycling or running in
    ///    the quarter hour before.
    ///
    /// With none of them, indoors: the common case, and the one where being
    /// wrong costs least.
    static let afterWorkout: TimeInterval = 15 * 60

    /// A workout, and which side of the door it was on.
    struct Outing: Hashable, Sendable {
        let span: ClosedRange<Date>
        let outdoors: Bool

        func contains(_ date: Date) -> Bool {
            date >= span.lowerBound && date <= span.upperBound.addingTimeInterval(Temperature.afterWorkout)
        }
    }

    static func isOutdoors(at date: Date,
                           marked: Bool?,
                           knownIndoors: Bool,
                           outings: [Outing],
                           moving: Bool?) -> Bool {
        if let marked { return marked }
        if knownIndoors { return false }
        if let outing = outings.first(where: { $0.contains(date) }) { return outing.outdoors }
        return moving ?? false
    }

    // MARK: - Places learnt from marks

    /// A reading the person put inside or outside themselves, and where it
    /// was. Every one is a lesson about that spot — a starting position
    /// merely let stand is not. Nothing is stored beyond the readings
    /// themselves, so both devices learn the same places from the same log.
    struct Mark: Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        let outdoors: Bool
    }

    /// How close two readings must be to count as the same place. A Wi‑Fi
    /// fix indoors is good to a few tens of metres, which this comfortably
    /// covers; it does not reach the café down the road.
    static let placeRadius: Double = 150

    /// How many lessons a place needs before it is believed. Three, as asked
    /// for: one flip is a flip, three is a kitchen.
    static let placeEvidence = 3

    /// Whether this spot has been marked inside often enough — at least
    /// `placeEvidence` more inside marks than outside marks within
    /// `placeRadius`. Outside marks count against, so a garden that keeps
    /// being flipped the other way does not become the house.
    static func isKnownIndoors(latitude: Double, longitude: Double, marks: [Mark]) -> Bool {
        var net = 0
        for mark in marks
        where distance(latitude, longitude, mark.latitude, mark.longitude) <= placeRadius {
            net += mark.outdoors ? -1 : 1
        }
        return net >= placeEvidence
    }

    /// Great-circle distance in metres. Haversine, on a sphere: the error
    /// against the ellipsoid is well under a metre at these distances.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let toRadians = Double.pi / 180
        let dLat = (lat2 - lat1) * toRadians
        let dLon = (lon2 - lon1) * toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * toRadians) * cos(lat2 * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// "18 °C" or "64 °F", whichever the locale uses.
    static func format(celsius: Double) -> String {
        #if canImport(Darwin)
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
        #else
        // swift-corelibs-foundation has no MeasurementFormatter; this branch
        // exists only so the model can be compiled and exercised on Linux.
        return "\(Int(celsius.rounded())) °C"
        #endif
    }
}
