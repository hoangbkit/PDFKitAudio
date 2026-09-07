# PDFKitAudio

Lightweight PDF extraction and audiobook-oriented text preparation for macOS 14+.

PDFKitAudio is a standalone, **macOS-only** Swift package. It is designed for desktop document-to-audio workflows where imports, OCR, and downstream synthesis may run for a long time. The package does not declare iOS/iPadOS support.

The parser uses PDFKit native text first and selectively falls back to Vision OCR. It intentionally avoids heavyweight document-understanding models.

> [!WARNING]
> **Public, but not maintained as a full OSS project.** This repository is public so the code can be reused, inspected, and referenced, but it is primarily maintained for the author's own projects. There is no guarantee of community support, issue/PR response times, semantic-versioning stability, or long-term API compatibility. If you depend on it in another project, pin a known-good commit or tag and review upgrades before adopting them.

## Installation

### Xcode

In Xcode, choose **File → Add Package Dependencies…** and add:

```text
https://github.com/hoangbkit/PDFKitAudio.git
```

Add the `PDFKitAudio` product to your macOS target.

### Package.swift

You can also add the package directly to a SwiftPM manifest. Until you choose a release/tag to pin, a branch dependency is the simplest way to follow the repository:

```swift
let package = Package(
    dependencies: [
        .package(
            url: "https://github.com/hoangbkit/PDFKitAudio.git",
            branch: "master"
        )
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: ["PDFKitAudio"]
        )
    ]
)
```

For production use, prefer pinning a known-good tag or commit instead of automatically following `master`.

## Basic usage

Import the package and parse a PDF URL:

```swift
import PDFKitAudio

let parser = PdfParser()
let book = try await parser.parseAsync(at: pdfURL)

print(book.metadata.title ?? "Untitled")
print("Pages: \(book.pages.count)")
print("Chapters: \(book.chapters.count)")

for chapter in book.chapters {
    print(chapter.title)
    print(chapter.plainText)
}
```

`PdfBook.pages` is the canonical ordered page output. Each `PdfPageContent` records its source page index and whether the selected text came from native PDF text, Vision OCR, or an empty page.

For new code that needs explicit behavior, configure the parser through `PdfParserConfiguration`:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    ocr: PdfOCRConfiguration(mode: .auto),
    cleanup: .audiobookDefault,
    extractCoverImage: false,
    retainNativeText: false
))

let book = try await parser.parseAsync(at: pdfURL)
```

`PdfParser()`, `PdfParser(ocrMode:)`, the OCR-specific initializer, and the synchronous `parse(at:)` / `parse(data:)` methods remain available for existing and simple callers.

`retainNativeText` controls whether raw PDFKit extraction is retained in `PdfPageContent.nativeText` after parsing. Set it to `false` for large or bulk imports when downstream diagnostics do not need the rejected native source. Selected text, extraction provenance, page indexes, and scanned-document metadata remain intact.

## OCR

Default parsing keeps healthy digital PDFs on the native fast path. Pages with missing, very short, or suspicious native text become OCR candidates.

Vision automatic language detection is enabled by default; PDFKitAudio does not hard-code English. Callers that need tighter control can provide explicit recognition languages and behavior:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    ocr: PdfOCRConfiguration(
        mode: .auto,
        recognitionLanguages: ["vi-VN", "en-US"],
        automaticallyDetectsLanguage: false,
        recognitionLevel: .accurate
    )
))
```

OCR modes are:

- `.auto` — use PDFKit first and run Vision only for pages whose native extraction is missing or looks unreliable.
- `.never` — never invoke Vision OCR.
- `.always` — attempt Vision OCR on every page, while still keeping native text when it is the better result.

Running OCR does not automatically replace native PDF text. PDFKitAudio keeps the native result when OCR is empty, low-confidence, or does not provide enough information gain.

## Audiobook cleanup

The default parser applies lightweight cleanup before chapter construction:

- page-local control/ligature/whitespace normalization
- conservative line-wrap dehyphenation
- document-level suppression of short recurring header/footer lines
- sequential page-number removal only after a pattern is proven across multiple pages

Repeated running text keeps its first semantic occurrence rather than disappearing everywhere. Standalone years, quantities, scores, and other numeric lines are not removed simply because they look like page numbers.

