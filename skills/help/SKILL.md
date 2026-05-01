---
name: help
description: Quick reference for magi-workflow. Bare invocation prints the full command roster, the standard workflow diagram, subagent roles, and common override flags, plus a state-aware "next step" hint when run inside a magi project. Pass a command name (e.g., /magi:help plan) to print details for one command extracted from its SKILL.md. Always allowed regardless of project state — this is the entry point users reach for when they don't remember which command to run.
---

# /magi:help — quick reference & next-step hint

You are the coordinator. This skill is a read-only reference printer. **Do
not modify any files, do not call subagents, do not invoke external CLIs.**
Output goes to the user as plain markdown.

## 0. Resolve paths

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

Verify `$PLUGIN_ROOT/skills` is a directory. If not, the plugin is installed
incorrectly — print a one-line error pointing to the install instructions
and stop.

## 0.1. Output language

Read `output_language` from `$USER_CONFIG` if it exists; default `zh-TW`.
Missing config is **not** an error — `/magi:help` must work before
`/magi:setup` has ever been run, since "I don't know what to do" is exactly
when users reach for help.

```bash
LANG_PREF="zh-TW"
if [[ -f "$USER_CONFIG" ]]; then
  LANG_PREF=$(jq -r '.output_language // "zh-TW"' "$USER_CONFIG" 2>/dev/null || echo "zh-TW")
fi
```

Section headers and ASCII flow diagrams stay English (matching README
conventions); descriptive prose follows `LANG_PREF`.

## 0.2. State preflight (fail-soft)

Try to read project state; never refuse. Help is unconditionally allowed,
but the reading lets the overview append a "current state → suggested next"
hint at the end.

```bash
STATE_JSON=""
if STATE_RAW=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh" 2>/dev/null); then
  STATE_JSON="$STATE_RAW"
fi
```

If `STATE_JSON` is empty (not in a git repo, or detect-state errored), skip
the next-step hint section and emit the static overview only.

## 1. Argument parsing

```
/magi:help                  → overview mode
/magi:help <name>           → detail mode for skills/<resolved>/SKILL.md
/magi:help --list           → bare command list, no flow diagram or hint
```

Resolve `<name>`:

- Accept `plan`, `plan`, or `/magi:plan`
- Strip leading `/` and `magi.` prefix; the remainder must match a directory
  under `$PLUGIN_ROOT/skills/magi.<remainder>/`
- Unknown name → print `unknown command: <name>` and the bare command list,
  then exit

## 2. Overview mode (`/magi:help` with no argument)

Output five sections in order. **Do not** hard-code descriptions for each
command — pull them live from `skills/magi.<name>/SKILL.md` frontmatter so
this skill never drifts from the source of truth.

### Section A — Command roster

Build the list dynamically:

```bash
for dir in "$PLUGIN_ROOT"/skills/magi.*/; do
  name=$(basename "$dir")
  desc=$(awk '/^description:/{sub(/^description: */,""); print; exit}' "$dir/SKILL.md")
  printf '%-32s  %s\n' "/$name" "$desc"
done | sort
```

Render as a markdown table with three columns:

| Command | Purpose | When |
|---------|---------|------|
| `/magi:help` | (description from this SKILL.md) | any time |
| `/magi:setup` | (description from setup) | once per machine |
| ... | ... | ... |

The "When" column is a short hand-curated label. Use this fixed mapping
(it is the only place help duplicates info from CLAUDE.md — see
"Conventions" below for why):

- `help` → any time
- `status` → any time
- `setup` → once per machine
- `init` → once per project
- `plan` → start of every change
- `tasks` → after plan, for major work
- `review-plan` → optional, after plan
- `go` → per work session
- `review-code` → before commit (mandatory in sprint flow)
- `commit` → end of every change
- `yolo` → walk-away mode
- `web-frontend-spec` / `.backend.spec` / `.infra.plan` / `.ci.spec`
  → between plan and tasks (web work)

