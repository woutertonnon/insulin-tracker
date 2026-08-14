import SwiftUI
import Charts
import UIKit

/// Insulin activity over time: how many units of rapid-acting insulin are
/// working at each moment, projected with the biexponential model used by
/// OpenAPS / Loop.
///
/// Scrollable in both directions. The visible window is a fixed 4 hours wide
/// and a fixed 5 units tall, so the curve's shape means the same thing wherever
/// it is scrolled to; the plotted range extends four hours either side of now,
/// so the past of the curve can be scrolled back into. Vertically it can never
/// go below zero — that is the floor of the domain, not a clamp.
///
/// Stacked boluses are summed, so overlapping doses show up as one combined
/// curve. Basal insulin is not part of this — it has a different action profile.
struct InsulinForecastChart: View {
    let doses: [InsulinMath.Dose]
    /// Recomputed by the caller so the curve slides with time.
    let now: Date

    /// Fixed visible window, matching the complication's scales.
    private static let visibleHours: TimeInterval = 4 * 3600
    private static let visibleUnits: Double = 5

    /// How far either side of `now` the curve is drawn.
    private static let pastSpan: TimeInterval = 4 * 3600

    private var start: Date { now.addingTimeInterval(-Self.pastSpan) }
    private var end: Date { now.addingTimeInterval(InsulinMath.duration) }

    private var points: [InsulinMath.ForecastPoint] {
        InsulinMath.forecast(doses,
                             from: start,
                             span: Self.pastSpan + InsulinMath.duration,
                             step: 5 * 60)
    }

    /// Insulin still working right now — the headline figure.
    private var iobNow: Double {
        InsulinMath.insulinOnBoard(doses, at: now)
    }

    /// Highest point of the curve, labelled directly on the chart.
    private var peak: InsulinMath.ForecastPoint? {
        points.max { $0.units < $1.units }
    }

    /// When activity finally reaches zero.
    private var endsAt: Date? {
        InsulinMath.lastActiveUntil(doses, at: now)
    }

    /// Zero floor is deliberate — scrolling can never go below it. The top only
    /// exceeds the visible 5 U when the curve actually needs the room, so
    /// vertical scrolling appears exactly when there is something to scroll to.
    private var yDomainMax: Double {
        max(Self.visibleUnits, ((peak?.units ?? 0) * 1.2).rounded(.up))
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

                // Separates what has already happened from what is projected —
                // easy to lose track of once the chart is scrolled.
                RuleMark(x: .value("Now", now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Self.grid)

                if let peak, peak.units > 0.01 {
                    PointMark(
                        x: .value("Time", peak.date),
                        y: .value("Units active", peak.units)
                    )
                    .symbolSize(70)
                    .foregroundStyle(Self.series)
                    .annotation(position: .top, spacing: 6) {
                        Text("peak \(InsulinMath.format(peak.units)) U")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...yDomainMax)
            .chartScrollableAxes([.horizontal, .vertical])
            .chartXVisibleDomain(length: Self.visibleHours)
            .chartYVisibleDomain(length: Self.visibleUnits)
            .chartScrollPosition(initialX: now)
            .chartScrollPosition(initialY: 0)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Self.grid)
                    AxisTick().foregroundStyle(Self.grid)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: 1)) { value in
                    AxisGridLine().foregroundStyle(Self.grid)
                    AxisValueLabel {
                        if let u = value.as(Double.self) {
                            Text(InsulinMath.format(u))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 190)

            footer
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(InsulinMath.format(iobNow))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.series)
                Text("U on board")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Insulin still working, all doses combined. The curve below is how much is active at each moment.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let endsAt {
            Text("Back to zero at \(endsAt.formatted(date: .omitted, time: .shortened)) · exponential model (OpenAPS / Loop) · scroll to pan")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
