# Agent guidance

<!-- project-guide:base start (0.6.0) -->
## Working in this repo

This repo follows the project-guide standard, version 0.6.0
(https://github.com/rschlek/project-guide). This block is replaced when the
standard updates; put project-specific guidance in the section below it.

- Read `README.md` and `project.yaml` first: what this is, who it is for,
  and where related things live.
- Before changing `project.yaml`, `README.md`, `AGENTS.md`, `CLAUDE.md`, or
  the repo's layout, read `docs/project-conventions.md` and keep to it.
- Make one change for one purpose, and run the checks this repo documents
  before proposing it.
- Commit only the files you changed, by path. Never commit credentials,
  tokens, or data extracts.
- If `project.yaml` says `visibility: public`, anyone can read this repo:
  write no person, employer, team, host, or machine names into it.
- If it says `visibility: internal`, everyone in the organization that
  hosts this repo can read it: the organization's own names are fine,
  other people's personal details are not.
- In a repo other people use, changes go in through its review process,
  not straight to the main branch.
- Keep work in progress in a worktree under `.claude/worktrees/`, one
  session per worktree, and push its branch before leaving it.
- Do not move or rename the repo, and keep `project.yaml` true when the
  project changes.
<!-- project-guide:base end -->

## This project

This repository is the single source of the terminal skills. Every catalog
that offers them references this repository on the `stable` ref; no catalog
keeps a copy. Fix a skill here, never in a consumer.

### Public repository

Everything here is public and generic. Write for "the user". No person,
username, host name, employer, team, or internal product; no absolute paths
from any machine; no names of skills or plugins from other catalogs; no real
tokens. The one exception is this repository's own URL. Anything specific to
one environment (how WezTerm or Warp is installed there, which launch flags
its CLIs use) belongs to that environment's own setup or to the user's own
Warp tab configs, never to these skills.

### Layout

- `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`: the manifests.
  Skills are auto-discovered from `skills/`.
- `.claude-plugin/marketplace.json`, `.agents/plugins/marketplace.json`:
  single-plugin catalogs for direct install.
- `skills/<name>/`: `SKILL.md`, `README.md` (maintainer and date),
  `agents/openai.yaml`, and any `scripts/`, `references/`, and `tests/`.
- `skills/shared-pane/scripts/`: `pane.sh` (Linux, macOS) and `pane.ps1`
  (Windows), the WezTerm helpers.
- `skills/new-warp-chat/scripts/new-warp-chat.ps1`: the Windows launcher that
  `breakout` also calls; `tests/test-seed-quoting.ps1` is its regression test.

### Two harnesses, no hooks

Every skill must work in Claude Code and Codex from the same `SKILL.md`. Refer
to bundled files the way the skills already do, add no hooks, and keep skill
bodies short and harness-neutral.

### Checks

- After any change to `new-warp-chat.ps1`, run
  `powershell -NoProfile -File skills/new-warp-chat/tests/test-seed-quoting.ps1`
  under Windows PowerShell 5.1. It opens no tabs: it writes configs to a temp
  folder and runs them against an argument-recording probe.
- After a change to a pane helper, check its syntax (`bash -n` for
  `pane.sh`, the PowerShell parser for `pane.ps1`) and try it end to end on a
  desktop session.
- Launch fallbacks stay plain: with no user tab config the launcher adds no
  flags beyond what a resume needs.

### Releases

Consumers track `stable`. A release bumps `version` in both manifests, tags
`vX.Y.Z`, and advances `stable` to the tag after validation. When to release
is the owner's decision.
