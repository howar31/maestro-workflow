---
name: magi.plan
description: Smart entry point for any commit-worthy work. Classifies the request by type (feat/fix/hotfix/refactor/chore/docs/perf/test/style/ci) and scale (trivial/minor/major), then routes to the right artifact (PLAN.md / SPEC.md / TICKET.md / HOTFIX.md / no-artifact). Multi-language semantic classification (zh-TW / en / mixed). User can override via flags or interactive confirm. Bare invocation reads docs/BACKLOG.md Pending entries.
disable-model-invocation: true
---

# /magi.plan — smart dispatcher + feature planning

You are the coordinator (Opus). Classify the user's request, route to the
appropriate artifact, and pause for user confirmation. **You do not write
production code in this skill.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow-workflow/config.json"
```

If `$USER_CONFIG` is missing, tell the user to run `/magi.setup` first.

## 0.4. State preflight + init detection

Run `scripts/shared/detect-state.sh`. `/magi.plan` is allowed in **any**
state (it's how users start work), but check for two early-exit signals:

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
state=$(jq -r .state <<<"$STATE_JSON")
```

- **state=BOOTSTRAP** (no root CLAUDE/README/SPEC at all) → warn the user:
  > Project has not been bootstrapped yet. Run `/magi.init` first to
  > scaffold root docs and `docs/PRD.md` / `docs/TECHSTACK.md` so plans
  > have project context. Continue anyway? (y/n)

  If they say no → exit and let them run `/magi.init`. If yes → proceed
  with whatever inline context they supply.

- **state=INITIALIZED but `docs/PRD.md` or `docs/TECHSTACK.md` missing** →
  same as before (existing §2 prompt to set them up).

## 0.5. Backlog awareness (only when no description argument was given)

If the user invoked `/magi.plan` **without** a description argument (and
without an explicit slug+description form), check for `docs/BACKLOG.md`:

```bash
[[ -f docs/BACKLOG.md ]] && pending=$(awk '/^## Pending/{flag=1;next} /^## /{flag=0} flag && /^- \[ \]/' docs/BACKLOG.md)
```

If `## Pending` has any entries:

1. List them numbered to the user, with their source sprint:
   ```
   Backlog 有 N 項待 promote：
     1. <description>  [from docs/03-foo/DRIFT.md]
     2. <description>  [from docs/04-bar/DRIFT.md]
     ...

   選一項當下個 sprint 起點？(輸入編號 / 輸入新 description / Enter 跳過 backlog)
   ```

2. Branch on user input:
   - **Number** → take that entry's description as the seed for this
     sprint. Continue with §1 below using that description. **After §4
     finishes writing the sprint folder**, edit `docs/BACKLOG.md`:
     - Remove the line from `## Pending`
     - Add to `## Promoted to sprints` (create the section if missing) as:
       ```markdown
       - ~~<description>~~ → `docs/<num>-<slug>/` (<YYYY-MM-DD>)
       ```
   - **Free text** → treat as a normal description argument; **leave
     BACKLOG.md untouched**.
   - **Empty (Enter)** → exit; don't create a sprint. Tell the user "no
     sprint started; backlog left as-is".

If `docs/BACKLOG.md` doesn't exist or `## Pending` is empty, fall through
to "what would you like to plan?" — same as no-arg behavior before this
upgrade.

If the user invoked `/magi.plan "<description>"` with an argument, **skip
this entire section** — don't even read BACKLOG.md. The argument is the
authoritative starting point.

## 0.6. Dispatcher — classify type/scale and route

This is the heart of the dispatcher. Given the user's free-text input,
classify the change and route to the appropriate artifact (or no artifact
at all for trivial chores).

### Step A. Override flags first

If the user passed any of these CLI flags, **skip auto-classification**:

| Flag | Effect |
|------|--------|
| `--type <feat\|fix\|hotfix\|refactor\|chore\|docs\|perf\|test\|style\|ci>` | force type |
| `--scale <trivial\|minor\|major>` | force scale |
| `--artifact <plan\|spec\|ticket\|hotfix\|none>` | bypass type/scale entirely; produce the named artifact |
| `--no-classify` | require explicit `--artifact` (useful for scripts) |

Otherwise proceed to Step B.

### Step B. Auto-classify (LLM semantic; multi-language)

