#!/usr/bin/env bash
# shared-pane: one visible WezTerm window that a human and an agent drive together.
# The agent opens it, runs a command, the human types anything secret (password, Duo,
# vault unlock), and the agent keeps reading and sending into the SAME authenticated shell.
#
#   pane.sh open  <name> [title]      -> starts a uniquely-classed WezTerm GUI, prints nothing;
#                                        state in $STATE_DIR/<name>.state (socket + pane id)
#   pane.sh send  <name> <text...>     -> types text into the pane, followed by Enter
#   pane.sh type  <name> <text...>     -> types text WITHOUT Enter
#   pane.sh read  <name> [lines]       -> prints the last N visible lines (default 40)
#   pane.sh wait  <name> <regex> [s]   -> blocks until the pane text matches regex (default 600 s);
#                                        exit 0 on match, 3 on timeout, 4 if the pane is gone
#   pane.sh title <name> <title>       -> retitle the tab (what the human sees)
#   pane.sh alive <name>               -> exit 0 if the pane still exists
#   pane.sh close <name>               -> kill the pane and its GUI, remove state
#
# Why the unique class: every WezTerm GUI process publishes its own unix socket, and a
# bare `wezterm cli` picks whichever it finds first. Each shared pane is its own GUI with
# its own --class and we always address it through WEZTERM_UNIX_SOCKET. Never read
# secrets out of the pane; the human types them, the agent only ever reads what the
# shell prints afterwards.
#
# The state file is <name>.state, never <name>.env: a shell guard hook, if the environment
# has one, may block any command that would print a .env file, and this file holds nothing
# secret - only a socket path, a pane id, the window class, and the GUI pid.
set -euo pipefail
STATE_DIR="${SHARED_PANE_STATE:-$HOME/.local/state/shared-pane}"
WEZ="${WEZTERM_BIN:-wezterm}"
mkdir -p "$STATE_DIR"

die() { echo "pane.sh: $*" >&2; exit 2; }
state_file() { echo "$STATE_DIR/$1.state"; }
load() { local f; f="$(state_file "$1")"; [ -f "$f" ] || die "no pane named '$1' (state $f missing)"; # shellcheck disable=SC1090
  . "$f"; export WEZTERM_UNIX_SOCKET="$SOCK"; }

cmd_open() {
  local name="$1" title="${2:-shared pane: $1}"
  local f; f="$(state_file "$name")"
  [ ! -f "$f" ] || die "pane '$name' already exists (close it first)"
  local class="shared-pane-$name-$$"
  local before; before="$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wezterm/" 2>/dev/null | grep '^gui-sock-' || true)"
  setsid nohup "$WEZ" start --class "$class" -- bash -l >/dev/null 2>&1 < /dev/null &
  local gui_pid=$!
  local sock="" i
  for i in $(seq 1 60); do
    sock="$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wezterm/" 2>/dev/null | grep '^gui-sock-' | grep -vxF "$before" | head -1 || true)"
    [ -z "$sock" ] || break
    sleep 0.25
  done
  [ -n "$sock" ] || die "wezterm GUI did not publish a socket"
  export WEZTERM_UNIX_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wezterm/$sock"
  local pane=""
  for i in $(seq 1 60); do
    pane="$("$WEZ" cli list --format json 2>/dev/null | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d[0]["pane_id"]) if d else print("")
except Exception: print("")')"
    [ -z "$pane" ] || break
    sleep 0.25
  done
  [ -n "$pane" ] || die "no pane appeared in the new GUI"
  "$WEZ" cli set-tab-title --pane-id "$pane" "$title" >/dev/null 2>&1 || true
  printf 'SOCK=%q\nPANE=%q\nCLASS=%q\nGUI_PID=%q\n' "$WEZTERM_UNIX_SOCKET" "$pane" "$class" "$gui_pid" > "$f"
  chmod 600 "$f"
}

cmd_send()  { load "$1"; shift; printf '%s\n' "$*" | "$WEZ" cli send-text --pane-id "$PANE" --no-paste; }
cmd_type()  { load "$1"; shift; printf '%s' "$*"   | "$WEZ" cli send-text --pane-id "$PANE" --no-paste; }
cmd_read()  { load "$1"; "$WEZ" cli get-text --pane-id "$PANE" | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "${2:-40}"; }
cmd_title() { load "$1"; shift; "$WEZ" cli set-tab-title --pane-id "$PANE" "$*"; }
cmd_alive() { load "$1"; "$WEZ" cli list --format json 2>/dev/null | grep -q "\"pane_id\": *$PANE\b"; }
cmd_wait()  {
  local name="$1" re="$2" budget="${3:-600}" t=0
  load "$name"
  while :; do
    cmd_alive "$name" || return 4
    if "$WEZ" cli get-text --pane-id "$PANE" 2>/dev/null | grep -Eq -- "$re"; then return 0; fi
    [ "$t" -lt "$budget" ] || return 3
    sleep 2; t=$((t+2))
  done
}
cmd_close() {
  local f; f="$(state_file "$1")"
  if [ -f "$f" ]; then load "$1"; "$WEZ" cli kill-pane --pane-id "$PANE" >/dev/null 2>&1 || true
    kill "$GUI_PID" >/dev/null 2>&1 || true; rm -f "$f"; fi
}

case "${1:-}" in
  open)  shift; cmd_open "$@" ;;
  send)  shift; cmd_send "$@" ;;
  type)  shift; cmd_type "$@" ;;
  read)  shift; cmd_read "$@" ;;
  wait)  shift; cmd_wait "$@" ;;
  title) shift; cmd_title "$@" ;;
  alive) shift; cmd_alive "$@" ;;
  close) shift; cmd_close "$@" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
