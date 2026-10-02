---
name: breakout
description: >-
  Open a fresh chat in a new Warp tab running the SAME CLI as the current session
  (Claude Code or Codex), optionally seeded with a starting prompt, while the current
  session keeps running untouched. Use when the user wants to "break out" into a new
  chat - to start a clean session, or to continue work in a fresh context with a
  seed prompt ("breakout", "open a new chat", "start a fresh chat in a new tab",
  "move this into a new tab", "hand off then break out"). Do NOT use to delegate
  background work you need a result back from (that is a subagent), or to capture a
  task.
---

# Breakout

Open a new, independent chat in a fresh **Warp tab**, running **whichever CLI the
current session is in** (Claude Code or Codex, auto-detected), optionally seeded
with a starting prompt. The current session is never paused. Use it directly to
start a clean chat, or after a handoff to continue work in a fresh context. A
subagent is no substitute - it runs autonomously and returns a result, and cannot be
conversed with; a real chat only exists as a new `claude` (or `codex`) session.

Breakout owns **which CLI to open and what the seed says**; the sibling
**`new-warp-chat`** skill owns the whole Warp mechanism (the self-deleting tab
config, TOML escaping, the PowerShell 5.1 seed-quoting, the `warp://` URI). Only
Warp is supported: on another terminal, say so and stop. If support is ever added,
the plugin's WezTerm driver (the one `shared-pane` uses) is the candidate engine.

## Steps

**1. Detect the current CLI.** The new session must run **the same CLI you are
running in now**. Read the environment to decide, in priority order:

- **Warp's `AI_AGENT`** (Warp sets it per pane to the active agent): a value
  starting `claude` -> **Claude Code**; starting `codex` -> **Codex**. This is the
  terminal's own agent marker and the most CLI-neutral signal - prefer it.
- **CLI-specific env** as corroboration: `CLAUDECODE=1` / `CLAUDE_CODE_*` ->
  Claude Code; Codex's own `CODEX_*` markers -> Codex.
- **If still ambiguous**, ask the user which CLI to open - do not guess.

**2. Resolve the launch command; do NOT pick the args.** The command is the detected
CLI. The **launch args come from the user's own config for that CLI**: the agent
menu's `agents.yaml` block (its `new` line, or `resume` for a resume) when there is
one, else the standing Warp tab config (`<tab_configs>/claude.toml` or `codex.toml`,
the `-resume` variant for a resume). That is how a CLI is launched here, any machine
or tenant pin (model, reasoning effort, permission mode) included. `new-warp-chat`
inherits them when you omit the args, so breakout **adds only two things**:

- the **working directory**, when the new tab must land in a specific project and
  the CLI takes it as a flag (Codex `-C <dir>`) - via extra args;
- the **seed** (step 3).

Drop or override a flag **only when the user asks**: `-ExtraArgs` to add to the set,
an explicit `-LaunchArgs` to replace it. Never restate the standing flags here, and
never carry a model name in this skill. Without either source the launcher
falls back to the plain CLI (no extra flags; a resume keeps only what resume needs)
and says so; that table, and how a user who wants a permission mode or other flag
gets it, are in [new-warp-chat's reference](../new-warp-chat/references/launch-mechanics.md).

**3. Prepare the seed (if any).** Write it to a temp file with the Write tool: per
the launcher's contract the seed never transits a command line, so quotes / `$` /
backticks survive any shell. Continuing a workflow (after a handoff), the seed must
be a **self-contained kickoff prompt** - what the new chat is, the goal, the next
step - since the fresh context inherits none of this conversation. Keep it tight.

**4. Launch via `new-warp-chat`.** Follow the sibling skill's SKILL.md: tab name
`breakout`, the step-1 CLI as the command, **no `-LaunchArgs`** (the standing tab
config's args are inherited), step-2 additions as `-ExtraArgs`, the step-3 seed
file. On Windows that is one call to its bundled helper (with no `-LaunchArgs`
it reads the user's config itself), the sibling skill's script in the same plugin:
`../new-warp-chat/scripts/new-warp-chat.ps1` from this skill's folder, called by
absolute path:

```powershell
# $SkillDir = the absolute path of this skill's folder
& "$SkillDir/../new-warp-chat/scripts/new-warp-chat.ps1" `
    -TabName breakout -LaunchCmd <cli> [-ExtraArgs '-C <dir>'] -SeedFile '<seed>'
```

(**Omit `-SeedFile` entirely** for an empty chat; omit `-ExtraArgs` when there is
nothing to add.) On macOS / Linux follow new-warp-chat's model-driven inline path
(resolve the args in the same order, compose the self-deleting tab command, write
the config, fire the URI). **Never hand-assemble the Windows command line** -
PowerShell 5.1 truncates a seed at its first `"`; the escaping lives in the launcher
precisely so that bug cannot regress.

**5. Confirm.** You cannot see the new tab - report what you launched, the args and
the file they were inherited from (the launcher prints both), and ask what opened.

## Notes

- The launcher's throwaway `breakout.toml` is distinct from the standing
  `claude.toml` / `codex.toml` (and any `-resume` variants) in the same dir. It
  self-deletes, so no `breakout` entry lingers in Warp's `+` menu beyond a flicker.
- New Warp tabs inherit the current tab's working directory, so a handoff that
  continues work lands in the same project for free.
- The new session matches the **current** CLI (step 1): a breakout from Claude opens
  Claude, from Codex opens Codex. The Codex branch (`AI_AGENT` starting `codex`,
  seed as a positional prompt) mirrors the Claude path and has been verified
  against real Codex sessions.
- This skill needs Warp running. The user's own config (the agent menu's
  `agents.yaml`, else the standing Warp tab configs) holds a machine's launch
  flags: if a breakout comes up on the wrong model or permission mode, fix that
  config, not this skill. It does not
  detect or support other terminals.
