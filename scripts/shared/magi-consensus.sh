#!/usr/bin/env bash
# MAGI consensus report builder.
#
# Reads an orchestrator workdir and produces:
#   <workdir>/magi-report.md   — human-readable consolidated review
#   <workdir>/magi-report.json — machine-readable structure for the coordinator
#
# Semantic issue de-duplication / voting is intentionally NOT done here:
# that is the coordinator agent's job (it has the language model).
# This script:
#   • tabulates which reviewers succeeded / skipped / failed
#   • computes total available weight and the configured threshold
#   • bundles every successful reviewer's final.txt into the report
#   • appends instructions for the coordinator on how to apply MAGI rules
#
# Usage:
#   magi-consensus.sh <workdir> [--mode majority|supermajority|unanimous|threshold:N]
#
# The --mode flag lets a slash command override config.xreview.magi.mode
# (e.g. /magi:review-code --magi unanimous).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=error-patterns.sh
. "$SCRIPT_DIR/error-patterns.sh"

[[ $# -lt 1 ]] && { echo "Usage: $0 <workdir> [--mode <m>]" >&2; exit 2; }
WORKDIR="$1"; shift
[[ -d "$WORKDIR" ]] || { echo "workdir not found: $WORKDIR" >&2; exit 2; }

MODE_OVERRIDE=""
THRESHOLD_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      shift
      raw="$1"; shift
      if [[ "$raw" == threshold:* ]]; then
        MODE_OVERRIDE="threshold"
        THRESHOLD_OVERRIDE="${raw#threshold:}"
      else
        MODE_OVERRIDE="$raw"
      fi
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

SUMMARY_JSON="$WORKDIR/orchestrator.summary.json"
EVENTS_LOG="$WORKDIR/events.log"
[[ -f "$SUMMARY_JSON" ]] || { echo "missing $SUMMARY_JSON" >&2; exit 2; }
[[ -f "$EVENTS_LOG" ]]  || { echo "missing $EVENTS_LOG" >&2; exit 2; }

CONFIG_PATH=$(jq -r '.config_path' "$SUMMARY_JSON")
[[ -f "$CONFIG_PATH" ]] || { echo "config from summary missing: $CONFIG_PATH" >&2; exit 2; }

# ── Resolve MAGI mode ──────────────────────────────────────────────────────
mode=$(jq -r '.xreview.magi.mode // "majority"' "$CONFIG_PATH")
threshold=$(jq -r '.xreview.magi.threshold // empty' "$CONFIG_PATH")
[[ -n "$MODE_OVERRIDE" ]] && mode="$MODE_OVERRIDE"
[[ -n "$THRESHOLD_OVERRIDE" ]] && threshold="$THRESHOLD_OVERRIDE"

# ── Collect per-reviewer outcomes by parsing events.log ────────────────────
declare -a REVIEWER_KEYS=() REVIEWER_STATUS=() REVIEWER_LOGS=() REVIEWER_FINALS=() REVIEWER_REASONS=()

while IFS= read -r line; do
  case "$line" in
    "RETURN "*)
      key=$(awk '{print $2}' <<<"$line")
      log=$(awk '{print $3}' <<<"$line")
      final=$(awk '{print $4}' <<<"$line")
      REVIEWER_KEYS+=("$key"); REVIEWER_STATUS+=("ok")
      REVIEWER_LOGS+=("$log"); REVIEWER_FINALS+=("$final"); REVIEWER_REASONS+=("")
      ;;
    "SKIP "*)
      key=$(awk '{print $2}' <<<"$line")
      reason=$(sed -nE 's/.*reason=([^ ]+).*/\1/p' <<<"$line")
      log=$(sed -nE 's/.*log=([^ ]+).*/\1/p' <<<"$line")
      REVIEWER_KEYS+=("$key"); REVIEWER_STATUS+=("skip")
      REVIEWER_LOGS+=("$log"); REVIEWER_FINALS+=(""); REVIEWER_REASONS+=("$reason")
      ;;
    "FAIL "*)
      key=$(awk '{print $2}' <<<"$line")
      log=$(sed -nE 's/.*log=([^ ]+).*/\1/p' <<<"$line")
      final=$(sed -nE 's/.*final=([^ ]+).*/\1/p' <<<"$line")
      reason=$(sed -nE 's/.*reason=([^ ]+).*/\1/p' <<<"$line")
      [[ -z "$reason" ]] && reason="exit-error"
      REVIEWER_KEYS+=("$key"); REVIEWER_STATUS+=("fail")
      REVIEWER_LOGS+=("$log"); REVIEWER_FINALS+=("$final"); REVIEWER_REASONS+=("$reason")
      ;;
  esac
