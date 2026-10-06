# Agent menu - details

Reference for the `agent-menu` skill: where its files live, the config format,
what the menu does, the tab configs setup writes, and the tests.

## Files

Everything the user or a tab config touches lives in one per-user folder,
outside the plugin directory (plugin installs are versioned and replaced on
update):

| OS            | folder                                         |
| ------------- | ---------------------------------------------- |
| Windows       | `%LOCALAPPDATA%\agent-menu`                    |
| macOS, Linux  | `${XDG_CONFIG_HOME:-~/.config}/agent-menu`     |

The `AGENT_MENU_DIR` environment variable overrides it (tests use a temp dir).
In that folder:

- `agents.yaml` - the config. Setup creates it from `templates/agents.yaml`
  only when it does not exist, and never rewrites it.
- `agent-menu.ps1` + `agent-config.ps1` (Windows) or `agent-menu.sh` - the
  menu, copied from the plugin and refreshed on every setup run, and by the
  menu itself when the plugin is updated (below).
- `plugin-source.txt` - written by setup: the plugin folder the menu was
  copied from, the plugin's name and its version. Safe to delete; the menu
  then stops refreshing itself until setup runs again.
- `recent.tsv` - projects opened through the menu, newest first, one
  `<unix-seconds><TAB><path>` line each.
- `backup/` - each standing tab config setup replaced, timestamped.

## Config format

```yaml
projects_root: /path/to/projects

claude:
  args:
  new: claude {args}
  resume: claude {args} --resume

codex:
  args:
  new: codex {args}
  resume: codex resume {args}
  resume_all: codex resume --all {args}
```

Flat on purpose, so both scripts read it line by line with no YAML library:

- Top-level `key: value` lines; an agent block is `name:` alone on a line,
  followed by indented (two spaces by convention) `key: value` lines.
- Blank lines and lines starting with `#` are skipped.
- A value is everything after `key: `, **verbatim to the end of the line**:
  quotes are kept exactly as typed, and a `#` is part of the value - there are
  no inline comments, multi-line values, or escapes. Write the line as it
  would be typed at the prompt, e.g.
  `args: --config 'some_key="value"'`.
- `{args}` in a command line is replaced by the block's `args`; when `args` is
  empty, the placeholder and the spaces before it are dropped.
- `projects_root` is a path: surrounding quotes are removed and a leading `~`
  expands to the home folder.
- `start_in` (optional, top level): `home` (the default) or `projects_root`,
  which adds a **Projects root** entry first on the home screen, moves
  **Home** to the end, and opens **Resume** in the projects root (see the menu
  below).
- Block keys: `new` (default `<name> {args}`), `resume`, `resume_all`
  (falls back to `resume`), the optional `new_project` (no default; see the
  project view), and the optional `session_list` (`claude` or `off`; see the
  session list). Any block name works as an agent name.

The new-warp-chat launcher reads the same file: a block's `new` line (or
`resume` line for a resume) is how a new tab of that CLI is launched. It
ignores `new_project`.

## The menu

The tab config runs the menu with one argument, the agent's block name.

- Home screen (Up/Down, Enter; Esc leaves a plain prompt):
  **Home** runs `new` in the home folder; **Project...** opens the project
  view; **Resume** runs `resume_all` (else `resume`) in the home folder.
- With `start_in: projects_root` and an existing `projects_root`, the home
  screen starts with **Projects root**, which runs `new` in `projects_root`
  itself and records nothing in `recent.tsv`. It is selected when the menu
  opens, so Enter alone starts a session there. The order is then
  **Projects root**, **Project...**, **Resume**, **Home**: the entries that
  work in the projects root come together and Home moves to the end.
  **Resume** opens in `projects_root` instead of the home
  folder: an agent's resume list shows only the sessions started in the folder
  it opens in, so it opens where the menu's default sessions start. The list
  itself can be widened to all folders from inside it. Resuming inside one
  project (Tab in the project view) is unchanged. If the root is missing the
  entry is left out and Resume stays in the home folder.
