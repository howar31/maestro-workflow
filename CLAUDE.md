# CLAUDE.md

Project-wide instructions for AI agents working in this repo.

## What this is
A Claude Code plugin that orchestrates multi-model code/plan reviews via parallel CLI fan-out plus MAGI weighted voting. Architecture and full feature spec live in [SPEC.md](SPEC.md).

## Status
All five phases (A–E) complete. The plugin is feature-complete relative to the original SPEC.

- **Phase A** — orchestrator + three adapters (claude/gemini/codex) + MAGI consensus report builder.
- **Phase B** — six core slash commands and override flags.
- **Phase C** — two subagents (`magi-developer` Sonnet, `magi-reviewer` Opus).
- **Phase D** — four web-domain skills + reference docs.
- **Phase E** — canonical `references/AGENTS.md`, optional git hooks (`commit-msg` Conventional Commits, `pre-commit` lint/typecheck auto-detect, `pre-push` WIP warning).

## Slash commands

Every command is `disable-model-invocation: true` — it only runs when the user explicitly types `/magi.<name>`.

### Core flow

Every command does a **state preflight** via `scripts/shared/detect-state.sh` and refuses to run when prerequisites are missing (with a clear "Suggested next step" pointing the user to the right command). Every command's hand-off ends with a "下一步" recommendation so users don't need to memorize the sequence.

| Command | Role | Mandatory? | Pauses for user? |
|---------|------|------------|-------------------|
| `/magi.setup` | First-run onboarding: healthcheck CLIs, write `~/.config/magi-workflow/config.json`, dry-run | once per machine | yes (interactive) |
| `/magi.init` | One-time project bootstrap: scaffolds missing root CLAUDE/README/SPEC + docs/PRD/TECHSTACK/BACKLOG. Idempotent | once per project | yes (per-file confirm) |
| `/magi.plan` | **Smart dispatcher**: classifies type (feat/fix/hotfix/refactor/chore/docs/perf/test/style/ci) + scale (trivial/minor/major) and routes to PLAN.md / SPEC.md / TICKET.md / HOTFIX.md / no-artifact. Bare invocation reads `docs/BACKLOG.md` Pending entries | per change | yes (confirm classification + doc) |
| `/magi.tasks` | Decomposes PLAN/SPEC/TICKET into TASKS.md milestones + checklists | major work only | yes (confirm tasks) |
| `/magi.review-plan` | Multi-CLI MAGI review of plan; outputs `MAGI_PLAN_REVIEW.md` | **optional** (skip to save tokens) | yes (verdict to user) |
| `/magi.go` | Dispatches `magi-developer` (Sonnet) per task. **Default auto-parallelizes** disjoint tasks; `--parallel` forces, `--sequential` overrides | per work session | yes (before commit) |
| `/magi.review-code` | Multi-CLI MAGI on git diff; produces `DRIFT.md` (Status: NONE/DETECTED) when a sprint context exists | **mandatory** in sprint flow (DRIFT.md is required by `/magi.commit`) | yes (verdict to user) |
| `/magi.commit` | Stage + commit. Sprint mode: A-class drift backfill into PLAN/SPEC, C-class promotion to `docs/BACKLOG.md`, optional root-doc sync, Conventional Commits. Standalone mode for chore/docs/small fixes | per commit | yes (confirm message) |
| `/magi.yolo` | **Headless / walk-away mode**. Fresh (`<desc>`) or Resume (`--resume`). Runs plan→tasks→work→review-code→commit pipeline without prompts; resume mode skips already-completed phases. Conservative auto-decisions, audit log in `<sprint>/YOLO_LOG.md`. `--push` optionally pushes (refused on default branch). Aborts on any failure | opt-in | **no prompts** (intentional) |

### Web-domain elaborations (run between `/magi.plan` and `/magi.tasks`)

| Command | Role | Output |
|---------|------|--------|
| `/magi.web.frontend.spec` | Append Frontend section (component tree, a11y, Playwright e2e) to SPEC.md | `SPEC.md` updated; optional Playwright stub |
| `/magi.web.backend.spec` | Append Backend section (OpenAPI/SDL contract, data model, authn/z, contract test) | `SPEC.md` updated; optional contract test stub |
| `/magi.web.infra.plan` | Generate `INFRA.md` with Terraform/gcloud dry-run, IAM diff, cost estimate, rollback | `docs/<num>-<slug>/INFRA.md`, `plan.tfplan`, `plan.json` |
| `/magi.web.ci.spec` | Generate `CI.md` + draft workflow file (GHA / Cloud Build / etc.) | `docs/<num>-<slug>/CI.md` + draft workflow inside the doc dir |

## Subagents

- **`magi-developer`** (`model: sonnet`) — TDD-first implementation worker. Read/Write/Edit/Bash/Grep/Glob. Reports `DONE: <summary>` or `BLOCKED: <reason>`. Does not make architecture decisions and does not commit.
- **`magi-reviewer`** (`model: opus`) — Defensive code reviewer. Read/Grep/Glob/Bash (read-only). Outputs structured Critical / Important / Note plus `Drift from contract` (A/B/C classes) when a sprint contract is provided. Never edits files.

## Project state model