done <"$EVENTS_LOG"

# ── Compute weights from config ────────────────────────────────────────────
total_weight=0
ok_weight=0

# Map cli:model -> weight from config
get_weight() {
  local cli_model="$1" cli model
  cli="${cli_model%%:*}"
  model="${cli_model#*:}"
  jq -r --arg cli "$cli" --arg model "$model" '
    .xreview.reviewers[]
    | select(.cli == $cli and .model == $model)
    | .weight // 1
  ' "$CONFIG_PATH" | head -1
}

for ((i=0; i<${#REVIEWER_KEYS[@]}; i++)); do
  w=$(get_weight "${REVIEWER_KEYS[$i]}")
  [[ -z "$w" || "$w" == "null" ]] && w=1
  total_weight=$((total_weight + w))
  [[ "${REVIEWER_STATUS[$i]}" == "ok" ]] && ok_weight=$((ok_weight + w))
done

# ── Compute threshold per mode ─────────────────────────────────────────────
threshold_value=""
threshold_rule=""
case "$mode" in
  majority)
    threshold_rule="vote_sum > total_weight × 0.5"
    threshold_value=$(awk -v w="$ok_weight" 'BEGIN { printf "%.4f", w/2 }')
    ;;
  supermajority)
    threshold_rule="vote_sum >= total_weight × 2/3"
    threshold_value=$(awk -v w="$ok_weight" 'BEGIN { printf "%.4f", w*2/3 }')
    ;;
  unanimous)
    threshold_rule="all reviewers must agree"
    threshold_value="$ok_weight"
    ;;
  threshold)
    threshold_rule="vote_sum >= configured threshold"
    threshold_value="${threshold:-1}"
    ;;
  *)
    echo "unknown mode: $mode" >&2; exit 2
    ;;
esac