- Project view: the folders directly under `projects_root` (dot-folders
  skipped), recently opened first, then the rest alphabetically. Each row shows
  the folder name and, from a `project.yaml` in it, `scope` and `summary`
  (trailing `# comments`, quotes, and folded `>` / literal `|` values are
  handled). Type to filter by name, Up/Down, Enter starts `new` there, Tab
  toggles to `resume` there, Esc goes back.
- When the agent's block has a `new_project` line, the project view starts
  with a pinned `+ new project` row, in new mode only. The filter never hides
  it; it is selected first only when there are no project folders yet, and the
  view then opens even with an empty `projects_root`. Enter on it runs the
  `new_project` line in `projects_root` itself and records nothing in
  `recent.tsv`. Without the key the view is unchanged. Setup never rewrites an
  existing `agents.yaml`, so to turn the row on add the line to the agent's
  block by hand (the template carries it commented out), for example
  `new_project: claude {args} "Create a new project in this folder."`.
- With no `projects_root`, or one that does not exist, the Project entry says
  so and names the key to set; the other entries still work.
- The launch changes the tab's own shell to the folder, then runs the line, so
  when the agent exits the user is at a prompt in that folder.

### The session list

An agent's own resume picker lists only the chats of the folder it opens in,
so chats started inside projects do not show up from the home folder or the
projects root. For an agent whose block has `session_list: claude`, **Resume**
opens the menu's own list instead: the past chats of every folder, newest
first, read from Claude Code's session store. A block named `claude` gets it
when the key is absent; every other block gets `off` (Codex lists every folder
itself with `codex resume --all`), and `session_list: off` keeps the agent's
own picker for `claude` too. Existing configs need no change.

- Each row: the title, the folder (relative to `projects_root` when under it,
  else the full path; the root itself shows as its full path), the age of the
  last activity, and the git branch when the chat recorded one (a detached or
  non-repository `HEAD` is left out).
- Type to filter on title and folder, Up/Down, Esc goes back.
- **Enter** changes to the folder the chat was started in and runs the
  block's `resume` line with the session id appended (for
  `claude {args} --resume`: `claude {args} --resume <id>`). The home folder
  and the projects root are folders like any other: a chat started there
  reopens there.
- **Tab** opens the project view to pick another folder and reopens the chat
  there instead (Claude Code reopens a chat from any folder; the chat's file
  stays where it is). Esc there goes back to the list. Tab needs a projects
  root. Nothing is recorded in `recent.tsv`.
- With no readable chats (no store, or nothing left after the skips below),
  Resume runs `resume_all` (else `resume`) in its folder, as without the list.

