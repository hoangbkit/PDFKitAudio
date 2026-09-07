# PDFKitAudio Layout Analyzer Plan

> Status: **planning only**. This document intentionally contains no implementation work.
>
> Baseline: `master` at `294e9dce6c67cb717f6220b34ef7124ace4962fb`.

## 1. Purpose

PDFKitAudio already has a strong lightweight pipeline for book-like PDFs: native PDFKit text first, selective Vision OCR, conservative audiobook cleanup, TOC/chapter construction, and TTS-oriented segmentation. Its main quality ceiling is not OCR or chunking; it is semantic reading order on visually complex pages.

The goal of this work is to add a lightweight, geometry-first layout analyzer that reconstructs a reliable **spoken reading order** before cleanup/chapter/TTS preparation, while preserving the current fast path for ordinary single-column documents.

The analyzer is explicitly optimized for document-to-audio use. It does not need to recreate the visual document or match a general-purpose document-understanding model. It needs to answer, conservatively and deterministically:

1. What text belongs together as a line and paragraph/block?
2. Which blocks form the main body, columns, sidebars, captions, footnotes, tables, or spanning regions?
3. In what order should those blocks be spoken?
4. When is the current `PDFPage.string` result already good enough that layout analysis should not run?

## 2. Goals

- Correct common one-, two-, and three-column reading order.
- Correct pages that transition between full-width and multi-column regions.
- Preserve headings that span multiple columns.
- Handle asymmetric columns and common sidebars without interleaving text.
- Preserve captions, lists, footnotes, and table content in a deterministic spoken order.
- Improve header/footer/page-number cleanup using geometry without making removal aggressive.
- Use the same internal geometry model for native PDF text and Vision OCR results.
- Preserve current behavior for normal books whenever layout analysis adds no value.
- Remain macOS-native and lightweight: PDFKit + Vision + Foundation/AppKit only.
- Keep memory page-bounded and avoid retaining rendered page images.
- Keep behavior deterministic for equivalent input.
- Preserve source-page provenance and exact page indexes throughout the pipeline.
- Fail safely: uncertainty must degrade to the current extraction path, not destroy readable text.

## 3. Non-goals

- Recreating Docling/Granite-style full document understanding.
- Recovering exact visual styling or exporting HTML that matches the source page.
- OCRing every digital page simply to obtain geometry.
- Perfect reconstruction of arbitrary forms, diagrams, mathematical notation, or deeply nested tables.
- Inferring semantic meaning from images.
- Using an LLM, remote service, Python runtime, GPU model, or bundled neural layout model.
- Changing TTS model policy, retries, prosody, or audio generation behavior.
- Making silent destructive decisions such as dropping sidebars/tables by default.

Unsupported or low-confidence layouts must remain readable, even if not perfectly ordered.

## 4. Design principles

### 4.1 Conservative by default

The existing native path is already good for ordinary books. The analyzer must earn the right to replace it. If complexity detection or reading-order confidence is low, use the existing page text.

### 4.2 Geometry before semantics

Reading order should be driven by stable spatial evidence first: bounding boxes, overlap, whitespace valleys, alignment, line spacing, and region continuity. Semantic labels such as `heading` or `caption` can improve ordering but must not be required for basic correctness.

### 4.3 Adaptive thresholds

Do not use hard-coded pixel distances. Derive tolerances from page-normalized coordinates and page statistics such as median fragment height, median line height, median inter-line spacing, dominant left edges, and detected gutters.

### 4.4 One coordinate system

Native PDF text geometry and Vision OCR geometry must be transformed into the same normalized page coordinate system, independent of crop/media box size, rotation, and raster size.

Recommended internal convention:

- normalized page coordinates in `[0, 1]`
- origin at top-left for reading-order reasoning
- `x` grows rightward
- `y` grows downward

### 4.5 Preserve provenance

Every synthesized line/block must retain the fragment IDs and source page index that created it. If the analyzer changes ordering, diagnostics must make the decision inspectable.

### 4.6 Deterministic tie breaking

Geometry can be ambiguous. Every sort, cluster, graph traversal, and cycle-resolution rule must have a deterministic final tie-breaker based on stable source order/IDs.

### 4.7 Page-bounded work

All page images, OCR observations, fragments, lines, blocks, and graphs should be released after the final `PdfPageContent` for that page is built, except for small document-level fingerprints needed for running-matter cleanup.

