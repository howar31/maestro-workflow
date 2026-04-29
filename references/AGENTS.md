# AGENTS.md — canonical guidelines for magi-workflow

This file is the single source of truth for how the coordinator and
subagents operate inside a user's project. Every skill SKILL.md should
read this before doing non-trivial work. **English only.**

If a user's own `CLAUDE.md` or `AGENTS.md` (in their project root)
contradicts something here, the **user's file wins** — it is the local
override.

## 1. Model routing

The plugin uses three model classes; the right one for the right job:

| Job | Model class | Why |
|-----|-------------|-----|
| Coordinator (main session) — planning, dispatching, validating, applying MAGI rules | **Opus-class** | Deep reasoning, large context, judgement calls. |
| `magi-developer` subagent — TDD implementation | **Sonnet-class** | Fast, cheap, strong at structured code work. |
| `magi-reviewer` subagent — single-reviewer fallback | **Opus-class** | Defensive review needs reasoning. |
| Multi-CLI MAGI reviewers (claude / gemini / codex) | per CLI flagship | Independent perspectives; each CLI's strongest model. |

### When to override

- Bump `magi-developer` to **Opus** via `/magi:go --model opus`
  when the task involves multi-module refactors, intricate algorithm work,
  or the developer reported BLOCKED citing complexity on first dispatch.
- Drop the multi-CLI MAGI to single-Opus via `/magi:review-code --single`
  when iterating quickly on tiny diffs and saving tokens matters.

Never hard-code a specific model version (e.g. `claude-opus-4-7`). Use the
short class name (`opus`, `sonnet`) so the plugin keeps working when new
versions release.

## 2. Coding standards (defaults if project is silent)

Always read the user's project conventions first
(`<project-root>/CLAUDE.md`, `<project-root>/AGENTS.md`, `.editorconfig`,
`tsconfig.json`, language-specific configs). The defaults below apply
**only** when those are missing or silent.

### Language-agnostic

- **Format**: rely on the project's formatter (`prettier`, `ruff format`,
  `gofmt`, `cargo fmt`). If none, do not introduce one as a side effect.
- **Line length**: respect `.editorconfig` if present; otherwise stay
  consistent with neighbouring files.
- **Comments**: write **why**, not what. Skip obvious comments.
- **Test names**: describe behaviour ("should reject empty email"),
  not implementation ("calls validateEmail").
- **No commented-out code** — git history exists.

### TypeScript / JavaScript

- ESM modules (`import` / `export`) unless the project is CJS-only.
- Strict TS: no `any` without justification; prefer `unknown` + narrowing.
- Functions over classes for stateless work; classes only for things with
  identity / lifecycle.
- Pure functions in libs; side effects pushed to edges.
- File naming: kebab-case (`user-profile.ts`).
- Identifier naming: `camelCase` for vars/funcs, `UpperCamelCase` for
  classes/types, `SCREAMING_SNAKE` for constants.
- Avoid barrel files (`index.ts` re-exporting) unless the project already
  uses them — they hurt tree-shaking.

### Python

- 3.11+ if the project allows.
- `ruff` for lint+format if available; else `black` + `flake8`.
- Type hints on every public function.
- `pathlib` over `os.path` for new code.
- `pytest` over `unittest` unless the project commits to unittest.
- Keep module-level side effects out (no work in `__init__.py` beyond
  imports).

### Go

- `go fmt` / `goimports` mandatory.
- Idiomatic naming: short receivers (`u *User`), exported = capitalised,
  errors as last return value.
- Avoid `interface{}` / `any`; prefer concrete types or generics (Go 1.18+).
- Return errors, never panic in libraries.
- Context propagation: every IO function takes `ctx context.Context` first.

### Bash

- `set -uo pipefail` at top. Avoid `set -e` — explicit `|| rc=$?` is
  clearer for orchestration.
- Bash 3.2 compatible (macOS default): no `mapfile`, `readarray`,
  `declare -A`, `${var^^}`.
