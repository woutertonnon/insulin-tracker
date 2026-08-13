import Foundation
import SwiftData

/// The things we track.
///
/// * `carbs`   — grams, when you know the number
/// * `meal`    — a meal *size* when you don't (see `MealSize`); no gram amount
/// * `insulin` — rapid-acting bolus units; the only kind that feeds IOB
/// * `basal`   — long-acting background insulin units; excluded from IOB
enum EntryKind: String, Codable, Sendable, CaseIterable {
    case carbs
    case meal
    case insulin
    case basal
}

/// Qualitative meal sizes, for when the carb count isn't known. Stored in
/// `LogEntry.amount` as the raw ordinal — deliberately *not* a gram estimate,
/// so nothing invented ever ends up in the history.
enum MealSize: Int, Codable, Sendable, CaseIterable, Identifiable {
    case snack = 1
    case small = 2
    case medium = 3
    case large = 4
    case veryLarge = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .snack: return "Snack"
        case .small: return "Small meal"
        case .medium: return "Medium meal"
        case .large: return "Large meal"
        case .veryLarge: return "Very large meal"
        }
    }

    /// Short form for the cramped watch dial.
    var shortLabel: String {
        switch self {
        case .snack: return "Snack"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .veryLarge: return "Very large"
        }
    }
}

/// A single logged event, stored locally with SwiftData on each device.
@Model
final class LogEntry {
    /// Stable id so the phone can de-duplicate entries pushed from the watch.
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Stored as a String because SwiftData persists primitives most reliably.
    var kindRaw: String
    /// Grams for `carbs`, units for `insulin`/`basal`, and the `MealSize`
    /// ordinal for `meal`.
    var amount: Double

    init(id: UUID = UUID(), timestamp: Date, kind: EntryKind, amount: Double) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.amount = amount
    }

    var kind: EntryKind {
        EntryKind(rawValue: kindRaw) ?? .carbs
    }

    /// The meal size, for `.meal` entries only.
    var mealSize: MealSize? {
        guard kind == .meal else { return nil }
        return MealSize(rawValue: Int(amount))
    }

    /// Human-readable amount, e.g. "30 g", "2.5 U", "Medium meal".
    var displayAmount: String {
        switch kind {
        case .carbs:
            return "\(Int(amount)) g"
        case .meal:
            return mealSize?.label ?? "Meal"
        case .insulin:
            // Show one decimal place, dropping a trailing ".0" (e.g. "3 U", "2.5 U").
            let s = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
            return "\(s) U"
        case .basal:
            return "\(Int(amount)) U"
        }
    }
}
