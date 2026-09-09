# Phase 4 hardening — automated test results

Date: 2026-09-09. Starting commit: `57459de` (`finish phase 3`).

## Status

Functional regression and stress checks pass. **Phase 4 is not fully cleared:** the controlled simple-page slowdown still exceeds the plan's initial 15% target, and manual Demo/Spokio verification remains unperformed under the owner's no-app-build instruction. Passing XCTest does not imply the performance target or merge-readiness gate passed.

## Fixes and simplification

- Fixed scanned-fixture generation: the image retains 2x pixel resolution but receives the intended logical page size before PDF embedding. Previously shrinking the PDF media box cropped upper-page text out of the visible scan. Real Vision OCR now recognizes the existing single-column, two-column, and mixed-document fixtures with exact marker order and expected OCR provenance.
- Added a narrow `.auto` native shortcut for at least three aligned, nonoverlapping, source-ordered lines whose selection ranges and Core Text widths show no unexplained spacing. Insets, overlaps, reversed source order, rotation, disjoint ranges, or suspicious spacing retain full analysis. `.always` and explicit diagnostics bypass the shortcut.
- Skip expensive glyph gutter probes for tightly fitting text selections. No page-width cutoff was introduced. Real column, mixed-region, and table regressions remain green.
- Removed the redundant permissive information-ratio thresholds: exact character-inventory conservation already supersedes them. Confidence, identity, fallback, and conservation gates remain intact.

## New coverage

Ten tests cover:

- All 12 committed digital PDFs with a failing OCR spy: no OCR invocation, all native provenance.
- Landscape dashboard text conservation and repeatable output in `.never`, `.auto`, and `.always`.
- 0/90/180/270-degree rotation, crop/media-box differences, mixed portrait/landscape sizes, finite normalized geometry, and source-text conservation.
- Every degraded native fixture: semantic-marker coverage, repeatable output, and no introduced duplicate regions. Intentional duplicate source layers are not required to become perfectly deduplicated.
- Vietnamese, Latin diacritics, horizontal CJK, mixed-script punctuation, and degraded horizontal RTL: preservation of canonically normalized non-whitespace Unicode content.
- Real Vision single-column, two-column, and mixed native/scanned recognition with exact reading order and OCR/native provenance.
- `.auto` default, `.always` identity-safety rejection, and diagnostic extraction despite the simple-page shortcut.
- Alternating warmed legacy/automatic performance measurements and a matched 500-page complex-document stress/memory comparison.

Existing Phases 1–3, supported generated-fixture order, simple-corpus fast-path precision, cancellation, and fallback tests remain green. No support labels or assertions were weakened to obtain these results.

## Debug verification and measurements

`swift test`: **274 selected, 272 passed, two skipped, zero failures** (40.9 seconds, excluding compilation).

The skips are the old opt-in benchmark harness and the environment-selected fixture helper. The new Phase 4 performance and 500-page stress tests run normally and were not skipped. `git diff --check` passes.

On this machine, the controlled 100-page fixture measured:

| Measurement | Legacy `.never` | Automatic `.auto` |
| --- | ---: | ---: |
| Initial debug median | 0.134 s | 0.505 s |
| Final full-suite debug median | 0.138 s | 0.254 s |

Automatic parsing improved by about half, but remains **1.84× legacy** (about 1.16 ms additional work per page); the 1.15× target is not met. Five measured rounds follow warm-up, alternating mode order. `.never` is the current package's legacy-path control, not a separately compiled historical revision. Timing targets are reported explicitly rather than used as flaky wall-clock assertions in ordinary CI.

The matched 500-page two-column `.auto` parse completed in 4.65 seconds, with every page's marker order and conservation checked. Current RSS sampled every 50 pages grew about 20.9 MiB for `.auto`, versus 42.1 MiB for `.never` in the same process. Both the 256 MiB gross-growth bound and the 32 MiB additional-over-legacy bound passed. Allocator reuse and PDFKit caching affect these numbers; they are not an allocation-lifetime proof.

Code inspection confirms page extraction is enclosed in an autorelease pool; full layout graphs and OCR raster images are not fields of retained page results. Selected text and compact document fingerprints necessarily grow with document size. Vision/PDFKit internal caches are outside that ownership guarantee.

## Remaining gates

Optimized confirmation: `swift test -c release --filter PdfLayoutPhase4PerformanceTests`
passed both measurement/stress tests. The 100-page medians were 0.126 s (`.never`)
and 0.245 s (`.auto`), **1.95× legacy**, so the performance target remains unmet in
release code too. The optimized 500-page complex parse completed in 3.28 s; RSS
growth was about 24.1 MiB for `.auto` versus 42.3 MiB for the matched legacy run.
The measurement test prints `targetMet=false`; its XCTest pass is not a performance-gate pass.

- Meet the simple-page performance target, or explicitly approve a correctness-justified exception supported by representative import timings.
- Run manual Demo/Spokio imports and compare displayed output with parser expectations when app verification is authorized.

No app was built or launched, and no PR/merge action was taken.
