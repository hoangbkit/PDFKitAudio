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

## Correctness before heuristics

Prefer preserving source text and provenance over aggressive cleanup or chapter inference. A parser that occasionally leaves a harmless artifact is preferable to one that silently drops or duplicates content.

## Fast path first

For ordinary digital PDFs, the dominant path should remain native PDFKit extraction. OCR must be selective and lazy. No phase should introduce heavy model startup into the default import path.

## Preserve provenance

Every selected page text block and every generated segment should be traceable to source PDF pages. Avoid APIs that collapse provenance too early.

## Deterministic output

Given the same PDF and parser configuration, chapter boundaries, page identities, cleanup, and TTS segmentation should be deterministic.

## Bounded work

Avoid eager full-document rendering and unbounded caches. Expensive work should scale predictably with page count and should be cancellable before Spokio adopts it for bulk project workflows.

## Public API restraint

Keep the public surface small. Internal parser stages can evolve, but `parse(at:)`, `parse(data:)`, page/chapter output, and audiobook generation should remain straightforward for app callers.

---

# Phase 0 - Baseline and safety net

## Status

**Complete.** GitHub Actions runs the SwiftPM suite on macOS 14. The current suite includes deterministic runtime PDF fixtures and direct coverage for parser, TOC, cleaner, chunker, and model behavior.

## Objective

Establish a reliable regression suite before changing parser semantics.

## Test architecture

Use a SwiftPM `testTarget` with small deterministic fixtures generated locally during tests. Avoid network-hosted fixture dependencies so CI remains reproducible.

Fixture categories:

- digital PDF with selectable text
- blank-content PDF
- malformed/non-PDF input
- password-protected PDF
- flat outline
- nested outline
- repeated outline destinations
- scanned/image-only PDF
- mixed native + scanned PDF
- non-English text where deterministic
- repeated headers/footers for later cleanup phases

Runtime-generated fixtures are preferred when Quartz/PDFKit can create the exact structure being tested. Check in binary fixtures only when a real PDF feature cannot be reproduced reliably with APIs.

## Parser invariants captured by tests

- invalid bytes produce `invalidPDF`
- missing URLs produce `fileNotFound`
- encrypted/locked PDFs produce `passwordProtected`
- metadata title and author are retained
- URL filename is the fallback title when PDF metadata lacks a title
- fallback chapters are created for usable PDFs without outlines
- digital and image-only pages can coexist in one document
- scanned detection is based on native-text availability
- audiobook chunks preserve selected-text order
- flat and nested outline hierarchy is preserved
- repeated destinations are represented as a known baseline before Phase 2 changes them

## Cleaner/chunker coverage

`PdfTextCleaner` tests cover:

- null removal
- ligature normalization
- line-break dehyphenation
- isolated page-number removal
- paragraph/newline normalization
- HTML body escaping

`TTSChunker` tests cover:

- short text
- sentence boundaries
- long-sentence fallback splitting
- empty-chunk avoidance

## CI requirements

- run on macOS 14 because the package currently targets macOS 14 and depends on PDFKit/AppKit/Vision
- use `swift test`
- tests must not depend on network access
- fixture sizes must keep ordinary CI fast
- avoid parallel XCTest execution where PDFKit/AppKit fixture generation may be sensitive to process-level graphics state

## Exit criteria

- `swift test` passes from a clean checkout
- every current core type has direct test coverage
- known parser bugs have reproducible fixtures
- the test suite can detect duplicated chapter text, wrong page provenance, excessive OCR activation, and accidental cleanup text loss

---

# Phase 1 - Page-level extraction as the source of truth

## Status

**Complete.** `PdfBook.pages` is now canonical, `PdfPageContent` preserves source indexes/native text/extraction source/confidence, OCR and empty page counts are page-based, `allPlainText()` is page-derived, and audiobook segments expose exact `sourcePageRange` values. CI currently passes 35 tests on macOS 14 / Swift 5.10.

## Objective

Replace anonymous page tuples with a durable page model and make every downstream chapter/segment traceable back to source pages.

## Core design

Use:

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

`nativeText` is retained for diagnostics and for later OCR/native quality decisions. If future large-document profiling proves retention too expensive, make it configurable rather than deleting provenance immediately.

## Implemented page pipeline

The parser now follows explicit page stages:

