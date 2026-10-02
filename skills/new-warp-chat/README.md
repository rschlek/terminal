# new-warp-chat

- Maintainer: the terminal plugin maintainers
- Submitted: 2026-10-01

The shared launcher: opens a new tab in the running Warp terminal that runs a
given command, optionally with a seed prompt as its final argument, through a
self-deleting Warp tab config and the `warp://` URI. Launch flags are read from
the user's own config: the agent menu's `agents.yaml` when it has a block for
the command, else the user's standing Warp tab config
(`<tab_configs>/<cmd>.toml`); otherwise the command runs with no extra flags.

## Prerequisites

Warp installed and running. On Windows the bundled
`scripts/new-warp-chat.ps1` does the launch; run `tests/test-seed-quoting.ps1`
under Windows PowerShell 5.1 after any change to it.
