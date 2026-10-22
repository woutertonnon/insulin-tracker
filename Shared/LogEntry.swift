import Foundation
import SwiftData

/// The things we track.
///
/// * `glucose` — a finger-prick reading, stored in mmol/L whatever unit it
///               was dialled in (see `GlucoseUnit`)
/// * `insulin` — rapid-acting bolus units; the only kind that feeds IOB
/// * `basal`   — long-acting background insulin units; excluded from IOB
enum EntryKind: String, Codable, Sendable, CaseIterable {
    case glucose
    case insulin
    case basal
}

/// A single logged event, stored locally with SwiftData on each device.
@Model
final class LogEntry {
    /// Stable id so the phone can de-duplicate entries pushed from the watch.
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Stored as a String because SwiftData persists primitives most reliably.
    var kindRaw: String
    /// mmol/L for `glucose`, units for `insulin` and `basal`.
    var amount: Double

    /// Where a reading was taken, so the outside temperature at that moment
    /// can be looked up for it later. Readings logged on the watch carry
    /// these; doses do not. Optional, so rows from before they existed load
    /// as they are.
    var latitude: Double?
    var longitude: Double?
    /// Metres above sea level at the reading, from the fix. Handed to the
    /// weather lookup, which downscales the temperature to it, so a reading
    /// on a mountainside gets the mountainside's air rather than the valley's.
    var altitude: Double?

    /// Outside air temperature at the reading, in °C, filled in afterwards by
    /// the phone from Open-Meteo. Nil until it has been.
    var temperature: Double?

    /// Whether the reading was taken outside: the badge as it stood on the
    /// watch when the reading saved, or the switch as it stood on the phone.
    /// **Ground truth.** The person saw it and let it stand or flipped it, and
    /// nothing recomputes it afterwards. Nil only on rows from before the
    /// badge existed, which are read as indoors.
    var outdoors: Bool?

    /// Whether the person set it themselves — flipped the badge on the watch
    /// or moved the switch on the phone — rather than let the starting
    /// position stand. Only these teach the app which places are indoors.
    var chosen: Bool?

    /// Whether the wrist saw cycling or running in the quarter hour before
    /// the reading. What set the badge's starting position; kept for the
    /// record.
    var moving: Bool?

    init(id: UUID = UUID(), timestamp: Date, kind: EntryKind, amount: Double) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.amount = amount
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// This reading as a lesson about its place: where it was, and which
    /// side of the door the person put it on. Nil unless they chose.
    var mark: Temperature.Mark? {
        guard kind == .glucose, chosen == true, let outdoors, let latitude, let longitude else { return nil }
        return Temperature.Mark(latitude: latitude, longitude: longitude, outdoors: outdoors)
    }

    /// The badge as saved. For a row from before the badge existed, what the
    /// place, the workouts and the wrist say — see `Temperature.isOutdoors`.
    func isOutdoors(outings: [Temperature.Outing], marks: [Temperature.Mark]) -> Bool {
        if let outdoors { return outdoors }
        var knownIndoors = false
        if let latitude, let longitude {
            knownIndoors = Temperature.isKnownIndoors(latitude: latitude, longitude: longitude, marks: marks)
        }
        return Temperature.isOutdoors(at: timestamp, marked: nil, knownIndoors: knownIndoors,
                                      outings: outings, moving: moving)
    }

    /// A reading corrected for the air it was taken in — see `Temperature`.
    /// Nil for doses, for readings taken indoors, and for readings whose
    /// temperature is not yet known.
    func adjustedAmount(outings: [Temperature.Outing], marks: [Temperature.Mark]) -> Double? {
        guard kind == .glucose, let temperature, isOutdoors(outings: outings, marks: marks) else { return nil }
        return Temperature.adjustedGlucose(amount, celsius: temperature)
    }

    /// Falls back to a reading rather than a dose: a row of a kind this build
    /// does not know must never be mistaken for insulin and fed to the IOB
    /// maths. `purgeRetiredKinds` removes such rows at launch anyway.
    var kind: EntryKind {
        EntryKind(rawValue: kindRaw) ?? .glucose
    }

    /// Human-readable amount, e.g. "5.6 mmol/L", "2.5 U", "24 U".
    func displayAmount(in unit: GlucoseUnit) -> String {
        switch kind {
        case .glucose:
            return "\(unit.format(amount)) \(unit.label)"
        case .insulin:
            // Show one decimal place, dropping a trailing ".0" (e.g. "3 U", "2.5 U").
            let s = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
            return "\(s) U"
        case .basal:
            return "\(Int(amount)) U"
        }
    }

    /// Delete rows whose kind this build no longer has — the carbohydrate and
    /// meal-size entries of earlier versions. Run once at launch on each
    /// device. Fetched whole and narrowed in Swift rather than through a
    /// predicate, so a predicate failing at runtime cannot quietly delete the
    /// wrong rows.
    @MainActor
    static func purgeRetiredKinds(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
        let retired = all.filter { EntryKind(rawValue: $0.kindRaw) == nil }
        guard !retired.isEmpty else { return }
        for row in retired { context.delete(row) }
        try? context.save()
    }
}