## 5. Target pipeline

Current conceptual pipeline:

```text
PDFPage
  -> PDFPage.string
  -> selective OCR when native text looks weak
  -> page cleanup
  -> document cleanup
  -> chapters
  -> TTS segments
```

Target pipeline:

```text
PDFPage
  |
  +-> native extraction -------------------------+
  |                                               |
  +-> Vision OCR when policy requires it --------+ 
                                                  |
                                                  v
                                      positioned text fragments
                                                  |
                                                  v
                                      page complexity detector
                                          /               \
                                  simple /                 \ complex
                                      /                     \
                                     v                       v
                         existing text fast path      PdfLayoutAnalyzer
                                                             |
                                        fragments -> lines -> blocks
                                                             |
                                              regions / columns / roles
                                                             |
                                                reading-order resolver
                                                             |
                                                  ordered page text
                                                             |
                                      +----------------------+
                                      v
                              existing page cleanup
                                      v
                        geometry-aware document cleanup
                                      v
                                  chapters
                                      v
                                TTS segments
```

## 6. Proposed internal model

Names can change during implementation, but the responsibilities should remain separated.

```swift
struct PdfLayoutFragment {
    let id: Int
    let text: String
    let rect: CGRect              // normalized top-left coordinate system
    let source: PdfExtractionSource
    let confidence: Double
    let sourceOrder: Int
    let style: PdfLayoutStyleHints?
}

struct PdfLayoutLine {
    let id: Int
    let fragments: [PdfLayoutFragment]
    let text: String
    let rect: CGRect
    let baselineEstimate: CGFloat?
}

struct PdfLayoutBlock {
    let id: Int
    let lines: [PdfLayoutLine]
    let text: String
    let rect: CGRect
    let role: PdfLayoutRole
    let column: Int?
    let region: Int
    let confidence: Double
}

enum PdfLayoutRole {
    case body
    case heading
    case list
    case sidebar
    case caption
    case footnote
    case table
    case runningMatter
    case unknown
}

struct PdfPageLayout {
    let pageIndex: Int
    let blocks: [PdfLayoutBlock]
    let readingOrder: [Int]
    let complexity: PdfLayoutComplexity
    let confidence: Double
}
```

Style hints are optional. Native extraction may expose font size/weight or attributed-string information; OCR may not. The algorithm must remain correct when style hints are absent.

## 7. Phase 0 — Baseline, fixture system, and quality metrics

### Objective

Create the safety net before changing extraction behavior. This phase establishes measurable current behavior and a large deterministic layout corpus.

### Implementation scope

1. Extend the existing deterministic PDF fixture builder so tests can place text at explicit rectangles, font sizes, alignments, and page rotations.
2. Add helpers that create marker-based text such as `L1_A`, `L1_B`, `R1_A`, `R1_B`. These make reading-order failures exact and easy to diagnose.
3. Add fixture helpers for:
   - positioned native text
   - scanned/image-only equivalents
   - mixed native + scanned pages
   - crop/media box differences
   - page rotation
   - variable page sizes
4. Add golden expected-order helpers that compare semantic marker order rather than relying only on raw PDFKit formatting.
5. Add pairwise reading-order scoring for real-world fixtures: if expected block A precedes B, record whether the parser satisfies that relationship.
6. Add benchmark harnesses for:
   - 100-page simple digital book
   - 100-page two-column digital document
   - mixed digital/scanned document
   - 500-page stress document with bounded synthetic content
7. Record baseline wall-clock time, peak memory where practical, OCR page count, output character count, and current reading-order score.
8. Add debug-only utilities to dump page fragments/blocks as JSON or textual diagnostics. Do not add a public API yet.

### Required layout fixtures

At minimum, build deterministic fixtures for all of these before analyzer implementation begins:

#### Simple layouts

- single column, narrow margins
- single column, wide margins
- centered paragraphs
- justified-looking paragraphs
- first-line indentation
- hanging indentation
- short chapter heading + body
- full-width title + body
- large whitespace between paragraphs
- blank page
- page containing only a page number

#### Column layouts

- symmetric two-column
- asymmetric two-column 60/40
- asymmetric two-column 40/60
- narrow gutter
- wide gutter
- three-column
- columns with unequal final heights
- left column ending early
- right column beginning lower
- one short column beside one long column
- columns with indented paragraphs

#### Mixed vertical regions

