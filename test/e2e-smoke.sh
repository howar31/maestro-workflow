#!/usr/bin/env bash
# End-to-end smoke test: run orchestrator with all configured CLIs against a
# minimal prompt, then run MAGI consensus. Verifies the full pipeline.
#
# Cost: spawns one short call per reviewer. Keep prompt small.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"

ORCHESTRATOR="$PLUGIN_ROOT/skills/review-plan/scripts/orchestrator.sh"
MAGI="$PLUGIN_ROOT/scripts/shared/magi-consensus.sh"

PROMPT_FILE=$(mktemp -t magi-prompt.XXXXXX.md)
cat >"$PROMPT_FILE" <<'EOF'
You are a brief reviewer. Reply with one short sentence:
"Smoke test acknowledged from <your-cli-name>."
EOF

trap 'rm -f "$PROMPT_FILE"' EXIT

echo "── e2e smoke test ───────────────────────────────────────────"
echo "Prompt: $PROMPT_FILE"
echo

echo "Step 1/3: preflight"
"$PLUGIN_ROOT/scripts/shared/preflight.sh" >/dev/null
preflight_rc=$?
if [[ $preflight_rc -ne 0 ]]; then
  echo "❌ preflight failed (rc=$preflight_rc)"
  exit 1
fi
echo "✅ preflight OK"
echo

echo "Step 2/3: orchestrator (parallel reviewer fan-out)"
ORCH_OUT=$(mktemp -t orch-out.XXXXXX)
"$ORCHESTRATOR" "$PROMPT_FILE" | tee "$ORCH_OUT"
orch_rc=${PIPESTATUS[0]}
echo
echo "(orchestrator rc=$orch_rc)"

WORKDIR=$(awk '/^WORKDIR /{print $2; exit}' "$ORCH_OUT")
[[ -z "$WORKDIR" || ! -d "$WORKDIR" ]] && {
  echo "❌ workdir not captured"
  rm -f "$ORCH_OUT"
  exit 1
}
echo

# Validate event stream coverage.
ok_count=$(grep -c '^RETURN ' "$ORCH_OUT" || true)
fail_count=$(grep -c '^FAIL ' "$ORCH_OUT" || true)
skip_count=$(grep -c '^SKIP ' "$ORCH_OUT" || true)

echo "Events: RETURN=$ok_count SKIP=$skip_count FAIL=$fail_count"

if (( ok_count == 0 )); then
  echo "❌ no successful reviewer"
  rm -f "$ORCH_OUT"
  exit 1
fi

# Validate finals are non-empty for RETURN events.
while IFS= read -r line; do
  final=$(awk '{print $4}' <<<"$line")
  if [[ ! -s "$final" ]]; then
    echo "❌ RETURN reported but final empty: $final"
    rm -f "$ORCH_OUT"
    exit 1
  fi
done < <(grep '^RETURN ' "$ORCH_OUT")

echo "✅ orchestrator wrote finals for all RETURN events"
rm -f "$ORCH_OUT"
echo

echo "Step 3/3: MAGI consensus report"
report=$("$MAGI" "$WORKDIR")
[[ -f "$report" ]] || { echo "❌ magi-consensus produced no report"; exit 1; }
echo "✅ MAGI report: $report"
echo
echo "── Report (preview) ─────────────────────────────────────────"
head -40 "$report"
echo "..."
echo
echo "── Workdir contents ─────────────────────────────────────────"
ls -la "$WORKDIR"
echo
echo "✅ e2e smoke test passed"
