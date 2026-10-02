---
name: agent-menu
description: >-
  Set up the agent menu: one standing Warp tab per agent CLI (claude, codex)
  that opens a small menu - a fresh session in the home folder, a fresh or
  resumed session in a project, or the agent's resume list - with each agent's
  launch flags kept in one per-user config file that new-warp-chat also reads.
  Use when the user wants the agent menu, wants fewer standing Warp tab configs
  (no separate -resume tabs), or wants to change an agent's flags or model in
  one place. Not for opening a one-off tab (new-warp-chat) or a fresh chat of
  the current CLI (breakout).
---

# Agent menu

Run the setup script for the platform (Windows:
`${CLAUDE_PLUGIN_ROOT}/skills/agent-menu/scripts/setup.ps1`; macOS and Linux:
`bash ${CLAUDE_PLUGIN_ROOT}/skills/agent-menu/scripts/setup.sh`).

1. Run it with `-Check` (`--check`) first; it changes nothing and reports what
   it found, including flags the user's current tab configs launch with.
2. If it reports flags and no config exists yet, ask the user whether to keep
   them; pass `-CarryArgs` (`--carry-args`) if so. Flags the user asks for go in
   with `-AgentArgs 'name=<args>'` (`--agent-args`). If a projects root is
   known or the user names one, pass `-ProjectsRoot` (`--projects-root`).
3. Run it for real and relay its report. It never deletes a redundant
   `<agent>-resume.toml`; remove one only when the user says so.

To change flags, a model, or the projects root later, edit the config file;
nothing else needs to change. Paths, format, keys, and platform notes:
[references/menu-details.md](references/menu-details.md).
