---
name: maestro.web.frontend.spec
description: Augment a sprint's SPEC.md with a Frontend section (component tree, state, a11y, routing, performance budget, Playwright e2e plan) tailored to the project's stack (React/Vue/Svelte/Solid/Astro/RN). Coordinator-only — does not write production code. Pauses for user confirmation. Read before /maestro.tasks so the test plan is captured in TASKS.md.
disable-model-invocation: true
---

# /maestro.web.frontend.spec — frontend elaboration

You are the coordinator. Add a frontend-specific section to a sprint's
SPEC.md. **You do not write production code.** Read
`references/domain/web/frontend.md` before starting.

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/maestro-workflow/config.json"
```

If config missing → tell user to run `/maestro.setup`.

## 1. Locate sprint + spec

Find the sprint folder (default: most recent; or `--sprint <num>-<slug>`).
The folder must contain a PLAN.md or SPEC.md. If only PLAN.md exists,
ask the user whether to upgrade to SPEC.md as part of this elaboration.

If no sprint is open, abort and tell the user to run `/maestro.plan` first.

## 2. Detect stack

Read project root for stack signals (see `references/domain/web/frontend.md`,
"Stack discovery" section). Capture:

- Framework (React / Vue / Svelte / Solid / Astro / React Native)
- Language (TS / JS)
- Styling (Tailwind / CSS modules / styled-components / vanilla)
- Routing (file-based vs explicit)
- State management (zustand / redux / pinia / jotai / context)
- Testing (vitest / jest / Playwright / Cypress)
- Build tool (vite / next / nuxt / sveltekit / webpack)

If any of these are ambiguous, ask the user **once** in a consolidated
question. Do not guess — wrong stack guesses produce useless specs.

## 3. Read the existing spec

Read PLAN.md / SPEC.md fully. Identify which features in the spec are
**frontend-relevant** — UI changes, new screens, new interactions, new
state. Out-of-scope items (pure backend, infra) are skipped here.

## 4. Generate the Frontend section

Following the template in `references/domain/web/frontend.md`
("Deliverable" section), produce a Frontend section covering:

- **Stack** (from step 2, confirmed with user)
- **Component tree** — diagram or nested list with one-line responsibilities
- **State & data flow** — where state lives, what re-renders cascade, store choice justification
- **Accessibility checklist** — every item populated; `OPEN` if unknown (do not omit)
- **Routing & data loading** — per-route rendering mode (SSR/CSR/SSG), data deps, SEO meta
- **Performance budget** — initial JS / Core Web Vitals / image strategy
- **Test plan** — unit + component + Playwright e2e (use template from reference)
- **Open questions** — what the spec author could not resolve

Use `output_language` for prose; keep code identifiers and headings in English.

## 5. Append to SPEC.md

Append the section under a top-level `## Frontend` heading. If a Frontend
section already exists (perhaps from an earlier iteration), ask before
overwriting.

```bash
sprint_dir="docs/<num>-<slug>"
# Append the new section to existing SPEC.md
```

## 6. Optional: scaffold the Playwright file

If the project has Playwright configured (or Cypress — adapt template),
offer to scaffold a stub at `tests/e2e/<feature-slug>.spec.ts` (or the
project's existing E2E directory). The stub uses the template in the
reference. Selectors and assertions stay as TODOs for the developer.

Do not create the file without confirming with the user.

## 7. Stop and hand off

Show the user:

- Diff of SPEC.md (the new Frontend section)
- Whether a stub e2e file was created
- Top 3 open questions that need answering before `/maestro.tasks`

Recommend the next step:
- `/maestro.tasks` if SPEC is now complete enough.
- `/maestro.web.backend.spec` etc. if other domains apply to this sprint.
- `/maestro.review-plan` if the user wants multi-model review before tasks.

**Do not run anything else automatically.**

## Argument parsing

- `--sprint <num>-<slug>` — explicit sprint folder.
- `--scaffold-e2e` — auto-create the Playwright stub (skip the confirmation).
- `--no-scaffold` — never create files outside the sprint dir.
- `--stack <react|vue|svelte|solid|astro|rn>` — skip stack detection.

## Conventions

- One Frontend section per SPEC.md. Iterating means editing the same section, not appending duplicates.
- Be honest about uncertainty. `OPEN` is better than a confident wrong answer.
- The accessibility checklist is **mandatory** — never skip it.
- For very small UI changes (e.g., one-line label tweak), this skill is
  overkill. Tell the user it's overkill and let them decide whether to
  proceed.
