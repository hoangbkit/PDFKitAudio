import Foundation
import PDFKit
import AppKit

public enum OCROptions: Sendable {
    case auto      // trigger only when page has little/no extractable text
    case always    // force OCR every page (best quality for scanned)
    case never     // never OCR, digital PDFs only
}

public final class PdfParser: @unchecked Sendable {
    private let ocrMode: OCROptions
    private let ocrThreshold: Int // chars below which we trigger OCR in auto mode

    public init(ocrMode: OCROptions = .auto, ocrThreshold: Int = 60) {
        self.ocrMode = ocrMode
        self.ocrThreshold = ocrThreshold
    }

    public func parse(at url: URL) throws -> PdfBook {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PdfError.fileNotFound }
        guard let doc = PDFDocument(url: url) else { throw PdfError.invalidPDF }
        return try parse(document: doc, fileURL: url)
    }

    public func parse(data: Data) throws -> PdfBook {
        guard let doc = PDFDocument(data: data) else { throw PdfError.invalidPDF }
        return try parse(document: doc, fileURL: nil)
    }

    private func parse(document: PDFDocument, fileURL: URL?) throws -> PdfBook {
        if document.isEncrypted || document.isLocked { throw PdfError.passwordProtected }

        let pageCount = document.pageCount
        let attrs = document.documentAttributes ?? [:]

        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fileURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"
        let authorString = attrs[PDFDocumentAttribute.authorAttribute] as? String
        let authors = authorString?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String
        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String
        let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        let modDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        let keywordsRaw = attrs[PDFDocumentAttribute.keywordsAttribute] as? String
        let keywords = keywordsRaw?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []

        // Keep the complete outline hierarchy as navigation metadata. Chapter
        // generation independently selects safe, non-overlapping boundaries.
        let toc = PdfTOCParser.parse(document: document)
        let isScannedOverall = PdfOCREngine.isScanned(document: document)

        let coverData: Data? = {
            guard let first = document.page(at: 0) else { return nil }
            let thumb = first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
            guard let tiff = thumb.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
        }()

        // Every source page produces exactly one page model. A missing PDFPage is
        // represented by an empty placeholder so downstream indexes never shift.
        var pages: [PdfPageContent] = []
        pages.reserveCapacity(pageCount)
        for pageIndex in 0..<pageCount {
            pages.append(extractPage(document.page(at: pageIndex), pageIndex: pageIndex))
        }

        let chapters = PdfChapterBuilder.build(toc: toc, pages: pages)

        let metadata = PdfMetadata(
            title: title,
            authors: authors,
            subject: subject,
            keywords: keywords,
            creator: creator,
            producer: producer,
            creationDate: creationDate,
            modificationDate: modDate,
            pageCount: pageCount,
            isScanned: isScannedOverall
        )

        return PdfBook(
            metadata: metadata,
            pages: pages,
            chapters: chapters,
            toc: toc,
            cover: coverData,
            fileURL: fileURL
        )
    }

    private func extractPage(_ page: PDFPage?, pageIndex: Int) -> PdfPageContent {
        guard let page else {
            return PdfPageContent(
                pageIndex: pageIndex,
                nativeText: "",
                text: "",
                extractionSource: .empty,
                confidence: 0
            )
        }

        let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var selectedText = nativeText
        var source: PdfExtractionSource = nativeText.isEmpty ? .empty : .native
        var confidence = nativeText.isEmpty ? 0.0 : 1.0

        if shouldRunOCR(nativeText: nativeText),
           let ocr = PdfOCREngine.recognize(page: page),
           !ocr.text.isEmpty,
           shouldPreferOCR(ocrText: ocr.text, nativeText: nativeText) {
            selectedText = ocr.text
            source = .ocr
            confidence = ocr.confidence
        }

        let cleanedText = PdfTextCleaner.clean(selectedText)
        if cleanedText.isEmpty {
            source = .empty
            confidence = 0
        }

        return PdfPageContent(
            pageIndex: pageIndex,
            nativeText: nativeText,
            text: cleanedText,
            extractionSource: source,
            confidence: confidence
        )
    }

    private func shouldRunOCR(nativeText: String) -> Bool {
        switch ocrMode {
        case .always:
            return true
        case .never:
            return false
        case .auto:
            return nativeText.count < ocrThreshold
        }
    }

    private func shouldPreferOCR(ocrText: String, nativeText: String) -> Bool {
        // Preserve the existing selection policy through Phase 2. Phase 3 will
        // make OCR selection richer and configurable.
        ocrText.count > nativeText.count * 2 || nativeText.count < ocrThreshold
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
