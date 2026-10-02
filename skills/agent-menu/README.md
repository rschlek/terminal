# agent-menu

- Maintainer: the terminal plugin maintainers
- Submitted: 2026-10-02

Sets up one standing Warp tab per agent CLI (`claude`, `codex`) that opens a
small menu: a fresh session in the home folder, a fresh or resumed session in
a project under the user's projects root, or the agent's own resume list. Each
agent's launch lines live in one per-user config file (`agents.yaml`), which
the `new-warp-chat` launcher also reads, so a flag or model change is one edit.

## Prerequisites

Warp installed. Windows: Windows PowerShell 5.1 with an execution policy that
allows local scripts. macOS and Linux: bash 3.2 or later as the menu's
interpreter, and bash or zsh as the tab's shell. Run
`tests/test-agent-menu.ps1` (Windows PowerShell 5.1) and
`tests/test-agent-menu.sh` (bash) after any change to the scripts.
