---
name: init
description: One-time, idempotent project bootstrap. Detects which magi-workflow project files are missing (root CLAUDE/README/SPEC, magi/PRD/TECHSTACK/BACKLOG) and offers to scaffold them. Never overwrites existing files. Run once when adopting magi-workflow on a new or existing project. Safe to re-run.
disable-model-invocation: true
---

# /magi:init — project bootstrap

You are the coordinator. Detect which magi-workflow files are missing in
this project and offer to scaffold the missing ones with minimal templates.
Existing files are **never** overwritten. **You do not write production
code.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If `$USER_CONFIG` is missing, tell the user to run `/magi:setup` first
(init needs `output_language` from there).

This skill does not require a git repo, but warns the user if not in one
(a typical magi-workflow project will be).

## 1. Scan for missing files

Check existence of each well-known project file:

| Path | Tier | Role |
|------|------|------|
| `CLAUDE.md` | 1 (root) | AI agent entry / instructions index |
| `README.md` | 1 (root) | Human-readable project description |
| `SPEC.md` | 1 (root) | Architecture & feature spec for AI agents |
| `magi/PRD.md` | 2 (`magi/`) | Product requirements |
| `magi/TECHSTACK.md` | 2 (`magi/`) | Tech stack constraints |
| `magi/BACKLOG.md` | 2 (`magi/`) | Pending items promoted from sprint DRIFT.md |

Build two lists:
- **missing** — files that don't exist
- **existing** — files that do exist (will be skipped, never modified)

Show the user both lists clearly.

If `missing` is empty, tell the user "project is already bootstrapped" and
suggest `/magi:plan` for next steps. Exit.

## 2. Confirm with the user (unless `--all`)

For each missing file, ask:

```
Create <path>? (y/n/skip-all)
```

- `y` → mark for creation
- `n` → skip just this one
- `skip-all` → skip everything remaining and stop asking

If `--all` flag was passed, mark everything missing for creation without
prompting.

If `--only <file1,file2>` was passed, mark only those (intersected with
the missing list).

If `--dry-run` was passed, list what **would** be created and exit
without writing.

## 3. Scaffold templates

Use `output_language` from `$USER_CONFIG` (default `zh-TW`) for prose; keep
structural headings in English. All templates are deliberately short — the
user fills in the substance themselves or via subsequent magi-workflow
commands.

### `CLAUDE.md` (root, Tier 1)

```markdown
# CLAUDE.md

Project-wide instructions for AI agents working in this repo.

## What this is
<one-sentence description>. Architecture and full feature spec live in
[SPEC.md](SPEC.md).

## Run / test commands
```bash
# Add the commands your project needs to build, run, and test here.
```

## Conventions
- <e.g., language version, indentation, naming>
- <project-specific rules AI agents should follow>

## Workflow rules
- Don't commit on the user's behalf without explicit confirmation.
- Use Conventional Commits.
- Use `/magi:commit` to commit (sprint mode for feature work, standalone
  mode for chore/docs/small fixes).
```

### `README.md` (root, Tier 1)

```markdown
# <Project Name>

<one-paragraph description of what this project does>.

## Installation
```bash
# Installation steps
```

## Usage
```bash
# Quick-start example
```

## Documentation
- [SPEC.md](SPEC.md) — architecture and feature spec
- `magi/` — PRD, TECHSTACK, BACKLOG, sprint folders

## License
<license name>
```

### `SPEC.md` (root, Tier 1)

```markdown
# SPEC

Architecture and feature spec, kept in sync with the codebase. Updated by
`/magi:commit` when project-level changes warrant it.

## Architecture overview
<3–5 sentences describing the high-level architecture>.

## Components
<list and briefly describe each component / module>.

## Public surface
- <commands / endpoints / public APIs>

## Conventions
- <e.g., file layout, naming>

## Status
<one paragraph: what's done, what's in progress>.
```

### `magi/PRD.md` (Tier 2)

```markdown
# PRD — <Project Name>

## Problem
<what problem this project solves; who feels it>.

## Users
<primary users, secondary users, non-users>.

## Goals
- <measurable goal 1>
- <measurable goal 2>

## Non-goals
- <what this project explicitly will not do>

## Success metrics
<how we will know this project is succeeding>.
```

### `magi/TECHSTACK.md` (Tier 2)

```markdown
# Tech stack

## Language(s)
- <e.g., TypeScript 5, Node 20+>

## Framework / runtime
- <e.g., Next.js 14, FastAPI, Go net/http>

## Database / storage
- <e.g., Postgres 16, Redis>

## Deployment
- <e.g., Cloud Run, Kubernetes, Vercel>

## Test framework
- <e.g., vitest, pytest, go test>

## Constraints
- <license / compliance / performance constraints AI agents should respect>
```

### `magi/BACKLOG.md` (Tier 2)

```markdown
# Backlog

Items here are candidates for future sprints, typically promoted from
sprint DRIFT.md by `/magi:commit`. Use `/magi:plan` (no args) to promote
one into a new sprint.

## Pending
<!-- /magi:commit appends C-class drift items here -->

## Promoted to sprints
<!-- /magi:plan moves consumed items here -->
```

## 4. Write files

For each marked-for-creation entry:

1. Verify the file still doesn't exist (defense in depth).
2. Ensure parent directory exists (`mkdir -p docs` for Tier 2).
3. Write the template.
4. Report `created: <path>` to the user.

## 5. Report and hand-off

Show a summary:

```
Created:
  - CLAUDE.md
  - README.md
  - magi/PRD.md
  ...

Skipped (already existed):
  - SPEC.md
  ...

Skipped (user declined):
  - magi/TECHSTACK.md
  ...
```

Recommend the next step in the user's `output_language`. After init, the
project is ready to start its first sprint:

```
✅ Bootstrap complete.

下一步：
  /magi:plan "<功能描述>"     (開始第一個 sprint)
  /magi:plan                  (乾跑：從 magi/BACKLOG.md 挑既有項目)

Tip: 先把 magi/PRD.md 與 magi/TECHSTACK.md 補完，/magi:plan 會用得到。
```

Suggestions by scenario:
- If `magi/PRD.md` was just scaffolded → suggest user fill it in before
  `/magi:plan`.
- If everything (or most things) already existed → suggest `/magi:plan` to
  start a sprint.

## Argument parsing

- `--all` — auto-create all missing files; skip per-file prompts. Useful in
  CI or when you want a one-shot bootstrap.
- `--only <file1,file2>` — restrict to a subset (e.g.,
  `--only magi/BACKLOG.md`). Comma-separated list of paths from the table
  in §1.
- `--dry-run` — print what would be created without writing anything.

## Conventions

- **Idempotent**: re-running `/magi:init` is always safe. Never overwrites.
- **No production code**: this skill only creates project-meta documentation.
- **Templates are minimal on purpose**: the user (or follow-up
  magi-workflow commands) fills in the substance. init's job is to
  create the *anchor* for future work, not to author content.
- **Per-feature files** (PLAN/SPEC/TASKS/WORKS/DRIFT inside
  `magi/<num>-<slug>/`) are NOT bootstrapped here — those are created by
  `/magi:plan` per sprint.
