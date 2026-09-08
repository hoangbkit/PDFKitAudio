# PDF Layout Analyzer Correctness Review

> Review date: 2026-09-08
>
> Branch: `plan/layout-analyzer`
>
> PR: #3 — `Implement lightweight geometry-first PDF layout analyzer`
>
> Conclusion: **do not merge yet**. The current implementation is broad and well-instrumented, but real PDF reading-order correctness is not yet reliable enough for Spokio. A simple two-column PDF already fails in the Demo, which invalidates the assumption that Phase 0–10 implementation completeness equals parser correctness.

## Executive summary

The PR contains substantial work across extraction, geometry normalization, line/block reconstruction, complexity detection, region/column detection, reading-order resolution, role classification, table handling, running-matter cleanup, diagnostics, and quality gates.

The main problem is not the amount of code. It is the reliability of the earliest primitive in the production pipeline:

```text
PDFKit selection
  -> positioned fragments
  -> lines
  -> blocks
  -> regions / columns
  -> reading order
  -> spoken text
```

If PDFKit produces one `PDFSelection` spanning text from two visual columns, the rest of the pipeline can receive a bad fragment before column detection begins. The current extractor tries to repair suspicious line selections by inspecting character geometry, but that repair is intentionally gated by conservative width heuristics. Once two columns have already been collapsed into one fragment, later line/block/column logic cannot reliably reconstruct the missing boundary.

This explains the current contradiction:

- synthetic Phase 9 fixtures can pass exact marker-order tests;
- the Demo can still produce incorrect output for an ordinary two-column PDF.

The next work should therefore be a **correctness recovery**, not additional feature phases.

---

## 1. Test corpus assessment

The Swift fixture catalog is broad and useful. It contains at least 75 deterministic scenarios across:

- simple layouts
- columns
- mixed vertical regions
- side content
- tables
- footnotes and captions
- running matter
- difficult positioning
- scripts and languages
- OCR equivalents

The fixture breadth is not the problem. The weakness is that these generated PDFs originate from idealized `TestLayoutTextBox` geometry with deterministic coordinates and semantic markers. They are excellent for exercising later layout algorithms once positioned fragments are already reasonable, but they do not adequately model real PDFKit extraction pathologies.

The Phase 9 quality gates require exact coverage, pairwise marker order, and no duplicate markers for supported generated fixtures. That is valuable, but it can overstate real-world readiness because the generated corpus does not sufficiently stress incorrect PDFKit fragment boundaries.

### Critical testing gap

The 12 committed native PDFs under:

`Tests/PDFKitAudioTests/TestFixtures/PDFLayout/`

are currently manual fixtures. `Package.swift` does not declare them as test resources, so they are not first-class release gates through the actual parser path.

They should become the primary correctness corpus for this recovery work.

---

## 2. Assessment of the 12 committed PDF fixtures

| Fixture | Current assessment | Confidence | Main concern |
| --- | --- | --- | --- |
| `01-single-column.pdf` | Likely correct | High | Normal single-column pages usually stay on the legacy fast path in `.auto`, which is desirable. |
| `02-two-columns.pdf` | **Incorrect** | Confirmed | Demo failure. Native fragment extraction can preserve merged same-baseline selections and destroy the column boundary before layout detection. |
| `03-three-columns.pdf` | Likely incorrect | Very high | Requires two reliable gutters; cannot be trusted while ordinary two-column extraction fails. |
| `04-spanning-headline-two-columns.pdf` | Likely incorrect | High | Spanning detection depends on correct primary-column discovery first. |
| `05-right-sidebar.pdf` | Fragile | Medium-high | Sidebar classification depends on lane clustering, width ratios, block counts, and already-correct body geometry. |
| `06-pull-quote.pdf` | Probably readable, not proven robust | Medium-high | Natural source order may already be usable, so passing does not prove the analyzer understands pull quotes. |
| `07-table-with-prose.pdf` | Fragile | High | Table inference depends on distinct positioned cell fragments; merged row selections weaken grid evidence. |
| `08-footnotes.pdf` | Probably correct | Medium-high | Bottom placement and small-font signals are comparatively strong, but should still be tested through the committed PDF. |
| `09-repeated-header-footer.pdf` | **Fixture/behavior mismatch** | Very high | The fixture has three pages, while repeated-running-matter cleanup intentionally requires at least four pages. It cannot validate the intended behavior as written. |
| `10-mixed-column-transitions.pdf` | Likely incorrect | Very high | Requires reliable single-column -> multi-column -> single-column segmentation on top of the currently weak column primitive. |
| `11-landscape-dashboard.pdf` | Unreliable / degraded | High | Dashboard regions can resemble tables, columns, sidebars, or irregular blocks; current prose-oriented heuristics are not a strong fit. |
| `12-dense-academic.pdf` | Likely incorrect | Very high | Dense two-column prose stresses extraction, gutter detection, short final lines, headings, references, and column transitions simultaneously. |

### Priority order

Fix and gate these in this order:

1. `02-two-columns.pdf`
2. `03-three-columns.pdf`
3. `12-dense-academic.pdf`
4. `04-spanning-headline-two-columns.pdf`
5. `10-mixed-column-transitions.pdf`
6. `05-right-sidebar.pdf`
7. `07-table-with-prose.pdf`
8. `08-footnotes.pdf`
9. `09-repeated-header-footer.pdf`
10. `11-landscape-dashboard.pdf`
11. `06-pull-quote.pdf`
12. `01-single-column.pdf` regression protection

---

## 3. Current implementation assessment

