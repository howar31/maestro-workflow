#!/usr/bin/env bash
# Shared library: extract final assistant message from CLI output.
# Source this file from adapters; do not execute directly.
#
# Each CLI may have multiple output formats. This file provides
# extractor functions that take a raw output file (or stdin) and
# write the final assistant message to stdout.
#
# Adapters call these via dispatch_extractor:
#   dispatch_extractor <cli> <mode> <input-file> > <final-file>

set -euo pipefail

# Plain text passthrough. Used when CLI outputs only the final reply.
extract_plain() {
  local input="$1"
  cat "$input"
}

# Claude CLI stream-json mode: JSONL of events. Final assistant text is
# the concatenation of all "assistant" message text deltas.
extract_claude_stream_json() {
  local input="$1"
  jq -rs '
    [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text ]
    | join("")
  ' "$input"
}

# Claude CLI single-json mode: one JSON object with .result string.
extract_claude_single_json() {
  local input="$1"
  jq -r '.result // .response // empty' "$input"
}

# Gemini CLI default: prints reply to stdout with possible header noise.
# Best-effort: strip ANSI, strip leading/trailing whitespace.
# Use POSIX cat -s instead of GNU-only sed multiline syntax (BSD sed on macOS
# rejects /^$/{ N; /^\n$/D }).
extract_gemini_plain() {
  local input="$1"
  sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$input" \
    | awk 'NF { found = 1 } found' \
    | cat -s
}

# Codex CLI default: similar to gemini, plain text reply on stdout.
extract_codex_plain() {
  local input="$1"
  sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$input"
}

dispatch_extractor() {
  local cli="$1" mode="$2" input="$3"
  case "${cli}:${mode}" in
    claude:plain)        extract_plain "$input" ;;
    claude:stream-json)  extract_claude_stream_json "$input" ;;
    claude:single-json)  extract_claude_single_json "$input" ;;
    gemini:plain)        extract_gemini_plain "$input" ;;
    codex:plain)         extract_codex_plain "$input" ;;
    *:plain)             extract_plain "$input" ;;
    *)
      echo "extract-final: unknown extractor ${cli}:${mode}" >&2
      return 2
      ;;
  esac
}

# If executed directly (not sourced), dispatch from CLI args.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <cli> <mode> <input-file>" >&2
    exit 2
  fi
  dispatch_extractor "$1" "$2" "$3"
fi
