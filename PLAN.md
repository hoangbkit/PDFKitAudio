# PDFKitAudio hardening plan for Spokio

## Goal

Make PDFKitAudio a lightweight, production-ready PDF ingestion layer for Spokio without introducing heavy document-understanding models or large runtime dependencies.

The target pipeline is:

`PDF -> PDFKit native text -> selective Vision OCR fallback -> cleanup -> page model -> chapters -> TTS segments`

The library should optimize for fast import, low memory use, correct speech order for common books/documents, and enough provenance to support playback, resume, debugging, and future project workflows.

## Non-goals

- Do not add Granite Docling, VLMs, Core ML layout models, or remote parsing services.
- Do not attempt perfect reconstruction of arbitrary complex page layouts.
- Do not make OCR the default path when PDFKit already extracts usable text.
- Do not couple the package directly to Spokio UI, job queue, persistence, or TTS engines.

## Implementation status

- [x] Phase 0 - baseline and safety net
- [x] Phase 1 - page-level extraction as the source of truth
- [ ] Phase 2 - TOC resolution and chapter construction correctness
- [ ] Phase 3 - multilingual, selective, configurable OCR
- [ ] Phase 4 - audiobook-oriented document cleanup
- [ ] Phase 5 - TTS segmentation and source mapping
- [ ] Phase 6 - concurrency, cancellation, and progressive parsing
- [ ] Phase 7 - platform cleanup and package polish
- [ ] Phase 8 - Spokio integration validation

---

# Engineering principles

## 1. Lightweight by default

PDFKit native text extraction is always the first choice. OCR is selective. No layout model is loaded to parse normal text PDFs.

## 2. Preserve source provenance

Every selected text block should remain traceable back to a PDF page. Do not trade away page mapping just to simplify intermediate models.

## 3. Never duplicate spoken content by default

Navigation metadata and spoken chapter boundaries are related but not identical. Nested PDF outlines must not cause overlapping page ranges or repeated TTS output.

## 4. Prefer deterministic behavior

Page IDs, TOC IDs, chapter ordering, fallback names, cleanup passes, and segmentation should be repeatable for the same source document.

## 5. Fail locally when possible

One unreadable page should not necessarily fail a 500-page import. Preserve placeholders and diagnostics so callers can decide whether a partial import is acceptable.

## 6. Keep the public API small

Prefer configuration values and focused models over exposing every internal heuristic. Spokio should consume stable parsing concepts, not implementation details.

---

# Phase 0 - Baseline and safety net

## Objective

Create enough regression coverage to safely refactor parsing internals without guessing whether behavior changed.

## Implementation work

### 0.1 Add a SwiftPM test target

Add `PDFKitAudioTests` to `Package.swift` and keep test code outside the production target.

### 0.2 Build deterministic PDF fixtures at runtime

Do not check opaque binary fixtures into the repo unless a real-world PDF is needed to reproduce a PDFKit-specific bug.

Create a small helper capable of generating:

- digital text PDFs
- scanned/image-only PDFs
- mixed digital + scanned PDFs
- encrypted PDFs
- flat outlines
- nested outlines
- repeated destinations
- blank-content pages

### 0.3 Baseline parser behavior

Test:

- invalid data throws `invalidPDF`
- missing URLs throw `fileNotFound`
- encrypted documents throw `passwordProtected`
- metadata title/author extraction
- URL filename fallback titles
- no-outline chapter fallback
- native text order
- mixed page handling
- scanned detection

### 0.4 Baseline helper types

Add direct tests for:

- `PdfTextCleaner`
- `TTSChunker`
- model-derived metrics
- audiobook segment ordering

### 0.5 CI

Run `swift test` on macOS 14 for pull requests and master.

### 0.6 Document known limitations

Keep explicit regression coverage or plan notes for:

- PDFKit reading order on multi-column pages
- repeated/nested TOC destinations
- hard-coded OCR language
- page provenance limitations

