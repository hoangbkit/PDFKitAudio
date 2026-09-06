import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Small, deterministic PDF factory used by parser regression tests.
///
/// Fixtures are generated at runtime instead of storing binary PDFs in the repository.
/// This keeps test inputs readable and makes it easy to create targeted documents for
/// text extraction, scanned pages, mixed documents, and metadata cases.
enum TestPDFBuilder {
    static func digitalPDF(
        pages: [String],
        title: String? = "Fixture",
        author: String? = "PDFKitAudio Tests"
    ) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        var metadata: [CFString: Any] = [:]
        if let title { metadata[kCGPDFContextTitle] = title }
        if let author { metadata[kCGPDFContextAuthor] = author }

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(
                consumer: consumer,
                mediaBox: &mediaBox,
                metadata as CFDictionary
              ) else {
            throw FixtureError.couldNotCreatePDF
        }

        for text in pages {
            context.beginPDFPage(nil)
            draw(text: text, in: context, pageBounds: mediaBox)
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    static func scannedPDF(pages: [String]) throws -> Data {
        let document = PDFDocument()
        for (index, text) in pages.enumerated() {
            let image = renderedImage(text: text)
            guard let page = PDFPage(image: image) else {
                throw FixtureError.couldNotCreateScannedPage
            }
            document.insert(page, at: index)
        }

        guard let data = document.dataRepresentation() else {
            throw FixtureError.couldNotCreatePDF
        }
        return data
    }

    static func mixedPDF(digitalText: String, scannedText: String) throws -> Data {
        guard let digitalDocument = PDFDocument(data: try digitalPDF(pages: [digitalText])) else {
            throw FixtureError.couldNotCreatePDF
        }
        guard let scannedDocument = PDFDocument(data: try scannedPDF(pages: [scannedText])),
              let scannedPage = scannedDocument.page(at: 0) else {
            throw FixtureError.couldNotCreateScannedPage
        }
        digitalDocument.insert(scannedPage, at: 1)

        guard let data = digitalDocument.dataRepresentation() else {
            throw FixtureError.couldNotCreatePDF
        }
        return data
    }

    static func temporaryFile(data: Data, name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFKitAudioTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func draw(text: String, in context: CGContext, pageBounds: CGRect) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]

        NSString(string: text).draw(
            in: CGRect(x: 54, y: 54, width: pageBounds.width - 108, height: pageBounds.height - 108),
            withAttributes: attributes
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func renderedImage(text: String) -> NSImage {
        let size = NSSize(width: 1224, height: 1584)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        NSString(string: text).draw(
            in: NSRect(x: 100, y: 100, width: size.width - 200, height: size.height - 200),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 32),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        )
        image.unlockFocus()
        return image
    }

    enum FixtureError: Error {
        case couldNotCreatePDF
        case couldNotCreateScannedPage
    }
}
