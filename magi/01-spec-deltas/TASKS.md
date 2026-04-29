# Tasks — Spec Deltas

> Sprint: `magi/01-spec-deltas/` • Plan: `PLAN.md`

Milestones are roughly sequential to keep diffs auditable, but tasks tagged 🔀
within a milestone are file-disjoint and may run in parallel.

## Milestone 1 — Skill body changes

- [x] 🔀 **T1.1** — Modify `skills/plan/SKILL.md`
  - Add `## Spec deltas` block to PLAN.md template (after `## Open questions`, before `## Verification`)
  - Add `## Spec deltas` block to SPEC.md template (after `## Out of scope`, before `## Verification plan`)
  - Extend §2 read-context to also load root `SPEC.md` when artifact ∈ {PLAN.md, SPEC.md}
  - Add §3 sub-step "Draft Spec deltas" describing the four-file self-questioning routine
  - Update §5 hand-off to mention reviewing deltas

- [x] 🔀 **T1.2** — Modify `skills/review-plan/SKILL.md`
  - Append a fixed segment to the `xreview-prompt.md` builder (§2) instructing reviewers to evaluate the `## Spec deltas` section: justification, omissions, contract breaks
  - Reviewers tag delta-related issues with `[deltas]` for downstream visibility

- [x] **T1.3** — Modify `skills/commit/SKILL.md`
  - Insert §2.5 "Delta verification" between §2 (drift handling) and §3 (root-sync)
  - Define D1/D2/D3 classification with interactive prompts (lenient default)
  - Downgrade §3 Level 2 to fallback when delta verification passes; keep Level 1 always-on
  - Add `--strict-deltas` flag (D1/D2 → exit non-zero)
  - Extend `--no-root-sync` semantics to also skip §2.5
  - Update §3 to skip Level 2 when deltas-verified

## Milestone 2 — Documentation

- [x] 🔀 **T2.1** — Update `references/AGENTS.md` §6 SSOT discipline
  - One paragraph noting Spec deltas as the sprint's contract declaration against root docs

- [x] 🔀 **T2.2** — Update `SPEC.md`
  - Add `## Spec deltas (Phase 4)` section: schema, Type×Scale scope, lifecycle (plan declares → review evaluates → commit verifies)
  - Update Slash commands table rows for `/magi:plan` and `/magi:commit`
  - Add `--strict-deltas` row to Override flags table
  - Add F-Phase 4 row to Implementation phases table (✅ done)

- [x] 🔀 **T2.3** — Update `README.md`
  - Bump version badge to v0.9.0
  - Brief mention of Spec deltas in feature bullets and/or flow narrative (zh-TW)

## Milestone 3 — Version bump and validation

- [x] **T3.1** — Bump `.claude-plugin/plugin.json` from 0.8.0 to 0.9.0
- [x] **T3.2** — Syntax-check changed shell snippets: `bash -n` on bash blocks
- [x] **T3.3** — Run `./test/e2e-state.sh` (expect: green; no detect-state changes)
- [x] **T3.4** — Run `./test/e2e-fallback.sh` (expect: green; no orchestrator changes)
- [x] **T3.5** — Append WORKS.md entry summarising decisions
- [x] **T3.6** — Present commit summary to user (do NOT auto-commit)
