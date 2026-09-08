# PDFKitAudio Layout Analyzer Correctness Recovery Plan

> Status: **active recovery plan**
>
> Branch: `plan/layout-analyzer`
>
> PR: #3 — `Implement lightweight geometry-first PDF layout analyzer`
>
> This plan supersedes the original Phase 0–10 implementation plan as the merge/release authority. The earlier phases produced useful architecture, diagnostics, tests, and heuristics, but real Demo output shows that implementation completeness did not guarantee reading-order correctness.
>
> See `PDF_LAYOUT_CORRECTNESS_REVIEW.md` for the full review that triggered this reset.

## 1. Product goal

Build a lightweight local PDF parser that is **good enough for Spokio's document-to-audio workflow** without turning PDFKitAudio into a server-grade document-understanding system.

The parser must prioritize spoken correctness:

- preserve semantic text;
- avoid duplicates;
- recover correct primary reading order for common one-, two-, and three-column PDFs;
- handle common full-width/column transitions;
- keep side content readable and deterministic;
- linearize tables conservatively;
- place footnotes/captions predictably;
- remove repeated running matter conservatively;
- keep simple books on the existing fast path;
- fall back to readable source text instead of emitting confidently wrong reordered text.

## 2. Non-goals

This recovery does **not** target:

- Docling/Granite-level general document understanding;
- arbitrary forms, diagrams, or visual dashboards with perfect semantic reconstruction;
- exact visual layout reproduction;
- mathematical expression understanding;
- remote services, LLMs, Python runtimes, or bundled heavy ML layout models;
- OCR on every native digital page;
- perfect support for every malformed PDF in existence.

For unsupported layouts, readable deterministic degradation is acceptable. Incorrect reordering presented as high confidence is not.

## 3. Core design rule

The new order of trust is:

```text
1. trustworthy fragment boundaries
2. trustworthy gutters / region boundaries
3. trustworthy line and block membership
4. simple deterministic reading order
5. semantic roles and advanced heuristics
6. confidence / fallback
```

Do **not** compensate for weak early geometry by adding more downstream heuristics.

A sophisticated reading-order DAG cannot repair a column boundary that was already lost during PDFKit extraction.

## 4. Real fixture corpus is now the release gate

The committed PDFs under:

`Tests/PDFKitAudioTests/TestFixtures/PDFLayout/`

must become first-class SwiftPM test resources and must run through the exact `PdfParser` path used by the Demo.

Current corpus:

1. `01-single-column.pdf`
2. `02-two-columns.pdf`
3. `03-three-columns.pdf`
4. `04-spanning-headline-two-columns.pdf`
5. `05-right-sidebar.pdf`
6. `06-pull-quote.pdf`
7. `07-table-with-prose.pdf`
8. `08-footnotes.pdf`
9. `09-repeated-header-footer.pdf`
10. `10-mixed-column-transitions.pdf`
11. `11-landscape-dashboard.pdf`
12. `12-dense-academic.pdf`

The existing generated 75+ fixture catalog remains valuable, but it is a **secondary regression suite**, not sufficient proof of real PDF correctness.

## 5. Universal acceptance metrics

Every supported real fixture must be checked for:

- semantic text coverage;
- semantic reading order;
- duplicate text;
- analyzer decision (`fastPath`, `accepted`, or `fallback`);
- extraction source (`native`, `ocr`, `empty`);
- deterministic repeated runs;
- no crash;
- no unbounded page-retained state.

For marker-capable fixtures, require:

- coverage = `1.0`;
- pairwise reading-order accuracy = `1.0`;
- duplicate marker count = `0`.

For prose fixtures, use stronger expected text sequences or stable semantic probes rather than only short marker tokens.

The final parser output, not an internal helper output, is the acceptance target.

---

# Phase 1 — Fix native extraction and the column primitive

## Objective

Make ordinary two- and three-column native PDFs reliable before touching advanced semantics.

This is the critical phase. If Phase 1 is not correct, later phases must not proceed as though the foundation is stable.

## Work

### 1.1 Wire real PDFs into SwiftPM tests

- Add `TestFixtures/PDFLayout` as test resources in `Package.swift`.
- Add a single resource loader with explicit fixture names.
- Run each PDF through the public/final `PdfParser` API used by Spokio/Demo.
- Add expected semantic-order metadata next to the fixture corpus where necessary.
- Keep the actual PDFs committed so failures are reproducible outside tests in Preview and the Demo.

### 1.2 Instrument the extraction boundary

For every real fixture, capture diagnostics for:

- `PDFPage.string`;
- `selectionsByLine()` result count;
- text and bounds of each line selection;
- text ranges within each selection;
- character/glyph geometry when inspected;
- final `PdfLayoutFragment` list.

The diagnostics must make it obvious whether a wrong result originates during extraction or later reconstruction.

### 1.3 Replace the current suspicious-line-only split strategy

The current extractor only inspects character geometry when a line selection passes restrictive width/natural-width heuristics. That can miss ordinary column rows.

Refactor extraction so likely multi-lane pages can discover gutters from occupancy/character geometry before committing to line fragments.

Preferred strategy:

1. obtain PDFKit line selections cheaply;
2. detect whether page geometry suggests multiple persistent horizontal lanes/gutters;
3. for selections intersecting more than one candidate lane, inspect character geometry;
4. split the selection at persistent gutter boundaries;
5. preserve source range/order provenance;
6. avoid character-by-character work on obviously simple single-column pages.

Do not use page-width percentage alone as the primary trigger.

### 1.4 Introduce a first-class gutter primitive

Add an internal representation such as:

```swift
struct PdfLayoutGutter {
    let minX: CGFloat
    let maxX: CGFloat
    let verticalRange: ClosedRange<CGFloat>
    let confidence: Double
}
```

Gutter evidence should come from persistent whitespace/occupancy across many lines or glyphs, not only block `minX` clustering.

For ordinary two-column pages:

- find one persistent vertical gutter;
- classify each line/fragment as left, right, spanning, or ambiguous;
- read left column top-to-bottom, then right column top-to-bottom for LTR text;
- reverse column order for RTL only when writing direction evidence is strong.

For three-column pages:

- identify two persistent gutters;
- assign content to three lanes;
- order lanes deterministically.

### 1.5 Simplify the critical path

Before invoking the general region/DAG machinery, add a reliable simple-column path:

```text
native fragments
  -> persistent gutter(s)
  -> lane assignment
  -> top-to-bottom order within lane
  -> column-major output
```

Use the more general region resolver only when a page actually contains mixed/spanning structure.

### 1.6 Preserve the single-column fast path

Simple digital books must not pay the full character-geometry cost.

The complexity detector may remain as an early hint, but it must not be the only mechanism capable of discovering a column problem that PDFKit already merged.

## Phase 1 acceptance gates

Mandatory perfect output in the Demo and automated final-parser tests:

- `02-two-columns.pdf`
- `03-three-columns.pdf`
- `12-dense-academic.pdf` for its primary column reading order

Also require generated column fixtures to remain green:

- symmetric 2-column;
- 60/40 and 40/60;
- narrow/wide gutters;
- unequal column heights;
- one column beginning lower;
- short column beside long column;
- indented paragraphs;
- 3-column.

### Phase 1 exit condition

Do not mark Phase 1 complete until a developer can open `02-two-columns.pdf` in the Demo and the final output is unquestionably column-major and correct.

---

# Phase 2 — Robust reconstruction and mixed vertical regions

## Objective

Build correct prose structure on top of the fixed extraction/gutter primitive and support common layouts that transition between full-width and columns.

## Work

### 2.1 Re-evaluate line reconstruction

Once fragment boundaries are trustworthy:

- rebuild visual lines using baseline/vertical overlap;
- keep fragments separated across gutters;
- attach superscripts/subscripts conservatively;
- avoid combining independent side-by-side lanes;
- preserve CJK/RTL spacing behavior.

### 2.2 Re-evaluate paragraph/block reconstruction

Make block merging robust to:

- wrapped lines with different right edges;
- first-line indentation;
- hanging indentation;
- short final paragraph lines;
- uneven column widths;
- large paragraph spacing;
- one column ending earlier;
- headings with distinct style/spacing.

Do not use exact `minX` alignment as a requirement for ordinary paragraph continuity.

### 2.3 Replace global block-left-edge column inference where possible

The current region detector primarily clusters block `minX` values. Retain it only as secondary evidence.

Primary evidence should be:

- persistent gutters;
- lane occupancy;
- vertical continuity;
- block/gutter intersection;
- spanning blocks crossing established gutter centers.

### 2.4 Support vertical region transitions

Correctly segment:

- full-width title -> columns;
- full-width abstract -> columns;
- columns -> full-width conclusion;
- full-width intro -> columns -> full-width conclusion;
- spanning section headings between column regions;
- columns interrupted by caption/figure note.

Use the gutter's `verticalRange` to model where a column structure exists instead of assuming one global page-wide lane model.

### 2.5 Simplify reading-order resolution

Use deterministic sequences whenever structure is clear:

- spanning region;
- lane 1 top-to-bottom;
- lane 2 top-to-bottom;
- next spanning region;
- next lane group.

Only construct graph edges for genuinely semantic relationships such as captions/footnotes or ambiguous attachments.

Do not make the DAG responsible for ordinary column-major order.

## Phase 2 acceptance gates

Mandatory perfect final-parser output:

- `04-spanning-headline-two-columns.pdf`
- `10-mixed-column-transitions.pdf`

And generated mixed-region fixtures:

- full-width title + two columns;
- abstract + two columns;
- two columns + conclusion;
- title + columns + footer note;
- single -> two -> single;
- columns interrupted by caption;
- multiple spanning headings;
- abstract -> columns -> summary.

Re-run Phase 1 fixtures; no regression is allowed.

### Phase 2 exit condition

The Demo must correctly narrate normal magazine/article/academic pages containing titles, abstracts, section headings, and column transitions without row-wise interleaving.

---

# Phase 3 — Side content, tables, footnotes, captions, and running matter

## Objective

Make the parser useful for real Spokio documents beyond plain prose columns while preserving conservative degradation.

## Work

### 3.1 Sidebars and pull quotes

Use established body lanes/gutters before trying to classify side content.

A sidebar should be detected as content that is spatially separated from the primary narrative lane/group and has a limited vertical attachment span.

Define a deterministic spoken policy:

- primary narrative first;
- attached sidebar after the enclosing primary region unless a stronger explicit relation exists.

Pull quotes should not interrupt the body simply because their `y` position overlaps body prose.

### 3.2 Tables

Tables do not need perfect visual reconstruction for Spokio. They need deterministic readable speech.

Priorities:

1. preserve all cell text;
2. detect repeated row/column alignment;
3. identify header row only when confidence is strong;
4. linearize row-major with stable separators;
5. never convert ordinary prose columns into a table merely because lines align;
6. fall back to readable geometric order when table confidence is low.

Use character/glyph or fragment geometry when PDFKit merges multiple table cells into one line selection.

### 3.3 Footnotes and citations

Use combined evidence:

- bottom page zone;
- smaller font;
- separator/rule;
- reference marker;
- body-to-note whitespace;
- multiple small-note cluster.

Default spoken policy:

- body first;
- footnotes after the page's primary narrative unless explicit attachment is reliable.

### 3.4 Captions

Captions should remain close to their anchor region but must not reorder unrelated body columns.

Prefer explicit caption prefixes and spatial attachment. A generic small centered block should not automatically become a caption.

### 3.5 Running headers, footers, and pagination

Fix the real regression fixture and clarify the contract.

`09-repeated-header-footer.pdf` currently contains three pages while the repeated-text cleaner requires four pages for reliable repeated-header statistics.

Choose one explicit resolution:

- regenerate the fixture as at least four pages to test the existing conservative policy; **preferred**, or
- deliberately lower the production threshold only if new false-positive tests prove that three pages are safe.

Do not weaken running-matter cleanup merely to satisfy one fixture.

Continue protecting semantic headings and legitimate years/numbers near page edges.

## Phase 3 acceptance gates

Mandatory real-fixture checks:

- `05-right-sidebar.pdf`
- `06-pull-quote.pdf`
- `07-table-with-prose.pdf`
- `08-footnotes.pdf`
- `09-repeated-header-footer.pdf`

Expected standard:

- side content remains present exactly once;
- body prose is not interleaved incorrectly;
- table content is complete and deterministic;
- footnotes do not interrupt body order;
- repeated running matter follows the documented cleanup policy;
- legitimate semantic edge text is preserved.

Re-run Phase 1 and Phase 2 fixtures; no regression is allowed.

### Phase 3 exit condition

Spokio can ingest common reports, papers, manuals, magazines, and books without obvious reading-order defects or destructive cleanup.

---

# Phase 4 — Spokio hardening, OCR parity, performance, and simplification

## Objective

Turn the corrected parser into something safe to ship and maintain.

## Work

### 4.1 Landscape and irregular layouts

Use `11-landscape-dashboard.pdf` as a degraded-readability target, not a promise of perfect semantic dashboard interpretation.

Requirements:

- preserve all readable text;
- deterministic ordering;
- no crash;
- no duplicate regions;
- low confidence when semantics are ambiguous;
- fallback to source text when analyzer ordering is clearly less trustworthy.

### 4.2 Rotation, crop boxes, and variable page sizes

Revalidate:

- landscape pages;
- 90/180/270 rotation;
- crop/media box differences;
- portrait/landscape mixtures;
- normalized geometry invariants.

