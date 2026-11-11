# Agent guidance

<!-- playbook:base start (1.0.1) -->
## Working in this repo

This repo follows the playbook standard, version 1.0.1
(https://github.com/rschlek/playbook). This block is replaced when the
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
- The repo holds the project's own context; the tracker holds its work.
  A plan lives in its parent ticket, never in a file. Each decision is
  one file in `docs/decisions/`; research is a dated file under `docs/`.
  Write records for a reader who opens the project cold, and in a shared
  project (`shared: true`, or `visibility` set) show the user the exact
  text before writing one.
- Read and write tickets the way the tracker doc says: `docs/tracker.md`
  when present, else the user's own doc for the tracker `project.yaml` or
  the profile names. A ticket's status lives only in its tracker; never
  copy tickets between trackers, and never track progress in a document.
  Read `docs/project-conventions.md` before writing or moving anything
  under `docs/`, and leave existing documents as they are.
- The flow, each step a playbook skill: sharpen the idea (`grill-me`); if
  it is foggy, map its open questions (`wayfinder`, answering them with
  `research`, `prototype`, `grill-me`); plan and file the work
  (`to-tickets`); do each ticket (`tackle`); close the parent. Skip steps
  already clear. Any time: `capture` a stray item, `untangle` when lost,
  `next` when unsure what comes next.
- In a repo other people use, changes go in through its review process,
  not straight to the main branch.
- Keep work in progress in a worktree under `.claude/worktrees/`, one
  session per worktree, and push its branch before leaving it.
- Do not move or rename the repo, and keep `project.yaml` true when the
  project changes.
<!-- playbook:base end -->

## This project

This repository is the single source of the terminal skills. Every catalog
that offers them references this repository on the `stable` ref; no catalog
keeps a copy. Fix a skill here, never in a consumer.

### Public repository

Everything here is public and generic. Write for "the user". No person,
username, host name, employer, team, or internal product; no absolute paths
from any machine; no names of skills or plugins from other catalogs; no real
tokens. The exceptions are the `author` field in the plugin manifests (and the
owner of the single-plugin catalog) and this repository's own URL. Setting up
the terminals themselves belongs here too: `warp-setup` and `wezterm-setup` ship
generic defaults (the plugin's default Warp look, a minimal WezTerm block) that
any user can apply and change. What stays out is anything specific to one
environment or person - a machine's paths, which launch flags or model pins
its CLIs use - which lives in that environment's own setup or in the user's own
config files (the agent menu's `agents.yaml`, Warp's settings).

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
- `skills/agent-menu/scripts/`: `agent-menu.ps1` + `agent-config.ps1`
  (Windows) and `agent-menu.sh` (macOS, Linux), the menu a standing Warp tab
  runs, plus `setup.ps1` / `setup.sh`. `agent-config.ps1` is the one reader of
  the per-user `agents.yaml`; the Windows launcher dot-sources it too.
  `templates/` holds the shipped config and tab config templates.
- `skills/warp-setup/assets/`: the Warp settings it merges (`settings.toml`
  plus the Windows and Linux overlays). `skills/wezterm-setup/assets/wezterm.lua`:
  the WezTerm managed block. Both skills are prose plus assets, no scripts.

### Two harnesses, no hooks

Every skill must work in Claude Code and Codex from the same `SKILL.md`. Refer
to bundled files by paths relative to the skill's directory, add no hooks, and
keep skill bodies short and harness-neutral.

### Checks

- After any change to `new-warp-chat.ps1`, run
  `powershell -NoProfile -File skills/new-warp-chat/tests/test-seed-quoting.ps1`
  under Windows PowerShell 5.1. It opens no tabs: it writes configs to a temp
  folder and runs them against an argument-recording probe.
- After any change under `skills/agent-menu/scripts/` or to
  `agent-config.ps1`, run
  `powershell -NoProfile -File skills/agent-menu/tests/test-agent-menu.ps1`
  under Windows PowerShell 5.1 and `bash skills/agent-menu/tests/test-agent-menu.sh`
  (also under Git Bash), and the launcher test above. They use temp folders
  only.
- After a change to a pane helper, check its syntax (`bash -n` for
  `pane.sh`, the PowerShell parser for `pane.ps1`) and try it end to end on a
  desktop session.
- Launch fallbacks stay plain: with no user config the launcher adds no
  flags beyond what a resume needs, and the shipped `agents.yaml` template
  carries no flags, model, or path.

### Releases

Consumers track `stable`. A release bumps `version` in both manifests, tags
`vX.Y.Z`, and advances `stable` to the tag after validation. When to release
is the owner's decision.
