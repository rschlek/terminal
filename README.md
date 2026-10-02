# Terminal

Terminal skills for Claude Code and Codex: one WezTerm window the user and the
agent share for passwords, MFA, and interactive logins, and fresh, optionally
seeded chats opened in new tabs of the running Warp terminal.

## Skills

| Skill | What it does | Requires |
| --- | --- | --- |
| `shared-pane` | Opens one WezTerm window the user and the agent both drive: the user types the secret or approves the MFA push, the agent keeps working in the same authenticated shell. | WezTerm installed (set `WEZTERM_BIN` if it is not on PATH); a desktop session. |
| `new-warp-chat` | Opens a new tab in the running Warp terminal that runs a given command, optionally with a seed prompt as its final argument. | Warp installed and running. |
| `breakout` | Opens a fresh chat of the same CLI (Claude Code or Codex) in a new Warp tab, optionally seeded, through `new-warp-chat`. | Warp installed and running. |
| `agent-menu` | Sets up one standing Warp tab per agent CLI that opens a menu: a fresh session in the home folder, a fresh or resumed session in a project, or the agent's resume list. Each agent's launch lines live in one per-user config file. | Warp installed; on Windows, an execution policy that allows local scripts. |

## Launch flags

`new-warp-chat` and `breakout` read a CLI's launch flags from the user's own
config, so a permission mode or a model pin set there carries over to every new
tab: first the agent menu's `agents.yaml` (the CLI's `new` or `resume` line),
then the user's standing Warp tab configs (`<tab_configs>/<cmd>.toml`, and
`<cmd>-resume.toml` for a resume). With neither the CLI is launched plain, with
no extra flags (a resume keeps only what resume itself needs). Anything else is
set in that config, or asked for explicitly for one launch.

## Platform notes

- `shared-pane` needs a desktop session: on a headless or SSH-only machine
  there is no window to share, and the agent hands the user the command
  instead. `scripts/pane.sh` covers Linux and macOS, `scripts/pane.ps1`
  Windows; the `waitlast` and `sendf` subcommands are Windows only.
- `new-warp-chat` opens tabs in the running Warp and never starts Warp itself;
  if Warp is not running, the agent asks the user to open it. On Windows a
  bundled PowerShell helper does the launch; on macOS and Linux the agent
  composes it inline.
- `agent-menu` writes its menu and config to a per-user folder outside the
  plugin (`%LOCALAPPDATA%\agent-menu` on Windows,
  `${XDG_CONFIG_HOME:-~/.config}/agent-menu` on macOS and Linux). The macOS and
  Linux tab expects bash or zsh as the tab's shell.

## Install

From a catalog that lists this plugin, install `terminal` from it. To install
this repository directly:

```bash
# Claude Code
claude plugin marketplace add https://github.com/rschlek/terminal.git
claude plugin install terminal@terminal

# Codex
codex plugin marketplace add https://github.com/rschlek/terminal.git
codex plugin add terminal@terminal
```

A local checkout works the same way: pass its folder to `marketplace add`.
Start a new session afterwards.

## License

MIT; see [LICENSE](LICENSE).
