# Works — Spec Deltas

> Append-only journal. Started: 2026-04-29.

## 2026-04-29 — Implementation

### Decisions made during execution

- **Carrier choice locked**: embedded `## Spec deltas` section inside
  PLAN.md / SPEC.md, not a separate `SPEC_DELTA.md` artifact. Keeps
  detect-state.sh untouched and avoids file proliferation. Trade-off:
  delta edits mid-sprint mutate frozen sprint docs, but this is the
  same semantic as DRIFT.md A-class backfill — no new concept.
- **Strict-mode default**: lenient. `--strict-deltas` opt-in. Matches
  existing magi UX (D1/D2 mirrors DRIFT A/C lenient prompting).
- **TICKET.md / HOTFIX.md scope**: excluded from deltas. Root-doc
  changes from those scopes (rare) fall through to §3 Level 1
  heuristic only. Templates in `skills/plan/SKILL.md` left untouched.
- **Granularity v1**: file-level via `git diff --name-only`. Section-
  level matching against declared `Section: <name>` deferred until
  evidence shows file-level false-positives are unacceptable.
- **`--no-root-sync` semantics**: extended to also skip §2.5. Single
  escape hatch covers both delta verification and Level 1/2 heuristics.
- **`--strict-deltas` × `--no-root-sync`**: incompatible (contradict).
  Skill aborts with usage error if both passed.
- **Level 2 downgrade**: triggered by `deltas_verified=1` flag set in
  §2.5. Level 1 still runs because it covers infrastructure signals
  (`package.json`, `Dockerfile`) that deltas does not declare.
- **Missing `## Spec deltas` in PLAN/SPEC**: warn once, treat
  `declared_set` as empty. Allows old-format sprints to keep working
  without a hard fail; D2 still detects undeclared modifications.

### Files changed

| File | Change |
|------|--------|
| `skills/plan/SKILL.md` | PLAN.md / SPEC.md templates gain `## Spec deltas`; §2 reads root SPEC.md when artifact ∈ {PLAN, SPEC}; new §3.0 drafting routine; §4 hand-off draws attention to deltas |
| `skills/review-plan/SKILL.md` | xreview-prompt builder appends "[Special focus — Spec deltas section]" with three evaluation prompts; reviewers tag delta issues `[deltas]` |
| `skills/commit/SKILL.md` | New §2.5 Delta verification (D1/D2/D3); §3 downgrade on `deltas_verified=1`; new `--strict-deltas` flag; `--no-root-sync` extended to skip §2.5 |
| `references/AGENTS.md` | §6 SSOT discipline gains "Spec deltas" subsection contrasting with DRIFT.md |
| `SPEC.md` | New `## Spec deltas (Phase 4)` section; updated `/magi:plan`, `/magi:commit` rows; new `--strict-deltas` flag row; new F-Phase 4 row |
| `README.md` | Version badge v0.8.0 → v0.9.0; new feature bullet (zh-TW) |
| `.claude-plugin/plugin.json` | 0.8.0 → 0.9.0 (minor — new user-visible behavior) |

### Validation

- `bash -n` on each newly added bash block in `commit/SKILL.md` (5 of 7
  blocks, plus 2 pre-existing): all OK except pre-existing block 7 with
  `<changed files>` placeholder (unchanged from before; not a
  regression)
- `./test/e2e-state.sh`: 33/33 pass — detect-state untouched, all 8
  states + warnings still green
- `./test/e2e-fallback.sh`: pass — orchestrator + MAGI consensus
  unchanged

### Deferred / not done

- Section-level deltas matching (file-level only in v1)
- Yolo-specific auto-decision matrix for D1/D2 (yolo inherits commit
  skill's lenient behavior; revisit when real yolo+deltas usage shows
  pain)
- Manual dogfood (`/magi:plan` then verify deltas section appears) —
  requires running the plugin in a session, defer to user
