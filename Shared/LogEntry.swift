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

    init(id: UUID = UUID(), timestamp: Date, kind: EntryKind, amount: Double) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.amount = amount
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
