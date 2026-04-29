## What this is
Multi-CLI MAGI orchestration plugin for code/plan review. → `SPEC.md`

## Slash commands
Per-command contract in `skills/<name>/SKILL.md`. → `SPEC.md §Slash commands`

## Subagents
→ `agents/developer.md`, `agents/reviewer.md`

## Project state model
8 filesystem-derived states; SSOT is `scripts/shared/detect-state.sh`. → `SPEC.md §Project state model`

## Project document tiers
→ `SPEC.md §Project document tiers`

## Spec deltas
PLAN/SPEC carry a `## Spec deltas` section declaring expected modifications to root `SPEC.md` / `CLAUDE.md` / `magi/PRD.md` / `magi/TECHSTACK.md`. Evaluated by `/magi:review-plan`; verified by `/magi:commit` §2.5 (D1/D2/D3). → `SPEC.md §Spec deltas`

## Commits
- `/magi:commit` is the single in-project commit path (sprint + standalone). Independent of `~/.claude/skills/commit/`.
- Before any commit, check whether `.claude-plugin/plugin.json` needs a bump per `SPEC.md §Plugin versioning`. Bump goes in the same commit.
  - When bumping, also update the version badge in `README.md` (line near `shields.io/badge/version-vX.Y.Z`) in the same commit.

## Run / test
```bash
./scripts/shared/preflight.sh    # CLI healthcheck
./test/e2e-smoke.sh              # real CLI smoke test
./test/e2e-fallback.sh           # mock-adapter fallback test
```

## Conventions
- Bash 3.2 compatible (no `mapfile`, `readarray`, `declare -A`, `${var^^}`)
- `set -uo pipefail` on every script; avoid `set -e`; init arrays with `arr=()`
- `jq` for JSON; no `setsid` (Linux-only); prefer `gtimeout` over `timeout`
- Shellcheck-friendly (`# shellcheck source=` annotations)
- File naming: project SSOT docs uppercase (`PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md`, `DRIFT.md`, `PRD.md`, `TECHSTACK.md`, `BACKLOG.md`); plugin internals kebab-case
- Language: English for `CLAUDE.md`, `SPEC.md`, `references/`, `skills/**/SKILL.md`, `agents/*.md`; zh-TW for `README.md` and user-facing prompts; English for code comments

## Lessons
When magi misbehaves in a real session and we have to re-correct Claude's shortcut, add a one-line entry to `references/LESSONS.md` under the relevant skill section. Empirical incidents only — no theoretical "what if" entries.

## Adapter contract
→ `SPEC.md §Adapter contract`
