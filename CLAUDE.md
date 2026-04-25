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

| Command | Role | Pauses for user? |
|---------|------|-------------------|
| `/magi.setup` | First-run onboarding: healthcheck CLIs, write `~/.config/magi-workflow/config.json`, dry-run | yes (interactive) |
| `/magi.plan` | Coordinator drafts PLAN.md / SPEC.md in `docs/<num>-<slug>/`; after confirmation, scans the doc + TECHSTACK.md for web-domain keywords and offers `/magi.web.<x>.spec` add-ons | yes (confirm doc) |
| `/magi.tasks` | Coordinator decomposes PLAN/SPEC into TASKS.md milestones + checklists | yes (confirm tasks) |
| `/magi.review-plan` | Multi-CLI MAGI review of PLAN/SPEC; outputs `MAGI_PLAN_REVIEW.md` | yes (verdict to user) |
| `/magi.work` | Dispatches `magi-developer` (Sonnet) per task; updates WORKS.md | yes (before commit) |
| `/magi.review-code` | Default multi-CLI MAGI on git diff; `--single` falls back to `magi-reviewer` (Opus) | yes (verdict to user) |

### Web-domain elaborations (run between `/magi.plan` and `/magi.tasks`)

| Command | Role | Output |
|---------|------|--------|
| `/magi.web.frontend.spec` | Append Frontend section (component tree, a11y, Playwright e2e) to SPEC.md | `SPEC.md` updated; optional Playwright stub |
| `/magi.web.backend.spec` | Append Backend section (OpenAPI/SDL contract, data model, authn/z, contract test) | `SPEC.md` updated; optional contract test stub |
| `/magi.web.infra.plan` | Generate `INFRA.md` with Terraform/gcloud dry-run, IAM diff, cost estimate, rollback | `docs/<num>-<slug>/INFRA.md`, `plan.tfplan`, `plan.json` |
| `/magi.web.ci.spec` | Generate `CI.md` + draft workflow file (GHA / Cloud Build / etc.) | `docs/<num>-<slug>/CI.md` + draft workflow inside the doc dir |

## Subagents

- **`magi-developer`** (`model: sonnet`) — TDD-first implementation worker. Read/Write/Edit/Bash/Grep/Glob. Reports `DONE: <summary>` or `BLOCKED: <reason>`. Does not make architecture decisions and does not commit.
- **`magi-reviewer`** (`model: opus`) — Defensive code reviewer. Read/Grep/Glob/Bash (read-only). Outputs structured Critical / Important / Note. Never edits files.

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

- SSOT documents produced **inside user projects** are uppercase: `PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md` (one bundle per `docs/<num>-<name>/`).
- Plugin internals follow normal kebab-case for shell scripts and `<name>.md` for skill / agent definitions.

## Adapter contract (when adding a new CLI)

Every `skills/magi.review-plan/scripts/adapters/<cli>.sh` must support:

1. `<adapter> --healthcheck <config>` — print `status=ok|skip|fail` plus optional `reason=` / `version=` / `path=` lines. Exit 0 (ok), 1 (skip), 2 (fail).
2. `<adapter> run <config> <prompt-file> <log-file> <final-file> [model]` — invoke the CLI, write log + final, return:
   - `0` ok, `11` skip-quota, `12` skip-auth, `13` skip-missing, `14` skip-empty-final, anything else fail.

Adapters that wrap npm-based CLIs must source `scripts/shared/nvm-exec.sh` and run the CLI under the configured node version (avoids the macOS `/usr/bin/env node` → wrong-shebang trap).

## Workflow rules
Do not commit on the user's behalf without explicit confirmation. After completing an implementation, summarise and wait. Use Conventional Commits.
