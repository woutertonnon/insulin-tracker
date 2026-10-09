import SwiftUI
import SwiftData

/// Settings, which for now means the basal reminder.
///
/// The phone and not the watch, deliberately. The watch app is one crown dial
/// with no navigation in it, and a settings screen behind that dial would mean
/// a gesture that could be hit on the way to logging a dose. This is also a
/// set-once value: the time basal is taken changes about as often as a
/// prescription does.
struct SettingsView: View {
    @Query(sort: \LogEntry.timestamp, order: .reverse)
    private var entries: [LogEntry]

    @AppStorage(BasalSchedule.Defaults.enabledKey)
    private var isEnabled = false

    @AppStorage(BasalSchedule.Defaults.minuteOfDayKey)
    private var minuteOfDay = BasalSchedule.Defaults.defaultMinuteOfDay

    /// Debounces the push to the watch.
    ///
    /// The channel that carries it can wake the watch in the background, which
    /// is why it is used, and it is budgeted per day — while a time picker
    /// emits a change per tick of the wheel. One send per interaction, not per
    /// tick.
    @State private var push: Task<Void, Never>?

    /// Whether anything has changed since the last send. Keeps merely *opening*
    /// this screen from spending one of those transfers.
    @State private var isDirty = false

    private let pushDelay: Duration = .seconds(1.5)

    private var reminder: BasalSchedule.Reminder? {
        isEnabled ? BasalSchedule.Reminder(minuteOfDay: minuteOfDay) : nil
    }

    /// The newest basal in the log — what clears the reminder. `entries` is
    /// sorted newest first, so the first basal in it is the latest one.
    private var lastBasal: Date? {
        entries.first { $0.kind == .basal }?.timestamp
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isEnabled) {
                    Label("Basal reminder", systemImage: "alarm")
                }
                if isEnabled {
                    DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Basal")
            } footer: {
                if isEnabled {
                    Text("""
                    At this time the watch complication gives itself over to \
                    **BASAL!** — the chart and the insulin-on-board figure are \
                    replaced by the word, so a glance can't miss it. It clears \
                    the moment basal is logged, and gives up after \
                    \(Self.windowText) either way: a complication that always \
                    says BASAL! would stop being a signal. Logging it up to \
                    \(Self.graceText) early counts as done, so an early dose \
                    isn't asked for twice.
                    """)
                } else {
                    Text("A standard time for the long-acting injection. Nothing else in the day reminds you of it, and a missed basal is the largest single error in the averages on the history screen.")
                }
            }

            if isEnabled {
                Section("Right now") {
                    // Ticks, so sitting on this screen across the due minute
                    // shows the change rather than a stale line.
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        status(at: timeline.date)
                    }
                }

                Section {
                    Text("The watch is told over the same local link the log uses, so a change reaches it once the watch is in range. The reminder then runs on the watch — it needs no connection to fire.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isEnabled) { _, _ in schedulePush() }
        .onChange(of: minuteOfDay) { _, _ in schedulePush() }
        .onDisappear {
            // Leaving is the end of the interaction, so stop waiting out the
            // debounce and send what is set.
            push?.cancel()
            flushPush()
        }
    }

    // MARK: - Pushing to the watch

    private func schedulePush() {
        isDirty = true
        push?.cancel()
        push = Task {
            try? await Task.sleep(for: pushDelay)
            if Task.isCancelled { return }
            await MainActor.run { flushPush() }
        }
    }

    @MainActor
    private func flushPush() {
        guard isDirty else { return }
        isDirty = false
        ConnectivityManager.shared.sendBasalReminder(reminder)
    }

    // MARK: - Status

    @ViewBuilder
    private func status(at date: Date) -> some View {
        switch BasalSchedule.status(at: date, reminder: reminder, lastBasal: lastBasal) {
        case .due(let since):
            Label("Due since \(Self.timeFormatter.string(from: since)) — the watch is showing BASAL!",
                  systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.indigo)

        case .taken(let when):
            Label("Logged at \(Self.timeFormatter.string(from: when))",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .waiting(let next):
            Label("Next at \(Self.timeFormatter.string(from: next))", systemImage: "clock")
                .foregroundStyle(.secondary)

        case .off:
            Label("Off", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// The two windows, in prose. Spelled out because "7200 seconds" — and even
    /// "2 h" — reads as a machine talking in the middle of a sentence.
    private static let windowText = spelledHours(BasalSchedule.alertWindow)
    private static let graceText = spelledHours(BasalSchedule.earlyGrace)

    private static func spelledHours(_ interval: TimeInterval) -> String {
        let hours = Int((interval / 3600).rounded())
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let spelled = formatter.string(from: NSNumber(value: hours)) ?? "\(hours)"
        return "\(spelled) hour\(hours == 1 ? "" : "s")"
    }

    // MARK: - The picker's binding

    /// The stored value is a minute of the day; a `DatePicker` wants a `Date`.
    ///
    /// Resolved against a fixed, DST-free reference day rather than against
    /// today, so the wheel cannot show a time an hour off the stored one on the
    /// morning the clocks go forward. Which day the setting lands on is decided
    /// per day by `BasalSchedule`, not here.
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Self.referenceDate(minuteOfDay: minuteOfDay) },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private static func referenceDate(minuteOfDay: Int) -> Date {
        var c = DateComponents()
        c.year = 2000
        c.month = 1
        c.day = 1
        c.hour = minuteOfDay / 60
        c.minute = minuteOfDay % 60
        return Calendar.current.date(from: c) ?? .now
    }
}
