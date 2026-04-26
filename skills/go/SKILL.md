---
name: go
description: Execute the next undone task(s) from a sprint's TASKS.md by dispatching the magi-developer subagent (Sonnet by default). Updates WORKS.md as a development log. Pauses for user confirmation before any commit. Default behavior auto-parallelizes tasks with disjoint file scopes; --parallel forces parallel, --sequential forces serial. Supports --model, --task, --milestone for fine-grained control.
disable-model-invocation: true
---

# /magi:go — execute tasks via subagent

You are the coordinator. Read TASKS.md, dispatch `magi-developer` to do
the work, collect results, update WORKS.md, and stop. **You do not write
production code yourself.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If config missing → tell user to run `/magi:setup`.

## 0.5. State preflight (auto-refuse if not allowed)

Run `scripts/shared/detect-state.sh` and check `disallowed_skills["go"]`.
If present, surface reason + suggest in user's language and abort.

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["go"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["go"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["go"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:go: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
hotfix=$(jq -r '.hotfix_mode' <<<"$STATE_JSON")
```

`--force` skips preflight (advanced/recovery only).

If `hotfix=true`, the sprint has a HOTFIX.md and no TASKS.md is required.
Build a single-task brief from HOTFIX.md (Repro / Root cause / Fix /
Test) and dispatch directly — skip §1's TASKS.md scanning.

## 1. Locate sprint + task selection

Find the sprint folder (most recent or `--sprint <num>-<slug>`).

Read `TASKS.md`. Determine the next batch of work:

- Default: pick the next milestone with at least one `- [ ]` task. Within
  that milestone, all sequential `- [ ]` tasks become this batch.
- `--milestone N` — execute milestone N specifically.
- `--task T1.2` — execute exactly that task ID.
- `--parallel` — if the chosen milestone has `🔀` lanes, dispatch one
  developer per lane in parallel. Without this flag, lanes are executed
  sequentially.

If nothing is left to do, tell the user the sprint is complete and suggest
`/magi:review-code`.

## 2. Read context

For each task to dispatch, gather context the developer will need:

- The full **PLAN.md** or **SPEC.md** for this sprint (verbatim).
- The **task lines** from TASKS.md (the milestone heading + the chosen
  tasks).
- **File ranges** the task touches — list them and `Read` each in full to
  confirm they exist.
- **Interface contracts** (function signatures, type definitions, API
  shapes) extracted from PLAN/SPEC or existing code.
- **Project conventions** from CLAUDE.md, AGENTS.md, TECHSTACK.md.
- **Test framework** — discover from package.json / pyproject.toml /
  Cargo.toml / go.mod / etc. State the exact `<test command>` to run.
- **E2E recipe** — if PLAN/SPEC mentions one, copy its exact path and
  command.

If anything is genuinely unclear (TECHSTACK silent, no PLAN, etc.) ask the
user **once** before dispatching. Don't over-ask.

## 3. Build the developer brief

Construct a self-contained brief. The subagent will not be able to come
back for clarification — give it everything up front:

```markdown
You are dispatched to execute the following task(s) in this repo.

## Sprint
magi/<num>-<slug>/

## Task(s)
- Task ID: T1.2
  Description: <verbatim from TASKS.md>
- (more if a batch)

## Context

### From PLAN.md / SPEC.md
<verbatim relevant sections>

### Interface contracts
<function signatures, types, schemas>

### Files in scope
- <path>:<line-range or full> — <one-line note>

### Project conventions
- Language: <e.g., TypeScript 5, ESM>
- Test framework: <vitest | jest | pytest | ...>
- Test command: <exact shell command>
- Linter: <eslint | ruff | ...>
- Naming: kebab-case files, camelCase functions, ...

### How you know you are done
- All tests pass: `<test command>`
- E2E recipe (if applicable): `<command>`
- Acceptance criteria from SPEC.md:
  - <bullet>
  - <bullet>

## Output protocol
End with DONE: <summary> or BLOCKED: <reason>, per agent system prompt.
```

## 4. Dispatch

Use the Task tool with `subagent_type: magi:developer` (or whatever
override the user passed via `--model`).

### 4a. Choose dispatch mode (auto-parallel by default)

Default behavior is **auto-parallel**: analyze the batch and dispatch in
parallel any tasks whose file scopes are demonstrably disjoint. Otherwise
fall back to sequential. Flags can override:

- `--parallel` → force parallel for the entire batch (trusts the user that
  there are no hidden conflicts)
- `--sequential` → force sequential (debug mode, simplest semantics)
- (no flag) → auto: collect each task's "files in scope" from PLAN/SPEC
  and the task description; group tasks with disjoint file sets into
  parallel batches; tasks with any overlap or unclear scope run
  sequentially. Tasks marked `🔀` in TASKS.md are a strong hint —
  always-safe-to-parallelize as the author asserted.

When in doubt, prefer sequential. False positives on parallelism cost
hours of debugging; false negatives only cost wall-clock time.

### 4b. Sequential dispatch (default for tasks with overlapping/unclear scope or `--sequential`)

Dispatch one task. Wait for DONE/BLOCKED. Decide whether to continue:

- DONE → continue to next task in batch.
- BLOCKED → stop the batch, report to user, ask how to proceed.

### 4c. Parallel dispatch (auto-detected disjoint sets, all `🔀` lanes, or `--parallel`)

Dispatch all parallel-safe tasks in a single message (multiple Task tool
uses). Wait for all to return. Aggregate results.

Lanes must touch **disjoint files**. Do not dispatch parallel lanes that
contend on the same file. If auto-detection chose parallel but a runtime
collision shows up (e.g., the same module appears in two diffs unexpectedly),
abort and ask the user to re-decompose.

## 5. After each task / batch

Run the project test command **once** to confirm nothing else broke.
If tests fail and the developer reported DONE, that is a regression — go
back to the user with the failure, do not silently fix.

## 6. Update WORKS.md

Append a journal entry for the work just completed:

```markdown
## <ISO date> — <short summary>
**Tasks:** T1.2, T1.3
**Verdict:** DONE | BLOCKED | partial (T1.2 DONE, T1.3 BLOCKED)
**Test result:** <pass>/<total>; e2e: <pass | n/a>
**Files touched:** path1, path2
**Decisions made by developer:**
- <e.g. chose option A for the test harness because no framework existed>
**Out-of-scope observations to follow up:**
- <verbatim from developer note>
```

WORKS.md is the auditable history of how the sprint actually unfolded — it
captures decisions and observations that PLAN/SPEC/TASKS would not preserve.

## 7. Stop and hand off

Tell the user, in their `output_language`:

- What got done (link/cite tasks).
- What test status looks like.
- Recommended next step:

| Outcome | Recommended next |
|---------|------------------|
| Some tasks remain in this milestone | `/magi:go` again (or auto-continue if user says so) |
| Milestone done, more milestones remain | `/magi:go` (next milestone) |
| All tasks done — sprint implementation complete | **`/magi:review-code` (mandatory — produces DRIFT.md required by `/magi:commit`)** |
| BLOCKED | resolve the blocker; consider `/magi:plan --into <sprint>` to revise contract |

Always mark `/magi:review-code` as **mandatory** in the hand-off message —
it's not an optional review like `/magi:review-plan`; it produces
`DRIFT.md` which `/magi:commit` requires.

**Never commit on the user's behalf.** Wait for explicit instruction.

## Argument parsing

- `--model <name>` — override the developer subagent model (e.g., bump to
  Opus for one specific complex task).
- `--milestone N` — work on a specific milestone.
- `--task T<m>.<n>` — work on a specific task (overrides milestone).
- `--parallel` — force parallel dispatch for the entire batch (overrides
  auto-detection; trusts user there are no conflicts).
- `--sequential` — force sequential dispatch for the entire batch (debug
  mode; overrides auto-detection).
- `--sprint <num>-<slug>` — target a specific sprint folder.
- `--force` — skip §0.5 state preflight (advanced/recovery only).

## Conventions

- **Sonnet for routine, Opus for thorny.** Default is Sonnet (fast, cheap).
  If a task involves complex algorithm design, multi-module refactor, or
  the developer reports BLOCKED on first dispatch citing complexity,
  consider re-dispatching with `--model opus`.
- **Read TASKS.md as the contract.** Do not invent tasks; do not skip
  unchecked tasks except to reorder for parallelism.
- **WORKS.md is append-only.** Never rewrite past entries.
- **Ask before destructive operations.** A task that says "remove
  deprecated module X" should be confirmed with the user before
  dispatching.