- full-width title -> two columns
- full-width abstract -> two columns
- two columns -> full-width conclusion
- full-width title -> two columns -> full-width footer note
- single column -> two columns -> single column
- two columns interrupted by a full-width figure caption
- multiple spanning headings inside a multi-column page

#### Side content

- right sidebar beside body
- left sidebar beside body
- pull quote inside body vertical range
- narrow callout between two body regions
- marginal note
- multiple small sidebars

#### Tables

- simple 2x3 table with borders
- simple borderless table
- table with header row
- numeric table
- uneven column widths
- table spanning full page width
- table embedded within a single column
- table between two text regions
- table with multi-line cells

#### Footnotes and captions

- one footnote
- multiple footnotes
- footnote rule + footnotes
- image caption below a body region
- caption between columns
- small-font citation block

#### Running matter

- identical header on every page
- alternating even/odd headers
- chapter-title running header
- pure page number footer
- decorated page number footer
- legitimate year near page bottom
- short semantic sentence near page top that must not be removed

#### Difficult positioning

- floating text box overlapping vertical range of body
- text box near center gutter
- landscape page
- rotated page 90 degrees
- mixed portrait/landscape document
- different crop box from media box
- tiny superscript-like text near a line
- duplicate/overlapping text layer
- invisible/near-duplicate OCR layer if reproducible with the fixture builder

#### Scripts/languages

- Latin with diacritics
- Vietnamese
- horizontal CJK
- Arabic or Hebrew right-to-left horizontal text where platform extraction supports deterministic testing
- mixed Latin + CJK punctuation

Vertical CJK can be added as an explicit unsupported/diagnostic fixture unless a reliable native strategy is found.

### Tests

- All existing tests must pass unchanged.
- Every new fixture must declare whether it is `supported`, `degraded-but-readable`, or `unsupported` for the planned analyzer.
- Baseline tests should intentionally demonstrate current failures for complex layouts without making CI red; record those as expected baseline outcomes/metrics.

### Exit criteria

- Large deterministic fixture matrix exists.
- Existing `master` behavior is measurable.
- Reading-order score and performance baseline are recorded.
- No production parsing behavior changes.

## 8. Phase 1 — Unified positioned-fragment extraction

### Objective

Obtain reliable text + bounding boxes from both native PDF content and Vision OCR without yet changing selected page text.

### Native extraction investigation

Evaluate PDFKit-supported ways to obtain stable text geometry, including line/selection-based geometry and character-level bounds where necessary. Choose the lowest-cost method that satisfies these invariants:

- complete enough text coverage for supported digital PDFs
- stable source ordering
- rectangle per fragment
- correct handling of crop/media boxes and page rotation
- no reliance on private APIs
- no page rasterization for healthy native text

Do not prematurely commit to character-level extraction if line-level or run-level geometry is sufficient. Character-level work can be significantly more expensive on large pages.

### OCR extraction changes

Refactor OCR internals so Vision observations are not immediately flattened to strings. Preserve for each recognized observation:

- recognized string
- normalized bounding box
- confidence
- observation order

Transform Vision's coordinate system into the unified page coordinate system before any layout reasoning.

### Deduplication requirements

Detect exact or near-exact overlapping fragments caused by duplicate PDF text layers or OCR/native overlap. Deduplication must require both strong spatial overlap and text similarity; never remove repeated text simply because the string matches elsewhere on the page.

### Tests

- geometry normalization for portrait, landscape, crop-box, and rotated pages
- stable fragment ordering across repeated parses
- Unicode integrity
- OCR observation geometry transformation
- native/OCR equivalent-page geometry sanity checks
- duplicate overlapping fragments removed
- legitimate repeated words in different positions preserved
- fragments never escape normalized page bounds except for tiny tolerated numeric error

### Exit criteria

- `PdfLayoutFragment`-equivalent internal data exists for native and OCR sources.
- Existing selected text remains unchanged.
- Geometry correctness tests pass on all supported fixture orientations.

## 9. Phase 2 — Page complexity detector and fast-path gate

### Objective

Avoid running full layout reconstruction on pages where current extraction is already appropriate.

### Features

Compute cheap page-level features from positioned fragments/lines:

- number of distinct left-edge clusters
- number of distinct right-edge clusters
- horizontal text-density projection
- persistent vertical whitespace valleys
- amount of horizontal overlap between candidate lanes
- percentage of blocks spanning most page width
- count of short aligned cell-like fragments
- width distribution / multimodality
- presence of narrow side lanes
- abrupt changes in dominant X-range by vertical slice
- native extraction quality from existing OCR policy

