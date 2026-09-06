import AppKit
import Foundation
import PDFKit

public final class PdfParser: @unchecked Sendable {
    typealias OCRRecognizer = (PDFPage, PdfOCRConfiguration) -> PdfOCREngine.OCRResult?
    public typealias ProgressHandler = @Sendable (PdfParseProgress) -> Void

    public let ocrConfiguration: PdfOCRConfiguration
    public let cleanupConfiguration: PdfCleanupConfiguration
    public let extractCoverImage: Bool
    private let ocrRecognizer: OCRRecognizer

    /// Backward-compatible initializer for existing callers.
    public init(
        ocrMode: OCROptions = .auto,
        ocrThreshold: Int = 60,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault,
        extractCoverImage: Bool = true
    ) {
        let configuration = PdfOCRConfiguration(
            mode: ocrMode,
            nativeTextThreshold: ocrThreshold
        )
        self.ocrConfiguration = configuration
        self.cleanupConfiguration = cleanupConfiguration
        self.extractCoverImage = extractCoverImage
        self.ocrRecognizer = { page, configuration in
            PdfOCREngine.recognize(page: page, configuration: configuration)
        }
    }

    /// Preferred initializer for multilingual OCR and cleanup configuration.
    public init(
        ocrConfiguration: PdfOCRConfiguration,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault,
        extractCoverImage: Bool = true
    ) {
        self.ocrConfiguration = ocrConfiguration
        self.cleanupConfiguration = cleanupConfiguration
        self.extractCoverImage = extractCoverImage
        self.ocrRecognizer = { page, configuration in
            PdfOCREngine.recognize(page: page, configuration: configuration)
        }
    }

    /// Test seam that keeps OCR invocation/selection behavior directly verifiable.
    init(
        ocrConfiguration: PdfOCRConfiguration,
        cleanupConfiguration: PdfCleanupConfiguration = .audiobookDefault,
        extractCoverImage: Bool = true,
        ocrRecognizer: @escaping OCRRecognizer
    ) {
        self.ocrConfiguration = ocrConfiguration
        self.cleanupConfiguration = cleanupConfiguration
        self.extractCoverImage = extractCoverImage
        self.ocrRecognizer = ocrRecognizer
    }

    // MARK: - Synchronous API

    /// Synchronous compatibility API.
    ///
    /// Prefer the async overload for UI-driven or cancellable imports. This
    /// method intentionally does not inherit Swift task cancellation semantics.
    public func parse(at url: URL) throws -> PdfBook {
        try parseFile(at: url, control: .synchronous)
    }

    /// Synchronous compatibility API.
    public func parse(data: Data) throws -> PdfBook {
        try parseData(data, control: .synchronous)
    }

    // MARK: - Asynchronous API

    /// Parses a PDF without requiring callers to move blocking PDFKit/Vision work
    /// off their actor manually.
    ///
    /// The parser keeps PDFKit page access serial and checks Swift task
    /// cancellation between page-sized operations. Progress callbacks execute on
    /// the parser task's executor; UI callers should hop to `MainActor` before
    /// mutating UI state.
    public func parse(
        at url: URL,
        progress: ProgressHandler? = nil
    ) async throws -> PdfBook {
        try Task.checkCancellation()
        return try parseFile(at: url, control: .asynchronous(progress: progress))
    }

    /// Data equivalent of the async URL API.
    public func parse(
        data: Data,
        progress: ProgressHandler? = nil
    ) async throws -> PdfBook {
        try Task.checkCancellation()
        return try parseData(data, control: .asynchronous(progress: progress))
    }

    // MARK: - Shared parse core