### 4.3 OCR parity

The OCR path already exposes positioned observations, which can be cleaner than native PDFKit line selections.

Require equivalent reading-order contracts for:

- scanned single-column;
- scanned two-column;
- mixed native/scanned documents.

Do not increase OCR invocation on healthy digital PDFs simply to avoid fixing native extraction.

### 4.4 Language/script safety

Re-run:

- Vietnamese;
- Latin diacritics;
- horizontal CJK;
- mixed Latin/CJK punctuation;
- horizontal RTL degraded-readable behavior.

No normalization step may destroy Unicode text.

### 4.5 Performance

Benchmark against the pre-layout parser and current branch.

Targets:

- simple single-column digital PDFs remain close to legacy performance because they stay on the fast path;
- expensive character geometry is limited to suspicious/complex page regions;
- memory remains page-bounded;
- no retained full-page raster images after OCR page completion;
- 500-page synthetic stress document completes without growth proportional to retained layout graphs.

A reasonable initial performance guard is:

- no more than ~15% regression on the controlled simple digital-book benchmark unless correctness evidence justifies it;
- complex pages may cost more, but must remain practical for interactive local import.

### 4.6 Simplify aggressively

After correctness is established, remove or reduce heuristics that became redundant.

Candidates for simplification:

- duplicate column heuristics now superseded by gutter/lane evidence;
- DAG edges used only to compensate for incorrect region ordering;
- overlapping confidence systems that do not change fallback behavior;
- synthetic-only special cases with no real fixture justification.

Prefer fewer understandable rules backed by real regression PDFs over a larger number of interacting thresholds.

### 4.7 Final Demo/Spokio verification

Before merge:

- run all 12 real fixtures through the Demo;
- compare Demo output to automated parser output;
- import representative real Spokio PDFs from common document types;
- inspect diagnostics for any fallback/accepted mismatch;
- ensure `.never` remains a permanent escape hatch;
- ensure `.auto` is conservative and is the default;
- ensure `.always` does not bypass information-safety requirements.

## Phase 4 acceptance gates

- all 12 committed PDFs meet their declared support level;
- all generated supported fixtures remain exact;
- degraded fixtures remain readable and never crash;
- OCR equivalents meet the same reading-order contract;
- simple fast-path precision remains >= 99% on the controlled corpus;
- healthy digital-page OCR invocation does not increase;
- performance and memory checks pass;
- Demo output matches final-parser regression expectations.

### Phase 4 exit condition

PR #3 is mergeable only after this phase is complete.

---

## 6. Definition of done for PR #3

The PR is ready to merge when all of the following are true:

- [ ] Real fixture PDFs are SwiftPM test resources.
- [ ] `02-two-columns.pdf` is perfect through `PdfParser` and the Demo.
- [ ] `03-three-columns.pdf` is perfect through `PdfParser` and the Demo.
- [ ] `12-dense-academic.pdf` has correct primary reading order.
- [ ] `04-spanning-headline-two-columns.pdf` is correct.
- [ ] `10-mixed-column-transitions.pdf` is correct.
- [ ] Sidebar/pull-quote fixtures remain complete and deterministic.
- [ ] Table fixture is complete, readable, deterministic, and not misclassified as prose columns.
- [ ] Footnote fixture preserves body-first spoken order.
- [ ] Repeated-header/footer fixture correctly reflects the conservative running-matter policy.
- [ ] Landscape dashboard degrades readably without destructive reordering.
- [ ] Single-column fixture remains on the fast path with no regression.
- [ ] Generated supported fixture suite remains green.
- [ ] OCR/mixed-native-scanned suite remains green.
- [ ] No missing or duplicate semantic text in supported fixtures.
- [ ] Diagnostics explain accepted/fallback decisions.
- [ ] Simple-book performance remains close to legacy behavior.
- [ ] Memory remains page-bounded.
- [ ] `.never` remains a working escape hatch.
- [ ] CI is green.
- [ ] Manual Demo verification is green.

## 7. Implementation discipline

For every change during this recovery:

1. reproduce the failure with a committed real PDF;
2. add/strengthen the final-parser regression test first;
3. identify the earliest incorrect stage using diagnostics;
4. fix that stage rather than compensating downstream;
5. re-run every earlier phase gate;
6. remove obsolete heuristics when a more reliable primitive replaces them;
7. do not mark a phase complete based only on internal unit tests.

The governing principle is simple:

> **A layout analyzer that cannot reliably read an ordinary two-column PDF is not complete, regardless of how many advanced phases are implemented.**
