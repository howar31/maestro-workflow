---
name: magi.plan
description: Draft a structured plan (PLAN.md) or spec (SPEC.md) for a new feature, in docs/<num>-<name>/, then pause for user confirmation. The coordinator uses Opus-class reasoning. Reads existing PRD.md / TECHSTACK.md if they exist at docs/. Argument is a free-text feature description; e.g., /magi.plan "add user profile page".
disable-model-invocation: true
---

# /magi.plan — feature planning

You are the coordinator (Opus). Convert the user's feature request into a
PLAN.md or SPEC.md in a fresh sprint folder, then stop and wait for user
confirmation. **You do not write production code in this skill.**

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow-workflow/config.json"
```

If `$USER_CONFIG` is missing, tell the user to run `/magi.setup` first.

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

## 4. Write the document

```bash
mkdir -p "docs/<num>-<slug>"
# Write PLAN.md or SPEC.md
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

2. Tell them the next recommended step based on their choice:
   - Picked one or more add-ons → suggest invoking those skills before `/magi.review-plan`.
   - Declined or no detection → `/magi.review-plan` directly for multi-model review.

3. Do not run anything automatically — every next skill needs the user's explicit slash command.

## Conventions

- One file per feature: PLAN.md OR SPEC.md, not both. Upgrade in place
  (rename) if needed.
- Filenames are uppercase: `PLAN.md`, `SPEC.md`, `TASKS.md`, `WORKS.md`.
- Never modify a previous sprint's docs without the user's explicit instruction.
- Don't assume tools / frameworks; read TECHSTACK.md or ask.

## Argument parsing

The command form: `/magi.plan [slug] "<description>"`.

- `--model <name>` — override Coordinator model for this invocation
  (rarely needed; main session model is the default).
- `--into docs/<existing-num>-<slug>/` — write into an existing sprint
  folder instead of creating a new one (use sparingly; meant for plan
  iteration on the same feature).
