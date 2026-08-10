import Foundation
import SwiftData

/// The two things we track. `carbs` are grams, `insulin` are units.
enum EntryKind: String, Codable, Sendable, CaseIterable {
    case carbs
    case insulin
}

/// A single logged event, stored locally with SwiftData on each device.
@Model
final class LogEntry {
    /// Stable id so the phone can de-duplicate entries pushed from the watch.
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Stored as a String because SwiftData persists primitives most reliably.
    var kindRaw: String
    /// Grams for carbs, units for insulin.
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

    /// Human-readable amount, e.g. "30 g" or "2.5 U".
    var displayAmount: String {
        switch kind {
        case .carbs:
            return "\(Int(amount)) g"
        case .insulin:
            // Show one decimal place, dropping a trailing ".0" (e.g. "3 U", "2.5 U").
            let s = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
            return "\(s) U"
        }
    }
}
