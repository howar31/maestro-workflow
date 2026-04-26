#!/usr/bin/env bash
# Claude CLI adapter for magi xreview orchestrator.
#
# Modes:
#   --healthcheck <config>
#     Outputs key=value lines to stdout; exit 0 (ok) / 1 (skip) / 2 (fail).
#   run <config> <prompt-file> <log> <final> [model]
#     Runs claude in headless mode; writes log + final, exits per convention:
#       0 ok, 11 skip-quota, 12 skip-auth, 13 skip-missing, 14 skip-empty,
#       1 fail (other).

set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="$(cd "$ADAPTER_DIR/../../../../scripts/shared" && pwd)"
CLI_NAME="claude"

# shellcheck source=../../../../scripts/shared/extract-final.sh
. "$SHARED_DIR/extract-final.sh"
# shellcheck source=../../../../scripts/shared/error-patterns.sh
. "$SHARED_DIR/error-patterns.sh"
# shellcheck source=../../../../scripts/shared/nvm-exec.sh
. "$SHARED_DIR/nvm-exec.sh"

mode_healthcheck() {
  local config="$1"
  local bin
  bin=$(resolve_cli_path "$config" "$CLI_NAME" 2>/dev/null || true)

  if [[ -z "$bin" ]]; then
    echo "status=skip"
    echo "reason=$CLI_NAME not found in PATH or config.cli_paths"
    return 1
  fi

  local version
  version=$("$bin" --version 2>&1 | head -1 || true)
  if [[ -z "$version" ]]; then
    echo "status=fail"
    echo "reason=$CLI_NAME --version produced no output"
    return 2
  fi

  echo "status=ok"
  echo "reason=available"
  echo "version=$version"
  echo "path=$bin"
  return 0
}

mode_run() {
  local config="$1" prompt_file="$2" log_file="$3" final_file="$4"
  local model="${5:-}"

  : >"$log_file"
  : >"$final_file"

  local bin
  bin=$(resolve_cli_path "$config" "$CLI_NAME" 2>/dev/null || true)
  if [[ -z "$bin" ]]; then
    echo "$CLI_NAME not found" >>"$log_file"
    return 13
  fi

  # Build args. Use --print (-p) for headless, --output-format text default.
  local args=(--print --output-format text)
  if [[ -n "$model" ]]; then
    args+=(--model "$model")
  fi
  args+=(--input-format text)

  # Read prompt and pipe via stdin (more robust than command-line for long prompts).
  # claude -p reads prompt from stdin when no positional prompt given.
  local raw_out
  raw_out=$(mktemp -t claude-raw.XXXXXX)

  local rc=0
  "$bin" "${args[@]}" <"$prompt_file" >"$raw_out" 2>"$log_file" || rc=$?

  # Inspect failure patterns regardless of exit code.
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

  # Extract final message (claude --print text mode is already plain text).
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
