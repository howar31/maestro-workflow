---
name: maestro.setup
description: First-run onboarding wizard for maestro-workflow. Runs healthchecks on installed CLIs (claude/gemini/codex), records the user's preferred reviewer roster and weights into ~/.config/maestro-workflow/config.json, and validates end-to-end with a small dry-run. Use --recheck to re-validate without resetting config; --reset to wipe and start over.
disable-model-invocation: true
---

# /maestro.setup — onboarding wizard

You are the coordinator. Walk the user through configuring this plugin so the
multi-CLI orchestration works on their machine. Be interactive and helpful —
this is the user's first impression of the workflow.

## 0. Resolve paths

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/maestro-workflow/config.json"
DEFAULT_CONFIG="$PLUGIN_ROOT/config/default.json"
```

Verify `$PLUGIN_ROOT/scripts/shared/preflight.sh` exists. If not, the plugin is
installed incorrectly — tell the user and stop.

## 1. Subcommand handling

Inspect the arguments passed to the slash command:

- **`--reset`**: delete `$USER_CONFIG` (after confirming with user), then run
  the full wizard.
- **`--recheck`**: skip the wizard. Run preflight only. If the user has no
  config yet, fall through to the full wizard.
- **(no flag)**: if `$USER_CONFIG` already exists, ask the user whether to
  re-run the wizard (it will overwrite). If they decline, run preflight to
  show current state and exit.

## 2. Run preflight

```bash
"$PLUGIN_ROOT/scripts/shared/preflight.sh"
```

Parse the JSON. The shape is:

```jsonc
{
  "config_path": "...",
  "reviewers": [
    {"cli": "claude", "model": "opus", "status": "ok|skip|fail", "reason": "...", "version": "..."},
    ...
  ],
  "summary": {"ok": N, "skip": M, "fail": K, "total": T}
}
```

Display a friendly table to the user (in `output_language`, default zh-TW):

| CLI | Status | Version | Notes |
|-----|--------|---------|-------|
| claude | ✅ ok | 2.x.x | available |
| gemini | ⏭️ skip | — | reason |
| codex | ✅ ok | 0.x.x | available |

If `summary.ok == 0`, abort with a message: at least `claude` must work for
this plugin to function. Suggest running `claude login` and re-running.

## 3. Reviewer roster

For each detected CLI, ask the user (via AskUserQuestion or chat) whether to
enable it as a reviewer. Default selections:

- `claude`: enabled, `required: true`, `weight: 2`
- `gemini`: enabled if healthcheck ok, `required: false`, `weight: 1`
- `codex`: enabled if healthcheck ok, `required: false`, `weight: 1`

Ask in **one consolidated AskUserQuestion** if possible. Provide the
"Recommended" defaults so they can accept with one click.

After roster selection, ask for weights only if they want to deviate from
defaults. Recommend the default ratio (claude:2, others:1) — it ensures
opus is influential but cannot pass `majority` alone.

## 4. MAGI mode

Ask the user for a default voting mode:

- **majority** (recommended) — adopt issue if `vote_sum > ok_weight × 0.5`.
  Sensible for daily code review.
- **supermajority** — `>= 2/3`. For architectural decisions.
- **unanimous** — all reviewers must agree. For irreversible / production /
  IAM changes. Note that this requires all `required` reviewers; warn the
  user that pairing `unanimous` with `required: false` reviewers makes
  sense only if they are aware that a SKIP will abort.

Per-invocation override is always possible via `/maestro.review --magi <mode>`,
so this is just the default.

## 5. Node / nvm

Detect `~/.nvm/nvm.sh`. If present:

- Read `nvm ls` to find installed versions.
- Suggest the most recent LTS (typically Node 22).
- Write `node.use_nvm: true`, `node.default_version: <chosen>`.

If no nvm, set `node.use_nvm: false`. Note that npm-based CLIs (gemini,
codex) may then resolve via system PATH and could break on shebang issues —
warn the user.

## 6. Output language

Ask the user for `output_language` — the language the plugin will use when
generating PLAN.md / SPEC.md / TASKS.md / WORKS.md. Defaults from current
config or `zh-TW`. Plugin internal text remains in English regardless.

## 7. Write config

Build the JSON object (preserve unset fields by reading `$DEFAULT_CONFIG`
as the base and overlaying user choices). Create `~/.config/maestro-workflow/`
if needed and write `$USER_CONFIG` with `chmod 644`.

Validate with `jq '.' "$USER_CONFIG"` before declaring success.

## 8. Dry-run validation

Run a small end-to-end test to confirm the config works:

```bash
PROMPT=$(mktemp -t maestro-setup-prompt.XXXXXX.md)
echo "Setup validation: please reply with 'maestro setup OK from <your-cli-name>'." > "$PROMPT"

MAESTRO_CONFIG_PATH="$USER_CONFIG" \
  "$PLUGIN_ROOT/skills/maestro.xreview-plan/scripts/orchestrator.sh" "$PROMPT"

rm -f "$PROMPT"
```

Read the resulting workdir. Confirm at least one `RETURN` event. Show the
user the per-reviewer outputs (truncated). If `policy_pass=false`, explain
what failed and offer to re-run setup or skip the dry-run.

## 9. Onboarding summary

End with a short user-facing summary in `output_language`:

- Configured reviewers (with weights + required flags)
- Active MAGI mode
- Config location: `$USER_CONFIG`
- Next steps:
  - `/maestro.plan "<feature description>"` — start a new feature
  - `/maestro.setup --recheck` — re-validate after CLI / Node updates
  - `/maestro.setup --reset` — start over

## Conventions

- Never write secrets (API keys, tokens) into config — these belong in each
  CLI's own auth (e.g., `GEMINI_API_KEY`, `~/.codex/auth.json`,
  `claude login`).
- Always show the user the final config JSON before writing.
- If the user pastes their own JSON, run it through `jq` to validate before
  saving.
- When `claude` itself fails healthcheck, do not proceed to write config.
  Instead surface the actionable error.
