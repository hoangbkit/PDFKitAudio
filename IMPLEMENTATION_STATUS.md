# Layout analyzer implementation status

This PR started as a planning-only change and is now implementing the approved plan phase by phase.

- [x] Phase 0 — baseline, deterministic layout fixture system, quality metrics, and benchmark harness
- [x] Phase 1 — unified positioned-fragment extraction
- [x] Phase 2 — page complexity detector and fast-path gate
- [x] Phase 3 — fragment-to-line and line-to-block reconstruction
- [x] Phase 4 — columns, spanning regions, and vertical segmentation
- [x] Phase 5 — reading-order DAG and deterministic resolver
- [x] Phase 6 — lightweight role classification and special structures
- [x] Phase 7 — geometry-aware document cleanup
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

### Phase 3

- Added internal `PdfLayoutLine`, `PdfLayoutBlock`, and explicit left-to-right/right-to-left writing-direction models.
- Fragment-to-line reconstruction uses adaptive vertical overlap/center tolerances, with conservative superscript/subscript attachment only when small fragments are both vertically close and horizontally adjacent.
- Row candidates split at strong horizontal gaps before line construction so clearly separated columns or side regions do not become a single logical line.
- Within-line ordering follows dominant writing direction; reconstructed spacing uses source-boundary whitespace, geometry-derived character gaps, punctuation adjacency, and CJK-specific no-space handling.
- Line-to-block reconstruction keeps multiple compatible active lanes rather than relying only on immediately adjacent geometry order, allowing interleaved left/right rows to remain separate while each lane can still form coherent blocks.
- Paragraph first-line indentation and hanging indentation remain mergeable; strong font/emphasis transitions separate headings and footnotes from body text.
- Explicit list markers start distinct blocks while wrapped continuation lines remain attached to their item.
- Side-by-side low-overlap lines, narrow sidebars, and strong-gutter columns are prevented from merging into one paragraph-like block.
- Block text preserves reconstructed line breaks and hyphen evidence so `PdfTextCleaner` remains responsible for downstream audiobook cleanup/dehyphenation.
- Tests cover split runs, geometry-derived spaces, punctuation, source whitespace, superscripts, CJK, RTL, paragraph indentation, hanging indentation, lists, headings, footnotes, sidebars, strong gutters, and preserved hyphen evidence.
- All supported deterministic fixtures are checked for stable repeated output and structural text conservation: every input fragment ID appears exactly once in lines and blocks.
- A real generated PDFKit two-column fixture verifies that actual extracted fragments never produce a block crossing a strong column gutter.
- Phase 3 remains internal and does not alter `PdfParser` selected text or public API; parser/analyzer integration remains deferred to Phase 8.
- The Phase 3 gate passed SwiftPM tests and the generated macOS example-app build on macOS 14.

### Phase 4

- Added `PdfLayoutRegion`, `PdfLayoutColumn`, and `PdfPageRegionLayout` models plus deterministic page segmentation.
- Detects 1–3 primary columns, including symmetric/asymmetric widths, narrow/wide gutters, unequal column heights, staggered starts, and short-vs-long columns.
- Spanning/full-width blocks create vertical region boundaries, supporting layouts such as `single → columns → single` and interrupted multi-column regions.
- Sidebar candidates are excluded from primary-column count using sparse-lane continuity, width, style, and body-lane evidence; true asymmetric second columns remain primary columns.
- Ordinary indentation, pull quotes, and similar single-column geometry do not invent gutters or extra primary columns.
- Region/column assignments are deterministic and stable under small coordinate perturbations.
- Real PDFKit validation exposed same-baseline multi-column text being merged into one `PDFSelection`; native extraction now selectively inspects character geometry only for suspicious stretched line selections and splits at strong internal character gaps while keeping ordinary line-level extraction cheap.
- Added regressions ensuring real interrupted columns recover `columnar → spanning → columnar`, real sidebars remain non-primary, and wide ordinary single-column text is not over-split.
- Phase 4 remains internal and does not alter `PdfParser` selected text or public API.
- The final Phase 4 head passed SwiftPM tests and the generated macOS example-app build on macOS 14.

### Phase 5

- Added `PdfReadingOrderEdge`, `PdfReadingOrderHints`, `PdfReadingOrderResult`, and a deterministic `PdfReadingOrderResolver` built around an explicit precedence DAG rather than a large comparator.
- Same-column blocks receive top-to-bottom precedence; primary columns are sequenced column-major left-to-right or right-to-left according to the resolved writing direction; vertical regions receive explicit region-to-region edges.
- Spanning regions naturally precede/follow neighboring column regions, and observable trailing cross-column summaries/footers that Phase 4 conservatively associates with one lane are deferred until every primary column finishes.
- Sidebars default to spoken order after the primary region, with a geometric policy available internally for later experimentation.
- Semantic ordering is intentionally decoupled from role discovery: Phase 5 accepts optional footnote, caption-anchor, writing-direction, unknown-block, and additional-precedence hints; Phase 6 is responsible for classifying blocks and producing those hints.
- Footnote hints place notes after main body; caption attachments place captions after their anchors; stronger semantic constraints can override weaker geometric edges through deterministic cycle resolution.
- Cycles never drop blocks: the resolver removes the lowest-confidence inferred edge with stable tie-breaking, records the removal diagnostic, and retries topological sorting.
- Ambiguous irregular overlap, missing region assignments, and duplicate block identifiers fail safe to deterministic geometry/source ordering rather than crashing or silently losing content.
- Reading-order confidence incorporates region/column confidence, removed cycle edges, unknown blocks, and strong geometry conflicts.
- Exact-order tests cover all supported column and mixed-region fixtures, plus repeated determinism, LTR/RTL sequencing, sidebar policy, footnote/caption hints, forced cycles, irregular-overlap fallback, missing-assignment fallback, duplicate-ID safety, and real PDFKit two-column ordering.
- Every successful/fallback ordering path is checked for deterministic block conservation; parser-selected text and public API remain unchanged until Phase 8.
- The Phase 5 gate passed all SwiftPM tests and the generated macOS example-app build on macOS 14.

