#!/usr/bin/env bash
# Magi xreview orchestrator.
#
# Spawns N reviewer adapters in parallel, emits an event stream on stdout,
# writes per-reviewer log + final files into a workdir, and applies the
# fallback policy / MAGI quorum at the end.
#
# Usage:
#   orchestrator.sh <prompt-file> [<cli>:<model> ...]
#
# If no reviewer pairs are given, the list is read from
# config.xreview.reviewers.
#
# Event stream (one event per line, written to stdout):
#   WORKDIR <path>
#   START   <cli:model> <log-path>
#   SKIP    <cli:model> reason=<short> log=<path>
#   RETURN  <cli:model> <log-path> <final-path>
#   FAIL    <cli:model> exit=<n> log=<path> final=<path>
#   ALL_DONE successful=N skipped=M failed=K policy_pass=true|false workdir=<path>
#
# Exit codes:
#   0 — policy passed (enough successful reviewers per fallback_policy)
#   2 — policy failed (insufficient reviewers)
#   3 — config / setup error
#   130 — interrupted by signal

set -uo pipefail

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$ORCH_DIR/../../.." && pwd)"
ADAPTERS_DIR="$ORCH_DIR/adapters"
SHARED_DIR="$PLUGIN_ROOT/scripts/shared"

# shellcheck source=../../../scripts/shared/error-patterns.sh
. "$SHARED_DIR/error-patterns.sh"

usage() {
  cat >&2 <<EOF
Usage: $0 <prompt-file> [<cli>:<model> ...]

Examples:
  $0 prompt.md
  $0 prompt.md claude:opus gemini:default
EOF
  exit 2
}

