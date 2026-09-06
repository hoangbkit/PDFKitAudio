# PDFKitAudio hardening plan for Spokio

## Goal

Make PDFKitAudio a lightweight, production-ready PDF ingestion layer for Spokio without introducing heavy document-understanding models or large runtime dependencies.

Target pipeline:

`PDF -> PDFKit native text -> selective Vision OCR fallback -> page-level normalization -> document-level cleanup -> chapters/navigation -> TTS segments`

The library should optimize for:

- fast first usable text
- low and predictable memory use
- deterministic parsing results
- correct speech order for ordinary books and documents
- page-level provenance for playback, resume, regeneration, debugging, and future project workflows
- graceful degradation on imperfect PDFs
- no dependency on Spokio UI, persistence, job queues, or a specific TTS engine

## Engineering principles

These rules apply to every phase.

1. **Native extraction first.** Never render/OCR a page if PDFKit already provides sufficiently usable text unless the caller explicitly requests OCR.
2. **Preserve source provenance.** Do not throw away page boundaries, extraction source, or confidence before downstream objects are built.
3. **Prefer deterministic heuristics over opaque complexity.** Lightweight, testable heuristics are preferable to adding heavy ML/layout dependencies.
4. **Never silently lose text.** Cleanup can remove artifacts only when confidence is high. Ambiguous content should be preserved.
5. **Keep public API small.** Internal implementation may evolve, but Spokio should need only a small number of stable entry points.
6. **Make expensive work explicit and cancellable.** OCR and large-document work must never accidentally block the main actor.
7. **Treat malformed PDFs as expected input.** Invalid metadata, missing outline destinations, empty pages, mixed scanned/native documents, and broken extraction order should fail locally rather than crash the whole parse.
8. **Measure before optimizing.** Performance changes should be backed by representative fixtures/benchmarks rather than intuition.
9. **Do not recreate Granite Docling.** Complex arbitrary layout understanding is outside this package's scope.

## Non-goals

- No Granite Docling, VLMs, Core ML layout models, or remote parsing services.
- No attempt at perfect reconstruction of arbitrary multi-column/table-heavy documents.
- No OCR-by-default when native text is usable.
- No direct dependency on Spokio UI, storage, project models, job queue, or speech engines.
- No persistence format owned by PDFKitAudio; the library should expose stable data that Spokio may persist in its own models.

---

# Phase 0 - Baseline, fixtures, and safety net

## Objective

Create enough deterministic regression coverage that every later parser change can be evaluated for correctness, text preservation, and performance.

## Why this comes first

PDF parsing bugs are often data-dependent and difficult to notice manually. A parser that appears correct on one novel can duplicate chapters, drop headers incorrectly, or trigger OCR excessively on another. The test corpus becomes the contract for the rest of the work.

## Implementation work

### 0.1 Add a proper SwiftPM test target

Update `Package.swift` with `PDFKitAudioTests` and keep tests runnable with plain `swift test` on the supported macOS version.

Organize tests by responsibility:

- `PdfParserTests`
- `PdfTOCParserTests`
- `PdfTextCleanerTests`
- `PdfOCREngineTests`
- `TTSChunkerTests`
- `PdfBookTests`
- later: performance/benchmark tests kept separate from ordinary unit tests

### 0.2 Build a small, intentional PDF fixture corpus

Keep fixtures minimal so CI stays fast. Prefer generated/synthetic fixtures where practical so expected text is known exactly.

Required fixtures:

- single-page digital text PDF
- multi-page digital book-like PDF
- empty valid PDF
- malformed/non-PDF bytes
- encrypted/password-protected PDF
- flat TOC
- nested TOC
- multiple TOC items resolving to the same page
- out-of-order TOC destinations
- outline item with missing/unresolvable destination
- scanned single page
- scanned multi-page document
- mixed native + scanned document
- repeated running header/footer
- numeric page numbers
- legitimate short numeric content that must *not* be removed
- wrapped words with true line-break hyphenation
- legitimate semantic hyphens that must remain
- Unicode/emoji/non-ASCII digital text
- at least one Vietnamese scanned page if stable enough for Vision CI
- very long paragraph / very long sentence for chunking

