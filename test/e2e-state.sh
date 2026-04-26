#!/usr/bin/env bash
# E2E test for scripts/shared/detect-state.sh.
#
# Builds fake project structures covering the 8 states + warning scenarios,
# runs detect-state.sh against each, and verifies the JSON output matches
# expectations. Token-free; pure filesystem + bash/jq.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECT="$PLUGIN_ROOT/scripts/shared/detect-state.sh"

[[ -x "$DETECT" ]] || { echo "missing or non-executable: $DETECT" >&2; exit 1; }

PASS=0
FAIL=0
FAILURES=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: expected=$expected actual=$actual")
    echo "  ❌ $label: expected=$expected actual=$actual"
  fi
}

# Run detect-state inside a target dir without using a subshell (so counter
# updates persist).
run_in() {
  local d="$1"; shift
  local saved
  saved=$(pwd)
  cd "$d" || return 1
  bash "$DETECT" "$@" 2>/dev/null
  cd "$saved" || return 1
}

make_repo() {
  local d
  d=$(mktemp -d -t magi-state.XXXXXX)
  cd "$d" || return 1
  git init -q
  git config user.email "test@example"
  git config user.name "test"
  git commit -q --allow-empty -m "init"
  cd - >/dev/null || return 1
  echo "$d"
}

cleanup() {
  [[ -n "${1:-}" && -d "${1:-}" ]] && rm -rf "$1"
}

# ── Case 1: BOOTSTRAP ────────────────────────────────────────────────────
echo "=== Case 1: BOOTSTRAP (no root docs, no magi/) ==="
T=$(make_repo)
JSON=$(run_in "$T")
assert_eq "state" "BOOTSTRAP" "$(jq -r .state <<<"$JSON")"
assert_eq "tasks disallowed" "true" "$(jq -r '.disallowed_skills["tasks"] != null' <<<"$JSON")"
assert_eq "go disallowed" "true" "$(jq -r '.disallowed_skills["go"] != null' <<<"$JSON")"
assert_eq "yolo disallowed in BOOTSTRAP" "true" "$(jq -r '.disallowed_skills["yolo"] != null' <<<"$JSON")"
assert_eq "init allowed" "true" "$(jq -r '.allowed_skills | index("init") != null' <<<"$JSON")"
assert_eq "plan allowed (warned not blocked)" "true" "$(jq -r '.allowed_skills | index("plan") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 2: INITIALIZED ──────────────────────────────────────────────────
echo "=== Case 2: INITIALIZED (root docs only) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
echo "# CLAUDE" > "$T/CLAUDE.md"
JSON=$(run_in "$T")
assert_eq "state" "INITIALIZED" "$(jq -r .state <<<"$JSON")"
assert_eq "tasks disallowed" "true" "$(jq -r '.disallowed_skills["tasks"] != null' <<<"$JSON")"
assert_eq "commit allowed (has untracked diff)" "true" "$(jq -r '.allowed_skills | index("commit") != null' <<<"$JSON")"
assert_eq "yolo allowed in INITIALIZED" "true" "$(jq -r '.allowed_skills | index("yolo") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 3: PLANNING ─────────────────────────────────────────────────────
echo "=== Case 3: PLANNING (sprint with PLAN.md, no TASKS) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
JSON=$(run_in "$T")
assert_eq "state" "PLANNING" "$(jq -r .state <<<"$JSON")"
assert_eq "sprint_dir" "magi/01-foo" "$(jq -r .sprint_dir <<<"$JSON")"
assert_eq "tasks allowed" "true" "$(jq -r '.allowed_skills | index("tasks") != null' <<<"$JSON")"
assert_eq "go disallowed (no TASKS)" "true" "$(jq -r '.disallowed_skills["go"] != null' <<<"$JSON")"
assert_eq "web-backend-spec allowed" "true" "$(jq -r '.allowed_skills | index("web-backend-spec") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 4: PLAN_REVIEWED ────────────────────────────────────────────────
echo "=== Case 4: PLAN_REVIEWED (sprint with MAGI_PLAN_REVIEW.md) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
echo "# Review" > "$T/magi/01-foo/MAGI_PLAN_REVIEW.md"
JSON=$(run_in "$T")
assert_eq "state" "PLAN_REVIEWED" "$(jq -r .state <<<"$JSON")"
cleanup "$T"