## Test-quality rules

- Tests must not depend on network access.
- OCR tests should be tolerant enough to avoid OS-version flakiness while still validating that correct language/configuration paths are used.
- Fixtures should be small enough to keep ordinary CI fast.
- Large-document performance fixtures should not run in every unit-test invocation unless explicitly enabled.

## Exit criteria

- `swift test` passes from a clean checkout.
- Every current core type has direct test coverage.
- Known parser bugs have reproducible fixtures.
- The test suite can detect duplicated chapter text, wrong page provenance, excessive OCR activation, and accidental cleanup text loss.

---

# Phase 1 - Page-level extraction as the source of truth

## Objective

Replace anonymous page tuples with a durable page model and make every downstream chapter/segment traceable back to source pages.

## Core design

Introduce a public or package-visible model similar to:

```swift
public struct PdfPageContent: Sendable, Identifiable {
    public let id: Int               // same as pageIndex for deterministic identity
    public let pageIndex: Int
    public let nativeText: String
    public let text: String          // selected + cleaned text
    public let extractionSource: PdfExtractionSource
    public let confidence: Double
}

public enum PdfExtractionSource: Sendable {
    case native
    case ocr
    case empty
}
```

Do not use a random UUID for page identity. Page index is stable and naturally maps to the source PDF.

`nativeText` is useful for diagnostics and comparing OCR/native extraction quality. If memory profiling later proves this too expensive for very large documents, make retention configurable rather than deleting provenance immediately.

## Implementation work

### 1.1 Refactor extraction into an explicit page pipeline

Split the monolithic parser loop into focused operations:

1. load `PDFPage`
2. extract native text
3. evaluate whether OCR should run
4. optionally OCR
5. select native vs OCR result
6. run page-local cleanup
7. emit `PdfPageContent`

This makes each decision directly unit-testable.

### 1.2 Add `pages` to `PdfBook`

`PdfBook` should retain ordered `[PdfPageContent]` and derive:

- actual OCR page count
- empty page count if useful
- all plain text
- chapter contents
- segment provenance

Keep existing chapter-centric consumers working where feasible.

### 1.3 Fix page count semantics

`metadata.pageCount` should represent the actual `PDFDocument.pageCount`, regardless of whether some page objects fail extraction.

If a page cannot be loaded, retain an empty placeholder page result rather than shifting subsequent indexes. Never let array index stop matching source PDF page index.

### 1.4 Fix `ocrPageCount`

Compute from pages whose `extractionSource == .ocr`, not chapters containing at least one OCR page.

### 1.5 Define source ranges for chapters and segments

Replace ambiguous single-page metadata with a source range where appropriate:

```swift
public let sourcePageRange: ClosedRange<Int>
```

For chunks that originate from a subset of a chapter, derive the narrowest known page range rather than always using the chapter's first page.

A future enhancement may carry character offsets, but page range is the required baseline.

### 1.6 Compatibility strategy

Avoid unnecessary public breakage in this phase.

- keep `parse(at:)` and `parse(data:)`
- keep `chapters`
- keep `audiobookScript()`
- deprecate incorrect properties rather than silently changing their meaning when that could surprise downstream callers

Because the repo is still early, prefer correcting clearly wrong semantics now before Spokio deeply depends on them.

## Tests

Add tests proving:

- mixed native/OCR pages preserve correct indexes
- skipped/empty pages do not shift later indexes
- actual OCR page count is correct
- chapter source ranges match underlying pages
- segment source ranges do not all collapse to the chapter start
- `allPlainText()` contains each source page's selected text exactly once in the default path

## Exit criteria

- Every selected text block is traceable to its source page.
- `PdfBook.pages.count == metadata.pageCount` for valid PDFs.
- No page index is inferred from array position after transformations.
- OCR page counts are correct.
- Existing simple parse usage remains straightforward.

---

# Phase 2 - TOC resolution and chapter construction correctness

