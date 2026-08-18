import SwiftUI
import Charts
import UIKit

/// Recent glucose from Health, written there by the Dexcom G7 app.
///
/// Deliberately its own chart rather than another series on the insulin one:
/// glucose and units-of-insulin share no scale, and putting them on one plot
/// would mean two y-axes, which makes both harder to read rather than easier.
struct GlucoseCard: View {
    @ObservedObject var health: HealthStore
    let latest: HealthStore.GlucoseSample
    let now: Date

    /// Same window the insulin chart covers, so the two line up visually.
    private var start: Date { now.addingTimeInterval(-2 * InsulinMath.duration) }

    private var samples: [HealthStore.GlucoseSample] {
        health.glucose.filter { $0.date >= start }
    }

    /// Dexcom writes to Health in batches, so "latest" can be well behind the
    /// sensor. Saying how old it is matters more here than for the other
    /// readouts, which are computed from data this app owns.
    private var isStale: Bool {
        now.timeIntervalSince(latest.date) > 15 * 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if samples.count > 1 {
                Chart(samples) { s in
                    LineMark(
                        x: .value("Time", s.date),
                        y: .value("Glucose", s.value)
                    )
                    .foregroundStyle(Self.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { _ in
                        AxisGridLine().foregroundStyle(Self.grid)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Self.grid)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Self.axisLabel(v, unit: health.glucoseUnitLabel))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 130)
            }

            Text("From Apple Health · written by the Dexcom app, which uploads in batches, so this can lag the sensor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(health.format(latest))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Self.series)
            Text(health.glucoseUnitLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(latest.date, style: .relative)
                .font(.caption2)
                .foregroundStyle(isStale ? .orange : .secondary)
                .lineLimit(1)
        }
    }

    private static func axisLabel(_ value: Double, unit: String) -> String {
        unit.contains("mol") ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    // MARK: - Palette

    /// Categorical slot 5 (magenta) — distinct from the insulin blue and the
    /// exercise aqua already on screen.
    private static let series = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xd5 / 255, green: 0x51 / 255, blue: 0x81 / 255, alpha: 1)
            : UIColor(red: 0xe8 / 255, green: 0x7b / 255, blue: 0xa4 / 255, alpha: 1)
    })

    private static let grid = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2a / 255, alpha: 1)
            : UIColor(red: 0xe1 / 255, green: 0xe0 / 255, blue: 0xd9 / 255, alpha: 1)
    })
}
