import Foundation
import HealthKit

/// Read-only access to the two Health data types that matter alongside insulin:
/// **workouts**, because exercise changes how insulin behaves, and **glucose**,
/// which the Dexcom G7 app writes into Health.
///
/// Nothing here is written back to Health, and nothing is copied into SwiftData.
/// Health stays the source of truth for both, which avoids having to
/// de-duplicate against samples the Dexcom or Fitness apps may revise later.
///
/// > Dexcom writes to Health in batches rather than continuously, so the newest
/// > reading here can lag the sensor. Treat it as context, not as something to
/// > dose from.
@MainActor
final class HealthStore: ObservableObject {

    struct Workout: Identifiable, Hashable {
        let id: UUID
        let start: Date
        let end: Date
        let name: String
        /// Active energy Health attributes to this workout, in kcal. Nil when
        /// the workout was recorded without it — a manually added entry, say.
        let kilocalories: Double?

        var duration: TimeInterval { end.timeIntervalSince(start) }

        /// "32 min", "1 h 05 min"
        var durationText: String {
            let minutes = Int((duration / 60).rounded())
            if minutes < 60 { return "\(minutes) min" }
            return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
        }
    }

    struct GlucoseSample: Identifiable, Hashable {
        let id: UUID
        let date: Date
        /// In whatever unit Health is set to — see `glucoseUnitLabel`.
        let value: Double
    }

    struct DailyEnergy: Identifiable, Hashable {
        let day: Date
        let kilocalories: Double
        var id: Date { day }
    }

    struct WeightSample: Identifiable, Hashable {
        let id: UUID
        let date: Date
        /// In whatever unit Health is set to — see `weightUnitLabel`.
        let value: Double
    }

    @Published private(set) var workouts: [Workout] = []
    @Published private(set) var glucose: [GlucoseSample] = []
    /// Active energy per calendar day, summed by Health rather than by us.
    @Published private(set) var dailyEnergy: [DailyEnergy] = []
    @Published private(set) var weights: [WeightSample] = []
    /// Follows the unit chosen in Health, so mmol/L and mg/dL both read right
    /// without a setting of our own.
    @Published private(set) var glucoseUnitLabel = "mmol/L"
    /// Follows the unit chosen in Health, so kilograms and pounds both read
    /// right without a setting of our own.
    @Published private(set) var weightUnitLabel = "kg"
    @Published private(set) var didRequestAccess = false

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private var glucoseUnit = HKUnit(from: "mmol/L")
    private var weightUnit = HKUnit.gramUnit(with: .kilo)

    private var glucoseType: HKQuantityType { HKQuantityType(.bloodGlucose) }
    private var energyType: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private var weightType: HKQuantityType { HKQuantityType(.bodyMass) }

    /// Ask once for read access to workouts and glucose.
    ///
    /// Health deliberately does not report whether *read* permission was
    /// granted — a denied type simply returns no samples, which is
    /// indistinguishable from having no data. So there is no "authorized"
    /// state to show; empty results are handled the same way either way.
    func requestAccess() async {
        guard Self.isAvailable else { return }
        let read: Set<HKObjectType> = [HKObjectType.workoutType(),
                                       glucoseType,
                                       energyType,
                                       weightType]
        do {
            try await store.requestAuthorization(toShare: [], read: read)
            didRequestAccess = true
            await refreshUnit()
        } catch {
            didRequestAccess = true
        }
    }

    private func refreshUnit() async {
        // Split rather than subscripting the awaited call directly: `try?` would
        // wrap the whole expression, leaving a doubly-optional result.
        let units = try? await store.preferredUnits(for: [glucoseType, weightType])
        if let unit = units?[glucoseType] {
            glucoseUnit = unit
            glucoseUnitLabel = unit.unitString
        }
        if let unit = units?[weightType] {
            weightUnit = unit
            weightUnitLabel = unit.unitString
        }
    }

    /// Least time between Health queries.
    ///
    /// The view ticks every minute to slide the insulin curve, but Health is
    /// not worth re-querying that often: Dexcom uploads in batches and workouts
    /// land when they end, so a minute-by-minute query would mostly return the
    /// same samples.
    private static let minimumRefreshInterval: TimeInterval = 5 * 60
    private var lastRefresh: Date?

