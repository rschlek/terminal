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

The user's own standing Warp tab configs, when they exist, are the single
source of truth for how a CLI is launched on that machine - `<tab_configs>/<cmd>.toml`
for a fresh chat, `<tab_configs>/<cmd>-resume.toml` for a resume. Whatever flags they
carry (permission mode, a machine- or tenant-specific model or reasoning pin,
anything else) belong there and nowhere else; this skill and its callers never
hard-code them. When the caller **omits** the args, the launcher inherits them:

1. Read the standing config's `commands` entry (the first string; TOML `\\` and
   `\"` decoded).
2. Strip the **leading command name** only. Everything after it - subcommands
   like `resume`, flags, quoted values, an embedded session id - is used
   **verbatim**, in order.
3. Append the caller's **extra args** (if any) after the inherited set.
4. Print which args were used and **which file** they came from.

Order of precedence: **explicit args** (replace the whole set; use only when the
user asks to drop or override a flag) > **inherited** > **documented default**.

## Fallback launch args

Used **only** when the machine has no standing tab config for the command; the
launcher applies them itself and says that it did.

| command  | default args (fresh) | default args (resume) |
| -------- | -------------------- | --------------------- |
| `claude` | (none)               | `--resume`            |
| `codex`  | (none)               | `resume`              |
| other    | (none)               | (none)                |

These defaults add nothing beyond what a resume itself needs - no permission
mode, model, tenant, or machine pin ever goes in them (or anywhere in this
skill). Flags such as a permission mode or a model pin belong in the user's own
standing tab config, and every consumer inherits them from there; for a single
launch the user can ask for them explicitly (pass them as `-ExtraArgs`, or as
an explicit replacement arg set).

## OS specifics

| OS      | tab_configs dir                        | open-URI command                     |
| ------- | -------------------------------------- | ------------------------------------ |
| Windows | `%APPDATA%\warp\Warp\data\tab_configs` | `Start-Process "warp://tab_config/<name>"` |
| macOS   | `~/.warp/tab_configs`                  | `open "warp://tab_config/<name>"`    |
| Linux   | verify Warp's data dir (e.g. under `~/.local/state/warp-terminal/` or `~/.config/warp-terminal/`) | `xdg-open "warp://tab_config/<name>"` |

Create the tab_configs dir if missing. If Warp is not installed, say so and stop.
The tab_configs dir can be pointed elsewhere with the `WARP_TAB_CONFIGS_DIR`
environment variable (tests use a temp dir).

## Windows helper: invocation and flags

```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/new-warp-chat/scripts/new-warp-chat.ps1" `
    -TabName <name> -LaunchCmd <cmd> [-ExtraArgs '<additions>'] [-Resume] -SeedFile '<seed-file>'
```

- **Omit `-LaunchArgs`** so the args are inherited from the standing
  `<cmd>.toml`; add `-Resume` to inherit from `<cmd>-resume.toml` instead.
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
missing-config fallback, the env-var dir override, the name-collision guard).
Run it after ANY change to the script - the quoting has regressed before.