### Decision model

Use a transparent weighted heuristic, not ML. Produce both a category and confidence:

```text
simpleSingleColumn
likelyMultiColumn
mixedRegions
likelyTableHeavy
irregularPositioned
unknown
```

Only bypass the current path when complexity evidence exceeds a conservative threshold.

### False-positive policy

A false positive on a simple book is more dangerous than a false negative on a complex page because it risks changing already-good text. Tune toward high precision for `complex` classification.

### Tests

Create classification assertions for the full Phase 0 fixture matrix, including adversarial simple pages:

- narrow centered poem must not become two columns
- dialogue with short alternating lines must not look table-like
- indented quotes must not become sidebars
- numbered lists must not become tables
- wide heading + body must still be simple if body is one column

### Exit criteria

- Ordinary single-column fixtures consistently stay on the fast path.
- Canonical two-/three-column fixtures are detected with high confidence.
- Mixed vertical-region fixtures are detected.
- No selected text changes yet.

## 10. Phase 3 — Fragment-to-line and line-to-block reconstruction

### Objective

Build stable logical lines and paragraph-like blocks using geometry.

### Fragment-to-line algorithm

1. Estimate median fragment height and dominant baselines/vertical centers.
2. Candidate fragments share a line when vertical overlap and baseline/center distance fall within adaptive tolerance.
3. Sort fragments within a line according to dominant writing direction.
4. Reconstruct spaces from horizontal gaps and source text boundaries conservatively.
5. Preserve punctuation adjacency and Unicode grapheme clusters.
6. Keep superscript/subscript-like fragments associated with the closest compatible line when confidence is strong; otherwise keep them as separate fragments rather than losing text.

### Line-to-block algorithm

Merge adjacent lines when evidence supports one paragraph/block:

- compatible left/right alignment
- compatible width
- plausible line spacing
- no strong column gutter crossing
- no large vertical separation
- no spanning-region boundary
- no strong heading/body style transition

Paragraph indentation should not automatically split blocks. Use first-line vs subsequent-line patterns.

### Important separation of responsibility

Do not perform audiobook cleanup here. Keep source line breaks and hyphen evidence intact enough for the existing `PdfTextCleaner` to make its conservative dehyphenation decision later.

### Tests

- split glyph/runs reconstruct one line
- correct spaces between fragments
- punctuation spacing
- indented first line remains same paragraph
- hanging indent remains coherent
- bullet/list items remain distinct
- heading remains separate from body
- columns never merge across gutter
- footnote text does not merge into body above
- narrow sidebar does not merge into adjacent body
- CJK lines do not receive inappropriate ASCII spaces
- RTL line ordering where deterministic platform support exists

### Exit criteria

- Every supported fixture produces deterministic lines and blocks.
- No block crosses an established strong gutter.
- Text conservation invariant passes: normalized concatenated fragment text equals normalized concatenated block text, except explicitly recorded deduplication.

## 11. Phase 4 — Columns, spanning regions, and vertical segmentation

### Objective

Infer page regions before establishing reading order.

### Column detection

Use multiple mutually reinforcing signals:

1. X-axis text-density projection.
2. Persistent vertical whitespace valleys.
3. Clusters of block left/right edges.
4. Vertical continuity of candidate lanes.
5. Low cross-gutter block overlap.

A gutter must persist across enough vertical extent to count as a column separator. Local paragraph indentation is not a column.

Support 1-3 primary columns initially. More than three should be treated as irregular/table-like unless confidence is exceptionally strong.

### Spanning-block detection

A block is a spanning candidate when it:

- overlaps multiple detected column lanes, or
- occupies a large proportion of page width, and
- has meaningful vertical separation or style evidence.

Spanning blocks divide the page into vertical regions. Each region can have a different column model.

Example:

```text
[ full-width title ]
--------------------
[left col][right col]
[left col][right col]
--------------------
[ full-width summary ]
```

must be modeled as three vertical regions, not one page-wide two-column sort.

### Sidebar distinction

A narrow lane should be classified as a sidebar candidate rather than a primary column when it has low vertical continuity, substantially smaller width, and is surrounded vertically by a dominant body lane.

### Tests

