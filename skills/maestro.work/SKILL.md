---
name: maestro.work
description: Execute the next undone task(s) from a sprint's TASKS.md by dispatching the maestro-developer subagent (Sonnet by default). Updates WORKS.md as a development log. Pauses for user confirmation before any commit. Supports --model, --task, --milestone, --parallel for fine-grained control.
disable-model-invocation: true
---

# /maestro.work — execute tasks via subagent

You are the coordinator. Read TASKS.md, dispatch `maestro-developer` to do
the work, collect results, update WORKS.md, and stop. **You do not write
production code yourself.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/maestro-workflow/config.json"
```

If config missing → tell user to run `/maestro.setup`.

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
`/maestro.review`.

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
docs/<num>-<slug>/

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

Use the Task tool with `subagent_type: maestro-developer` (or whatever
override the user passed via `--model`).

**Sequential batch:**

Dispatch one task. Wait for DONE/BLOCKED. Decide whether to continue:

- DONE → continue to next task in batch.
- BLOCKED → stop the batch, report to user, ask how to proceed.

**Parallel batch (`--parallel` + lanes):**

Dispatch all lanes in a single message (multiple Task tool uses). Wait for
all to return. Aggregate results.

Lanes must touch **disjoint files**. Do not dispatch parallel lanes that
contend on the same file — TASKS.md author should have caught this; if you
spot it, abort and ask the user to re-decompose.

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

Tell the user:

- What got done (link/cite tasks).
- What test status looks like.
- Recommended next step:
  - More tasks remaining in this milestone → another `/maestro.work` (or
    auto-continue if user says so).
  - Milestone done → `/maestro.review` (multi-model MAGI by default) before
    commit.
  - Blocking issue → ask the user.

**Never commit on the user's behalf.** Wait for explicit instruction.

## Argument parsing

- `--model <name>` — override the developer subagent model (e.g., bump to
  Opus for one specific complex task).
- `--milestone N` — work on a specific milestone.
- `--task T<m>.<n>` — work on a specific task (overrides milestone).
- `--parallel` — dispatch lanes within a milestone in parallel.
- `--sprint <num>-<slug>` — target a specific sprint folder.

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
