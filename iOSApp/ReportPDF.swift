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

    /// One page of the report.
    ///
    /// Decided up front from counts rather than by measuring text, so a table
    /// can never run off the bottom of the paper: every row is a fixed height,
    /// and the number that fit is arithmetic.
    enum Page {
        case summary
        case charts
        case notes
        case days(ArraySlice<Report.Day>, continued: Bool)
        case log(ArraySlice<Report.LogLine>, continued: Bool)
    }

    static func paginate(_ document: Report.Document,
                         includeLog: Bool,
                         pageSize: CGSize) -> [Page] {
        var pages: [Page] = [.summary, .charts, .notes]

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

    private static func chunks<T>(_ array: [T], size: Int) -> [ArraySlice<T>] {
        guard !array.isEmpty, size > 0 else { return [] }
        return stride(from: array.startIndex, to: array.endIndex, by: size).map { start in
            array[start..<min(start + size, array.endIndex)]
        }
    }

    /// Draw every page. On the main actor because `ImageRenderer` is.
    @MainActor
    static func render(_ document: Report.Document, includeLog: Bool) -> Data? {
        let size = pageSize
        let pages = paginate(document, includeLog: includeLog, pageSize: size)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "Insulin & glucose report",
            kCGPDFContextCreator: "Insulin Tracker",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
            return nil
        }

        for (index, page) in pages.enumerated() {
            let view = ReportPageView(page: page,
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
