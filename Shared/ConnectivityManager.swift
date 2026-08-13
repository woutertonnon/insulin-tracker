import Foundation
import WatchConnectivity
import SwiftData
#if os(watchOS)
import WidgetKit
#endif

/// Keeps the Watch and iPhone stores in step over WatchConnectivity.
///
/// This is device-to-device (Bluetooth/Wi-Fi), NOT cloud. `transferUserInfo`
/// queues reliably in the background and is delivered even if the counterpart
/// is not reachable at the moment of the edit.
///
/// Sync runs **both ways**: the watch pushes what you log, and the phone pushes
/// edits and deletions back so the watch's store — and therefore the
/// complication, which reads its IOB from that store — stays correct.
final class ConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = ConnectivityManager()

    /// Set by each app at launch so received entries land in the same store the
    /// UI reads from.
    var modelContainer: ModelContainer?

    private enum Op {
        static let key = "op"
        static let upsert = "upsert"
        static let delete = "delete"
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Sending

    /// Push an added or edited entry to the counterpart device.
    func send(_ entry: LogEntry) {
        transfer([
            Op.key: Op.upsert,
            "id": entry.id.uuidString,
            "timestamp": entry.timestamp.timeIntervalSince1970,
            "kind": entry.kind.rawValue,
            "amount": entry.amount,
        ])
    }

    /// Push a deletion. Sent by id because the row is already gone locally.
    func sendDelete(id: UUID) {
        transfer([
            Op.key: Op.delete,
            "id": id.uuidString,
        ])
    }

    private func transfer(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        #if os(iOS)
        // The watch's complication is the thing that goes stale, so use the
        // complication-priority channel when the budget allows — it wakes the
        // watch app in the background to take delivery. Otherwise fall back to
        // the ordinary queue, which arrives the next time the watch app runs.
        if session.isComplicationEnabled,
           session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(payload)
            return
        }
        #endif

        session.transferUserInfo(payload)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate to keep receiving from the watch after a switch.
        WCSession.default.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            apply(userInfo)
        }
    }

    // MARK: - Receiving

    @MainActor
    private func apply(_ userInfo: [String: Any]) {
        guard
            let container = modelContainer,
            let idString = userInfo["id"] as? String,
            let id = UUID(uuidString: idString)
        else { return }

        let context = container.mainContext
        // Messages sent before `op` existed were always upserts.
        let op = userInfo[Op.key] as? String ?? Op.upsert
        let descriptor = FetchDescriptor<LogEntry>(predicate: #Predicate { $0.id == id })
        let existing = try? context.fetch(descriptor).first

        switch op {
        case Op.delete:
            guard let existing else { return }
            context.delete(existing)

        default:
            guard
                let ts = userInfo["timestamp"] as? TimeInterval,
                let kindRaw = userInfo["kind"] as? String,
                let kind = EntryKind(rawValue: kindRaw),
                let amount = userInfo["amount"] as? Double
            else { return }

            let date = Date(timeIntervalSince1970: ts)
            if let existing {
                existing.amount = amount
                existing.timestamp = date
                existing.kindRaw = kind.rawValue
            } else {
                context.insert(LogEntry(id: id, timestamp: date, kind: kind, amount: amount))
            }
        }

        try? context.save()

        #if os(watchOS)
        // The complication reads its doses from the App Group, not from
        // SwiftData, so it has to be rewritten before asking for a reload.
        refreshComplication(using: context)
        #endif
    }

    #if os(watchOS)
    /// Republish the bolus history the complication reads, then rebuild it.
    @MainActor
    private func refreshComplication(using context: ModelContext) {
        let insulin = EntryKind.insulin.rawValue
        let descriptor = FetchDescriptor<LogEntry>(
            predicate: #Predicate { $0.kindRaw == insulin },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let boluses = (try? context.fetch(descriptor)) ?? []
        SharedStore.setBolusDoses(
            boluses.map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
    #endif
}
