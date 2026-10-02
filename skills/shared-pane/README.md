# shared-pane

- Maintainer: the terminal plugin maintainers
- Submitted: 2026-10-01

Opens one visible, uniquely titled WezTerm window that the user and the agent
drive together. The agent runs the command, the user types the password,
approves the MFA push, or completes the interactive login in that window, and
the agent keeps reading and sending into the same authenticated shell. The
helper scripts address each window by its own socket so text never lands in
the wrong one.

## Prerequisites

WezTerm installed (set `WEZTERM_BIN` if it is not on PATH) and a desktop
session. `scripts/pane.sh` covers Linux and macOS; `scripts/pane.ps1` covers
Windows, where `waitlast` and `sendf` are available only.
