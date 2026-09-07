import Foundation
import PDFKitAudio
import SwiftUI

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: PdfBook?
    @Published var selectedChapter: PdfChapter?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var viewMode: ViewMode = .plain
    @Published var searchText = ""
    @Published var ocrMode: OCROptions = .auto

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var securityScopedURL: URL?

    enum ViewMode: String, CaseIterable, Identifiable {
        case plain = "Plain Text"
        case pdf = "PDF Preview"
        case audiobook = "Audiobook Script"

        var id: String { rawValue }
    }

    var filteredChapters: [PdfChapter] {
        guard !searchText.isEmpty else { return book?.chapters ?? [] }
        return book?.chapters.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.plainText.localizedCaseInsensitiveContains(searchText)
        } ?? []
    }

    var segments: [AudiobookSegment] {
        book?.audiobookScript() ?? []
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
        isLoading = true
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }

            let parser = PdfParser(configuration: PdfParserConfiguration(
                ocr: PdfOCRConfiguration(mode: mode)
            ))

            do {
                let result = try await parser.parseAsync(at: url)
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }

                book = result
                selectedChapter = result.chapters.first
                isLoading = false
            } catch is CancellationError {
                guard loadGeneration == generation else { return }
                isLoading = false
            } catch {
                guard loadGeneration == generation else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                releaseSecurityScopedURL()
            }
        }
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
