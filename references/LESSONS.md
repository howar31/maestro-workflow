# magi-workflow LESSONS

Empirical pitfalls observed in real magi-workflow sessions. One line per
entry. Add only after a real incident, never theoretical entries.

Format:
- **[skill]** Trigger phrase → Required behavior. _(YYYY-MM-DD, commit-sha)_

---

## /magi:plan

- **[plan]** Path to created artifact buried in paragraph → Show path on its own line (`📄 Plan written to:`) after file write and again in hand-off. _(2026-05-01)_

## /magi:tasks

_(no entries yet)_

## /magi:go

- **[go]** LLM stops after every 1-2 tasks asking "should I continue?" → Run all tasks within a milestone without pausing; only stop at milestone boundaries, BLOCKED, or hard gates. See §6.5 continuation policy. _(2026-05-01)_
- **[go]** Developer subagent returns "stream idle timeout" → Transient API error. Auto-retry once (§4.5) before reporting BLOCKED. _(2026-05-01)_

## /magi:review-plan

- **[review-plan]** Users run 3+ review rounds with diminishing returns → Add round awareness; after round 2, strongly suggest proceeding. Distinguish architectural vs implementation-detail issues for re-review. _(2026-05-01)_
- **[review-plan]** "Vanilla TS is fine" passes review but fails at spike → Add feasibility assessment dimension; flag unvalidated effort/complexity assumptions as spike candidates. _(2026-05-01)_

## /magi:review-code

_(no entries yet)_

## /magi:commit

_(no entries yet)_

## General

- **[web-*]** web-frontend-spec tries to rename PLAN.md to SPEC.md when no SPEC.md exists → Append to whichever plan-equivalent exists; never rename. _(2026-05-01)_
- **[general]** Options presented as inline text invisible to user → Use AskUserQuestion tool for interactive choices. _(2026-05-01)_
- **[general]** disable-model-invocation on help/init causes "I can't invoke myself" messages → Remove flag from read-only/idempotent skills (status, help, init). _(2026-05-01)_