You (Opus) classify the user's description by semantic understanding —
not regex match. The user can write in zh-TW, English, or mixed; you
understand intent regardless of keywords.

**Type detection hints** (illustrative, non-exhaustive):

| Type | Signals |
|------|---------|
| `feat` | "add" / "new" / "implement" / "create" / 新增 / 加入 / 做一個 |
| `fix` | "fix" / "bug" / "broken" / "resolve" / 修正 / 修復 / 解決 |
| `hotfix` | "production" / "urgent" / "critical" / "emergency" / "down" / 緊急 / 失火 / 急救 / 炸了 |
| `refactor` | "rename" / "extract" / "move" / "refactor" / "cleanup" / 重構 / 拆出 |
| `chore` | "upgrade" / "bump" / "update deps" / 升級 / 更新依賴 |
| `docs` | "typo" / "documentation" / "README" / "comment" / 文件 / 註解 |
| `perf` | "performance" / "optimize" / "slow" / "latency" / 效能 / 最佳化 / 慢 |
| `test` | "test" / "spec" / "coverage" / 測試 / 覆蓋率 |
| `style` / `ci` | format / lint only; workflow yaml only |

**Scale detection hints**:

| Scale | Signals |
|-------|---------|
| `trivial` | "small" / "quick" / "just" / "tiny" / "one-line" / 一下 / 小小的 / 一行 |
| `minor` | short description, single file/module, no architecture impact |
| `major` | "across" / "throughout" / "all" / 整個 / 全面 / new service / new dep / multiple files |

### Step C. Route to artifact

| Type \ Scale | Trivial | Minor | Major |
|--------------|---------|-------|-------|
| `feat` | TICKET.md | TICKET.md | PLAN.md / SPEC.md |
| `fix` | none (`/magi.commit` standalone) | TICKET.md | PLAN.md / SPEC.md |
| `hotfix` | HOTFIX.md | HOTFIX.md | HOTFIX.md (always fast-path) |
| `refactor` | none | TICKET.md | SPEC.md (architecture impact) |
| `chore` | none | TICKET.md | TICKET.md |
| `docs` | none | TICKET.md | TICKET.md |
| `perf` | TICKET.md | TICKET.md | SPEC.md |
| `test` / `style` / `ci` | none | TICKET.md | TICKET.md |

PLAN.md vs SPEC.md choice (when major): same as previous logic (§3) —
PLAN for exploratory phase, SPEC when requirements are clear.

### Step D. Confirm with user (interactive override)

Show the classification and let user adjust before any file is written:

```
識別為：feat / minor → 將建立 TICKET.md，路徑 docs/03-search-pagination/TICKET.md

不對？輸入：
  - 修正 type（如 'fix' / 'refactor' / 'hotfix'）
  - 修正 scale（'trivial' / 'major'）
  - 兩者一起改（如 'feat major'）
  - 直接指定 artifact（'plan' / 'spec' / 'ticket' / 'hotfix' / 'none'）
  - Enter 確認
```

Loop until user confirms or specifies an artifact.

### Step E. Branch on chosen artifact

- **`none`** (chore/docs/typo): tell the user no sprint needed; suggest
  `/magi.commit` standalone after their edit. **Exit.**
- **`PLAN.md` / `SPEC.md`**: continue to §1 (sprint folder resolution),
  use existing PLAN/SPEC templates.
- **`TICKET.md`**: continue to §1 + use TICKET.md template (see §3.5).
- **`HOTFIX.md`**: continue to §1 + use HOTFIX.md template (see §3.6).

## 1. Resolve the sprint folder

The convention: every feature lives in `docs/<num>-<slug>/`.

1. If the user supplied a path or slug as an argument prefix (e.g.,
   `/magi.plan profile-page "<details>"`), use it as the slug.
2. Otherwise infer a kebab-case slug from the description (max 4 words).
3. Pick `<num>` as max(existing sprint numbers in `docs/`) + 1, zero-padded
   to 2 digits (e.g. `03-profile-page`). If `docs/` does not exist yet,
   create it and start at `01`.

Confirm the resolved path with the user before creating files.

## 2. Read project-level context

If they exist, read:

- `docs/PRD.md` — product requirements (project-level)
- `docs/TECHSTACK.md` — language, framework, deployment constraints
- `CLAUDE.md` / `AGENTS.md` (root) — project conventions

