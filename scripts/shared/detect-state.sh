#!/usr/bin/env bash
# Project state detector for magi-workflow.
#
# Computes the project's current state from filesystem inspection and emits
# a structured JSON report on stdout. Never persists state to disk; each
# invocation re-derives from filesystem so state automatically tracks
# git checkouts and manual edits.
#
# This is the single source of truth for:
#   - which of 8 states the project is in
#   - which magi-workflow skills are allowed/disallowed in this state
#   - staleness warnings (review artifacts older than their inputs)
#
# Each magi.* SKILL.md preflight calls this script and inspects
# .disallowed_skills["<self>"] before proceeding.
#
# Usage:
#   detect-state.sh                    # detect latest sprint
#   detect-state.sh --sprint <slug>    # detect specific sprint folder
#
# Output: JSON on stdout
# Exit:   0 success (any state); 2 fatal (not in git repo, etc.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────
SPRINT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sprint) shift; SPRINT_OVERRIDE="${1:-}"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── Locate repo root ──────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo '{"error":"not a git repository","state":"UNKNOWN"}'
  exit 2
}
cd "$REPO_ROOT" || exit 2

# ── File existence helpers ────────────────────────────────────────────────
file_exists() { [[ -f "$1" ]] && echo true || echo false; }

# ── Tier 1 / Tier 2 detection ─────────────────────────────────────────────
ROOT_CLAUDE=$(file_exists "CLAUDE.md")
ROOT_README=$(file_exists "README.md")
ROOT_SPEC=$(file_exists "SPEC.md")
DOCS_PRD=$(file_exists "docs/PRD.md")
DOCS_TECHSTACK=$(file_exists "docs/TECHSTACK.md")
DOCS_BACKLOG=$(file_exists "docs/BACKLOG.md")

# ── Locate sprint folder (latest by num, or override) ─────────────────────
SPRINT_DIR=""
if [[ -n "$SPRINT_OVERRIDE" ]]; then
  if [[ -d "docs/$SPRINT_OVERRIDE" ]]; then
    SPRINT_DIR="docs/$SPRINT_OVERRIDE"
  fi
else
  # Find latest docs/<num>-<slug>/ by sorting numeric prefix
  if [[ -d "docs" ]]; then
    SPRINT_DIR=$(find docs -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9]-*' 2>/dev/null \
      | sort -r | head -1)
  fi
fi

# ── Tier 3 (sprint) file detection ────────────────────────────────────────
SPRINT_PLAN=false
SPRINT_SPEC=false
SPRINT_TICKET=false
SPRINT_HOTFIX=false
SPRINT_TASKS=false
SPRINT_WORKS=false
SPRINT_DRIFT=false
SPRINT_PLAN_REVIEW=false

if [[ -n "$SPRINT_DIR" ]]; then
  SPRINT_PLAN=$(file_exists "$SPRINT_DIR/PLAN.md")
  SPRINT_SPEC=$(file_exists "$SPRINT_DIR/SPEC.md")
  SPRINT_TICKET=$(file_exists "$SPRINT_DIR/TICKET.md")
  SPRINT_HOTFIX=$(file_exists "$SPRINT_DIR/HOTFIX.md")
  SPRINT_TASKS=$(file_exists "$SPRINT_DIR/TASKS.md")
  SPRINT_WORKS=$(file_exists "$SPRINT_DIR/WORKS.md")
  SPRINT_DRIFT=$(file_exists "$SPRINT_DIR/DRIFT.md")
  SPRINT_PLAN_REVIEW=$(file_exists "$SPRINT_DIR/MAGI_PLAN_REVIEW.md")
fi

# Has any plan-equivalent file?
SPRINT_HAS_ANY_PLAN=false
[[ "$SPRINT_PLAN" == true || "$SPRINT_SPEC" == true \
   || "$SPRINT_TICKET" == true || "$SPRINT_HOTFIX" == true ]] \
  && SPRINT_HAS_ANY_PLAN=true

