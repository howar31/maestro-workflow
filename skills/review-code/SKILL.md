---
name: review-code
description: Review the current git diff and produce DRIFT.md when a sprint context exists. **Mandatory before /magi:commit in sprint mode** — DRIFT.md is required input for the commit step's drift backfill flow. Default behaviour is multi-CLI MAGI cross-review (orchestrator + magi-consensus). Use --single to fall back to a single Opus reviewer (the magi-reviewer subagent) — saves tokens but loses cross-validation. Supports --magi <mode> override and --reviewers override. Never auto-fixes; always presents findings for the user to decide.
disable-model-invocation: true
---

# /magi:review-code — code review (MAGI by default)

You are the coordinator. Review the current uncommitted change set (or a
specified diff) and produce a structured verdict. Default: multi-CLI MAGI.
Fallback: single-reviewer subagent.

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
blocked=$(jq -r '.disallowed_skills["review-code"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["review-code"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["review-code"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:review-code: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

`--force` skips preflight. The most common refusal: no diff to review
(working tree clean and nothing staged) — make changes first.

## 1. Determine the diff scope

In priority order:

- `--diff <range>` — explicit (e.g. `HEAD~3..HEAD`, `main..HEAD`,
  `<file>...`). Pass through to git.
- `--staged` — review only staged changes.
- (no flag) — review unstaged + staged changes against HEAD.
  - If working tree is clean, fall back to last commit (`HEAD~..HEAD`)
    and warn the user.

Capture the diff:

```bash
git diff $diff_args > "$workdir/changes.diff"
git diff --stat $diff_args > "$workdir/changes.stat"
```

Show the user `git diff --stat` first so they confirm scope before tokens
get spent.

## 2. Branch on review mode

### 2a. Single-reviewer mode (`--single`)

Dispatch the `magi-reviewer` subagent. Build a brief:

```markdown
You are dispatched to review this change set.

## Repo
<path>, branch <branch>, target <upstream-branch>

## Diff
<paste of changes.diff or --reference if too large>

## Files to read in full
- <path>
- <path>

## Project context
- TECHSTACK.md: <verbatim or summary>
- Conventions: CLAUDE.md / AGENTS.md (root)

## Sprint contract (if a sprint context exists)
<verbatim PLAN.md and/or SPEC.md from magi/<num>-<slug>/>

## Acceptance criteria (if applicable)
<from current sprint's SPEC.md if exists>

## Output protocol
Follow your standard structure: Verdict + 🔴 / 🟡 / 🟢 sections.
If a sprint contract was provided above, additionally output a
`## Drift from contract` section with A / B / C classes per your agent
spec.
```

Use Task tool with `subagent_type: magi:reviewer` (or `--model` override).

### 2b. Multi-CLI MAGI mode (default)

Build a reviewer prompt at `<workdir>/review-prompt.md`:

```
You are reviewing a software change. Apply skepticism and domain expertise.

## Repo context
<branch info, target branch, recent commits>

## Diff
<paste of changes.diff>

## Files in scope (full content for context)
<paste each touched file's relevant region(s)>

## Project conventions
<from CLAUDE.md / AGENTS.md / TECHSTACK.md>

## Sprint contract (if a sprint context exists)
<verbatim PLAN.md and/or SPEC.md from magi/<num>-<slug>/>

## Acceptance criteria
<from sprint SPEC.md if applicable>

## Your task
Identify concerns. For each, output:

  ## Issue: <short subject>
  Severity: Critical | Important | Note
  Where: <file:line>
  Description: <2–6 sentences>
  Suggested fix: <1–3 sentences>

End with:

  ## Verdict
  APPROVE | APPROVE-WITH-NITS | REQUEST-CHANGES
  <one paragraph>

If a sprint contract was provided above, additionally output a
`## Drift from contract` section classifying any deviations:

  ## Drift from contract

  ### A. Contract violations
  - <subject> — files: <paths>
    What the contract says vs. what the code does.
    Proposed PLAN/SPEC update: <one sentence>.
  (or "(none)" if no contract violations)

  ### B. Below-the-contract decisions
  - <description>
  (or "(none)")

  ### C. Out-of-scope observations
  - <description>
  (or "(none)")

A = code does something the contract did not authorize or contradicts.
B = code chose freely where the contract was silent.
C = new concerns that surfaced during implementation, not in the contract.

Do not edit files.
```

Invoke orchestrator:

```bash
WORKDIR=$(mktemp -d -t magi-review.XXXXXX)
MAGI_REVIEW_WORKDIR="$WORKDIR" \
  "$PLUGIN_ROOT/skills/review-plan/scripts/orchestrator.sh" \
  "$workdir/review-prompt.md" \
  $reviewer_args
```

Stream events to user. Then run consensus:

```bash
"$PLUGIN_ROOT/scripts/shared/magi-consensus.sh" "$WORKDIR" \
  ${magi_override:+--mode "$magi_override"}
```

Apply MAGI rules per `references/MAGI_VOTING.md` (semantic dedup +
weighted voting). Same procedure as `/magi:review-plan` step 6.

If `policy_pass=false`:

- Required reviewer failed → abort, surface cause.
- Optional reviewers failed → continue in degraded mode with explicit warning.

If unanimous mode + degraded → abort per MAGI_VOTING.md.

## 3. Write the consolidated review

Write to `<sprint_dir>/MAGI_CODE_REVIEW.md` (or fallback to project root if
no current sprint). Use `output_language`:

```markdown
# 🧠 MAGI Code Review — <branch> @ <short-sha>

**Diff scope:** <range>
**Mode:** <mode>  •  **OK weight:** <ok_weight> / <total>
**Threshold:** <threshold>  •  **Degraded:** yes | no

## Verdict
APPROVE | APPROVE-WITH-NITS | REQUEST-CHANGES

## 🔴 Critical (adopted)
...

## 🟡 Important (adopted)
...

## 🟢 Minority
...

## Untested paths
- <path/function> — flagged by <reviewer(s)>

## ⚠️ Degraded mode (if applicable)
<short explanation>
```

For `--single` mode the file is `<sprint_dir>/SINGLE_CODE_REVIEW.md` and
omits the MAGI-specific sections (mode/weights/etc.).

Summarise top concerns in chat: 3 most critical issues + verdict.

## 3.5. Write DRIFT.md (when a sprint context exists)

If a sprint folder was identified and the reviewer prompt included a sprint
contract, **always** write `<sprint_dir>/DRIFT.md` regardless of whether
deviations were found. The file's existence signals "review was run"; the
`Status` field signals "was there drift?".

Apply MAGI semantic dedup + voting to the `## Drift from contract`
sections of every successful reviewer (same procedure as code-review issues).
Only adopt items that meet the configured threshold; below-threshold drift
items are dropped (avoid single-reviewer over-flagging).

For `--single` mode, take the `## Drift from contract` section verbatim
from the reviewer's output; no voting needed.

Schema:

```markdown
# Drift — <feature>
> Source: magi-report.md (or single reviewer)  •  Generated: <ISO 8601>  •  Status: NONE | DETECTED

## A. Contract violations
(none)
<or>
- [ ] <description> — files: `<paths>`
  Proposed PLAN/SPEC update: <one sentence>

## B. Below-the-contract decisions
(none)
<or>
- [ ] <description>

## C. Out-of-scope observations
(none)
<or>
- [ ] <description>
```

`Status: NONE` when all three sections are `(none)`. `Status: DETECTED`
otherwise. The status field is the canonical signal `/magi:commit` reads.

DRIFT.md is overwritten on every `/magi:review-code` run (current-state
semantics). Historical record stays in WORKS.md.

## 4. Hand-off

If verdict = APPROVE: tell user it's safe to commit. Recommend
`/magi:commit` (sprint mode if DRIFT.md was produced — it will pick up
DRIFT.md automatically).

If verdict = APPROVE-WITH-NITS: list nits and ask user whether to address
before commit (or note they can defer). Then `/magi:commit`.

If verdict = REQUEST-CHANGES: enumerate critical issues and recommend
`/magi:go --task <id>` (or manual edit) to address. Do not commit.

If DRIFT.md status = DETECTED, also tell the user the count of A / B / C
items so they know what `/magi:commit` will prompt them to handle.

**Never commit, never push, never auto-fix.** The user is the gate.

## Argument parsing

- `--single` — use single-reviewer subagent (Opus by default; saves tokens).
- `--magi <mode>` — override MAGI mode for this run (`majority` /
  `supermajority` / `unanimous` / `threshold:<N>`).
- `--reviewers <list>` — override the reviewer roster (e.g.
  `--reviewers claude:opus,gemini:pro` to skip codex).
- `--diff <range>` — explicit diff range.
- `--staged` — only review staged changes.
- `--model <name>` — override the single-reviewer model (only with
  `--single`).
- `--workdir <path>` — reuse an orchestrator workdir (skip fan-out).

## Conventions

- The diff is the source of truth for what to review. Do not review code
  that is not in the diff (out-of-scope observations are allowed in
  `🟢 Note` only).
- For renamed files, read both old and new content.
- Always read `references/MAGI_VOTING.md` before classifying in MAGI mode.
- Be conservative in semantic dedup; preserve minority concerns.
- If the diff is huge (> ~2000 lines): warn the user and offer to split by
  file or by commit before spending tokens.
