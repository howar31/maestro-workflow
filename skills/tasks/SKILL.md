---
name: tasks
description: Decompose a confirmed PLAN.md or SPEC.md into a TASKS.md milestone+checklist file in the same magi/<num>-<name>/ folder. Coordinator-only — does not write production code. Pauses for user confirmation before allowing /magi:go to start.
disable-model-invocation: true
---

# /magi:tasks — milestone & task decomposition

You are the coordinator (Opus). Convert a confirmed PLAN.md or SPEC.md into a
TASKS.md, then stop and wait for user confirmation. **You do not write
production code in this skill.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If `$USER_CONFIG` is missing, tell the user to run `/magi:setup` first.

## 0.5. State preflight (auto-refuse if not allowed)

Run `scripts/shared/detect-state.sh` and check whether `tasks` is in
the `disallowed_skills` map. If yes, present the reason + suggested next
step in the user's `output_language` and abort.

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["tasks"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["tasks"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["tasks"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:tasks: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

After preflight passes, also surface any **staleness warnings** relevant
to this skill. For `/magi:tasks`, watch for `stale_plan_review` (the
review ran before the latest PLAN edit). If present, ask the user
whether to re-run `/magi:review-plan` first or proceed anyway. Default
proceed if the user just hits Enter.

`--force` skips the entire preflight (advanced/recovery only).

## 1. Locate the sprint

Find the target `magi/<num>-<slug>/` folder:

1. If user passed an argument (`/magi:tasks 03-profile-page`), use it.
2. Otherwise, list `magi/*/` folders sorted by `<num>` desc and ask the user
   to pick. Default to the most recent.

Read the existing `PLAN.md` or `SPEC.md` in the chosen folder. If neither
exists, tell the user to run `/magi:plan` first.

## 2. Read context

- `magi/PRD.md`, `magi/TECHSTACK.md` (project-level)
- `CLAUDE.md`, `AGENTS.md` (root)
- The PLAN/SPEC for the current sprint

## 3. Decompose

Produce milestones + tasks following this shape (in `output_language`):

```markdown
# Tasks — <Feature Name>

> Source: PLAN.md | SPEC.md   •   Sprint: magi/<num>-<slug>/

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
  must touch disjoint files. /magi:go can later dispatch parallel
  developers for `🔀` lanes.
- Each task should imply at least one **test** that proves it. If the test is
  E2E or browser-based, note the recipe path (e.g. `# E2E: cypress/run.sh
  user-profile.spec.ts`).
- Never assume framework / tool — read TECHSTACK.md.

## 4. Write the file

```bash
sprint_dir="magi/<num>-<slug>"
echo "<task content>" > "$sprint_dir/TASKS.md"
```

Show the user the resulting `TASKS.md` and ask them to confirm.

If they want changes, iterate until they confirm.

## 5. Hand-off

After confirmation, tell the user the next step in their `output_language`.

Decision:

- If `MAGI_PLAN_REVIEW.md` is **missing** for this sprint → suggest
  `/magi:review-plan` (**optional**, can skip to save tokens) **or**
  `/magi:go` directly if the user trusts the plan.
- If `MAGI_PLAN_REVIEW.md` exists → suggest `/magi:go`.

Example output:

```
✅ TASKS.md written to magi/03-profile-page/TASKS.md
3 milestones, 8 tasks. Lane parallelism on T2.1+T2.2.

下一步：
  /magi:go            (派工 magi-developer 實作 — 預設自動偵測可平行的 task)
  /magi:review-plan   (optional — 多模型審 plan，省 token 可跳過)
```

Do not run anything else automatically.

## Conventions

- File name is uppercase: `TASKS.md`.
- Task IDs are stable: `T<milestone>.<index>`. They survive iteration so
  WORKS.md can reference them.
- Once `/magi:go` has started touching a TASKS.md, do not rewrite it
  destructively in this skill — tell the user to revert + re-decompose, or
  edit specific tasks manually.

## Argument parsing

- `/magi:tasks` — most recent sprint
- `/magi:tasks <num>-<slug>` — explicit sprint folder
- `/magi:tasks --milestones N` — hint at desired milestone count (the
  coordinator will try to honour but will not split where it makes no sense)