# ── Count tasks (total / done) from TASKS.md ──────────────────────────────
# Note: grep -c exits 1 when 0 matches but still prints "0" to stdout.
# Using `|| TASKS_X=0` after the assignment keeps the captured value clean.
TASKS_TOTAL=0
TASKS_DONE=0
if [[ "$SPRINT_TASKS" == true ]]; then
  TASKS_TOTAL=$(grep -cE '^- \[[ x]\]' "$SPRINT_DIR/TASKS.md" 2>/dev/null) || TASKS_TOTAL=0
  TASKS_DONE=$(grep -cE '^- \[x\]' "$SPRINT_DIR/TASKS.md" 2>/dev/null) || TASKS_DONE=0
fi

# ── Has diff (working tree, staged, or untracked)? ────────────────────────
HAS_DIFF=false
if ! git diff --quiet HEAD -- 2>/dev/null; then
  HAS_DIFF=true
elif ! git diff --staged --quiet 2>/dev/null; then
  HAS_DIFF=true
else
  # Treat untracked files as "diff present" — they typically need to be
  # added and committed, just like modified files.
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null | head -1)
  [[ -n "$untracked" ]] && HAS_DIFF=true
fi

# ── Compute the state ─────────────────────────────────────────────────────
STATE="BOOTSTRAP"

ANY_ROOT_DOC=false
[[ "$ROOT_CLAUDE" == true || "$ROOT_README" == true || "$ROOT_SPEC" == true ]] \
  && ANY_ROOT_DOC=true

if [[ "$ANY_ROOT_DOC" == true ]]; then
  STATE="INITIALIZED"
fi

if [[ -n "$SPRINT_DIR" && "$SPRINT_HAS_ANY_PLAN" == true ]]; then
  STATE="PLANNING"

  if [[ "$SPRINT_PLAN_REVIEW" == true ]]; then
    STATE="PLAN_REVIEWED"
  fi

  if [[ "$SPRINT_TASKS" == true ]]; then
    STATE="TASKS_READY"

    if [[ "$SPRINT_WORKS" == true ]]; then
      STATE="IN_PROGRESS"
      # WORK_DONE if all tasks checked
      if [[ "$TASKS_TOTAL" -gt 0 && "$TASKS_DONE" -eq "$TASKS_TOTAL" ]]; then
        STATE="WORK_DONE"
      fi
    fi

    if [[ "$SPRINT_DRIFT" == true ]]; then
      STATE="CODE_REVIEWED"
    fi
  fi
fi

# Hotfix mode: PLANNING but with HOTFIX.md skips TASKS state — /magi.go
# can dispatch directly. Reflect this by allowing /magi.go in HOTFIX-PLANNING.
HOTFIX_MODE=false
[[ "$SPRINT_HOTFIX" == true ]] && HOTFIX_MODE=true

# ── Detect staleness via mtime comparison ─────────────────────────────────
WARNINGS_JSON="[]"
add_warning() {
  local type="$1" file="$2" reason="$3" suggest="$4"
  WARNINGS_JSON=$(jq --arg t "$type" --arg f "$file" --arg r "$reason" --arg s "$suggest" \
    '. + [{type: $t, file: $f, reason: $r, suggest: $s}]' <<<"$WARNINGS_JSON")
}

# stale_plan_review: MAGI_PLAN_REVIEW.md older than PLAN/SPEC/TICKET source
if [[ "$SPRINT_PLAN_REVIEW" == true ]]; then
  REVIEW_MTIME=$(stat -f %m "$SPRINT_DIR/MAGI_PLAN_REVIEW.md" 2>/dev/null \
    || stat -c %Y "$SPRINT_DIR/MAGI_PLAN_REVIEW.md" 2>/dev/null || echo 0)
  for src in PLAN.md SPEC.md TICKET.md; do
    src_path="$SPRINT_DIR/$src"
    [[ -f "$src_path" ]] || continue
    SRC_MTIME=$(stat -f %m "$src_path" 2>/dev/null \
      || stat -c %Y "$src_path" 2>/dev/null || echo 0)
    if [[ "$SRC_MTIME" -gt "$REVIEW_MTIME" ]]; then
      add_warning "stale_plan_review" "$SPRINT_DIR/MAGI_PLAN_REVIEW.md" \
        "$src modified after last review" "/magi.review-plan"
      break
    fi
  done
fi

