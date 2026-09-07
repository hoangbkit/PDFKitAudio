# PDFKitAudio

Lightweight PDF extraction and audiobook-oriented text preparation for macOS 14+.

PDFKitAudio is intentionally **macOS-only**. It is designed for desktop document-to-audio workflows where imports, OCR, and downstream synthesis may run for a long time. The package does not declare iOS/iPadOS support.

The parser uses PDFKit native text first and selectively falls back to Vision OCR. It intentionally avoids heavyweight document-understanding models.

## Quick start

For new code, configure the parser through `PdfParserConfiguration`:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    ocr: PdfOCRConfiguration(mode: .auto),
    cleanup: .audiobookDefault,
    extractCoverImage: false,
    retainNativeText: false
))

let book = try await parser.parseAsync(at: url)
```

`PdfParser()`, `PdfParser(ocrMode:)`, the OCR-specific initializer, and the synchronous `parse(at:)` / `parse(data:)` methods remain available for existing and simple callers.

`retainNativeText` controls whether raw PDFKit extraction is retained in `PdfPageContent.nativeText` after parsing. Set it to `false` for large or bulk imports when downstream diagnostics do not need the rejected native source. Selected text, extraction provenance, page indexes, and scanned-document metadata remain intact.

## OCR

Default parsing keeps healthy digital PDFs on the native fast path. Pages with missing, short, or suspicious native text become OCR candidates.

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

PDFKitAudio provides an engine-agnostic convenience segmenter for callers that want bounded text with page provenance. `TTSChunkingConfiguration` controls only generic document behavior such as character limits and paragraph preservation; TTS-engine token limits, prosody, pause durations, retries, and generation policy belong in the consuming TTS layer.

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

Spokio already owns richer engine-facing chunking in `TextToSpeech` (`ProsodyTextChunker`), so PDFKitAudio deliberately does not duplicate prosody or silence-boundary semantics.

## Async parsing, progress, and cancellation

For UI-driven imports, projects, and bulk workflows, use the async API instead of manually wrapping synchronous parsing in `Task.detached`:

```swift
let parser = PdfParser(configuration: PdfParserConfiguration(
    ocr: PdfOCRConfiguration(mode: .auto),
    extractCoverImage: false,
    retainNativeText: false
))

let book = try await parser.parse(at: url, progress: { progress in
    print("\(progress.stage): \(progress.completedPages)/\(progress.totalPages)")
})
```

When progress is not needed, `parseAsync(at:)` and `parseAsync(data:)` provide the shorter form:

```swift
let book = try await parser.parseAsync(at: url)
```

The older synchronous `parse(at:)` and `parse(data:)` APIs remain source-compatible, including when called from an async context. The progress-reporting async overload therefore requires the `progress:` label instead of using a default that could shadow an existing synchronous call.

`PdfParseProgress` reports these high-level stages: `loading`, `extracting`, `cleaning`, `buildingChapters`, `finishing`, and `finished`. Extraction progress uses monotonic completed/total source-page counts.

Progress callbacks run on the parser task's executor. Callers that update UI should hop to `MainActor` rather than assuming main-thread delivery.

Async parsing preserves Swift task cancellation as `CancellationError`. Cancellation is checked before every source page, immediately before OCR rendering/recognition, immediately after OCR returns, and around document-wide cleanup/chapter/cover work. Vision recognition itself is synchronous, so one OCR page is the maximum non-interruptible unit.

PDFKit access is intentionally serial rather than page-parallel. Each page is processed inside an autorelease pool, OCR thumbnails are page-scoped, and no rendered page images are retained by `PdfBook`. Cover rendering is deferred until text/chapter work is complete, remains bounded to a small thumbnail, and can be disabled for bulk imports.

PDFKitAudio deliberately does not add an `AsyncSequence` page-streaming API yet. Spokio's job model already uses `async throws` work plus progress reporting, so stage/page progress is the smaller integration surface unless a real workflow later demonstrates a need for streaming partial page objects.

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

Tests generate small PDF fixtures at runtime so binary fixture files are not required in the repository. CI exercises the declared macOS 14 package target; PDFKitAudio intentionally does not advertise untested iOS/iPadOS support.

Current hardening status: Phases 0-7 are complete. See `PHASE_STATUS.md` for completion tracking and `PLAN.md` for the original implementation design. The optional iOS branch described in the original Phase 7 plan was intentionally not pursued; the package remains macOS-only.
