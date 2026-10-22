import Foundation

/// The unit blood glucose is shown and dialled in. Health decides it on the
/// phone; the watch is told.
///
/// Finger-prick readings are **stored in mmol/L** whatever the unit in use,
/// so a reading survives Health being switched from one unit to the other —
/// and so the two devices, which may hear about a change at different times,
/// never disagree about what a stored number means.
enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case millimolesPerLitre = "mmol/L"
    case milligramsPerDecilitre = "mg/dL"

    /// HealthKit's own molar mass for blood glucose, 180.15588 g/mol, so a
    /// value converted here lands on the number Health would show.
    static let milligramsPerMillimole = 18.015588

    /// Decided the way the rest of the app decides it: mmol/L is the one
    /// whose name contains "mol".
    init(label: String) {
        self = label.contains("mol") ? .millimolesPerLitre : .milligramsPerDecilitre
    }

    var label: String { rawValue }

    /// Display precision — a meter reads 5.6 in one unit and 101 in the other.
    var step: Double {
        switch self {
        case .millimolesPerLitre: return 0.1
        case .milligramsPerDecilitre: return 1
        }
    }

    /// A stored (mmol/L) value in this unit.
    func display(_ stored: Double) -> Double {
        switch self {
        case .millimolesPerLitre: return stored
        case .milligramsPerDecilitre: return stored * Self.milligramsPerMillimole
        }
    }

    /// A value in this unit as it is stored.
    func stored(_ value: Double) -> Double {
        switch self {
        case .millimolesPerLitre: return value
        case .milligramsPerDecilitre: return value / Self.milligramsPerMillimole
        }
    }

    /// "5.6", "101" — a stored value, shown in this unit.
    func format(_ stored: Double) -> String {
        formatValue(display(stored))
    }

    /// A value already in this unit.
    func formatValue(_ value: Double) -> String {
        switch self {
        case .millimolesPerLitre: return String(format: "%.1f", value)
        case .milligramsPerDecilitre: return String(Int(value.rounded()))
        }
    }

    // MARK: - The watch dial

    /// Every value the crown can land on, in this unit, lowest first.
    ///
    /// At a meter's own precision across the whole range — a tenth of a
    /// mmol/L from 2.0 to 30.0, a whole mg/dL from 40 to 500 — so what is
    /// logged is exactly what the meter said. The travel is long, but a
    /// reading dialled to the nearest half would be a different number from
    /// the one on the meter. Built from integers so no value carries a
    /// floating-point tail into the store.
    var dialLadder: [Double] {
        switch self {
        case .millimolesPerLitre:
            return (20...300).map { Double($0) / 10 }
        case .milligramsPerDecilitre:
            return (40...500).map(Double.init)
        }
    }

    // MARK: - Where the setting lives

    /// On the phone, in its own defaults, written whenever Health says which
    /// unit it is in; on the watch, in the App Group (`SharedStore`), put
    /// there over WatchConnectivity. The raw string travels.
    static let settingsKey = "glucoseUnit"

    static func current(_ defaults: UserDefaults = .standard) -> GlucoseUnit {
        defaults.string(forKey: settingsKey).flatMap(GlucoseUnit.init(rawValue:)) ?? .millimolesPerLitre
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.settingsKey)
    }
}
