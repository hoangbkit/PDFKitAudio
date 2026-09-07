# Layout analyzer implementation status

This PR started as a planning-only change and is now implementing the approved plan phase by phase.

- [x] Phase 0 — baseline, deterministic layout fixture system, quality metrics, and benchmark harness
- [x] Phase 1 — unified positioned-fragment extraction
- [ ] Phase 2 — page complexity detector and fast-path gate
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

Each phase is marked complete only after its exit criteria are satisfied and CI is green.