    /// Pull all four series over one window. Failures leave the previous values
    /// in place rather than blanking the UI.
    ///
    /// One window rather than one per series: the trends view plots all four
    /// day by day against each other, so a shorter span on any of them would
    /// leave a chart that stops early and reads as an absence of data rather
    /// than an absence of query. Consumers that want less filter at the point
    /// of use.
    ///
    /// - Parameter force: bypass the interval — used on first appearance, where
    ///   waiting five minutes for anything to show would be absurd.
    func refresh(since: Date, force: Bool = false) async {
        guard Self.isAvailable else { return }
        if !force,
           let last = lastRefresh,
           Date.now.timeIntervalSince(last) < Self.minimumRefreshInterval {
            return
        }
        lastRefresh = .now
        async let w = fetchWorkouts(since: since)
        async let g = fetchGlucose(since: since)
        async let e = fetchDailyEnergy(since: since)
        async let m = fetchWeights(since: since)
        let (fetchedWorkouts, fetchedGlucose, fetchedEnergy, fetchedWeights) = await (w, g, e, m)
        if let fetchedWorkouts { workouts = fetchedWorkouts }
        if let fetchedGlucose { glucose = fetchedGlucose }
        if let fetchedEnergy { dailyEnergy = fetchedEnergy }
        if let fetchedWeights { weights = fetchedWeights }
    }

    private func fetchWorkouts(since: Date) async -> [Workout]? {
        let predicate = HKSamplePredicate.workout(
            HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            // Three months of daily training, with headroom. The newest are
            // kept, so a very heavy log loses its oldest days rather than its
            // most recent ones.
            limit: 500
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        return samples.map {
            Workout(id: $0.uuid,
                    start: $0.startDate,
                    end: $0.endDate,
                    name: Self.name(for: $0.workoutActivityType),
                    kilocalories: $0.statistics(for: HKQuantityType(.activeEnergyBurned))?
                        .sumQuantity()?
                        .doubleValue(for: .kilocalorie()))
        }
    }

    private func fetchGlucose(since: Date) async -> [GlucoseSample]? {
        let predicate = HKSamplePredicate.quantitySample(
            type: glucoseType,
            predicate: HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            // Ninety days of CGM at five-minute intervals is ~26,000 samples;
            // leave headroom rather than silently truncating the oldest days,
            // which are exactly the ones the long windows are made of.
            limit: 40000
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let unit = glucoseUnit
        return samples.map {
            GlucoseSample(id: $0.uuid,
                          date: $0.startDate,
                          value: $0.quantity.doubleValue(for: unit))
        }
    }

    /// Active energy per calendar day.
    ///
    /// Summed by Health with a statistics collection rather than by pulling
    /// every sample and adding them up here: the watch writes active energy in
    /// small, frequent increments, so three months of raw samples runs to tens
    /// of thousands of rows to produce ninety numbers.
    private func fetchDailyEnergy(since: Date) async -> [DailyEnergy]? {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: since)
        let predicate = HKSamplePredicate.quantitySample(
            type: energyType,
            predicate: HKQuery.predicateForSamples(withStart: anchor, end: nil, options: .strictStartDate)
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate,
            options: .cumulativeSum,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )
        guard let collection = try? await descriptor.result(for: store) else { return nil }
        return collection.statistics().compactMap { statistic in
            guard let sum = statistic.sumQuantity() else { return nil }
            return DailyEnergy(day: calendar.startOfDay(for: statistic.startDate),
                               kilocalories: sum.doubleValue(for: .kilocalorie()))
        }
    }

    /// Every weight reading in the window. Not one per day — people weigh
    /// themselves when they remember to, and the gaps are the honest picture.
    private func fetchWeights(since: Date) async -> [WeightSample]? {
        let predicate = HKSamplePredicate.quantitySample(
            type: weightType,
            predicate: HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 2000
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let unit = weightUnit
        return samples.map {
            WeightSample(id: $0.uuid,
                         date: $0.startDate,
                         value: $0.quantity.doubleValue(for: unit))
        }
    }

    /// Most recent reading, if any.
    var latestGlucose: GlucoseSample? { glucose.last }

    /// Formatted for the unit in use: mmol/L wants a decimal, mg/dL does not.
    func format(_ sample: GlucoseSample) -> String {
        glucoseUnitLabel.contains("mol")
            ? String(format: "%.1f", sample.value)
            : String(Int(sample.value.rounded()))
    }

    // MARK: - Activity names

    /// HealthKit has no display names for activity types, so the common ones
    /// are spelled out and anything else falls back to "Workout".
    private static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .swimming: return "Swim"
        case .hiking: return "Hike"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .rowing: return "Row"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "Stairs"
        case .dance: return "Dance"
        case .soccer: return "Football"
        case .tennis: return "Tennis"
        case .basketball: return "Basketball"
        case .climbing: return "Climbing"
        case .crossTraining: return "Cross-training"
        case .coreTraining: return "Core"
        case .flexibility: return "Stretching"
        case .skatingSports: return "Skating"
        case .snowSports, .downhillSkiing: return "Snow sports"
        case .paddleSports: return "Paddling"
        case .surfingSports: return "Surfing"
        case .golf: return "Golf"
        case .martialArts, .boxing: return "Martial arts"
        default: return "Workout"
        }
    }
}
