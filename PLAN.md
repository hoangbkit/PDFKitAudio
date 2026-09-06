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
- [x] Phase 4 - audiobook-oriented document cleanup
- [x] Phase 5 - TTS segmentation and source mapping
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

## Status

**Complete.** SwiftPM regression coverage, runtime PDF fixtures, macOS CI, and characterization tests are in place.

## Objective

Create enough regression coverage to safely refactor parsing internals without guessing whether behavior changed.

## Implemented

- `PDFKitAudioTests` SwiftPM target
- runtime-generated digital, scanned, mixed, encrypted, outline, and blank fixtures
- parser, TOC, cleaner, chunker, and model coverage
- macOS 14 GitHub Actions CI
- pre-existing TOC compilation issue fixed

---

# Phase 1 - Page-level extraction as the source of truth

## Status

**Complete.** `PdfPageContent` is the canonical source model with stable source indexes and native/OCR/empty provenance.

## Objective

Make every selected text block traceable to the source PDF page and prevent page-index drift.

## Implemented

- canonical `PdfBook.pages`
- deterministic page identity from page index
- explicit extraction source and confidence
- empty-page placeholders
- accurate OCR/empty-page counts
- canonical `allPlainText()`
- `AudiobookSegment.sourcePageRange`

---

# Phase 2 - TOC resolution and chapter construction correctness

## Status

**Complete.** Navigation hierarchy and spoken chapter boundaries are separate, and default spoken ranges are monotonic and non-overlapping.

## Objective

Prevent nested/repeated PDF outlines from duplicating spoken text while preserving navigation metadata.

## Implemented

- deterministic TOC path IDs
- optional unresolved destinations rather than false page zero
- `PDFDestination` and `PDFActionGoTo` resolution
- same-page and nested-outline boundary collapse
- front-matter preservation
- safe hierarchy-level fallback
- chapter coverage invariants

---

# Phase 3 - Multilingual, selective, configurable OCR

## Status

**Complete.** OCR is configured through `PdfOCRConfiguration`, automatic language detection is enabled by default without a package-level English override, native-text quality drives automatic OCR activation, and OCR output only replaces native extraction when it is materially better.

## Objective

Keep OCR lightweight while making it suitable for multilingual use and reducing false OCR activation.

## Implemented

- no package-level `en-US` hard-code
- Vision automatic language detection by default
- explicit recognition languages and recognition level
- package-owned OCR recognition-level enum
- native quality classification: empty / insufficient / suspicious / usable
- healthy digital pages stay on zero-OCR fast path
- confidence + information-gain OCR selection
- bounded aspect-preserving page rendering
- page-local OCR failures
- real non-English Vision regression coverage

---

# Phase 4 - Audiobook-oriented document cleanup

## Status

**Complete.** Cleanup is split between safe page-local normalization and conservative cross-page running-matter removal.

## Objective

Improve spoken output for books and reports without a heavyweight layout model or aggressive text deletion.

## Implemented

- `PdfCleanupConfiguration` with `.audiobookDefault` and `.minimal`
- control-character, ligature, line-ending, and whitespace normalization
- conservative line-wrap dehyphenation
- standalone numbers preserved by page-local cleanup
- repeated short header/footer detection using same-edge cross-page evidence
- alternating running headers supported
- decorated running matter such as `Some Book • 42` supported
- pure pagination removed only after a consistent sequence across at least three pages
- two-page consecutive-year regression protection
- first semantic running-header occurrence retained
- HTML title and body escaping
- untouched `nativeText` retained for diagnostics

## Reading-order boundary

PDFKit page-string order can still be imperfect for multi-column or heavily positioned layouts. That remains a documented lightweight-parser limitation rather than a reason to add a heavy layout model.

---

# Phase 5 - TTS segmentation and exact source mapping

## Status

**Complete.** PDFKitAudio now has robust engine-agnostic convenience chunking and configuration-based cross-page packing with exact provenance. Spokio's existing `TextToSpeech.ProsodyTextChunker` remains the owner of engine-facing prosody, silence, and generation limits.

## Objective

Provide stable, speech-friendly bounded text without corrupting words or losing source-page provenance, while avoiding a second TTS-engine policy layer.

## Public configuration

```swift
public struct TTSChunkingConfiguration: Sendable, Equatable {
    public var maxCharacters: Int
    public var preferredMinimumCharacters: Int
    public var preserveParagraphs: Bool
}
```

Invalid/non-positive maximum values are clamped safely, preserving the existing non-throwing convenience API.

## Implemented boundary strategy

Generic PDFKitAudio chunking prefers:

1. explicit paragraph boundaries when configured
2. Foundation sentence boundaries
3. clause punctuation for oversized sentences
4. whitespace/word boundaries
5. grapheme-safe hard splitting only for an unbroken token longer than the limit

Coverage includes abbreviations, decimals, quoted endings, multilingual/CJK punctuation, long normal sentences, and long Unicode tokens.

## Source-aware audiobook segments

The preferred configuration-based API is:

```swift
book.audiobookScript(configuration: TTSChunkingConfiguration(...))
```

It may pack adjacent short pieces across page boundaries when they remain inside the same chapter. Each output retains:

- exact union `sourcePageRange`
- deterministic global order
- stable generated segment ID using deterministic FNV-1a hashing rather than Swift `Hasher`
- character-weighted confidence across merged pages
- content ordering

Segments never merge across chapter boundaries.

