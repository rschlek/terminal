#!/usr/bin/env bash
# agent-menu setup (macOS, Linux) - install the agent menu for the current user and point
# the standing Warp tab configs at it. Safe to re-run. It:
#   1. copies agent-menu.sh to $AGENT_MENU_DIR (refreshed every run; default
#      ${XDG_CONFIG_HOME:-$HOME/.config}/agent-menu), so the tab configs never point
#      into the versioned plugin directory;
#   2. creates $AGENT_MENU_DIR/agents.yaml from the template ONLY when it does not exist;
#   3. writes <tab_configs>/<agent>.toml for each agent, running the menu; a replaced tab
#      config is first copied to $AGENT_MENU_DIR/backup/;
#   4. reports any <agent>-resume.toml as redundant - it never deletes one.
#
#   setup.sh [--check] [--carry-args] [--agent-args 'name=<args>']... [--projects-root <dir>]
#            [--agents "claude codex"]
#
# --check reports what it found and would do and changes nothing, including the flags each
# existing standing tab config launches with; --carry-args writes those flags into each
# block's `args` line when the config is created now; --agent-args 'name=<args>' sets a
# block's `args` explicitly (repeatable; wins over --carry-args for that agent);
# --projects-root fills projects_root. All three apply only when the config is created; an
# existing one is never rewritten. WARP_TAB_CONFIGS_DIR overrides Warp's tab_configs dir
# (macOS ~/.warp/tab_configs, Linux ${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill="$(dirname "$here")"
# shellcheck source=agent-menu.sh
. "$here/agent-menu.sh"

check=0; carry=0; root_arg=""; agents="claude codex"
# Explicit args, parallel arrays (bash 3.2 has no associative arrays).
explicit_names=(); explicit_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --carry-args) carry=1 ;;
    --agent-args)
      pair="${2:?--agent-args needs name=<args>}"; shift
      [[ "$pair" =~ ^([A-Za-z0-9._-]+)=(.*)$ ]] || { echo "setup.sh: --agent-args takes name=<args> (got: $pair)" >&2; exit 2; }
      explicit_names+=("${BASH_REMATCH[1]}"); explicit_args+=("${BASH_REMATCH[2]}") ;;
    --projects-root) root_arg="${2:?--projects-root needs a value}"; shift ;;
    --agents) agents="${2:?--agents needs a value}"; shift ;;
    *) echo "setup.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