# ── Detect degraded mode ───────────────────────────────────────────────────
ok_count=$(jq -r '.summary.ok' "$SUMMARY_JSON")
configured_count=${#REVIEWER_KEYS[@]}
degraded="false"
degrade_reason=""
if (( ok_count < configured_count )); then
  degraded="true"
  degrade_reason="only $ok_count of $configured_count reviewers succeeded; threshold recomputed against ok_weight=$ok_weight"
fi
if (( ok_count == 1 )); then
  degraded="true"
  degrade_reason="single-reviewer mode — no cross-validation; treat output with caution"
fi

# ── Detect unanimous-mode misconfiguration ─────────────────────────────────
if [[ "$mode" == "unanimous" && "$degraded" == "true" ]]; then
  degrade_reason="unanimous mode requires all reviewers; degraded → result must be treated as ABORT unless all required reviewers succeeded"
fi

# ── Write JSON report ──────────────────────────────────────────────────────
JSON_REPORT="$WORKDIR/magi-report.json"
{
  reviewers_json="["
  first=1
  for ((i=0; i<${#REVIEWER_KEYS[@]}; i++)); do
    [[ $first -eq 0 ]] && reviewers_json+=","
    first=0
    w=$(get_weight "${REVIEWER_KEYS[$i]}")
    [[ -z "$w" || "$w" == "null" ]] && w=1
    reviewers_json+=$(jq -n \
      --arg key "${REVIEWER_KEYS[$i]}" \
      --arg status "${REVIEWER_STATUS[$i]}" \
      --arg log "${REVIEWER_LOGS[$i]}" \
      --arg final "${REVIEWER_FINALS[$i]}" \
      --arg reason "${REVIEWER_REASONS[$i]}" \
      --argjson weight "$w" \
      '{key: $key, status: $status, weight: $weight, log: $log, final: $final, reason: $reason}')
  done
  reviewers_json+="]"

  jq -n \
    --arg workdir "$WORKDIR" \
    --arg mode "$mode" \
    --arg threshold_rule "$threshold_rule" \
    --arg threshold_value "$threshold_value" \
    --argjson total_weight "$total_weight" \
    --argjson ok_weight "$ok_weight" \
    --argjson reviewers "$reviewers_json" \
    --arg degraded "$degraded" \
    --arg degrade_reason "$degrade_reason" \
    '{
      workdir: $workdir,
      magi: {
        mode: $mode,
        threshold_rule: $threshold_rule,
        threshold_value: $threshold_value,
        total_weight_configured: $total_weight,
        ok_weight: $ok_weight,
        degraded: ($degraded == "true"),
        degrade_reason: $degrade_reason
      },
      reviewers: $reviewers
    }'
} >"$JSON_REPORT"

# ── Write markdown report ──────────────────────────────────────────────────
MD_REPORT="$WORKDIR/magi-report.md"
{
  echo "# 🧠 MAGI Consensus Report"
  echo
  echo "**Mode:** \`$mode\`  •  **Rule:** $threshold_rule  •  **Threshold value:** $threshold_value"
  echo "**Total configured weight:** $total_weight  •  **Successful (ok) weight:** $ok_weight"
  if [[ "$degraded" == "true" ]]; then
    echo
    echo "> ⚠️ **DEGRADED MODE** — $degrade_reason"
  fi
  echo
  echo "## Reviewer outcomes"
  echo
  echo "| Reviewer | Weight | Status | Notes |"
  echo "|----------|--------|--------|-------|"
  for ((i=0; i<${#REVIEWER_KEYS[@]}; i++)); do
    w=$(get_weight "${REVIEWER_KEYS[$i]}")
    [[ -z "$w" || "$w" == "null" ]] && w=1
    case "${REVIEWER_STATUS[$i]}" in
      ok)   icon="✅" ;;
      skip) icon="⏭️" ;;
      fail) icon="❌" ;;
    esac
    notes="${REVIEWER_REASONS[$i]:-—}"
    echo "| \`${REVIEWER_KEYS[$i]}\` | $w | $icon ${REVIEWER_STATUS[$i]} | $notes |"
  done
  echo
  echo "---"
  echo
  echo "## Reviewer outputs"
  echo
  for ((i=0; i<${#REVIEWER_KEYS[@]}; i++)); do
    if [[ "${REVIEWER_STATUS[$i]}" == "ok" && -s "${REVIEWER_FINALS[$i]}" ]]; then
      w=$(get_weight "${REVIEWER_KEYS[$i]}")
      [[ -z "$w" || "$w" == "null" ]] && w=1
      echo "### \`${REVIEWER_KEYS[$i]}\` (weight $w)"
      echo
      echo '```'
      cat "${REVIEWER_FINALS[$i]}"
      echo
      echo '```'
      echo
    fi
  done
  echo "---"
  echo
  echo "## Coordinator instructions"
  echo
  echo "1. Treat each reviewer's output as an independent opinion."
  echo "2. Identify which **issues** are raised by which reviewers (apply semantic dedup — same issue described differently still counts)."
  echo "3. For each unique issue, sum the weights of reviewers who raised it (\`vote_sum\`)."
  echo "4. Apply the rule \`$threshold_rule\` (current threshold: $threshold_value):"
  echo "   - 🔴 **Critical / 🟡 Important** — if \`vote_sum\` meets the threshold."
  echo "   - 🟢 **Note (minority)** — if raised but below threshold; surface for awareness only."
  echo "5. Present the final consolidated MAGI report to the user."
  if [[ "$degraded" == "true" ]]; then
    echo "6. ⚠️ Prefix the user-facing report with the DEGRADED MODE warning above."
  fi
} >"$MD_REPORT"

echo "$MD_REPORT"
