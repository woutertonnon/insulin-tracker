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
///   still relevant to the complication, plus the basal reminder time. This is
///   what the complication actually depends on, and it is self-healing: the
///   context always holds the current state, so a single delivery repairs any
///   amount of earlier drift. Nothing has to arrive in order, and nothing is
///   lost if a transfer is dropped.
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
        static let settings = "settings"
    }

    /// Key for the whole-list snapshot, as a flat `[timestamp, units, …]`.
    private static let snapshotKey = "boluses"

    /// Key for the basal reminder, as minutes after local midnight, or
    /// `BasalSchedule.reminderOff`. Travels phone → watch only.
    private static let basalReminderKey = "basalReminder"

    /// Key for the glucose unit the watch dials readings in, as the raw
    /// `GlucoseUnit` string. Health decides it on the phone; phone → watch only.
    private static let glucoseUnitKey = GlucoseUnit.settingsKey

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

    /// Push the basal reminder time to the watch, where the complication reads
    /// it out of the App Group.
    ///
    /// Sent on the same channel as a dose, which can wake the watch app in the
    /// background to take delivery. That matters: the setting does nothing
    /// until it crosses, and a reminder that waits for the next time the watch
    /// app happens to be opened is not a reminder.
    ///
    /// **Callers must debounce.** That channel is budgeted per day, and a time
    /// picker emits a change per tick of the wheel.
    @MainActor
    func sendBasalReminder(_ reminder: BasalSchedule.Reminder?) {
        transfer([
            Op.key: Op.settings,
            Self.basalReminderKey: reminder?.minuteOfDay ?? BasalSchedule.reminderOff,
        ])
        // And into the context, so the current setting is also sitting there
        // for a watch that misses the transfer entirely.
        pushSnapshot()
    }

    /// Push the glucose unit to the watch, so a reading dialled there is in
    /// the unit Health is in here. Same channel and same reasoning as the
    /// reminder; it changes about as often as a meter does, so no debounce.
    @MainActor
    func sendGlucoseUnit(_ unit: GlucoseUnit) {
        transfer([
            Op.key: Op.settings,
            Self.glucoseUnitKey: unit.rawValue,
        ])
        pushSnapshot()
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

    /// Publish the complete bolus list, and the basal reminder, as application
    /// context too.
    ///
    /// This is a *secondary* channel. It is delivered whenever the counterpart
    /// next runs, which makes it a good backstop, but it does not reliably wake
    /// a sleeping watch app — so it cannot be the only way the complication
    /// hears about a change. The snapshot rides along with the transfers above
    /// for that.
    @MainActor
    func pushSnapshot() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        var context: [String: Any] = [Self.snapshotKey: currentBolusSnapshot()]
        #if os(iOS)
        // The phone owns the reminder, so only the phone publishes it. Always
        // present, as a minute or as the "off" sentinel: an absent key means
        // the sender said nothing about the reminder, which must not read as
        // "turn it off".
        context[Self.basalReminderKey] =
            BasalSchedule.Defaults.current()?.minuteOfDay ?? BasalSchedule.reminderOff
        context[Self.glucoseUnitKey] = GlucoseUnit.current().rawValue
        #endif

        // Throws only if the session is not activated, which is guarded above.
        try? session.updateApplicationContext(context)
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
            pushSnapshot()
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
        // The reminder, unlike the doses, *is* data: the phone owns it and this
        // is a copy of it, so it is written straight through.
        applySettings(context)

        guard context[Self.snapshotKey] != nil else {
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard let container = modelContainer else { return }
        refreshComplication(using: container.mainContext)
        #endif
    }

    @MainActor
    private func apply(_ userInfo: [String: Any]) {
        // Messages sent before `op` existed were always upserts.
        let op = userInfo[Op.key] as? String ?? Op.upsert

        // Settings carry no entry, so they are handled before anything asks for
        // an id or a model container.
        if op == Op.settings {
            #if os(watchOS)
            applySettings(userInfo)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            return
        }

        guard
            let container = modelContainer,
            let idString = userInfo["id"] as? String,
            let id = UUID(uuidString: idString)
        else { return }

        let context = container.mainContext
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
    /// Store the phone's settings where the watch app and the widget process
    /// can read them: the basal reminder, and the glucose unit.
    ///
    /// One-way by design: the phone owns both, and nothing on iOS needs this —
    /// the phone has no App Group of its own, and it is the source of the
    /// values anyway. Each key is applied on its own, so a message carrying
    /// one setting says nothing about the other.
    @MainActor
    private func applySettings(_ payload: [String: Any]) {
        if let minute = payload[Self.basalReminderKey] as? Int {
            // `reminderOff` fails `Reminder`'s validating initialiser, which is
            // how "off" arrives as nil rather than as a reminder at some odd hour.
            SharedStore.setBasalReminder(BasalSchedule.Reminder(minuteOfDay: minute))
        }
        if let raw = payload[Self.glucoseUnitKey] as? String,
           let unit = GlucoseUnit(rawValue: raw) {
            SharedStore.setGlucoseUnit(unit)
        }
    }

    /// Republish what the complication reads out of the App Group, then rebuild
    /// it: the bolus history for IOB, and the newest basal, which is what
    /// clears the basal reminder.
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
        // `max()` over the whole log rather than the newest row, so deleting
        // today's basal on the phone puts the reminder back rather than leaving
        // it cleared by a dose that no longer exists.
        SharedStore.setLastBasal(
            all.filter { $0.kind == .basal }.map(\.timestamp).max()
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
    #endif
}
