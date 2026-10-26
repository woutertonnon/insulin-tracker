import Foundation
import CoreLocation

/// Location fixes, so a blood sugar reading can be stamped with where it was
/// taken and the outside temperature looked up for it later.
///
/// The watch records only the coordinate, the height and the time — it needs
/// no network to do that — and the phone, which has a connection when it has
/// one, asks Open-Meteo afterwards. So nothing here waits on anything: a fix in hand is
/// used, a fix that arrives in the next minutes is attached when it lands, and
/// a reading with no fix is simply a reading with no temperature.
///
/// A fix is asked for as soon as the crown enters the reading region, so one
/// is usually in hand by the time the reading saves three seconds later.
/// Indoors it is: Wi‑Fi answers in a second or two. Outside, away from known
/// networks, GPS can take a minute, and by then the wrist is down and the app
/// suspended. So a reading saved without a fix starts **background** location
/// updates, which keep running with the wrist down until a good fix lands or
/// `trackingLimit` runs out, whichever is first — never longer.
@MainActor
final class LocationStamper: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// The newest fix, whatever its age.
    @Published private(set) var latest: CLLocation?

    private let manager = CLLocationManager()
    private var isRequesting = false
    private var waiting: [(CLLocation) -> Void] = []

    /// Whether background updates are running for a reading waiting on a fix.
    private var isTracking = false
    private var trackingDeadline: Task<Void, Never>?

    /// A fix younger than this is reused rather than asked for again. Weather
    /// does not change across the distance a wrist travels in ten minutes.
    private let freshness: TimeInterval = 10 * 60

    /// A fix older than this is not worth attaching even as a fallback.
    private let staleness: TimeInterval = 2 * 3600

    /// The longest background updates run for one reading. GPS from cold
    /// takes well under this outside; past it, the sky is not on offer and
    /// the battery is better kept.
    private let trackingLimit: Duration = .seconds(120)

    /// What counts as a good enough fix to stop on: the places rule wants a
    /// hundred metres, and the first answers from GPS are often coarser.
    private let goodAccuracy: CLLocationAccuracy = 100

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

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Ask for a fix if there is no fresh one. Safe to call on every tick of
    /// the crown: it does nothing while a request is already out.
    func requestFix() {
        guard fresh == nil, !isRequesting, !isTracking else { return }
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

    /// Hand a fix to `handler`: the fresh one now, or the next good one to
    /// arrive — with the wrist down, too — or, once tracking gives up, the
    /// newest there is, provided it is not stale. `handler` may run at most
    /// once, and not at all if nothing is known.
    ///
    /// Call it while the app is in front: watchOS lets background updates
    /// continue only if they were started there.
    func whenFixed(_ handler: @escaping (CLLocation) -> Void) {
        if let fresh {
            handler(fresh)
            return
        }
        waiting.append(handler)
        startTracking()
    }

    // MARK: - Background updates

    private func startTracking() {
        guard isAuthorized else {
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            return
        }
        // Restart the clock for each reading that joins the wait.
        trackingDeadline?.cancel()
        trackingDeadline = Task {
            try? await Task.sleep(for: trackingLimit)
            if Task.isCancelled { return }
            giveUp()
        }
        guard !isTracking else { return }
        isTracking = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    private func stopTracking() {
        trackingDeadline?.cancel()
        trackingDeadline = nil
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// Out of time: settle for the newest fix there is, coarse or old, so
    /// long as it is not stale.
    private func giveUp() {
        stopTracking()
        let handlers = waiting
        waiting.removeAll()
        guard let latest, Date.now.timeIntervalSince(latest.timestamp) < staleness else { return }
        for handler in handlers { handler(latest) }
    }

    private func deliver(_ fix: CLLocation) {
        stopTracking()
        let handlers = waiting
        waiting.removeAll()
        for handler in handlers { handler(fix) }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in
            isRequesting = false
            latest = fix
            guard !waiting.isEmpty else { return }
            // While tracking, wait for a fix that is both new and good: the
            // first updates are often a cached position or a coarse cell
            // estimate. The one-shot request answers once, so take it.
            if isTracking {
                let isGood = fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= goodAccuracy
                let isNew = Date.now.timeIntervalSince(fix.timestamp) < 60
                guard isGood, isNew else { return }
            }
            deliver(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isRequesting = false
            // A transient failure — no fix yet, GPS still warming up — is
            // retried by the running updates themselves. Only a refusal ends
            // them.
            if (error as? CLError)?.code == .denied { giveUp() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // Permission granted mid-dial: a reading waiting on a fix can
            // have one now.
            if !waiting.isEmpty { startTracking() }
        }
    }
}
