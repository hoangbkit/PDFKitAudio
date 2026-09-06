# PDFKitAudio

Lightweight PDF extraction and audiobook-oriented text preparation for Apple platforms.

The parser uses PDFKit native text first and selectively falls back to Vision OCR. It intentionally avoids heavyweight document-understanding models.

## OCR

Default parsing keeps healthy digital PDFs on the native fast path. Pages with missing, short, or suspicious native text become OCR candidates.

Vision automatic language detection is enabled by default; PDFKitAudio no longer hard-codes English. Callers that need tighter control can provide explicit recognition languages and recognition behavior:

```swift
let parser = PdfParser(ocrConfiguration: PdfOCRConfiguration(
    mode: .auto,
    recognitionLanguages: ["vi-VN", "en-US"],
    automaticallyDetectsLanguage: false,
    recognitionLevel: .accurate
))

let book = try parser.parse(at: url)
```

`PdfParser()` and `PdfParser(ocrMode:)` remain available for simple and existing callers.

Running OCR does not automatically replace native PDF text. PDFKitAudio keeps the native result when OCR is empty, low-confidence, or does not provide enough information gain.

## Audiobook cleanup

The default parser applies two lightweight cleanup stages before chapter construction:

- page-local control/ligature/whitespace normalization
- conservative line-wrap dehyphenation
- document-level suppression of short recurring header/footer lines
- sequential page-number removal only after a pattern is proven across at least three pages

Repeated running text keeps its first semantic occurrence rather than disappearing everywhere. Standalone years, quantities, scores, and other numeric lines are not removed simply because they look like page numbers. `PdfPageContent.nativeText` remains unchanged for diagnostics even when the selected spoken text is cleaned.

Cleanup is configurable independently from OCR:

```swift
let parser = PdfParser(
    ocrMode: .auto,
    cleanupConfiguration: .minimal
)
```

`.minimal` keeps safe page-local normalization while disabling document-level running-matter suppression and automatic line-wrap dehyphenation.

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
let parser = PdfParser(
    ocrMode: .auto,
    extractCoverImage: false
)

let book = try await parser.parse(at: url, progress: { progress in
    print("\(progress.stage): \(progress.completedPages)/\(progress.totalPages)")
})
```

When progress is not needed, `parseAsync(at:)` and `parseAsync(data:)` provide the shorter form:

```swift
let book = try await parser.parseAsync(at: url)
```

The older synchronous `parse(at:)` and `parse(data:)` APIs remain source-compatible, including when called from an async context. The progress-reporting async overload therefore requires the `progress:` label instead of using a default that could shadow an existing synchronous call.

`PdfParseProgress` reports these high-level stages:

- `loading`
- `extracting` with monotonic completed/total page counts
- `cleaning`
- `buildingChapters`
- `finishing`
- `finished`

Progress callbacks run on the parser task's executor. Callers that update UI should hop to `MainActor` in the callback rather than assuming main-thread delivery.

Async parsing preserves Swift task cancellation as `CancellationError`. Cancellation is checked before every source page, immediately before OCR rendering/recognition, immediately after OCR returns, and around document-wide cleanup/chapter/cover work. Vision recognition itself is synchronous, so one OCR page is the maximum non-interruptible unit.

PDFKit access is intentionally serial rather than page-parallel. Each page is processed inside an autorelease pool, OCR thumbnails are page-scoped, and no rendered page images are retained by `PdfBook`. Cover rendering is deferred until text/chapter work is complete, remains bounded to a small thumbnail, and can be disabled with `extractCoverImage: false` for bulk imports.

PDFKitAudio deliberately does not add an `AsyncSequence` page-streaming API yet. Spokio's job model already uses `async throws` work plus progress reporting, so stage/page progress is the smaller integration surface unless a real workflow later demonstrates a need for streaming partial page objects.

## Current limitations

PDF text does not carry a universal semantic reading order. PDFKit generally works well for ordinary books and single-column documents, but results can still be imperfect for:

- multi-column academic papers and magazines
- pages with floating text boxes, sidebars, or complex positioned layouts
- tables where visual structure is important
- PDFs with malformed or unusual embedded text encodings
- scanned languages or scripts not supported by the Vision version on the target OS

These are documented limitations rather than reasons to introduce a heavyweight layout model into the default parsing path.

`PdfChapter` identity is still UUID-based in the current hardening branch; deterministic chapter identity and model immutability are intentionally handled in Phase 7 rather than being mixed into the async parser work.

## Development

Run the package regression suite with:

```sh
swift test
```

Tests generate small PDF fixtures at runtime so binary fixture files are not required in the repository.

Current hardening status: Phases 0-6 are complete. See `PLAN.md` for the remaining platform/API polish and Spokio integration phases.
