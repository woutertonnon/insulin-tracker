import SwiftUI
import Charts
import UIKit

/// "Insulin activity — next 4 hours": how many units of rapid-acting insulin
/// will be working at each moment from now on, projected with the biexponential
/// model used by OpenAPS / Loop.
///
/// Stacked boluses are summed, so overlapping doses show up as one combined
/// curve. Basal insulin is not part of this — it has a different action profile.
struct InsulinForecastChart: View {
    let doses: [InsulinMath.Dose]
    /// Recomputed by the caller's TimelineView so the curve slides with time.
    let now: Date

    private var points: [InsulinMath.ForecastPoint] {
        InsulinMath.forecast(doses, from: now)
    }

    private var nowUnits: Double {
        InsulinMath.exponentialActivity(doses, at: now)
    }

    /// Highest point of the forecast — labelled directly on the chart.
    private var peak: InsulinMath.ForecastPoint? {
        points.max { $0.units < $1.units }
    }

    /// When activity finally reaches zero.
    private var endsAt: Date? {
        InsulinMath.lastActiveUntil(doses, at: now)
    }

    private var yMax: Double {
        max((peak?.units ?? 0) * 1.25, 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Chart {
                ForEach(points) { p in
                    AreaMark(
                        x: .value("Time", p.date),
                        y: .value("Units active", p.units)
                    )
                    .foregroundStyle(areaGradient)
                    .interpolationMethod(.monotone)
                }

                ForEach(points) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value("Units active", p.units)
                    )
                    .foregroundStyle(Self.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }

                // Peak marker, with a surface ring so it reads over the line.
                if let peak, peak.units > 0.01 {
                    PointMark(
                        x: .value("Time", peak.date),
                        y: .value("Units active", peak.units)
                    )
                    .symbolSize(70)
                    .foregroundStyle(Self.series)
                    .annotation(position: annotationPosition(for: peak),
                                spacing: 6) {
                        Text("peak \(InsulinMath.format(peak.units)) U")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Self.grid)
                    AxisTick().foregroundStyle(Self.grid)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Self.grid)
                    AxisValueLabel {
                        if let u = value.as(Double.self) {
                            Text(InsulinMath.format(u))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 170)

            footer
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(InsulinMath.format(nowUnits))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.series)
                Text("U active now")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Rapid-acting insulin still working, all doses combined.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let endsAt {
            Text("Back to zero at \(endsAt.formatted(date: .omitted, time: .shortened)) · exponential model (OpenAPS / Loop)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Keep the peak label inside the plot when the peak sits near the top.
    private func annotationPosition(for peak: InsulinMath.ForecastPoint) -> AnnotationPosition {
        peak.units > yMax * 0.85 ? .bottom : .top
    }

    // MARK: - Palette
    //
    // Categorical slot 1, stepped per mode so it stays legible on both
    // surfaces rather than being an automatic flip of one hex.

    private static let series = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    private static let grid = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2a / 255, alpha: 1)
            : UIColor(red: 0xe1 / 255, green: 0xe0 / 255, blue: 0xd9 / 255, alpha: 1)
    })

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [Self.series.opacity(0.28), Self.series.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
