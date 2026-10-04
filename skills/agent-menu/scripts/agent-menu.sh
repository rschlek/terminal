#!/usr/bin/env bash
# agent-menu: the menu a standing Warp tab runs for one agent CLI - a fresh session in
# the home folder, a fresh or resumed session in a project, or the agent's own resume
# list. macOS and Linux; bash 3.2 or later, nothing beyond coreutils.
#
# A child process cannot change its parent shell's directory, so the menu does not run
# the agent itself. It draws on /dev/tty and prints ONE shell line on stdout, which the
# tab config evals in the tab's own shell (bash or zsh):
#
#   eval "$(bash '<AGENT_MENU_DIR>/agent-menu.sh' claude)"
#
# The printed line is `cd -- '<folder>' && <command line>`, so when the agent exits the
# user is at a prompt in that folder. Esc on the home screen prints nothing: plain prompt.
#
#   agent-menu.sh <agent>                    interactive; prints the line to eval
#   agent-menu.sh --print <agent> <mode>     print the composed command line (new|resume|resume_all|new_project)
#   agent-menu.sh --list [<agent>]           print the project rows: name TAB path TAB scope TAB summary
#                                            (with an agent whose block has new_project, the
#                                            pinned `+ new project` row comes first)
#   agent-menu.sh --entries                  print the home screen's entries: key TAB folder
#
# Home screen: Home (`new` in $HOME), Project... (the project view), Resume (`resume_all`,
# else `resume`, in $HOME). With `start_in: projects_root` and an existing projects root, a
# first entry Projects root (`new` in projects_root) is added and selected when the menu
# opens; Home stays as the second entry. Project view: folders directly under projects_root, recently
# opened first; type to filter, Up/Down, Enter = new there, Tab toggles resume, Esc = back.
# When the agent's block has a `new_project` line, a pinned first row `+ new project` (new
# mode only, never filtered out) runs that line in projects_root and records nothing.
#
# Config: $AGENT_MENU_DIR/agents.yaml, AGENT_MENU_DIR defaulting to
# ${XDG_CONFIG_HOME:-$HOME/.config}/agent-menu. Flat format, read line by line: top-level
# `key: value`; an agent block is `name:` alone, then indented `key: value` lines. Values
# run verbatim to end of line (quotes kept, no inline comments); `{args}` is replaced by
# the block's args (placeholder and the spaces before it dropped when args is empty).
# Recent projects: $AGENT_MENU_DIR/recent.tsv, `<unix-seconds> TAB <path>`, newest first.
#
# Sourcing this file (tests) defines the functions without running the menu.

menu_dir() { printf '%s\n' "${AGENT_MENU_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-menu}"; }

# --- Config: cfg_get <section> <key>. Section "" is the top level. Exit 1 when absent.
# Re-reads the file each call; it is a handful of lines.
cfg_get() {
  local want_sec="$1" want_key="$2" file line sec="" key val
  local re_top='^([A-Za-z0-9_.-]+):([[:space:]]+(.*))?$'
  local re_sub='^[[:space:]]+([A-Za-z0-9_.-]+):([[:space:]]+(.*))?$'
  file="$(menu_dir)/agents.yaml"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # drop trailing whitespace
    while [ -n "$line" ] && [[ "${line: -1}" == [[:space:]] ]]; do line="${line%?}"; done
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi
    if [[ "$line" =~ $re_top ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[3]}"
      if [ -z "$want_sec" ] && [ "$key" = "$want_key" ]; then printf '%s\n' "$val"; return 0; fi
      if [ -z "$val" ]; then sec="$key"; else sec=""; fi
    elif [[ "$line" =~ $re_sub ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[3]}"
      if [ -n "$sec" ] && [ "$sec" = "$want_sec" ] && [ "$key" = "$want_key" ]; then printf '%s\n' "$val"; return 0; fi
    fi
  done < "$file"
  return 1
}

# cfg_has_block <agent>: exit 0 when the config has a `<agent>:` line.
cfg_has_block() {
  local file line
  file="$(menu_dir)/agents.yaml"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    while [ -n "$line" ] && [[ "${line: -1}" == [[:space:]] ]]; do line="${line%?}"; done
    [ "$line" = "$1:" ] && return 0
  done < "$file"
  return 1
}

# projects_root: quotes stripped, a leading ~ expanded; empty when unset.
projects_root() {
  local v
  v="$(cfg_get "" projects_root)" || v=""
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  case "$v" in '~') v="$HOME" ;; '~/'*) v="$HOME/${v#\~/}" ;; esac
  printf '%s\n' "$v"
}

