#!/usr/bin/env bash
# Gemini CLI adapter for magi xreview orchestrator.
# Wraps invocations with nvm exec to avoid wrong-node-version traps.
#
# Modes & exit codes: see claude.sh

set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$ADAPTER_DIR/../../../../scripts/shared" && pwd)"
CLI_NAME="gemini"

# shellcheck source=../../../../scripts/shared/extract-final.sh
. "$SHARED_DIR/extract-final.sh"
# shellcheck source=../../../../scripts/shared/error-patterns.sh
. "$SHARED_DIR/error-patterns.sh"
# shellcheck source=../../../../scripts/shared/nvm-exec.sh
. "$SHARED_DIR/nvm-exec.sh"

# Run gemini under the resolved node version. Captures stdout/stderr.
# Args: <config> <stdout-file> <stderr-file> [extra-gemini-args...]
# Note: prompt is read from stdin to avoid argv length limits.
run_gemini_via_node() {
  local config="$1" stdout_file="$2" stderr_file="$3"
  shift 3

  local bin
  bin=$(resolve_cli_path "$config" "$CLI_NAME" 2>/dev/null || true)
  if [[ -z "$bin" ]]; then
    echo "$CLI_NAME not found via override / nvm / PATH" >>"$stderr_file"
    return 127
  fi

  # Run in a subshell that loads nvm.sh and switches to the right node version.
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
  out=$(mktemp -t gemini-hc.XXXXXX); err=$(mktemp -t gemini-hc.XXXXXX); rc=0
  run_gemini_via_node "$config" "$out" "$err" --version || rc=$?

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

  local raw_out args
  raw_out=$(mktemp -t gemini-raw.XXXXXX)
  args=(--prompt "$(cat "$prompt_file")" --yolo --output-format text)
  if [[ -n "$model" && "$model" != "default" ]]; then
    args+=(--model "$model")
  fi

  local rc=0
  run_gemini_via_node "$config" "$raw_out" "$log_file" "${args[@]}" || rc=$?

  if match_error_pattern "$log_file" "$config" "quota_error_patterns" "$CLI_NAME"; then
    rm -f "$raw_out"
    return 11
  fi
  if match_error_pattern "$log_file" "$config" "auth_error_patterns" "$CLI_NAME"; then
    rm -f "$raw_out"
    return 12
  fi

  if [[ $rc -ne 0 ]]; then
    rm -f "$raw_out"
    return 1
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
    --healthcheck)
      shift
      mode_healthcheck "${1:?config path required}"
      ;;
    run)
      shift
      mode_run "$@"
      ;;
    *)
      echo "Unknown mode: $1" >&2
      exit 2
      ;;
  esac
}

main "$@"