### 0.3 Capture current behavior before changing it

For existing public APIs, write characterization tests for:

- `parse(at:)`
- `parse(data:)`
- metadata extraction
- chapter ordering
- `allPlainText()`
- `audiobookScript()`
- current OCR mode behavior
- current cleaner transformations

Where behavior is known to be wrong, name the test clearly and mark the desired behavior in the later phase rather than locking the bug in as permanent behavior.

### 0.4 Add invariants

Parser-level tests should assert invariants, not only exact strings:

- page indexes are zero-based and monotonic
- chapter ranges remain within document bounds
- generated chapter ranges are ordered
- audiobook segment order is strictly monotonic
- no non-empty source page disappears without an explicit documented cleanup reason
- `allPlainText()` contains all chapter text exactly once for the default path
- OCR confidence always remains in `0...1`
- empty PDFs do not produce invalid ranges such as `0...0` pretending a page exists

### 0.5 Document known limitations

Add a short architecture/limitations section describing what PDFKitAudio intentionally does not guarantee:

- perfect reading order for arbitrary multi-column layouts
- reconstruction of tables/forms
- extraction from unsupported embedded content
- perfect chapter detection when no outline/headings exist

This prevents later implementation work from drifting into heavy document understanding.

## Quality checks

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

Separate PDF navigation structure from audiobook chapter boundaries and guarantee that chapter generation never duplicates spoken page content by default.

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

- choose one chapter boundary
- retain all corresponding TOC nodes for navigation
- never create zero-length/duplicate spoken chapters

### 2.6 Improve no-TOC fallback

Current chapter detection should become conservative and deterministic.

Use a layered fallback:

1. detect strong chapter headings near the top of pages
2. if none found, return a small number of deterministic sections based on page count
3. avoid pretending arbitrary 25-page blocks are semantically real chapters in metadata; label them as generated sections

Heading detection should support more than exactly `Chapter 1` / Roman numerals when cheap to do safely, but avoid language-specific overfitting in this phase.

### 2.7 Guarantee coverage exactly once

For the default audiobook chapter list:

- every meaningful page belongs to exactly one chapter
- no page belongs to two generated chapter ranges
- no meaningful page between chapter boundaries disappears

## Tests

Required TOC scenarios:

- flat unique destinations
- nested parent/child same page
- nested children on later pages
- duplicate destinations
- unsorted destination order
- missing destination
- out-of-range destination
- first chapter begins after front matter
- TOC exists but is unusable

Assertions:

- chapter ranges monotonic
- no overlaps
- no duplicates in `allPlainText()`
- full text coverage exactly once
- navigation hierarchy remains intact independently of audiobook chapters

## Exit criteria

- Nested TOCs cannot duplicate spoken text.
- Invalid destinations never silently become page zero.
- Default chapter ranges are monotonic, non-overlapping, and cover meaningful pages exactly once.
- Navigation hierarchy remains available even when audiobook boundaries are simplified.

---

# Phase 3 - Multilingual, selective, and configurable OCR

## Objective

Make Vision OCR reliable for multilingual scanned/mixed PDFs while ensuring native digital PDFs remain fast and avoid rendering work.

## API design

Replace scattered OCR parameters with one configuration type:

```swift
public struct PdfOCRConfiguration: Sendable {
    public var mode: OCROptions
    public var recognitionLanguages: [String]
    public var automaticallyDetectsLanguage: Bool
    public var recognitionLevel: VNRequestTextRecognitionLevel
    public var minimumNativeCharacterCount: Int
}
```

If exposing Vision-specific enums publicly would couple the API too tightly to Vision, define package-owned equivalents and map them internally.

Provide a sensible `.default` tuned for Spokio's common path.

## Implementation work

### 3.1 Remove hard-coded English

Do not force `en-US` with automatic language detection disabled.

Desired behavior:

- if caller supplies explicit languages, honor them
- otherwise allow automatic language detection where supported
- validate/normalize requested languages against Vision support where practical
- do not fail the entire document because one requested OCR language is unsupported

### 3.2 Improve `.auto` OCR triggering

A single `raw.count < threshold` rule is insufficient.

Use cheap signals such as:

- trimmed native character count
- ratio of letters/digits to replacement/control characters
- suspiciously low text density on a page relative to nearby pages
- empty/near-empty extraction

Keep the trigger conservative. Do not add expensive page rendering just to decide whether page rendering is needed.

### 3.3 Native-vs-OCR selection policy

When OCR runs, compare candidates rather than automatically replacing native text.

Rules should prefer native extraction unless OCR is clearly better by signals such as:

- native extraction nearly empty
- OCR contains substantially more plausible text
- native extraction has excessive invalid/control characters

Record which source won and its confidence.

### 3.4 Render only OCR candidates

Never pre-render all document pages.

For `.auto`, render only pages selected for OCR. For `.always`, process one page at a time and release temporary images promptly.

### 3.5 Correct image sizing

Avoid assuming every page is US Letter.

Determine render size from the page bounds while preserving aspect ratio and targeting a configurable approximate DPI / maximum dimension. Cap dimensions to avoid extreme memory use on pathological page sizes.

### 3.6 OCR error semantics

OCR failure on one page should normally produce a page-level result rather than abort the entire document if native text exists.

Distinguish:

- OCR not attempted
- OCR attempted and selected
- OCR attempted but native text retained
- OCR failed with native fallback
- OCR failed with no text available

This can be internal diagnostics initially if the public model would otherwise become too large.

### 3.7 Scanned-document metadata

Determine `metadata.isScanned` from actual extraction results when possible rather than relying solely on a pre-parse sample heuristic.

For example, classify as scanned when a meaningful proportion of non-empty pages ultimately require OCR. Keep the existing sample heuristic only as an optimization/early hint if useful.

## Tests

- digital English PDF: zero OCR in `.auto`
- digital Vietnamese PDF: zero OCR in `.auto`
- scanned English PDF: OCR selected
- scanned Vietnamese PDF: OCR runs without hard-coded English
- mixed native/scanned PDF: only scanned pages OCR
- `.never`: no OCR regardless of page content
- `.always`: every loadable page attempts OCR
- OCR failure with usable native text: native text survives
- pathological page dimensions do not allocate unbounded images

## Performance requirements

Capture baseline and post-change metrics on representative documents:

- number of pages rendered
- OCR page count
- total parse duration
- peak memory where measurable

The common digital-PDF path should not become materially slower because OCR capabilities improved.

## Exit criteria

- No hard-coded English-only behavior remains.
- Mixed documents OCR only pages that need it in `.auto`.
- Native digital documents avoid rendering in the common path.
- One OCR failure cannot destroy otherwise usable document text.
- OCR render dimensions are bounded and page-aspect-aware.

---

# Phase 4 - Audiobook-oriented text normalization and cleanup

## Objective

Remove artifacts that sound bad in speech while preserving real content and avoiding layout-model complexity.

## Architecture

Split cleanup into two stages:

1. **page-local normalization**: safe transformations that do not require context from other pages
2. **document-level cleanup**: repeated header/footer and cross-page heuristics that require multiple pages

Do not mix the two; this keeps transformations testable and makes text-loss bugs easier to isolate.

## Implementation work

### 4.1 Page-local safe normalization

Retain and harden:

- null/control-character cleanup
- Unicode normalization where useful
- ligature replacement
- whitespace normalization
- soft-hyphen handling

Avoid converting punctuation unnecessarily. For example, do not normalize an em dash merely because TTS can read it; preserve semantic punctuation unless there is a proven speech issue.

### 4.2 Conservative dehyphenation

Current `-\n -> ''` behavior is too aggressive.

Only dehyphenate when evidence suggests a line-wrap split, for example:

- alphabetic characters on both sides
- preceding token is not obviously a standalone hyphenated compound
- next line begins with lowercase when language heuristics make that meaningful

When uncertain, preserve the hyphen.

### 4.3 Repeated header/footer detection

Use a document-level pass.

Candidate extraction:

- inspect first N non-empty lines and last N non-empty lines per page
- normalize whitespace/case for comparison while retaining originals
- ignore clearly page-specific numeric portions when computing repetition signatures

Removal threshold:

- require the candidate to occur across a significant fraction of eligible pages
- avoid applying to very short documents where repetition evidence is weak
- distinguish alternating left/right headers in printed books
- avoid removing a line merely because it repeats twice

The cleanup system should produce a set of known repeated artifact signatures and then remove only those matching lines.

### 4.4 Page-number handling

Do not globally remove every short numeric line.

Restrict page-number removal to likely header/footer zones or a proven repeated numbering pattern. Numeric content inside body text must survive.

### 4.5 Paragraph reconstruction

Preserve paragraph boundaries where PDFKit provides useful line breaks.

For book-like text, join soft line wraps within a paragraph while retaining blank-line paragraph separation. Avoid turning the whole page into one paragraph.

Keep this heuristic conservative because poetry, code, and lists intentionally use line breaks.

### 4.6 Cleanup configuration

Introduce options for potentially risky transforms:

- dehyphenation
- repeated header/footer removal
- page number removal
- paragraph line joining

Provide a default tuned for audiobook narration, but let callers choose a minimally transformed mode for debugging or specialized content.

### 4.7 Diagnostics for removed artifacts

For tests/debug builds, make it possible to inspect what was removed (e.g. repeated-header signatures) without exposing large debug payloads in the normal public API.

This is important when a user reports missing text.

## Tests

- repeated book title header removed
- alternating author/book headers removed
- legitimate repeated body phrase retained
- page number in footer removed
- year/section number in body retained
- wrapped `exam-\nple` becomes `example`
- legitimate `well-\nknown` style cases handled conservatively
- poetry/list line breaks not aggressively collapsed
- cleanup does not reduce document text by an implausibly large percentage without explicit fixture expectation

## Exit criteria

- Common running headers/footers stop appearing in TTS output.
- Cleanup is deterministic.
- No transform silently drops large content blocks.
- Riskier cleanup behaviors can be disabled independently.

---

# Phase 5 - TTS segmentation and precise source mapping

## Objective

Produce natural, stable, engine-agnostic text chunks suitable for Spokio generation while retaining enough provenance to navigate back to source pages.

## Design principles

- Chunking belongs in PDFKitAudio only as generic text segmentation, not engine-specific token budgeting.
- Prefer semantic boundaries before hard limits.
- Never split Swift `String` using assumptions that can corrupt extended grapheme clusters.
- Segment identity should be deterministic for the same parsed input/configuration where practical.

## Implementation work

### 5.1 Separate sentence boundary detection from chunk packing

Implement two concepts:

1. split text into candidate semantic units
2. pack units into chunks up to configured limits

This makes sentence logic testable independently from max-length behavior.

### 5.2 Prefer boundary hierarchy

When packing chunks, prefer in order:

1. chapter boundary
2. paragraph boundary
3. sentence boundary
4. clause/punctuation boundary for very long sentences
5. whitespace boundary
6. grapheme-safe hard split only as the final fallback

### 5.3 Improve sentence detection

Avoid splitting naïvely after every period.

Cover common cases:

- abbreviations (`Mr.`, `Dr.`, `e.g.`)
- decimal numbers
- ellipses
- quoted dialogue punctuation
- Unicode sentence punctuation

Do not attempt a full NLP sentence parser if Foundation linguistic APIs or simple deterministic rules are sufficient.

### 5.4 Track source provenance during chunking

Do not concatenate an entire chapter and then lose page boundaries before chunking.

Feed page-associated text units into the segmenter so each `AudiobookSegment` can expose:

- chapter index/title
- segment order
- source page range
- text
- confidence aggregated from contributing pages