magi-workflow has 8 project states derived purely from the filesystem (no state file). The shared script `scripts/shared/detect-state.sh` is the single source of truth — it inspects which root/docs/sprint files exist, computes the state, and outputs a JSON that includes:

- `state` — one of `BOOTSTRAP` / `INITIALIZED` / `PLANNING` / `PLAN_REVIEWED` / `TASKS_READY` / `IN_PROGRESS` / `WORK_DONE` / `CODE_REVIEWED`
- `allowed_skills` / `disallowed_skills` — which `magi.*` commands are valid in this state and (for disallowed ones) the reason + suggested next step
- `warnings` — staleness signals (e.g., `stale_plan_review`, `stale_drift`, `tasks_without_plan`)

Every magi skill's preflight calls this script and refuses to run if it appears in `disallowed_skills`. Full state model + transitions: see SPEC.md "Project state model" section.

## Project document tiers

magi-workflow's project documents are organized into three tiers by reading frequency:

| Tier | Location | Role | Files |
|------|----------|------|-------|
| **1: Entry / primary reference** | Root | First-eye contact for humans (GitHub) and AI agents (Anthropic convention); high-frequency reads | `README.md`, `CLAUDE.md`, `SPEC.md` |
| **2: Process / secondary reference** | `docs/` | Consulted when context is needed; low-frequency reads | `PRD.md`, `TECHSTACK.md`, `BACKLOG.md` |
| **3: Sprint scope** | `docs/<num>-<slug>/` | per-feature; written by `/magi.plan`, frozen at sprint end | `PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md`, `DRIFT.md` |

Decision rule: "Want to see it on first opening the repo?" Yes → Tier 1. "Reference when needed?" → Tier 2. "Tied to a single feature?" → Tier 3.

`/magi.init` bootstraps Tier 1 + Tier 2 (creates only what's missing). `/magi.plan` creates Tier 3 per sprint. `/magi.commit` keeps Tier 1 in sync when project-level changes warrant it (heuristic-detected, user-gated).

## Scope boundaries (commit tools)

magi-workflow is **self-contained**: it does not depend on any external commit skill. `/magi.commit` handles the entire commit + doc-sync flow for both sprint and standalone scenarios.

If a user happens to also have a personal `~/.claude/skills/commit/` skill, the two coexist:
- `/magi.commit` — commits within a magi-workflow project (sprint or standalone)
- A personal `/commit` skill — commits in projects that don't use magi-workflow at all

The user can choose to keep both, or retire the personal skill once `/magi.commit` is preferred. magi-workflow makes no assumption either way.

## Run / test commands

```bash
# Aggregate CLI healthcheck (writes nothing; exits 0 if at least one ok).
./scripts/shared/preflight.sh

# Real CLI smoke test — calls every reviewer with a tiny prompt.
./test/e2e-smoke.sh

# Mock-adapter test — validates quota/auth fallback without spending tokens.
./test/e2e-fallback.sh
```

## Conventions

- **Bash 3.2 compatible.** macOS ships bash 3.2; do not use `mapfile`, `readarray`, `declare -A`, or `${var^^}`/`${var,,}`.
- **Shellcheck-friendly.** Source paths use `# shellcheck source=...` annotations.
- **`set -uo pipefail`** at the top of every script. Avoid `set -e` — explicit `|| rc=$?` patterns are clearer for orchestration.
- **Bash arrays must be initialised** (`arr=()`) before any indexed access; otherwise `set -u` aborts the script.
- **`jq`** for all JSON read/write. **Python 3** is allowed but currently unused.
- **No `setsid`** (Linux-only). Process group isolation is achieved via subshell `(...) &` + PID tracking.
- **`gtimeout` preferred over `timeout`** when both are present (BSD/GNU divergence).

### Language

| Surface | Language |
|---------|----------|
| `CLAUDE.md`, `SPEC.md`, `references/**`, `skills/**/SKILL.md`, `agents/*.md` | English |
| `README.md`, future `/magi.setup` interactive prompts, plugin output to user | Traditional Chinese (zh-TW), configurable |
| Code comments | English |

### File naming

- SSOT documents produced **inside user projects** are uppercase: `PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md`, `DRIFT.md` (one bundle per `docs/<num>-<name>/`); `PRD.md`, `TECHSTACK.md`, `BACKLOG.md` (project-level under `docs/`).
- Plugin internals follow normal kebab-case for shell scripts and `<name>.md` for skill / agent definitions.

## Adapter contract (when adding a new CLI)

Every `skills/magi.review-plan/scripts/adapters/<cli>.sh` must support:

1. `<adapter> --healthcheck <config>` — print `status=ok|skip|fail` plus optional `reason=` / `version=` / `path=` lines. Exit 0 (ok), 1 (skip), 2 (fail).
2. `<adapter> run <config> <prompt-file> <log-file> <final-file> [model]` — invoke the CLI, write log + final, return:
   - `0` ok, `11` skip-quota, `12` skip-auth, `13` skip-missing, `14` skip-empty-final, anything else fail.

Adapters that wrap npm-based CLIs must source `scripts/shared/nvm-exec.sh` and run the CLI under the configured node version (avoids the macOS `/usr/bin/env node` → wrong-shebang trap).

## Workflow rules
Do not commit on the user's behalf without explicit confirmation. After completing an implementation, summarise and wait. Use Conventional Commits.