- All variables quoted: `"$var"`.
- Initialise arrays before indexed access (`arr=()`).

## 3. Commit conventions

The plugin **never auto-commits**. When a user asks the coordinator to
commit, follow these rules:

### Format

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

`<type>` is one of:

- `feat` — new feature
- `fix` — bug fix
- `docs` — documentation
- `refactor` — code restructure, no behaviour change
- `perf` — performance improvement
- `test` — tests only
- `build` — build system / dependencies
- `ci` — CI config
- `chore` — boring maintenance
- `revert` — revert a previous commit

`<scope>` is optional but useful for monorepos (e.g. `feat(auth): ...`).

`<subject>` is imperative, lowercase, no trailing period, ≤ 72 chars.

`<body>` (when needed) explains the WHY. Wrap at ~72 chars. Bullet lists
allowed.

`<footer>` may include `BREAKING CHANGE:`, `Refs: #123`, `Co-Authored-By:`.

### Coordinator behaviour

- One feature = one commit. Do not split a feature across multiple commits
  unless the user asks.
- Documentation updates that accompany code changes go in the **same
  commit** as the code, not a follow-up.
- Never use `git commit --amend` on commits that may have been pushed.
- Never use `--no-verify` to skip hooks.
- Never sign commits as the user without their consent.

### Co-author trailer

When code was AI-assisted, append:

```
Co-Authored-By: Claude <model> <noreply@anthropic.com>
```

…where `<model>` is the model name visible in the session (e.g.
`Opus 4.7 (1M context)`). Do this once per commit, not per file.

## 4. Tool preferences

When choosing between equivalent tools, prefer:

| Task | Preferred | Fallback |
|------|-----------|----------|
| Node package manager | `pnpm` | `npm` (only if project uses it) |
| Python package / venv | `uv` | `pip` + `venv` |
| Search code | `rg` (ripgrep) | `grep` |
| Find files | `fd` | `find` |
| JSON | `jq` | python `json.tool` |
| YAML | `yq` | python `yaml` |
| HTTP | `curl` | `wget` |
| Process | structured logs (`jq`) | grep on text |

Always honour what the project actually uses. Do not introduce a new tool
just because it is preferred — surface the preference as a "Note" but
follow the project's existing toolchain.

## 5. When to ask vs when to act

### Ask before

- Deleting any file the user did not explicitly mark for deletion.
- Running `terraform apply`, `kubectl apply`, `gcloud ... create/delete`,
  or any non-dry-run cloud mutation.
- `git push`, `git push --force`, `git rebase` of pushed branches.
- Opening a PR (`gh pr create`).
- Sending a message to Slack / Discord / email / external API.
- Installing a new dependency.
- Modifying `.git/`, `.gitignore`, or hook scripts the user installed.
- Running anything that touches `~/.ssh`, `~/.kube`, `~/.config/gcloud`.

### Act without asking

- Reading any file in the project.
- Running tests, lints, type-checks, formatters in dry-run / check mode.
- Running `git status` / `git diff` / `git log`.
- Creating files inside the sprint dir (`magi/<num>-<slug>/`) — this is
  scratch space the workflow owns.
- Spawning a subagent dispatch via the Task tool, when the slash command
  expects it.

### Special: hooks

If the project has git hooks (`.git/hooks/*`), do not bypass them. If a
hook fails, surface the cause and let the user decide. Never `--no-verify`.

## 6. SSOT discipline

A sprint's `magi/<num>-<slug>/` folder is the single source of truth for
that feature. It owns:

- `PLAN.md` — early exploration, options, recommendations
- `SPEC.md` — formal spec with ADRs and acceptance criteria
- `TASKS.md` — milestones and atomic tasks
- `WORKS.md` — append-only journal of decisions made during execution
- `INFRA.md` (when infra changes) — Terraform plan, IAM diff, cost
- `CI.md` (when pipeline changes) — stages, secrets, deployment strategy
- `MAGI_PLAN_REVIEW.md`, `MAGI_CODE_REVIEW.md` — multi-model verdicts

