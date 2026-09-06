import SwiftUI
import PDFKitAudio
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = BookViewModel()
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            chapterList
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("Import PDF", systemImage: "doc.richtext") }
                    .keyboardShortcut("o", modifiers: .command)
            }
            if vm.book != nil {
                ToolbarItem {
                    Picker("View", selection: $vm.viewMode) {
                        ForEach(BookViewModel.ViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented).frame(width: 380)
                }
                ToolbarItem {
                    Picker("OCR", selection: $vm.ocrMode) {
                        Text("Auto").tag(OCROptions.auto)
                        Text("Always").tag(OCROptions.always)
                        Text("Never").tag(OCROptions.never)
                    }.pickerStyle(.menu).frame(width: 120)
                }
                ToolbarItem {
                    Button { exportText() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                vm.load(url: url)
            }
        }
        .overlay { if vm.isLoading { loadingOverlay } }
        .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let book = vm.book {
                VStack(alignment: .leading, spacing: 12) {
                    if let data = book.coverImageData, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(radius: 4)
                    }
                    Text(book.metadata.title).font(.title3).bold().lineLimit(3)
                    Text(book.metadata.authorString).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Pages", value: "\(book.metadata.pageCount)")
                    LabeledContent("Chapters", value: "\(book.chapters.count)")
                    LabeledContent("Words", value: "\(book.totalWords)")
                    LabeledContent("Scanned", value: book.metadata.isScanned ? "Yes" : "No")
                    if book.ocrPageCount > 0 { LabeledContent("OCR Pages", value: "\(book.ocrPageCount)") }
                    LabeledContent("Reading", value: "~\(book.estimatedReadingMinutes) min")
                    if !book.tableOfContents.isEmpty {
                        Divider()
                        Text("Outline").font(.headline)
                        ForEach(book.tableOfContents.prefix(25)) { item in
                            Button(item.title) {
                                if let pageIndex = item.pageIndex,
                                   let chapter = book.chapters.first(where: { $0.pageRange.contains(pageIndex) }) {
                                    vm.selectedChapter = chapter
                                }
                            }.buttonStyle(.link).font(.caption).lineLimit(1)
                        }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No PDF loaded").font(.headline)
                    Text("Import a PDF. Auto-OCR runs only when native text looks insufficient, with automatic language detection by default.").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout).padding(.horizontal)
                    Button("Import PDF") { showImporter = true }.buttonStyle(.borderedProminent)
                }.padding(24)
            }
        }.navigationSplitViewColumnWidth(min: 260, ideal: 320)
    }

    private var chapterList: some View {
        VStack(spacing: 0) {
            if vm.book != nil {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $vm.searchText).textFieldStyle(.plain)
                    if !vm.searchText.isEmpty { Button { vm.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.padding(8).background(.bar, in: RoundedRectangle(cornerRadius: 8)).padding()
            }
            List(vm.filteredChapters, id: \.self, selection: $vm.selectedChapter) { ch in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ch.title).font(.body).lineLimit(2)
                    HStack(spacing: 6) {
                        Text("p.\(ch.pageRange.lowerBound+1)-\(ch.pageRange.upperBound+1)").font(.caption2).padding(3).background(.quaternary, in: Capsule())
                        if ch.isOCRSourced { Text("OCR \(Int(ch.confidence*100))%").font(.caption2).foregroundStyle(.orange) }
                        Text("\(ch.wordCount) w").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical,2).tag(ch)
            }.listStyle(.sidebar)
        }.navigationSplitViewColumnWidth(min: 280, ideal: 340)
    }

    private var detailView: some View {
        Group {
            if let ch = vm.selectedChapter {
                switch vm.viewMode {
                case .plain:
                    ScrollView { Text(ch.plainText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(28).font(.system(.body, design: .serif)) }
                case .pdf:
                    if let url = vm.book?.fileURL { PDFKitView(url: url, pageIndex: ch.pageRange.lowerBound) } else { Text("No preview") }
                case .audiobook:
                    audiobookView(for: ch)
                }
            } else if let book = vm.book {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Audiobook Script • \(vm.segments.count) segments").font(.title2).bold()
                        Text("Ready for TTS. Auto-OCR supplied text for \(book.ocrPageCount) pages.").foregroundStyle(.secondary)
                        Divider()
                        ForEach(vm.segments.prefix(60)) { seg in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(seg.chapterTitle).font(.caption).bold().foregroundStyle(.secondary); Spacer(); Text("\(seg.text.count) chars").font(.caption2).foregroundStyle(.secondary) }
                                Text(seg.text).font(.callout).textSelection(.enabled)
                                if seg.confidence < 0.85 { Text("Low confidence \(Int(seg.confidence*100))% — review OCR").font(.caption2).foregroundStyle(.orange) }
                                Divider()
                            }
                        }
                    }.padding(28)
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc", description: Text("Import a PDF and pick a chapter"))
            }
        }.navigationTitle(vm.selectedChapter?.title ?? vm.book?.metadata.title ?? "PDFKitAudio Demo")
    }

    private func audiobookView(for chapter: PdfChapter) -> some View {
        let chunks = chapter.ttsChunks()
        return List {
            Section("TTS Chunks — \(chunks.count) segments") {
                ForEach(Array(chunks.enumerated()), id: \.offset) { idx, chunk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Segment \(idx+1)").font(.caption).bold()
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chunk, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                        }
                        Text(chunk).font(.callout).textSelection(.enabled)
                    }.padding(.vertical,6)
                }
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack { Color.black.opacity(0.15).ignoresSafeArea(); VStack(spacing:12){ ProgressView().scaleEffect(1.3); Text("Parsing PDF — OCR auto when needed…").font(.headline) }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }

    private func exportText() {
        guard let book = vm.book else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "\(book.metadata.title).txt"
        if panel.runModal() == .OK, let url = panel.url { try? book.allPlainText().write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL; let pageIndex: Int
    func makeNSView(context: Context) -> PDFView { let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; return v }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url { nsView.document = PDFDocument(url: url) }
        if let page = nsView.document?.page(at: pageIndex) { nsView.go(to: page) }
    }
}