## Objective

Separate PDF navigation structure from audiobook chapter boundaries and guarantee that default chapter generation does not duplicate spoken page content.

## Core design decision

The PDF outline is **navigation metadata**, not automatically a one-to-one audiobook chapter list.

Nested outline items may represent sections/subsections within a parent chapter. Flattening every outline node into independent page ranges is unsafe because parent and child entries can share pages and overlap.

## Implementation work

### 2.1 Normalize outline destinations

For every outline item:

- resolve destination page through `document.index(for:)` when possible
- support valid PDF go-to action destinations if PDFKit exposes them through the outline item
- reject unresolved/out-of-range destinations without defaulting them to page zero
- preserve the item in navigation metadata if useful, but mark destination absence explicitly rather than inventing one

Never use `0` as a generic fallback for a missing destination; that creates false Chapter 1/page 1 associations.

### 2.2 Preserve hierarchy exactly for navigation

`PdfTOCItem` should keep:

- title
- optional resolved page index
- hierarchy/children
- stable deterministic ordering

Avoid random UUID identity if the TOC may be persisted or compared between parses. A deterministic path-based identity such as outline index path (`0/3/1`) is preferable.

### 2.3 Define audiobook boundary selection

Default strategy:

1. Prefer usable top-level outline entries with unique, monotonic destinations.
2. If top-level outline is too sparse or malformed, consider the first consistent hierarchy level rather than flattening all levels indiscriminately.
3. Collapse multiple entries that start on the same page into one chapter boundary while preserving aliases/subtitles in navigation metadata.
4. Sort boundaries by page only after preserving original outline order for tie-breaking.
5. Never emit overlapping default chapter ranges.

### 2.4 Handle preface/front matter

If the first usable TOC destination starts after page 0 and prior pages contain meaningful text, generate a deterministic front-matter chapter such as `Front Matter` rather than silently discarding those pages.

### 2.5 Handle same-page boundaries

When multiple headings start on the same page:

- select one audiobook boundary
- retain all navigation entries
- avoid zero-length or duplicate chapters
- use deterministic title selection (prefer the highest/outermost usable level, then original outline order)

### 2.6 Handle malformed order

Real PDFs may have outline entries that jump backward or are not in visual page order.

- navigation hierarchy should retain source order
- audiobook boundaries should be normalized into monotonic page order
- log/diagnose ignored malformed entries when practical
- never create negative or inverted page ranges

### 2.7 Fallback chapter heuristics

When no usable outline exists:

- inspect only a small number of leading lines per page
- detect obvious `Chapter`, `Part`, and equivalent headings conservatively
- avoid splitting on ordinary body lines that happen to be short
- keep the deterministic fixed-page fallback for documents with no reliable headings

Do not add ML heading classification in this library.

## Tests

Add fixtures proving:

- nested outlines do not duplicate source pages in chapter output
- parent + child entries on the same page generate one audiobook boundary
- repeated destinations generate one chapter boundary
- invalid destinations do not silently become page 0
- front matter before the first TOC entry is preserved
- malformed/backward outline order normalizes safely
- generated chapter ranges are monotonic and non-overlapping
- concatenating default chapters reproduces canonical page text exactly once

## Exit criteria

- default audiobook chapter ranges never overlap
- every canonical non-empty page belongs to at most one default chapter
- front matter is not silently lost
- TOC hierarchy remains available independently from audiobook chapter boundaries
- nested/repeated TOC fixtures cannot duplicate spoken text

---

# Phase 3 - Multilingual, selective, configurable OCR

## Objective

Keep OCR lightweight while making it suitable for Spokio's multilingual use cases and reducing false OCR activation.

## Public configuration shape

Replace scattered OCR constructor parameters with a focused configuration value, while retaining convenient defaults. A target shape could be:

