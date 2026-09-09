# Phase 3 correctness recovery — test results

Date: 2026-09-09.

Phase 3's mandatory real-fixture automated acceptance checks pass. No app build or GUI verification was performed, as requested.

## Changes verified

- Native cell recovery now uses selection-range geometry and selection text consistently. PDFKit's character-bound indexes and synthesized whitespace had caused incorrect splits. Existing fragment gutters also trigger inspection of short merged numeric cells; range subdivision retains source text.
- Isolated inset pull quotes between aligned narrative blocks are deferred until after their enclosing narrative. The real sidebar remains after primary body text, exactly once.
- Tables use deterministic row-major speech with every source cell, including headers, emitted once. Header inference requires bold styling or consistent whole-word labels, not incidental substrings. The explicit header-aware linearizer remains available internally.
- Table materialization consumes matched cell fragments, not entire paragraph blocks. Unmatched text survives. An alphanumeric character-inventory check additionally rejects destructive or duplicating analyzer output.
- Strong footnote evidence takes priority over numbered-list markers. Separated, explicitly labeled note sections can establish small referenced notes above the bottom margin.
- Captions require an explicit prefix; generic small centered text is insufficient. Caption anchors must overlap horizontally, preventing attachment to a disjoint column.
- Fixture 09 was regenerated as four pages using the checked-in Swift generator. It uses a separate `Page N` line and an explicit bullet before the decorated footer's numeric suffix. Cleanup thresholds and production cleanup code were not weakened. The test verifies one retained header/footer, removed pagination, all unique body lines, and unchanged native text; minimal cleanup retains running matter.

## Acceptance coverage

All five mandatory real PDFs pass final-parser checks:

- `05-right-sidebar.pdf`: primary narrative before sidebar.
- `06-pull-quote.pdf`: opening and closing body before the isolated quote.
- `07-table-with-prose.pdf`: intro, complete row-major table, conclusion.
- `08-footnotes.pdf`: body before all five notes; explicit note roles when analyzed.
- `09-repeated-header-footer.pdf`: four-page conservative cleanup contract.

Tests verify source-word occurrence counts through pages, chapters, and speech segments; native provenance; deterministic repeat parsing; and matching default synchronous/asynchronous URL results. Added negative and conservation checks cover false captions, cross-column anchors, numbered notes, false header labels, and prose sharing a table block.

Phase 1 and Phase 2 regression tests remain green. The previously failing `PdfLayoutRoleClassifierIntegrationTests.testRealPDFKitTableSurvivesExtractionAndSpecialStructureAnalysis` now passes.

## Final verification

Command: `swift test`

**264 tests selected: 262 passed, two skipped, zero failures.** Twelve tests were added in this phase. The skips are the opt-in stress benchmark and environment-selected fixture helper. `git diff --check` passes.

This verifies the mandatory Phase 3 cases, not perfect reconstruction of every degraded fixture: the broad generated-catalog baseline still reports imperfect ordering for some side-content, table, and difficult-positioning cases. Those fixtures have not been silently promoted to fully supported. Phase 4's OCR parity, performance/stress work, and simplification remain unperformed.