say() { printf 'agent-menu setup: %s\n' "$*"; }
# explicit_for <agent>: prints the explicit args and exits 0, or exits 1 when none were given.
explicit_for() {
  local i
  for ((i = 0; i < ${#explicit_names[@]}; i++)); do
    if [ "${explicit_names[$i]}" = "$1" ]; then printf '%s' "${explicit_args[$i]}"; return 0; fi
  done
  return 1
}

if [ -n "${WARP_TAB_CONFIGS_DIR:-}" ]; then tabdir="$WARP_TAB_CONFIGS_DIR"
elif [ "$(uname -s)" = Darwin ]; then tabdir="$HOME/.warp/tab_configs"
else tabdir="${XDG_DATA_HOME:-$HOME/.local/share}/warp-terminal/tab_configs"; fi
mdir="$(menu_dir)"; config="$mdir/agents.yaml"; menu="$mdir/agent-menu.sh"

for a in $agents; do
  [[ "$a" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "setup.sh: bad agent name: $a" >&2; exit 2; }
done

# standing_command <file>: the first `commands` string, TOML \\ and \" decoded.
standing_command() {
  local line re='^[[:space:]]*commands[[:space:]]*=[[:space:]]*\[[[:space:]]*"(([^"\\]|\\.)*)"'
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $re ]]; then
      line="${BASH_REMATCH[1]}"
      line="${line//\\\\/$'\001'}"; line="${line//\\\"/\"}"; line="${line//$'\001'/\\}"
      printf '%s\n' "$line"; return 0
    fi
  done < "$1"
  return 1
}

# What each existing standing tab config runs today (flags = command minus the agent name).
# Parallel arrays (bash 3.2 has no associative arrays): agent_names[i] -> agent_flags[i].
agent_names=(); agent_flags=()
flags_for() {
  local i
  for ((i = 0; i < ${#agent_names[@]}; i++)); do
    if [ "${agent_names[$i]}" = "$1" ]; then printf '%s' "${agent_flags[$i]}"; return 0; fi
  done
  return 0
}
for a in $agents; do
  f="$tabdir/$a.toml"; fl=""
  if [ ! -f "$f" ]; then
    say "no $f yet"
  else
    cmd="$(standing_command "$f" || true)"
    first="${cmd%%[[:space:]]*}"; rest="${cmd#"$first"}"; rest="${rest#"${rest%%[![:space:]]*}"}"
    if [[ "$cmd" == *agent-menu* ]]; then say "$f already opens the agent menu"
    elif [ "$first" = "$a" ] && [ -n "$rest" ]; then fl="$rest"; say "$f launches '$a' with flags: $rest"
    else say "$f runs: $cmd"; fi
  fi
  agent_names+=("$a"); agent_flags+=("$fl")
done
for a in $agents; do
  if [ -f "$tabdir/$a-resume.toml" ]; then
    say "$tabdir/$a-resume.toml is redundant once the menu is in place (Resume is on the menu); it was NOT deleted"
  fi
done

if [ -f "$config" ]; then
  say "config $config exists; it is left as it is"
  for a in $agents; do
    if ! cfg_has_block "$a"; then say "WARNING: $config has no '$a' block; add one before using the $a tab"; continue; fi
    fl="$(flags_for "$a")"
    if [ -n "$fl" ]; then
      have="$(cfg_get "$a" args || true)"
      [ "$have" = "$fl" ] || say "the '$a' block's args are [$have]; the old tab config used [$fl] - edit the config to keep them"
    fi
  done
  for ((i = 0; i < ${#explicit_names[@]}; i++)); do
    say "--agent-args for '${explicit_names[$i]}' not applied: the config exists; edit its block instead"
  done
else
  say "config $config will be created from the template"
  for ((i = 0; i < ${#explicit_names[@]}; i++)); do
    say "  '${explicit_names[$i]}' args: [${explicit_args[$i]}] (from --agent-args)"
  done
  for a in $agents; do
    if explicit_for "$a" >/dev/null; then continue; fi
    fl="$(flags_for "$a")"
    [ -n "$fl" ] || continue
    if [ "$carry" = 1 ]; then say "  '$a' args: $fl (carried from the old tab config)"
    else say "  '$a' args left empty; --carry-args would keep: $fl"; fi
  done
fi

if [ "$check" = 1 ]; then say "check only - nothing changed"; exit 0; fi

# 1. The menu script, refreshed every run.
mkdir -p "$mdir"
cp -f "$here/agent-menu.sh" "$menu.tmp.$$" && mv -f "$menu.tmp.$$" "$menu"
say "installed the menu at $menu"

# 2. The config, only when absent.
if [ ! -f "$config" ]; then
  block=""; tmp="$config.tmp.$$"; : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then block="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[^[:space:]] ]]; then block=""; fi
    if [[ "$line" == projects_root:* ]] && [ -n "$root_arg" ]; then line="projects_root: $root_arg"
    elif [[ "$line" == '  args:'* ]] && [ -n "$block" ] && explicit_for "$block" >/dev/null; then
      ex="$(explicit_for "$block")"; line="  args: $ex"; line="${line%"${line##*[![:space:]]}"}"
    elif [[ "$line" == '  args:'* ]] && [ "$carry" = 1 ] && [ -n "$block" ]; then
      fl="$(flags_for "$block")"; [ -z "$fl" ] || line="  args: $fl"
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$skill/templates/agents.yaml"
  mv -f "$tmp" "$config"
  say "created $config"
  for a in $agents; do
    if ! cfg_has_block "$a"; then say "WARNING: the template has no '$a' block; add one to $config before using the $a tab"; fi
  done
fi

# 3. The standing tab configs. Path: shell single-quoted, then TOML basic-string escaped.
mkdir -p "$tabdir"
q="'\\''"; m="${menu//\'/$q}"; m="${m//\\/\\\\}"; m="${m//\"/\\\"}"
for a in $agents; do
  f="$tabdir/$a.toml"; tmp="$f.tmp.$$"; : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; line="${line//\{menu\}/$m}"; line="${line//\{agent\}/$a}"
    printf '%s\n' "$line" >> "$tmp"
  done < "$skill/templates/tab-config.unix.toml"
  if [ -f "$f" ]; then
    if [ "$(cat "$tmp")" = "$(cat "$f")" ]; then rm -f "$tmp"; say "$f is current"; continue; fi
    mkdir -p "$mdir/backup"; b="$mdir/backup/$a.$(date +%Y%m%d-%H%M%S).toml"
    cp -f "$f" "$b"; say "saved the previous $f as $b"
  fi
  mv -f "$tmp" "$f"; say "wrote $f"
done