# stale_drift: DRIFT.md older than any source file in sprint or any modified file
if [[ "$SPRINT_DRIFT" == true ]]; then
  DRIFT_MTIME=$(stat -f %m "$SPRINT_DIR/DRIFT.md" 2>/dev/null \
    || stat -c %Y "$SPRINT_DIR/DRIFT.md" 2>/dev/null || echo 0)
  if [[ "$HAS_DIFF" == true ]]; then
    # Any modified file newer than DRIFT.md → stale
    NEWER_FOUND=false
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      F_MTIME=$(stat -f %m "$f" 2>/dev/null \
        || stat -c %Y "$f" 2>/dev/null || echo 0)
      if [[ "$F_MTIME" -gt "$DRIFT_MTIME" ]]; then
        NEWER_FOUND=true
        break
      fi
    done < <(git diff --name-only HEAD 2>/dev/null; git diff --staged --name-only 2>/dev/null)
    if [[ "$NEWER_FOUND" == true ]]; then
      add_warning "stale_drift" "$SPRINT_DIR/DRIFT.md" \
        "code modified after last review" "/magi.review-code"
    fi
  fi
fi

# tasks_without_plan: TASKS.md exists but no plan equivalent
if [[ "$SPRINT_TASKS" == true && "$SPRINT_HAS_ANY_PLAN" == false ]]; then
  add_warning "tasks_without_plan" "$SPRINT_DIR/TASKS.md" \
    "TASKS.md exists but no PLAN/SPEC/TICKET/HOTFIX found" "/magi.plan --into $SPRINT_DIR"
fi

# works_without_tasks: WORKS.md exists but no TASKS.md
if [[ "$SPRINT_WORKS" == true && "$SPRINT_TASKS" == false ]]; then
  add_warning "works_without_tasks" "$SPRINT_DIR/WORKS.md" \
    "WORKS.md exists but no TASKS.md found" "/magi.tasks"
fi

# ── Compute allowed/disallowed skills for this state ──────────────────────
ALL_SKILLS=(magi.setup magi.init magi.plan magi.tasks magi.review-plan magi.go magi.review-code magi.commit magi.web.frontend.spec magi.web.backend.spec magi.web.infra.plan magi.web.ci.spec)

ALLOWED_JSON="[]"
DISALLOWED_JSON="{}"

allow() {
  ALLOWED_JSON=$(jq --arg s "$1" '. + [$s]' <<<"$ALLOWED_JSON")
}
disallow() {
  local skill="$1" reason="$2" suggest="$3"
  DISALLOWED_JSON=$(jq --arg s "$skill" --arg r "$reason" --arg sug "$suggest" \
    '. + {($s): {reason: $r, suggest: $sug}}' <<<"$DISALLOWED_JSON")
}

# magi.setup: always allowed (per-user config wizard)
allow "magi.setup"

# magi.init: always allowed (idempotent)
allow "magi.init"

# magi.plan: allowed in any state; warns (not refuses) in BOOTSTRAP
allow "magi.plan"

# magi.tasks: needs PLANNING+ (sprint folder with plan equivalent)
case "$STATE" in
  PLANNING|PLAN_REVIEWED|TASKS_READY|IN_PROGRESS|WORK_DONE|CODE_REVIEWED)
    allow "magi.tasks"
    ;;
  *)
    disallow "magi.tasks" \
      "no PLAN/SPEC/TICKET/HOTFIX found in current sprint (state=$STATE)" \
      "/magi.plan"
    ;;
esac

# magi.review-plan: needs PLANNING+
case "$STATE" in
  PLANNING|PLAN_REVIEWED|TASKS_READY|IN_PROGRESS|WORK_DONE|CODE_REVIEWED)
    allow "magi.review-plan"
    ;;
  *)
    disallow "magi.review-plan" \
      "no PLAN/SPEC found in current sprint (state=$STATE)" \
      "/magi.plan"
    ;;
esac

# magi.go: needs TASKS_READY+ for normal flow; or HOTFIX mode in PLANNING
case "$STATE" in
  TASKS_READY|IN_PROGRESS|CODE_REVIEWED)
    allow "magi.go"
    ;;
  WORK_DONE)
    # All tasks done — re-running magi.go would be a no-op; allow with warning
    allow "magi.go"
    ;;
  PLANNING|PLAN_REVIEWED)
    if [[ "$HOTFIX_MODE" == true ]]; then
      allow "magi.go"
    else
      disallow "magi.go" \
        "no TASKS.md and not a hotfix sprint (state=$STATE)" \
        "/magi.tasks"
    fi
    ;;
  *)
    disallow "magi.go" \
      "no sprint context (state=$STATE)" \
      "/magi.plan"
    ;;