How the store is read (Claude Code's on-disk format): the store is
`<config dir>/projects`, the config dir being `CLAUDE_CONFIG_DIR` or
`~/.claude`. Each chat is one `<projects>/<folder>/<session-id>.jsonl`;
subfolders (subagent transcripts) are never entered. The folder name encodes
the working folder lossily, so the real one comes from the file: the first
`"cwd"` in its first 40 lines (a chat resumed elsewhere records the new folder
in later lines, so the first one is the original). Only the head (256 KB, 4 MB
when no folder turns up there) and the last 64 KB of a file are read. The
title is the last `ai-title` in the tail, else the last `last-prompt`, else the
first user message's text, cut to 60 characters. The newest 40 chats by file
time are listed. Left out: a file with no user message, a chat whose folder no
longer exists, and chats in temp folders or the Windows system folder.

### Self-refresh

Plugin updates install a new plugin folder; they do not touch the menu copy
in the per-user folder. So setup records where the copy came from in
`plugin-source.txt`, and at every start the installed menu looks for a newer
version of that plugin: the recorded folder itself (a checkout updated in
place), and, when that folder is named after its version (plugin caches keep
one folder per version, and may delete old ones), its sibling version folders.
The newest one whose manifest (`.claude-plugin/plugin.json`, else
`.codex-plugin/plugin.json`) names the same plugin and has a higher version
wins: the menu copies its scripts over the installed ones, rewrites the record,
and runs the new copy with the same arguments. Versions compare numerically
(`1.10.0` is newer than `1.9.9`). With no record, nothing newer, or any
failure, the menu runs as it is, without a message. `agents.yaml`, the tab
configs and `recent.tsv` are never touched. A menu copy installed before this
feature has no record; run setup once to start it.

Non-interactive modes, for checking a config edit:
`agent-menu.ps1 <agent> -Print new|resume|resume_all|new_project`,
`agent-menu.ps1 [<agent>] -List` (with an agent whose block has `new_project`,
the pinned row comes first), `agent-menu.ps1 <agent> -Entries` (the home
screen's entries in order, `<key><TAB><folder>`; the `resume` row's folder is
where Resume opens), `agent-menu.ps1 <agent> -Sessions` (the session list,
`<id><TAB><folder><TAB><branch><TAB><title>`, empty when the list is off),
`agent-menu.ps1 <agent> -NoLaunch` (runs the menu, prints instead of
launching); `agent-menu.sh --print <agent> <mode>`,
`agent-menu.sh --list [<agent>]`, `agent-menu.sh --entries`,
`agent-menu.sh --sessions <agent>`.

## Tab configs

Setup writes `<tab_configs>/<agent>.toml` (UTF-8, no BOM) for each agent; the
tab_configs folder is Warp's (`%APPDATA%\warp\Warp\data\tab_configs`,
`~/.warp/tab_configs`, `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs`)
unless `WARP_TAB_CONFIGS_DIR` is set. The command each tab runs:

- Windows (Windows PowerShell):
  `& '<menu folder>\agent-menu.ps1' claude`.
  It runs in the tab's session, so `Set-Location` sticks. The execution policy
  must allow local scripts; setup warns when it would not, and changing it is
  the user's decision.
- macOS, Linux (bash or zsh):
  `eval "$(bash '<menu folder>/agent-menu.sh' claude)"`.
  A child process cannot change its parent's directory, so the menu draws on
  the terminal and prints one line, `cd -- '<folder>' && <command>`, which the
  tab's own shell evaluates. fish needs a different form and is not covered.

An existing tab config that already launches the agent with flags is reported
by setup, which can carry those flags into the new config's `args`.

## Platform notes

- On bash 3.2 (the macOS default) a lone Esc takes about a second to register,
  since `read` there only accepts whole-second timeouts; bash 4 and later
  respond at once.
- The bash menu needs nothing beyond bash, coreutils, sed and awk.

## Testing

`tests/test-agent-menu.ps1` (Windows PowerShell 5.1) and
`tests/test-agent-menu.sh` (bash; also runs under Git Bash) cover the config
reader (including a quoted `--config` value round-tripping verbatim and
`{args}` substitution), `project.yaml` fields, listing and sort order, the
recent file, the home screen's entries and Resume's folder with and without `start_in`, the menu's non-interactive modes, and setup against temp folders.
Both also build a fake session store in a temp `CLAUDE_CONFIG_DIR` (titles
present, missing and duplicated, string and array messages, several folders
in one file, a partial last line, long titles, temp-folder, no-user and
missing-folder chats, a subagent transcript) and a fake plugin cache for the
self-refresh (a newer sibling version, a checkout updated in place, a gone
source, an unparsable version, another plugin's folder). `AGENT_MENU_TEMP_DIR`
(test-only) replaces the temp folders the session list skips, since the tests
themselves run in one.
The bash test also scripts whole menu sessions by feeding keys from a file
(`AGENT_MENU_TTY_IN` / `AGENT_MENU_TTY_OUT`, test-only) and evaluates the
printed line. The PowerShell key loop needs a real console and is not covered.