1. resolve the source `PDFPage` for an exact source index
2. extract native text
3. evaluate the existing OCR trigger
4. optionally OCR
5. select native vs OCR result
6. run page-local cleanup
7. emit one `PdfPageContent`

A source page that cannot yield usable text still emits `.empty`; no page is omitted from the canonical sequence.

## Canonical page invariants

- parser-produced `PdfBook.pages.count == metadata.pageCount`
- `pageIndex` is the source PDF index, not a post-transform array position
- empty pages remain explicit placeholders so later indexes cannot shift
- manually-created books canonicalize duplicate page indexes rather than letting later provenance lookup crash
- pages are exposed in ascending source order

## Book-level semantics

With canonical pages available:

- `ocrPageCount` counts actual `.ocr` pages
- `emptyPageCount` counts empty canonical pages
- `totalWords` uses canonical selected page text
- `allPlainText()` emits canonical selected page text once and in source order
- legacy manually-created books without page models retain chapter-based compatibility behavior

## Segment provenance

`AudiobookSegment` now exposes:

```swift
public let sourcePageRange: ClosedRange<Int>
```

The previous `pageIndex` behavior remains available as a compatibility alias for the lower bound.

During Phase 1, chunks are deliberately bounded to individual source pages. This produces exact provenance immediately. Phase 5 may merge text across page boundaries while widening `sourcePageRange` to cover every contributing page.

## Tests

Coverage proves:

- mixed native/OCR pages preserve source indexes
- OCR-disabled image pages become `.empty` without shifting later indexes
- automatic OCR records `.ocr` provenance on the scanned page
- an empty middle page does not shift a later page from source index 2
- actual OCR/empty page counts are correct
- fallback chapter page ranges match underlying source pages
- `allPlainText()` contains each source page marker exactly once
- audiobook segments from a multi-page chapter report `0...0`, `1...1`, etc. rather than all claiming the chapter start page
- duplicate manually-supplied page indexes are canonicalized safely

## Exit criteria

- every selected text block is traceable to its source page
- `PdfBook.pages.count == metadata.pageCount` for parser-produced valid PDFs
- no page index is inferred from a transformed array position
- OCR page counts are correct
- existing simple `parse(at:)`, `parse(data:)`, chapters, and audiobook usage remain straightforward

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
- reserve document-level failure for cases where parsing cannot produce a meaningful document at all

Optional per-page diagnostics can identify OCR failures without blocking import.

## Tests

- `.never` never invokes/chooses OCR
- `.always` evaluates OCR for every usable page
- `.auto` avoids OCR on sufficiently good digital pages
- `.auto` OCRs image-only pages
- explicit languages propagate into Vision request configuration
- automatic language detection configuration is respected
- OCR failure preserves good native text
- multilingual scanned fixture produces non-empty selected text
- mixed documents report accurate `.native/.ocr/.empty` page sources

## Exit criteria

- non-English scanned PDFs are not forced through English OCR
- ordinary digital PDFs remain on native extraction
- OCR rendering is lazy and page-scoped
- OCR failure cannot unnecessarily destroy good native text
- configuration stays small and caller-friendly

---

# Phase 4 - Audiobook-oriented document cleanup

## Objective

Remove artifacts that sound bad when spoken while staying conservative enough to avoid deleting legitimate book content.

## Pipeline split

Separate cleanup into:

1. **page-local normalization** — safe transformations that require only one page
2. **document-level cleanup** — transformations that require comparing multiple pages

This prevents `PdfTextCleaner` from accumulating document-wide heuristics in a single raw-string function.

## Page-local normalization

Retain/improve:

- null/control-character removal
- safe Unicode/ligature normalization
- whitespace normalization
- line-wrap dehyphenation
- isolated page-number filtering

Dehyphenation must be conservative. Do not blindly remove every `-\n`; preserve likely semantic compounds and punctuation when evidence is ambiguous.

## Repeated header/footer detection

Detect candidates from a bounded number of first/last lines on each page.

Suggested process:

1. normalize candidate line for comparison (trim, collapse spaces, optionally normalize digits)
2. count occurrences by approximate vertical role (header vs footer)
3. require recurrence across a meaningful fraction/minimum number of pages
4. exclude long lines and paragraph-like content
5. remove only candidate lines that meet conservative recurrence rules

Account for alternating odd/even page headers. A book may alternate title and author/chapter name.

Never remove a line from a page merely because it appears twice in the whole book.

## Page numbers

Support:

- plain Arabic numbers
- `Page 12`-style short markers
- optional Roman numeral front matter when isolated