```swift
public struct PdfOCRConfiguration: Sendable {
    public var mode: OCROptions
    public var nativeTextThreshold: Int
    public var recognitionLanguages: [String]
    public var automaticallyDetectsLanguage: Bool
    public var recognitionLevel: VNRequestTextRecognitionLevel
}
```

If exposing Vision's recognition-level type in the public API creates undesirable framework coupling, wrap it in a package-owned enum.

Default behavior should preserve the lightweight fast path.

## OCR language behavior

Current hard-coded `en-US` must be removed.

Recommended policy:

- if explicit recognition languages are supplied, pass them to Vision
- otherwise allow automatic language detection when supported and enabled
- do not pretend metadata `detectedLanguage = "en"` is actual detection
- keep language configuration independent from Spokio's TTS voice selection

Test Vietnamese and at least one Latin-script non-English sample if Vision CI behavior is sufficiently deterministic.

## Auto-OCR decision policy

The current character-count threshold is useful but too simple by itself.

Keep the decision cheap. Candidate signals:

- selected native character count
- ratio of printable/alphanumeric characters
- suspicious replacement/control-character rate
- whether native extraction contains only a page number/header fragment

Do not render a page merely to decide whether it needs rendering.

A reasonable decision sequence:

1. native extraction is empty -> OCR candidate
2. native extraction is below configurable threshold -> OCR candidate
3. native extraction is long and text-like -> stay native
4. native extraction is suspicious/garbled -> OCR candidate

## Native-vs-OCR selection

Running OCR does not automatically mean OCR output should win.

Selection should consider:

- non-empty result
- text length/information gain
- OCR confidence
- obvious native-text corruption indicators

If native text is clearly good and OCR is shorter or low-confidence, preserve native text.

Expose the selected source through `PdfPageContent.extractionSource`; optional diagnostic reason fields can remain internal unless callers need them.

## Rendering strategy

- render only pages selected for OCR
- use a bounded target resolution suitable for text recognition
- avoid retaining full-size page images after OCR
- process one/few page images at a time so memory does not scale with full document image size

Do not pre-render the whole PDF.

## Error semantics

- OCR failure on a page with usable native text should fall back to native text
- OCR failure on an image-only page should produce `.empty`, not abort the entire document by default
- optional strict mode can be considered later if Spokio needs hard failures

## Tests

Add deterministic tests for:

- `.never` never invokes OCR
- `.always` attempts OCR for every page
- `.auto` leaves strong native pages alone
- `.auto` OCRs image-only pages
- OCR failure falls back safely
- native text wins when OCR output is worse
- OCR wins when native text is absent/clearly bad
- explicit language configuration reaches the Vision request
- automatic language detection path is exercised when configured
- OCR page count reflects selected OCR pages, not merely attempted pages

## Performance targets

Measure rather than guess. Add a benchmark harness that records at least:

- total parse duration
- number of pages
- pages OCR attempted
- pages OCR selected
- approximate peak memory if practical

Do not make fragile absolute timing limits part of ordinary unit tests. Record baselines for representative hardware instead.

## Exit criteria

- a normal digital PDF performs zero OCR work in default mode
- multilingual scanned PDFs are no longer forced through English OCR
- OCR failures are page-local
- OCR source/provenance remains correct
- OCR work scales with selected problem pages, not total page count

---

# Phase 4 - Audiobook-oriented document cleanup

## Objective

Improve spoken output for normal books and reports without adding a heavyweight layout model.

## Design split

Separate cleanup into two levels:

1. **page-local normalization** - safe transformations that need only one page
2. **document-level cleanup** - transformations that require statistics across pages

Do not mix cross-page heuristics into `PdfTextCleaner.clean(_:)` without context.

## 4.1 Page-local normalization

Keep or improve conservative handling of:

- null/control characters
- common ligatures
- whitespace normalization
- hard-wrap dehyphenation
- isolated numeric page numbers
- obvious empty-line noise

Avoid aggressive punctuation rewriting because TTS prosody depends on punctuation.

## 4.2 Repeated header/footer detection

