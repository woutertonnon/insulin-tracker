import SwiftUI
import UIKit

/// Glucose and insulin averaged over four look-back windows, side by side, so a
/// drift in sensitivity is visible as a column that no longer matches the ones
/// beside it.
///
/// The bottom row is the point of the card: total daily insulin per unit of
/// glucose. With diet roughly constant it says what a given glucose level is
/// costing in insulin — and it rises as sensitivity falls.
struct InsulinStatsCard: View {
    let summary: InsulinStats.Summary
    /// For labelling the glucose rows, e.g. "mmol/L".
    let glucoseUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.anchor == nil {
                noGlucose
            } else {
                grid
                caveats
                method
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - States

    private var noGlucose: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waiting for glucose")
                .font(.headline)
            Text("Every window ends at the newest reading, so nothing can be measured until Health has some. The Dexcom app writes them there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The table

    /// One row of the table. The closure returns nil where a window has nothing
    /// to say, which is drawn as a dash rather than a zero — an unmeasured
    /// window and a window measuring zero are not the same claim.
    private struct Metric: Identifiable {
        let name: String
        let unit: String
        let emphasised: Bool
        let value: (InsulinStats.Window) -> String?

        var id: String { name }
    }

    private var metrics: [Metric] {
        let unit = glucoseUnit
        return [
            Metric(name: "Glucose", unit: unit, emphasised: false) { window in
                window.meanGlucose.map { InsulinStats.formatGlucose($0, unit: unit) }
            },
            Metric(name: "SD", unit: unit, emphasised: false) { window in
                window.sdGlucose.map { InsulinStats.formatGlucose($0, unit: unit) }
            },
            Metric(name: "Basal", unit: "U/day", emphasised: false) { window in
                window.basalPerDay.map(InsulinStats.formatUnits)
            },
            Metric(name: "Bolus", unit: "U/day", emphasised: false) { window in
                window.bolusPerDay.map(InsulinStats.formatUnits)
            },
            Metric(name: "Total", unit: "U/day", emphasised: false) { window in
                window.totalPerDay.map(InsulinStats.formatUnits)
            },
            Metric(name: "Insulin ÷ glucose", unit: "U/day per \(unit)", emphasised: true) { window in
                window.insulinPerGlucose.map { InsulinStats.formatIndex($0, unit: unit) }
            },
        ]
    }

    private var grid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 9) {
            GridRow {
                Text("")
                    .frame(width: Self.labelWidth, alignment: .leading)
                ForEach(summary.windows) { window in
                    Text("\(window.days) d")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            ForEach(metrics) { metric in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(metric.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(metric.unit)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: Self.labelWidth, alignment: .leading)

                    ForEach(summary.windows) { window in
                        value(metric.value(window), emphasised: metric.emphasised)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func value(_ text: String?, emphasised: Bool) -> some View {
        if let text {
            Text(text)
                .font(.system(size: emphasised ? 15 : 14,
                              weight: .semibold,
                              design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(emphasised ? Self.index : Self.primary)
        } else {
            Text("—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - What the numbers are not

    /// Everything that makes a column mean less than it looks like it means.
    /// A window running on a fortnight of log, or on a CGM that was offline for
    /// half of it, is not obviously different from a full one — so it is said
    /// outright rather than left to be noticed.
    private var caveats: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(caveatText, id: \.self) { text in
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Built as plain strings rather than in the view body: each one lists a
    /// subset of the windows, and assembling those lists inside a `Text`
    /// interpolation nests string literals two deep for no gain.
    private var caveatText: [String] {
        var notes: [String] = []

        if let anchor = summary.anchor {
            notes.append("Windows end at the newest reading, \(Self.time.string(from: anchor)).")
        }

        let partial = summary.windows.filter(\.isPartial)
        if !partial.isEmpty {
            let parts = partial.map { "\($0.days) d: \(Int($0.loggedDays.rounded())) days" }
            notes.append("The log only reaches back \(join(parts)). Per-day figures are divided by that, not by the window.")
        }

        let thin = summary.windows.filter { $0.glucoseCoverage < 0.8 && $0.glucoseCount > 0 }
        if !thin.isEmpty {
            let parts = thin.map { "\($0.days) d: \(Int(($0.glucoseCoverage * 100).rounded()))%" }
            notes.append("CGM covers \(join(parts)). The averages describe the covered part only.")
        }

        let noBasal = summary.windows.filter(\.missingBasal)
        if !noBasal.isEmpty {
            let parts = noBasal.map { "\($0.days) d" }
            notes.append("No basal logged in \(join(parts)). Basal is usually the larger half of the day, so the total and the index there are understated, not slightly off.")
        }

        let spotty = summary.windows.filter(\.basalIsSpotty)
        if !spotty.isEmpty {
            let parts = spotty.map { "\($0.days) d: \($0.basalGapDays)" }
            notes.append("Days with no basal on them — \(join(parts)). A missed log and a missed injection look the same from here, and either way those days divide the average without contributing to it.")
        }

        return notes
    }

    private func join(_ parts: [String]) -> String {
        parts.formatted(.list(type: .and))
    }

    private var method: some View {
        Text("Mean and standard deviation over the CGM readings in each window; insulin summed and divided by the days of log it covers. The last row is total daily insulin per unit of glucose — with diet unchanged it rises when the same glucose costs more insulin, so **up means less sensitive**. An observation, not a dose recommendation.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Layout

    /// Wide enough for "Insulin ÷ glucose" on two lines, narrow enough to leave
    /// four number columns room on the smallest phone.
    private static let labelWidth: CGFloat = 92

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // MARK: - Palette

    private static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    /// Categorical slot 3 (amber) — the index is a different kind of quantity
    /// from the units and millimoles above it, and reads as one.
    private static let index = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xd4 / 255, green: 0x8e / 255, blue: 0x2c / 255, alpha: 1)
            : UIColor(red: 0xc5 / 255, green: 0x7c / 255, blue: 0x1e / 255, alpha: 1)
    })
}