# ── Case 5: TASKS_READY ──────────────────────────────────────────────────
echo "=== Case 5: TASKS_READY (PLAN + TASKS, no WORKS) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
printf "## M1\n- [ ] T1.1 — foo\n- [ ] T1.2 — bar\n" > "$T/magi/01-foo/TASKS.md"
JSON=$(run_in "$T")
assert_eq "state" "TASKS_READY" "$(jq -r .state <<<"$JSON")"
assert_eq "tasks_total" "2" "$(jq -r .tasks_total <<<"$JSON")"
assert_eq "tasks_done" "0" "$(jq -r .tasks_done <<<"$JSON")"
assert_eq "go allowed" "true" "$(jq -r '.allowed_skills | index("go") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 6: IN_PROGRESS ──────────────────────────────────────────────────
echo "=== Case 6: IN_PROGRESS (TASKS + WORKS, partial done) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
printf "## M1\n- [x] T1.1 — foo\n- [ ] T1.2 — bar\n" > "$T/magi/01-foo/TASKS.md"
echo "# Works" > "$T/magi/01-foo/WORKS.md"
JSON=$(run_in "$T")
assert_eq "state" "IN_PROGRESS" "$(jq -r .state <<<"$JSON")"
assert_eq "tasks_done" "1" "$(jq -r .tasks_done <<<"$JSON")"
cleanup "$T"

# ── Case 7: WORK_DONE ────────────────────────────────────────────────────
echo "=== Case 7: WORK_DONE (all tasks checked) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
printf "## M1\n- [x] T1.1 — foo\n- [x] T1.2 — bar\n" > "$T/magi/01-foo/TASKS.md"
echo "# Works" > "$T/magi/01-foo/WORKS.md"
JSON=$(run_in "$T")
assert_eq "state" "WORK_DONE" "$(jq -r .state <<<"$JSON")"
cleanup "$T"

# ── Case 8: CODE_REVIEWED ────────────────────────────────────────────────
echo "=== Case 8: CODE_REVIEWED (sprint with DRIFT.md) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
printf "## M1\n- [x] T1.1 — foo\n" > "$T/magi/01-foo/TASKS.md"
echo "# Works" > "$T/magi/01-foo/WORKS.md"
echo "# Drift" > "$T/magi/01-foo/DRIFT.md"
JSON=$(run_in "$T")
assert_eq "state" "CODE_REVIEWED" "$(jq -r .state <<<"$JSON")"
assert_eq "commit allowed" "true" "$(jq -r '.allowed_skills | index("commit") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 9: HOTFIX mode ──────────────────────────────────────────────────
echo "=== Case 9: HOTFIX mode (HOTFIX.md, no TASKS — go still allowed) ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Hotfix" > "$T/magi/01-foo/HOTFIX.md"
JSON=$(run_in "$T")
assert_eq "state" "PLANNING" "$(jq -r .state <<<"$JSON")"
assert_eq "hotfix_mode" "true" "$(jq -r .hotfix_mode <<<"$JSON")"
assert_eq "go allowed (hotfix bypass)" "true" "$(jq -r '.allowed_skills | index("go") != null' <<<"$JSON")"
cleanup "$T"

# ── Case 10: warning — tasks_without_plan ────────────────────────────────
echo "=== Case 10: warning tasks_without_plan ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
printf "## M1\n- [ ] T1.1 — orphan\n" > "$T/magi/01-foo/TASKS.md"
JSON=$(run_in "$T")
assert_eq "warning tasks_without_plan present" "true" \
  "$(jq -r '[.warnings[] | select(.type == "tasks_without_plan")] | length > 0' <<<"$JSON")"
cleanup "$T"

# ── Case 11: warning — stale_plan_review ─────────────────────────────────
echo "=== Case 11: warning stale_plan_review ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
echo "# Review" > "$T/magi/01-foo/MAGI_PLAN_REVIEW.md"
sleep 1
echo "# Plan v2" > "$T/magi/01-foo/PLAN.md"
JSON=$(run_in "$T")
assert_eq "warning stale_plan_review present" "true" \
  "$(jq -r '[.warnings[] | select(.type == "stale_plan_review")] | length > 0' <<<"$JSON")"
cleanup "$T"

# ── Case 12: --sprint flag ──────────────────────────────────────────────
echo "=== Case 12: --sprint flag overrides latest detection ==="
T=$(make_repo)
echo "# README" > "$T/README.md"
mkdir -p "$T/magi/01-foo" "$T/magi/02-bar"
echo "# Plan" > "$T/magi/01-foo/PLAN.md"
printf "## M1\n- [ ] T1.1\n" > "$T/magi/02-bar/TASKS.md"
echo "# Plan2" > "$T/magi/02-bar/PLAN.md"
JSON_DEFAULT=$(run_in "$T")
JSON_EXPLICIT=$(run_in "$T" --sprint 01-foo)
assert_eq "default state (latest)" "TASKS_READY" "$(jq -r .state <<<"$JSON_DEFAULT")"
assert_eq "explicit sprint state" "PLANNING" "$(jq -r .state <<<"$JSON_EXPLICIT")"
assert_eq "explicit sprint dir" "magi/01-foo" "$(jq -r .sprint_dir <<<"$JSON_EXPLICIT")"
cleanup "$T"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "Passed: $PASS  •  Failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "✅ all detect-state.sh assertions passed"