| Component | Assessment | Notes |
| --- | --- | --- |
| Geometry normalization | Good | A normalized top-left coordinate space is the right foundation. |
| Native PDFKit fragment extraction | **Main blocker** | Starts from `selectionsByLine()`. The code knows one selection may span columns, but character-level splitting is only attempted under restrictive heuristics. |
| OCR fragment model | Promising | OCR observations already provide explicit geometry and fit the shared model better than some native PDFKit selections. |
| Line reconstruction | Reasonable after good fragments | Can split strong gaps between fragments, but cannot recover a missing column boundary inside one already-merged fragment. |
| Block reconstruction | Reasonable | Paragraph merge heuristics are serviceable but depend on reliable line geometry. |
| Complexity detection | Useful but heuristic-heavy | Good as a conservative fast-path gate, not as proof of semantic correctness. |
| Column detection | Fragile | Primarily clusters block left edges and uses width/overlap thresholds. Real wrapped prose, indentation, short final lines, and merged selections can break the lane model. |
| Mixed-region detection | Fragile | Depends on reliable column detection first. |
| Reading-order DAG | Technically strong, currently downstream of bad inputs | The graph resolver is not the first problem. Correct graph logic cannot repair incorrect fragment segmentation. |
| Role classification | Useful secondary layer | Heading/sidebar/caption/footnote/table heuristics should remain secondary to correct geometry. |
| Table handling | Fragile on native PDFs | Strong when PDFKit exposes separate cells; weak when selections merge cells/rows. |
| Running-matter cleanup | Conservative | Sensible safety bias, but the new three-page committed fixture is incompatible with the current four-page repetition gate. |
| Diagnostics | Good | Keep them. They are important for recovery work and Demo inspection. |
| Safety gates | Incomplete for semantic order | Conservation, IDs, information ratios, and internal confidence do not independently prove that column reading order is correct. |
| Synthetic quality tests | Strong for idealized geometry | Useful but insufficient as release proof. |
| Real PDF regression tests | **Missing** | The committed PDFs are not currently exercised as SwiftPM resources through the production parser. |

---

## 4. Root cause: the parser can lose structure before layout analysis

The production path begins with `PdfPositionedTextExtractor.nativeFragments(page:)`, which obtains a page-wide `PDFSelection` and calls `selectionsByLine()`.

PDFKit may legally return one line selection for text that visually occupies separate columns on the same baseline.

The implementation attempts to split a line selection by character geometry only when the selection appears suspiciously wide. The current inspection gate requires conditions such as:

- selection width being a large fraction of page width;
- attributed text being available;
- visual width being meaningfully larger than the text's natural attributed width.

The subsequent glyph-gap split also uses a strong fixed/adaptive gap threshold.

This approach is conservative, but it creates false negatives: ordinary column rows can remain merged.

After that point:

- `PdfLayoutLineBuilder` can split strong gaps **between fragments**, but not inside a bad merged fragment;
- `PdfLayoutBlockBuilder` reconstructs blocks from those lines;
- `PdfLayoutRegionDetector` then clusters those blocks into lanes;
- `PdfReadingOrderResolver` trusts the region/column model.

Therefore a bad extraction boundary propagates through a sophisticated but internally consistent pipeline.

The recovery plan must repair this primitive first.

---

## 5. Why the current quality gates did not catch the Demo failure

The existing tests are not fake or useless. They do verify useful properties:

- fixture generation succeeds;
- semantic markers survive PDFKit extraction;
- supported fixtures have exact marker coverage/order;
- duplicate markers are rejected;
- malformed geometry is filtered;
- deterministic perturbations do not break selected synthetic layouts;
- simple fast-path behavior remains stable;
- OCR invocation remains controlled.

The missing dimension is **realistic native extraction behavior**.

Small coordinate perturbations applied to already-good fragments do not model PDFKit returning the wrong text-selection granularity. Marker-order tests on generated boxes can therefore pass while a visually ordinary real PDF fails.

The release gate should move from:

> "All supported generated fixtures pass."

To:

> "All supported generated fixtures pass **and** all committed native regression PDFs pass through the exact production parser path used by the Demo."

---

## 6. Correctness standard for Spokio

PDFKitAudio is not trying to reproduce a full document-understanding engine. For Spokio, the goal is reliable spoken text.

A page is correct enough when it satisfies all of these:

1. **No missing semantic text** unless explicitly classified as removable running matter.
2. **No duplicated semantic text.**
3. **Correct primary reading order** for common single-, two-, and three-column documents.
4. **Correct vertical transitions** between spanning/full-width regions and columns.
5. **Deterministic side-content policy** so sidebars/pull quotes do not interleave into body prose.
6. **Readable deterministic tables** even when visual reconstruction is imperfect.
7. **Footnotes/captions remain readable and do not interrupt primary prose unpredictably.**
8. **Repeated headers, footers, and page numbers are removed conservatively.**
9. **Simple book pages remain on the fast path and do not regress.**
10. **Low-confidence pages preserve readable source text rather than producing a confidently wrong reordering.**
11. **OCR pages use the same final reading-order contract as native pages.**
12. **Memory remains page-bounded and performance remains suitable for local macOS use.**

---

## 7. Merge recommendation

PR #3 should remain open.

Do not treat the existing Phase 0–10 implementation status as completion criteria. Those phases represent implemented architecture and test infrastructure, not demonstrated real-PDF correctness.

The next work should follow the replacement multi-phase correctness plan in `LAYOUT_ANALYZER_PLAN.md`.

The PR becomes mergeable only when the real fixture corpus is wired into CI and the Spokio-oriented acceptance gates pass.