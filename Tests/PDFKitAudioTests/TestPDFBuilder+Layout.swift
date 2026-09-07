import AppKit
import CoreGraphics
import Foundation
import PDFKit

extension TestPDFBuilder {
    /// Builds a deterministic multi-page PDF from explicit normalized layout boxes.
    /// Native and scanned pages can be mixed in the same document.
    static func layoutPDF(_ fixture: TestLayoutFixture) throws -> Data {
        let document = PDFDocument()

        for (index, pageSpec) in fixture.pages.enumerated() {
            let page: PDFPage
            switch pageSpec.rendering {
            case .native:
                page = try nativeLayoutPage(pageSpec)
            case .scanned:
                page = try scannedLayoutPage(pageSpec)
            }
            document.insert(page, at: index)
        }

        guard let data = document.dataRepresentation() else {
            throw FixtureError.couldNotCreatePDF
        }
        return data
    }

    /// Creates a document by repeating the first page of a fixture. Useful for
    /// opt-in stress/benchmark harnesses without storing large binaries.
    static func repeatedLayoutPDF(_ fixture: TestLayoutFixture, pageCount: Int) throws -> Data {
        guard let page = fixture.pages.first, pageCount > 0 else {
            throw FixtureError.couldNotCreatePDF
        }
        let repeated = TestLayoutFixture(
            name: "\(fixture.name)-x\(pageCount)",
            category: fixture.category,
            support: fixture.support,
            pages: Array(repeating: page, count: pageCount),
            expectedMarkerOrder: fixture.expectedMarkerOrder,
            notes: "Repeated benchmark fixture"
        )
        return try layoutPDF(repeated)
    }

    private static func nativeLayoutPage(_ spec: TestLayoutPage) throws -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: spec.size)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotCreatePDF
        }

        context.beginPDFPage(nil)
        drawLayoutBoxes(spec.boxes, in: context, pageSize: spec.size, scale: 1)
        context.endPDFPage()
        context.closePDF()

        guard let onePageDocument = PDFDocument(data: data as Data),
              let page = onePageDocument.page(at: 0)?.copy() as? PDFPage else {
            throw FixtureError.couldNotCreatePDF
        }

        applyPageGeometry(spec, to: page)
        return page
    }

    private static func scannedLayoutPage(_ spec: TestLayoutPage) throws -> PDFPage {
        // Render at 2x for stable Vision OCR while preserving the intended page
        // dimensions on the resulting PDFPage.
        let scale: CGFloat = 2
        let imageSize = NSSize(width: spec.size.width * scale, height: spec.size.height * scale)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        guard let cgContext = NSGraphicsContext.current?.cgContext else {
            throw FixtureError.couldNotCreateScannedPage
        }
        drawLayoutBoxes(spec.boxes, in: cgContext, pageSize: spec.size, scale: scale)

        guard let page = PDFPage(image: image) else {
            throw FixtureError.couldNotCreateScannedPage
        }
        applyPageGeometry(spec, to: page)
        return page
    }

    private static func applyPageGeometry(_ spec: TestLayoutPage, to page: PDFPage) {
        let media = CGRect(origin: .zero, size: spec.size)
        page.setBounds(media, for: .mediaBox)

        if spec.cropInsets != .zero {
            let crop = CGRect(
                x: spec.cropInsets.left,
                y: spec.cropInsets.bottom,
                width: max(1, spec.size.width - spec.cropInsets.left - spec.cropInsets.right),
                height: max(1, spec.size.height - spec.cropInsets.top - spec.cropInsets.bottom)
            )
            page.setBounds(crop, for: .cropBox)
        } else {
            page.setBounds(media, for: .cropBox)
        }

        page.rotation = normalizedRotation(spec.rotation)
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        let normalized = rotation % 360
        return normalized >= 0 ? normalized : normalized + 360
    }

    private static func drawLayoutBoxes(
        _ boxes: [TestLayoutTextBox],
        in context: CGContext,
        pageSize: CGSize,
        scale: CGFloat
    ) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphicsContext

        for box in boxes {
            let rect = drawingRect(for: box.rect, pageSize: pageSize, scale: scale)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = box.alignment
            paragraph.lineBreakMode = .byWordWrapping

            let font = NSFont.systemFont(
                ofSize: box.fontSize * scale,
                weight: box.fontWeight
            )
            NSString(string: box.text).draw(
                in: rect,
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraph
                ]
            )
        }
    }

    /// Fixture geometry is stored in normalized top-left coordinates. AppKit's
    /// non-flipped PDF drawing context has a bottom-left origin, so Y is inverted.
    private static func drawingRect(
        for normalized: CGRect,
        pageSize: CGSize,
        scale: CGFloat
    ) -> CGRect {
        let width = pageSize.width * scale
        let height = pageSize.height * scale
        return CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height
        )
    }
}
