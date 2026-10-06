import Foundation
import PDFKit
import PDFKitAudio
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var model = DemoViewModel()
#if os(iOS)
    @State private var isImporting = false
#endif

    var body: some View {
#if os(macOS)
        macOSBody
#elseif os(iOS)
        iOSBody
#endif
    }

#if os(macOS)
    private var macOSBody: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.loadSamplePDF()
                } label: {
                    Label("Use Sample PDF", systemImage: "doc.text")
                }

                Button {
                    model.openPDFPanel()
                } label: {
                    Label("Pick PDF File", systemImage: "folder")
                }

                ocrPicker

                Button {
                    model.copyAllText()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(model.book == nil)
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(16)

            Divider()

            if let book = model.book {
                List(selection: $model.selectedChapterID) {
                    Section("Chapters") {
                        ForEach(book.chapters) { chapter in
                            chapterRow(chapter)
                                .tag(chapter.id)
                        }
                    }

                    if !book.tableOfContents.isEmpty {
                        Section("Outline") {
                            outlineRows(book)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let data = model.book?.coverImageData {
                CoverImage(data: data)
                    .frame(maxHeight: 180)
            }

            Text(model.title)
                .font(.title2.bold())
                .lineLimit(3)

            if let book = model.book {
                Text(book.metadata.authorString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                metadataSummary(book)
                provenanceSummary(book)
            }

            parseProgress
        }
    }
#endif

#if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            Group {
                if let book = model.book {
                    iOSDocumentView(book)
                } else {
                    emptyState
                }
            }
            .navigationTitle(model.book == nil ? "PDFKitAudio" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.loadSamplePDF()
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .accessibilityLabel("Use Sample PDF")

                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Pick PDF File")

                    Menu {
                        Picker("OCR", selection: $model.ocrMode) {
                            Text("Auto").tag(OCROptions.auto)
                            Text("Always").tag(OCROptions.always)
                            Text("Never").tag(OCROptions.never)
                        }
                    } label: {
                        Image(systemName: "text.viewfinder")
                    }
                    .accessibilityLabel("OCR Mode")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            model.load(url: url)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func iOSDocumentView(_ book: PdfBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let data = book.coverImageData {
                    CoverImage(data: data)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    if !book.metadata.authorString.isEmpty {
                        Text(book.metadata.authorString)
                            .foregroundStyle(.secondary)
                    }

                    metadataSummary(book)
                    provenanceSummary(book)
                }

                parseProgress

                Divider()

                chapterPicker(book)

                Picker("View", selection: $model.viewMode) {
                    ForEach(DemoViewModel.ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if let chapter = model.selectedChapter {
                    iOSChapterContent(chapter)
                }

                if !book.tableOfContents.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Outline")
                            .font(.headline)
                        outlineRows(book)
                    }
                }

                Button {
                    model.copyAllText()
                } label: {
                    Label("Copy All Text", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private func chapterPicker(_ book: PdfBook) -> some View {
        Menu {
            ForEach(book.chapters) { chapter in
                Button {
                    model.selectedChapterID = chapter.id
                } label: {
                    Text(chapter.title)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chapter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.selectedChapter?.title ?? "Select Chapter")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iOSChapterContent(_ chapter: PdfChapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pages \(chapter.pageRange.lowerBound + 1)–\(chapter.pageRange.upperBound + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.copySelectedChapterText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            switch model.viewMode {
            case .plain:
                Text(chapter.plainText)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .pdf:
                if let url = model.sourceURL {
                    PDFKitView(url: url, pageIndex: chapter.pageRange.lowerBound)
                        .frame(minHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

            case .audiobook:
                let chunks = chapter.ttsChunks()
                VStack(alignment: .leading, spacing: 12) {
                    Text("TTS Chunks · \(chunks.count)")
                        .font(.headline)

                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Segment \(index + 1) · \(chunk.count) chars")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(chunk)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
#endif

    private var ocrPicker: some View {
        Picker("OCR", selection: $model.ocrMode) {
            Text("Auto").tag(OCROptions.auto)
            Text("Always").tag(OCROptions.always)
            Text("Never").tag(OCROptions.never)
        }
        .pickerStyle(.menu)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Open a PDF")
                .font(.headline)
            Text("Inspect native text, selective Vision OCR, layout reconstruction, chapters, and TTS-ready output.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("Use Sample PDF") {
                    model.loadSamplePDF()
                }
                .buttonStyle(.borderedProminent)

                Button("Pick PDF File") {
                    openPDF()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private func chapterRow(_ chapter: PdfChapter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chapter.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("p.\(chapter.pageRange.lowerBound + 1)–\(chapter.pageRange.upperBound + 1)")
                if chapter.isOCRSourced {
                    Text("OCR \(Int(chapter.confidence * 100))%")
                        .foregroundStyle(.orange)
                }
                Text("\(chapter.wordCount) words")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func outlineRows(_ book: PdfBook) -> some View {
        ForEach(book.tableOfContents.prefix(30)) { item in
            Button {
                model.selectOutlineItem(item)
            } label: {
                HStack {
                    Text(item.title)
                        .lineLimit(1)
                    Spacer()
                    if let page = item.pageIndex {
                        Text("\(page + 1)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func metadataSummary(_ book: PdfBook) -> some View {
        HStack(spacing: 12) {
            Label("\(book.metadata.pageCount)", systemImage: "doc")
            Label("\(book.chapters.count)", systemImage: "list.bullet.rectangle")
            Label("\(book.totalWords)", systemImage: "text.word.spacing")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func provenanceSummary(_ book: PdfBook) -> some View {
        Text("Native \(model.nativePageCount) · OCR \(book.ocrPageCount) · Empty \(model.emptyPageCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var parseProgress: some View {
        if model.isParsing {
            VStack(alignment: .leading, spacing: 5) {
                if let fraction = model.progress?.pageFractionCompleted {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

#if os(macOS)
    private var detail: some View {
        Group {
            if let chapter = model.selectedChapter {
                VStack(spacing: 0) {
                    detailHeader(chapter)
                    Divider()

                    switch model.viewMode {
                    case .plain:
                        ScrollView {
                            Text(chapter.plainText)
                                .font(.system(.body, design: .serif))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                        }

                    case .pdf:
                        if let url = model.sourceURL {
                            PDFKitView(url: url, pageIndex: chapter.pageRange.lowerBound)
                        } else {
                            ContentUnavailableView("No PDF", systemImage: "doc")
                        }

                    case .audiobook:
                        audiobookView(chapter)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Chapter Selected",
                    systemImage: "doc.text",
                    description: Text("Open a PDF to inspect parsed output.")
                )
            }
        }
    }

    private func detailHeader(_ chapter: PdfChapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .font(.title.bold())
                        .lineLimit(2)
                    Text("Pages \(chapter.pageRange.lowerBound + 1)–\(chapter.pageRange.upperBound + 1) · \(chapter.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.copySelectedChapterText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            Picker("View", selection: $model.viewMode) {
                ForEach(DemoViewModel.ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
    }

    private func audiobookView(_ chapter: PdfChapter) -> some View {
        let chunks = chapter.ttsChunks()
        return List {
            Section("TTS Chunks · \(chunks.count)") {
                ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Segment \(index + 1) · \(chunk.count) chars")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(chunk)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
#endif

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func openPDF() {
#if os(macOS)
        model.openPDFPanel()
#else
        isImporting = true
#endif
    }
}

private struct CoverImage: View {
    let data: Data

    var body: some View {
#if os(macOS)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
#elseif os(iOS)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
#endif
    }
}

#if os(macOS)
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let page = view.document?.page(at: pageIndex) {
            view.go(to: page)
        }
    }
}
#elseif os(iOS)
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let page = view.document?.page(at: pageIndex) {
            view.go(to: page)
        }
    }
}
#endif

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
