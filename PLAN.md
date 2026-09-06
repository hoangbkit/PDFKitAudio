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

## Phase 0 - Baseline and safety net

### Objectives

Establish regression coverage before changing parser behavior.

### Work

- Add a SwiftPM test target.
- Add small PDF fixtures covering:
  - normal digital text PDF
  - empty PDF / invalid input
  - password-protected PDF
  - flat outline/TOC
  - nested outline/TOC
  - repeated TOC destinations
  - scanned page
  - mixed digital + scanned pages
  - non-English text/OCR where practical
  - repeated headers/footers
- Add unit tests for `PdfTextCleaner` and `TTSChunker`.
- Add parser-level tests for page count, chapter ranges, OCR flags, and text preservation.
- Document known PDFKit reading-order limitations, especially multi-column layouts.

### Exit criteria

- `swift test` runs successfully on the supported macOS target.
- Current behavior is captured well enough that later phases can change behavior intentionally rather than accidentally.

## Phase 1 - Introduce page-level extraction as the source of truth

### Objectives

Stop discarding page boundaries early and establish reliable provenance for all downstream output.

### Work

- Add a public page model, e.g. `PdfPageContent`, containing:
  - `pageIndex`
  - cleaned text
  - raw/native text when useful
  - extraction source (`native`, `ocr`, possibly `empty`)
  - confidence
- Make `PdfBook` retain `[PdfPageContent]`.
- Build chapters from page objects rather than anonymous tuples.
- Keep existing chapter-facing APIs where practical to reduce breakage.
- Fix `ocrPageCount` so it counts actual OCR-sourced pages.
- Update `AudiobookSegment` provenance to reference the true source page or page range instead of always using the chapter start page.
- Add tests for mixed native/OCR documents and segment provenance.

### Exit criteria

- Every extracted text unit can be traced back to one or more PDF pages.
- OCR counts and segment page metadata are correct.
- Existing basic `PdfParser.parse(at:)` and `parse(data:)` workflows remain simple.

## Phase 2 - Fix TOC and chapter construction correctness

### Objectives

Prevent duplicated spoken text and make nested outlines safe for audiobook generation.

### Work

- Separate navigation TOC from audiobook chapter boundaries.
- Prefer top-level TOC entries for default chapter generation.
- Preserve nested children for navigation metadata.
- Deduplicate or normalize repeated destinations/page starts.
- Define behavior for multiple outline entries pointing to the same page.
- Ignore invalid or out-of-range outline destinations safely.
- Ensure chapter page ranges do not overlap unless explicitly intended.
- Improve fallback chapter naming when no usable TOC exists.
- Keep heuristic chapter detection conservative; avoid inventing excessive chapters.

### Exit criteria

- Nested TOCs do not cause duplicated text in `allPlainText()` or audiobook scripts.
- Chapter ranges are monotonic and non-overlapping for the default audiobook path.
- Flat and nested TOC fixtures have deterministic results.

## Phase 3 - Make OCR multilingual, selective, and configurable

### Objectives

Keep OCR lightweight while making it suitable for Spokio's multilingual use cases.

### Work

- Replace hard-coded `en-US` OCR with parser configuration.
- Add options for:
  - explicit recognition languages
  - automatic language detection when supported
  - Vision recognition level
- Keep `.auto`, `.always`, and `.never` modes.
- Improve the `.auto` OCR trigger beyond a single character-count threshold where inexpensive signals help.
- Preserve native extraction when it is clearly better than OCR.
- Record OCR confidence per page.
- Avoid rendering all pages up front; process only pages that require OCR.
- Add multilingual fixtures/tests where reliable in CI.

### Exit criteria

- Non-English scanned PDFs are not forced through English OCR.
- Digital PDFs still avoid OCR in the common path.
- OCR configuration is exposed through a small, stable API.

## Phase 4 - Improve audiobook-oriented text cleanup

### Objectives

Remove common PDF artifacts that sound bad when spoken without introducing heavy layout analysis.

### Work

- Split cleanup into page-local and document-level cleanup.
- Keep current normalization for nulls, ligatures, whitespace, and line-wrap dehyphenation.
- Add repeated header/footer detection by comparing candidate lines across pages.
- Remove isolated page numbers conservatively.
- Preserve paragraph boundaries where possible.
- Avoid aggressive dehyphenation when the hyphen is likely semantic.
- Add configurable cleanup options so callers can disable risky transforms.
- Ensure cleanup never silently drops large blocks of text.
- Add regression fixtures for books with repeating headers/footers.

