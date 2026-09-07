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
- [x] Phase 2 - TOC resolution and chapter construction correctness
- [x] Phase 3 - multilingual, selective, configurable OCR
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
    public let pageIndex: Int
    public let nativeText: String
    public let text: String
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

## Status

**Complete.** OCR is now configured through `PdfOCRConfiguration`, automatic language detection is enabled by default without a package-level English override, native-text quality drives automatic OCR activation, and OCR output only replaces native extraction when it is materially better. Backward-compatible `PdfParser()` and `PdfParser(ocrMode:)` initializers remain available.

## Objective

Keep OCR lightweight while making it suitable for Spokio's multilingual use cases and reducing false OCR activation.

## Public configuration shape

The implemented configuration is:

```swift
public struct PdfOCRConfiguration: Sendable {
    public var mode: OCROptions
    public var nativeTextThreshold: Int
    public var recognitionLanguages: [String]
    public var automaticallyDetectsLanguage: Bool
    public var recognitionLevel: PdfOCRRecognitionLevel
    public var usesLanguageCorrection: Bool
}
```

A package-owned recognition-level enum avoids forcing callers to import Vision.

## OCR language behavior

- no package-level `en-US` hard-code remains
- Vision automatic language detection is enabled by default
- explicit recognition languages are passed through when supplied
- language codes are trimmed and deduplicated deterministically
- metadata language is optional/unknown unless the parser actually has a reliable detected-language signal
- OCR language configuration stays independent from Spokio TTS voice selection

## Auto-OCR decision policy

Automatic mode uses cheap native-text signals only and does not render merely to decide whether rendering is needed.

The policy classifies native extraction as:

- empty
- insufficient
- suspicious
- usable

Signals include selected character count, alphanumeric/information ratio, Unicode replacement characters, and unexpected control characters.

Behavior:

1. empty native text -> OCR candidate
2. short native text -> OCR candidate
3. suspicious/garbled native text -> OCR candidate
4. sufficiently long, text-like native extraction -> stay native with zero OCR work

`.never` performs no OCR work. `.always` attempts OCR for every page but still does not force OCR output to win.

## Native-vs-OCR selection

OCR output is selected only when it is non-empty and satisfies confidence/information-gain requirements appropriate to native-text quality.

- missing native text accepts a minimally credible OCR result
- short/suspicious native text requires usable OCR confidence and comparable information
- healthy native text is replaced only by high-confidence OCR with material information gain
- empty, failed, or weak OCR falls back to native text when native text exists
- image-only OCR failure remains an empty page rather than failing the full document

## Rendering strategy

- only OCR-candidate pages are rendered in auto mode
- page aspect ratio is preserved
- maximum rendered dimension is bounded to 2200 pixels
- unusually small page coordinates are capped at 3x scale
- page images are scoped to one recognition call and are not retained by the document model
- the full PDF is never pre-rendered for OCR

## Tests

Coverage proves:

- `.never` invokes the OCR recognizer zero times
- `.auto` invokes OCR zero times for strong native pages
- `.auto` triggers for empty, short, and suspicious native extraction
- `.always` attempts OCR while preserving better native text
- explicit recognition languages reach `VNRecognizeTextRequest`
- automatic language detection configuration reaches Vision
- recognition level and language-correction settings propagate correctly
- OCR wins when native extraction is missing and OCR is usable
- weak OCR cannot replace healthy native extraction
- a real French scanned fixture is recognized successfully through Vision
- configuration thresholds and language lists normalize deterministically

## Exit criteria

- non-English scanned PDFs are no longer forced through English OCR
- ordinary digital PDFs remain on native extraction with zero OCR work in auto mode
- OCR rendering is lazy and page-scoped
- OCR failure cannot unnecessarily destroy good native text
- configuration stays small and caller-friendly
- Phase 3 regression suite is green on macOS 14 / Swift 5.10

---

# Phase 4 - Audiobook-oriented document cleanup

## Objective

Improve spoken output for normal books and reports without adding a heavyweight layout model.

## Design split

Separate cleanup into two levels:

1. **page-local normalization** - safe transformations that need only one page
2. **document-level cleanup** - transformations that require statistics across pages

## Page-local normalization

Retain conservative transformations such as:

- null/control cleanup
- common ligature normalization
- whitespace normalization
- obvious line-wrap dehyphenation

Review the current unconditional isolated-number removal; years, numbered data, and legitimate standalone numeric content must not be deleted simply because they look like a page number.