Keep descriptions to one line each. If a `description:` field spans
multiple lines (it shouldn't, but defensively), truncate at the first
period or 200 chars.

### Section B — Standard workflow

Print this ASCII diagram verbatim (English, language-independent):

```
First-time setup:
  /magi:setup  →  /magi:init

Per change:
  /magi:plan  →  [/magi:review-plan?]  →  /magi:tasks  →  /magi:go
              →  /magi:review-code  →  /magi:commit

Walk-away:
  /magi:yolo "<desc>"        # fresh
  /magi:yolo --resume        # continue latest sprint

Web add-ons (between plan and tasks):
  /magi:web-frontend-spec   /magi:web-backend-spec
  /magi:web-infra-plan      /magi:web-ci-spec

Note: /magi:plan creates plan documents (PLAN.md / SPEC.md / TICKET.md /
      HOTFIX.md). For interactive read-only exploration, use Claude's
      built-in /plan first, then /magi:plan to formalize.
```

### Section C — Subagents

Two-line summary (translated per `LANG_PREF`):

- `magi-developer` (Sonnet) — TDD-first implementation worker dispatched by
  `/magi:go`. Reports `DONE` / `BLOCKED`. Does not commit.
- `magi-reviewer` (Opus) — Read-only defensive reviewer. Used by
  `/magi:review-code --single` and as fallback when MAGI degrades to one.

### Section D — Common override flags

Compact list (English flag names, prose per `LANG_PREF`):

- `--model <name>` — override model for the active reviewer / worker
- `--reviewers <list>` — override reviewer roster (`/magi:review-plan`,
  `/magi:review-code`)
- `--magi <mode>` — `majority` / `supermajority` / `unanimous` / `threshold:N`
- `--single` — `/magi:review-code` uses `magi-reviewer` only
- `--parallel` / `--sequential` — force `/magi:go` parallelism mode
- `--resume` — `/magi:yolo` continues the latest sprint
- `--push` — `/magi:yolo` pushes after commit (refused on default branch)
- `--reset` / `--recheck` — `/magi:setup` wipe vs re-validate
- `--all` / `--only <list>` / `--dry-run` — `/magi:init` scope control
- `--skip-review` / `--no-root-sync` — `/magi:commit` opt-outs

For the full list see `SPEC.md` § "Override flags".

### Section E — State-aware next step

<!-- KEEP IN SYNC: skills/status/SKILL.md § Section 1 mapping table -->

Only render this section when `STATE_JSON` is non-empty. If the user
only wants this hint without the rest of the overview, point them to
`/magi:status` — same mapping, 3–6 lines of output.

```bash
state=$(jq -r .state <<<"$STATE_JSON")
has_diff=$(jq -r .has_diff <<<"$STATE_JSON")
hotfix=$(jq -r .hotfix_mode <<<"$STATE_JSON")
sprint_dir=$(jq -r '.sprint_dir // ""' <<<"$STATE_JSON")
```

Mapping (state → suggested next command):

| State | Suggestion |
|-------|------------|
| `BOOTSTRAP` | `/magi:init`（`/magi:setup` first if no `~/.config/magi-workflow/config.json` exists） |
| `INITIALIZED` | `/magi:plan "<description>"` 或 bare `/magi:plan` 從 `magi/BACKLOG.md` 選取 |
| `PLANNING` | `/magi:tasks`（hotfix → `/magi:go`；可選 `/magi:review-plan` 先 review） |
| `PLAN_REVIEWED` | `/magi:tasks` |
| `TASKS_READY` | `/magi:go` |
| `IN_PROGRESS` | 繼續 `/magi:go`；若 `has_diff` 為 true 也可 `/magi:review-code` |
| `WORK_DONE` | `/magi:review-code` |
| `CODE_REVIEWED` | `/magi:commit` |

Surface any `warnings[]` from `STATE_JSON` after the suggestion (one line
each, prefixed with the warning's `suggest`).

**Exception — `other_in_progress_sprint`**: render as
`⚠ Also in progress: <file> (IN_PROGRESS) — <suggest>` where `<file>` is
the warning's `file` field. Same special case as `/magi:status` § 1.

Format:

```
目前狀態：<state>
建議下一步：<command>
（如果有 warnings）
⚠ <warning.reason> → <warning.suggest>
（other_in_progress_sprint）
⚠ Also in progress: <file> (IN_PROGRESS) — <suggest>
```

### Footer

Print one line:

```
完整文件：README.md（流程介紹）、CLAUDE.md（AI agent 指引）、SPEC.md（架構與 state model）
詳細指令說明：/magi:help <name>，例如 /magi:help plan
```

## 3. Detail mode (`/magi:help <name>`)

After resolving `<name>` to `magi.<resolved>`:

1. Print the heading: `# /magi.<resolved>`
2. Print the `description:` field from frontmatter (one line)
3. Print the next paragraph from the SKILL.md (the role definition that
   immediately follows the `# /magi.<name> — ...` heading)
4. Extract and print Conventions / Flags / Sections relevant to usage:

```bash
# Print everything from the H1 line down to (but not including) the first
# `## 0.` section — this captures the role intro.
awk '
  /^---$/ { fence++; next }
  fence < 2 { next }
  /^## 0\./ { exit }
  { print }
' "$PLUGIN_ROOT/skills/magi.$resolved/SKILL.md"
```

5. Append a "When to run / preconditions" hint based on the
   `disallowed_skills["<name>"]` field of the live `STATE_JSON` (if
   available — fail-soft):
   - If allowed → `目前可執行` + state name
   - If disallowed → print `reason` and `suggest` from the state JSON

6. Footer: `完整 SKILL.md：skills/magi.<resolved>/SKILL.md`

Detail mode does **not** dump the full SKILL.md body — it is meant as a
quick reminder, not a replacement for reading the file.

## 4. `--list` mode

Bare list, one line per command, sorted alphabetically. No diagram, no
section headers, no state hint. Useful as input for shell completion or
when piping into another tool.

```
/magi:commit
/magi:go
/magi:help
/magi:init
/magi:plan
/magi:review-code
/magi:review-plan
/magi:setup
/magi:tasks
/magi:web-backend-spec
/magi:web-ci-spec
/magi:web-frontend-spec
/magi:web-infra-plan
/magi:yolo
```

## Conventions

- **Source of truth**: descriptions come from each skill's frontmatter.
  Never re-paraphrase here — drift between `/magi:help` and `SKILL.md` is
  the one thing this skill must avoid.
- **Exception — the "When" column** in Section A is hand-curated because
  the SKILL.md `description` field is too long for a roster cell. Keep it
  in sync with CLAUDE.md's "Mandatory?" / "Pauses for user?" columns when
  that file changes.
- **No writes**: this skill is purely a reader. It does not modify config,
  state, sprint folders, or any project file.
- **Fail-soft**: if `detect-state.sh` errors, if config is missing, or if
  invoked outside a magi project, still produce useful output. The static
  command roster works without any project context.
- **Output language**: section headers and ASCII flow stay English; prose
  follows `LANG_PREF` from config (`zh-TW` default).