esac

# magi.review-code: needs has_diff (any state)
if [[ "$HAS_DIFF" == true ]]; then
  allow "magi.review-code"
else
  disallow "magi.review-code" \
    "no diff to review (working tree clean)" \
    "make some changes or stage them first"
fi

# magi.commit: sprint mode needs CODE_REVIEWED; standalone needs has_diff
if [[ "$STATE" == "CODE_REVIEWED" ]]; then
  allow "magi.commit"
elif [[ "$HAS_DIFF" == true ]]; then
  # Allow standalone-mode commit if diff exists
  allow "magi.commit"
else
  disallow "magi.commit" \
    "no diff to commit and no CODE_REVIEWED sprint" \
    "make changes or run /magi.review-code first"
fi

# magi.web.* — same gating as magi.tasks (need PLANNING+)
for web_skill in magi.web.frontend.spec magi.web.backend.spec magi.web.infra.plan magi.web.ci.spec; do
  case "$STATE" in
    PLANNING|PLAN_REVIEWED|TASKS_READY|IN_PROGRESS|WORK_DONE|CODE_REVIEWED)
      allow "$web_skill"
      ;;
    *)
      disallow "$web_skill" \
        "no PLAN/SPEC found in current sprint (state=$STATE)" \
        "/magi.plan"
      ;;
  esac
done

# ── Emit JSON ─────────────────────────────────────────────────────────────
jq -n \
  --arg state "$STATE" \
  --arg sprint_dir "${SPRINT_DIR:-}" \
  --argjson root_claude "$ROOT_CLAUDE" \
  --argjson root_readme "$ROOT_README" \
  --argjson root_spec "$ROOT_SPEC" \
  --argjson docs_prd "$DOCS_PRD" \
  --argjson docs_techstack "$DOCS_TECHSTACK" \
  --argjson docs_backlog "$DOCS_BACKLOG" \
  --argjson sprint_plan "$SPRINT_PLAN" \
  --argjson sprint_spec "$SPRINT_SPEC" \
  --argjson sprint_ticket "$SPRINT_TICKET" \
  --argjson sprint_hotfix "$SPRINT_HOTFIX" \
  --argjson sprint_tasks "$SPRINT_TASKS" \
  --argjson sprint_works "$SPRINT_WORKS" \
  --argjson sprint_drift "$SPRINT_DRIFT" \
  --argjson sprint_plan_review "$SPRINT_PLAN_REVIEW" \
  --argjson tasks_total "${TASKS_TOTAL:-0}" \
  --argjson tasks_done "${TASKS_DONE:-0}" \
  --argjson has_diff "$HAS_DIFF" \
  --argjson hotfix_mode "$HOTFIX_MODE" \
  --argjson allowed "$ALLOWED_JSON" \
  --argjson disallowed "$DISALLOWED_JSON" \
  --argjson warnings "$WARNINGS_JSON" \
  '{
    state: $state,
    sprint_dir: $sprint_dir,
    files: {
      root_claude: $root_claude,
      root_readme: $root_readme,
      root_spec: $root_spec,
      docs_prd: $docs_prd,
      docs_techstack: $docs_techstack,
      docs_backlog: $docs_backlog,
      sprint_plan: $sprint_plan,
      sprint_spec: $sprint_spec,
      sprint_ticket: $sprint_ticket,
      sprint_hotfix: $sprint_hotfix,
      sprint_tasks: $sprint_tasks,
      sprint_works: $sprint_works,
      sprint_drift: $sprint_drift,
      sprint_plan_review: $sprint_plan_review
    },
    tasks_total: $tasks_total,
    tasks_done: $tasks_done,
    has_diff: $has_diff,
    hotfix_mode: $hotfix_mode,
    allowed_skills: $allowed,
    disallowed_skills: $disallowed,
    warnings: $warnings
  }'
