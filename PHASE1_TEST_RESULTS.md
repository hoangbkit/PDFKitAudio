# Phase 1 correctness recovery — test results

Date: 2026-09-08. Baseline commit: `b14d5f3`.

The automated Phase 1 gates pass. The full suite is not green: two existing tests still fail. Manual Demo verification was deferred at the repository owner's request to focus on testing; this report does not mark the complete Phase 1 exit condition satisfied.

## Changes verified

- Native extraction probes a bounded sample of line selections for intersecting, persistent glyph gaps without the previous page-width cutoff. Fragments retain exact native text ranges.
- Ordinary sentence-bearing column lanes use direct gutter-based ordering before table classification. Ambiguous grids and mixed interior spans retain the general resolver.
- Optional extraction diagnostics include native text, PDFKit line selections, text ranges, raw and normalized character bounds (including invalid/empty bounds), detected gutters, and final fragments.
- Generated PDFs use named Helvetica fonts rather than private system-font names that were substituted when PDFKit reopened the fixtures on this environment.
- The optional environment-selected fixture test skips when no fixture was requested. Fast-path precision no longer assumes PDFKit must misorder at least one healthy fixture on every OS.

## Automated results

The focused run selected 30 tests: 29 passed, one optional test skipped, zero failures.

```sh
swift test --filter 'PdfRealFixturePhase1Tests|PdfSimpleColumnLayoutTests|PdfLayoutPhase9CategoryQualityTests|PdfPositionedTextExtractorColumnSplitTests'
```

Coverage includes:

- Exact final-parser order for `02-two-columns.pdf`, `03-three-columns.pdf`, and `12-dense-academic.pdf`, including the academic abstract and reference placement.
- Every original word and its occurrence count preserved through canonical pages, chapters, and TTS segments for those three fixtures.
- The Demo's default asynchronous URL parsing API producing the same verified text, with native extraction provenance.
- Deterministic, nonempty native output and extraction diagnostics for all 12 committed real PDFs.
- Single-column fast-path equivalence, generated column regressions, variable line endings, compact column footprints, unequal heights, an earlier right-column start, and RTL column ordering.
- Cell-like grids and interior spans declining the simple-column path.

The final full `swift test` run selected 243 tests: **239 passed, two skipped, two test cases failed (13 assertion failures)**.

Remaining failures:

1. `PdfLayoutPhase9QualityGateTests.testSupportedLayoutsRemainExactUnderDeterministicCoordinatePerturbations`: the `caption-between-columns` fixture has pairwise order accuracy `0.7`, failing in all 12 perturbations.
2. `PdfLayoutRoleClassifierIntegrationTests.testRealPDFKitTableSurvivesExtractionAndSpecialStructureAnalysis`: `table-header-row` produces no detected table in the internal role-classifier integration test.

Both failures reproduce with the original production code in a temporary checkout using the same corrected fixture fonts. The unmodified checkout had 250 assertion failures; the original production code with corrected fonts had 19. No remaining failure is newly introduced by the Phase 1 implementation.

The full-suite skip reasons are the opt-in performance benchmark and the environment-selected fixture helper. Existing OCR, mixed native/scanned parsing, cancellation, source provenance, and supported generated-fixture order/conservation tests pass.

`git diff --check` passes. App/GUI verification is outside this completed testing pass.

To print extraction and analyzer diagnostics for the real fixtures:

```sh
PDFKITAUDIO_LAYOUT_DIAGNOSTICS=1 swift test --filter PdfRealFixturePhase1Tests
```
