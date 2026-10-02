# breakout

- Maintainer: the terminal plugin maintainers
- Submitted: 2026-10-01

Opens a fresh chat in a new Warp tab running the same CLI as the current
session (Claude Code or Codex), optionally seeded with a starting prompt,
while the current session keeps running. It decides which CLI to open and what
the seed says, and launches through the sibling `new-warp-chat` skill.

## Prerequisites

Warp installed and running. Launch flags come from the user's own config (the
agent menu's `agents.yaml`, else the user's Warp tab configs) when it exists;
otherwise the plain CLI is launched.