Do not remove numbers embedded in body paragraphs, dates, headings, or lists.

## Paragraph reconstruction

PDF native text often contains line breaks caused by visual layout rather than semantic paragraphs.

Conservative strategy:

- preserve blank-line paragraph boundaries
- join adjacent wrapped lines when punctuation/casing suggests one paragraph
- preserve likely headings/list items
- do not run expensive language models

This logic should be separately testable from OCR.

## Text-loss guardrails

For every cleanup stage:

- make transforms deterministic
- keep optional debug statistics (characters/lines removed)
- reject or disable a heuristic if it removes an implausibly large share of document text
- tests should compare key markers before/after cleanup

A configurable cleanup policy can allow Spokio to choose conservative/default behavior.

## Tests

- repeated identical headers
- alternating odd/even headers
- repeated footers
- page numbers only
- legitimate repeated chapter title inside body content is preserved
- hyphenated compounds vs line-wrap hyphenation
- paragraphs spanning visual lines
- bullet/list lines preserved
- cleanup cannot remove unique page markers

## Exit criteria

- common book PDFs no longer speak repeated headers/footers/page numbers
- canonical body content survives cleanup exactly once
- cleanup remains linear/near-linear and lightweight
- risky transforms can be disabled/configured

---

# Phase 5 - TTS segmentation and source mapping

## Objective

Produce robust, deterministic speech chunks with precise source provenance while remaining engine-agnostic.

## Segmentation architecture

Move from returning bare `[String]` internally to a segment candidate structure that can retain provenance through splitting.

Conceptually:

```swift
struct TextSpan {
    let text: String
    let sourcePageRange: ClosedRange<Int>
}
```

Final `AudiobookSegment` is then created from spans rather than trying to infer the page after text has already been concatenated and split.

## Boundary preferences

In order:

1. chapter boundary
2. paragraph boundary
3. sentence boundary
4. clause/punctuation boundary where practical
5. whitespace boundary
6. Unicode-safe hard boundary as last resort

Never split by integer offsets that assume Swift `String` uses byte/UTF-16 indexing.

## Sentence handling

Improve beyond `.`, `!`, and `?` while avoiding an oversized NLP dependency.

Consider:

- common abbreviations (`Mr.`, `Dr.`, `e.g.`)
- decimal numbers
- ellipses
- dialogue punctuation/quotes
- Unicode sentence punctuation

Foundation linguistic APIs may be evaluated if available/reliable on supported platforms, but deterministic behavior is more important than cleverness.

## Cross-page chunks

Once page provenance exists, chunks may span page boundaries when it improves speech continuity.

When merging spans:

- preserve a page break as a soft boundary
- compute `sourcePageRange` as first contributing page through last contributing page
- never reorder source spans
- do not merge across chapter boundaries

## Size policy

Keep character-limit support for current Spokio engines, but design around a strategy type so future engines can use word/token/time-based budgets.

Avoid an API that hard-codes one specific TTS model's token accounting into PDFKitAudio.

## Deterministic IDs

Current chapter UUID-derived segment IDs are not stable between parses.

Introduce deterministic identity based on stable inputs such as:

- chapter order/stable chapter identity
- segment order within chapter
- source page range

Do not hash full user text unless there is a concrete need; simple deterministic structural IDs are easier to reason about.

## Tests

- multi-paragraph chapter
- long sentence exceeding maximum
- abbreviations
- decimal numbers
- quoted dialogue
- emoji/non-Latin Unicode
- cross-page paragraph
- empty pages between text pages
- stable segment ordering and IDs across repeated parses
- concatenated segments reproduce selected canonical text modulo expected whitespace normalization

## Exit criteria

- no malformed Unicode splits
- no empty segments
- source ranges cover every contributing page
- repeated parse produces stable segmentation
- chunk size constraints are respected
- segmentation remains independent from a particular TTS engine

---

# Phase 6 - Concurrency, cancellation, and progressive parsing

## Objective

Make large and bulk PDF imports responsive without coupling PDFKitAudio to Spokio's job system.

## Public async API

Add an async API alongside the synchronous compatibility path, for example:

```swift
public func parse(at url: URL) async throws -> PdfBook
```

Avoid ambiguous overload ergonomics if Swift call sites become confusing; a distinct name such as `parseAsync` is acceptable if necessary.

The synchronous API may internally share the same pure extraction helpers rather than one wrapping the other with blocking constructs.