## Repeated header/footer detection

The most valuable audiobook cleanup is repeated running matter.

Suggested algorithm:

1. retain raw leading/trailing candidate lines for each page before final line collapsing
2. normalize candidates for comparison:
   - trim whitespace
   - collapse internal spaces
   - optionally normalize changing page-number tokens
   - compare case-insensitively where safe
3. count normalized candidates across pages
4. only remove a candidate when it appears near the same page edge on a meaningful fraction of eligible pages
5. never remove long body-like lines merely because they repeat twice

Conservative thresholds are important for short documents.

Examples worth detecting:

- book title repeated at every top edge
- author name repeated at top/bottom
- `Chapter 4` running header
- page number alone
- `Some Book • 42` with changing numeric suffix

## Page-number policy

Replace blanket "standalone <=4 digit" removal with context-aware logic.

A numeric line is safer to remove when:

- it is at the first/last line of a page
- neighboring pages contain similarly positioned sequential numbers
- or it participates in a repeated header/footer pattern

Preserve legitimate body numbers such as years, scores, quantities, and numbered examples.

## Dehyphenation policy

Current `-\n` removal can corrupt real compounds.

Prefer joining only when:

- previous fragment ends in an alphabetic word + hyphen
- next line begins with lowercase alphabetic continuation
- neither fragment strongly resembles a heading/list item

Preserve explicit compounds when continuation looks like a new word/heading.

## HTML preview safety

If `htmlWrap` remains:

- escape title
- escape body
- document that output is presentation HTML, not sanitized arbitrary user HTML

If Spokio does not consume HTML preview, consider deprecating/removing it in Phase 7 rather than investing heavily in it.

## Reading-order boundary

PDFKit's page string order may be wrong for multi-column layouts.

For this project:

- document the limitation
- do not reintroduce a heavyweight layout model
- consider a lightweight geometry-based experiment only if real Spokio PDFs show this is common enough to justify complexity

## Tests

Add multi-page text fixtures for:

- repeated header every page
- alternating header
- changing page number footer
- legitimate year on a line
- legitimate numeric data line
- real hyphenated compound
- line-wrap hyphenation
- title containing `&`, `<`, `>` and quotes
- short document where repetition threshold should not over-delete

For every cleanup fixture assert important body markers remain exactly once.

## Exit criteria

- common running headers/footers are not spoken every page
- legitimate standalone numbers are not broadly deleted
- dehyphenation is more conservative than the current implementation
- HTML title/body cannot inject markup accidentally
- cleanup remains deterministic and lightweight

---

# Phase 5 - TTS segmentation and exact source mapping

## Objective

Produce stable, speech-friendly chunks without cutting words unnecessarily and without losing source-page provenance.

## Configuration

Move from a bare integer toward a focused configuration while keeping the convenience API.

Candidate:

```swift
public struct TTSChunkingConfiguration: Sendable {
    public var maxCharacters: Int
    public var preferredMinimumCharacters: Int
    public var preserveParagraphs: Bool
}
```

Do not expose TTS-engine-specific tokenizers in this package unless a real integration requires them.

## Validation

Public entry points must safely handle invalid sizes.

- `maxCharacters <= 0` must never cause stride-by-zero or an infinite loop
- choose either a precondition with clear API contract or clamped/empty behavior; throwing configuration validation is preferable if this becomes a richer API
- avoid empty output chunks

## Boundary preference

Split in this priority order:

1. paragraph boundary near target size
2. sentence boundary
3. clause/punctuation boundary if useful
4. whitespace/word boundary
5. hard character boundary only for an unbroken token longer than the limit

Do not cut a normal word merely because a sentence exceeds the limit.

## Sentence handling

The current punctuation scanner is intentionally simple but splits abbreviations poorly.

Evaluate Foundation/NaturalLanguage sentence tokenization before inventing a complex custom parser. Compare:

- startup/throughput overhead
- multilingual behavior
- abbreviation handling
- deterministic chunk size control

If system sentence enumeration gives adequate results with negligible overhead, prefer it.

## Cross-page segmentation

Phase 1 page-bounded chunks are correct but can produce unnaturally tiny segments at page boundaries.

Phase 5 may merge content across adjacent pages inside a chapter when:

- combined size stays within configured maximum
- paragraph/sentence flow indicates continuity
- source range is widened to include every contributing page

