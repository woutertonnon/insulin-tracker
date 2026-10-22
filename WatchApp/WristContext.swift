import Foundation
import CoreMotion

/// What the wrist's own sensors can say about a reading: whether its owner
/// was out moving, and how high up they were. Both offline, both from the
/// motion coprocessor and the barometer rather than from anything that needs
/// a network.
///
/// * **Moving outdoors.** The coprocessor classifies activity continuously.
///   Cycling or running in the quarter hour before a reading means it was
///   taken outside, whether or not a workout was recorded — the badge's
///   starting position. Walking and standing still say nothing either way.
/// * **Altitude.** The barometer gives absolute altitude to a few metres in
///   a second or two, where GPS height is worse and slower. It is what the
///   weather lookup downscales to, which matters on a mountain.
@MainActor
final class WristContext: ObservableObject {

    /// Barometric altitude in metres, once the altimeter has settled. Nil on
    /// a watch without one, or before it has reported.
    @Published private(set) var altitude: Double?

    private let altimeter = CMAltimeter()
    private let activity = CMMotionActivityManager()
    private var altimeterRunning = false

    /// How far back to look for a ride or a run.
    static let recentMovement: TimeInterval = 15 * 60

    /// Start the altimeter. Called when the crown enters the reading region;
    /// it is cheap, and a reading saves three seconds later.
    func begin() {
        guard !altimeterRunning, CMAltimeter.isAbsoluteAltitudeAvailable() else { return }
        altimeterRunning = true
        altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            Task { @MainActor in
                self.altitude = data.altitude
            }
        }
    }

    /// Stop it again once the crown is back at neutral. The last altitude is
    /// kept for the reading that may still be saving.
    func end() {
        guard altimeterRunning else { return }
        altimeterRunning = false
        altimeter.stopAbsoluteAltitudeUpdates()
    }

    /// Whether the coprocessor saw cycling or running in the last quarter
    /// hour. Asks permission the first time; false when it is refused or the
    /// watch cannot say.
    func wasMovingOutdoors() async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let now = Date.now
        let since = now.addingTimeInterval(-Self.recentMovement)
        return await withCheckedContinuation { continuation in
            activity.queryActivityStarting(from: since, to: now, to: .main) { activities, _ in
                let moving = (activities ?? []).contains { sample in
                    (sample.cycling || sample.running) && sample.confidence != .low
                }
                continuation.resume(returning: moving)
            }
        }
    }
}