Introduce a document cleanup stage after page extraction and before chapter assembly.

Suggested algorithm:

1. collect first and last `N` non-empty lines from each page
2. normalize candidate lines for comparison:
   - trim whitespace
   - optionally normalize numeric page tokens
   - preserve enough text to avoid merging unrelated lines
3. count normalized candidates across pages
4. only mark as repeated if they occur on a meaningful percentage/minimum count of pages
5. remove the corresponding lines only from page-edge regions, never from arbitrary body positions

Use conservative thresholds. A header accidentally spoken is preferable to deleting real content.

## 4.3 Running page-number variants

Recognize patterns like:

- `42`
- `Page 42`
- `42 | Book Title`
- `Book Title 42`

but only near page boundaries and preferably with repeated-document evidence.

## 4.4 Preserve paragraph continuity across page breaks

After headers/footers are removed, consider whether adjacent pages represent a continuing sentence/paragraph.

Signals might include:

- previous page does not end in sentence punctuation
- next page begins lowercase
- neither edge is a detected heading/list/table boundary

Keep this logic conservative because incorrect merging can damage narration structure.

## 4.5 Reading-order limitations

Document clearly:

- PDFKit's extracted string order is the baseline
- multi-column or heavily positioned documents can still read in the wrong order
- this package intentionally does not run a general layout-understanding model

If future evidence shows simple block ordering is necessary, add it as a separate optional feature rather than silently increasing the default parser cost.

## Tests

Create multi-page synthetic text cases for:

- same header repeated on most pages -> removed
- same footer repeated -> removed
- a legitimate repeated phrase in body text -> retained
- varying page numbers -> removed only at page edge
- header appearing on only two pages -> retained when below threshold
- paragraph spanning pages -> preserved sensibly
- chapter title at top of one page -> not mistaken for running header

## Exit criteria

- typical ebook-like PDFs no longer narrate repeated headers/footers on every page
- cleanup does not silently delete body text in regression fixtures
- page provenance is retained after cleanup
- cleanup remains deterministic and cheap compared with OCR

---

# Phase 5 - TTS segmentation and source mapping

## Objective

Produce speech-ready segments with stable ordering, useful sizes, and accurate source-page provenance.

## Segment model

Target a model such as:

```swift
public struct AudiobookSegment: Sendable, Identifiable {
    public let id: String
    public let chapterIndex: Int
    public let chapterTitle: String
    public let text: String
    public let order: Int
    public let sourcePageRange: ClosedRange<Int>
    public let confidence: Double
}
```

Optionally add character/source offsets later if required by Spokio highlighting or exact resume behavior.

## Chunking hierarchy

Prefer boundaries in this order:

1. paragraph
2. sentence
3. punctuation/clause
4. whitespace near target length
5. hard split only as a final fallback

Do not split by raw UTF-16/byte offset.

## Segment sizing

`maxCharacters` is a simple compatibility control but does not perfectly represent TTS workload.

Keep it initially, but structure the chunker so future limits can be based on:

- Unicode scalar count
- words
- model-specific token estimates

without rewriting provenance logic.

## Cross-page chunks

If text from adjacent pages is merged into one segment:

- set `sourcePageRange` to the union of pages contributing text
- do not claim a single page when multiple pages contribute

## Stable identity

Segment IDs should remain deterministic for an unchanged source document/configuration where practical. Avoid UUIDs if segments will be persisted or compared across re-imports.

Possible identity inputs:

- chapter stable ID
- source page range
- ordinal within chapter
- hash of normalized segment text if a stable hash is introduced

Do not use Swift's randomized `Hashable` result as a persisted ID.

## Tests

Test:

- no empty segments
- stable segment order
- maximum size respected except explicitly documented impossible cases
- sentences are preferred over arbitrary cuts
- Unicode/emoji cannot be split into invalid text
- paragraph boundaries are preferred
- source page ranges are accurate
- full concatenated segment text reproduces the chapter speech text
- deterministic input/configuration produces deterministic segment IDs