# home_entries: the home screen's entries in order, one `key TAB folder` line each:
# root (a fresh session in the projects root), home, project, resume. The root entry is
# there only when `start_in: projects_root` is set and the root exists; it then comes
# first, so it is the one selected when the menu opens.
home_entries() {
  local root start
  root="$(projects_root)"
  start="$(cfg_get "" start_in)" || start=""
  if [ "$start" = projects_root ] && [ -n "$root" ] && [ -d "$root" ]; then printf 'root\t%s\n' "$root"; fi
  printf 'home\t%s\nproject\t%s\nresume\t%s\n' "$HOME" "$root" "$HOME"
}

# agent_command <agent> <new|resume|resume_all|new_project>: the composed line, exit 1 when absent.
agent_command() {
  local agent="$1" mode="$2" line args
  cfg_has_block "$agent" || return 1
  if ! line="$(cfg_get "$agent" "$mode")"; then
    if [ "$mode" = resume_all ] && line="$(cfg_get "$agent" resume)"; then :
    elif [ "$mode" = new ]; then line="$agent {args}"
    else return 1; fi
  fi
  [ -n "$line" ] || return 1
  args="$(cfg_get "$agent" args)" || args=""
  if [ -z "$args" ]; then
    # drop the placeholder and the whitespace before it
    while [[ "$line" == *' {args}'* ]]; do line="${line/ \{args\}/\{args\}}"; done
    line="${line//\{args\}/}"
  else
    line="${line//\{args\}/$args}"
  fi
  while [[ "$line" == ' '* ]]; do line="${line# }"; done
  while [[ "$line" == *' ' ]]; do line="${line% }"; done
  printf '%s\n' "$line"
}

# yaml_field <file> <key>: one top-level scalar from a project.yaml (trailing # comment,
# quotes, and folded > / literal | block scalars joined with spaces).
yaml_field() {
  local file="$1" name="$2" line v found=0 out=""
  local re_key="^${name}:([[:space:]]+(.*))?\$"
  local re_dq='^"(([^"\\]|\\.)*)"' re_sq="^'(([^']|'')*)'" re_block='^[>|][+-]?[0-9]?$'
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$found" = 1 ]; then
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]] ]] || break
      while [[ "$line" == [[:space:]]* ]]; do line="${line#?}"; done
      while [ -n "$line" ] && [[ "${line: -1}" == [[:space:]] ]]; do line="${line%?}"; done
      if [ -z "$out" ]; then out="$line"; else out="$out $line"; fi
      continue
    fi
    [[ "$line" =~ $re_key ]] || continue
    v="${BASH_REMATCH[2]}"
    while [ -n "$v" ] && [[ "${v: -1}" == [[:space:]] ]]; do v="${v%?}"; done
    if [[ "$v" =~ $re_dq ]]; then
      v="${BASH_REMATCH[1]}"; v="${v//\\\"/\"}"; v="${v//\\\\/\\}"; printf '%s\n' "$v"; return 0
    fi
    if [[ "$v" =~ $re_sq ]]; then
      v="${BASH_REMATCH[1]}"; v="${v//\'\'/\'}"; printf '%s\n' "$v"; return 0
    fi
    case "$v" in '#'*) v="" ;; esac
    v="${v%%[[:space:]]#*}"
    while [ -n "$v" ] && [[ "${v: -1}" == [[:space:]] ]]; do v="${v%?}"; done
    if [ -z "$v" ] || [[ "$v" =~ $re_block ]]; then found=1; continue; fi
    printf '%s\n' "$v"; return 0
  done < "$file"
  printf '%s\n' "$out"
}

# --- Recent projects (newest first; file order is the sort order).
recent_file() { printf '%s\n' "$(menu_dir)/recent.tsv"; }

save_recent() {
  local p="$1" f tmp line n=1
  f="$(recent_file)"
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  printf '%s\t%s\n' "$(date +%s)" "$p" > "$tmp"
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ "${line#*	}" = "$p" ] && continue
      [ -n "${line#*	}" ] || continue
      n=$((n + 1)); [ "$n" -le 200 ] || break
      printf '%s\n' "$line" >> "$tmp"
    done < "$f"
  fi
  mv -f "$tmp" "$f"
}