If none exist, ask the user once whether they want to set up `docs/PRD.md`
and `docs/TECHSTACK.md` first (offer a brief template). If they decline,
proceed with whatever context the user supplies inline.

## 3. Draft the document

Decide between **PLAN.md** and **SPEC.md** based on the request:

- **PLAN.md** — early exploratory phase: still figuring out the right shape;
  many open questions; trade-offs to surface. Loose structure.
- **SPEC.md** — requirements are clear; user wants formal acceptance criteria,
  ADRs, API contracts. Disciplined structure.

If unclear, draft `PLAN.md` and offer to upgrade to `SPEC.md` after review.

### PLAN.md structure

```markdown
# <Feature Name>

## Context
Why this work is being requested. The user need or problem.

## Goals & Non-Goals

## Design options considered
For each option: cost, risk, who-it-helps, who-it-hurts. Recommend one.

## Recommended approach
Explain in enough detail that a reviewer (and future you) can sanity check.
Include code paths, data shape changes, and any new dependencies.

## Open questions
What remains uncertain. The /magi.review-plan step should help resolve.

## Verification
How we will know the implementation is correct.
```

### SPEC.md structure

```markdown
# <Feature Name>

## Context

## User stories / use cases

## Acceptance criteria
Concrete, testable statements.

## Architecture decisions (ADR-style)
- Decision: ...
  - Status: proposed | accepted
  - Context: ...
  - Consequences: ...

## API / Data contracts
Endpoints, payloads, schemas.

## Out of scope

## Verification plan
```

Use `output_language` from the user config (zh-TW by default) for the
document body. Headings can be in English; prose in user's preferred
language.

### 3.5. TICKET.md structure (lightweight contract for minor work)

```markdown
# Ticket — <Title>
> Type: <feat|fix|refactor|chore|docs|perf|test|style|ci>  •  Scale: <minor|major>

## Context
<1-2 sentences: what's the situation, why does this matter>

## Approach
<3-5 sentences: what we'll do, key choices, files affected>

## Verification
<how we'll know it's done; specific test command(s)>
```

Differences from PLAN.md / SPEC.md: no "Design options considered", no
"ADR", no "API contracts" — but TICKET.md is still a contract.
`/magi.review-code` will compare code against TICKET.md the same way it
does against PLAN/SPEC, producing DRIFT.md.

### 3.6. HOTFIX.md structure (urgent fix fast-path)

```markdown
# Hotfix — <one-sentence summary>
> Severity: <critical|high>  •  Reported: <ISO date>

## Repro
<exact steps to reproduce>

## Root cause
<best-current-hypothesis>

## Fix
<what we'll change, file paths>

## Test
<how to verify the fix works AND doesn't regress>

## Rollback plan
<what to do if the fix doesn't work or makes things worse>
```

Hotfix special semantics:
- **Skip /magi.tasks**: HOTFIX is small enough to dispatch directly. The
  hand-off (§5) recommends `/magi.go` instead of `/magi.tasks`.
- **/magi.review-code still mandatory**: produces DRIFT.md against
  HOTFIX.md as the contract — confirms the fix matches the diagnosed
  root cause and didn't expand scope.
- **`/magi.commit` uses `fix:` prefix**, not `hotfix:` (Conventional
  Commits has no `hotfix:` type; `hotfix` is a magi-internal classifier).

## 4. Write the document

```bash
mkdir -p "docs/<num>-<slug>"
# Write PLAN.md or SPEC.md
```

If this sprint was started by **picking a backlog entry** in §0.5, after
the sprint folder is created, also update `docs/BACKLOG.md`:

- Remove the chosen entry's line (and its `> from ...` source line) from
  `## Pending`
- Append under `## Promoted to sprints` (create the section if it doesn't
  exist):
  ```markdown
  - ~~<original description>~~ → `docs/<num>-<slug>/` (<YYYY-MM-DD>)
  ```

After writing, **stop and ask the user to confirm**. Do not auto-trigger
`/magi.review-plan`. The user is the gate.

If the user wants edits, iterate until they confirm.

## 5. Hand-off

When the user confirms the document:

1. **Detect web-domain scope** — scan the drafted PLAN/SPEC + `docs/TECHSTACK.md` (if it exists) for keywords (case-insensitive, match whole words / phrases, not substrings):

   | Domain | Trigger keywords | Suggested skill |
   |--------|-----------------|----------------|
   | Frontend | `react`, `vue`, `svelte`, `angular`, `next.js`, `nuxt`, `astro`, `component`, `UI`, `UX`, `a11y`, `accessibility`, `playwright`, `cypress`, `前端` | `/magi.web.frontend.spec` |
   | Backend | `api`, `rest`, `graphql`, `openapi`, `endpoint`, `database`, `migration`, `schema`, `authn`, `authz`, `jwt`, `oauth`, `後端` | `/magi.web.backend.spec` |
   | Infra | `terraform`, `aws`, `gcp`, `azure`, `kubernetes`, `k8s`, `docker`, `iam`, `infrastructure`, `基礎設施` | `/magi.web.infra.plan` |
   | CI | `ci/cd`, `github actions`, `gha`, `cloud build`, `gitlab ci`, `pipeline`, `workflow`, `deployment`, `部署` | `/magi.web.ci.spec` |

   If **any** domain matches, prompt the user once, listing only the matched domains:

   > 偵測到這個 feature 可能涉及 **[matched domains]**。要不要先補強 SPEC 再進入 review？
   >   - `/magi.web.frontend.spec` — component / a11y / e2e
   >   - `/magi.web.backend.spec` — API contract / migration / authz
   >   - `/magi.web.infra.plan` — terraform plan / IAM diff / cost
   >   - `/magi.web.ci.spec` — pipeline / secrets / deployment
   >
   > 或直接跳過進入 `/magi.review-plan`。

   Skip this entire step if **no** keywords match — do not bother the user with empty prompts.

2. Tell them the next recommended step **based on the artifact produced**
   (this is where the dispatcher routing pays off):

   | Artifact | Recommended next step |
   |----------|-----------------------|
   | `PLAN.md` / `SPEC.md` | `/magi.review-plan` (**optional** — skip to save tokens) → `/magi.tasks` |
   | `TICKET.md` | `/magi.tasks` directly (TICKET is light enough to skip review-plan) |
   | `HOTFIX.md` | `/magi.go` directly (skip both `/magi.tasks` and `/magi.review-plan` — fast-path) |
   | (no artifact, e.g., chore/docs/typo) | `/magi.commit` standalone after your edit |

3. If §1 picked any web add-on (Frontend/Backend/Infra/CI), suggest those
   first, then continue to the appropriate next step from the table above.

4. Always mark `/magi.review-plan` as **optional** in the hand-off message
   and `/magi.review-code` as **mandatory** wherever it appears.

5. Do not run anything automatically — every next skill needs the user's explicit slash command.

## Conventions

- One artifact per feature: pick exactly one of PLAN.md / SPEC.md /
  TICKET.md / HOTFIX.md (or none). Upgrade in place (rename) if scale
  changes during work.
- Filenames are uppercase: `PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md`,
  `TICKET.md`, `HOTFIX.md`, `DRIFT.md`.
- Never modify a previous sprint's docs without the user's explicit instruction.
- Don't assume tools / frameworks; read TECHSTACK.md or ask.
- Trivial chores (typo / formatting / single-line fixes) shouldn't get a
  sprint folder at all — the dispatcher routes them to `/magi.commit`
  standalone directly.

## Argument parsing

The command form:
- `/magi.plan` (no args) — backlog-aware mode (see §0.5). Lists `## Pending`
  entries from `docs/BACKLOG.md`; user picks one or types a new
  description.
- `/magi.plan "<description>"` — direct mode. Plans the described feature;
  **does not read or modify BACKLOG.md**.
- `/magi.plan <slug> "<description>"` — direct mode with explicit slug.

Flags:

- `--model <name>` — override Coordinator model for this invocation
  (rarely needed; main session model is the default).
- `--into docs/<existing-num>-<slug>/` — write into an existing sprint
  folder instead of creating a new one (use sparingly; meant for plan
  iteration on the same feature).

**Dispatcher overrides** (skip auto-classification):

- `--type <feat|fix|hotfix|refactor|chore|docs|perf|test|style|ci>` — force a specific type
- `--scale <trivial|minor|major>` — force a specific scale
- `--artifact <plan|spec|ticket|hotfix|none>` — bypass type×scale and produce the named artifact directly (or none)
- `--no-classify` — require explicit `--artifact` (CI/script-friendly mode; refuses to guess)
- `--force` — skip §0.4 BOOTSTRAP warning
