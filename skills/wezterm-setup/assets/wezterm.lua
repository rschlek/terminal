-- wezterm-setup: managed block start
-- Managed block. The wezterm-setup skill owns everything between these two
-- markers and replaces the whole region on a re-run. Put your own settings
-- OUTSIDE the markers and they survive untouched.
--
-- WezTerm here is the engine behind the shared-pane skill: one visible window a
-- human and an agent drive together, so the human can type a password or
-- approve an MFA push and the agent keeps working in that same authenticated
-- shell. It does not have to be the daily terminal.
--
-- Deliberately minimal, so this file never fights an interactive WezTerm:
--   * no `default_prog` - your login shell stays your login shell.
--   * `unix_domains` left at its default (unset). Shared panes do NOT use the
--     mux server; each one is its own GUI process, addressed through that
--     GUI's own socket.
--   * no font, colour, or keybinding opinions.
--
-- Shared panes are launched as
--     wezterm start --class shared-pane-<name>-<pid> -- <shell>
-- so the window class is unique per pane and can never collide with a WezTerm
-- window the user opened themselves, and every `wezterm cli` call that drives
-- it is pinned to that GUI's own socket via WEZTERM_UNIX_SOCKET. A bare
-- `wezterm cli` picks whichever socket it finds first and will happily type
-- into the wrong window when several WezTerm GUIs are up at once.

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Enough history that `wezterm cli get-text --start-line` can reach back past
-- the viewport when an agent needs to re-read a long command's output.
config.scrollback_lines = 10000

-- wezterm-setup: managed block end

return config
