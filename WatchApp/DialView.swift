import SwiftUI
import SwiftData
import WatchKit
import WidgetKit
import CoreLocation
import Combine

/// The single-screen logging UI.
///
/// One Digital Crown dial:
///   • crown UP   → a blood sugar reading from a finger-prick meter, in the
///                  unit Health is set to on the phone
///   • crown DOWN → first rapid-acting insulin (0.5 U steps, to 20 U),
///                  then long-acting basal insulin (1 U steps, to 60 U)
///   • center (0) → neutral, shows insulin on board + time since last bolus
///
/// After you stop turning for `autoSaveDelay` seconds, the current value is
/// saved automatically with the current date/time. If you never leave the
/// neutral position, nothing is saved.
///
/// A reading also carries an **inside / outside** badge, because a meter
/// reads low in the cold and high in the heat and the phone adjusts for the
/// outside air only when the reading was taken in it. The badge starts at
/// what the wrist can tell — a place flipped to inside before, else cycling
/// or running in the last quarter hour means outside — and flips on a press
/// of the Action Button, a Double Tap where the watch has it, or a tap on
/// the badge. None of those is on the path of a dose, which is the rule this
/// screen is built around. **What the badge shows when the reading saves is
/// the truth**, flipped or not; nothing recomputes it afterwards.
struct DialView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    /// Everything logged, newest first. Drives the IOB readout on the neutral
    /// screen and the data pushed to the complication.
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var allEntries: [LogEntry]

    /// Crown position as a discrete index. 0 = neutral.
    @State private var index: Double = 0
    @State private var pendingSave: Task<Void, Never>?
    @State private var justSaved: SavedInfo?
    @State private var dismissSaved: Task<Void, Never>?

    /// The unit readings are dialled in. The phone's copy of Health's choice,
    /// put in the App Group over WatchConnectivity; re-read whenever the app
    /// comes to the front, since a change can land while it is away.
    @State private var glucoseUnit = SharedStore.glucoseUnit()

    /// Where a reading is taken. Asked for a fix the moment the crown enters
    /// the reading region, so one is in hand by the time the reading saves.
    @StateObject private var location = LocationStamper()

    /// Whether the wrist was out moving, and how high up it is.
    @StateObject private var wrist = WristContext()

    /// The badge on the reading being dialled: what the wrist inferred,
    /// whether the fix landed on a place marked inside before, and a flip if
    /// one was made. Reset each time the crown leaves neutral.
    @State private var inferredOutdoors = false
    @State private var knownIndoors = false
    @State private var flippedOutdoors: Bool?

    /// Every reading marked by hand, with where it was — the places.
    private var marks: [Temperature.Mark] { allEntries.compactMap(\.mark) }

    private let autoSaveDelay: Duration = .seconds(3)

    /// How long the checkmark stays up, and how much longer after a flip on
    /// it, so the result of the flip can be seen.
    private let savedDisplay: Duration = .seconds(1.4)
    private let savedDisplayAfterFlip: Duration = .seconds(2.5)

    /// Re-logging the **same kind** within this window edits the last entry
    /// instead of adding a new one (correcting a mis-entry).
    private let correctionWindow: TimeInterval = 15

    /// What the last save produced, and what kind it was.
    ///
    /// The correction only ever applies to this entry, and only when the new
    /// value is of the same kind: a bolus is never edited into a basal, a
    /// basal never into a bolus, and a reading touches neither. Kept here
    /// rather than looked up in the query, which is the other reason — a row
    /// inserted a moment ago may not be in `@Query` results yet, and a search
    /// for "the newest bolus" would then find an older one and add a duplicate
    /// instead of correcting.
    @State private var lastSaved: LastSaved?

    // MARK: - Dial ladders

    /// Crown up, steps 1…N: every blood sugar value the meter could read, in
    /// the unit in use. See `GlucoseUnit.dialLadder`.
    private var glucoseLadder: [Double] { glucoseUnit.dialLadder }

    /// Crown down, steps 1…40: rapid-acting bolus in 0.5 U steps, up to 20 U.
    private static let bolusMaxSteps = 40

    /// Crown down, steps 41+: long-acting basal, restarting at 1 U in 1 U
    /// steps, up to 60 U. Basal has a different action profile and is
    /// deliberately excluded from the IOB / activity math.
    private static let basalMaxUnits = 60

    private static let insulinMaxSteps = bolusMaxSteps + basalMaxUnits

    private var step: Int { Int(index.rounded()) }

    /// "1.0 (39)" — `CFBundleVersion` is the CI run number, so this is exactly
    /// the TestFlight build number.
    private static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    // MARK: - Dial value decoding

    /// What a positive crown step means: a reading, in the unit in use.
    private func glucoseValue(for positiveStep: Int) -> Double {
        let ladder = glucoseLadder
        let s = min(max(positiveStep, 1), ladder.count)
        return ladder[s - 1]
    }

    /// What a negative crown step means: a rapid-acting bolus, or basal.
    private enum InsulinValue {
        case bolus(Double)
        case basal(Double)
    }

    private func insulinValue(for downSteps: Int) -> InsulinValue {
        let s = min(max(downSteps, 1), Self.insulinMaxSteps)
        if s <= Self.bolusMaxSteps {
            return .bolus(Double(s) * 0.5)
        }
        return .basal(Double(s - Self.bolusMaxSteps))
    }

    // MARK: - Derived insulin state

    private var lastBolus: LogEntry? {
        allEntries.first { $0.kind == .insulin }
    }

    /// Rapid-acting boluses only — basal is not part of the IOB model.
    private var activeDoses: [InsulinMath.Dose] {
        let cutoff = Date.now.addingTimeInterval(-InsulinMath.duration)
        return allEntries
            .filter { $0.kind == .insulin && $0.timestamp > cutoff }
            .map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
    }

    /// The badge as it stands for the reading being dialled: a flip, else a
    /// place marked inside before, else what the wrist saw.
    private var shownOutdoors: Bool { flippedOutdoors ?? (knownIndoors ? false : inferredOutdoors) }

    var body: some View {
        ZStack {
            if let saved = justSaved {
                savedView(saved)
            } else {
                dialContent
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $index,
            from: -Double(Self.insulinMaxSteps),
            through: Double(glucoseLadder.count),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: index) { previous, _ in
            if step > 0 {
                location.requestFix()
                wrist.begin()
                if Int(previous.rounded()) <= 0 { enteredReadingRegion() }
            } else {
                wrist.end()
            }
            scheduleSave()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                glucoseUnit = SharedStore.glucoseUnit()
                resetToNeutral()
                // A reading saved before its fix came, and the app put away
                // before the fix did: ask again, and the fix stamps it.
                if !unstampedReadings(near: .now).isEmpty { location.requestFix() }
                // Repair the complication if a push was missed while away.
                syncWidget()
            case .inactive, .background:
                // Wrist-down / screen-off before the 3s timer fired — commit
                // the current value now so it isn't lost.
                flushPendingSave()
            default:
                break
            }
        }
        .onAppear {
            glucoseUnit = SharedStore.glucoseUnit()
            resetToNeutral()
            syncWidget()
        }
        // The Action Button, assigned to this app's Shortcut, runs the intent
        // on every press — the first opens the dial, the next flips the badge.
        .onReceive(NotificationCenter.default.publisher(for: .insulinActionButton)) { _ in
            flipBadge()
        }
        // A fix landing while a reading is dialled may land on a known place.
        .onReceive(location.$latest) { fix in
            if step > 0 { refreshKnownPlace() }
            if let fix { stampUnstamped(with: fix) }
        }
    }

    /// Fresh badge for a fresh reading: no flip yet, and the wrist asked
    /// whether it has been out moving.
    @MainActor
    private func enteredReadingRegion() {
        flippedOutdoors = nil
        inferredOutdoors = false
        knownIndoors = false
        refreshKnownPlace()
        Task {
            let moving = await wrist.wasMovingOutdoors()
            // Only if the crown is still on a reading — not after it has gone
            // back to neutral and on to a dose.
            if step > 0 { inferredOutdoors = moving }
        }
    }

    /// Whether the fix in hand — fresh or not; a place does not move — is
    /// somewhere marked inside at least three times more than outside.
    @MainActor
    private func refreshKnownPlace() {
        guard let fix = location.latest else { return }
        knownIndoors = Temperature.isKnownIndoors(latitude: fix.coordinate.latitude,
                                                  longitude: fix.coordinate.longitude,
                                                  marks: marks)
    }

    /// Push what the complication reads into the App Group — the recent bolus
    /// history, so it can compute IOB itself, and the newest basal, which is
    /// what clears its basal reminder — then nudge WidgetKit to rebuild.
    private func syncWidget(including extra: LogEntry? = nil) {
        var entries = allEntries
        // A freshly-inserted entry may not be in @Query results yet.
        if let extra, !entries.contains(where: { $0.id == extra.id }) {
            entries.append(extra)
        }
        SharedStore.setBolusDoses(
            entries
                .filter { $0.kind == .insulin }
                .map { InsulinMath.Dose(units: $0.amount, date: $0.timestamp) }
        )
        SharedStore.setLastBasal(
            entries.filter { $0.kind == .basal }.map(\.timestamp).max()
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Subviews

    @ViewBuilder
    private var dialContent: some View {
        if step > 0 {
            VStack(spacing: 6) {
                valueView(title: "BLOOD SUGAR",
                          value: glucoseUnit.formatValue(glucoseValue(for: step)),
                          unit: glucoseUnit.label,
                          color: .pink,
                          systemImage: "drop.fill",
                          large: true)
                badge(outdoors: shownOutdoors)
            }
        } else if step < 0 {
            switch insulinValue(for: -step) {
            case .bolus(let units):
                valueView(title: "INSULIN",
                          value: unitsString(units),
                          unit: "U",
                          color: .blue,
                          systemImage: "syringe",
                          large: true)
            case .basal(let units):
                valueView(title: "BASAL",
                          value: unitsString(units),
                          unit: "U",
                          color: .indigo,
                          systemImage: "syringe",
                          large: true)
            }
        } else {
            neutralView
        }
    }

    /// Inside or outside, as a small capsule. A button, so a tap flips it and
    /// so Double Tap — which drives an app's primary action — can be pointed
    /// at it on watches that have the gesture.
    private func badge(outdoors: Bool) -> some View {
        let button = Button(action: flipBadge) {
            Label(outdoors ? "outside" : "inside",
                  systemImage: outdoors ? "sun.max" : "house")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(outdoors ? Color.teal.opacity(0.25) : Color.gray.opacity(0.25)))
                .foregroundStyle(outdoors ? Color.teal : Color.secondary)
        }
        .buttonStyle(.plain)

        return Group {
            if #available(watchOS 11, *) {
                button.handGestureShortcut(.primaryAction)
            } else {
                button
            }
        }
    }

    private var neutralView: some View {
        // Re-evaluates every 30 s so the IOB figures stay honest while the
        // screen is up.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let doses = activeDoses
            let iob = InsulinMath.insulinOnBoard(doses, at: timeline.date)
            // Exponential model, matching the complication's chart and the
            // iPhone forecast — otherwise this screen would contradict the
            // complication sitting on the same watch face.
            let active = InsulinMath.exponentialActivity(doses, at: timeline.date)

            VStack(spacing: 6) {
                if let last = lastBolus {
                    VStack(spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(InsulinMath.format(iob))
                                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                            Text("U on board")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.blue)

                        Text("\(InsulinMath.format(active)) U active now")
                            .font(.caption2)
                            .foregroundStyle(.teal)

                        Text(last.timestamp, style: .timer)
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    Text("No insulin logged yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 1)

                VStack(spacing: 2) {
                    Label("Blood sugar", systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                    Label("Insulin / basal", systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                // Which binary is actually on the wrist. The complication is
                // embedded in this app, so it is always this same build —
                // which makes this the version marker for both.
                Text(Self.versionString)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
        }
    }

    private func valueView(title: String,
                           value: String,
                           unit: String?,
                           color: Color,
                           systemImage: String,
                           large: Bool) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: large ? 56 : 30, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit {
                    Text(unit)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Text("saving in a moment…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
    }

    private func savedView(_ info: SavedInfo) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(info.text)
                .font(.headline)
                .multilineTextAlignment(.center)
            // A reading's badge stays flippable on the checkmark, for the
            // glance that comes a moment too late.
            if let outdoors = info.outdoors {
                badge(outdoors: outdoors)
            }
        }
    }

    // MARK: - Logic

    private func unitsString(_ units: Double) -> String {
        units == units.rounded() ? String(Int(units)) : String(format: "%.1f", units)
    }

    /// Save immediately if there's a dialed-but-not-yet-saved value. Used when
    /// the app is about to background so a pending entry isn't dropped.
    @MainActor
    private func flushPendingSave() {
        guard step != 0, justSaved == nil else { return }
        pendingSave?.cancel()
        save()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard step != 0 else { return }
        pendingSave = Task {
            try? await Task.sleep(for: autoSaveDelay)
            if Task.isCancelled { return }
            await MainActor.run { save() }
        }
    }

    /// Flip inside ↔ outside: on the reading being dialled, restarting the
    /// save timer so the result can be seen; or on the reading just saved,
    /// rewriting it and keeping the checkmark up a little longer. A press
    /// with a dose on screen, or nothing on screen, does nothing.
    @MainActor
    private func flipBadge() {
        if let saved = justSaved {
            guard let entry = saved.entry, entry.kind == .glucose, let outdoors = saved.outdoors else { return }
            entry.outdoors = !outdoors
            entry.chosen = true
            try? context.save()
            ConnectivityManager.shared.send(entry)
            WKInterfaceDevice.current().play(.click)
            justSaved = SavedInfo(text: saved.text, entry: entry, outdoors: !outdoors)
            showSaved(for: savedDisplayAfterFlip)
            return
        }

        guard step > 0 else { return }
        flippedOutdoors = !shownOutdoors
        WKInterfaceDevice.current().play(.click)
        scheduleSave()
    }

    @MainActor
    private func save() {
        let s = step
        guard s != 0 else { return }

        let now = Date.now
        let kind: EntryKind
        let amount: Double

        if s > 0 {
            kind = .glucose
            // Stored in mmol/L whichever unit it was dialled in.
            amount = glucoseUnit.stored(glucoseValue(for: s))
        } else {
            switch insulinValue(for: -s) {
            case .bolus(let units):
                kind = .insulin
                amount = units
            case .basal(let units):
                kind = .basal
                amount = units
            }
        }

        let entry: LogEntry
        let wasCorrection: Bool
        if let last = lastSaved,
           last.kind == kind,
           now.timeIntervalSince(last.at) <= correctionWindow {
            // Same kind logged moments ago — treat this as a correction.
            last.entry.amount = amount
            last.entry.timestamp = now
            entry = last.entry
            wasCorrection = true
        } else {
            entry = LogEntry(timestamp: now, kind: kind, amount: amount)
            context.insert(entry)
            wasCorrection = false
        }
        lastSaved = LastSaved(kind: kind, entry: entry, at: now)

        var savedOutdoors: Bool?
        if kind == .glucose {
            // The badge, as shown: the person saw it and let it stand or
            // flipped it, and either way it is the truth from here on. A
            // flip is also noted — only those teach the app a place.
            savedOutdoors = shownOutdoors
            entry.outdoors = shownOutdoors
            entry.chosen = flippedOutdoors != nil
            entry.moving = inferredOutdoors

            // Stamp a reading with where it was taken. A fresh fix is
            // attached before the entry crosses to the phone; one that
            // arrives later is attached when it lands and the entry sent
            // again, so the phone can look up the temperature either way.
            if let fix = location.fresh {
                stamp(entry, with: fix)
            } else {
                location.whenFixed { fix in
                    stamp(entry, with: fix)
                    try? context.save()
                    ConnectivityManager.shared.send(entry)
                }
            }
        }

        try? context.save()
        ConnectivityManager.shared.send(entry)
        WKInterfaceDevice.current().play(.success)

        syncWidget(including: entry)

        justSaved = SavedInfo(text: (wasCorrection ? "Updated " : "Saved ") + entry.displayAmount(in: glucoseUnit),
                              entry: entry,
                              outdoors: savedOutdoors)
        showSaved(for: savedDisplay)
    }

    /// Where, and how high. The barometer's altitude where the watch has
    /// one — a few metres, in a second — else the fix's, and only when the
    /// fix vouches for it.
    private func stamp(_ entry: LogEntry, with fix: CLLocation) {
        entry.latitude = fix.coordinate.latitude
        entry.longitude = fix.coordinate.longitude
        entry.altitude = wrist.altitude ?? (fix.verticalAccuracy >= 0 ? fix.altitude : nil)
    }

    /// How long after a reading a fix still stands for where it was taken.
    /// Weather does not change across a quarter hour's walk.
    private static let lateFixWindow: TimeInterval = 15 * 60

    /// Readings still without a place that a fix at `date` could stand for.
    private func unstampedReadings(near date: Date) -> [LogEntry] {
        allEntries.filter {
            $0.kind == .glucose && !$0.hasLocation
                && $0.timestamp <= date
                && date.timeIntervalSince($0.timestamp) <= Self.lateFixWindow
        }
    }

    /// The backstop for `whenFixed`, whose waiting handler lives only in
    /// memory: a failed request, or the app suspended or ended after the
    /// wrist went down, and it never runs. The log does not forget, so every
    /// fix stamps the readings that went without one, and sends them again
    /// for the phone to look the weather up.
    private func stampUnstamped(with fix: CLLocation) {
        let readings = unstampedReadings(near: fix.timestamp)
        guard !readings.isEmpty else { return }
        for entry in readings { stamp(entry, with: fix) }
        try? context.save()
        for entry in readings { ConnectivityManager.shared.send(entry) }
    }

    /// Show the checkmark for `duration`, then return to neutral. Calling it
    /// again restarts the clock.
    private func showSaved(for duration: Duration) {
        dismissSaved?.cancel()
        dismissSaved = Task {
            try? await Task.sleep(for: duration)
            if Task.isCancelled { return }
            await MainActor.run { resetToNeutral() }
        }
    }

    private func resetToNeutral() {
        pendingSave?.cancel()
        pendingSave = nil
        dismissSaved?.cancel()
        dismissSaved = nil
        justSaved = nil
        flippedOutdoors = nil
        inferredOutdoors = false
        wrist.end()
        index = 0
    }
}

private struct SavedInfo: Equatable {
    let text: String
    /// The row behind the checkmark, so a flip on the checkmark can rewrite it.
    let entry: LogEntry?
    /// The badge as saved; nil for a dose, which has none.
    let outdoors: Bool?

    static func == (lhs: SavedInfo, rhs: SavedInfo) -> Bool {
        lhs.text == rhs.text && lhs.outdoors == rhs.outdoors && lhs.entry === rhs.entry
    }
}

private struct LastSaved {
    let kind: EntryKind
    let entry: LogEntry
    let at: Date
}
