#!/usr/bin/env bash
# End-to-end fallback test: drives the orchestrator with mock adapters that
# simulate quota / auth / missing / empty-final failures. Verifies the
# fallback policy and SKIP/FAIL semantics without consuming real API quota.
#
# Strategy:
#   • Build a temp config that points to mock adapters (via cli_paths and
#     an alternate adapter dir layout).
#   • For simplicity, we override the adapter scripts via a temp plugin root
#     that symlinks scripts/shared and substitutes adapters/.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
MAGI="$PLUGIN_ROOT/scripts/shared/magi-consensus.sh"

TMP_ROOT=$(mktemp -d -t magi-fb-test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/skills/review-plan/scripts/adapters"
mkdir -p "$TMP_ROOT/scripts/shared"
mkdir -p "$TMP_ROOT/config"

# Mirror shared scripts.
ln -s "$PLUGIN_ROOT/scripts/shared/extract-final.sh"   "$TMP_ROOT/scripts/shared/"
ln -s "$PLUGIN_ROOT/scripts/shared/error-patterns.sh"  "$TMP_ROOT/scripts/shared/"
ln -s "$PLUGIN_ROOT/scripts/shared/nvm-exec.sh"        "$TMP_ROOT/scripts/shared/"
ln -s "$PLUGIN_ROOT/scripts/shared/magi-consensus.sh"  "$TMP_ROOT/scripts/shared/"
ln -s "$PLUGIN_ROOT/scripts/shared/preflight.sh"       "$TMP_ROOT/scripts/shared/"
ln -s "$PLUGIN_ROOT/skills/review-plan/scripts/orchestrator.sh" \
      "$TMP_ROOT/skills/review-plan/scripts/orchestrator.sh"

ADAPTERS="$TMP_ROOT/skills/review-plan/scripts/adapters"

# Mock claude: succeeds with canned output.
cat >"$ADAPTERS/claude.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  --healthcheck) echo "status=ok"; echo "version=mock-1.0"; exit 0 ;;
  run)
    config="$2"; prompt="$3"; log="$4"; final="$5"
    echo "[mock claude] processing $prompt" >>"$log"
    cat >"$final" <<EOF
🔴 Critical: Mock issue A in src/foo.ts
🟡 Important: Mock note B
🟢 Pass: looks good overall
EOF
    exit 0
    ;;
esac
exit 2
MOCK

# Mock gemini: fails with quota.
cat >"$ADAPTERS/gemini.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  --healthcheck) echo "status=ok"; echo "version=mock-1.0"; exit 0 ;;
  run)
    config="$2"; prompt="$3"; log="$4"; final="$5"
    echo "RESOURCE_EXHAUSTED: gemini quota for project ABC" >>"$log"
    exit 11
    ;;
esac
exit 2
MOCK

# Mock codex: fails with auth error.
cat >"$ADAPTERS/codex.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  --healthcheck) echo "status=ok"; echo "version=mock-1.0"; exit 0 ;;
  run)
    config="$2"; prompt="$3"; log="$4"; final="$5"
    echo "401 unauthorized: codex token expired" >>"$log"
    exit 12
    ;;
esac
exit 2
MOCK

chmod +x "$ADAPTERS"/*.sh

# Mock config: lenient policy, claude required, others optional.
cat >"$TMP_ROOT/config/default.json" <<'CFG'
{
  "version": "test",
  "xreview": {
    "reviewers": [
      {"cli": "claude", "model": "opus",    "weight": 1, "required": true},
      {"cli": "gemini", "model": "default", "weight": 1, "required": false},
      {"cli": "codex",  "model": "default", "weight": 1, "required": false}
    ],
    "magi": {"mode": "majority", "threshold": null, "degraded_mode": "warn_user"},
    "fallback_policy": "lenient",
    "min_successful_reviewers": 1,
    "timeout_seconds": 60,
    "quota_error_patterns": {"claude": [], "gemini": [], "codex": []},
    "auth_error_patterns":  {"claude": [], "gemini": [], "codex": []}
  },
  "node": {"use_nvm": false, "default_version": "", "cli_paths": {}},
  "output_language": "en"
}
CFG

PROMPT=$(mktemp -t magi-fb-prompt.XXXXXX.md)
echo "Mock review prompt." >"$PROMPT"
trap 'rm -rf "$TMP_ROOT" "$PROMPT"' EXIT

echo "── e2e fallback test ────────────────────────────────────────"
echo "Mock plugin root: $TMP_ROOT"

ORCH_OUT=$(mktemp -t orch-fb.XXXXXX)
MAGI_CONFIG_PATH="$TMP_ROOT/config/default.json" \
  "$TMP_ROOT/skills/review-plan/scripts/orchestrator.sh" "$PROMPT" \
  | tee "$ORCH_OUT"
orch_rc=${PIPESTATUS[0]}
echo "(orchestrator rc=$orch_rc)"
echo

# Expectations:
#   • claude → RETURN
#   • gemini → SKIP reason=quota
#   • codex  → SKIP reason=auth
#   • policy_pass=true (lenient + min_ok=1)
ret=$(grep -c '^RETURN ' "$ORCH_OUT" || true)
skip=$(grep -c '^SKIP ' "$ORCH_OUT" || true)
fail=$(grep -c '^FAIL ' "$ORCH_OUT" || true)
all_done=$(grep -E '^ALL_DONE ' "$ORCH_OUT")

echo "Events: RETURN=$ret SKIP=$skip FAIL=$fail"
echo "Final:  $all_done"
echo

if (( ret != 1 || skip != 2 || fail != 0 )); then
  echo "❌ unexpected event counts (want RETURN=1 SKIP=2 FAIL=0)"
  rm -f "$ORCH_OUT"
  exit 1
fi
if ! grep -q 'reason=quota' "$ORCH_OUT"; then
  echo "❌ missing SKIP reason=quota"
  rm -f "$ORCH_OUT"; exit 1
fi
if ! grep -q 'reason=auth' "$ORCH_OUT"; then
  echo "❌ missing SKIP reason=auth"
  rm -f "$ORCH_OUT"; exit 1
fi
if ! grep -q 'policy_pass=true' <<<"$all_done"; then
  echo "❌ policy_pass should be true (lenient + claude succeeded)"
  rm -f "$ORCH_OUT"; exit 1
fi
echo "✅ event stream + fallback policy as expected"

WORKDIR=$(awk '/^WORKDIR /{print $2; exit}' "$ORCH_OUT")
rm -f "$ORCH_OUT"

echo
echo "Step: MAGI consensus on degraded outcome"
report=$("$MAGI" "$WORKDIR")
[[ -f "$report" ]] || { echo "❌ no MAGI report"; exit 1; }

if ! grep -q 'DEGRADED MODE' "$report"; then
  echo "❌ degraded warning missing from MAGI report"
  exit 1
fi
echo "✅ MAGI report flagged degraded mode"
echo
head -25 "$report"
echo "..."
echo
echo "✅ e2e fallback test passed"