### Phase 6

- Added a separate, non-destructive role-annotation layer (`PdfLayoutRole`, `PdfLayoutRoleAssignment`, and `PdfSpecialStructureAnalysis`) so semantic hints do not mutate the deterministic Phase 3–5 geometry models.
- Transparent conservative scores classify headings, explicit list items, Phase 4 sidebars, centered pull quotes/callouts, captions, footnotes, table cells, ordinary body text, and unknown content using relative font size/emphasis, normalized geometry, text length, whitespace, page position, and explicit prefixes.
- Heading assignments can emit strong local precedence hints; footnotes emit end-of-body hints; captions emit nearest-compatible anchor attachments consumed by the existing Phase 5 DAG resolver.
- Footnotes require strong combined evidence such as bottom-zone placement, body-relative small type, reference markers, clustered notes, separator/rule evidence, or clear body separation; an ordinary full-size paragraph near the bottom remains body text.
- Captions and centered pull quotes use distinct placement evidence so small centered text in the body is not automatically treated as a caption.
- Phase 4 sidebar assignments are preserved as sidebars and are never silently skipped; their spoken ordering remains governed by the Phase 5 sidebar policy.
- Added deterministic table structures (`PdfTableCell`, `PdfDetectedTable`) and a lightweight `PdfTableLinearizer` supporting conservative row-major output plus header-aware `Header: value` speech when a first-row header is clear.
- Table cell recovery uses positioned source fragments with block/line provenance because Phase 3 may correctly reconstruct several horizontally separated cells as one logical line; table-grid validation then clusters rows by Y and columns by stable X lanes.
- Table detection is gated by Phase 2 table-heavy evidence or a stricter repeated three-lane compact-grid fallback, preventing ordinary two-column prose and numbered lists from being promoted into tables.
- Multiline cells, numeric tables, borderless tables, header rows, full-width tables, in-column tables, and tables between prose regions have deterministic regression coverage; ambiguous non-table structures remain ordinary ordered blocks rather than losing content.
- The entire single-page fixture matrix is checked for deterministic role output and exact block conservation: every input block receives exactly one assignment and no role classifier removes text.
- Real generated PDFKit integration tests validate table structure/linearization, caption role plus anchor hint, and strong footnote classification through the full native extraction → line/block reconstruction → region → role-analysis pipeline.
- Phase 6 remains internal and does not alter `PdfParser` selected text or public API; parser/analyzer integration remains deferred to Phase 8.
- The Phase 6 gate passed all SwiftPM tests and the generated macOS example-app build on macOS 14, including the real PDFKit integration suite.

### Phase 7

- Added compact document-level layout fingerprints containing normalized line signatures, normalized block geometry, page/block identity, role confidence, and an optional coarse style bucket; raw block text and full page layout graphs are not retained across the document.
- Refactored `PdfDocumentTextCleaner` into one removal pass where existing text-only first/last-line heuristics remain the fallback and geometry augments candidate discovery/evidence instead of creating a second competing cleaner.
- Geometry can discover recurrent edge text outside the legacy first/last-two-line windows by matching normalized fingerprint signatures back to canonical selected page text.
- Repeated running matter requires both textual recurrence and a stable normalized Y-zone when enough analyzed-page geometry is available; enough inconsistent geometry becomes evidence against deletion.
- Horizontal movement is intentionally tolerated inside a stable header/footer zone so mirrored even/odd headers and moving footer page numbers remain detectable.
- Existing conservative recurrence thresholds are preserved; the alternating real-PDF integration uses eight pages instead of weakening the production threshold.
- Confident semantic heading occurrences can replace an earlier geometric running-header copy as the single preserved semantic occurrence, including short-page top/bottom edge ambiguity.
- Proven pagination remains removable while legitimate years/quantities are preserved without a valid page-index sequence.
- Mixed analyzed/fast-path pages share the same document cleanup/removal set; style information is supporting metadata only and can never independently trigger deletion.
- Regression coverage includes headers outside legacy windows, inconsistent geometry, moving page numbers, legitimate years, semantic chapter headings, sparse recurrence, short documents, mixed-mode pages, alternating headers, determinism, and real PDFKit identical/alternating running headers.
- Existing parser behavior remains source-compatible because `layoutFingerprints` defaults to empty; production parser wiring is Phase 8.
- The Phase 7 code/test gate passed the full SwiftPM suite and generated macOS example-app build on macOS 14. Phase 8 remains untouched until the final branch head is green.

Each phase is marked complete only after its exit criteria are satisfied and CI is green.