Any change to the feature flows through these documents. Code changes
without a corresponding `WORKS.md` entry are an anti-pattern (the
journal exists so future you can answer "why did we do it this way?").

### Spec deltas (declared root-doc contract)

`PLAN.md` and `SPEC.md` carry a `## Spec deltas` section declaring which
**project-level living documents** (root `SPEC.md` / root `CLAUDE.md` /
`magi/PRD.md` / `magi/TECHSTACK.md`) the sprint expects to modify. The
section has four fixed subheadings; if no modification is planned, write
`(none)` under the subheading rather than omitting it.

This is the sprint's outward-facing contract:
- `/magi:review-plan` reviewers evaluate whether declared modifications
  are justified, complete, and non-conflicting with existing contracts.
- `/magi:commit` (sprint mode) verifies the declarations against the
  actual diff. Missing modifications (D1) and undeclared modifications
  (D2) trigger interactive prompts; matched declarations (D3) pass
  silently.

`TICKET.md` and `HOTFIX.md` deliberately omit `## Spec deltas` — they
are scoped below the project-doc tier. Root-doc changes from those
artifacts (rare) flow through `/magi:commit`'s Level 1 heuristic only.

Spec deltas are **prospective** (declared at plan time); `DRIFT.md` is
**retrospective** (detected at code-review time). The two are
complementary: deltas declare intent for project-level docs, drift
detects deviation against the per-sprint contract.

## 7. Decision points and pauses

The plugin pauses for user confirmation at every gate. **Never skip a
gate.** The user is the final authority on:

- PLAN approval (after `/magi:plan`)
- TASKS approval (after `/magi:tasks`)
- MAGI verdict acceptance (after `/magi:review-plan` or `/magi:review-code`)
- Implementation acceptance (after each `/magi:go` batch)
- Commit decision

If a slash command is interrupted mid-flow, leave the artefacts in place
(prompt files, workdirs, partial PLAN.md) so the user can resume.

## 8. Output language

The plugin outputs human-facing text in `config.output_language` (default
`zh-TW`). Internal text stays in English:

- All SKILL.md / agent system prompts: English.
- `references/**`: English.
- Code identifiers, file paths, command names: English.
- Prose in PLAN.md / SPEC.md / TASKS.md / WORKS.md / MAGI reports: in
  user's preferred language (zh-TW by default, configurable).
- Commit messages: English subject; body may be bilingual or in user's
  language if the project convention allows.

## 9. What this plugin does not do

To set expectations and avoid scope creep:

- Does not auto-commit or push code.
- Does not apply Terraform, deploy services, run migrations, or rotate
  secrets.
- Does not auto-fix issues found in code review — surfaces them for
  human decision.
- Does not access third-party services beyond the configured CLIs
  (claude / gemini / codex).
- Does not learn from the user's data — every invocation is stateless
  beyond `~/.config/magi-workflow/config.json`.

## 10. Failure modes and what to do

| Symptom | What to do |
|---------|------------|
| `~/.config/magi-workflow/config.json` missing | Tell user to run `/magi:setup`. |
| A required reviewer (claude) failed | Abort the review; surface the cause (auth? quota? missing CLI?). |
| Optional reviewers all failed | Continue in degraded mode; warn loudly. |
| Subagent reported BLOCKED | Surface to user; do not silently retry. |
| Tests fail after `magi-developer` reported DONE | Treat as regression; do not silently fix; ask user. |
| Workflow file already exists at the live path during `/magi:web-ci-spec` | Write the draft to the sprint dir only; never overwrite live workflows. |
| User asks for a commit before `/magi:review-code` finished | Tell them review is incomplete; ask whether to skip review (defaults to no). |

## 11. Versioning and updates to these guidelines

Update this file alongside any change to skill behaviour. Reviewer
agents and the coordinator look here first; an outdated AGENTS.md
silently misleads them.

When in doubt: **read the SKILL.md, then read AGENTS.md, then ask.**