## Exit criteria

- segments can be persisted in Spokio without ambiguous source-page mapping
- no segment is empty
- chunking is deterministic
- text reconstruction from ordered segments is lossless modulo documented whitespace normalization

---

# Phase 6 - Concurrency, cancellation, and progressive parsing

## Objective

Make large-document and bulk import practical without hiding blocking work inside UI callers.

## Public API direction

Retain synchronous APIs for compatibility if useful, but provide an explicit asynchronous parser surface, for example:

```swift
public func parse(at url: URL) async throws -> PdfBook
```

If Swift overload ambiguity makes identical sync/async names awkward for callers, use a clearly named async method rather than forcing cleverness.

## 6.1 Cancellation

Check `Task.isCancelled` / `Task.checkCancellation()` at useful boundaries:

- before expensive metadata/cover work
- between pages
- before OCR render
- after OCR completion
- before document-level cleanup/chapter assembly

Cancellation should stop starting new expensive page work quickly.

## 6.2 Progress

Provide a lightweight progress mechanism independent of Spokio UI.

Candidate value:

```swift
public struct PdfParseProgress: Sendable {
    public let completedPages: Int
    public let totalPages: Int
    public let ocrPagesAttempted: Int
}
```

Delivery options:

- `@Sendable` closure
- `AsyncStream`

Prefer the smallest mechanism that supports Spokio project imports cleanly.

Progress callbacks should not require `MainActor`; the caller can hop to UI isolation.

## 6.3 Bounded OCR concurrency

Do not launch OCR for hundreds of pages simultaneously.

If parallel OCR materially improves throughput:

- cap concurrent OCR pages to a small configurable/default number
- preserve output order independently of completion order
- measure memory before increasing concurrency

Serial OCR is acceptable initially if it keeps memory predictable and cancellation simple.

## 6.4 Thread-safety review

Remove `@unchecked Sendable` where practical.

Audit whether:

- `PDFDocument` is confined to a single task/thread
- parser configuration is immutable while parsing
- AppKit/PDFKit rendering has any actor/thread restrictions in the deployment target

Do not use `@unchecked Sendable` merely to suppress compiler warnings without an isolation story.

## 6.5 Bulk workflow expectations

The package itself should parse one document at a time. Spokio can coordinate multiple project files.

Still ensure:

- parser instances do not hold large document state after return
- no global mutable OCR state exists
- cancellation of one parse does not affect another

## Tests

Add tests for:

- cancellation before parse
- cancellation during a multi-page parse
- progress reaches total page count on success
- progress remains monotonic
- output page order is stable if internal work is concurrent
- simultaneous independent parses do not leak state into each other

## Performance harness

Create a non-CI or opt-in benchmark for:

- 10-page digital PDF
- 100-page digital PDF
- mixed 100-page PDF with a small OCR percentage
- all-scanned PDF

Record:

- wall-clock time
- OCR count
- approximate memory
- resulting word/segment count

This is more valuable than committing brittle absolute timing assertions.

## Exit criteria

- the async API does not block a caller's main actor with the full parse
- cancellation stops new expensive work promptly
- progress is usable by Spokio's project UI
- OCR concurrency is bounded
- output ordering remains deterministic

---

# Phase 7 - Platform cleanup and package polish

## Objective

Make the library reusable across intended Apple platforms and remove preview/UI concerns from parsing internals.

## 7.1 Decide supported platforms explicitly

If Spokio needs both macOS and iOS PDF import, target both in `Package.swift`.

Likely direction:

```swift
platforms: [
    .macOS(.v14),
    .iOS(.v17)
]
```

Confirm against actual Spokio deployment targets before committing them.

## 7.2 Remove direct AppKit assumptions

Current OCR/cover rendering uses `NSImage`/`NSBitmapImageRep`.