- all two-/three-column fixtures
- asymmetric columns
- narrow/wide gutters
- unequal column heights
- spanning heading
- abstract then columns
- columns then conclusion
- multiple span transitions
- sidebar vs true second column
- pull quote vs primary column
- figure/caption interruption

### Exit criteria

- Canonical supported fixtures receive the expected region/column assignment.
- No primary-column detector mistakes ordinary paragraph indentation for a gutter.
- Region boundaries are deterministic and stable under small coordinate perturbations.

## 12. Phase 5 — Reading-order DAG and deterministic resolver

### Objective

Turn blocks/regions into a safe spoken sequence.

### Why a graph

Avoid a giant comparator that mixes X and Y heuristics. Instead, add precedence edges only when evidence is strong, then topologically sort.

### Core precedence rules

Within a vertical region:

- same primary column: upper block precedes lower block
- LTR multi-column: final block of left column precedes first block of next column
- RTL multi-column: inverse horizontal column order when dominant document/page direction is confidently RTL
- spanning block above a column region precedes all blocks in that region
- spanning block below a column region follows all blocks in that region
- caption strongly attached to a figure/table region follows its anchor region
- footnote region follows the main body region for the page

Across vertical regions:

- earlier region precedes later region

### Cycle handling

Cycles indicate conflicting heuristics. Never drop blocks. Resolve by removing the lowest-confidence inferred edge, record a diagnostic, and retry topological sort. Final fallback is deterministic geometric/source order.

### Confidence

Produce a page reading-order confidence from:

- strength of detected gutters/regions
- ambiguity of block assignments
- number of removed graph edges
- number of unknown blocks
- geometry overlap conflicts

Low-confidence analyzed output should be compared against the existing fast-path text and may be rejected.

### Tests

- exact marker sequence for every supported complex fixture
- deterministic result across repeated parses
- intentionally ambiguous overlap fixture triggers fallback rather than text loss
- forced cycle fixture preserves all blocks
- LTR and RTL column sequencing
- headings before columns
- footnotes after body
- sidebars follow configured attachment policy

### Exit criteria

- Supported generated fixtures produce exact expected marker order.
- No block appears twice or disappears.
- Every graph resolves deterministically.

## 13. Phase 6 — Lightweight role classification and special structures

### Objective

Improve spoken ordering for common non-body structures without introducing a heavyweight semantic model.

### Role scoring

Use transparent heuristic scores from:

- relative font size when available
- block width/height
- text length
- whitespace above/below
- centeredness
- indentation
- page position
- repeated alignment patterns
- proximity to body/table regions
- repeated X positions and Y bands
- punctuation/list prefixes

Roles are hints, not destructive truth.

### Heading

Strong signals:

- larger font than page median
- short text
- surrounding whitespace
- centered/full-width placement
- position before body region

Heading classification should improve region boundaries and chapter heuristics later, but ordinary text must remain readable if misclassified.

### Lists

Preserve list item boundaries and marker text. Do not merge adjacent bullets into one paragraph.

### Sidebars / pull quotes

Default spoken policy: **preserve**, never silently skip. Attach a sidebar to the closest compatible body region and speak it after that body region unless there is stronger source ordering evidence.

Expose skip/include policy only if there is a clear consuming-app need; avoid premature public configuration.

### Captions

Attach captions using geometric proximity, width alignment, smaller style hints, and short text. Speak after the nearby anchored region. If the anchor cannot be inferred, preserve caption in geometric order.

### Footnotes

Detect a bottom-page footnote region only with strong evidence such as:

- small text relative to body
- horizontal rule / strong separation when detectable
- concentrated bottom zone
- reference-marker patterns

Do not treat every small bottom paragraph as a footnote.

### Tables

Table detection signals:

- repeated X positions across multiple Y bands
- multiple short blocks/cells per row
- aligned column boundaries
- dense local grid-like geometry

Initial supported table policy:

1. Detect a table region.
2. Cluster rows by Y and cells by stable X lanes.
3. If row/column structure confidence is high, linearize row-major.
4. If a clear header row exists, use header-aware spoken text where deterministic.
5. If table structure confidence is low, preserve conservative row-major geometric text rather than inventing relationships.

Example preferred output for a confident simple table:

```text
Name: Apple. Revenue: 100. Growth: 12 percent.
Name: Google. Revenue: 90. Growth: 8 percent.
```

Do not attempt merged-cell/nested-table semantics in the first implementation. Such tables must degrade without losing text.

