---
name: yolo
description: Headless / walk-away mode. Two modes — fresh (`/magi:yolo "<description>"`) creates a new sprint and runs the full pipeline; resume (`/magi:yolo --resume`) continues an existing sprint from its current state. Both run plan/tasks/work/review-code/commit phases without user prompts, with conservative auto-decisions and an audit log at YOLO_LOG.md. Aborts and preserves intermediate state on first failure. --push optionally pushes after commit (refused on default branch unless explicitly allowed). Intentionally separate from the normal flow.
disable-model-invocation: true
---

# /magi:yolo — headless full-pipeline runner

You are the coordinator. The user has invoked `/magi:yolo` because they
want the full pipeline executed **without any prompts** — they're walking
away. Run plan → tasks → work → review-code → commit (and optionally
push) in one shot. **Never ask for user input after launch.**

This skill is intentionally separate from the normal workflow. It
violates the "顯式優先" design principle on purpose, scoped to opt-in
use. Decisions that would normally pause for user confirmation are
auto-resolved with the most conservative non-destructive default.

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If config missing → abort with "/magi:setup required".

Confirm we are inside a git repo:

```bash
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }
```

## 0.5. State preflight (auto-refuse)

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["yolo"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["yolo"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["yolo"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:yolo: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

Yolo is refused only in BOOTSTRAP (suggest `/magi:init` first).

## 0.6. Mode determination (fresh vs resume)

Yolo has **two modes**, mutually exclusive, determined by arguments:

| Invocation | Mode | Behavior |
|-----------|------|----------|
| `/magi:yolo "<description>"` | **Fresh** | Create new sprint, run full pipeline plan→...→commit |
| `/magi:yolo --resume [--sprint <slug>]` | **Resume** | Pick up an existing sprint (latest by default, or `--sprint`) from its current state, skipping phases already done |
| `/magi:yolo` (no description, no `--resume`) | error | Print usage hint and abort |
| `/magi:yolo "<desc>" --resume` | error | Mutually exclusive |

For **resume** mode:

- If `--sprint <slug>` not given → use latest sprint (per `detect-state.sh`)
- If no sprint exists at all → error: "no sprint to resume; provide a description for fresh mode"
- Read state JSON; map state to entry phase:

| Entry state | First phase yolo runs | Phases skipped (already done) |
|-------------|----------------------|------------------------------|
| PLANNING | tasks | plan |
| PLAN_REVIEWED | tasks | plan, review-plan (user already did or skipped) |
| TASKS_READY | work | plan, tasks |
| IN_PROGRESS | work (continue undone tasks) | plan, tasks (existing TASKS.md respected) |
| WORK_DONE | review-code | plan, tasks, work |
| CODE_REVIEWED | commit | plan, tasks, work, review-code |

In resume mode, `--type` / `--scale` / `--artifact` / `<description>` are not applicable (the artifact already exists in the sprint).

For **fresh** mode: same args as before (`--type` / `--scale` / `--artifact` overrides allowed; `--sprint <slug>` lets you set the slug name but the folder is still newly created with auto-incremented number).

Record the chosen mode + entry phase in the YOLO_LOG header.

## 0.7. Branch safety check

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
[[ -z "$default_branch" ]] && default_branch=main
on_default=false
[[ "$current_branch" == "$default_branch" ]] && on_default=true
```

Yolo will **commit** on the default branch (no refusal there — that's
just a local commit). But yolo will **refuse to `--push`** when on the
default branch unless `--allow-push-to-default-branch` is also passed.
Loud safety rail against unsupervised force-push to main.

## 1. Initialize YOLO_LOG audit trail

After Step 2 (sprint folder resolution) creates the sprint dir, write
`<sprint_dir>/YOLO_LOG.md` with frontmatter and append progress as the
run unfolds:

```markdown
# YOLO Run — <sprint slug> @ <ISO 8601>

> Invoked: `/magi:yolo "<description>"` <flags>
> Branch: <current_branch>  •  Default branch: <default_branch>
> Status: RUNNING

## Phase log

### plan: <starting...>
```

Update the file at the end of every phase. Final status: `SUCCESS` /
`ABORTED at <phase>`.

## 2. Plan phase

**Skipped in resume mode** (artifact already exists in the sprint).

In fresh mode, apply `/magi:plan` SKILL.md logic, with auto decisions:

1. Read project context (PRD / TECHSTACK / CLAUDE.md / AGENTS.md).
2. Classify type × scale via LLM semantic understanding (multi-language
   input). Honor `--type` / `--scale` / `--artifact` overrides if user
   passed them.
3. Resolve sprint folder (auto-pick next `<num>-<slug>`).
4. **Skip user confirmation** of classification — apply directly.
5. Write the chosen artifact (PLAN.md / SPEC.md / TICKET.md / HOTFIX.md)
   based on the routing matrix.
   - If routing returns "no artifact" (trivial chore/docs/typo): jump
     directly to a degenerate path — invoke `magi-developer` to make
     the edit, run tests, then go to commit phase. Skip tasks /
     review-plan / review-code (since there's no contract).
6. Append to YOLO_LOG: classification result, sprint dir path, artifact
   chosen.

Do **not** call `/magi:review-plan` — it's optional and yolo skips it
to save tokens. Note this in YOLO_LOG.

## 3. Tasks phase

**Skipped if** entry state is TASKS_READY or later in resume mode
(TASKS.md already exists). **Also skipped** for HOTFIX.md or no-artifact
paths (hotfix goes straight to magi-developer with HOTFIX.md as brief;
no-artifact also skips).

Otherwise, apply `/magi:tasks` SKILL.md logic:

1. Read the artifact from §2 (or existing artifact in sprint folder for
   resume mode entering at PLANNING).
2. Decompose into milestones + tasks; mark `🔀` lanes for parallel-safe.
3. Write TASKS.md.
4. **Skip user confirmation** — accept own decomposition.
5. Append to YOLO_LOG: milestone count, task count.

## 4. Work phase

**Skipped if** entry state is WORK_DONE or CODE_REVIEWED in resume
mode (all tasks already done — verify TASKS.md fully checked).

Otherwise, apply `/magi:go` SKILL.md logic, default mode (auto-parallel).
In resume mode entering at IN_PROGRESS, this naturally continues from
the next undone task because /magi:go itself picks "next batch of `- [ ]`
tasks" — no special-casing needed.

1. Read TASKS.md (or HOTFIX.md for hotfix path).
2. Build self-contained briefs for `magi-developer` subagent dispatches.
3. Auto-detect task file scopes; group disjoint tasks for parallel
   dispatch; sequential for the rest.
4. Dispatch one batch at a time. Wait for DONE/BLOCKED.
5. **On any BLOCKED** → abort. Append YOLO_LOG entry:
   `phase: work`, `outcome: aborted`, `reason: <blocker>`,
   `recovery: review WORKS.md and resolve manually; then /magi:go to
   continue, /magi:review-code, /magi:commit`.
6. After all batches DONE, run project test command once. Test failure
   → also abort (regression).
7. Append to YOLO_LOG: tasks done, parallel groups used, test result.

## 5. Review-code phase

**Skipped if** entry state is CODE_REVIEWED in resume mode (DRIFT.md
already exists from a prior `/magi:review-code` run by the user).
Note in YOLO_LOG which DRIFT.md status was inherited.

Otherwise, apply `/magi:review-code` SKILL.md logic in MAGI mode:

1. Capture `git diff` of the sprint's changes.
2. Build reviewer prompt including PLAN/SPEC/TICKET/HOTFIX as contract.
3. Invoke orchestrator + magi-consensus. Wait for all reviewers.
4. Coordinator applies semantic dedup + weighted vote, writes
   MAGI_CODE_REVIEW.md and DRIFT.md (with Status: NONE | DETECTED).
5. **On verdict REQUEST-CHANGES** → abort. Append YOLO_LOG entry with
   the critical issues and recovery suggestion (review the report,
   fix, then `/magi:go` again or `/magi:commit` directly if confident).
6. **On policy_pass=false** (required reviewer failed) → abort.
7. **On verdict APPROVE / APPROVE-WITH-NITS** → continue.
8. Append to YOLO_LOG: verdict, drift status, A/B/C counts.

## 6. Commit phase (no prompts; conservative auto-decisions)

Apply `/magi:commit` SKILL.md sprint-mode logic, but with all user
prompts auto-resolved:

| Decision | Yolo behavior |
|----------|---------------|
| A class drift backfill (per item) | **auto-IGNORE** (kept in DRIFT.md, PLAN/SPEC unchanged — agent does not silently modify the contract under no supervision) |
| C class drift promotion (per item) | **auto-PROMOTE** to `magi/BACKLOG.md` Pending (append-only, safe) |
| Root doc sync detection | **auto-SKIP** (root docs not modified by yolo — touching them needs supervision) |
| Commit message | main agent generates Conventional Commits message from PLAN/SPEC/TICKET title + work summary; not reviewed |

Then:
1. `git add` per-feature scope (sprint dir + code files staged by magi-developer).
2. `git commit -m "<generated>"`.
3. Append to YOLO_LOG: commit SHA, message, drift handling summary.

If trivial / no-artifact path: invoke `/magi:commit` standalone-mode
logic instead — no drift handling, infer commit type from diff, commit.

## 7. Push phase (only with `--push`)

If `--push` was passed:

```bash
if [[ "$on_default" == true && -z "${ALLOW_PUSH_DEFAULT_BRANCH:-}" ]]; then
  echo "Refused: yolo will not push to default branch '$default_branch' without --allow-push-to-default-branch"
  exit 2
fi
git push  # never --force
```

If push is rejected (non-fast-forward or other) → abort with the rejection
message in YOLO_LOG; commit stays local. Never `--force` push.

If `--push` not passed: leave commit local; YOLO_LOG records "pushed: no".

## 8. Final report

Mark YOLO_LOG status as `SUCCESS` (or `ABORTED at <phase>`).

Print to user a one-screen summary:

```
🤖 yolo done — <sprint slug>
  ✅ plan: <type/scale> → <artifact>
  ✅ tasks: <N> milestones, <M> tasks
  ✅ work: <K> tasks DONE; <P> parallel batches; tests <pass>/<total>
  ✅ review-code: APPROVE-WITH-NITS; DRIFT status: DETECTED (A:1 B:0 C:2)
  ✅ commit: <short-sha> "<message>"
  ⏭️  push: not requested (use --push next time, or git push manually)

Audit log: magi/<sprint>/YOLO_LOG.md
```

For aborts:

```
🛑 yolo ABORTED at review-code — verdict REQUEST-CHANGES (3 critical issues)

Recovery:
  1. Read magi/<sprint>/MAGI_CODE_REVIEW.md
  2. Fix critical items via /magi:go
  3. /magi:review-code, /magi:commit

State preserved at: magi/<sprint>/
```

## Argument parsing

Two modes; one of `<description>` or `--resume` is required, mutually
exclusive.

| Arg | Mode | Behavior |
|-----|------|----------|
| (positional) `<description>` | fresh | Free-text feature description; required for fresh mode |
| `--resume` | resume | Continue an existing sprint from its current state |
| `--sprint <slug>` | both | Fresh: use this slug for new folder. Resume: target this specific sprint instead of latest |
| `--push` | both | Push after commit (refused on default branch unless `--allow-push-to-default-branch`) |
| `--allow-push-to-default-branch` | both | Required when pushing while on `main` / `master` |
| `--type <t>` | fresh only | Override dispatcher type classification |
| `--scale <s>` | fresh only | Override dispatcher scale classification |
| `--artifact <a>` | fresh only | Override routing entirely (`plan` / `spec` / `ticket` / `hotfix` / `none`) |
| `--no-test` | both | Skip the post-work test command (use only when project has no tests) |

Errors:
- Neither `<description>` nor `--resume` → print usage and abort
- Both given → print usage (mutually exclusive) and abort
- `--resume` with no sprint folder anywhere → "no sprint to resume; provide a description for fresh mode"
- `--resume --sprint <slug>` where `<slug>` doesn't exist → "sprint not found"
- Fresh-only flags (`--type` / `--scale` / `--artifact`) passed in resume mode → warn and ignore

## Conventions

- **Audit everything**: every auto-decision lands in YOLO_LOG.md. The
  user is walking away — they need a reliable trace to inspect later.
- **Conservative on destructive ops**: A-class drift backfill, root-doc
  sync, force push are the three operations that could damage user
  state under unsupervision. Yolo never does any of them automatically.
- **Abort > recover**: yolo never tries to "be smart" about failure
  recovery (e.g., retrying a BLOCKED task with Opus, auto-fixing review
  findings). Failure → stop, preserve state, log recovery hints.
- **No interactive prompts**: ever. If a phase's underlying skill would
  ask the user something, yolo must have a hard-coded default for that
  decision. New gates added to underlying skills must also be addressed
  here, or yolo will silently behave worse than expected.
- **Same artifacts as normal flow**: PLAN/SPEC/TICKET/HOTFIX, TASKS.md,
  WORKS.md, DRIFT.md, MAGI_CODE_REVIEW.md, BACKLOG.md updates, sprint
  folder layout — all identical to the manual flow. Only difference is
  YOLO_LOG.md and the absence of user confirmation prompts.