Prefer Core Graphics image data internally where practical. If platform image APIs are needed, isolate them behind conditional compilation rather than scattering `#if os(...)` throughout parsing logic.

## 7.3 Separate preview formatting

`htmlPreview` is presentation output, not fundamental PDF parsing data.

Options in order of preference:

1. move HTML generation to a dedicated formatter target/type
2. make it a derived helper outside core parsing
3. retain temporarily for compatibility but escape all untrusted title/body content correctly

Do not let HTML generation complicate page extraction.

## 7.4 Public API documentation

Add doc comments for:

- parser entry points
- OCR modes/configuration
- page provenance
- chapter semantics
- known reading-order limitations
- cancellation/progress behavior

## 7.5 Semantic-versioning review

Before tagging a release, list breaking changes introduced by the hardening work.

Because the library appears early-stage, this is a good time to fix incorrect semantics before Spokio adopts them heavily.

## Tests

- `swift test` on all supported package platforms where feasible
- demo app still builds
- package imports without AppKit on iOS if iOS is enabled
- public examples compile

## Exit criteria

- supported platform list matches actual product needs
- parsing core is not unnecessarily tied to preview/UI frameworks
- public API is documented and internally consistent

---

# Phase 8 - Spokio integration validation

## Objective

Prove PDFKitAudio works as Spokio's default PDF ingestion layer before merging product integration work.

## Integration contract

Spokio should receive enough information to build its own persistent/project models without PDFKitAudio knowing about them.

Expected outputs:

- document metadata
- canonical pages
- chapter/navigation structure
- speech-ready segments
- source ranges
- OCR provenance/confidence
- optional cover image

## Representative validation corpus

Use private/manual test documents if licensing prevents checking them into this public repository.

Include at least:

1. normal exported ebook/text PDF
2. long novel PDF
3. scanned PDF
4. mixed scanned + digital PDF
5. Vietnamese PDF
6. PDF with nested TOC
7. PDF with repeated headers/footers
8. two-column paper/report
9. encrypted PDF
10. malformed/no-TOC PDF

## Acceptance review per document

Record:

- import success/failure
- parse duration
- page count
- OCR pages selected
- chapter count
- duplicated/missing text observations
- header/footer narration issues
- reading-order problems
- memory observations

## Product-level checks

In Spokio verify:

- importing does not freeze the Mac UI
- cancelling import behaves predictably
- project progress can be shown
- generated jobs preserve chapter/page order
- resume/reopen can map jobs back to source ranges
- one failed page/file does not corrupt unrelated project work
- large imports do not retain full rendered PDF pages in memory

## Explicit limitation messaging

If multi-column/complex layouts remain imperfect, document that in Spokio's import UX instead of silently adding Granite Docling back to the default path.

Possible future product option:

`Standard PDF parsing` - fast, local PDFKit/Vision path

A future advanced parser should be a separate opt-in capability with its own cost/performance expectations.

## Exit criteria

- representative Spokio PDFs import with acceptable text order and speech quality
- normal digital PDFs remain fast
- OCR occurs only where needed
- no known duplicate-chapter bug remains
- project workflow can consume source page ranges without special-case reconstruction
- limitations are understood before shipping

---

# Recommended implementation order

The phases are deliberately dependency-ordered:

```text
Phase 0  Tests / fixtures / CI
   |
Phase 1  Canonical page model + provenance
   |
Phase 2  TOC -> safe chapters
   |
Phase 3  Selective multilingual OCR
   |
Phase 4  Cross-page audiobook cleanup
   |
Phase 5  Provenance-aware TTS segments
   |
Phase 6  Async + cancellation + progress
   |
Phase 7  Platform/API cleanup
   |
Phase 8  Spokio corpus validation
```

For the shortest path to using PDFKitAudio in Spokio safely, complete **Phases 0-3 first**. Phase 4 is the highest-value quality improvement after correctness. Phases 5-6 become especially important for the planned bulk/project import workflow.
