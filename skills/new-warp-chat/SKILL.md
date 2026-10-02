---
name: new-warp-chat
description: >-
  Shared launcher: open a new tab in the user's running Warp terminal that
  auto-runs a given command, optionally with a seed prompt as its final argument,
  leaving the current session untouched. Use when a skill or the user needs a fresh
  Warp tab running a command (a seeded onboarding tab, a one-off tool). Not for
  background work you need a result back from (a subagent), not for a fresh CLI
  chat (that is breakout, which calls this launcher), and not on terminals other
  than Warp.
---

# New Warp Chat (the shared seeded-tab launcher)

Open a new, independent **Warp tab** that auto-runs a command - e.g. a fresh CLI
chat seeded with a starting prompt - while the current session keeps running
untouched. This skill owns only the **mechanism**; the caller (a user request or a
higher-level skill such as the sibling `breakout`) owns *what* to launch and *what
the seed says*.

## The mechanism

A new tab is opened by writing a **throwaway, self-deleting config** into Warp's
`tab_configs` dir and firing the `warp://tab_config/<name>` URI: the config's one
command deletes the config itself, then runs your command, so no `<name>` entry
lingers in Warp's `+` menu. Why that is race-free, plus the per-OS paths and URI
commands: [references/launch-mechanics.md](references/launch-mechanics.md). Two
rules never bend: **never relaunch `warp.exe`** (the URI opens a tab in the
*running* Warp; launching the exe trips Warp's session restore - if Warp is not
running, stop and ask the user to open it), and **UTF-8, no BOM** (Warp's TOML
parser chokes on a BOM).

## Inputs (every caller decides these)

| Input | Meaning |
| ----- | ------- |
| tab name | Names the config file and the URI (`[A-Za-z0-9._-]+`). Use your skill's name so a stray failure is attributable. It may not equal a standing config's name (`claude`, `codex-resume`, ...) - the throwaway self-deletes. |
| command | What the tab runs, e.g. `claude` or `codex`. |
| args | **Inherited from the user's own config by default** (below). Callers add to the set with extra args (`-C <dir>`, a session id) and replace it only when the user asks. |
| seed (optional) | Text appended as the command's **final single argument** - e.g. a CLI's initial prompt. Multi-line seeds are collapsed to one line. |

Prepare any seed in a **file** (Write tool), never inline on a command line, so that
quotes, `$` and backticks survive regardless of shell. The launcher deletes the seed
file once it is baked in.

## Launch args: the user's own config

Needs Warp running. How a CLI is launched on a machine, any machine- or
tenant-specific pin included, is the user's to set; this skill and its callers
never hard-code those flags. Omit the args and the launcher inherits them from
the first source that has them, appends the caller's extras, and prints which
args it used and which file they came from:

1. the agent menu's config (`agents.yaml`, see the sibling `agent-menu` skill):
   the `<cmd>` block's `new` line, or its `resume` line for a resume;
2. the standing Warp tab config `<tab_configs>/<cmd>.toml` (`<cmd>-resume.toml`
   for a resume), for a machine without the agent menu;
3. the documented defaults table, which adds no extra flags - and it **says so**.

**Explicit args** replace the whole set, only when the user asks to drop or
override a flag. Parse rules and table: [reference](references/launch-mechanics.md).

## Windows - call the bundled helper (do not hand-assemble)

PowerShell 5.1 truncates a hand-assembled seed at its first `"`, so run
`${CLAUDE_PLUGIN_ROOT}/skills/new-warp-chat/scripts/new-warp-chat.ps1` and never
reimplement its escaping inline. Its invocation line, every flag (`-TabName`,
`-LaunchCmd`, `-ExtraArgs`, `-LaunchArgs`, `-Resume`, `-SeedFile`) and what it
escapes: [reference](references/launch-mechanics.md).

## macOS / Linux - model-driven inline

`"$(cat file)"` passes a seed verbatim in bash/zsh, so no helper is needed. Resolve
the args by the same order as the helper: the agent menu's composed line if it has
one (`bash ${CLAUDE_PLUGIN_ROOT}/skills/agent-menu/scripts/agent-menu.sh --print <cmd> new`,
or `resume`), else the standing config's `commands` entry; either minus the leading
command name, verbatim, plus any extra args. Say which file they came from, and fall
back to the reference's defaults table - saying so - only when neither exists. Then
compose the tab command (no `$S` parts if no seed):

```
rm -f '<cfg>'; S="$(cat '<seed-file>')"; rm -f '<seed-file>'; <cmd> <args> "$S"
```

Write `<tab_configs>/<name>.toml` with the Write tool (UTF-8, no BOM):

```toml
name = "<name>"
[[panes]]
id = "main"
type = "terminal"
commands = ["<the command above, TOML-escaped: \ as \\ and \" for quotes>"]
```

Fire the URI for the OS ([reference](references/launch-mechanics.md) OS table). On
every OS the new tab inherits the current tab's working directory.

## For calling skills

The contract: **you** compose the seed and pick the command; **this skill** gets it
into a new tab intact, with the launch flags the user's own config already carries. Do not restate those flags in your own skill - add to them with
extra args, override them only on the user's say-so. Current consumer: the sibling
`breakout` skill (fresh CLI chat). You cannot see the launched tab - report what you
launched and let the user confirm it appeared. Run `tests/test-seed-quoting.ps1`
after ANY change to the script - the quoting has regressed before (the reference
says what the test covers).