Never merge across audiobook chapter boundaries by default.

## Source mapping model

At minimum retain:

```swift
sourcePageRange: ClosedRange<Int>
```

If implementation remains tractable, internally retain per-piece page attribution during chunk assembly so the final range is calculated rather than guessed.

Segment IDs should be deterministic for a stable parsed book where practical. Random chapter UUIDs currently make repeatability weaker.

## TTS-library boundary

Before locking this API, compare against Spokio's existing TTS job/segmentation layer.

If Spokio already owns model-specific chunking, PDFKitAudio should stop at cleaned chapter/page text plus provenance rather than competing with a better central chunker.

The likely durable responsibility split is:

- PDFKitAudio: document extraction + semantic-ish page/chapter structure + provenance
- Spokio: engine-specific generation chunking, retries, queueing, duration constraints

## Tests

- invalid/zero/negative maximum
- exact-limit string
- very long unbroken token
- long sentence containing spaces
- abbreviations
- decimals
- quotes after terminal punctuation
- paragraph-preferred boundaries
- multilingual punctuation where system tokenizer supports it
- cross-page merge carries correct source range
- no chunk exceeds maximum unless explicitly documented for an unsplittable unit
- normalized concatenated chunks equal normalized input

## Exit criteria

- no crashes for caller-provided chunk size
- ordinary words are not hard-cut
- chunk ordering is deterministic
- concatenated chunk text preserves input content
- page ranges remain accurate when pages are merged
- responsibility does not conflict with Spokio's generation pipeline

---

# Phase 6 - Concurrency, cancellation, progress, and large-document behavior

## Objective

Make parsing safe for large PDFs and Spokio bulk/project workflows without forcing apps to manage synchronous PDFKit/Vision work manually.

## Public API strategy

Keep synchronous APIs for simple uses:

```swift
parse(at:)
parse(data:)
```

Add async equivalents rather than silently changing behavior:

```swift
parse(at:) async throws
parse(data:) async throws
```

Name overloads carefully so Swift call-site resolution stays understandable.

## Execution model

PDFKit and Vision behavior should be treated conservatively.

- do not assume arbitrary concurrent access to the same `PDFDocument` is safe
- process source pages in deterministic order
- initially keep extraction serial unless profiling proves bounded parallel OCR is safe and valuable
- if parallel OCR is introduced, bound concurrency explicitly (for example 1-2 pages) rather than creating a task per page

Correctness and peak memory matter more than maximizing CPU occupancy.

## Cancellation

Check `Task.isCancelled` / `Task.checkCancellation()`:

- before starting a page
- before expensive render/OCR work
- after OCR before committing page output
- before expensive document-level cleanup
- before chapter/segment generation if those become nontrivial

Cancellation should throw `CancellationError`, not convert to a parser-specific generic failure.

Dropping a UI task should stop future page/OCR work promptly.

## Progress

Expose progress without coupling to SwiftUI.

Possible model:

```swift
public struct PdfParsingProgress: Sendable {
    public enum Stage: Sendable {
        case opening
        case extracting
        case ocr
        case cleaning
        case chapters
        case finalizing
    }

    public let stage: Stage
    public let completedPages: Int
    public let totalPages: Int
    public let currentPageIndex: Int?
}
```

Delivery options:

- `@Sendable` callback
- `AsyncStream`

A callback is simpler for first integration; `AsyncStream` is attractive if Spokio wants native Swift concurrency consumption. Pick one primary API rather than maintaining two equal mechanisms without need.

Progress guarantees:

- never decrease
- total page count stable once document opens
- page indexes are source indexes
- no fake 100% before finalization

## Large-document memory behavior

Review allocations:

- only one/few OCR page images alive at once
- cover thumbnail retained, not source page images
- canonical page text retained intentionally
- native raw text retained only if its diagnostics benefit justifies memory
- avoid copying giant `[String]` values repeatedly while building chapters

Potential optimization: build chapter strings from canonical pages once and avoid repeated joined copies across overlapping transformations. Phase 2's non-overlap should already help.

## Benchmark harness

Do not use brittle timing assertions in unit tests.

Create opt-in benchmark tooling or tests for approximately:

- 100-page digital document
- 100-page mixed document with 10% OCR
- 25-page fully scanned document
- a document with large text pages

Record:

- elapsed parse time
- OCR attempts/selections
- total text size
- page count
- rough memory observations if available

