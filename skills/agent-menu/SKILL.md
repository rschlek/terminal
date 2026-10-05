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

Run the setup script for the platform, by absolute path (this skill's folder
plus `scripts/...`; Windows: `scripts/setup.ps1`; macOS and Linux:
`bash scripts/setup.sh`).

1. Run it with `-Check` (`--check`) first; it changes nothing and reports what
   it found, including flags the user's current tab configs launch with.
2. If it reports flags and no config exists yet, ask the user whether to keep
   them; pass `-CarryArgs` (`--carry-args`) if so. Flags the user asks for go in
   with `-AgentArgs 'name=<args>'` (`--agent-args`). If a projects root is
   known or the user names one, pass `-ProjectsRoot` (`--projects-root`).
3. Run it for real and relay its report. It never deletes a redundant
   `<agent>-resume.toml`; remove one only when the user says so.

To change flags, a model, or the projects root later, edit the config file;
nothing else needs to change. An optional `new_project` line in an agent's block
adds a `+ new project` row to the project view (the template has it commented
out), and a top-level `start_in: projects_root` makes a fresh session in the
projects root the menu's first, preselected entry, followed by Project... and
Resume with Home moved to the end, and opens Resume there too, since an agent's resume list shows only the
sessions of the folder it opens in; the list can be widened to all folders
from inside it. Setup never rewrites an existing config, so add either by
hand. Paths, format, keys, and platform notes:
[references/menu-details.md](references/menu-details.md).