    private func parseFile(at url: URL, control: ParseControl) throws -> PdfBook {
        try control.checkpoint()
        control.report(stage: .loading, completedPages: 0, totalPages: 0)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PdfError.fileNotFound
        }
        try control.checkpoint()
        guard let document = PDFDocument(url: url) else {
            throw PdfError.invalidPDF
        }
        try control.checkpoint()
        return try parse(document: document, fileURL: url, control: control)
    }

    private func parseData(_ data: Data, control: ParseControl) throws -> PdfBook {
        try control.checkpoint()
        control.report(stage: .loading, completedPages: 0, totalPages: 0)

        guard let document = PDFDocument(data: data) else {
            throw PdfError.invalidPDF
        }
        try control.checkpoint()
        return try parse(document: document, fileURL: nil, control: control)
    }

    private func parse(
        document: PDFDocument,
        fileURL: URL?,
        control: ParseControl
    ) throws -> PdfBook {
        try control.checkpoint()
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

        // Keep PDFKit access confined to this single parse execution. Pages are
        // intentionally processed one at a time rather than concurrently because
        // PDFDocument/PDFPage do not provide a strong cross-thread safety contract.
        control.report(stage: .extracting, completedPages: 0, totalPages: pageCount)
        var pages: [PdfPageContent] = []
        pages.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            try control.checkpoint()
            let content = try autoreleasepool {
                try extractPage(
                    document.page(at: pageIndex),
                    pageIndex: pageIndex,
                    control: control
                )
            }
            pages.append(content)
            control.report(
                stage: .extracting,
                completedPages: pageIndex + 1,
                totalPages: pageCount
            )
        }

        try control.checkpoint()
        control.report(stage: .cleaning, completedPages: pageCount, totalPages: pageCount)
        pages = PdfDocumentTextCleaner.clean(
            pages,
            configuration: cleanupConfiguration
        )

        try control.checkpoint()
        control.report(stage: .buildingChapters, completedPages: pageCount, totalPages: pageCount)

        // Parse navigation only after page extraction so large outline trees do
        // not delay the first useful page result/progress update.
        let tableOfContents = PdfTOCParser.parse(document: document)
        try control.checkpoint()
        let chapters = PdfChapterBuilder.build(toc: tableOfContents, pages: pages)
        let isScannedOverall = isLikelyScanned(pages: pages)

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

        try control.checkpoint()
        control.report(stage: .finishing, completedPages: pageCount, totalPages: pageCount)
        let coverData = extractCoverImage ? extractCover(from: document) : nil
        try control.checkpoint()

        let book = PdfBook(
            metadata: metadata,
            pages: pages,
            chapters: chapters,
            toc: tableOfContents,
            cover: coverData,
            fileURL: fileURL
        )

        control.report(stage: .finished, completedPages: pageCount, totalPages: pageCount)
        return book
    }

    private func extractPage(
        _ page: PDFPage?,
        pageIndex: Int,
        control: ParseControl
    ) throws -> PdfPageContent {
        try control.checkpoint()
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
        ) {
            // One OCR page is the maximum non-interruptible unit. Cancellation is
            // checked immediately before rendering/Vision work and again as soon
            // as the recognizer returns.
            try control.checkpoint()
            let ocrResult = ocrRecognizer(page, ocrConfiguration)
            try control.checkpoint()

            if let ocrResult,
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

    private func extractCover(from document: PDFDocument) -> Data? {
        autoreleasepool {
            guard let first = document.page(at: 0) else { return nil }
            let thumbnail = first.thumbnail(
                of: CGSize(width: 600, height: 800),
                for: .mediaBox
            )
            guard let tiff = thumbnail.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(
                using: .jpeg,
                properties: [:]
            )
        }
    }

    /// Reuses the original lightweight scanned-document heuristic without
    /// touching PDFKit pages a second time after extraction.
    private func isLikelyScanned(
        pages: [PdfPageContent],
        sampleCount: Int = 5
    ) -> Bool {
        guard !pages.isEmpty, sampleCount > 0 else { return false }

        let step = max(1, pages.count / sampleCount)
        var weakNativePages = 0
        var checked = 0
        for index in stride(from: 0, to: pages.count, by: step).prefix(sampleCount) {
            if pages[index].nativeText.count < 30 {
                weakNativePages += 1
            }
            checked += 1
        }

        return checked > 0 && Double(weakNativePages) / Double(checked) >= 0.6
    }
}

private struct ParseControl {
    let progress: PdfParser.ProgressHandler?
    let checkCancellation: () throws -> Void

    static let synchronous = ParseControl(
        progress: nil,
        checkCancellation: {}
    )

    static func asynchronous(
        progress: PdfParser.ProgressHandler?
    ) -> ParseControl {
        ParseControl(
            progress: progress,
            checkCancellation: {
                try Task.checkCancellation()
            }
        )
    }

    func checkpoint() throws {
        try checkCancellation()
    }

    func report(
        stage: PdfParseStage,
        completedPages: Int,
        totalPages: Int
    ) {
        progress?(PdfParseProgress(
            stage: stage,
            completedPages: completedPages,
            totalPages: totalPages
        ))
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
