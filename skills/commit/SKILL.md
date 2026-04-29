---
name: commit
description: Commit the current change set with optional drift backfill (sprint mode) or as a generic Conventional Commits commit (standalone mode). Auto-detects which mode based on sprint context. Sprint mode verifies declared spec deltas (PLAN.md / SPEC.md `## Spec deltas`) against the actual diff before staging; missing or undeclared root-doc changes are surfaced interactively (lenient default; `--strict-deltas` makes them blocking). Falls back to Level 1/2 heuristics when no deltas are declared. Never commits without user confirmation.
disable-model-invocation: true
---

# /magi:commit — sprint-aware commit (dual-mode)

You are the coordinator. Stage the change set, optionally backfill drift
into PLAN/SPEC, optionally sync root docs, generate a Conventional Commits
message, then ask the user to confirm. **Never commit without explicit
confirmation.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If config missing → tell user to run `/magi:setup`.

Confirm we are inside a git repo:

```bash
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }
```

## 0.5. State preflight (auto-refuse if not allowed)

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["commit"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["commit"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["commit"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:commit: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

After preflight passes, surface the `stale_drift` warning if present —
warn the user that the DRIFT.md is older than current code changes;
recommend re-running `/magi:review-code` first or pass `--skip-review` to
proceed anyway.

`--force` skips preflight (advanced/recovery only).

## 1. Mode selection (preflight)

Decide between **Sprint mode** and **Standalone mode** by inspecting:

```bash
# Find the most recent sprint folder
sprint_dir=$(ls -d magi/[0-9]*-*/ 2>/dev/null | sort -r | head -1)
[[ -n "$sprint_dir" ]] && sprint_dir="${sprint_dir%/}"

# Capture changed files
changed_files=$(git diff --name-only HEAD; git diff --staged --name-only)
```

Apply rules:

| Condition | Mode |
|-----------|------|
| `--mode sprint` flag | force Sprint mode |
| `--mode standalone` flag | force Standalone mode |
| `--sprint <num>-<slug>` flag | force Sprint mode against that sprint |
| sprint folder exists + `<sprint_dir>/DRIFT.md` exists | **Sprint mode** |
| sprint folder exists but no DRIFT.md | warn the user: "DRIFT.md not found in `<sprint_dir>/` — recommend `/magi:review-code` first. Add `--skip-review` to bypass."; **abort** unless `--skip-review` provided |
| no sprint folder anywhere | **Standalone mode** |
| sprint folder exists but `changed_files` are all outside it (e.g., `.github/workflows/*` or root files only) | ask user: "Sprint `<sprint_dir>` exists but your changes don't touch it. Use Sprint mode anyway, or Standalone?" |

Tell the user the chosen mode before proceeding.

## 2. Branch on mode

### 2a. Sprint mode

1. Read `<sprint_dir>/DRIFT.md`. Parse the `Status:` field from the header.

2. **If `Status: NONE`** → skip step 3 entirely. Tell user "no drift, will
   commit as-is."

3. **If `Status: DETECTED`**:

   a. **A class — contract violations**: for each `## A.` item, show it to
      the user and ask `(y回填 / n忽略 / e編輯)`:
      - `y` → edit the per-feature `PLAN.md` or `SPEC.md` inline to incorporate
        the proposed update. Preserve existing structure; append to the
        relevant section. Make the edit minimal and targeted.
      - `e` → ask user for the edit they want, apply that.
      - `n` → leave the item in DRIFT.md (will be overwritten on next review).
      Do not auto-resolve; every A item needs an explicit user decision.

   b. **C class — out-of-scope observations**: for each `## C.` item, ask
      `(y升級到 backlog / n忽略)`:
      - `y` → append to `magi/BACKLOG.md` under `## Pending` (create file if
        missing) with this format:
        ```markdown
        - [ ] <description>
          > from `<sprint_dir>/DRIFT.md` (<YYYY-MM-DD>)
        ```
      - `n` → leave as-is; will reappear on next review unless the
        underlying concern goes away.

   c. **B class — below-the-contract decisions**: do not prompt the user.
      These stay in DRIFT.md as an audit trail of "what the developer
      decided when the contract was silent." They are not actionable at
      commit time.

4. **If `--skip-review` was used** (user bypassing the missing-DRIFT.md
   warning): skip 3a/b/c entirely; record one line in the commit message
   body: `Note: committed with --skip-review; no drift report consulted.`

5. Proceed to **§2.5 Delta verification**.

### 2b. Standalone mode

Standalone mode covers commits outside the sprint flow (chore / docs / small
fix / small refactor / commits in projects that don't use magi-workflow at
all). It is intentionally a thin wrapper around the same root-sync detection
+ Conventional Commits message generation that Sprint mode uses.

1. Skip drift handling entirely (no sprint context → no contract to check).
2. Skip §2.5 Delta verification (no sprint contract → no deltas declared).
3. Proceed to **§3 Root doc sync detection**.

## 2.5. Delta verification (sprint mode only)

Before §3 (root-sync heuristic), reconcile the sprint's **declared spec
deltas** against the **actual diff**. This converts root-doc sync from
heuristic detection into contract verification: the plan announced what
project-level docs would change; we now check reality.

Skip §2.5 entirely when any of these hold:
- `--no-root-sync` was passed (the user opted out of all root-doc gating)
- The sprint contract artifact is `TICKET.md` or `HOTFIX.md` (these do
  not contain `## Spec deltas`; rely on §3 Level 1 only)
- No PLAN.md / SPEC.md exists in the sprint folder (already in 2a, but
  guard explicitly here)
- `--skip-review` was passed (user already bypassed the contract gate)

Otherwise:

### 2.5.1. Parse declared deltas

```bash
contract=""
for f in "$sprint_dir/PLAN.md" "$sprint_dir/SPEC.md"; do
  [[ -f "$f" ]] && contract="$f" && break
done
```

If `contract` is empty (only TICKET.md / HOTFIX.md present), skip §2.5.

Read `contract` and locate the `## Spec deltas` section. For each of the
four fixed subheadings (`### root \`SPEC.md\``, `### root \`CLAUDE.md\``,
`### magi/\`PRD.md\``, `### magi/\`TECHSTACK.md\``), record whether the
subsection body is the literal string `(none)` or contains at least one
bullet starting with `- **Section:`.

Build `declared_set` = set of file paths whose subsection has at least
one bullet:

| Subheading | File path |
|------------|-----------|
| `### root \`SPEC.md\`` | `SPEC.md` |
| `### root \`CLAUDE.md\`` | `CLAUDE.md` |
| `### magi/\`PRD.md\`` | `magi/PRD.md` |
| `### magi/\`TECHSTACK.md\`` | `magi/TECHSTACK.md` |

If the `## Spec deltas` section is **missing entirely** from a PLAN.md /
SPEC.md, warn the user once: "Sprint contract has no `## Spec deltas`
section — your `/magi:plan` may pre-date this feature. Treating
`declared_set` as empty; deltas verification will run in detection mode."
Then continue with `declared_set = ∅`.

### 2.5.2. Compute actual_set

```bash
actual_set=$(git diff --name-only HEAD -- \
  SPEC.md CLAUDE.md magi/PRD.md magi/TECHSTACK.md 2>/dev/null)
```

Empty set is fine (the sprint genuinely modified nothing at this tier).

### 2.5.3. Classify

| Class | Definition | Default action |
|-------|-----------|----------------|
| **D1 — Declared but missing** | `declared_set ∖ actual_set` | Per-item prompt; assume "you forgot to update" |
| **D2 — Modified but undeclared** | `actual_set ∖ declared_set` | Per-item prompt; assume "you should backfill the deltas, or this was unintended" |
| **D3 — Match** | `declared_set ∩ actual_set` | Silent pass |

If `D1 ∪ D2 == ∅` → set `deltas_verified=1` and proceed to §3. Tell the
user "Spec deltas verified."

### 2.5.4. Lenient mode (default)

For each D1 item, prompt:
```
[deltas D1] Declared but not modified: <file>
  Section(s) declared: <bulleted list of "Section: <name>" headings>
  (y backfill / n proceed-anyway / e edit declaration)
```
- `y` → open `<file>` and let user make the modification; re-diff after
- `n` → record `Note: D1 unresolved for <file>` in commit body; proceed
- `e` → let user edit the deltas section in PLAN.md / SPEC.md to remove
  the obsolete declaration; re-parse §2.5.1 and re-classify

For each D2 item, prompt:
```
[deltas D2] Modified but not declared: <file>
  (y backfill declaration / n proceed-anyway / e revert change)
```
- `y` → open the contract (`PLAN.md` or `SPEC.md`) `## Spec deltas`
  section and append a bullet under the appropriate subheading; re-parse
  §2.5.1 and re-classify
- `n` → record `Note: D2 unresolved for <file>` in commit body; proceed
- `e` → user reverts the file change; re-diff and re-classify

When all D1/D2 items are resolved (or user said `n` to each), set
`deltas_verified=1` and proceed to §3.

### 2.5.5. Strict mode (`--strict-deltas`)

If `--strict-deltas` was passed and `D1 ∪ D2 ≠ ∅`:

```
[deltas] strict mode: <N> declared-but-missing, <M> modified-but-undeclared
  Re-run /magi:commit without --strict-deltas to handle interactively,
  or update PLAN.md / SPEC.md ## Spec deltas to match the diff first.
```

Exit non-zero. Do not stage, do not commit.

`--strict-deltas` is incompatible with `--no-root-sync` (they contradict).
If both set, abort with usage error.

## 3. Root doc sync detection (shared by both modes)

Apply the **Level 2 (aggressive) heuristic** unless one of the following
downgrades it:
- `--root-sync-strict` → Level 1 only
- `--no-root-sync` → skip §3 entirely
- `deltas_verified=1` from §2.5 → Level 1 only (deltas already gave a
  more reliable signal for project-level docs; Level 2's keyword scan
  and contradiction analysis would just duplicate that signal)

Level 1 always runs (when not `--no-root-sync`) because it covers
infrastructure signals (`package.json` deps, `Dockerfile`, `Makefile`)
that the deltas section does not — deltas only declares modifications to
the four project-level living docs.

### 3.1. Detect "this change might affect root docs"

Triggers:

**Top-level signals (Level 1, always checked):**
- New file at repo root (excluding hidden / lock files)
- `package.json` `"scripts"` added or renamed
- Dependency change in `package.json` / `pyproject.toml` / `go.mod` /
  `Cargo.toml` / `Gemfile`
- `Dockerfile` / `docker-compose.yml` / `Makefile` modified

**Sprint-context signals (Level 2 only, requires sprint mode):**
- PLAN.md or SPEC.md (sprint scope) contains keywords
  (case-insensitive whole-word match): `architecture`, `breaking change`,
  `new service`, `migration`, `deprecate`
- Per-feature SPEC.md contradicts root SPEC.md (i.e., the per-feature spec
  describes architecture that is missing or different in root SPEC.md)

**Level 2 is skipped when `deltas_verified=1`** (set by §2.5). The
declared deltas already covered every project-level doc that needs
updating; running keyword/contradiction heuristics would only duplicate
or muddle that signal.

Aggregate the triggered signals into a list of reasons.

### 3.2. Prompt the user

If at least one trigger fires:

```
Root docs may need updating. Triggers detected:
  - <reason 1>
  - <reason 2>
  ...

Update existing root docs (CLAUDE.md, README.md, SPEC.md, etc.) to reflect
this change? (y/n)
```

If `y`:
- For each **existing** root doc, read it and update it to reflect the
  feature changes. Preserve each file's existing structure and tone.
- For the standard three filenames, treat them with their established roles:
  - `CLAUDE.md` = index for AI agents (commands, architecture pointers,
    conventions). Keep concise — details belong in SPEC.md.
  - `README.md` = human-readable project description and command list.
  - `SPEC.md` = AI-readable architecture & feature spec.
- For other root `.md` files (e.g., `ARCHITECTURE.md`), update in their own
  style without imposing a structure.
- **Never auto-create** root files that don't exist. Bootstrap is `/magi:init`'s
  responsibility.

If `n`: skip root updates; proceed.

If no trigger fires, skip this step silently.

## 4. Stage

```bash
# Stage the per-feature changes (and any root-doc updates from §3)
git add -- <changed files>
```

If sprint mode and the sprint folder has uncommitted PLAN/SPEC edits from
§2a (drift backfill), include those in the stage.

Show `git diff --staged --stat` to the user so they see exactly what is
about to be committed.

## 5. Compose the commit message

Generate a Conventional Commits message:

```
<type>(<scope>): <subject>

<body — optional, 2–5 lines explaining why>

<footer — optional>
```

Pick `<type>` from: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
`test`, `chore`, `ci`, `build`, `revert`. Use `!` after type for breaking
changes (`feat!:`).

**Sprint mode**: derive `<type>` and `<subject>` from the sprint's PLAN/SPEC
title; use `<scope>` from the sprint slug if useful. Body summarizes the
work, citing milestone(s) completed and DRIFT.md status. If A items were
backfilled, list them tersely in the body.

**Standalone mode**: infer `<type>` from the diff (e.g., README change →
`docs:`, dependency bump → `chore:`, code-only fix → `fix:`); subject is one
clear sentence. Body optional — keep it short.

For `--skip-review`, append the warning to the body.

## 6. Show, confirm, commit

```
About to commit:

  <staged diff stat>

Message:
  <type>(<scope>): <subject>

  <body>

OK to commit? (y/n/edit)
```

- `y` → run `git commit -m "$msg"` (use heredoc to preserve formatting).
- `edit` → let user revise the message; show again; loop.
- `n` → abort; tell user nothing was committed.

After commit, run `git log -1 --stat` to confirm.

## 7. Optional push

If the user invoked `/magi:commit push` (positional `push` argument), run
`git push` immediately and report the result.

Otherwise, ask: `Push to remote? (y/n)`. Do not push without explicit
confirmation.

**Never force-push.** If push is rejected (non-fast-forward), surface the
error and let the user decide.

## 8. Sprint hand-off (sprint mode only)

After a successful commit:

- If C items were upgraded to backlog in §2a-b, remind the user:
  > N item(s) added to `magi/BACKLOG.md`. Run `/magi:plan` (no args) to
  > pick one as your next sprint, or `/magi:plan "<new feature>"` to plan
  > something else.

- If the sprint has remaining unchecked tasks in TASKS.md, suggest
  `/magi:go` for the next batch.

- If TASKS.md is fully checked, suggest the sprint is complete; user can
  open a new sprint.

## Argument parsing

Positional:
- `push` — commit then immediately push (mirror `/commit push` UX).

Flags:
- `--mode sprint|standalone` — force mode (default: auto-detect).
- `--sprint <num>-<slug>` — explicit sprint folder (implies `--mode sprint`).
- `--skip-review` — sprint mode only: bypass missing DRIFT.md (records a
  warning in the commit body).
- `--no-root-sync` — skip both §2.5 (delta verification) and §3 entirely.
- `--strict-deltas` — sprint mode only: §2.5 D1/D2 → exit non-zero
  instead of interactive prompt. Incompatible with `--no-root-sync`.
- `--root-sync-strict` — use Level 1 heuristic only (no PLAN/SPEC keyword
  scan, no contradiction analysis).
- `--message <msg>` / `-m <msg>` — pre-supply the commit message; skip the
  generation step.

## Conventions

- **Single commit per invocation.** Code + per-feature docs + root docs (if
  approved in §3) all land in one commit. Never split.
- **Conventional Commits** for the message. Footer can include `Co-Authored-By`
  if the user has configured it elsewhere; this skill does not add one
  by default.
- **Never modify** files outside the user-staged scope without explicit
  consent (drift backfill in §2a, root sync in §3 are both gated by user
  prompts).
- **Never auto-create** root files. `/magi:init` owns bootstrap.
- **Never commit on hooks failure.** If a pre-commit hook fails, surface the
  error and let the user fix; do not retry with `--no-verify`.
- **Concept reused from the user's private `/commit` skill** (when present
  on the user's machine): three-file role definitions, single-commit
  philosophy, Conventional Commits. The implementation is independent;
  magi-workflow does not depend on that skill being installed.
