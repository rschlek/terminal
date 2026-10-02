# warp-setup

- Maintainer: the terminal plugin maintainers
- Submitted: 2026-10-02

Applies the plugin's default Warp look (theme, font sizes, zoom, vertical tabs,
Warp AI, Warp Drive and the code editor panels off, the sticky command header
off) by merging it into Warp's `settings.toml`, sets up the agent tabs through
the sibling `agent-menu` skill, and makes the `claude` tab Warp's default new
tab. On Windows it also switches Warp to Shell (PS1) input so Warp stops
spawning its own Git prompt probes. The user can change any of it afterwards.

## Prerequisites

Warp installed and opened once with onboarding finished; the skill does not
install Warp. It ships settings assets only, no scripts.
