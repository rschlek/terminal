---
name: warp-setup
description: >-
  Apply the plugin's default Warp look on this device - theme, font sizes,
  zoom, vertical tabs, Warp AI / Warp Drive / code editor / sticky header off -
  by merging it into settings.toml, set up the agent tabs through agent-menu,
  and make the `claude` tab Warp's default new tab; on Windows it also applies
  the Shell (PS1) safeguard against runaway Git prompt probes. Config applier
  only: Warp must already be installed and onboarded. Windows, macOS and Linux.
  Use for "set up warp", "configure warp", "apply the warp settings". Not for
  installing Warp or opening a one-off tab (new-warp-chat).
---

# Warp setup

End state: Warp's `settings.toml` carries every key in the shipped assets at
the shipped value, the user's other settings are untouched, the agent tab
configs exist, Warp's default new tab is the `claude` tab, and the result is
verified on disk. The assets are a default look; the user can change any of it
afterwards. Platform paths, commands, and the reasons behind each rule:
[references/warp-details.md](references/warp-details.md).

## Steps

1. **Precondition.** Warp is installed and has been opened once with onboarding
   finished (`settings.toml` exists and is not empty). If not, give the user the
   install steps from the reference and wait; never install Warp yourself.
   Writing before onboarding finishes gets overwritten by Warp.
2. **Agent tabs.** Run the sibling `agent-menu` skill's setup. It writes the
   `claude` and `codex` tab configs and keeps each agent's launch flags in its
   own config file; this skill writes no tab configs.
3. **Reconcile `settings.toml`** (UTF-8, no BOM; Warp's parser rejects a BOM):
   - Merge `assets/settings.toml`, plus `assets/settings.windows.toml` on
     Windows or `assets/settings.linux.toml` on Linux. Every key in those
     assets is set to the asset value, overwriting the user's value on
     conflict; every other key and section the user has is kept as is.
   - Replace the `{{DEFAULT_TAB_CONFIG_PATH}}` token with the absolute,
     OS-native path to `<tab_configs>/claude.toml` (no `~`).
   - Self-host guard: if this session runs inside Warp, never quit Warp. Write
     live, and tell the user one full quit and relaunch of Warp, with no agent
     session inside it, makes the settings durable. Otherwise quit Warp, write
     while it is stopped, and relaunch it (on Linux, SIGTERM only).
4. **Verify on disk** - re-read and check: the asset keys hold the asset values
   and the path token resolved to this machine's `claude.toml`; no BOM; every
   key the user had that is not ours is still there; on Windows after a clean
   relaunch, the Git-probe check in the reference finds no Warp-spawned probes
   (in the self-host case it stays pending until the relaunch). Retry at most
   two or three times, then stop and tell the user what was written where, what
   failed, and what you need.
5. **Open a session** with the `warp://tab_config/claude` URI (Warp does not
   reliably open the default tab on its own), and report what changed.

Never read or write `warp.sqlite` or anything in Warp's state directory.
