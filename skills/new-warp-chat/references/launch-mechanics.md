# New Warp chat - launch mechanics

Reference material for the `new-warp-chat` skill: why the tab config is a
throwaway, how launch args are inherited, the per-OS paths and URI commands, the
Windows helper's flags and escaping, and the regression test. The procedure
lives in SKILL.md.

## The mechanism in full

Warp exposes exactly one way to open a tab in the current window from a script:
the `warp://tab_config/<name>` URI opens a new tab running a config file you
drop in Warp's `tab_configs` dir. The launcher writes a throwaway config whose
one command **deletes the config itself, then runs your command**:

- **Self-deleting, race-free.** Warp has already read the config by the time the
  tab runs its first command, so the delete never races the read - and no
  `<name>` entry lingers in Warp's `+` menu.
- **Never relaunch `warp.exe`.** The URI opens a tab in the *running* Warp;
  launching the exe instead trips Warp's session restore. If Warp is not
  running, stop and ask the user to open it.
- **UTF-8, no BOM.** Warp's TOML parser chokes on a BOM.

## Resolving launch args (the inheritance rule)

How a CLI is launched on a machine is the user's own setting. Whatever flags it
carries (permission mode, a machine- or tenant-specific model or reasoning pin,
anything else) belong in the user's config and nowhere else; this skill and its
callers never hard-code them. When the caller **omits** the args, the launcher
takes the command line from the first source that has one:

1. **The agent menu's config**, `<AGENT_MENU_DIR>/agents.yaml`
   (`%LOCALAPPDATA%\agent-menu` on Windows, `${XDG_CONFIG_HOME:-~/.config}/agent-menu`
   on macOS and Linux; format in the `agent-menu` skill's reference): the `<cmd>`
   block's `new` line for a fresh chat, its `resume` line for a resume, with
   `{args}` substituted. A file without a `<cmd>` block is skipped silently.
2. **The standing Warp tab config**, for a machine without the agent menu:
   `<tab_configs>/<cmd>.toml` for a fresh chat, `<tab_configs>/<cmd>-resume.toml`
   for a resume; its `commands` entry (the first string; TOML `\\` and `\"`
   decoded). Once the menu is set up, `<cmd>.toml` runs the menu instead and
   source 1 has already answered.

Then:

1. Strip the **leading command name** only. Everything after it - subcommands
   like `resume`, flags, quoted values, an embedded session id - is used
   **verbatim**, in order. A source whose command is not `<cmd>` is skipped
   with a warning.
2. Append the caller's **extra args** (if any) after the inherited set. For a
   resume that puts a session id last: `codex resume <flags> <id>`,
   `claude <flags> --resume <id>`.
3. Print which args were used and **which file** they came from.

Order of precedence: **explicit args** (replace the whole set; use only when the
user asks to drop or override a flag) > **agent menu config** > **standing tab
config** > **documented default**.

## Fallback launch args

Used **only** when neither source gives a line for the command; the launcher
applies them itself and says that it did.

| command  | default args (fresh) | default args (resume) |
| -------- | -------------------- | --------------------- |
| `claude` | (none)               | `--resume`            |
| `codex`  | (none)               | `resume`              |
| other    | (none)               | (none)                |

These defaults add nothing beyond what a resume itself needs - no permission
mode, model, tenant, or machine pin ever goes in them (or anywhere in this
skill). Flags such as a permission mode or a model pin belong in the user's own
config (the agent menu's `agents.yaml`, or a standing tab config), and every
consumer inherits them from there; for a single
launch the user can ask for them explicitly (pass them as `-ExtraArgs`, or as
an explicit replacement arg set).

## OS specifics

| OS      | tab_configs dir                        | open-URI command                     |
| ------- | -------------------------------------- | ------------------------------------ |
| Windows | `%APPDATA%\warp\Warp\data\tab_configs` | `Start-Process "warp://tab_config/<name>"` |
| macOS   | `~/.warp/tab_configs`                  | `open "warp://tab_config/<name>"`    |
| Linux   | `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs` | `xdg-open "warp://tab_config/<name>"` |

Create the tab_configs dir if missing. If Warp is not installed, say so and stop.
The tab_configs dir can be pointed elsewhere with the `WARP_TAB_CONFIGS_DIR`
environment variable, and the agent menu's folder with `AGENT_MENU_DIR` (tests
use temp dirs).

## Windows helper: invocation and flags

```powershell
# $SkillDir = the absolute path of the new-warp-chat skill's folder (above references/)
& "$SkillDir/scripts/new-warp-chat.ps1" `
    -TabName <name> -LaunchCmd <cmd> [-ExtraArgs '<additions>'] [-Resume] [-StartIn '<dir>'] -SeedFile '<seed-file>'
```

- `-StartIn '<dir>'` makes the tab change to that folder before it runs the
  command, for any CLI: the tab command gets
  `Set-Location -LiteralPath '<dir>' -ErrorAction Stop;` after the self-delete.
  The folder must exist (the launcher refuses one that does not); the path is a
  single-quoted literal with every quote character PowerShell reads as a single
  quote doubled (curly ones included), so spaces, `$`, backticks and brackets
  are taken literally, and a folder that vanished before the tab opened stops
  the line instead of launching in the wrong folder. Without `-StartIn` the tab
  command is unchanged.

- **Omit `-LaunchArgs`** so the args are inherited (the `<cmd>` block's `new`
  line in `agents.yaml`, else the standing `<cmd>.toml`); add `-Resume` to
  inherit the resume form instead (the block's `resume` line, else
  `<cmd>-resume.toml`). `-AgentMenuDir` and `-TabConfigsDir` override where
  the two sources are read.
- `-ExtraArgs '<additions>'` appends after the inherited set, verbatim - e.g.
  `-ExtraArgs '-C C:\work\proj'` or a session id for a resume. Quote a value
  with spaces yourself (`-ExtraArgs "-C 'C:\My Dir'"`).
- `-LaunchArgs '<args>'` **replaces** the whole set (nothing inherited). Only
  when the user asks to drop or override a flag; it may be empty.
- Omit `-SeedFile` entirely for no seed.

## What the Windows helper escapes

The script writes a single-quoted PowerShell literal and then applies the
CommandLineToArgvW rules: double each backslash run before a `"` and add one
more, and double a trailing backslash run when the argument will be quoted. It
writes the self-deleting config, deletes the seed file, and fires the URI. It
prints the resolved args and their source, then what it launched.

PowerShell 5.1 does **not** escape interior `"` when invoking a native exe, so a
hand-assembled seed splits at the first `"` and silently truncates - the exact
regression the script exists to kill.

## Testing

`tests/test-seed-quoting.ps1` (Windows PowerShell 5.1) regression-tests the
escaping end-to-end without opening tabs: it decodes the generated TOML and
executes the tab command against an argv-recording probe. It also covers
launch-arg inheritance against fixture standing configs in a temp dir
(inherit, inherit + extra, explicit override, resume, quoted-flag round-trip,
missing-config fallback, the env-var dir override, the name-collision guard),
and the agent menu config's place in the order (it beats a standing config,
explicit args beat it, a missing block falls through, a wrong command is
skipped, `-Resume` for both CLIs with no `-resume.toml` present), and
`-StartIn` (the probe records the folder it started in, for names with spaces,
quotes, `$`, a backtick, brackets and a curly apostrophe). It points
`AGENT_MENU_DIR` at a temp dir, so the user's real config never affects it.
Run it after ANY change to the script - the quoting has regressed before.
