import Foundation
import CoreLocation

/// One-shot location fixes, so a blood sugar reading can be stamped with
/// where it was taken and the outside temperature looked up for it later.
///
/// The watch records only the coordinate, the height and the time — it needs
/// no network to do that — and the phone, which has a connection when it has
/// one, asks Open-Meteo afterwards. So nothing here waits on anything: a fix in hand is
/// used, a fix that arrives in the next minute is attached when it lands, and
/// a reading with no fix is simply a reading with no temperature.
///
/// A fix is asked for as soon as the crown enters the reading region, so one
/// is usually in hand by the time the reading saves three seconds later.
@MainActor
final class LocationStamper: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// The newest fix, whatever its age.
    @Published private(set) var latest: CLLocation?

    private let manager = CLLocationManager()
    private var isRequesting = false
    private var waiting: [(CLLocation) -> Void] = []

    /// A fix younger than this is reused rather than asked for again. Weather
    /// does not change across the distance a wrist travels in ten minutes.
    private let freshness: TimeInterval = 10 * 60

    /// A fix older than this is not worth attaching even as a fallback.
    private let staleness: TimeInterval = 2 * 3600

    /// How long a reading waits for a fix before settling for an older one.
    private let patience: Duration = .seconds(45)

    override init() {
        super.init()
        manager.delegate = self
        // A hundred metres: enough to tell the kitchen from the café down
        // the road, which the places rule needs, and still a fix the watch
        // gets from Wi‑Fi in a second or two rather than waiting on GPS.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// The fix in hand, if it is fresh.
    var fresh: CLLocation? {
        guard let latest, Date.now.timeIntervalSince(latest.timestamp) < freshness else { return nil }
        return latest
    }

    /// Ask for a fix if there is no fresh one. Safe to call on every tick of
    /// the crown: it does nothing while a request is already out.
    func requestFix() {
        guard fresh == nil, !isRequesting else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isRequesting = true
            manager.requestLocation()
        default:
            break
        }
    }

    /// Hand a fix to `handler`: the fresh one now, or the next to arrive, or
    /// — after `patience` — the newest there is, provided it is not stale.
    /// `handler` may run at most once, and not at all if nothing is known.
    func whenFixed(_ handler: @escaping (CLLocation) -> Void) {
        if let fresh {
            handler(fresh)
            return
        }

        var delivered = false
        let once: (CLLocation) -> Void = { fix in
            guard !delivered else { return }
            delivered = true
            handler(fix)
        }
        waiting.append(once)
        requestFix()

        Task {
            try? await Task.sleep(for: patience)
            guard !delivered, let latest, Date.now.timeIntervalSince(latest.timestamp) < staleness else { return }
            once(latest)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in
            isRequesting = false
            latest = fix
            let handlers = waiting
            waiting.removeAll()
            for handler in handlers { handler(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isRequesting = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Permission granted mid-dial: the fix asked for before it was
            // answered can go out now.
            if !waiting.isEmpty { requestFix() }
        }
    }
}
