#!/usr/bin/env bash
# Preflight: run --healthcheck on every configured reviewer adapter
# and emit an aggregated JSON status report.
#
# Output JSON (single object on stdout):
#   {
#     "config_path": "...",
#     "reviewers": [
#       {"cli": "claude", "model": "opus", "status": "ok",   "reason": "...", "version": "..."},
#       {"cli": "gemini", "model": "default", "status": "skip", "reason": "..."},
#       {"cli": "codex",  "model": "default", "status": "fail", "reason": "..."}
#     ],
#     "summary": {"ok": 1, "skip": 1, "fail": 1, "total": 3}
#   }
#
# Exit codes:
#   0 — at least one ok reviewer
#   2 — no ok reviewer (all skip/fail)
#   3 — config missing or invalid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTERS_DIR="$PLUGIN_ROOT/skills/maestro.review-plan/scripts/adapters"

# shellcheck source=error-patterns.sh
. "$SCRIPT_DIR/error-patterns.sh"

PLUGIN_DEFAULT_CONFIG="$PLUGIN_ROOT/config/default.json"
CONFIG_PATH=$(resolve_config_path "$PLUGIN_DEFAULT_CONFIG" || true)

if [[ -z "${CONFIG_PATH:-}" ]]; then
  jq -n '{error: "no config found"}'
  exit 3
fi

if ! jq -e '.xreview.reviewers' "$CONFIG_PATH" >/dev/null 2>&1; then
  jq -n --arg path "$CONFIG_PATH" '{error: "invalid config", path: $path}'
  exit 3
fi

reviewer_count=$(jq '.xreview.reviewers | length' "$CONFIG_PATH")

results_json="[]"
ok=0
skip=0
fail=0

for ((i = 0; i < reviewer_count; i++)); do
  cli=$(jq -r ".xreview.reviewers[$i].cli" "$CONFIG_PATH")
  model=$(jq -r ".xreview.reviewers[$i].model" "$CONFIG_PATH")
  adapter="$ADAPTERS_DIR/${cli}.sh"

  if [[ ! -x "$adapter" ]]; then
    item=$(jq -n \
      --arg cli "$cli" --arg model "$model" \
      --arg reason "adapter not found: $adapter" \
      '{cli: $cli, model: $model, status: "fail", reason: $reason}')
    fail=$((fail + 1))
  else
    healthcheck_out=$("$adapter" --healthcheck "$CONFIG_PATH" 2>&1 || true)
    healthcheck_rc=$?
    status=$(echo "$healthcheck_out" | awk -F= '/^status=/{print $2; exit}')
    reason=$(echo "$healthcheck_out" | awk -F= '/^reason=/{sub(/^reason=/, ""); print; exit}')
    version=$(echo "$healthcheck_out" | awk -F= '/^version=/{print $2; exit}')

    if [[ -z "$status" ]]; then
      status="fail"
      reason="adapter returned no status (rc=$healthcheck_rc)"
    fi

    case "$status" in
      ok)   ok=$((ok + 1)) ;;
      skip) skip=$((skip + 1)) ;;
      *)    fail=$((fail + 1)) ;;
    esac

    item=$(jq -n \
      --arg cli "$cli" --arg model "$model" \
      --arg status "$status" --arg reason "$reason" --arg version "$version" \
      '{cli: $cli, model: $model, status: $status, reason: $reason, version: $version}')
  fi

  results_json=$(jq --argjson item "$item" '. + [$item]' <<<"$results_json")
done

jq -n \
  --arg config_path "$CONFIG_PATH" \
  --argjson reviewers "$results_json" \
  --argjson ok "$ok" --argjson skip "$skip" --argjson fail "$fail" --argjson total "$reviewer_count" \
  '{
    config_path: $config_path,
    reviewers: $reviewers,
    summary: {ok: $ok, skip: $skip, fail: $fail, total: $total}
  }'

if [[ $ok -eq 0 ]]; then
  exit 2
fi
exit 0
