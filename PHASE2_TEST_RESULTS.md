# Phase 2 correctness recovery — test results

Date: 2026-09-08. Starting commit: `486e33a` (`finish phase 1`).

Phase 2 implementation and automated acceptance checks pass. App builds and manual GUI verification were not performed, following the repository owner's instruction to focus on code and tests. This report does not claim the plan's manual Demo exit condition was verified.

## Implementation

- Persistent gutter evidence now survives line reconstruction, including gutters narrower than the old per-line gap threshold. The automatic analyzer gate also recognizes this evidence.
- Paragraph merging cannot cross an established gutter or reconnect text across an intervening spanning heading. Existing indentation, wrapping, short final lines, typography, CJK/RTL, and superscript behavior remains covered.
- Added a direct mixed-region resolver before block-left-edge clustering and the general graph resolver. It separates spanning text from column bands, reconstructs each band independently, and emits explicit region/column sequences.
- Each column band has its own gutter geometry and vertical extent. Column widths can change across headings, and staggered baselines can use established gutters when both lanes remain occupied and vertically overlap.
- Ambiguous bands retain the general resolver. Table and footnote semantics were not expanded in this phase. Public APIs remain unchanged.

## Acceptance coverage

All nine new Phase 2 tests pass, covering:

- Exact final-parser reading order for `04-spanning-headline-two-columns.pdf` and `10-mixed-column-transitions.pdf`, including deck, intro, body columns, and conclusion.
- Full source-word occurrence counts through pages, chapters, and speech segments; native provenance, deterministic repeated parsing, and default asynchronous URL parsing.
- All eight planned generated mixed-region patterns, including the previously degraded interrupted-column and multiple-heading fixtures, plus `caption-between-columns`.
- Narrow-gutter preservation; heading boundaries in paragraph reconstruction; indentation, wrapping, and short final lines; independent gutters for changing column widths; staggered column baselines after a heading.

Phase 1 real-fixture tests, generated column tests, existing reconstruction and language tests, OCR/native-mixed parsing, cancellation, and supported generated-fixture quality gates remain green. The previously failing caption-order perturbation test now passes all 12 seeds.

## Full-suite result

```sh
swift test
```

**252 tests selected: 249 passed, two skipped, one failed.**

The remaining failure is unchanged from Phase 1:

`PdfLayoutRoleClassifierIntegrationTests.testRealPDFKitTableSurvivesExtractionAndSpecialStructureAnalysis`

The `table-header-row` fixture produces no detected table through the internal role-classifier integration path. Table recovery belongs to Phase 3; the full suite must not be described as green until this is resolved.

The two skips are the opt-in performance benchmark and the optional environment-selected fixture helper. `git diff --check` passes.
