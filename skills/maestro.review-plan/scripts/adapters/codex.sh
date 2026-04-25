#!/usr/bin/env bash
# Codex CLI adapter for maestro-workflow xreview orchestrator.
# Uses `codex exec` for non-interactive runs. Wraps via nvm.

set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$ADAPTER_DIR/../../../../scripts/shared" && pwd)"
CLI_NAME="codex"

# shellcheck source=../../../../scripts/shared/extract-final.sh
. "$SHARED_DIR/extract-final.sh"
# shellcheck source=../../../../scripts/shared/error-patterns.sh
. "$SHARED_DIR/error-patterns.sh"
# shellcheck source=../../../../scripts/shared/nvm-exec.sh
. "$SHARED_DIR/nvm-exec.sh"

run_codex_via_node() {
  local config="$1" stdout_file="$2" stderr_file="$3"
  shift 3

  local bin
  bin=$(resolve_cli_path "$config" "$CLI_NAME" 2>/dev/null || true)
  if [[ -z "$bin" ]]; then
    echo "$CLI_NAME not found via override / nvm / PATH" >>"$stderr_file"
    return 127
  fi

  local node_ver use_nvm
  use_nvm=$(jq -r '.node.use_nvm // false' "$config" 2>/dev/null || echo "false")
  node_ver=$(jq -r --arg cli "$CLI_NAME" '
    .xreview.node_version_per_cli[$cli]
    // .node.default_version
    // empty
  ' "$config" 2>/dev/null || true)

  if [[ "$use_nvm" == "true" && -n "$node_ver" && -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    (
      export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
      \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1
      nvm use "$node_ver" >/dev/null 2>&1
      "$bin" "$@" >"$stdout_file" 2>"$stderr_file"
    )
    return $?
  fi

  "$bin" "$@" >"$stdout_file" 2>"$stderr_file"
  return $?
}

mode_healthcheck() {
  local config="$1"

  local out err rc
  out=$(mktemp -t codex-hc.XXXXXX); err=$(mktemp -t codex-hc.XXXXXX); rc=0
  run_codex_via_node "$config" "$out" "$err" --version || rc=$?

  local version
  version=$(head -1 "$out" 2>/dev/null || true)

  if [[ $rc -ne 0 || -z "$version" ]]; then
    local reason
    reason=$(head -3 "$err" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | head -c 200)
    [[ -z "$reason" ]] && reason="non-zero exit ($rc) from $CLI_NAME --version"
    echo "status=skip"
    echo "reason=$reason"
    rm -f "$out" "$err"
    return 1
  fi

  echo "status=ok"
  echo "reason=available"
  echo "version=$version"
  rm -f "$out" "$err"
  return 0
}

mode_run() {
  local config="$1" prompt_file="$2" log_file="$3" final_file="$4"
  local model="${5:-}"

  : >"$log_file"
  : >"$final_file"

  local raw_out
  raw_out=$(mktemp -t codex-raw.XXXXXX)

  # codex exec reads prompt from positional argument or stdin.
  # We pass the prompt via stdin (using "-" as prompt arg).
  local args=(exec --skip-git-repo-check)
  if [[ -n "$model" && "$model" != "default" ]]; then
    args+=(--model "$model")
  fi
  args+=(-)

  local rc=0
  # codex needs stdin; call via subshell with redirect.
  local config_abs="$config"
  # Use a wrapper to pipe prompt into codex.
  # run_codex_via_node doesn't currently support stdin redirection; do it inline:
  local bin node_ver use_nvm
  bin=$(resolve_cli_path "$config_abs" "$CLI_NAME" 2>/dev/null || true)
  if [[ -z "$bin" ]]; then
    echo "$CLI_NAME not found" >>"$log_file"
    rm -f "$raw_out"
    return 13
  fi
  use_nvm=$(jq -r '.node.use_nvm // false' "$config_abs" 2>/dev/null || echo "false")
  node_ver=$(jq -r --arg cli "$CLI_NAME" '
    .xreview.node_version_per_cli[$cli] // .node.default_version // empty
  ' "$config_abs" 2>/dev/null || true)

  if [[ "$use_nvm" == "true" && -n "$node_ver" && -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    (
      export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
      \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1
      nvm use "$node_ver" >/dev/null 2>&1
      "$bin" "${args[@]}" <"$prompt_file" >"$raw_out" 2>"$log_file"
    )
    rc=$?
  else
    "$bin" "${args[@]}" <"$prompt_file" >"$raw_out" 2>"$log_file"
    rc=$?
  fi

  if match_error_pattern "$log_file" "$config" "quota_error_patterns" "$CLI_NAME"; then
    rm -f "$raw_out"; return 11
  fi
  if match_error_pattern "$log_file" "$config" "auth_error_patterns" "$CLI_NAME"; then
    rm -f "$raw_out"; return 12
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$raw_out"; return 1
  fi

  dispatch_extractor "$CLI_NAME" "plain" "$raw_out" >"$final_file"
  rm -f "$raw_out"

  if [[ ! -s "$final_file" ]]; then
    return 14
  fi
  return 0
}

main() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 --healthcheck <config> | run <config> <prompt> <log> <final> [model]" >&2
    exit 2
  fi
  case "$1" in
    --healthcheck) shift; mode_healthcheck "${1:?config required}" ;;
    run) shift; mode_run "$@" ;;
    *) echo "Unknown mode: $1" >&2; exit 2 ;;
  esac
}

main "$@"
