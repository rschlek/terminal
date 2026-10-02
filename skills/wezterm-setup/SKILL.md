---
name: wezterm-setup
description: >-
  Install and configure WezTerm on this device as the engine behind the
  shared-pane skill (a window the user and the agent both drive, for a typed
  secret or an MFA approval): install it per OS if missing (native package
  first, a no-admin AppImage route on Linux), reconcile the minimal managed
  wezterm.lua, and prove `wezterm cli` can address a uniquely classed GUI. Use
  for "set up wezterm", "install wezterm", "shared pane doesn't work". Not for
  opening a shared pane during real work (shared-pane) and not for Warp config
  (warp-setup).
---

# WezTerm setup

End state: `wezterm` runs, the WezTerm config carries the managed block from
`assets/wezterm.lua`, and a uniquely classed WezTerm GUI can be started,
addressed by `wezterm cli`, and closed again - what the sibling `shared-pane`
skill does at run time. Install commands, paths, and socket mechanics:
[references/wezterm-details.md](references/wezterm-details.md).

## Steps

1. **Install if needed.** `wezterm --version`. Missing: install from the
   reference (native package; the Linux no-admin route when there is no sudo,
   or hand the user the one install command). A `2024*` build on Linux/Wayland
   is the stable release with known Wayland problems: offer the nightly, but do
   not force it if the verification passes.
2. **Reconcile the config** (`~/.config/wezterm/wezterm.lua`;
   `%USERPROFILE%\.wezterm.lua` on Windows), never clobbering the user's file:
   - absent or empty: write the asset verbatim;
   - has the markers `-- wezterm-setup: managed block start` / `end`: replace
     that region with the asset's, every other byte preserved;
   - exists without the markers: the user owns it, and a WezTerm config is one
     Lua chunk with one `return`, so insert no executable Lua. If it sets a
     `default_prog` that forces a non-shell program or a `unix_domains` entry,
     say so and ask before changing anything. Otherwise append only the
     asset's comment lines from the marker region and report that no settings
     were applied (the one setting shipped, `scrollback_lines`, is optional).

   Back up to `<file>.bak` first, write UTF-8 without a BOM, re-read, restore
   the backup on failure, remove it on success. A re-run that finds the file
   correct changes nothing.
3. **Verify the chain**: `wezterm --version` prints a version; a GUI started
   with a unique `--class` publishes a socket, and `wezterm cli list --format
   json` with `WEZTERM_UNIX_SOCKET` set to that socket returns a pane (the
   `shared-pane` helper does exactly this: open a pane named
   `wezterm-setup-verify`, read it, close it); the GUI is closed afterwards,
   since a stray window is a failed run. Never call a bare `wezterm cli`. With
   no desktop session, report this check as deferred. Retry at most two or
   three times, then stop and tell the user the paths, command, output, and
   what you need.
4. **Report** the version and install route, what happened to the config file,
   and each check's result.

This changes neither the default terminal nor the shell, and never reads,
writes, or types a credential.
