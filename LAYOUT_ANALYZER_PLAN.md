# PDFKitAudio Layout Analyzer Plan

> Status: **implementation in progress on PR #3**. Phase 0 is being implemented first; later phases remain gated by the exit criteria in this document.
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

- same-line fragments merge despite small baseline noise
- adjacent lines form paragraphs
- paragraph spacing creates block boundaries
- first-line indentation stays in one block
- two columns never merge across gutter
- full-width heading stays separate from body columns
- punctuation spacing is preserved
- superscripts do not vanish
- mixed scripts remain intact

### Exit criteria

- line/block reconstruction is deterministic
- no text loss on supported fixtures
- no cross-column merges on canonical column fixtures

## 11. Phase 4 — Columns, spanning regions, and vertical segmentation

### Objective

Infer the page's coarse layout structure before assigning final reading order.

### Horizontal density projection

Project fragment/block occupancy onto normalized X. Persistent low-density X intervals are candidate gutters. Score gutters using:

- width relative to median character/line height
- vertical persistence
- amount of text on each side
- how few blocks cross the candidate gutter
- whether left/right lanes have repeated aligned edges

Do not treat a temporary paragraph indent or centered heading as a column gutter.

### Vertical segmentation

A page can change layout by Y. Partition into vertical regions when spanning blocks or major lane changes provide strong evidence:

```text
full-width title
----------------
two-column body
----------------
full-width caption
----------------
two-column continuation
----------------
full-width conclusion
```

Analyze columns separately inside each region rather than assigning one column model to the entire page.

### Column requirements

Support at minimum:

- 1 column
- 2 symmetric columns
- 2 asymmetric columns
- 3 columns
- columns beginning/ending at different Y positions
- narrow and wide gutters

Use deterministic left-to-right ordering for LTR regions. Preserve enough writing-direction metadata to support RTL region ordering later.

### Tests

- every Phase 0 column fixture
- every mixed vertical-region fixture
- centered heading must not create fake columns
- short sidenote must not split body into columns
- table cells should not make the whole page appear as N body columns

### Exit criteria

- correct lane count on canonical column fixtures
- correct vertical region boundaries on mixed-layout fixtures
- stable results under small coordinate perturbations

## 12. Phase 5 — Reading-order resolver and safe fallback

### Objective

Convert blocks and regions into a deterministic spoken order.

### Graph model

Represent strong ordering constraints as a directed acyclic graph when possible.

Examples:

- same column: upper block -> lower block
- spanning heading above region -> first blocks of all lanes
- left column completion -> right column beginning for LTR body regions
- full-width region N -> following region N+1
- body paragraph -> tightly associated caption when caption relationship is strong

Avoid adding weak edges simply because two blocks have nearby Y values.

### Topological sort

Use deterministic Kahn-style topological sorting with stable tie-breaking:

1. region order
2. column order
3. normalized Y
4. normalized X
5. source order / stable ID

### Cycles and ambiguity

Cycles indicate contradictory geometry heuristics. Never arbitrarily delete content.

Resolution policy:

1. identify weakest-confidence edge in cycle
2. remove it deterministically
3. recompute
4. reduce layout confidence
5. if confidence falls below threshold, fall back to current page text

### Confidence

Derive page layout confidence from evidence quality, including:

- gutter persistence
- block alignment consistency
- amount of ambiguous overlap
- number/strength of removed graph edges
- text conservation
- role-classification certainty where roles affect ordering

Do not expose a fake precise statistical probability; this is a heuristic confidence score.

### Comparison against native text

Before accepting reconstructed output, compare it to native/OCR selected text:

- similar information/character coverage
- no unexplained disappearance of unique tokens
- no large duplicate expansion
- output is non-empty when source was non-empty

If invariants fail, fall back.

### Tests

- exact marker order for canonical column fixtures
- mixed vertical regions
- unequal column heights
- overlapping floating blocks
- intentionally ambiguous/cyclic synthetic layouts
- deterministic cycle resolution
- fallback preserves old text exactly enough for current public behavior

