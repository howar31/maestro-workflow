# MAGI Voting Reference

Canonical rules for the coordinator agent when consolidating multi-reviewer
output into a final verdict. Read this once at the start of any
`/maestro.xreview-plan` or `/maestro.review` invocation.

## Inputs

After the orchestrator + magi-consensus.sh finish, you have:

- `<workdir>/magi-report.md` — human-readable view (already includes per-reviewer
  text, weights, mode, threshold).
- `<workdir>/magi-report.json` — machine-readable structure with the same data.
- `<workdir>/<cli>-<model>.final.txt` — each successful reviewer's full output.

The shell script does **mechanical** aggregation. Semantic deduplication and
the final vote are **your job** — that is why a coordinator LLM is in the loop.

## Step 1 — Read the structure

Open `magi-report.json` and extract:

- `magi.mode` — voting mode (`majority` / `supermajority` / `unanimous` / `threshold`)
- `magi.threshold_value` — numeric threshold the vote_sum must clear
- `magi.total_weight_configured` and `magi.ok_weight`
- `magi.degraded` — true if any reviewer skipped/failed
- `reviewers[]` — list of `{key, status, weight, final}` entries

## Step 2 — Identify issues per reviewer

For each `status: "ok"` reviewer, read its `final` text and extract a list of
discrete issues. An "issue" is a concrete observation the reviewer wants the
team to act on (a bug, a risk, a style violation, a missing test, etc.).

For each issue capture:

- **subject** — short summary (1 line)
- **severity hint** — Critical / Important / Note (use the reviewer's wording
  if any; otherwise infer from tone)
- **evidence** — file path, line range, or quoted code if the reviewer cited it
- **raw text** — the verbatim paragraph(s)

## Step 3 — Semantic deduplication across reviewers

Two issues from different reviewers refer to the **same underlying problem**
when at least one of these holds:

- Both cite the same file path AND function/region.
- Both describe the same observable defect (e.g. "missing input validation on
  POST /users" vs. "no schema check on user-create endpoint").
- Both propose substantively the same fix.

Be **conservative**: when in doubt, treat them as **different** issues. It is
worse to over-merge (and silently drop a real concern) than to under-merge
(which only produces a slightly noisier report).

## Step 4 — Compute vote_sum per merged issue

For each merged issue, sum the **weights** of every reviewer who raised it.
A reviewer who did not raise the issue contributes 0.

## Step 5 — Apply the configured rule

| Mode | Adopt issue if |
|------|----------------|
| `majority` | `vote_sum > ok_weight × 0.5` |
| `supermajority` | `vote_sum >= ok_weight × 2/3` |
| `unanimous` | `vote_sum == ok_weight` (all OK reviewers agreed) |
| `threshold` | `vote_sum >= magi.threshold_value` |

Note: thresholds use **`ok_weight`** (sum of successful reviewers' weights),
not `total_weight_configured`. This is how degraded mode adapts: with one
reviewer missing, the threshold scales down.

## Step 6 — Classify

- ✅ **Adopted** (`vote_sum` clears the rule): surface to the user.
  - 🔴 **Critical**: reviewer-marked Critical OR severity is high
    (security, data loss, broken contract) AND adopted.
  - 🟡 **Important**: adopted but not Critical.
- 🟢 **Minority**: raised by some reviewer(s) but did not clear the rule.
  Keep in the report under a separate section so the user can still see them,
  but do not act on them automatically.

## Step 7 — Special cases

- **Unanimous mode + degraded**: if `magi.degraded` is true and
  `magi.mode` is `unanimous`, **abort** the review and tell the user the
  configuration requires all reviewers but only some succeeded.
- **Single OK reviewer**: when `ok_weight` corresponds to only one reviewer,
  output a clear `⚠️ MAGI degraded to single-reviewer` banner. Every issue
  the lone reviewer raises auto-passes the rule (vote_sum = its weight =
  ok_weight = threshold), so the user must understand there was no
  cross-validation.
- **Required reviewer failed**: if any reviewer with `required: true` is not
  ok (per orchestrator policy_pass=false), abort and tell the user.

## Step 8 — Present the verdict

Always include in the user-facing report:

1. A header line stating the mode, ok_weight, threshold value, and degraded
   status if applicable.
2. The 🔴 / 🟡 adopted issues, with which reviewers agreed (and their weights).
3. A 🟢 minority section.
4. The pass/fail recommendation: should the work proceed (no critical
   adopted) or is iteration required (any critical adopted)?

Keep the output language consistent with `config.output_language`
(default `zh-TW`).

## Anti-patterns

- ❌ Trusting `magi-report.md` alone — it does not vote.
- ❌ Letting one high-weight reviewer's solo issue pass `majority`. The weight
  system is designed so that even a high-`weight` reviewer needs at least
  one other voice to clear the threshold (see range examples in SPEC.md).
- ❌ Hiding minority issues — show them, just below the adopted ones.
- ❌ Glossing over degraded mode — surface it loudly.
