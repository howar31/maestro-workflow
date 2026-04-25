---
name: magi.commit
description: Commit the current change set with optional drift backfill (sprint mode) or as a generic Conventional Commits commit (standalone mode). Auto-detects which mode based on sprint context. Optionally syncs root docs (CLAUDE/README/SPEC) when project-level changes are detected. Never commits without user confirmation.
disable-model-invocation: true
---

# /magi.commit — sprint-aware commit (dual-mode)

You are the coordinator. Stage the change set, optionally backfill drift
into PLAN/SPEC, optionally sync root docs, generate a Conventional Commits
message, then ask the user to confirm. **Never commit without explicit
confirmation.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow-workflow/config.json"
```

If config missing → tell user to run `/magi.setup`.

Confirm we are inside a git repo:

```bash
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }
```

## 0.5. State preflight (auto-refuse if not allowed)

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["magi.commit"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["magi.commit"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["magi.commit"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi.commit: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

After preflight passes, surface the `stale_drift` warning if present —
warn the user that the DRIFT.md is older than current code changes;
recommend re-running `/magi.review-code` first or pass `--skip-review` to
proceed anyway.

`--force` skips preflight (advanced/recovery only).

## 1. Mode selection (preflight)

Decide between **Sprint mode** and **Standalone mode** by inspecting:

```bash
# Find the most recent sprint folder
sprint_dir=$(ls -d docs/[0-9]*-*/ 2>/dev/null | sort -r | head -1)
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
| sprint folder exists but no DRIFT.md | warn the user: "DRIFT.md not found in `<sprint_dir>/` — recommend `/magi.review-code` first. Add `--skip-review` to bypass."; **abort** unless `--skip-review` provided |
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
      - `y` → append to `docs/BACKLOG.md` under `## Pending` (create file if
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

5. Proceed to **§3 Root doc sync detection**.

### 2b. Standalone mode

Standalone mode covers commits outside the sprint flow (chore / docs / small
fix / small refactor / commits in projects that don't use magi-workflow at
all). It is intentionally a thin wrapper around the same root-sync detection
+ Conventional Commits message generation that Sprint mode uses.

1. Skip drift handling entirely (no sprint context → no contract to check).
2. Proceed to **§3 Root doc sync detection**.

## 3. Root doc sync detection (shared by both modes)

Apply the **Level 2 (aggressive) heuristic** unless `--root-sync-strict` is
set (which downgrades to Level 1) or `--no-root-sync` is set (skips entirely).

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
- **Never auto-create** root files that don't exist. Bootstrap is `/magi.init`'s
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

If the user invoked `/magi.commit push` (positional `push` argument), run
`git push` immediately and report the result.

Otherwise, ask: `Push to remote? (y/n)`. Do not push without explicit
confirmation.

**Never force-push.** If push is rejected (non-fast-forward), surface the
error and let the user decide.

## 8. Sprint hand-off (sprint mode only)

After a successful commit:

- If C items were upgraded to backlog in §2a-b, remind the user:
  > N item(s) added to `docs/BACKLOG.md`. Run `/magi.plan` (no args) to
  > pick one as your next sprint, or `/magi.plan "<new feature>"` to plan
  > something else.

- If the sprint has remaining unchecked tasks in TASKS.md, suggest
  `/magi.go` for the next batch.

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
- `--no-root-sync` — skip §3 entirely.
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
- **Never auto-create** root files. `/magi.init` owns bootstrap.
- **Never commit on hooks failure.** If a pre-commit hook fails, surface the
  error and let the user fix; do not retry with `--no-verify`.
- **Concept reused from the user's private `/commit` skill** (when present
  on the user's machine): three-file role definitions, single-commit
  philosophy, Conventional Commits. The implementation is independent;
  magi-workflow does not depend on that skill being installed.