## Progress

Expose lightweight structured progress, e.g.:

```swift
enum PdfParsingStage {
    case loading
    case extracting
    case ocr
    case buildingChapters
    case cleaning
}

struct PdfParsingProgress {
    let stage: PdfParsingStage
    let completedPages: Int
    let totalPages: Int
}
```

Progress requirements:

- monotonic completed-page count within a stage
- no callbacks after completion/cancellation
- avoid high-frequency UI spam; at most page-level updates are sufficient
- caller decides which actor/UI context handles progress

Use `AsyncStream` or a callback only if the resulting API remains straightforward. Do not add a bespoke reactive framework dependency.

## Cancellation

Check cancellation:

- before starting each page
- before expensive page rendering
- immediately after OCR returns
- before chapter/document-wide post-processing

Vision requests should be cancelled if practical. If an individual synchronous system operation cannot be interrupted, cancellation should take effect before the next expensive step.

Cancellation should throw `CancellationError` rather than a package-specific generic parsing error.

## Thread/actor safety

Audit PDFKit and AppKit object usage carefully.

- do not assume `PDFDocument`/`PDFPage` are freely Sendable
- keep document/page access on a controlled execution context if required
- move immutable extracted strings/page models across concurrency boundaries, not live PDFKit objects
- remove `@unchecked Sendable` where a safer design can express ownership

This is more important than maximizing parallelism.

## Parallelism policy

Do not OCR many high-resolution pages concurrently by default; memory spikes matter more than theoretical throughput.

Start with sequential or tightly bounded OCR concurrency. Benchmark before increasing it.

Native extraction is already fast enough that aggressive page parallelism may not provide meaningful value.

## Memory strategy

- render only the page currently being OCR'd (or a very small bounded batch)
- release image intermediates after OCR
- avoid retaining duplicate chapter + full-page + segment text copies where measurable
- use autorelease pools around repeated AppKit/PDFKit image work if profiling indicates benefit

Consider optional omission of `nativeText` only after measuring real large PDFs.

## Progressive output

Evaluate, but do not automatically expose, page streaming.

A progressive page stream is useful if Spokio wants to begin planning/generating speech before an entire 1000-page PDF finishes parsing. However, do not complicate Phase 6's main API unless there is a real integration benefit.

Potential later shape:

```swift
AsyncThrowingStream<PdfPageContent, Error>
```

Chapter construction still requires enough global context to finalize TOC/document cleanup.

## Tests

- cancellation before parse
- cancellation during multi-page extraction
- progress reaches total pages
- no progress after cancellation
- async output equals synchronous output for deterministic digital fixtures
- repeated large-ish fixture does not deadlock
- actor/thread sanitizer review if practical

## Exit criteria

- Spokio can import without blocking its main actor
- parsing can be cancelled cooperatively
- progress can drive project/job UI
- resource usage stays bounded
- concurrency design does not rely on unchecked PDFKit Sendability assumptions

---

# Phase 7 - Platform cleanup and package polish

## Objective

Make the package reusable across intended Spokio targets and reduce presentation/application concerns inside the parser.

## iOS portability

Audit all `AppKit` dependencies:

- cover thumbnail encoding
- PDF OCR page rendering
- image conversion
- demo-specific UI

Prefer Core Graphics/ImageIO or small platform adapters where practical.

Add iOS to `Package.swift` only after the package builds/tests cleanly there. Do not claim iOS support simply because PDFKit/Vision exist on iOS.

Suggested minimum should match Spokio's actual deployment target rather than choosing an arbitrary low version.

## Remove presentation concerns

`htmlPreview` and HTML styling are presentation-layer behavior.

Options in preference order:

1. remove HTML generation from the parsing core if Spokio does not need it
2. move it into a separate helper/presentation module
3. if retained, correctly escape title and metadata as well as text

The parser's durable output should be structured text/provenance, not pre-styled HTML.

## Model immutability

Review mutable public properties on `PdfChapter`, `PdfMetadata`, and TOC types.

Prefer immutable values unless mutation is a deliberate supported workflow. Derived metrics such as word counts should ideally be computed or initialized consistently so callers cannot create stale combinations.

## Stable identities

Replace random UUID identities where persisted/regenerated models benefit from stable IDs:

- pages: page index already solves this
- TOC: outline path
- chapters: deterministic boundary/order identity
- segments: deterministic chapter/segment identity

