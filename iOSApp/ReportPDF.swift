import SwiftUI
import UIKit

/// The report on paper: paginated, then drawn page by page into a PDF.
///
/// Each page is an ordinary SwiftUI view laid out at the paper's size and
/// rendered through `ImageRenderer` into a Core Graphics PDF context, so the
/// charts stay vectors and the text stays text — selectable, searchable and
/// crisp at any zoom. Paper follows the locale: Letter where inches are the
/// measure, A4 everywhere else.
enum ReportPDF {

    static var pageSize: CGSize {
        Locale.current.measurementSystem == .us
            ? CGSize(width: 612, height: 792)
            : CGSize(width: 595, height: 842)
    }

    static let margin: CGFloat = 36
    static let rowHeight: CGFloat = 14

    /// Which report: the overview a visit starts from, or one of the two
    /// event reports, each its own document so it can be sent on its own.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case overview
        case lows
        case highs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .lows: return "Lows"
            case .highs: return "Highs"
            }
        }

        /// On every page, and in the file's name.
        var documentTitle: String {
            switch self {
            case .overview: return "Insulin & glucose report"
            case .lows: return "Low glucose events"
            case .highs: return "High glucose events"
            }
        }

        var fileStem: String {
            switch self {
            case .overview: return "Insulin report"
            case .lows: return "Low events"
            case .highs: return "High events"
            }
        }
    }

    /// Events to a page: an event takes a chart and four lines, and three
    /// fit with the totals above them on the first page taking the room of one.
    static let eventsPerPage = 3

    /// One page of the report.
    ///
    /// Decided up front from counts rather than by measuring text, so a table
    /// can never run off the bottom of the paper: every row is a fixed height,
    /// and the number that fit is arithmetic.
    enum Page {
        case summary
        /// Glucose over the period: estimated A1c and GMI, mean glucose.
        case glucoseOverTime
        /// Insulin, active energy and weight over the period, together.
        case insulinAndBody
        case notes
        case days(ArraySlice<Report.Day>, continued: Bool)
        case log(ArraySlice<Report.LogLine>, continued: Bool)
        /// Low or high events, one panel each. The first page carries the
        /// definition and the totals; one with no events at all still does,
        /// and says none.
        case events(Report.EventKind, ArraySlice<Report.GlucoseEvent>, first: Bool)
    }

    static func paginate(_ document: Report.Document,
                         kind: Kind,
                         includeLog: Bool,
                         pageSize: CGSize) -> [Page] {
        switch kind {
        case .overview:
            break
        case .lows:
            return eventPages(.low, document.lows)
        case .highs:
            return eventPages(.high, document.highs)
        }

        var pages: [Page] = [.summary, .glucoseOverTime, .insulinAndBody, .notes]

        // The title block, the section heading and the column headers sit
        // above a table; 120 points is more than they take, so the rows that
        // remain fit with room under them for the footer.
        let rows = max(1, Int((pageSize.height - 2 * margin - 120) / rowHeight))

        pages += chunks(document.days, size: rows).enumerated().map { chunk in
            Page.days(chunk.element, continued: chunk.offset > 0)
        }
        if includeLog {
            // Two columns of lines per page.
            pages += chunks(document.log, size: rows * 2).enumerated().map { chunk in
                Page.log(chunk.element, continued: chunk.offset > 0)
            }
        }
        return pages
    }

    private static func eventPages(_ kind: Report.EventKind, _ events: [Report.GlucoseEvent]) -> [Page] {
        let first = Array(events.prefix(eventsPerPage - 1))
        let rest = Array(events.dropFirst(eventsPerPage - 1))
        return [Page.events(kind, first[...], first: true)]
            + chunks(rest, size: eventsPerPage).map { Page.events(kind, $0, first: false) }
    }

    private static func chunks<T>(_ array: [T], size: Int) -> [ArraySlice<T>] {
        guard !array.isEmpty, size > 0 else { return [] }
        return stride(from: array.startIndex, to: array.endIndex, by: size).map { start in
            array[start..<min(start + size, array.endIndex)]
        }
    }

    /// Draw every page. On the main actor because `ImageRenderer` is.
    @MainActor
    static func render(_ document: Report.Document, kind: Kind, includeLog: Bool) -> Data? {
        let size = pageSize
        let pages = paginate(document, kind: kind, includeLog: includeLog, pageSize: size)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: kind.documentTitle,
            kCGPDFContextCreator: "Insulin Tracker",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            return nil
        }

        for (index, page) in pages.enumerated() {
            let view = ReportPageView(page: page,
                                      title: kind.documentTitle,
                                      document: document,
                                      number: index + 1,
                                      count: pages.count)
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                // Paper is white whatever the phone is set to.
                .environment(\.colorScheme, .light)

            let renderer = ImageRenderer(content: view)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                context.saveGState()
                draw(context)
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Written to the temporary directory under the report's own name, which
    /// is the name the share sheet, Mail and Files will show.
    static func write(_ data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
