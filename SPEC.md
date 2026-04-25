# SPEC.md

Authoritative architecture and feature spec of `maestro-workflow`. Update when behavior changes.

## Vision

A Claude Code plugin that drives a five-stage engineering workflow with each stage backed by the most appropriate model:

1. **Plan** — Opus-class coordinator drafts `PLAN.md` / `SPEC.md`.
2. **Plan review (xreview)** — three external CLIs (claude / gemini / codex) review the plan in parallel. MAGI weighted voting decides which findings are adopted.
3. **Tasks** — coordinator decomposes the approved plan into `TASKS.md`.
4. **Implementation** — Sonnet-class subagent runs TDD against `TASKS.md`, updating `WORKS.md`.
5. **Code review** — same MAGI-weighted multi-CLI fan-out applied to the diff.

A `/maestro.setup` wizard runs once at install time to inspect installed CLIs, write `~/.config/maestro-workflow/config.json`, and surface unavailable reviewers.

## Implementation phases

| Phase | Deliverable | Status |
|-------|-------------|--------|
| A | Orchestrator + three adapters + MAGI consensus + tests | ✅ done |
| B | Setup wizard + 6 core skills + override flags | ✅ done |
| C | Subagents (`maestro-developer` / `maestro-reviewer`) | ✅ done (folded into Phase B) |
| D | Web-domain skills (frontend / backend / infra / ci) + 4 reference docs | ✅ done |
| E | Team-ready hooks + canonical AGENTS.md | ⏳ remaining |

## Slash commands (Phase B)

Every command's SKILL.md has `disable-model-invocation: true` — it only runs
when the user explicitly types the slash. Skills delegate to the
orchestrator + magi-consensus shell scripts and to the two subagents below.

| Command | Body summary |
|---------|--------------|
| `/maestro.setup [--reset \| --recheck]` | Healthcheck CLIs via `preflight.sh`, ask user for reviewer roster + weights + MAGI mode + nvm version + output language, write `~/.config/maestro-workflow/config.json`, validate with a tiny dry-run via the orchestrator. |
| `/maestro.plan [slug] "<desc>"` | Resolve `docs/<num>-<slug>/`, read project context (PRD/TECHSTACK/CLAUDE/AGENTS), decide PLAN.md vs SPEC.md, draft, pause for user confirmation. |
| `/maestro.tasks [<num>-<slug>] [--milestones N]` | Read PLAN/SPEC, write TASKS.md with milestones + atomic tasks, mark `🔀` lanes for parallelisable work, pause for confirmation. |
| `/maestro.xreview-plan [--reviewers ...] [--magi <mode>]` | Build review prompt from PLAN/SPEC, invoke orchestrator, run magi-consensus, then **the coordinator** applies semantic dedup + weighted vote per `references/MAGI_VOTING.md`, writes `MAGI_PLAN_REVIEW.md`. |
| `/maestro.work [--milestone N \| --task T<m>.<n>] [--parallel] [--model ...]` | Read TASKS.md, dispatch `maestro-developer` per task (or per `🔀` lane in parallel), aggregate DONE/BLOCKED, append to WORKS.md, pause before commit. |
| `/maestro.review [--single] [--magi <mode>] [--diff <range>]` | Default: orchestrator + MAGI on `git diff`. `--single`: dispatch `maestro-reviewer` only. Writes `MAGI_CODE_REVIEW.md` or `SINGLE_CODE_REVIEW.md`. Never auto-commits. |

## Subagents (Phase C — folded into B)

| Agent | Model | Tools | Role |
|-------|-------|-------|------|
| `maestro-developer` | `sonnet` | Read, Write, Edit, Bash, Grep, Glob | TDD-first implementation worker. Receives a self-contained task brief from `/maestro.work`. Reports `DONE` or `BLOCKED`. Forbidden from architecture changes, scope expansion, commits, or package upgrades. |
| `maestro-reviewer` | `opus` | Read, Grep, Glob, Bash (read-only) | Defensive code reviewer for `/maestro.review --single` and degraded-MAGI fallback. Outputs Verdict + 🔴 Critical / 🟡 Important / 🟢 Note. Never edits files. |

## Override flags (Phase B)

Every slash command supports its applicable subset:

| Flag | Applies to | Effect |
|------|-----------|--------|
| `--model <name>` | plan, tasks, work, review | Override the active model for this invocation. |
| `--magi <mode>` | xreview-plan, review | Override MAGI mode (`majority` / `supermajority` / `unanimous` / `threshold:<N>`). |
| `--reviewers <list>` | xreview-plan, review | Override the reviewer roster: `claude:opus,gemini:default,...`. |
| `--single` | review | Skip MAGI; use `maestro-reviewer` subagent only. |
| `--diff <range>` | review | Diff range to review. Defaults to working tree vs HEAD. |
| `--staged` | review | Review only staged changes. |
| `--workdir <path>` | xreview-plan, review | Reuse a previous orchestrator workdir; skip fan-out, re-run consensus. |
| `--milestone N` / `--task T<m>.<n>` | work | Pick what to dispatch. |
| `--parallel` | work | Dispatch `🔀` lanes in parallel. |
| `--reset` / `--recheck` | setup | Wipe config / re-validate without resetting. |

## Phase A architecture

### Components

```
maestro-workflow/
├── .claude-plugin/plugin.json                 # plugin metadata
├── config/default.json                        # reviewer list, MAGI rules, fallback policy
├── scripts/shared/
│   ├── error-patterns.sh                      # quota/auth pattern matchers (sourced lib)
│   ├── extract-final.sh                       # per-CLI final-message extractors (sourced lib + CLI entry)
│   ├── nvm-exec.sh                            # nvm-aware CLI path resolution (sourced lib)
│   ├── preflight.sh                           # aggregated CLI healthcheck → JSON
│   └── magi-consensus.sh                      # consolidates per-reviewer outputs into a MAGI report
├── skills/maestro.xreview-plan/scripts/
│   ├── orchestrator.sh                        # parallel fan-out + event stream + fallback policy
│   └── adapters/{claude,gemini,codex}.sh      # CLI-specific run + healthcheck
└── test/
    ├── e2e-fallback.sh                        # mock adapters → validates quota/auth SKIP semantics
    └── e2e-smoke.sh                           # real CLIs → validates end-to-end pipeline
```

### Orchestrator event protocol

The orchestrator emits one event per line on stdout, mirrored to `<workdir>/events.log`:

| Event | Payload |
|-------|---------|
| `WORKDIR <path>` | First event; consumers parse this to find artifacts. |
| `START <cli:model> <log-path>` | Reviewer task started. |
| `RETURN <cli:model> <log-path> <final-path>` | Reviewer succeeded; `final-path` is non-empty. |
| `SKIP <cli:model> reason=<short> log=<path>` | Reviewer skipped (`quota` / `auth` / `missing`). |
| `FAIL <cli:model> exit=<n> log=<path> final=<path> [reason=<short>]` | Hard failure. |
| `ALL_DONE successful=N skipped=M failed=K policy_pass=true|false workdir=<path> [signal=<name>]` | Terminal event. |

Exit codes: `0` policy passed, `2` policy failed, `3` config error, `130` interrupted by signal.

### Adapter contract

Every adapter at `skills/maestro.xreview-plan/scripts/adapters/<cli>.sh` supports two modes:

1. `--healthcheck <config>` → prints `key=value` lines (`status` / `reason` / `version` / `path`) and exits 0/1/2.
2. `run <config> <prompt-file> <log-file> <final-file> [model]` → exit codes:

| Code | Meaning |
|------|---------|
| 0 | Success — `final-file` non-empty. |
| 11 | SKIP — quota / rate-limit detected via `xreview.quota_error_patterns.<cli>`. |
| 12 | SKIP — auth failure detected via `xreview.auth_error_patterns.<cli>`. |
| 13 | SKIP — CLI binary not found. |
| 14 | SKIP — exit 0 but `final-file` empty (content-layer failure). |
| 1+ | FAIL — anything else. |

### Fallback policy

Defined in `config.xreview.fallback_policy` (`lenient` default | `strict`) and `config.xreview.min_successful_reviewers`. The orchestrator computes `policy_pass`:

- `false` if any `required: true` reviewer did not RETURN.
- `false` under `strict` if any reviewer was SKIP or FAIL.
- `false` if `successful < min_successful_reviewers`.
- `true` otherwise.

### MAGI weighted voting (consensus report)

`scripts/shared/magi-consensus.sh` reads orchestrator artifacts and produces `magi-report.md` (human) + `magi-report.json` (machine). It does **not** semantically deduplicate issues — that is the coordinator agent's job. It does:

