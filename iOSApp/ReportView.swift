import SwiftUI
import SwiftData
import PDFKit

/// The doctor's report: pick a period, see the pages, send them on.
///
/// A PDF rather than a screen to hand over, because a PDF is the one thing
/// every clinic can take — AirDropped, mailed, printed at home, or saved to
/// Files and uploaded to a patient portal — and it reads the same on their
/// side as on this one. The share sheet offers all of those; this screen only
/// decides what goes in.
///
/// The period and the appendix choice are remembered, so the report for the
/// next visit is one tap.
@MainActor
struct ReportView: View {
    let entries: [LogEntry]
    @ObservedObject var health: HealthStore

    @AppStorage("reportPeriodDays")
    private var periodDays = Report.Period.month.rawValue

    @AppStorage("reportIncludesLog")
    private var includeLog = false

    @AppStorage("reportKind")
    private var kindRaw = ReportPDF.Kind.overview.rawValue

    private var kind: ReportPDF.Kind {
        ReportPDF.Kind(rawValue: kindRaw) ?? .overview
    }

    @State private var pdf: Data?
    @State private var fileURL: URL?
    @State private var isBuilding = false
    @State private var build: Task<Void, Never>?

    private var period: Report.Period {
        Report.Period(rawValue: periodDays) ?? .month
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            preview
        }
        .navigationTitle("Doctor's report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let fileURL, !isBuilding {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .task { await rebuild() }
        .onChange(of: periodDays) { _, _ in rebuild() }
        .onChange(of: includeLog) { _, _ in rebuild() }
        .onChange(of: kindRaw) { _, _ in rebuild() }
        .onDisappear { build?.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Report", selection: $kindRaw) {
                ForEach(ReportPDF.Kind.allCases) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Period", selection: $periodDays) {
                ForEach(Report.Period.allCases) { period in
                    Text(period.title).tag(period.rawValue)
                }
            }
            .pickerStyle(.segmented)

            switch kind {
            case .overview:
                Toggle(isOn: $includeLog) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Append every entry")
                        Text("Each injection, meter reading and workout in time order. Adds pages.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            case .lows:
                Text("Every low from the CGM — under 60 mg/dL, or under 70 mg/dL for 30 minutes — with the insulin, exercise and finger-pricks around it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .highs:
                Text("Every high from the CGM — over 180 mg/dL for an hour — with the insulin, exercise and finger-pricks around it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Whole days ending yesterday. Share, print or save with the button above.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var preview: some View {
        if let pdf {
            PDFPreview(data: pdf)
                .ignoresSafeArea(edges: .bottom)
        } else if isBuilding {
            ProgressView("Laying out the pages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing to show",
                                   systemImage: "doc.text",
                                   description: Text("The report could not be built."))
        }
    }

    // MARK: - Building

    @MainActor
    private func rebuild() {
        build?.cancel()
        isBuilding = true

        // Snapshotted as plain values first: the entries are SwiftData
        // objects and Health's arrays belong to the main actor, and neither
        // should cross to the thread the numbers are built on.
        let period = self.period
        let includeLog = self.includeLog
        let kind = self.kind
        let now = Date.now
        let unit = health.glucoseUnitLabel
        let weightUnit = health.weightUnitLabel
        let weightPadding = health.weightAxisPadding
        let glucose = health.glucose.map { Report.GlucosePoint(date: $0.date, value: $0.value) }
        let events = entries.map {
            Report.Event(date: $0.timestamp, kind: $0.kind, amount: $0.amount,
                         temperature: $0.temperature, outdoors: $0.outdoors, chosen: $0.chosen,
                         moving: $0.moving, latitude: $0.latitude, longitude: $0.longitude)
        }
        let workouts = health.workouts.map {
            Report.Workout(start: $0.start, end: $0.end, name: $0.name,
                           kilocalories: $0.kilocalories, outdoors: $0.outdoors)
        }
        let energy = health.dailyEnergy.map { Report.Energy(day: $0.day, kilocalories: $0.kilocalories) }
        let weights = health.weights.map { Report.Weight(date: $0.date, value: $0.value) }

        build = Task {
            // The numbers are built off the main thread — ninety days of CGM
            // is tens of thousands of readings — and only the drawing, which
            // `ImageRenderer` insists on doing there, happens on it.
            let document = await Task.detached(priority: .userInitiated) {
                Report.build(period: period,
                             now: now,
                             glucoseUnit: unit,
                             weightUnit: weightUnit,
                             weightAxisPadding: weightPadding,
                             glucose: glucose,
                             events: events,
                             workouts: workouts,
                             energy: energy,
                             weights: weights)
            }.value
            if Task.isCancelled { return }

            let data = ReportPDF.render(document, kind: kind, includeLog: includeLog)
            if Task.isCancelled { return }

            pdf = data
            fileURL = data.flatMap { try? ReportPDF.write($0, named: document.fileName(kind.fileStem)) }
            isBuilding = false
        }
    }
}

/// PDFKit's viewer, so the pages on screen are exactly the pages that will be
/// sent — not a SwiftUI approximation of them.
private struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // Reloading on every SwiftUI update would reset the scroll position
        // each time the parent redraws; only a new document is worth it.
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: Data?
    }
}
