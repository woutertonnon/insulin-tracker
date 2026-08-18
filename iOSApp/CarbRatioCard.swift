import SwiftUI

/// Insulin-to-carb ratio measured from how meals actually behaved, split by
/// time of day and by whether exercise overlapped.
///
/// Cells with too few meals show their count rather than a number. A ratio
/// drawn from two meals and one drawn from twenty should not look alike.
struct CarbRatioCard: View {
    let estimate: CarbRatio.Estimate
    /// For labelling the measured sensitivity, e.g. "mmol/L".
    let glucoseUnit: String

    private var hasAnything: Bool {
        estimate.pooled != nil || estimate.cells.contains { $0.ratio != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if estimate.isf == nil {
                needsCorrections
            } else if !hasAnything {
                needsMeals
            } else {
                grid
                if let pooled = estimate.pooled {
                    Text("All meals together: **\(CarbRatio.format(pooled))**")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                sensitivity
                correctionEvidence
            }
            evidence
            method
        }
        .padding(.vertical, 4)
    }

    // MARK: - States

    private var needsCorrections: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Needs a correction dose first")
                .font(.headline)
            Text("Turning a glucose miss into missing units needs to know how far one unit moves you. That is measured from boluses taken with no food within four hours — \(estimate.isfSampleCount) usable so far, \(CarbRatio.minimumCorrections) needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            correctionEvidence
        }
    }

    private var needsMeals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not enough meals yet")
                .font(.headline)
            Text("Needs meals logged in grams with a bolus in the hour before, and glucose either side. \(CarbRatio.minimumEpisodes) per slot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The grid

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                Text("No exercise").font(.caption2).foregroundStyle(.secondary)
                Text("With exercise").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(CarbRatio.Daypart.allCases, id: \.self) { part in
                GridRow {
                    Text(part.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    cell(for: part, exercise: false)
                    cell(for: part, exercise: true)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for part: CarbRatio.Daypart, exercise: Bool) -> some View {
        let match = estimate.cells.first { $0.daypart == part && $0.withExercise == exercise }
        VStack(alignment: .leading, spacing: 0) {
            if let ratio = match?.ratio {
                Text(CarbRatio.format(ratio))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(exercise ? Self.exerciseTint : Self.primary)
                Text("\(match?.episodeCount ?? 0) meals")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("\(match?.episodeCount ?? 0) of \(CarbRatio.minimumEpisodes)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var sensitivity: some View {
        if let isf = estimate.isf {
            Text("Measured sensitivity: 1 U moves you \(String(format: "%.1f", isf)) \(glucoseUnit), from \(estimate.isfSampleCount) correction\(estimate.isfSampleCount == 1 ? "" : "s").")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Corrections that were looked at and dropped. Without this a dose that
    /// quietly failed a filter is indistinguishable from one that never
    /// happened.
    @ViewBuilder
    private var correctionEvidence: some View {
        let dropped = estimate.correctionRejections.filter { $0.value > 0 }
        if !dropped.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Corrections not used")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(dropped.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                    Text("\(count) · \(reason.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var evidence: some View {
        let rejected = estimate.rejections.filter { $0.value > 0 }
        if !rejected.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meals not counted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rejected.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                    Text("\(count) · \(reason.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var method: some View {
        Text("For each meal with carbs in grams and a bolus in the hour before: glucose at the meal versus four hours later, with the miss converted into the units that were missing, giving the ratio that would have landed flat. Median per slot. An observation, not a dose recommendation.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Palette

    private static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    private static let exerciseTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255, alpha: 1)
            : UIColor(red: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255, alpha: 1)
    })
}