The legacy `audiobookScript(maxCharsPerSegment:)` remains page-bounded so existing callers do not silently receive wider source ranges.

## Responsibility boundary validated against Spokio

Spokio `develop` already contains `Packages/TextToSpeech/Sources/TTSCore/ProsodyTextChunker.swift`. That layer models paragraph/sentence/clause/forced-word boundaries and silence durations. PDFKitAudio therefore deliberately does **not** add:

- engine tokenizers
- model-specific generation limits
- pause durations
- prosody boundary enums
- audio-generation retries or queue policy

PDFKitAudio owns document extraction, cleanup, structure, generic bounded text, and provenance. Spokio/TextToSpeech owns final engine-facing chunking and prosody.

## Exit criteria met

- invalid maximum sizes cannot crash or loop
- ordinary words are not hard-cut
- hard splits are Unicode grapheme safe
- output ordering is deterministic
- generated segment IDs are stable for stable inputs/configuration
- cross-page source ranges are calculated rather than guessed
- segments do not cross chapter boundaries
- normalized chunk content preserves source text
- responsibility does not conflict with Spokio's TTS pipeline

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
- if parallel OCR is introduced, bound concurrency explicitly rather than creating a task per page

Correctness and peak memory matter more than maximizing CPU occupancy.

## Cancellation

Check cancellation before each page, before expensive render/OCR work, after OCR before committing output, and before document-level cleanup/chapter generation. Cancellation should remain `CancellationError`.

## Progress

Expose progress without SwiftUI coupling. A focused callback model is preferred for first integration, with stages such as opening, extracting, OCR, cleaning, chapters, and finalizing. Progress must be monotonic and use source page indexes.

## Large-document memory behavior

- keep only one/few OCR page images alive at once
- do not retain page renders
- retain canonical text intentionally
- avoid repeated large string copies where practical
- measure before introducing concurrency complexity

## Benchmark harness

Use opt-in benchmarks rather than brittle timing assertions. Cover representative digital, mixed, scanned, and large-text documents and record elapsed time, OCR attempts, page count, and text size.

## Exit criteria

- async parsing does not block the main actor
- cancellation stops future expensive work promptly
- progress is monotonic and meaningful
- rendered image memory remains bounded
- digital PDFs remain on the native fast path

---

# Phase 7 - Platform cleanup, API hardening, and package polish

## Objective

Make the package reusable and unsurprising as an Apple-platform dependency.

## Platform strategy

Current source imports AppKit directly and the package is macOS-only. If Spokio needs iOS parsing, isolate the small image/platform surface with conditional AppKit/UIKit compilation and only declare platforms exercised by CI.

## Sendability audit

Remove `@unchecked Sendable` where it is not justified. Prefer immutable value models and document every remaining unchecked invariant.

## Mutability and derived metrics

`PdfChapter.plainText` is mutable while stored word-count/reading-time fields can become stale. Make parsed text immutable or compute derived metrics rather than allowing silent drift.

## Error/API cleanup

Review unused errors, HTML-preview responsibility, metadata language semantics, public mutation, and platform deployment targets before stabilizing the package API.

## Documentation/CI

Document quick start, OCR, cleanup, output provenance, concurrency expectations, strengths/limitations, and build every declared platform in CI.

## Exit criteria

- package builds for every declared platform
- no unexplained unchecked sendability
- public mutation cannot silently stale derived metrics
- metadata/error semantics are truthful
- README explains strengths and limitations

---

# Phase 8 - Spokio integration validation

## Objective

Prove the library fits Spokio's real document-to-audio workflow before treating it as the primary PDF ingestion path.

## Ownership boundary

PDFKitAudio should own opening/extraction/selective OCR/conservative cleanup/page provenance/navigation/optional audiobook chapter structure. Spokio should own TTS model choice, model-specific chunking/prosody, queue persistence, retries, audio files/cache, generation state, and project orchestration.

## Real-world validation corpus

Validate ordinary digital books, non-English digital/scanned PDFs, mixed PDFs, nested/no-TOC books, running-header reports, complex multi-column PDFs, protected PDFs, and 100-300 page files. Do not commit copyrighted/private documents publicly.

## Compare at product level

Record import time, OCR pages, chapter count, extracted size, duplication/missing text, running artifacts, reading order, memory behavior, and final Spokio generation segmentation.

## Failure handling

Map invalid/protected/empty/partial-OCR/cancelled/missing-source failures into Spokio's existing project/job error model without leaking unnecessary implementation details to users.

## Exit criteria

- representative digital PDFs stay fast/native
- scanned and mixed PDFs OCR selectively
- no nested-TOC duplication
- multilingual OCR works within Vision capabilities
- running matter is acceptably cleaned
- large imports are cancellable with useful progress
- responsibility split remains clean in real Spokio workflows

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

Phases 0-5 are complete. Phase 6 is the next production-readiness step for large and bulk project workflows; Phase 7 stabilizes the reusable API/platform surface; Phase 8 validates the final ownership boundary in Spokio.

# Definition of done

PDFKitAudio is ready to act as Spokio's lightweight PDF ingestion layer when:

- digital books stay on fast native PDFKit extraction
- OCR is selective, multilingual/configurable, and page-scoped
- every page/segment has correct source provenance
- chapter generation cannot duplicate nested TOC ranges
- common running headers/footers are not spoken repeatedly
- generic chunking does not corrupt words or provenance
- large parses can be cancelled and report progress
- declared Apple platforms build in CI
- real Spokio integration confirms the ownership boundary is clean