If a chunk crosses a page boundary, record the true range.

### 5.5 Deterministic segment IDs

Avoid IDs built from random chapter UUIDs if Spokio may use them for regeneration/resume.

Prefer deterministic identity derived from stable inputs such as chapter order + segment order + source range, optionally with a short content hash if needed.

### 5.6 Configurable segmentation policy

Use a configuration struct rather than proliferating method parameters:

- max characters
- preferred minimum characters (optional)
- paragraph preference
- sentence preference

Keep character limits for now. Do not introduce model-specific token counting into this package.

## Tests

- ordinary prose
- very long sentence
- very long unbroken token
- abbreviations
- decimals
- dialogue/quotes
- emoji and composed Unicode characters
- CJK/no-space text where possible
- chunk crossing page boundary
- stable output across repeated parses with same config
- no empty chunks
- concatenating segment texts (with documented separator normalization) preserves source text

## Exit criteria

- Segments are natural enough for audiobook generation on normal prose.
- No malformed Unicode slicing is possible.
- Every segment has accurate source page provenance.
- Segment order and identity are deterministic for identical input/configuration.

---

# Phase 6 - Async API, cancellation, progress, and bounded resource use

## Objective

Make large PDF imports responsive and cancellable in Spokio while keeping concurrency implementation inside the parsing library.

## Public API direction

Prefer an async API like:

```swift
public func parse(
    at url: URL,
    progress: (@Sendable (PdfParseProgress) -> Void)? = nil
) async throws -> PdfBook
```

Keep synchronous methods temporarily for compatibility if useful, implemented through shared core logic rather than maintaining two parsers.

## Implementation work

### 6.1 Define progress semantics

Progress should be based on meaningful stages and page counts, not arbitrary percentages.

Possible model:

```swift
public struct PdfParseProgress: Sendable {
    public let stage: Stage
    public let completedPages: Int
    public let totalPages: Int
}
```

Stages may include:

- loading metadata/outline
- extracting pages
- OCR
- document cleanup
- building chapters
- segment preparation if parsing owns it

Do not emit extremely frequent progress callbacks that create UI overhead.

### 6.2 Cooperative cancellation

Check cancellation:

- before each page
- before expensive rendering
- before Vision OCR
- between major document-level passes

Throw `CancellationError` without converting it into a generic parse error.

### 6.3 Actor/thread safety

Audit PDFKit behavior carefully instead of assuming `PDFDocument`/`PDFPage` are freely sendable.

Prefer confining document access to one parsing executor/task rather than parallelizing page extraction immediately.

Remove `@unchecked Sendable` where possible. If it remains, document the invariant that makes it safe.

### 6.4 Avoid eager large intermediates

Process one page at a time for extraction/OCR.

Release rendered images after each OCR request. Avoid storing thumbnails or TIFF representations unless they are part of returned data.

Evaluate whether storing both native and cleaned text causes material memory pressure for large PDFs. If so, make raw text retention optional after diagnostics are mature.

### 6.5 Cover image generation

Cover thumbnail generation should not unnecessarily block first text extraction or allocate oversized buffers.

Consider making cover extraction optional/configurable or performing it as a cheap bounded operation.

### 6.6 Progressive page delivery (evaluate, don't force)

Consider an `AsyncSequence<PdfPageContent>` only if Spokio can materially benefit from starting downstream generation before the entire PDF is parsed.

Do not add this abstraction unless it provides real workflow value; a clean async whole-document API is preferable to premature complexity.

## Performance validation

Create a repeatable benchmark harness using representative PDFs, recording:

- total parse time
- time to first extracted page
- pages/second native path
- pages/second OCR path
- number of rendered pages
- peak resident memory where practical
- cancellation latency

Benchmark at least:

- ~20-page digital PDF
- ~300-page digital book
- mixed OCR/native PDF
- ~300-page scanned document if fixture size/repository policy permits local-only benchmark data

## Exit criteria

