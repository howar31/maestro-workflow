## What this is
Multi-CLI MAGI orchestration plugin for code/plan review. → `SPEC.md`

## Slash commands
Per-command contract in `skills/magi.<name>/SKILL.md`. → `SPEC.md §Slash commands`

## Subagents
→ `agents/magi-developer.md`, `agents/magi-reviewer.md`

## Project state model
8 filesystem-derived states; SSOT is `scripts/shared/detect-state.sh`. → `SPEC.md §Project state model`

## Project document tiers
→ `SPEC.md §Project document tiers`

## Commit scope
`/magi.commit` is the single in-project commit path (sprint + standalone). Independent of `~/.claude/skills/commit/`.

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

## Adapter contract
→ `SPEC.md §Adapter contract`

## Plugin versioning
→ `SPEC.md §Plugin versioning`