Cleanup can be configured independently:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    cleanup: .minimal
))
```

`.minimal` keeps safe page-local normalization while disabling document-level running-matter suppression and automatic line-wrap dehyphenation.

## Output model

`PdfBook` is the immutable parsed result. Its canonical source is ordered `PdfPageContent` values with zero-based source page indexes and `.native`, `.ocr`, or `.empty` extraction provenance.

Parsed output models are immutable and Sendable. Generated page, TOC, chapter, and audiobook-segment identities are deterministic for equivalent parsed content. `PdfChapter` derives word count and reading time from immutable `plainText`, so metrics cannot become stale after construction.

`PdfMetadata.detectedLanguage` is optional. `nil` means the parser does not have a reliable document-language result; PDFKitAudio never reports English merely as a default.

`PdfError` is reserved for fatal whole-document failures such as a missing file, invalid PDF, or password-protected PDF. Recoverable page-level OCR misses keep native text when possible or produce an empty page instead of aborting a long import.

`PdfChapter.htmlPreview` remains an escaped, immutable convenience representation derived during chapter construction. Canonical selected text and page provenance remain the source of truth.

## Chapters and navigation

PDF outline entries are retained as navigation metadata independently from audiobook chapter boundaries. Nested and repeated outline destinations are normalized into monotonic, non-overlapping spoken chapter ranges, and meaningful content before the first chapter is preserved as front matter.

## Audiobook segmentation

PDFKitAudio provides an engine-agnostic convenience segmenter for callers that want bounded text with page provenance. `TTSChunkingConfiguration` controls generic document behavior such as character limits and paragraph preservation; model token limits, prosody, pause durations, retries, and synthesis policy belong in the consuming TTS layer.

```swift
let segments = book.audiobookScript(configuration: TTSChunkingConfiguration(
    maxCharacters: 2_800,
    preferredMinimumCharacters: 700,
    preserveParagraphs: true
))
```

The configuration-based API may pack adjacent short pieces across page boundaries inside the same chapter. Every resulting `AudiobookSegment` carries the exact union `sourcePageRange`, character-weighted confidence, deterministic ordering, and a stable generated ID. Segments never merge across chapter boundaries.

The legacy `audiobookScript(maxCharsPerSegment:)` API remains page-bounded so existing callers do not silently receive wider provenance ranges.

Chunking prefers paragraph and Foundation sentence boundaries, then clause/word boundaries. A hard split is reserved for an unbroken token that exceeds the maximum, and Swift grapheme-cluster indexing keeps Unicode characters intact.

## Async parsing, progress, and cancellation

For UI-driven imports and large/bulk workflows, use the async API instead of manually wrapping synchronous parsing in `Task.detached`:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    ocr: PdfOCRConfiguration(mode: .auto),
    extractCoverImage: false,
    retainNativeText: false
))

let book = try await parser.parse(at: pdfURL, progress: { progress in
    print("\(progress.stage): \(progress.completedPages)/\(progress.totalPages)")
})
```

When progress is not needed, `parseAsync(at:)` and `parseAsync(data:)` provide the shorter form:

```swift
let book = try await parser.parseAsync(at: pdfURL)
```

The older synchronous `parse(at:)` and `parse(data:)` APIs remain source-compatible, including when called from an async context. The progress-reporting async overload therefore requires the `progress:` label instead of using a default that could shadow an existing synchronous call.

`PdfParseProgress` reports these high-level stages: `loading`, `extracting`, `cleaning`, `buildingChapters`, `finishing`, and `finished`. Extraction progress uses monotonic completed/total source-page counts.

Progress callbacks run on the parser task's executor. Callers that update UI should hop to `MainActor` rather than assuming main-thread delivery.

Async parsing preserves Swift task cancellation as `CancellationError`. Cancellation is checked before every source page, immediately before OCR rendering/recognition, immediately after OCR returns, and around document-wide cleanup/chapter/cover work. Vision recognition itself is synchronous, so one OCR page is the maximum non-interruptible unit.

PDFKit access is intentionally serial rather than page-parallel. Each page is processed inside an autorelease pool, OCR thumbnails are page-scoped, and no rendered page images are retained by `PdfBook`. Cover rendering is deferred until text/chapter work is complete, remains bounded to a small thumbnail, and can be disabled for bulk imports.

The package deliberately does not add an `AsyncSequence` page-streaming API yet. Stage/page progress is the smaller public surface unless a real standalone use case demonstrates a need for streaming partial page objects.

## Example macOS app

A signed, sandboxed demo app lives in `Examples/Demo` and is generated with XcodeGen. The generated `.xcodeproj` is intentionally not committed.

Requirements:

```sh
brew install xcodegen
```

Generate and open the project:

```sh
make example-open
```

Build it from the command line:

```sh
make example-build
```

Or build and launch it:

```sh
make example-run
```

The example includes small PDF fixtures under `Examples/Demo/TestFixtures` for quick manual parser checks. They are bundled into the generated demo app as resources.

The example uses bundle identifier `com.hoangbkit.pdfkit.demo`, development team `J458WW3452`, automatic signing, hardened runtime, and App Sandbox with read-only access to user-selected PDFs. It imports the package through a local Swift package dependency (`../..`), so the example always exercises the checkout being edited.

## Current limitations

PDF text does not carry a universal semantic reading order. PDFKit generally works well for ordinary books and single-column documents, but results can still be imperfect for:

- multi-column academic papers and magazines
- pages with floating text boxes, sidebars, or complex positioned layouts
- tables where visual structure is important
- PDFs with malformed or unusual embedded text encodings
- scanned languages or scripts not supported by the Vision version on the target macOS release

These are documented limitations rather than reasons to introduce a heavyweight layout model into the default parsing path.

## Development

Run the package regression suite with:

```sh
swift test
```

Unit tests generate deterministic small PDFs at runtime. The standalone demo additionally keeps a few tiny checked-in PDFs under `Examples/Demo/TestFixtures` for manual testing. CI runs the package tests, generates the XcodeGen example, builds it on macOS 14 with code signing disabled, and verifies the demo fixtures are present in the built app bundle.

The original hardening plan is retained in `PLAN.md` for historical design context. `PHASE_STATUS.md` records the completed package-hardening work.