### Exit criteria

- high-confidence complex fixtures produce expected spoken marker order
- low-confidence fixtures safely use current path
- no content loss in accepted analyzer output

## 13. Phase 6 — Lightweight role classification

### Objective

Improve ordering and spoken usefulness with transparent geometry/style heuristics without turning PDFKitAudio into a general semantic model.

### Roles

#### Heading

Evidence:

- font size relative to page/body median when available
- font weight when available
- short text length
- whitespace above/below
- centered or spanning placement
- existing chapter-heading lexical patterns as weak supporting evidence

#### Body

Evidence:

- dominant column widths
- repeated paragraph alignment
- typical font size/line spacing

#### Sidebar / callout / pull quote

Evidence:

- narrow lane outside dominant body lane
- vertical overlap with body paragraphs
- different alignment or font size
- does not persist like running matter

Default policy: preserve and speak; role only affects placement.

#### Caption

Evidence:

- smaller text near a non-text gap/image region if detectable
- lexical prefix such as Figure/Fig./Table only as supporting evidence
- centered/narrow placement below/above another region

#### Footnote

Evidence:

- bottom-of-page geometry
- smaller font
- separated from body by gap/rule
- numeric/symbol prefix only as supporting evidence

#### List

Evidence:

- repeated bullet/number prefixes
- common hanging indentation
- aligned continuation lines

### Tests

Each classifier must have positive and negative fixtures. Examples:

- centered poem is not a heading merely because centered
- numbered prose is not automatically a list
- small body text is not automatically a footnote
- narrow main column is not automatically a sidebar

### Exit criteria

- roles improve reading order without being necessary for core column correctness
- ambiguous roles resolve to `.unknown`/`.body`, not destructive classification

## 14. Phase 7 — Tables and audiobook-friendly table preservation

### Objective

Detect common tables and keep them coherent in reading order without promising perfect spreadsheet reconstruction.

### Detection

Use repeated X alignments and Y bands:

- many short fragments/lines sharing row bands
- several stable cell-start X positions
- repeated column boundaries
- compact vertical spacing
- optional ruling-line evidence only if cheaply available; do not depend on it

Ensure numbered lists and multi-column prose are strong negative cases.

### Initial linearization

Keep table handling conservative. Build row/cell groups where geometry is clear, then emit deterministic row-major text. Do not invent headers or semantic relationships unless geometry strongly supports them.

Possible internal representation:

```swift
struct PdfLayoutTable {
    let rows: [[PdfLayoutBlock]]
    let rect: CGRect
    let confidence: Double
}
```

For TTS, a later policy can decide whether to add phrases such as "Table" or header labels. The layout layer should initially preserve content/order without inserting fabricated speech.

### Tests

All Phase 0 table fixtures plus negatives:

- numbered list
- glossary-style hanging indent
- two-column article
- aligned code-like text

### Exit criteria

- common small tables remain contiguous in spoken order
- table detection does not break normal prose columns
- no cells are silently lost

## 15. Phase 8 — Geometry-aware document running matter cleanup

### Objective

Improve existing header/footer/page-number cleanup by adding position fingerprints while retaining its conservative semantics.

### Fingerprint

For candidate edge text record small normalized metadata:

```text
normalized text
edge side
normalized Y band
normalized X band / alignment
page parity
numeric template where relevant
```

This permits detection of:

- alternating left/right headers
- chapter-title headers occupying stable positions
- page numbers whose textual decorations vary slightly

### Preserve current safety rules

- require evidence across multiple pages
- preserve a first semantic occurrence for running text when appropriate
- sequential numbers require proven sequence
- standalone years/quantities must not be removed based on position alone
- short semantic sentences near the edge should survive without repetition evidence

### Tests

All running-matter fixtures plus:

- alternating X position by page parity
- chapter transition changes running header text
- sparse headers in only part of a document
- year sequence at bottom that looks like pagination but is semantic

### Exit criteria

- increased removal precision/recall on known running matter
- no regression of current conservative numeric safety tests