### Tests

- headings of different sizes/alignment
- bullets and numbered lists
- left/right sidebars
- pull quotes
- captions above/below
- footnotes vs legitimate bottom text
- simple bordered and borderless tables
- table with header
- numeric table
- multi-line table cells
- ambiguous table-like list must remain readable

### Exit criteria

- No role classifier removes text.
- Confident simple tables linearize deterministically.
- Low-confidence special structures degrade to ordered blocks.

## 14. Phase 7 — Geometry-aware document cleanup

### Objective

Improve recurring-header/footer/page-number removal using layout information while preserving the conservative philosophy of the existing `PdfDocumentTextCleaner`.

### Document-level fingerprints

Retain only small per-block fingerprints after page analysis:

- normalized text signature
- normalized rect / Y zone
- role hint
- page index
- optional style bucket

### Running-matter detection

Require both textual recurrence and geometric consistency. Support:

- identical running headers
- alternating even/odd headers
- chapter-title running headers
- decorated pagination
- pure pagination

Keep the existing principle that repeated semantic text should retain a safe first occurrence unless the evidence specifically proves non-semantic pagination.

### Integration strategy

Do not create two independent cleaners that can double-remove content. Refactor document cleanup so text-only logic remains the fallback while geometry augments confidence when layout metadata exists.

### Tests

- all existing cleanup tests unchanged
- alternating headers
- moving page number within footer zone
- legitimate years/quantities near edge
- chapter heading identical to later running header
- short semantic top line appearing only twice
- documents with fewer than four pages
- mixed analyzed/fast-path pages

### Exit criteria

- Existing cleanup behavior does not regress.
- Geometry improves recurring-matter precision on complex layouts.
- No removal depends on font size alone.

## 15. Phase 8 — Parser integration, selection policy, and public configuration

### Objective

Integrate the analyzer into the actual selected-text path without destabilizing the package API.

### Recommended configuration

Keep the public surface small. A likely shape is:

```swift
enum PdfLayoutMode: Sendable {
    case auto
    case never
    case always
}

struct PdfLayoutConfiguration: Sendable {
    var mode: PdfLayoutMode
}
```

Default should be `.auto`.

Avoid exposing dozens of heuristic thresholds. Thresholds are implementation details and should remain internal unless a real caller demonstrates a tuning need.

### Selection policy

For each page:

1. Obtain native text and native quality.
2. Invoke OCR according to the existing OCR policy.
3. Preserve positioned observations for the selected extraction candidate.
4. Run complexity detection.
5. If page is simple, retain existing selected text.
6. If page is complex and layout confidence is sufficient, produce analyzed text.
7. Compare analyzed output against conservation/sanity invariants.
8. If invariants fail or confidence is too low, fall back to current selected text.
9. Continue existing cleanup.

### Sanity invariants before accepting analyzed output

- no major text loss relative to fragment information count
- no duplicated block IDs
- no empty output when source text is meaningful
- output character/information count within a safe ratio of source fragments
- all expected fragments accounted for or explicitly deduplicated

### Progress and cancellation

Layout analysis is page-local. Cancellation should be checked:

- before geometry extraction if expensive
- before layout analysis
- after layout analysis

Avoid casually adding a new public `PdfParseStage` case because downstream exhaustive switches may break. Initially report layout work inside `extracting` unless a deliberate API-versioning decision is made.

### Provenance

Keep `PdfPageContent.extractionSource` meaning native vs OCR. Layout analysis is not a new extraction source; it is a transformation of the selected source. If diagnostics need to expose layout usage, prefer a separate optional/internal field rather than overloading extraction provenance.

### Tests

- `.never` produces current behavior
- `.always` analyzes supported pages
- `.auto` preserves simple fast path
- OCR/native selection still follows existing policy
- mixed native/scanned complex document
- cancellation during large complex document
- progress monotonicity remains valid
- stable IDs/provenance preserved

### Exit criteria

- Layout-aware text is used only when safe.
- Existing simple-document output is byte-equivalent or intentionally documented where exact PDFKit formatting prevents that guarantee.
- Existing public initializers remain source-compatible.

## 16. Phase 9 — Comprehensive real-world and adversarial testing

### Objective

Move beyond synthetic correctness and prove the analyzer against many layout families.

### Test corpus strategy

Use three layers.

#### Layer A — deterministic generated PDFs

The Phase 0 matrix is the primary CI suite because it is reproducible and legally uncomplicated.

