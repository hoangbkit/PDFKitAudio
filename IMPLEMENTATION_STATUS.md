# Layout analyzer implementation status

This PR started as a planning-only change and is now implementing the approved plan phase by phase.

- [ ] Phase 0 — baseline, deterministic layout fixture system, quality metrics, and benchmark harness
- [ ] Phase 1 — unified positioned-fragment extraction
- [ ] Phase 2 — page complexity detector and fast-path gate
- [ ] Phase 3 — fragment-to-line and line-to-block reconstruction
- [ ] Phase 4 — columns, spanning regions, and vertical segmentation
- [ ] Phase 5 — reading-order DAG and deterministic resolver
- [ ] Phase 6 — lightweight role classification and special structures
- [ ] Phase 7 — geometry-aware document cleanup
- [ ] Phase 8 — parser integration, selection policy, and public configuration
- [ ] Phase 9 — comprehensive real-world and adversarial testing
- [ ] Phase 10 — hardening, diagnostics, documentation, and rollout

Each phase is marked complete only after its exit criteria are satisfied and CI is green.
