---
name: maestro.review-code
description: Review the current git diff. Default behaviour is multi-CLI MAGI cross-review (orchestrator + magi-consensus). Use --single to fall back to a single Opus reviewer (the maestro-reviewer subagent) — saves tokens but loses cross-validation. Supports --magi <mode> override and --reviewers override. Never auto-fixes; always presents findings for the user to decide.
disable-model-invocation: true
---

# /maestro.review-code — code review (MAGI by default)

You are the coordinator. Review the current uncommitted change set (or a
specified diff) and produce a structured verdict. Default: multi-CLI MAGI.
Fallback: single-reviewer subagent.

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/maestro-workflow/config.json"
```

If config missing → tell user to run `/maestro.setup`.

Confirm we are inside a git repo:

```bash
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }
```

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

Dispatch the `maestro-reviewer` subagent. Build a brief:

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

## Acceptance criteria (if applicable)
<from current sprint's SPEC.md if exists>

## Output protocol
Follow your standard structure: Verdict + 🔴 / 🟡 / 🟢 sections.
```

Use Task tool with `subagent_type: maestro-reviewer` (or `--model` override).

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

Do not edit files.
```

Invoke orchestrator:

```bash
WORKDIR=$(mktemp -d -t maestro-review.XXXXXX)
MAESTRO_REVIEW_WORKDIR="$WORKDIR" \
  "$PLUGIN_ROOT/skills/maestro.review-plan/scripts/orchestrator.sh" \
  "$workdir/review-prompt.md" \
  $reviewer_args
```

Stream events to user. Then run consensus:

```bash
"$PLUGIN_ROOT/scripts/shared/magi-consensus.sh" "$WORKDIR" \
  ${magi_override:+--mode "$magi_override"}
```

Apply MAGI rules per `references/MAGI_VOTING.md` (semantic dedup +
weighted voting). Same procedure as `/maestro.review-plan` step 6.

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

## 4. Hand-off

If verdict = APPROVE: tell user it's safe to commit.

If verdict = APPROVE-WITH-NITS: list nits and ask user whether to address
before commit (or note they can defer).

If verdict = REQUEST-CHANGES: enumerate critical issues and recommend
`/maestro.work --task <id>` (or manual edit) to address. Do not commit.

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