## 16. Phase 9 — Parser integration, configuration, and provenance

### Objective

Integrate layout analysis into `PdfParser` without destabilizing public callers.

### Configuration

Add a small public configuration surface only when behavior is proven. Candidate shape:

```swift
public enum PdfLayoutMode: Sendable {
    case automatic
    case never
    case always
}
```

Potential configuration:

```swift
public struct PdfLayoutConfiguration: Sendable {
    public let mode: PdfLayoutMode
    public let minimumComplexityConfidence: Double
    public let minimumReadingOrderConfidence: Double
}
```

Avoid exposing every heuristic threshold. Internal tuning should remain implementation detail.

Default should be `.automatic` only after regression quality is established; until then implementation can remain opt-in/internal.

### Parser order

For each page:

1. extract native text
2. decide whether OCR is required using existing OCR policy
3. obtain positioned fragments for selected source(s)
4. classify page complexity
5. run analyzer only when requested/justified
6. validate reconstructed text against source invariants
7. choose analyzer text or current fallback
8. run existing `PdfTextCleaner`
9. retain page provenance

### Provenance additions

Consider internal diagnostics or an additive model field that records whether layout analysis affected a page. Do not overload `.native`/`.ocr`; those describe text source, not ordering strategy.

Potential future additive metadata:

```text
layoutAnalyzed: Bool
layoutConfidence: Double?
layoutComplexity: ...
```

Only expose publicly if it provides real caller value.

### Cancellation/performance

- preserve per-page cancellation checks
- never retain Vision page images after page completion
- complexity detector should be cheaper than full analyzer
- native geometry extraction must remain bounded
- avoid page-parallel PDFKit access unless its safety contract changes

### Tests

- existing parser tests unchanged
- `.never` exactly preserves current behavior
- `.automatic` stays on fast path for ordinary books
- `.always` analyzes when geometry exists but still falls back on invariant failure
- cancellation through layout work
- progress remains monotonic
- page provenance/indexes unchanged
- OCR/native source selection semantics unchanged

### Exit criteria

- public behavior is backward compatible
- no chapter/TTS source mapping regressions
- layout mode semantics are documented and deterministic

## 17. Phase 10 — Validation, adversarial testing, and performance hardening

### Objective

Prove that the analyzer improves complicated PDFs without making ordinary PDFs worse.

### Deterministic matrix

By this phase the synthetic matrix should contain at least 50 layout variants. Prefer 70+ once combinations are included.

For each supported fixture track:

- expected marker order
- marker coverage
- duplicate marker count
- analyzer/fast-path decision
- layout confidence
- output determinism

### Real-world corpus

Maintain a small legally redistributable or locally referenced corpus representing:

- public-domain book
- academic paper
- technical report
- magazine/newsletter style page
- textbook-like page
- scanned historical document
- mixed digital/scanned report
- table-heavy report

Do not commit copyrighted fixtures without redistribution rights. Tests may document external/manual fixture acquisition separately.

### Adversarial / property tests

Generate controlled perturbations:

- +/- small X/Y jitter
- small font-size variation
- gutter width changes
- paragraph indentation changes
- source fragment ordering shuffled while geometry remains fixed
- duplicate fragments injected
- one fragment moved into ambiguous overlap

Invariants:

- every accepted analyzer output contains every unique semantic marker exactly once unless fixture explicitly models duplicates
- output order is deterministic across repeated parses
- normalized bounds remain finite/in-range
- no crash for empty/one-fragment/huge-fragment pages
- layout analysis never increases text length by an unexplained large factor

### Fuzzing

Add bounded random geometry generation with a fixed seed. The purpose is invariants/crash detection, not exact semantic ordering.

### Performance budgets

Measure against Phase 0 baseline on Apple Silicon CI/local hardware.

Suggested initial gates, tune after real measurements:

- simple digital document: <= 10-15% parser time regression when automatic mode stays on fast path
- two-column digital document: <= 2x current native extraction time is acceptable if reading-order accuracy materially improves
- no unbounded memory growth with page count
- OCR-dominated documents should not materially regress from duplicate rasterization