# list_projects <root>: name TAB path TAB scope TAB summary, recent first, then by name.
list_projects() {
  local root="${1%/}" d name f rank line scope summary k
  [ -n "$root" ] && [ -d "$root" ] || return 0
  f="$(recent_file)"
  {
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"; name="${d##*/}"
      case "$name" in .*) continue ;; esac
      rank=999999
      if [ -f "$f" ]; then
        k=0
        while IFS= read -r line || [ -n "$line" ]; do
          if [ "${line#*	}" = "$d" ]; then rank=$k; break; fi
          k=$((k + 1))
        done < "$f"
      fi
      scope=""; summary=""
      if [ -f "$d/project.yaml" ]; then
        scope="$(yaml_field "$d/project.yaml" scope)"
        summary="$(yaml_field "$d/project.yaml" summary)"
      fi
      printf '%06d\t%s\t%s\t%s\t%s\n' "$rank" "$name" "$d" "$scope" "$summary"
    done
  } | LC_ALL=C sort -t '	' -k1,1n -k2,2f | while IFS= read -r line; do printf '%s\n' "${line#*	}"; done
}

# --- Drawing on /dev/tty: a fixed block of rows redrawn in place with relative cursor
# moves; every row is cut to the terminal width so nothing wraps.
TTY_W=80; TTY_H=24; REGION=0
tty_size() {
  local s
  s="$(stty size <&4 2>/dev/null)" || s=""
  if [ -n "$s" ]; then TTY_H="${s%% *}"; TTY_W="${s##* }"; fi
  [ "$TTY_W" -gt 40 ] 2>/dev/null || TTY_W=80
  [ "$TTY_H" -gt 10 ] 2>/dev/null || TTY_H=24
}
# draw <line>...: paint the lines from the region's top row, cursor back to that top row.
draw() {
  local n=$# i=0 l w=$((TTY_W - 1)) out=""
  for l in "$@"; do
    i=$((i + 1))
    l="${l:0:$w}"
    out="$out"$'\r\033[K'"$l"
    [ "$i" -lt "$n" ] && out="$out"$'\n'
  done
  [ "$n" -gt 1 ] && out="$out"$'\033['"$((n - 1))"'A'
  printf '%s\r' "$out" >&3
  REGION=$n
}
clear_region() {
  local blanks=() i
  for ((i = 0; i < REGION; i++)); do blanks+=(""); done
  [ "$REGION" -gt 0 ] && draw "${blanks[@]}"
}
# Short escape timeout where bash supports fractions (4+); 3.2 waits a whole second.
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then ESC_WAIT=0.05; else ESC_WAIT=1; fi
# read_key: sets KEY to up|down|enter|tab|esc|backspace|char:<c>|other
read_key() {
  local k rest
  IFS= read -rsn1 -d '' k <&4 || { KEY=esc; return; }
  case "$k" in
    $'\033')
      rest=""
      IFS= read -rsn2 -t "$ESC_WAIT" -d '' rest <&4 || true
      case "$rest" in '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '') KEY=esc ;; *) KEY=other ;; esac ;;
    $'\n'|$'\r') KEY=enter ;;
    $'\t') KEY=tab ;;
    $'\177'|$'\b') KEY=backspace ;;
    [A-Za-z0-9._\ -]) KEY="char:$k" ;;
    *) KEY=other ;;
  esac
}

home_menu() {
  local sel=0 i n text note_p keys=() labels=() notes=() rows line
  note_p="pick a project, fresh session there (Tab there: resume)"
  if [ -z "$ROOT" ]; then note_p="no projects root - set projects_root in $CONFIG"
  elif [ ! -d "$ROOT" ]; then note_p="projects root $ROOT not found - set projects_root in $CONFIG"; fi
  while IFS= read -r line; do
    keys+=("${line%%	*}")
    case "${line%%	*}" in
      root) labels+=("Projects root"); notes+=("fresh session in $ROOT") ;;
      home) labels+=("Home"); notes+=("fresh session in $HOME") ;;
      project) labels+=("Project..."); notes+=("$note_p") ;;
      resume) labels+=("Resume"); notes+=("the $AGENT resume list") ;;
    esac
  done <<EOF