### Exit criteria

- Common book PDFs no longer speak repeated running headers, footers, and page numbers.
- Cleanup remains deterministic and fast.
- Tests guard against accidental text loss.

## Phase 5 - Harden TTS segmentation and source mapping

### Objectives

Produce robust chunks for Spokio generation while keeping segmentation independent of any specific TTS engine.

### Work

- Improve sentence splitting beyond only `.`, `!`, and `?` where useful.
- Preserve paragraph boundaries as preferred chunk boundaries.
- Avoid splitting inside common abbreviations where practical.
- Never hard-cut Unicode text using unsafe assumptions.
- Carry source page/page-range metadata into each segment.
- Keep max-character configuration but structure the API so token/word-aware strategies can be added later.
- Add tests for very long sentences, dialogue, abbreviations, Unicode, and paragraph-heavy text.

### Exit criteria

- Generated chunks are stable, non-empty, ordered, and source-traceable.
- Long inputs cannot produce malformed Unicode slicing or obviously broken segment boundaries.

## Phase 6 - Concurrency, cancellation, and progressive parsing

### Objectives

Make large-PDF imports responsive in Spokio without moving parsing logic into the app.

### Work

- Add an async parsing API while retaining synchronous APIs if useful for compatibility.
- Support cooperative cancellation between pages and OCR operations.
- Add lightweight progress reporting by page count.
- Keep PDFKit/Vision work off the main actor.
- Avoid unbounded in-memory intermediates for large PDFs.
- Consider yielding page results progressively if it improves Spokio's project workflow without complicating the public API excessively.
- Remove unnecessary `@unchecked Sendable` usage where stronger isolation can be expressed safely.

### Exit criteria

- Spokio can show import progress and cancel large PDF parsing.
- Parsing a large document does not require blocking the UI thread.
- Memory usage scales predictably with document size.

## Phase 7 - Platform cleanup and package polish

### Objectives

Keep the library reusable across Spokio targets and make its public API production-ready.

### Work

- Evaluate iOS support by abstracting `AppKit`-specific image conversion.
- Add iOS to `Package.swift` if the implementation and tests are cleanly portable.
- Remove HTML preview generation from the core parser or move it behind a presentation helper.
- If HTML remains, escape title/metadata as well as body text.
- Review public models for unnecessary mutability.
- Replace UUID-only identities where stable deterministic identity helps persistence or regeneration.
- Tighten error reporting for invalid, encrypted, empty, and OCR-failed documents.
- Add README usage examples centered on lightweight parsing and TTS ingestion.

### Exit criteria

- Public API is small, documented, and decoupled from UI concerns.
- Package support matches Spokio's intended platforms.
- No unsafe HTML interpolation remains.

## Phase 8 - Spokio integration validation

### Objectives

Prove the library against Spokio's real PDF project workflow before declaring it stable.

### Work

- Integrate a pinned branch/tag into a Spokio development branch.
- Test representative real-world PDFs:
  - novels/books
  - scanned books
  - mixed PDFs
  - Vietnamese/non-English documents
  - PDFs with nested TOCs
  - large PDFs
- Measure:
  - import latency
  - OCR frequency
  - peak memory
  - chapter count quality
  - duplicated/missing text
  - TTS segment quality
- Keep Granite Docling out of the default path.
- Document known unsupported/problematic layouts such as complex multi-column academic papers.

### Exit criteria

- Common PDFs reach usable TTS text quickly with no heavy model startup.
- No known duplicated-chapter or wrong-page provenance bugs remain.
- Performance is acceptable for Spokio's project workflow on supported Macs.

## Recommended implementation order

1. Phase 0 - tests
2. Phase 1 - page model/provenance
3. Phase 2 - TOC correctness
4. Phase 3 - multilingual OCR
5. Phase 4 - document-level cleanup
6. Phase 5 - TTS segmentation
7. Phase 6 - async/cancellation/progress
8. Phase 7 - platform/API polish
9. Phase 8 - Spokio validation

The first four phases should provide the highest-value path to a safe Spokio integration. Later phases can be delivered incrementally once the parser is already useful in production.
