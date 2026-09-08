import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Small, deterministic PDF factory used by parser regression tests.
///
/// Fixtures are generated at runtime instead of storing binary PDFs in the repository.
/// This keeps test inputs readable and makes it easy to create targeted documents for
/// text extraction, scanned pages, mixed documents, encryption, and outline cases.
enum TestPDFBuilder {
    static func digitalPDF(
        pages: [String],
        title: String? = "Fixture",
        author: String? = "PDFKitAudio Tests"
    ) throws -> Data {
        try quartzPDF(
            pages: pages,
            title: title,
            author: author,
            userPassword: nil,
            ownerPassword: nil
        )
    }

    static func encryptedPDF(
        pages: [String],
        userPassword: String = "reader",
        ownerPassword: String = "owner"
    ) throws -> Data {
        try quartzPDF(
            pages: pages,
            title: "Encrypted Fixture",
            author: "PDFKitAudio Tests",
            userPassword: userPassword,
            ownerPassword: ownerPassword
        )
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

    static func documentWithOutline(
        pages: [String],
        outline: [OutlineNode]
    ) throws -> PDFDocument {
        guard let document = PDFDocument(data: try digitalPDF(pages: pages)) else {
            throw FixtureError.couldNotCreatePDF
        }

        let root = PDFOutline()
        for (index, node) in outline.enumerated() {
            root.insertChild(try makeOutline(node, document: document), at: index)
        }
        document.outlineRoot = root
        return document
    }

    static func temporaryFile(data: Data, name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFKitAudioTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    struct OutlineNode {
        let title: String
        let pageIndex: Int
        let children: [OutlineNode]

        init(_ title: String, pageIndex: Int, children: [OutlineNode] = []) {
            self.title = title
            self.pageIndex = pageIndex
            self.children = children
        }
    }

    private static func quartzPDF(
        pages: [String],
        title: String?,
        author: String?,
        userPassword: String?,
        ownerPassword: String?
    ) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        var options: [CFString: Any] = [:]
        if let title { options[kCGPDFContextTitle] = title }
        if let author { options[kCGPDFContextAuthor] = author }
        if let userPassword { options[kCGPDFContextUserPassword] = userPassword }
        if let ownerPassword { options[kCGPDFContextOwnerPassword] = ownerPassword }

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(
                consumer: consumer,
                mediaBox: &mediaBox,
                options as CFDictionary
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

    private static func makeOutline(_ node: OutlineNode, document: PDFDocument) throws -> PDFOutline {
        guard node.pageIndex >= 0,
              node.pageIndex < document.pageCount,
              let page = document.page(at: node.pageIndex) else {
            throw FixtureError.invalidOutlinePage
        }

        let outline = PDFOutline()
        outline.label = node.title
        outline.destination = PDFDestination(page: page, at: .zero)
        for (index, child) in node.children.enumerated() {
            outline.insertChild(try makeOutline(child, document: document), at: index)
        }
        return outline
    }

    private static func draw(text: String, in context: CGContext, pageBounds: CGRect) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fixtureFont(size: 14),
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
                .font: fixtureFont(size: 32),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        )
        image.unlockFocus()
        return image
    }

    /// Public PostScript names embed predictably in generated PDFs. Private
    /// variable system-font names can be substituted on reload, changing glyph
    /// geometry and breaking source markers (notably underscores) across OS/SDKs.
    static func fixtureFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight >= .semibold ? "Helvetica-Bold" : "Helvetica"
        guard let font = NSFont(name: name, size: size) else {
            preconditionFailure("Missing standard fixture font: \(name)")
        }
        return font
    }

    enum FixtureError: Error {
        case couldNotCreatePDF
        case couldNotCreateScannedPage
        case invalidOutlinePage
    }
}
