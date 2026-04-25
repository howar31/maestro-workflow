---
name: maestro.tasks
description: Decompose a confirmed PLAN.md or SPEC.md into a TASKS.md milestone+checklist file in the same docs/<num>-<name>/ folder. Coordinator-only — does not write production code. Pauses for user confirmation before allowing /maestro.work to start.
disable-model-invocation: true
---

# /maestro.tasks — milestone & task decomposition

You are the coordinator (Opus). Convert a confirmed PLAN.md or SPEC.md into a
TASKS.md, then stop and wait for user confirmation. **You do not write
production code in this skill.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/maestro-workflow/config.json"
```

If `$USER_CONFIG` is missing, tell the user to run `/maestro.setup` first.

## 1. Locate the sprint

Find the target `docs/<num>-<slug>/` folder:

1. If user passed an argument (`/maestro.tasks 03-profile-page`), use it.
2. Otherwise, list `docs/*/` folders sorted by `<num>` desc and ask the user
   to pick. Default to the most recent.

Read the existing `PLAN.md` or `SPEC.md` in the chosen folder. If neither
exists, tell the user to run `/maestro.plan` first.

## 2. Read context

- `docs/PRD.md`, `docs/TECHSTACK.md` (project-level)
- `CLAUDE.md`, `AGENTS.md` (root)
- The PLAN/SPEC for the current sprint

## 3. Decompose

Produce milestones + tasks following this shape (in `output_language`):

```markdown
# Tasks — <Feature Name>

> Source: PLAN.md | SPEC.md   •   Sprint: docs/<num>-<slug>/

## Milestone 1: <name>
**Goal:** <one-sentence outcome>
**Acceptance:** <how we know it is done>

- [ ] T1.1 — <atomic task, 1–4 hours of work>
- [ ] T1.2 — ...

## Milestone 2: ...
```

### Decomposition rules

- A **milestone** ends in something demonstrable (a feature works, a test
  passes, a script returns expected output). 1–5 milestones per sprint.
- A **task** is one focused change. If it cannot be done in 1–4 hours, split.
- Tasks are written so a TDD-focused subagent can execute them with the
  context already in PLAN/SPEC + the task line.
- For **parallelisable** work within a milestone, mark a `🔀` lane:
  `- [ ] 🔀 [A] T1.1 — ...` and `- [ ] 🔀 [B] T1.2 — ...`. Lanes [A] and [B]
  must touch disjoint files. /maestro.work can later dispatch parallel
  developers for `🔀` lanes.
- Each task should imply at least one **test** that proves it. If the test is
  E2E or browser-based, note the recipe path (e.g. `# E2E: cypress/run.sh
  user-profile.spec.ts`).
- Never assume framework / tool — read TECHSTACK.md.

## 4. Write the file

```bash
sprint_dir="docs/<num>-<slug>"
echo "<task content>" > "$sprint_dir/TASKS.md"
```

Show the user the resulting `TASKS.md` and ask them to confirm.

If they want changes, iterate until they confirm.

## 5. Hand-off

After confirmation:

1. Recommend the next step: `/maestro.work` (or `/maestro.xreview-plan` if
   the PLAN was not yet reviewed).
2. Do not run anything else automatically.

## Conventions

- File name is uppercase: `TASKS.md`.
- Task IDs are stable: `T<milestone>.<index>`. They survive iteration so
  WORKS.md can reference them.
- Once `/maestro.work` has started touching a TASKS.md, do not rewrite it
  destructively in this skill — tell the user to revert + re-decompose, or
  edit specific tasks manually.

## Argument parsing

- `/maestro.tasks` — most recent sprint
- `/maestro.tasks <num>-<slug>` — explicit sprint folder
- `/maestro.tasks --milestones N` — hint at desired milestone count (the
  coordinator will try to honour but will not split where it makes no sense)
