import Foundation
import WatchConnectivity
import SwiftData

/// Moves logged entries from the Watch to the iPhone over WatchConnectivity.
///
/// This is device-to-device (Bluetooth/Wi-Fi), NOT cloud. `transferUserInfo`
/// queues reliably in the background and is delivered even if the phone is not
/// reachable at the moment of logging.
final class ConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = ConnectivityManager()

    #if os(iOS)
    /// Set by the iOS app at launch so received entries can be inserted into
    /// the same store the history view reads from.
    var modelContainer: ModelContainer?
    #endif

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(watchOS)
    /// Send a saved entry to the paired iPhone.
    func send(_ entry: LogEntry) {
        guard WCSession.isSupported() else { return }
        let info: [String: Any] = [
            "id": entry.id.uuidString,
            "timestamp": entry.timestamp.timeIntervalSince1970,
            "kind": entry.kind.rawValue,
            "amount": entry.amount,
        ]
        WCSession.default.transferUserInfo(info)
    }
    #endif

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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            guard let container = modelContainer else { return }
            guard
                let idString = userInfo["id"] as? String,
                let id = UUID(uuidString: idString),
                let ts = userInfo["timestamp"] as? TimeInterval,
                let kindRaw = userInfo["kind"] as? String,
                let kind = EntryKind(rawValue: kindRaw),
                let amount = userInfo["amount"] as? Double
            else { return }

            let context = container.mainContext

            // De-duplicate: skip if we already have this id.
            let descriptor = FetchDescriptor<LogEntry>(predicate: #Predicate { $0.id == id })
            if let existing = try? context.fetch(descriptor), !existing.isEmpty {
                return
            }

            let entry = LogEntry(id: id,
                                 timestamp: Date(timeIntervalSince1970: ts),
                                 kind: kind,
                                 amount: amount)
            context.insert(entry)
            try? context.save()
        }
    }
    #endif
}