Use trend/baseline measurements rather than fragile millisecond assertions in normal CI. Performance tests can be explicit/manual if runner variance is high.

### Quality gates

Before enabling automatic mode by default:

- near-perfect marker coverage on supported deterministic fixtures
- >= 98% pairwise reading-order accuracy on canonical supported fixtures
- zero known semantic text-loss regressions in ordinary single-column corpus
- no duplicate inflation from native/OCR overlap
- fast-path precision high enough that ordinary books almost never enter analyzer unnecessarily

## 18. Phase 11 — Hardening, diagnostics, documentation, and rollout

### Diagnostics

Keep production diagnostics lightweight and privacy-safe. Do not log document text by default.

Potential debug diagnostics:

```text
page index
fragment count
line count
block count
complexity category/confidence
column/region count
reading-order confidence
fallback reason
```

Optional developer-only layout dump can contain text/rects when explicitly invoked by tests/demo tooling.

### Demo/manual inspection

Enhance the macOS example with a developer/debug mode only if it proves useful:

- choose fixture/PDF
- show selected spoken text
- optionally overlay block rectangles and reading-order numbers
- compare native order vs analyzed order

Do not turn the package demo into a production document viewer.

### Documentation

Update README with:

- what layout analysis improves
- layouts it supports well
- unsupported/degraded cases
- performance tradeoff
- configuration examples
- relationship between OCR source selection and layout analysis

### Rollout strategy

1. internal/opt-in analyzer
2. validate against deterministic + real-world corpus
3. enable `.automatic` for complex pages only
4. monitor consuming app regressions
5. preserve `.never` escape hatch

Never remove fallback behavior merely because synthetic tests pass.

## 19. Proposed file structure

Likely production files:

```text
Sources/PDFKitAudio/Layout/
  PdfLayoutFragment.swift
  PdfLayoutGeometry.swift
  PdfNativeLayoutExtractor.swift
  PdfOCRLayoutExtractor.swift
  PdfLayoutComplexityDetector.swift
  PdfLayoutLineBuilder.swift
  PdfLayoutBlockBuilder.swift
  PdfLayoutRegionDetector.swift
  PdfLayoutRoleClassifier.swift
  PdfLayoutTableDetector.swift
  PdfReadingOrderResolver.swift
  PdfLayoutAnalyzer.swift
  PdfLayoutConfiguration.swift
```

Likely tests:

```text
Tests/PDFKitAudioTests/Layout/
  LayoutFixtureBuilder.swift
  LayoutFragmentTests.swift
  LayoutComplexityDetectorTests.swift
  LayoutLineBuilderTests.swift
  LayoutBlockBuilderTests.swift
  LayoutRegionDetectorTests.swift
  LayoutRoleClassifierTests.swift
  LayoutTableDetectorTests.swift
  LayoutReadingOrderTests.swift
  LayoutIntegrationTests.swift
  LayoutAdversarialTests.swift
  LayoutPerformanceTests.swift
```

Exact file count is secondary to clear responsibilities. Avoid giant god objects.

## 20. Definition of done

This project is complete when all of the following are true:

- normal single-column PDFs retain current behavior/performance characteristics
- common 2/3-column documents produce correct spoken reading order
- mixed full-width/column layouts are reconstructed correctly
- sidebars/captions/footnotes/tables are preserved coherently
- scanned and native text share equivalent geometry reasoning
- repeated running matter is removed at least as safely as today
- low-confidence cases fall back without content loss
- OCR source-selection semantics remain correct
- chapters and TTS source-page mappings remain correct
- cancellation/progress guarantees remain intact
- deterministic fixture corpus passes
- real-world validation meets quality gates
- performance/memory stay within agreed budgets
- limitations are documented accurately

The target is not "understand every PDF." The target is a robust, lightweight, native **spoken reading-order engine** that materially improves complicated PDFs without making ordinary books worse.