The most important regression guard is that a digital PDF does not accidentally start OCRing most pages.

## Demo update

Replace the demo's direct `Task.detached` management with the async API once stable.

- snapshot UI configuration on the main actor
- start one parsing task
- cancel the previous task on new import
- bind progress
- ignore stale task results after cancellation

## Exit criteria

- async parsing does not block the main actor
- cancellation stops future expensive work promptly
- progress is monotonic and meaningful
- memory does not scale with rendered image size across all pages
- digital PDFs remain fast-path native extraction

---

# Phase 7 - Platform cleanup, API hardening, and package polish

## Objective

Make the package reusable and unsurprising as an Apple-platform dependency.

## Platform strategy

Current source imports AppKit directly and `Package.swift` is macOS-only.

If Spokio needs PDF parsing on iOS, support both platforms by abstracting only the small image/platform surface needed by:

- PDF page thumbnails/rendering
- image -> CGImage conversion
- cover JPEG encoding

Likely options:

```swift
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
```

Avoid a large custom graphics abstraction; most parsing should remain PDFKit/Vision/Foundation code.

Choose minimum iOS/macOS versions based on Spokio's actual deployment targets and Vision APIs used, not arbitrary latest versions.

## Sendability audit

Remove `@unchecked Sendable` where it is not justified.

Questions:

- Are public models immutable value types? Prefer real `Sendable`.
- Does `PdfBook` need to be a class? If immutable, a struct may simplify safety; do not convert solely for style if source compatibility matters.
- Does `PdfParser` actually hold non-Sendable state? If parser becomes an async worker around PDFKit, document concurrency must be explicit.

Every remaining unchecked conformance should have a reason.

## Mutability and derived metrics

`PdfChapter.plainText` is mutable while `wordCount` and `readingTimeMinutes` are stored from initialization, allowing stale metrics.

Fix by one of:

- make text immutable
- compute metrics from text
- use private setters and update derived values together

Prefer immutable parsed models unless a caller genuinely needs mutation.

Apply the same review to metadata and TOC models: public mutability should be intentional.

## Metadata language semantics

Do not default `detectedLanguage` to `"en"` unless detection actually ran and returned English.

Options:

- `String?`
- package-owned language metadata type
- remove until implemented

If language detection is useful for Spokio, derive it from selected text using a lightweight Apple framework and keep it independent from OCR configuration.

## Error API cleanup

Review unused errors:

- `pageOutOfRange`
- `ocrFailed`
- `extractionFailed`

Either wire them into meaningful public operations or remove them before callers depend on dead semantics.

For resilient whole-document parsing, page-level diagnostics may be more useful than throwing for every OCR miss.

## HTML responsibility

Decide whether `htmlPreview` belongs in the core package.

If retained:

- escape title/body
- test it
- document the output contract

If unused by Spokio:

- deprecate it or move to demo/presentation helper
- keep core focused on text/provenance

## Documentation

Add a README covering:

- what the package is for
- supported platforms
- quick start
- OCR modes/configuration
- output model
- scanned PDF behavior
- known reading-order limitations
- performance characteristics
- thread/concurrency expectations

Document that PDFKitAudio is optimized for ordinary books/documents, not arbitrary layout-perfect document reconstruction.

## Tests/CI matrix

If adding iOS support:

- keep SwiftPM/macOS tests
- compile/test an iOS target in CI where practical
- at minimum ensure the package builds for every declared platform

Do not declare platform support that CI never exercises.

## Exit criteria

- package builds for every declared platform
- no unexplained unchecked Sendable conformances
- public model mutation cannot silently corrupt derived metrics
- metadata language is truthful
- unused error cases are removed or justified
- README explains strengths and limitations

---

# Phase 8 - Spokio integration validation

## Objective

Prove the library fits Spokio's real document-to-audio workflow before treating it as the primary PDF ingestion path.

## Integration review first

Inspect current Spokio develop before coding the adapter. Specifically locate:

- document/file import boundary
- project/job model
- text normalization
- language handling
- TTS chunking
- job queue and retry behavior
- generation progress
- persistence of source references
- macOS/iOS deployment targets

Avoid duplicating responsibilities that Spokio already handles well.

## Recommended ownership boundary

PDFKitAudio should own:

- opening PDF
- native extraction
- selective OCR
- conservative document cleanup
- source-page models
- TOC navigation metadata
- optional audiobook-friendly chapter boundaries

Spokio should usually own:

- chosen TTS engine/model
- engine-specific chunk sizing/tokenization
- voice/language compatibility policy
- queue persistence
- retries
- audio file paths/cache
- generation status/progress aggregation
- bulk project orchestration

If this review shows `TTSChunker` belongs entirely in Spokio, keep it only as a convenience helper or deprecate it rather than building parallel chunking systems.

## Adapter design

Prefer a narrow conversion from parsed PDF output into Spokio's existing text/job structures.

Do not persist `PDFPage`, `PDFDocument`, `NSImage`, or Vision objects.

Persist durable primitives such as:

- source file/book identifier
- source page range
- cleaned text
- extraction source if useful for diagnostics
- OCR confidence where relevant
- chapter title/order

## Import UX

For project/bulk workflows, Spokio should be able to show at least:

- parsing stage/progress
- page count
- OCR pages or OCR-in-progress indicator
- chapter count after parse
- warnings for empty/low-confidence pages
- cancellation

Do not block import merely because some pages are non-English or lower-confidence unless the chosen TTS engine truly cannot process them.

## Real-world validation corpus

Use documents representing actual intended usage, not only synthetic fixtures:

1. normal English ebook-like PDF
2. non-English selectable-text PDF
3. non-English scanned PDF
4. mixed native/scanned PDF
5. book with nested TOC
6. book without TOC
7. report with repeating headers/footers
8. multi-column academic PDF
9. password-protected PDF
10. large 100-300 page PDF

Do not commit copyrighted commercial books into a public test repository. Use locally held validation files or redistributable fixtures.

## Compare against current Spokio parser

For each representative document record:

- import duration
- OCR pages
- detected chapter count
- total extracted words/characters
- obvious duplicated text
- obvious missing text
- repeated headers/page numbers
- reading order quality
- peak/subjective memory behavior
- resulting TTS segment count after Spokio processing

The goal is not mathematical identity with a heavier parser. The goal is better product-level tradeoff: fast enough, light enough, and good enough spoken text.

## Failure handling

Define adapter behavior for:

- invalid PDF
- password-protected PDF
- all-empty PDF
- isolated empty page
- OCR failure on one page
- cancellation
- source file disappearing mid-import

Failures should map cleanly into Spokio's existing job/project error model without exposing implementation-specific errors to users unnecessarily.

## Rollout strategy

Recommended:

1. integrate behind the new PDF project workflow
2. keep existing fallback path temporarily if one exists and is cheap to retain
3. validate on real files
4. collect/debug parser failures locally
5. make PDFKitAudio the normal lightweight path once confidence is high

Do not ship Granite Docling as an automatic fallback; that recreates the startup/memory problem this work is meant to avoid.

## Exit criteria

- representative digital PDFs import quickly without OCR
- scanned/mixed PDFs selectively OCR and retain page mapping
- no nested-TOC spoken duplication
- non-English scanned PDFs are supported according to Vision capabilities
- repeated running matter is acceptably cleaned
- large imports are cancellable and do not retain page images
- PDFKitAudio responsibilities do not overlap awkwardly with Spokio's TTS/job queue
- Spokio can display useful import progress and errors

---

# Recommended implementation order

1. Phase 0 - tests
2. Phase 1 - page model/provenance
3. Phase 2 - TOC correctness
4. Phase 3 - OCR language/configuration
5. Phase 4 - repeated header/footer cleanup
6. Phase 5 - chunking/provenance polish
7. Phase 6 - async/cancellation/progress
8. Phase 7 - package/platform cleanup
9. Phase 8 - Spokio integration

Phases 0-3 are the minimum correctness foundation before adopting the parser broadly in Spokio. Phase 4 is the highest-value speech-quality pass. Phases 5-6 make it production-ready for large and bulk project workflows. Phase 7 should happen before promising reusable iOS support. Phase 8 validates the final responsibility split against Spokio rather than guessing it in advance.

# Definition of done

PDFKitAudio is ready to act as Spokio's lightweight PDF ingestion layer when:

- digital books stay on fast native PDFKit extraction
- OCR is selective, multilingual/configurable, and page-scoped
- every page/segment has correct source provenance
- chapter generation cannot duplicate nested TOC ranges
- common running headers/footers are not spoken repeatedly
- chunking does not corrupt words or provenance
- large parses can be cancelled and report progress
- declared Apple platforms build in CI
- real Spokio integration confirms the ownership boundary is clean