$(home_entries)
EOF
  n=${#keys[@]}
  while :; do
    rows=(" $AGENT" "")
    for ((i = 0; i < n; i++)); do
      text="$(printf '%-14s %s' "${labels[$i]}" "${notes[$i]}")"
      if [ "$i" = "$sel" ]; then rows+=(" > $text"); else rows+=("   $text"); fi
    done
    rows+=("" " Up/Down move   Enter select   Esc cancel")
    draw "${rows[@]}"
    read_key
    case "$KEY" in
      up) [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
      down) [ "$sel" -lt $((n - 1)) ] && sel=$((sel + 1)) ;;
      esc) clear_region; PICK=""; return ;;
      enter) clear_region; PICK="${keys[$sel]}"; return ;;
    esac
  done
}

# has_new_project <agent>: exit 0 when the pinned `+ new project` row applies (the block
# has a new_project line and the projects root exists).
has_new_project() {
  local root
  root="$(projects_root)"
  [ -n "$root" ] && [ -d "$root" ] && agent_command "$1" new_project > /dev/null
}
NEW_PROJECT_LABEL="+ new project"

# project_picker: sets CHOICE_DIR and CHOICE_MODE (new_project for the pinned row), or
# CHOICE_DIR="" on Esc.
project_picker() {
  local names=() paths=() scopes=() sums=() line rest
  while IFS= read -r line; do
    names+=("${line%%	*}"); rest="${line#*	}"
    paths+=("${rest%%	*}"); rest="${rest#*	}"
    scopes+=("${rest%%	*}"); sums+=("${rest#*	}")
  done <<EOF
$(list_projects "$ROOT")
EOF
  local filter="" mode=new sel=0 offset=0 nrows i r view=() rows head hint more text
  local pin=0 on_pin=0 prows
  nrows=$((TTY_H - 8)); [ "$nrows" -gt 12 ] && nrows=12; [ "$nrows" -lt 3 ] && nrows=3
  shopt -s nocasematch
  while :; do
    view=()
    for ((i = 0; i < ${#names[@]}; i++)); do
      [ -z "${names[$i]}" ] && continue
      if [ -z "$filter" ] || [[ "${names[$i]}" == *"$filter"* ]]; then view+=("$i"); fi
    done
    pin=0; [ "$HAS_NP" = 1 ] && [ "$mode" = new ] && pin=1
    if [ "$pin" = 0 ]; then on_pin=0; elif [ "${#view[@]}" -eq 0 ]; then on_pin=1; fi
    prows=$((nrows - pin))
    [ "$sel" -ge "${#view[@]}" ] && sel=$(( ${#view[@]} > 0 ? ${#view[@]} - 1 : 0 ))
    [ "$sel" -lt "$offset" ] && offset=$sel
    [ "$sel" -ge $((offset + prows)) ] && offset=$((sel - prows + 1))
    if [ "$mode" = resume ]; then head=" $AGENT  -  RESUME a session"; hint="(Tab: switch to new)"
    else head=" $AGENT  -  NEW session"; hint="(Tab: switch to resume)"; fi
    rows=("$(printf '%-34s%s' "$head" "$hint")" "")
    if [ "$pin" = 1 ]; then
      if [ "$on_pin" = 1 ]; then rows+=(" > $NEW_PROJECT_LABEL"); else rows+=("   $NEW_PROJECT_LABEL"); fi
    fi
    for ((r = 0; r < prows; r++)); do
      i=$((offset + r))
      if [ "$i" -lt "${#view[@]}" ]; then
        local j="${view[$i]}"
        text="$(printf '%-24s %-10s %s' "${names[$j]}" "${scopes[$j]}" "${sums[$j]}")"
        if [ "$i" = "$sel" ] && [ "$on_pin" = 0 ]; then rows+=(" > $text"); else rows+=("   $text"); fi
      else
        rows+=("")
      fi
    done
    more=$(( ${#view[@]} - offset - prows ))
    if [ "$more" -gt 0 ]; then rows+=("   ... $more more")
    elif [ "${#view[@]}" -eq 0 ]; then rows+=("   no match")
    else rows+=(""); fi
    rows+=(" filter: ${filter}_" " type to filter   Up/Down move   Tab new/resume   Enter select   Esc back")
    draw "${rows[@]}"
    read_key
    case "$KEY" in
      up)
        if [ "$on_pin" = 1 ]; then :
        elif [ "$sel" -gt 0 ]; then sel=$((sel - 1))
        elif [ "$pin" = 1 ]; then on_pin=1; fi ;;
      down)
        if [ "$on_pin" = 1 ]; then [ "${#view[@]}" -gt 0 ] && { on_pin=0; sel=0; }
        elif [ "$sel" -lt $(( ${#view[@]} - 1 )) ]; then sel=$((sel + 1)); fi ;;
      tab) if [ "$mode" = new ]; then mode=resume; else mode=new; fi ;;
      backspace) [ -n "$filter" ] && { filter="${filter%?}"; sel=0; on_pin=0; } ;;
      esc) shopt -u nocasematch; clear_region; CHOICE_DIR=""; return ;;
      enter)
        if [ "$on_pin" = 1 ]; then
          shopt -u nocasematch; clear_region
          CHOICE_DIR="$ROOT"; CHOICE_MODE=new_project; return
        elif [ "${#view[@]}" -gt 0 ]; then
          shopt -u nocasematch; clear_region
          CHOICE_DIR="${paths[${view[$sel]}]}"; CHOICE_MODE="$mode"; return
        fi ;;
      char:*) filter="$filter${KEY#char:}"; sel=0; on_pin=0 ;;
    esac
  done
}

# shell_quote <s>: one single-quoted word for the evaluating shell.
shell_quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }

main() {
  case "${1:-}" in
    --print)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: agent-menu.sh --print <agent> <new|resume|resume_all|new_project>" >&2; return 2; }
      agent_command "$2" "$3" || { echo "agent-menu: no '$3' line for '$2' in $(menu_dir)/agents.yaml" >&2; return 1; }
      return 0 ;;
    --list)
      if [ -n "${2:-}" ] && has_new_project "$2"; then printf '%s\t%s\t\t\n' "$NEW_PROJECT_LABEL" "$(projects_root)"; fi
      list_projects "$(projects_root)"; return 0 ;;
    --entries) home_entries; return 0 ;;
    ''|-*) echo "usage: agent-menu.sh <agent> | --print <agent> <mode> | --list [<agent>] | --entries" >&2; return 2 ;;
  esac
  AGENT="$1"; CONFIG="$(menu_dir)/agents.yaml"
  if [ ! -f "$CONFIG" ]; then echo "agent-menu: no config at $CONFIG - run the agent-menu setup" >&2; return 1; fi
  if ! cfg_has_block "$AGENT"; then echo "agent-menu: $CONFIG has no '$AGENT' block" >&2; return 1; fi
  ROOT="$(projects_root)"
  HAS_NP=0; has_new_project "$AGENT" && HAS_NP=1
  # Keys come from fd 4 and drawing goes to fd 3, both the terminal; the two
  # AGENT_MENU_TTY_* variables swap in files so tests can script a session.
  exec 3>"${AGENT_MENU_TTY_OUT:-/dev/tty}" 4<"${AGENT_MENU_TTY_IN:-/dev/tty}" || { echo "agent-menu: no terminal" >&2; return 1; }
  tty_size
  printf '\033[?25l' >&3
  trap 'printf "\033[?25h" >&3' EXIT
  trap 'clear_region; exit 130' INT
  local dir="" mode=""
  while :; do
    home_menu
    case "$PICK" in
      '') return 0 ;;
      root) dir="$ROOT"; mode=new; break ;;
      home) dir="$HOME"; mode=new; break ;;
      resume) dir="$HOME"; mode=resume_all; break ;;
      project)
        [ -n "$ROOT" ] && [ -d "$ROOT" ] || continue
        [ -n "$(list_projects "$ROOT")" ] || [ "$HAS_NP" = 1 ] || continue
        project_picker
        if [ -n "$CHOICE_DIR" ]; then
          dir="$CHOICE_DIR"; mode="$CHOICE_MODE"
          [ "$mode" = new_project ] || save_recent "$dir"
          break
        fi ;;
    esac
  done
  local line
  if ! line="$(agent_command "$AGENT" "$mode")"; then
    echo "agent-menu: the '$AGENT' block in $CONFIG has no '$mode' line" >&2; return 1
  fi
  printf '%s> %s\n' "$dir" "$line" >&3
  printf 'cd -- %s && %s\n' "$(shell_quote "$dir")" "$line"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
