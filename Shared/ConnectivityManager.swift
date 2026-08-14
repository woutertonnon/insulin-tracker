import Foundation
import WatchConnectivity
import SwiftData
#if os(watchOS)
import WidgetKit
#endif

/// Keeps the Watch and iPhone stores in step over WatchConnectivity.
///
/// This is device-to-device (Bluetooth/Wi-Fi), NOT cloud.
///
/// Two channels, deliberately:
///
/// * **Per-entry transfers** (`transferUserInfo`) carry individual adds, edits
///   and deletions so each device's own history stays complete. Queued and
///   delivered in order, but any one of them can be delayed.
/// * **A whole-list snapshot** (`updateApplicationContext`) carries every bolus
///   still relevant to the complication. This is what the complication actually
///   depends on, and it is self-healing: the context always holds the current
///   state, so a single delivery repairs any amount of earlier drift. Nothing
///   has to arrive in order, and nothing is lost if a transfer is dropped.
final class ConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = ConnectivityManager()

    /// Set by each app at launch so received entries land in the same store the
    /// UI reads from.
    var modelContainer: ModelContainer?

    /// Payloads raised before the session finished activating. Activation is
    /// asynchronous, so an edit made moments after launch would otherwise be
    /// dropped on the floor.
    private var pending: [[String: Any]] = []
    private let lock = NSLock()

    private enum Op {
        static let key = "op"
        static let upsert = "upsert"
        static let delete = "delete"
    }

    /// Key for the whole-list snapshot, as a flat `[timestamp, units, …]`.
    private static let snapshotKey = "boluses"

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Sending

    /// Push an added or edited entry to the counterpart device.
    @MainActor
    func send(_ entry: LogEntry) {
        transfer([
            Op.key: Op.upsert,
            "id": entry.id.uuidString,
            "timestamp": entry.timestamp.timeIntervalSince1970,
            "kind": entry.kind.rawValue,
            "amount": entry.amount,
            Self.snapshotKey: currentBolusSnapshot(),
        ])
    }

    /// Push a deletion. Sent by id because the row is already gone locally.
    @MainActor
    func sendDelete(id: UUID) {
        transfer([
            Op.key: Op.delete,
            "id": id.uuidString,
            Self.snapshotKey: currentBolusSnapshot(),
        ])
    }

    /// Every bolus, flattened. Rides along with each message so a single
    /// delivery carries complete state — the receiver never has to have seen
    /// any earlier message for the complication to end up correct.
    @MainActor
    private func currentBolusSnapshot() -> [Double] {
        guard let container = modelContainer else { return [] }
        let all = (try? container.mainContext.fetch(FetchDescriptor<LogEntry>())) ?? []
        return all
            .filter { $0.kind == .insulin }
            .sorted { $0.timestamp < $1.timestamp }
            .flatMap { [$0.timestamp.timeIntervalSince1970, $0.amount] }
    }

    /// Publish the complete bolus list as application context too.
    ///
    /// This is a *secondary* channel. It is delivered whenever the counterpart
    /// next runs, which makes it a good backstop, but it does not reliably wake
    /// a sleeping watch app — so it cannot be the only way the complication
    /// hears about a change. The snapshot rides along with the transfers above
    /// for that.
    @MainActor
    func pushBolusSnapshot() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // Throws only if the session is not activated, which is guarded above.
        try? session.updateApplicationContext([Self.snapshotKey: currentBolusSnapshot()])
    }

    private func transfer(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        guard session.activationState == .activated else {
            lock.lock()
            pending.append(payload)
            lock.unlock()
            session.activate()
            return
        }

        deliver(payload, on: session)
    }

    private func deliver(_ payload: [String: Any], on session: WCSession) {
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

    private func flushPending(on session: WCSession) {
        lock.lock()
        let queued = pending
        pending.removeAll()
        lock.unlock()
        for payload in queued {
            deliver(payload, on: session)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        flushPending(on: session)
        Task { @MainActor in
            // Republish the snapshot now that we can, so a counterpart that
            // missed earlier edits is brought up to date on connect.
            pushBolusSnapshot()
        }
    }

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

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in
            applySnapshot(context)
        }
    }

    // MARK: - Receiving

    /// A snapshot arriving from the counterpart is treated as a *nudge*, not as
    /// data.
    ///
    /// Writing it straight through would be actively wrong: this watch's store
    /// is the union of both devices, so the phone's list can be missing a dose
    /// just logged here that has not reached it yet. Overwriting with it would
    /// delete that dose from the complication. Rebuild from the local store
    /// instead, which already has everything.
    @MainActor
    private func applySnapshot(_ context: [String: Any]) {
        #if os(watchOS)
        guard context[Self.snapshotKey] != nil else { return }
        guard let container = modelContainer else { return }
        refreshComplication(using: container.mainContext)
        #endif
    }

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
        // Fetched unfiltered and narrowed in Swift on purpose: a #Predicate that
        // fails at runtime would be swallowed by try? and silently blank the
        // complication instead of leaving it merely stale.
        let all = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
        let boluses = all
            .filter { $0.kind == .insulin }
            .sorted { $0.timestamp < $1.timestamp }
        SharedStore.setBolusDoses(
            boluses.map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
    #endif
}