Target: at least **50 distinct layout fixtures**, with multiple variants for spacing, page size, and orientation.

#### Layer B — checked-in small handcrafted fixtures

Add small, purpose-built PDFs when PDF generation APIs cannot reproduce a behavior such as unusual embedded text order, duplicate layers, or specific rotations. Keep files tiny.

#### Layer C — local/manual real-world corpus

Maintain a documented manual evaluation matrix without necessarily committing copyrighted documents. Categories should include:

- novels/books
- technical books
- academic papers
- conference papers
- magazines
- reports/whitepapers
- annual reports
- textbooks
- lecture notes
- manuals
- scanned books
- bilingual documents

For each sampled page, label expected block order, not full copyrighted text.

### Quality metrics

Track:

1. **Block pair ordering accuracy** — percentage of labeled A-before-B relationships satisfied.
2. **Text conservation** — source informative-character count vs accepted output.
3. **Duplicate rate** — duplicated semantic markers/blocks.
4. **Fast-path precision** — simple pages not unnecessarily analyzed.
5. **Complex-page recall** — known multi-column pages detected.
6. **Fallback rate** — complex pages that safely reject analyzer output.
7. **Runtime overhead** — simple and complex digital documents.
8. **Peak memory** — especially 500-page and OCR cases.

### Initial quality gates

These are implementation targets and can be tightened after the Phase 0 baseline:

- 100% existing regression suite passes.
- 100% supported deterministic generated fixtures produce exact expected marker order.
- 0 missing semantic markers on supported fixtures.
- 0 duplicated semantic markers on supported fixtures.
- >= 97% pairwise block-order accuracy on manually labeled supported real-world pages.
- Simple single-column fast-path precision >= 99% on the controlled simple corpus.
- No increase in OCR invocation for healthy simple digital PDFs.
- Median 100-page simple-digital parse time overhead <= 10% relative to baseline.
- Peak memory for the simple-digital benchmark <= 15% above baseline.
- No retained full-page raster images after page completion.

If performance targets are missed, optimize complexity detection/geometry extraction before weakening correctness gates.

### Adversarial tests

- text boxes physically overlap
- nearly zero-width gutter
- three columns with one spanning block
- centered poem that resembles two lanes
- dialogue with short left/right-looking lines
- table-like numbered list
- wide code block with indentation
- duplicate invisible text layer
- page with thousands of tiny fragments
- huge unbroken token
- pathological page with many small labels
- malformed/low-information native text forcing OCR
- OCR failure on one page in a complex document

### Property/invariant tests

Where deterministic random generation is practical, fuzz geometry and assert:

- analyzer never crashes
- output deterministic for same seed
- every accepted block appears once
- graph always resolves
- coordinates remain finite/in bounds
- fallback returns readable original text
- no Unicode grapheme corruption

### Exit criteria

- Quality gates met.
- Manual corpus results documented.
- Performance and memory regressions understood and within budget.

## 17. Phase 10 — Hardening, diagnostics, documentation, and rollout

### Objective

Make the feature safe to maintain and safe for consuming apps.

### Diagnostics

Provide internal/debug diagnostics capable of showing:

- complexity category/confidence
- fragments and normalized boxes
- reconstructed lines
- blocks and roles
- detected gutters/regions
- reading-order edges
- removed low-confidence graph edges
- analyzer accepted vs fallback decision

Optionally add a debug overlay in the example macOS app, but keep it out of the core public API unless it proves broadly useful.

### Documentation

Update README with:

- what layout analysis does
- fast-path behavior
- supported layout families
- remaining limitations
- interaction with OCR
- table behavior
- known unsupported cases such as highly graphical pages or vertical writing if still unresolved

### Rollout strategy

1. Land analyzer internals behind `.never`/test-only selection first if needed.
2. Enable `.auto` only after Phase 9 gates pass.
3. Keep explicit `.never` escape hatch.
4. Keep fallback to legacy selected text permanently; it is a safety property, not temporary migration code.

### Exit criteria

- Documentation matches actual support.
- Diagnostics are sufficient to investigate future problematic PDFs without adding ad hoc logging.
- `.auto` is safe as default only after quality gates pass.

## 18. Detailed algorithm notes

### 18.1 X-axis density and gutter detection

Project block/line horizontal spans onto a normalized X histogram. Candidate gutters are low-density valleys that:

