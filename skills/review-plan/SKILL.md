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

[Special focus — Spec deltas section]
If the document under review contains a `## Spec deltas` section
declaring modifications to project-level living documents (root SPEC.md,
root CLAUDE.md, magi/PRD.md, magi/TECHSTACK.md), evaluate it critically:

- Are the declared modifications justified by the design described above?
- Are there obvious omissions — impacts the design implies but no delta
  lists (e.g., the plan adds a CLI flag but does not declare a delta to
  the SPEC.md flag table)?
- Does any declared modification break a contract documented elsewhere
  in the targeted file (e.g., contradicting an existing ADR)?

Surface delta-related concerns as standard `## Issue:` blocks and prefix
the subject with `[deltas]` so downstream consensus aggregation can
group them. If the deltas look correct, do not invent issues — silence
is a valid signal.

If `## Spec deltas` is missing entirely from a PLAN.md or SPEC.md, raise
one Important `[deltas]` issue saying so. (TICKET.md and HOTFIX.md never
contain this section — do not raise the issue against those.)

[Feasibility assessment]
Examine the plan for assumptions about development effort, complexity, or
tool/framework ergonomics that have not been validated by prototype or
prior experience. Examples:
- "vanilla TS state management is sufficient" — has this been prototyped?
- "migration will take ~2 hours" — based on what evidence?
- "no external dependencies needed" — are there hidden complexities?

For each such assumption, output:

  ## Spike candidate: <one-line assumption>
  Risk: <what could go wrong if this assumption is false>
  Validation: <how to validate — small prototype, benchmark, or PoC>

If no feasibility assumptions need validation, write:
  ## Spike candidates
  (none identified)
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

## Dashboard

```
┌─────────────────────────────────────────────────┐
│  VERDICT: <APPROVE | APPROVE-WITH-NITS | ...>   │
├─────────────────────────────────────────────────┤
│  Mode: <mode>        Threshold: <value>         │
│  OK weight: <ok> / <total>    Degraded: <y/n>   │
├─────────────────────────────────────────────────┤
│  <✅|❌> claude  <✅|❌> gemini  <✅|❌> codex  │
├─────────────────────────────────────────────────┤
│  🔴 Critical: <N>    🟡 Important: <N>         │
│  🟢 Minority: <N>    🔬 Spikes: <N>            │
└─────────────────────────────────────────────────┘
```

Generate this box dynamically using the actual values. Adjust column
widths to fit the content.

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

## 🔬 Spike candidates
- [flagged by: <reviewers>] <assumption>
  Risk: ...
  Validation: ...

## ⚠️ Degraded mode (if applicable)
<short explanation of what was missing>
```

Then summarise to the user in chat: include a condensed version of the
Dashboard box (verdict + issue counts on 2-3 lines), followed by the top
3 adopted issues.

## 7.5. Re-review guidance (round awareness + severity triage)

### Round tracking

Check whether a previous `MAGI_PLAN_REVIEW.md` exists for this sprint
(the current run overwrites it, but its presence before overwrite signals
a prior round). Also check WORKS.md or git history for earlier review
references. If this is a repeated review on the same document version,
track the round number.

General guidance:
- **Round 1**: normal review. All issue severities warrant attention.
- **Round 2**: focus on whether round-1 Critical/Important issues were
  addressed. New issues are fine to raise.
- **Round 3+**: tell the user explicitly: "This is round 3+. Repeated
  review rounds have diminishing returns. Consider proceeding to
  `/magi:tasks` unless there are unresolved Critical issues."

### Severity-based re-review recommendation

When the verdict is REQUEST-CHANGES, classify whether the issues are:

**(a) Architectural / structural** — fundamentally changes the design
shape, API contracts, data model, or dependency choices. These warrant
PLAN/SPEC revision followed by re-review.

**(b) Implementation-detail level** — naming, error handling strategy,
test approach, logging format. These should be recorded in the PLAN as
`## Implementation notes` (append section) for the developer to follow
during `/magi:go`, but do NOT require a full re-review cycle.

Apply this classification in §8 hand-off below.

## 8. Hand-off

Tell the user (in `output_language`). When presenting multiple actionable
choices, use the **AskUserQuestion** tool so the options appear interactively:

- If verdict = APPROVE → suggest `/magi:tasks` (if TASKS.md doesn't exist)
  or `/magi:go` (if it does).
- If verdict = APPROVE-WITH-NITS → list nits, ask whether to address
  before `/magi:tasks` or defer.
- If verdict = REQUEST-CHANGES → apply §7.5 severity triage:
  - If only (b)-type issues remain → recommend: "Record these as
    Implementation notes and proceed to `/magi:tasks`."
  - If any (a)-type issues remain → recommend: "Revise PLAN/SPEC to
    address the architectural concerns, then re-run `/magi:review-plan`."
  - If round >= 3 and only (b)-type remain → strongly recommend
    proceeding: "已超過兩輪 review，剩餘皆為實作細節，建議直接進入
    `/magi:tasks`。"

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