- Parsing can be called asynchronously without UI blocking.
- Cancellation normally stops within the current page/OCR operation rather than after the whole document.
- Progress is stable and meaningful enough for Spokio UI.
- Memory growth is bounded and does not include all rendered page images simultaneously.
- No concurrency change introduces nondeterministic chapter/text ordering.

---

# Phase 7 - Platform support and public API hardening

## Objective

Make PDFKitAudio a clean reusable package for Spokio targets, with minimal UI-specific baggage and stable semantics.

## Implementation work

### 7.1 Evaluate iOS support deliberately

Current AppKit usage should be isolated behind platform-specific helpers.

Use conditional compilation only at the narrow image-conversion/rendering boundary. Avoid duplicating parser logic for macOS/iOS.

If all required PDFKit/Vision behavior is available and tested, update `Package.swift` to support the minimum Spokio iOS version.

Do not lower deployment targets merely for theoretical reuse if doing so adds compatibility complexity Spokio does not need.

### 7.2 Remove presentation concerns from core models

`htmlPreview` is UI/presentation output and does not belong in a parsing core unless there is a strong demonstrated consumer.

Preferred direction:

- remove or deprecate HTML generation from `PdfChapter`
- provide a separate formatter/helper if the demo still needs HTML

If HTML remains anywhere, escape title/metadata and body text consistently.

### 7.3 Review model mutability

Properties that are computed during parsing and should not change afterward should be `let`.

Avoid models that expose mutable cached values (`wordCount`, `readingTimeMinutes`) which can drift out of sync with mutable `plainText`.

Either:

- make source text immutable and derived properties computed, or
- encapsulate mutation so invariants are maintained

Prefer immutable value types.

### 7.4 Stabilize identities

Replace random UUID identities for deterministic source-derived objects where they provide persistence/regeneration value:

- pages: page index
- TOC nodes: outline path
- chapters: chapter order + source range / stable boundary key
- segments: deterministic segment key

### 7.5 Error model cleanup

Review `PdfError` cases against actual parser behavior.

Distinguish errors that should abort parsing from recoverable page-level diagnostics.

Document expected behavior for:

- file missing
- invalid bytes
- encrypted/locked PDF
- zero-page PDF
- page extraction failure
- OCR failure
- unsupported operation
- cancellation

Remove unused error cases rather than leaving misleading API surface.

### 7.6 Configuration consolidation

By this phase, parser options may include OCR, cleanup, and output/provenance preferences.

Consolidate them into one stable top-level configuration object rather than growing the initializer indefinitely:

```swift
public struct PdfParserConfiguration: Sendable {
    public var ocr: PdfOCRConfiguration
    public var cleanup: PdfCleanupConfiguration
    public var retainNativeText: Bool
}
```

Provide a strong default so common usage remains:

```swift
let book = try await PdfParser().parse(at: url)
```

### 7.7 README and API documentation

Document:

- common native parsing path
- OCR behavior
- known limitations
- cancellation/progress
- page/chapter/segment provenance
- recommended Spokio-style TTS ingestion

Make clear that the package is optimized for lightweight audiobook/text extraction rather than full document-layout reconstruction.

## Exit criteria

- Core package contains no unnecessary UI formatting concerns.
- Public models are internally consistent and mostly immutable.
- Parser configuration is coherent rather than parameter-heavy.
- Supported platforms are explicit and tested.
- Public API can reasonably be tagged/versioned without immediate redesign.

---

# Phase 8 - Spokio integration validation and release readiness

## Objective

Validate the hardened library against the actual Spokio project workflow and establish objective release criteria before depending on it in production.

## Integration strategy

Integrate the PR branch or a prerelease tag into a dedicated Spokio development branch. Keep the dependency pinned during validation so parser behavior cannot change underneath app testing.

PDFKitAudio should return parsed data only. Spokio remains responsible for:

- project lifecycle
- persistence
- job queue orchestration
- TTS engine selection
- audio generation
- retry/UI behavior

## Real-world corpus

Use representative user-style documents, not only synthetic fixtures:

- ordinary novel with a clean text layer
- exported ebook-style PDF with TOC
- nested-outline PDF
- scanned English book
- scanned Vietnamese book
- mixed scanned/native document
- large 300+ page book
- PDF with repeating headers/footers
- PDF with no outline
- intentionally difficult multi-column academic paper to confirm graceful limitation behavior

Do not commit copyrighted/private test documents to the public repository. Keep a local/internal benchmark corpus where necessary and document expected characteristics rather than contents.

## Metrics to capture

For each validation document record:

### Correctness

- page count
- generated chapter count
- duplicated text occurrences
- missing meaningful text
- OCR pages selected
- wrong OCR/native source choices
- header/footer artifacts remaining
- chapter boundary quality
- segment/page provenance correctness

### Performance

- total import duration
- time to first usable text if available
- peak memory
- rendered/OCR page count
- cancellation responsiveness

### Speech quality proxy

Manually inspect/listen to representative generated segments for:

- broken sentence boundaries
- repeated page headers
- spoken page numbers
- bad line-wrap joins
- duplicated chapter content
- clearly wrong reading order

## Regression budget

Define concrete release gates after baseline measurements are available.

At minimum:

- digital text PDFs should remain fast and avoid OCR
- no duplicated chapter text in known TOC fixtures
- no page provenance mismatches in regression corpus
- no known large-text-loss cleanup bug
- large digital books stay within a reasonable memory envelope on supported Macs
- OCR is invoked only where expected in `.auto`

Avoid inventing arbitrary millisecond/MB targets before benchmarks exist. Record the baseline first, then set thresholds relative to supported hardware and Spokio UX requirements.

## Failure handling validation

Verify Spokio experience for:

- invalid PDF
- encrypted PDF
- cancelled parse
- OCR failure on a subset of pages
- PDF containing no usable text

The app should be able to distinguish a recoverable warning from a fatal import failure based on PDFKitAudio output/errors.

## Final library release checklist

Before tagging a stable version for Spokio:

- all unit/regression tests green
- README/API docs current
- no known text duplication bug
- no hard-coded English OCR behavior
- async cancellation/progress validated
- public API reviewed for naming/semantics
- changelog/release notes describe behavior changes
- Spokio pinned-integration smoke test passes

## Exit criteria

- Common PDFs reach usable TTS text quickly with no model startup cost.
- Known nested-TOC duplication, OCR language, provenance, and cleanup issues are resolved.
- Difficult layouts degrade predictably rather than causing crashes or catastrophic text loss.
- Performance is acceptable for Spokio's supported Macs and intended project workflow.
- PDFKitAudio is ready for a stable version tag and direct Spokio dependency.

---

# Recommended implementation sequence

1. **Phase 0 - Baseline and tests**
2. **Phase 1 - Page model and provenance**
3. **Phase 2 - TOC/chapter correctness**
4. **Phase 3 - Multilingual selective OCR**
5. **Phase 4 - Audiobook cleanup**
6. **Phase 5 - TTS segmentation/provenance**
7. **Phase 6 - Async, cancellation, progress, memory**
8. **Phase 7 - Platform/API hardening**
9. **Phase 8 - Spokio validation and release**

## Integration checkpoints

Do not wait until Phase 8 for the first Spokio experiment.

- **After Phase 2:** verify digital PDF import + chapter correctness in a disposable Spokio branch.
- **After Phase 4:** verify real-world book cleanup and multilingual scanned import.
- **After Phase 6:** verify large-document UX, progress, cancellation, and memory behavior.
- **After Phase 8:** pin/tag the production dependency.

## Highest-priority path

Phases 0-3 are the minimum correctness foundation before PDFKitAudio should become Spokio's primary PDF parser.

Phase 4 is the highest-value speech-quality improvement.

Phases 5-6 make the integration production-grade for bulk/project workflows.

Phase 7 should stabilize the API only after real implementation pressure has clarified what Spokio actually needs.

Phase 8 is the release gate, not a place to discover basic architectural flaws for the first time.