- exceed a minimum normalized width derived from median character/fragment width
- persist across a meaningful vertical portion of the region
- separate substantial text mass on both sides

Do not accept a gutter based on a single local whitespace gap.

### 18.2 Vertical slicing

Column structure can change down the page. Detect spanning blocks and major whitespace/structure transitions, then solve columns independently per vertical slice. This is required for academic papers with full-width title/abstract before two-column body text.

### 18.3 Alignment clustering

Cluster left/right edges with adaptive tolerance. Prefer simple deterministic clustering over general-purpose ML. Candidate column lanes should be supported by multiple lines/blocks and meaningful vertical extent.

### 18.4 Writing direction

Default to LTR when text/script evidence is not confidently RTL. For RTL-supported pages, reverse primary-column horizontal order while preserving top-to-bottom order within columns. Horizontal CJK should not receive forced ASCII word spacing. Vertical writing can remain a documented limitation until there is a reliable geometry rule and fixture coverage.

### 18.5 Analyzer-vs-legacy acceptance

Complexity alone is not enough. Accept analyzed output only when:

- reading-order confidence exceeds threshold
- text conservation passes
- duplicate/missing-block invariants pass
- graph ambiguity is below threshold

This two-stage gate is central to protecting existing book quality.

## 19. Expected source organization

Suggested internal organization:

```text
Sources/PDFKitAudio/Layout/
  PdfLayoutAnalyzer.swift
  PdfLayoutFragment.swift
  PdfLayoutLineBuilder.swift
  PdfLayoutBlockBuilder.swift
  PdfLayoutComplexityDetector.swift
  PdfColumnDetector.swift
  PdfRegionDetector.swift
  PdfLayoutRoleClassifier.swift
  PdfReadingOrderResolver.swift
  PdfTableLinearizer.swift
  PdfLayoutDiagnostics.swift
```

Keep files responsibility-focused. Avoid one giant analyzer type.

Suggested tests:

```text
Tests/PDFKitAudioTests/Layout/
  PdfLayoutGeometryTests.swift
  PdfLayoutComplexityTests.swift
  PdfLayoutLineBuilderTests.swift
  PdfLayoutBlockBuilderTests.swift
  PdfColumnDetectorTests.swift
  PdfRegionDetectorTests.swift
  PdfReadingOrderTests.swift
  PdfLayoutRoleTests.swift
  PdfTableLinearizerTests.swift
  PdfLayoutIntegrationTests.swift
  PdfLayoutPerformanceTests.swift
  PdfLayoutAdversarialTests.swift
```

The exact folder structure can be adjusted to SwiftPM/Xcode conventions, but tests should remain separated by algorithmic responsibility.

## 20. Definition of done

The layout analyzer is complete only when all of the following are true:

- Existing ordinary-book behavior is preserved.
- Healthy native PDFs do not incur unnecessary OCR.
- Supported two-/three-column and mixed-region pages have correct spoken order.
- Sidebars/captions/footnotes/tables are preserved and ordered conservatively.
- Text is never silently lost due to layout uncertainty.
- Low-confidence pages fall back safely.
- Document-level cleanup remains conservative.
- Source-page provenance remains exact.
- Cancellation and memory remain page-bounded.
- The deterministic fixture corpus covers at least 50 layout variants.
- Real-world manual evaluation reaches the agreed quality gate.
- Performance overhead on simple digital books remains small enough that the current lightweight character of PDFKitAudio is preserved.
- README clearly documents supported and unsupported layouts.

## 21. Implementation order summary

```text
Phase 0  Baseline + large fixture corpus + metrics
Phase 1  Unified native/OCR positioned fragments
Phase 2  Complexity detector + simple fast-path gate
Phase 3  Fragment -> line -> block reconstruction
Phase 4  Columns + spanning regions + vertical segmentation
Phase 5  Reading-order DAG + confidence + fallback
Phase 6  Roles + sidebars + captions + footnotes + tables
Phase 7  Geometry-aware document cleanup
Phase 8  Parser integration + configuration + cancellation/provenance
Phase 9  Large real-world/adversarial/performance validation
Phase 10 Hardening + diagnostics + docs + rollout
```

Implementation should proceed in this order. Each phase must satisfy its exit criteria and keep all previous tests green before the next phase begins. Do not skip directly to parser integration: the fixture corpus, geometry invariants, complexity precision, and reading-order graph are the safety foundation for the feature.
