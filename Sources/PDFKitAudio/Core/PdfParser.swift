import AppKit
import Foundation
import PDFKit

public final class PdfParser: @unchecked Sendable {
    typealias OCRRecognizer = (PDFPage, PdfOCRConfiguration) -> PdfOCREngine.OCRResult?

    public let ocrConfiguration: PdfOCRConfiguration
    public let cleanupConfiguration: PdfCleanupConfiguration
    private let ocrRecognizer: OCRRecognizer

    /// Backward-compatible initializer for existing callers.
    public init(
        ocrMode: OCROptions = .auto,
        ocrThreshold: Int = 60,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault
    ) {
        let configuration = PdfOCRConfiguration(
            mode: ocrMode,
            nativeTextThreshold: ocrThreshold
        )
        self.ocrConfiguration = configuration
        self.cleanupConfiguration = cleanupConfiguration
        self.ocrRecognizer = { page, configuration in
            PdfOCREngine.recognize(page: page, configuration: configuration)
        }
    }

    /// Preferred initializer for multilingual OCR and cleanup configuration.
    public init(
        ocrConfiguration: PdfOCRConfiguration,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault
    ) {
        self.ocrConfiguration = ocrConfiguration
        self.cleanupConfiguration = cleanupConfiguration
        self.ocrRecognizer = { page, configuration in
            PdfOCREngine.recognize(page: page, configuration: configuration)
        }
    }

    /// Test seam that keeps OCR invocation/selection behavior directly verifiable.
    init(
        ocrConfiguration: PdfOCRConfiguration,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault,
        ocrRecognizer: @escaping OCRRecognizer
    ) {
        self.ocrConfiguration = ocrConfiguration
        self.cleanupConfiguration = cleanupConfiguration
        self.ocrRecognizer = ocrRecognizer
    }

    public func parse(at url: URL) throws -> PdfBook {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PdfError.fileNotFound
        }
        guard let document = PDFDocument(url: url) else {
            throw PdfError.invalidPDF
        }
        return try parse(document: document, fileURL: url)
    }

    public func parse(data: Data) throws -> PdfBook {
        guard let document = PDFDocument(data: data) else {
            throw PdfError.invalidPDF
        }
        return try parse(document: document, fileURL: nil)
    }

    private func parse(document: PDFDocument, fileURL: URL?) throws -> PdfBook {
        if document.isEncrypted || document.isLocked {
            throw PdfError.passwordProtected
        }

        let pageCount = document.pageCount
        let attributes = document.documentAttributes ?? [:]

        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fileURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"
        let authorString = attributes[PDFDocumentAttribute.authorAttribute] as? String
        let authors = authorString?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String
        let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String
        let creationDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        let modificationDate = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date
        let keywordsRaw = attributes[PDFDocumentAttribute.keywordsAttribute] as? String
        let keywords = keywordsRaw?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []

        // Keep the complete outline hierarchy as navigation metadata. Chapter
        // generation independently selects safe, non-overlapping boundaries.
        let tableOfContents = PdfTOCParser.parse(document: document)
        let isScannedOverall = PdfOCREngine.isScanned(document: document)

        let coverData: Data? = {
            guard let first = document.page(at: 0) else { return nil }
            let thumbnail = first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
            guard let tiff = thumbnail.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
        }()

        // Page-local normalization happens during extraction. Once all pages are
        // available, a separate document-level pass can safely detect running
        // headers/footers and sequential pagination without guessing from one page.
        var pages: [PdfPageContent] = []
        pages.reserveCapacity(pageCount)
        for pageIndex in 0..<pageCount {
            pages.append(extractPage(document.page(at: pageIndex), pageIndex: pageIndex))
        }
        pages = PdfDocumentTextCleaner.clean(
            pages,
            configuration: cleanupConfiguration
        )

        let chapters = PdfChapterBuilder.build(toc: tableOfContents, pages: pages)
        let metadata = PdfMetadata(
            title: title,
            authors: authors,
            subject: subject,
            keywords: keywords,
            creator: creator,
            producer: producer,
            creationDate: creationDate,
            modificationDate: modificationDate,
            pageCount: pageCount,
            isScanned: isScannedOverall,
            detectedLanguage: nil
        )

        return PdfBook(
            metadata: metadata,
            pages: pages,
            chapters: chapters,
            toc: tableOfContents,
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

        if PdfOCRPolicy.shouldRunOCR(
            nativeText: nativeText,
            configuration: ocrConfiguration
        ), let ocrResult = ocrRecognizer(page, ocrConfiguration),
           PdfOCRPolicy.shouldPreferOCR(
               ocrText: ocrResult.text,
               confidence: ocrResult.confidence,
               nativeText: nativeText,
               configuration: ocrConfiguration
           ) {
            selectedText = ocrResult.text
            source = .ocr
            confidence = ocrResult.confidence
        }

        let cleanedText = PdfTextCleaner.cleanPage(
            selectedText,
            configuration: cleanupConfiguration
        )
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
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
