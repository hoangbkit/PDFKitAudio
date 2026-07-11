import SwiftUI
import PDFKitAudio

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: PdfBook?
    @Published var selectedChapter: PdfChapter?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var viewMode: ViewMode = .plain
    @Published var searchText = ""
    @Published var ocrMode: OCROptions = .auto

    enum ViewMode: String, CaseIterable, Identifiable {
        case plain = "Plain Text"
        case pdf = "PDF Preview"
        case audiobook = "Audiobook Script"
        var id: String { rawValue }
    }

    var filteredChapters: [PdfChapter] {
        guard !searchText.isEmpty else { return book?.chapters ?? [] }
        return book?.chapters.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.plainText.localizedCaseInsensitiveContains(searchText)
        } ?? []
    }

    func load(url: URL) {
        isLoading = true
        errorMessage = nil
        Task.detached {
            do {
                let parser = PdfParser(ocrMode: await self.ocrMode)
                let result = try parser.parse(at: url)
                await MainActor.run {
                    self.book = result
                    self.selectedChapter = result.chapters.first
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    var segments: [AudiobookSegment] { book?.audiobookScript() ?? [] }
}
