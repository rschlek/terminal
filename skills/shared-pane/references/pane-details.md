# Shared pane - details

Reference material for the `shared-pane` skill: why the mechanism exists, the
full "when to reach for it" list, the two mechanics the helper gets right, a
worked example, and the platform notes. The procedure and the rules live in
SKILL.md.

## Why one shared window

The old workaround was to hand the human the whole command and ask them to run it
in their own terminal - at which point the authenticated shell is *theirs*, the agent
is blind, and every follow-up command is another paste.

## When to reach for it

Any step where a human must supply something the agent cannot, **and** the agent
needs the shell afterwards:

- `sudo` / `sudo -v` and anything behind it (package installs, root scripts).
- `ssh user@host` where the password and an MFA push (Duo, Okta) are typed at the
  prompt - including a later identity switch inside that session, which is why
  connection-sharing tricks (PuTTY's, `ControlMaster` against a separate login)
  do not substitute.
- Vault and cloud logins: `bw login` / `bw unlock`, `az login`, `gcloud auth
  login`, `gh auth login`, `op signin`.
- A database client that prompts (`psql`, `mysql`, `sqlplus`).
- Any TUI that needs a human decision partway (a `y/N` on something destructive,
  a license accept) while the agent handles the rest.

## Two mechanics the helper gets right so nobody re-derives them

- **Unique window class.** Each pane is its own GUI started with
  `--class shared-pane-<name>-<pid>`, so it can never be confused with a WezTerm
  window the human opened.
- **Always address the GUI by its own socket.** Several WezTerm GUIs share a
  default class and a bare `wezterm cli` picks whichever socket it finds first -
  it will happily type into the wrong window. The helper captures the new GUI's
  socket at `open` and exports `WEZTERM_UNIX_SOCKET` on every later call.

## Worked example: a local root run

A follow-up script needed root on the local box. The human typed only the sudo
password; the agent did everything else in the same shell.

```sh
P=${CLAUDE_PLUGIN_ROOT}/skills/shared-pane/scripts/pane.sh

# 1. Open a pane whose title is the instruction.
"$P" open root "ROOT STEPS - TYPE YOUR SUDO PASSWORD HERE"

# 2. Run the command that will prompt.
"$P" send root 'sudo -v && sudo bash /path/script.sh'

# 3. Wait for the prompt to actually appear.
"$P" wait root 'password for'        # 0 = prompt is up, 3 = never came, 4 = window gone
```

> Then, to the human: **"A WezTerm window titled `ROOT STEPS - TYPE YOUR SUDO
> PASSWORD HERE` just opened - type your sudo password in it. I'll take it from
> there."**

```sh
# 4. Wait for the post-auth marker: either the script's own DONE or a prompt
#    the run stops at. A generous budget, because the human has to walk over.
"$P" wait root 'Is this ok \[y/N\]|DONE' 900

# 5. Read what it is asking - summarize it, do not paste the screen.
"$P" read root 20

# 6. Answer and keep going.
"$P" send root y
"$P" wait root 'DONE'
"$P" read root 15

# 7. Always close.
"$P" close root
```

The same shape carries an `ssh` + Duo login: `send root 'ssh user@host'`,
`wait root 'assword:'`, tell the human to type the password and approve the push,
`wait root 'Duo|Success|\$ $'`, then drive the remote shell - including an
identity switch (`sudo su - svcacct`) approved in that same window.

## Platform and verification notes

- **Engine:** WezTerm must be installed (set `WEZTERM_BIN` if it is not on
  PATH). If `pane.sh open` fails with "wezterm GUI did not publish a socket",
  check that WezTerm can start a GUI window on this desktop.
- **`scripts/pane.sh`** is verified end to end on a Linux desktop (Wayland) with
  a recent WezTerm build; macOS uses the same path.
- **State** lives in `~/.local/state/shared-pane/<name>.state` (Windows:
  `%LOCALAPPDATA%\shared-pane\<name>.state`; override with `SHARED_PANE_STATE`).
  It holds a socket path, a pane id, the window class, and the GUI pid - nothing
  secret. It is `.state`, not `.env`, so a shell guard hook, if the environment
  has one, does not have to treat it as a secrets file.
- **`WEZTERM_BIN`** overrides which `wezterm` binary is used (useful for the
  no-admin `~/.local/bin` install); on Windows `WEZTERM_GUI_BIN` does the same for
  `wezterm-gui.exe`.
- **Windows.** `scripts/pane.ps1` is verified end to end (Windows 11,
  PowerShell 5.1, WezTerm 20240203) from both PowerShell and Git Bash. It
  addresses the GUI the same way `pane.sh` does - by its socket,
  `%USERPROFILE%\.local\share\wezterm\gui-sock-<pid>` - because
  `wezterm cli --class` did not select the right GUI in practice. The pane's
  shell is `cmd.exe` under ConPTY, so Enter is CR and the prompt is `C:\...>`
  (`waitlast <name> '>$'` detects it coming back). From Git Bash call
  `powershell -NoProfile -ExecutionPolicy Bypass -File <abs path>\pane.ps1 ...`,
  one quoted argument per text or regex; set `MSYS_NO_PATHCONV=1` if an argument
  starts with `/`. `waitlast` and `sendf` exist only in `pane.ps1` for now.
