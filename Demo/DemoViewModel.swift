import Combine
import Foundation
import PDFKitAudio
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class DemoViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var book: PdfBook?
    @Published var selectedChapterID: String?
    @Published var isParsing = false
    @Published var progress: PdfParseProgress?
    @Published var errorMessage: String?
    @Published var viewMode: ViewMode = .plain
    @Published var ocrMode: OCROptions = .auto

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var securityScopedURL: URL?

    enum ViewMode: String, CaseIterable, Identifiable {
        case plain = "Text"
        case pdf = "PDF"
        case audiobook = "Audio Script"

        var id: String { rawValue }
    }

    var selectedChapter: PdfChapter? {
        guard let selectedChapterID else { return book?.chapters.first }
        return book?.chapters.first { $0.id == selectedChapterID }
    }

    var title: String {
        book?.metadata.title
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "No PDF Loaded"
    }

    var nativePageCount: Int {
        book?.pages.filter { $0.extractionSource == .native }.count ?? 0
    }

    var emptyPageCount: Int {
        book?.emptyPageCount ?? 0
    }

    var progressLabel: String {
        guard let progress else { return "Preparing…" }
        switch progress.stage {
        case .loading:
            return "Loading PDF…"
        case .extracting:
            return "Extracting page \(progress.completedPages) of \(progress.totalPages)…"
        case .cleaning:
            return "Cleaning document text…"
        case .buildingChapters:
            return "Building chapters…"
        case .finishing:
            return "Finishing…"
        case .finished:
            return "Finished"
        }
    }

#if os(macOS)
    func openPDFPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open PDF"
        panel.message = "Choose a PDF to inspect extraction, OCR, layout, and audiobook output."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }
#endif

    func loadSamplePDF() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "pdf") else {
            errorMessage = "Bundled sample PDF is missing."
            return
        }
        load(url: url)
    }

    func load(url: URL) {
        loadTask?.cancel()
        releaseSecurityScopedURL()

        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        let generation = UUID()
        let mode = ocrMode
        loadGeneration = generation
        sourceURL = url
        book = nil
        selectedChapterID = nil
        isParsing = true
        progress = nil
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }

            let parser = PdfParser(configuration: PdfParserConfiguration(
                ocr: PdfOCRConfiguration(mode: mode)
            ))

            do {
                let result = try await parser.parse(at: url, progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.progress = update
                    }
                })
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }

                book = result
                selectedChapterID = result.chapters.first?.id
                isParsing = false
            } catch is CancellationError {
                guard loadGeneration == generation else { return }
                isParsing = false
            } catch {
                guard loadGeneration == generation else { return }
                errorMessage = error.localizedDescription
                isParsing = false
            }
        }
    }

    func selectOutlineItem(_ item: PdfTOCItem) {
        guard let pageIndex = item.pageIndex,
              let chapter = book?.chapters.first(where: { $0.pageRange.contains(pageIndex) }) else {
            return
        }
        selectedChapterID = chapter.id
    }

    func copySelectedChapterText() {
        guard let text = selectedChapter?.plainText, !text.isEmpty else { return }
        copy(text)
    }

    func copyAllText() {
        guard let text = book?.allPlainText(), !text.isEmpty else { return }
        copy(text)
    }

    private func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = text
#endif
    }

    private func releaseSecurityScopedURL() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    deinit {
        loadTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}