- Compute `total_weight` (configured) and `ok_weight` (successful reviewers only).
- Resolve `mode` from config (or `--mode` override): `majority` (>50% of ok_weight) / `supermajority` (≥2/3) / `unanimous` (=ok_weight) / `threshold:N` (absolute).
- Bundle every successful reviewer's `final.txt` with weight metadata.
- Flag DEGRADED MODE when `ok_count < configured_count` or `ok_count == 1`.
- Append explicit instructions for the coordinator on how to apply the voting rule.

### Node / nvm strategy

`scripts/shared/nvm-exec.sh` resolves CLI paths in priority order:

1. `config.node.cli_paths.<cli>` (absolute path).
2. `nvm exec <version> <cli>` if `config.node.use_nvm == true` and `${NVM_DIR}/nvm.sh` exists. `version` is `config.xreview.node_version_per_cli.<cli>` falling back to `config.node.default_version`.
3. `PATH` lookup via `command -v`.

This avoids the macOS pitfall where `gemini`'s shebang `#!/usr/bin/env node` resolves to whatever `node` is first in `$PATH` (often v18 from a system install) instead of the v22 the package was built against.

### Config schema

```jsonc
{
  "xreview": {
    "reviewers": [
      {"cli": "claude", "model": "opus", "weight": 2, "required": true},
      {"cli": "gemini", "model": "default", "weight": 1, "required": false},
      {"cli": "codex",  "model": "default", "weight": 1, "required": false}
    ],
    "magi": {
      "mode": "majority",        // majority | supermajority | unanimous | threshold
      "threshold": null,         // required when mode == "threshold"
      "degraded_mode": "warn_user"
    },
    "fallback_policy": "lenient",          // lenient | strict
    "min_successful_reviewers": 1,
    "timeout_seconds": 3000,
    "quota_error_patterns": {"<cli>": ["regex", ...]},
    "auth_error_patterns":  {"<cli>": ["regex", ...]}
  },
  "node": {
    "use_nvm": true,
    "default_version": "22",
    "cli_paths": {}                        // absolute path overrides per cli
  },
  "output_language": "zh-TW"
}
```

Resolution order: `$MAESTRO_CONFIG_PATH` → `~/.config/maestro-workflow/config.json` → `<plugin>/config/default.json`.

## Tests

| Test | What it covers |
|------|----------------|
| `test/e2e-fallback.sh` | Mock adapters simulate RETURN / SKIP-quota / SKIP-auth; verifies event counts, `policy_pass=true` under lenient + 1 ok, MAGI degraded warning. Token-free. |
| `test/e2e-smoke.sh` | Real CLIs against a one-sentence prompt; verifies preflight + orchestrator + MAGI report end-to-end. Costs a small number of tokens per reviewer. |

Run `bash -n <script>` to syntax-check any shell file.

## Web-domain skills (Phase D)

Four optional add-ons. Each reads its corresponding reference document
under `references/domain/web/<x>.md` (canonical patterns, templates, and
anti-patterns). Skills produce documentation only — they never run apply,
deploy, or commit operations.

| Skill | Output | Reference |
|-------|--------|-----------|
| `/maestro.web.frontend.spec` | Frontend section appended to SPEC.md (component tree, state, a11y checklist, routing/data, perf budget, Playwright test plan); optional `tests/e2e/<feature>.spec.ts` stub | `references/domain/web/frontend.md` |
| `/maestro.web.backend.spec` | Backend section appended to SPEC.md (OpenAPI / SDL contract, data model + migration plan, authn/z matrix, validation rules, observability, contract test plan); optional contract test stub | `references/domain/web/backend.md` |
| `/maestro.web.infra.plan` | `<sprint>/INFRA.md` with Terraform `plan.tfplan` (dry-run only), IAM diff matrix, cost estimate via Infracost, rollback plan with STOP-checklist for irreversible changes | `references/domain/web/infra.md` |
| `/maestro.web.ci.spec` | `<sprint>/CI.md` with stage breakdown, secrets/permissions audit, deployment strategy, smoke tests; draft workflow file inside the sprint dir (never written to live `.github/workflows/`) | `references/domain/web/ci-cd.md` |

Each skill is invoked between `/maestro.plan` (which produces the
high-level SPEC) and `/maestro.tasks` (which decomposes into work
units). They are independent — only invoke the ones a feature actually
touches.

## Out of scope (still pending)

- **Phase E** — team-ready hooks (commit-msg Conventional Commits, pre-commit
  lint), canonical `references/AGENTS.md` for cross-project conventions.
- Plugin marketplace registration — repo is currently consumed via
  `claude plugin add github:howar31/maestro-workflow`.
