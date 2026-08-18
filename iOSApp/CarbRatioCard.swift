import SwiftUI

/// Running 7-day insulin-to-carb ratio.
///
/// Shows the insulin-only figure as the headline, because that is the one your
/// meal logging cannot distort, and the meal-derived figure beside it as
/// corroboration. When they disagree, that disagreement is the interesting part
/// and is stated rather than averaged away.
struct CarbRatioCard: View {
    let estimate: CarbRatio.Estimate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if estimate.fromTotalInsulin == nil && estimate.fromMeals == nil {
                notEnoughYet
            } else {
                figures
                agreement
                evidence
            }
            caveats
        }
        .padding(.vertical, 4)
    }

    private var notEnoughYet: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not enough yet")
                .font(.headline)
            Text("Needs insulin logged on at least \(CarbRatio.minimumDays) of the last 7 days. Days covered so far: \(estimate.daysCovered).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var figures: some View {
        HStack(alignment: .top, spacing: 20) {
            if let insulin = estimate.fromTotalInsulin {
                figure(title: "From insulin",
                       value: CarbRatio.format(insulin),
                       detail: tdiText,
                       tint: Self.primary)
            }
            if let meals = estimate.fromMeals {
                figure(title: "From clean meals",
                       value: CarbRatio.format(meals),
                       detail: "\(estimate.episodes.count) meal\(estimate.episodes.count == 1 ? "" : "s")",
                       tint: Self.secondaryTint)
            }
        }
    }

    private func figure(title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var tdiText: String {
        guard let tdi = estimate.totalDailyInsulin else { return "—" }
        return "\(InsulinMath.format(tdi)) U/day over \(estimate.daysCovered) d"
    }

    /// Two independent methods landing far apart is a signal in itself.
    @ViewBuilder
    private var agreement: some View {
        if let a = estimate.fromTotalInsulin, let b = estimate.fromMeals {
            let spread = abs(a - b) / max(a, b)
            if spread > 0.25 {
                Label("The two disagree by more than a quarter. Meals that went well suggest \(CarbRatio.format(b)); your total insulin suggests \(CarbRatio.format(a)).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Label("Both methods agree within a quarter.", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What was thrown away, and why. A ratio drawn from three meals should not
    /// look the same as one drawn from twenty.
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

    private var caveats: some View {
        VStack(alignment: .leading, spacing: 3) {
            if estimate.basalMissing {
                Label("No basal logged in the last 7 days, so total daily insulin is understated and the insulin-based ratio reads higher than it should.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("500 Rule (Think Like a Pancreas): 500 ÷ total daily insulin. Meal figure is the median of meals with one bolus, no other food or insulin within 4 h, no exercise, and glucose back to its starting value 3½ h later. An observation, not a dose recommendation.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Palette

    private static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : UIColor(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    private static let secondaryTint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255, alpha: 1)
            : UIColor(red: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255, alpha: 1)
    })
}
