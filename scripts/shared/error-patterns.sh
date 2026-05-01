#!/usr/bin/env bash
# Shared library: classify CLI failure types from stderr/stdout.
# Source this file; do not execute directly.

set -euo pipefail

# Detect quota / rate-limit failures. Returns 0 if matched, 1 otherwise.
# Args: <stderr-file> <cli-name> <patterns-json>
#   patterns-json: jq path to quota_error_patterns.<cli> array, e.g. via:
#     jq -r '.xreview.quota_error_patterns.gemini[]?' config.json
is_quota_error() {
  local stderr_file="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -qiE "$pattern" "$stderr_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Detect auth failures. Same args as is_quota_error.
is_auth_error() {
  local stderr_file="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -qiE "$pattern" "$stderr_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Resolve config path with fallback chain:
#   $MAGI_CONFIG_PATH > ~/.config/magi-workflow/config.json > <plugin>/config/default.json
resolve_config_path() {
  local plugin_default="$1"
  if [[ -n "${MAGI_CONFIG_PATH:-}" && -f "$MAGI_CONFIG_PATH" ]]; then
    echo "$MAGI_CONFIG_PATH"
    return 0
  fi
  local user_config="$HOME/.config/magi-workflow/config.json"
  if [[ -f "$user_config" ]]; then
    echo "$user_config"
    return 0
  fi
  if [[ -f "$plugin_default" ]]; then
    echo "$plugin_default"
    return 0
  fi
  return 1
}

# Read an array of patterns from config for a given cli + category.
# Args: <config-file> <category: quota_error_patterns|auth_error_patterns> <cli>
# Outputs: one pattern per line.
read_patterns() {
  local config="$1" category="$2" cli="$3"
  jq -r --arg cli "$cli" --arg cat "$category" '
    .xreview[$cat][$cli][]? // empty
  ' "$config" 2>/dev/null
}

# Detect stream idle timeout. Returns 0 if matched, 1 otherwise.
# Args: <log-file>
is_stream_idle_timeout() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE "stream.*(idle|timeout)|idle.*timeout|connection.*timed?\s*out" "$log_file" 2>/dev/null
}

# Returns 0 if any pattern from config.xreview.<category>.<cli> matches the
# log file content; 1 otherwise. Bash 3.2 compatible (no mapfile).
# Args: <log-file> <config> <category> <cli>
match_error_pattern() {
  local log_file="$1" config="$2" category="$3" cli="$4"
  [[ -f "$log_file" ]] || return 1
  local pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if grep -qiE "$pattern" "$log_file" 2>/dev/null; then
      return 0
    fi
  done < <(read_patterns "$config" "$category" "$cli")
  return 1
}