[[ $# -lt 1 ]] && usage
PROMPT_FILE="$1"; shift
[[ ! -f "$PROMPT_FILE" ]] && { echo "prompt file not found: $PROMPT_FILE" >&2; exit 3; }

# ── Resolve config ─────────────────────────────────────────────────────────
CONFIG_PATH=$(resolve_config_path "$PLUGIN_ROOT/config/default.json" || true)
[[ -z "${CONFIG_PATH:-}" ]] && { echo "no config found" >&2; exit 3; }
if ! jq -e '.xreview.reviewers' "$CONFIG_PATH" >/dev/null 2>&1; then
  echo "invalid config: $CONFIG_PATH" >&2
  exit 3
fi

# ── Reviewer list: explicit args > config ──────────────────────────────────
declare -a REVIEWERS  # entries: "cli:model:weight:required"

if [[ $# -gt 0 ]]; then
  for pair in "$@"; do
    cli="${pair%%:*}"
    model="${pair#*:}"
    [[ -z "$cli" || -z "$model" || "$cli" == "$pair" ]] && {
      echo "invalid reviewer arg: $pair (expected cli:model)" >&2
      exit 3
    }
    REVIEWERS+=("$cli:$model:1:false")
  done
else
  count=$(jq '.xreview.reviewers | length' "$CONFIG_PATH")
  for ((i=0; i<count; i++)); do
    cli=$(jq -r ".xreview.reviewers[$i].cli" "$CONFIG_PATH")
    model=$(jq -r ".xreview.reviewers[$i].model" "$CONFIG_PATH")
    weight=$(jq -r ".xreview.reviewers[$i].weight // 1" "$CONFIG_PATH")
    required=$(jq -r ".xreview.reviewers[$i].required // false" "$CONFIG_PATH")
    REVIEWERS+=("$cli:$model:$weight:$required")
  done
fi

(( ${#REVIEWERS[@]} == 0 )) && { echo "no reviewers configured" >&2; exit 3; }

# ── Workdir ────────────────────────────────────────────────────────────────
WORKDIR="${MAGI_REVIEW_WORKDIR:-$(mktemp -d -t magi-review.XXXXXX)}"
mkdir -p "$WORKDIR"
EVENTS_LOG="$WORKDIR/events.log"
: >"$EVENTS_LOG"

emit() {
  local line="$*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$EVENTS_LOG"
}
emit "WORKDIR $WORKDIR"

# ── Signal handling ────────────────────────────────────────────────────────
declare -a CHILD_PIDS=()

cleanup() {
  local sig="${1:-EXIT}"
  if (( ${#CHILD_PIDS[@]} > 0 )); then
    for pid in "${CHILD_PIDS[@]}"; do
      [[ -z "$pid" ]] && continue
      kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${CHILD_PIDS[@]}"; do
      [[ -z "$pid" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  fi
  if [[ "$sig" != "EXIT" ]]; then
    emit "ALL_DONE successful=0 skipped=0 failed=${#REVIEWERS[@]} policy_pass=false workdir=$WORKDIR signal=$sig"
    exit 130
  fi
}
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM

# ── Per-reviewer worker ────────────────────────────────────────────────────
TIMEOUT_SECS=$(jq -r '.xreview.timeout_seconds // 3000' "$CONFIG_PATH")
TIMEOUT_BIN=$(command -v gtimeout || command -v timeout || true)

run_reviewer() {
  local cli="$1" model="$2" status_file="$3"
  local adapter="$ADAPTERS_DIR/${cli}.sh"
  local log_file="$WORKDIR/${cli}-${model}.log"
  local final_file="$WORKDIR/${cli}-${model}.final.txt"

  if [[ ! -x "$adapter" ]]; then
    echo "rc=13" >"$status_file"
    echo "log=$log_file" >>"$status_file"
    echo "final=$final_file" >>"$status_file"
    echo "reason=adapter not found" >>"$status_file"
    return
  fi

  local rc=0
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" --foreground "${TIMEOUT_SECS}s" \
      "$adapter" run "$CONFIG_PATH" "$PROMPT_FILE" "$log_file" "$final_file" "$model" \
      >>"$log_file" 2>&1 || rc=$?
  else
    "$adapter" run "$CONFIG_PATH" "$PROMPT_FILE" "$log_file" "$final_file" "$model" \
      >>"$log_file" 2>&1 || rc=$?
  fi

  echo "rc=$rc" >"$status_file"
  echo "log=$log_file" >>"$status_file"
  echo "final=$final_file" >>"$status_file"
}

# ── Spawn workers ──────────────────────────────────────────────────────────
declare -a STATUS_FILES=() ENTRY_KEYS=()
for entry in "${REVIEWERS[@]}"; do
  cli="${entry%%:*}"
  rest="${entry#*:}"
  model="${rest%%:*}"
  rest="${rest#*:}"
  weight="${rest%%:*}"
  required="${rest#*:}"

  key="${cli}:${model}"
  log_file="$WORKDIR/${cli}-${model}.log"
  final_file="$WORKDIR/${cli}-${model}.final.txt"
  status_file="$WORKDIR/${cli}-${model}.status"

  emit "START $key $log_file"

  ( run_reviewer "$cli" "$model" "$status_file" ) &
  CHILD_PIDS+=($!)
  STATUS_FILES+=("$status_file")
  ENTRY_KEYS+=("$entry")
done

# ── Wait for all and collect ───────────────────────────────────────────────
wait
trap - INT TERM

ok=0; skip=0; fail=0
declare -a HARD_FAIL_REQUIRED=()
for ((i=0; i<${#ENTRY_KEYS[@]}; i++)); do
  entry="${ENTRY_KEYS[$i]}"
  cli="${entry%%:*}"; rest="${entry#*:}"
  model="${rest%%:*}"; rest="${rest#*:}"
  weight="${rest%%:*}"; required="${rest#*:}"
  status_file="${STATUS_FILES[$i]}"

  rc=$(awk -F= '/^rc=/{print $2; exit}' "$status_file" 2>/dev/null || echo "1")
  log_file=$(awk -F= '/^log=/{sub(/^log=/, ""); print; exit}' "$status_file" 2>/dev/null)
  final_file=$(awk -F= '/^final=/{sub(/^final=/, ""); print; exit}' "$status_file" 2>/dev/null)

  key="$cli:$model"
  case "$rc" in
    0)
      emit "RETURN $key $log_file $final_file"
      ok=$((ok + 1))
      ;;
    11)
      emit "SKIP $key reason=quota log=$log_file"
      skip=$((skip + 1))
      [[ "$required" == "true" ]] && HARD_FAIL_REQUIRED+=("$key:quota")
      ;;
    12)
      emit "SKIP $key reason=auth log=$log_file"
      skip=$((skip + 1))
      [[ "$required" == "true" ]] && HARD_FAIL_REQUIRED+=("$key:auth")
      ;;
    13)
      emit "SKIP $key reason=missing log=$log_file"
      skip=$((skip + 1))
      [[ "$required" == "true" ]] && HARD_FAIL_REQUIRED+=("$key:missing")
      ;;
    14)
      emit "FAIL $key exit=14 log=$log_file final=$final_file reason=empty-final"
      fail=$((fail + 1))
      [[ "$required" == "true" ]] && HARD_FAIL_REQUIRED+=("$key:empty")
      ;;
    *)
      emit "FAIL $key exit=$rc log=$log_file final=$final_file"
      fail=$((fail + 1))
      [[ "$required" == "true" ]] && HARD_FAIL_REQUIRED+=("$key:exit=$rc")
      ;;
  esac
done

# ── Apply fallback policy ──────────────────────────────────────────────────
policy=$(jq -r '.xreview.fallback_policy // "lenient"' "$CONFIG_PATH")
min_ok=$(jq -r '.xreview.min_successful_reviewers // 1' "$CONFIG_PATH")

policy_pass="true"
if (( ${#HARD_FAIL_REQUIRED[@]} > 0 )); then
  policy_pass="false"
elif [[ "$policy" == "strict" && $fail -gt 0 ]]; then
  policy_pass="false"
elif [[ "$policy" == "strict" && $skip -gt 0 ]]; then
  policy_pass="false"
elif (( ok < min_ok )); then
  policy_pass="false"
fi

emit "ALL_DONE successful=$ok skipped=$skip failed=$fail policy_pass=$policy_pass workdir=$WORKDIR"

# Write summary JSON for downstream consumers (MAGI consensus).
jq -n \
  --arg workdir "$WORKDIR" \
  --argjson ok "$ok" --argjson skip "$skip" --argjson fail "$fail" \
  --arg policy_pass "$policy_pass" \
  --arg config_path "$CONFIG_PATH" \
  '{
    workdir: $workdir,
    summary: {ok: $ok, skip: $skip, fail: $fail},
    policy_pass: ($policy_pass == "true"),
    config_path: $config_path
  }' >"$WORKDIR/orchestrator.summary.json"

[[ "$policy_pass" == "true" ]] && exit 0 || exit 2
