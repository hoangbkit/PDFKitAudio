# Layout analyzer implementation status

This PR started as a planning-only change and is now implementing the approved plan phase by phase.

- [x] Phase 0 — baseline, deterministic layout fixture system, quality metrics, and benchmark harness
- [x] Phase 1 — unified positioned-fragment extraction
- [x] Phase 2 — page complexity detector and fast-path gate
- [ ] Phase 3 — fragment-to-line and line-to-block reconstruction
- [ ] Phase 4 — columns, spanning regions, and vertical segmentation
- [ ] Phase 5 — reading-order DAG and deterministic resolver
- [ ] Phase 6 — lightweight role classification and special structures
- [ ] Phase 7 — geometry-aware document cleanup
- [ ] Phase 8 — parser integration, selection policy, and public configuration
- [ ] Phase 9 — comprehensive real-world and adversarial testing
- [ ] Phase 10 — hardening, diagnostics, documentation, and rollout

## Completed phase notes

### Phase 0

- 75 deterministic layout fixtures across simple, column, mixed-region, side-content, table, running-matter, difficult-positioning, multilingual, native, and scanned cases.
- Semantic marker coverage/order scoring, JSON diagnostics, and opt-in 100/500-page stress benchmarks.
- Measured baseline is recorded in `LAYOUT_BASELINE.md`.
- No production parser text-selection behavior changes.

### Phase 1

- Added internal `PdfLayoutFragment` and optional style hints.
- Native PDFKit extraction uses one page selection split into line selections, retaining text, stable source order, page-space bounds, and lightweight font hints.
- PDF page-space rectangles normalize into visual top-left `[0, 1]` coordinates with media-box offsets and 0/90/180/270-degree page rotation handling.
- Vision OCR now retains per-observation text, normalized geometry, confidence, and observation order while preserving the existing flattened OCR result used by `PdfParser`.
- Native/OCR fragments share one model and conservative overlap + text-similarity deduplication.
- Added tests for normalization, rotation, crop/landscape fixtures, repeated-parse stability, Unicode integrity, Vision geometry conversion, real OCR observation geometry, equivalent coordinate sanity, and duplicate-layer handling.
- Existing selected page text remains unchanged; analyzer integration is intentionally deferred to Phase 8.

### Phase 2

- Added a deterministic, geometry-first `PdfLayoutComplexityDetector` that classifies pages as simple single-column, likely multi-column, mixed-region, table-heavy, irregular-positioned, or ambiguous/unknown.
- Ordinary single-column pages remain on the existing fast path; ambiguous geometry also fails safe to the current path rather than forcing reconstruction.
- Recurring left-edge lanes and median lane extents provide persistent column-separation evidence without allowing a one-off full-width title, caption, or conclusion to erase the underlying gutter.
- Staggered/unequal columns can be detected even when opposing lines do not share baselines.
- Mixed-region detection combines recurring lanes with vertical transitions and spanning/emphasized singleton evidence.
- Table detection uses aligned multi-item rows plus compact-cell, dense-grid, and explicit multiline-cell evidence so ordinary prose columns are not treated as tables.
- Sparse side lanes and floating positioned regions are conservatively flagged for later analysis.
- Explicit false-positive guards cover centered poems, alternating dialogue indents, indented quotations, numbered lists, wide headings with single-column body text, and sparse ambiguous pairs.
- Native text quality is retained as diagnostic context but does not override geometry classification.
- The complete deterministic fixture matrix has an explicit analyze/fast-path expectation, with real PDFKit tests verifying both a two-column page and a simple page.
- Phase 2 does not change `PdfParser` selected text, cleanup, chaptering, or TTS output; analyzer integration remains deferred to Phase 8.
- Normal CI keeps stress benchmarks opt-in; the Phase 2 gate passed SwiftPM tests and the generated macOS example-app build on macOS 14.

Each phase is marked complete only after its exit criteria are satisfied and CI is green.