## Errors and diagnostics

Separate fatal parse errors from recoverable page diagnostics.

Fatal examples:

- file missing
- unreadable/not a PDF
- locked/password protected without password support

Recoverable examples:

- one page OCR failure
- unresolved outline destination
- empty source page

Avoid enum cases that are defined but never meaningfully used.

## Documentation

README should include:

- installation
- fastest native-only parse
- default selective OCR parse
- explicit OCR configuration
- access pages/chapters/TOC
- generate TTS segments
- known limitation: complex reading order/multi-column layouts
- statement that parsing is on-device/local

Do not market the library as arbitrary document understanding.

## Exit criteria

- supported platforms are explicit and verified
- public API has no accidental presentation coupling
- stable model identity exists where useful
- errors have clear semantics
- README reflects real capabilities/limitations

---

# Phase 8 - Spokio integration validation

## Objective

Prove the hardened package against the real Spokio project workflow before treating it as the primary PDF ingestion path.

## Integration strategy

Use a pinned branch/commit during development, then tag a stable PDFKitAudio version once validation passes.

Keep Spokio responsibilities outside this library:

- project/job persistence
- queue scheduling
- TTS engine selection
- audio output paths
- retry policy for generation jobs
- user-facing progress/error UI

PDFKitAudio should return structured parsed content and parsing progress only.

## Validation corpus

Test a curated local corpus containing at minimum:

### Digital books

- normal novel with TOC
- novel without TOC
- deeply nested TOC
- front matter before Chapter 1

### Scans

- clean English scan
- Vietnamese scan
- mixed native + scanned book
- low-quality scan to exercise OCR failure/fallback behavior

### Layout stress cases

- two-column academic paper
- magazine-like layout
- tables
- image-heavy document

These stress cases establish documented limitations; they do not automatically justify adding Granite Docling back into the default path.

### Scale

- ~100 pages
- ~500 pages
- 1000+ pages if practical

## Measurements

Record:

- total parse time
- native extraction time
- OCR page count and OCR time
- peak memory where practical
- pages/sec native path
- duplicated text incidents
- missing text incidents
- chapter count/boundary quality
- segment count
- cancellation responsiveness

Separate digital and scanned metrics; averaging them together hides OCR cost.

## Quality sampling

For representative books, manually inspect/listen to:

- beginning/front matter
- first chapter transition
- middle chapter transition
- last chapter
- pages with headers/footers
- page-boundary sentences
- OCR pages

Speech quality matters more than visually recreating the PDF.

## Performance targets

Do not invent strict numbers before baseline measurements, but establish release gates from measured Phase 8 data.

Desired characteristics:

- digital PDFs feel near-immediate relative to TTS generation time
- no model initialization/download
- memory does not scale as if every page were rendered at once
- OCR cost scales mainly with pages that actually need OCR
- cancellation takes effect before substantial additional pages are processed

## Spokio release gate

Before replacing any existing parser path:

- no known duplicate-page/chapter bug
- no incorrect segment provenance bug
- multilingual OCR configuration verified
- large digital PDF import is stable
- bulk project cancellation is stable
- known complex-layout limitations documented
- parser version pinned/tagged

## Fallback policy

Do not silently route difficult PDFs to Granite Docling in production during this project.

If PDFKitAudio detects low-quality extraction, Spokio may surface a warning such as "This PDF has a complex layout; extracted reading order may be imperfect." A separate advanced parser can be evaluated later as an explicit user choice if real demand justifies its cost.

## Exit criteria

- representative Spokio PDFs import quickly without heavy model startup
- user can cancel/progress large imports
- generated audio does not contain known systematic duplicate header/page/chapter artifacts
- page/chapter/segment provenance is trustworthy
- performance and known limitations are documented with measured data

---

# Recommended implementation order

1. Phase 0 - tests ✅
2. Phase 1 - page model/provenance ✅
3. Phase 2 - TOC correctness
4. Phase 3 - multilingual OCR
5. Phase 4 - document-level cleanup
6. Phase 5 - TTS segmentation
7. Phase 6 - async/cancellation/progress
8. Phase 7 - platform/API polish
9. Phase 8 - Spokio validation

Phases 0-3 form the minimum correctness foundation before PDFKitAudio should become Spokio's primary PDF parser. Phase 4 provides the biggest direct speech-quality improvement. Phases 5-6 make the package suitable for large and bulk project workflows.
