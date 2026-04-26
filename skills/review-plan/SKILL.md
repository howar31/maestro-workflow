---
name: review-plan
description: Run a multi-CLI MAGI review of a sprint's PLAN.md / SPEC.md. **Optional step** — can be skipped to save tokens if you trust the plan; human review of the doc is a valid alternative. Spawns reviewers in parallel via the orchestrator, then applies semantic dedup + weighted voting per references/MAGI_VOTING.md. Default reviewers and voting mode come from ~/.config/magi-workflow/config.json. Override with --reviewers and --magi.
disable-model-invocation: true
---

# /magi:review-plan — MAGI plan review

You are the coordinator. Have N CLIs review the user's PLAN/SPEC in parallel,
then consolidate their findings using MAGI weighted voting.

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

Run a lightweight preflight; if `$USER_CONFIG` missing or empty
`xreview.reviewers`, tell the user to run `/magi:setup`.

Read `references/MAGI_VOTING.md` (in the plugin root) for the consensus
rules. You will follow Steps 1–8 of that document.

## 0.5. State preflight (auto-refuse if not allowed)

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["review-plan"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["review-plan"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["review-plan"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:review-plan: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

`--force` skips preflight. **Note this skill is optional** — the user can
always skip it entirely by going straight to `/magi:tasks`.

## 1. Locate the document

Find the sprint folder (same logic as `/magi:tasks`). Read its `PLAN.md`
or `SPEC.md`. If neither exists, abort and tell the user to run
`/magi:plan` first.

## 2. Build the reviewer prompt

Write a prompt file at `<sprint_dir>/.xreview-prompt.md` (use `.gitignore`
if needed) containing:

```
You are reviewing a software engineering plan. Apply skepticism and
domain expertise. Your output must be structured for downstream
consensus aggregation.

[Project context]
- TECHSTACK: see magi/TECHSTACK.md (read it)
- Conventions: see CLAUDE.md / AGENTS.md (read if available)

[Document under review]
<full content of PLAN.md or SPEC.md, with file path header>

[Your task]
Identify issues. For each issue, output a section in this format:

  ## Issue: <one-line subject>
  Severity: Critical | Important | Note
  Where: <file:line or section>
  Description: <2–6 sentences>
  Suggested fix: <1–3 sentences>

Then end with:

  ## Verdict
  <one of: APPROVE | APPROVE-WITH-NITS | REQUEST-CHANGES>
  <one paragraph rationale>

Do not produce any other output sections. Do not edit files.
```

## 3. Argument parsing

- `--reviewers <cli:model>[,<cli:model>...]` — override the reviewer list
  for this run. Empty list falls back to config.
- `--magi <mode>` — override `magi.mode` for this run
  (`majority` / `supermajority` / `unanimous` / `threshold:<N>`).
- `--workdir <path>` — reuse an existing orchestrator workdir (skip the
  fan-out, just re-run consensus). Useful for iterating on the consensus
  prompt.

## 4. Invoke the orchestrator

```bash
WORKDIR=$(mktemp -d -t magi-review.XXXXXX)
MAGI_REVIEW_WORKDIR="$WORKDIR" \
  "$PLUGIN_ROOT/skills/review-plan/scripts/orchestrator.sh" \
  "$prompt_file" \
  $reviewer_args   # optional <cli:model> ... from --reviewers
```

The orchestrator emits an event stream on stdout. Stream it to the user as
status updates. Capture the WORKDIR path from the first event.

If `policy_pass=false`:

- If a `required: true` reviewer failed → tell the user the cause and
  abort (e.g., claude failed → check `claude login`).
- If only optional reviewers failed → continue (degraded MAGI is allowed).

## 5. Run consensus aggregation

```bash
"$PLUGIN_ROOT/scripts/shared/magi-consensus.sh" "$WORKDIR" \
  ${magi_override:+--mode "$magi_override"}
```

This produces `<workdir>/magi-report.md` and `<workdir>/magi-report.json`.
**This is mechanical aggregation, not the final vote.**

## 6. Apply MAGI rules (this is your real job)

Open `magi-report.json`. Follow `references/MAGI_VOTING.md`:

1. Read every successful reviewer's `final.txt`.
2. Extract issues per reviewer.
3. Semantically dedup across reviewers (be conservative).
4. Compute `vote_sum` per merged issue.
5. Apply the configured (or overridden) rule against `ok_weight`.
6. Classify: 🔴 Critical / 🟡 Important (adopted) vs 🟢 Note (minority).
7. Surface degraded-mode warnings prominently.

## 7. Write the consolidated report

Write to `<sprint_dir>/MAGI_PLAN_REVIEW.md` in `output_language`:

```markdown
# 🧠 MAGI Plan Review — <Feature Name>

**Sprint:** magi/<num>-<slug>/ • **Document:** PLAN.md | SPEC.md
**Mode:** <mode>  •  **OK weight:** <ok_weight> / <total_weight>
**Threshold:** <threshold_value>  •  **Degraded:** yes | no

## Verdict
<APPROVE | APPROVE-WITH-NITS | REQUEST-CHANGES>
Reasoning ...

## 🔴 Critical (adopted)
- [vote: 4/4 — claude(2) + gemini(1) + codex(1)] <issue subject>
  - Where: <file:line>
  - Suggested fix: ...
  - Reviewer details: ...

## 🟡 Important (adopted)
...

## 🟢 Minority
- [vote: 1/4 — codex(1) only] <issue>
  - Reviewer text: ...

## ⚠️ Degraded mode (if applicable)
<short explanation of what was missing>
```

Then summarise to the user in chat: top 3 adopted issues + verdict.

## 8. Hand-off

Tell the user (in `output_language`):

- If verdict = APPROVE → suggest `/magi:tasks` (if TASKS.md doesn't exist)
  or `/magi:go` (if it does).
- If verdict = APPROVE-WITH-NITS → list nits, ask whether to address
  before `/magi:tasks` or defer.
- If verdict = REQUEST-CHANGES → suggest user revise PLAN/SPEC, then
  re-run `/magi:review-plan` (which will overwrite `MAGI_PLAN_REVIEW.md`).

Example output:

```
✅ Verdict: APPROVE-WITH-NITS

下一步：
  /magi:tasks         (拆 milestones + 任務清單)
```

Do not auto-trigger anything.

## Conventions

- Always read `references/MAGI_VOTING.md` before classifying.
- Be **conservative** in semantic dedup: when two issues are unclear, keep
  them separate.
- Show minority issues — they are not noise; they are signal that one
  reviewer noticed something others missed.
- If MAGI mode is `unanimous` and degraded, **abort and surface clearly** —
  do not silently produce a verdict on degraded data.
- The workdir contains raw transcripts; offer them to the user if they want
  to inspect a specific reviewer's reasoning.
