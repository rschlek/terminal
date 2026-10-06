#!/usr/bin/env bash
# agent-menu: the menu a standing Warp tab runs for one agent CLI - a fresh session in
# the home folder, a fresh or resumed session in a project, or the agent's own resume
# list. macOS and Linux; bash 3.2 or later, nothing beyond coreutils, sed and awk.
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
#   agent-menu.sh --sessions <agent>         print the session list: id TAB folder TAB branch TAB title
#                                            (nothing when the agent's list is off)
#
# Home screen: Home (`new` in $HOME), Project... (the project view), Resume (`resume_all`,
# else `resume`, in $HOME). With `start_in: projects_root` and an existing projects root,
# the order is Projects root (`new` in projects_root, selected when the menu opens),
# Project..., Resume (in projects_root instead of $HOME), Home last. Project view: folders
# directly under projects_root, recently opened first; type to filter, Up/Down, Enter = new there, Tab toggles resume, Esc = back.
# When the agent's block has a `new_project` line, a pinned first row `+ new project` (new
# mode only, never filtered out) runs that line in projects_root and records nothing.
#
# Session list: when the agent's block has `session_list: claude` (the default for a block
# named `claude`), Resume opens the past chats of every folder, newest first, read from
# Claude Code's session store: title, folder, age, branch. Type to filter, Enter reopens the
# chat in the folder it was started in (the `resume` line plus the session id), Tab picks
# another folder from the project view and reopens it there, Esc goes back. With no readable
# chats, Resume runs the plain resume line as before.
#
# Self-refresh: the installed copy carries plugin-source.txt (written by setup). When the
# plugin it came from has a newer version, the menu copies the newer script over itself and
# runs it; on any failure it runs as it is. agents.yaml is never touched.
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

# home_entries: the home screen's entries in order, one `key TAB folder` line each.
# Without `start_in: projects_root` the menu is home, project, resume, with resume in
# $HOME. With the key set and an existing projects root it is root (a fresh session in the
# projects root), project, resume, home: everything in the projects root together and home
# last. Root comes first, so it is the one selected when the menu opens, and resume opens
# in the projects root too, where those sessions were started.
home_entries() {
  local root start
  root="$(projects_root)"
  start="$(cfg_get "" start_in)" || start=""
  if [ "$start" = projects_root ] && [ -n "$root" ] && [ -d "$root" ]; then
    printf 'root\t%s\nproject\t%s\nresume\t%s\nhome\t%s\n' "$root" "$root" "$root" "$HOME"
  else
    printf 'home\t%s\nproject\t%s\nresume\t%s\n' "$HOME" "$root" "$HOME"
  fi
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

# --- The session list: past chats from every folder, for an agent whose block turns it
# on. `session_list: claude` reads Claude Code's on-disk session store; `off` (or any other
# value) keeps the agent's own resume command. With no key, a block named `claude` gets
# `claude` and every other block `off`, so existing configs need no change.
session_list_kind() {
  local v
  if v="$(cfg_get "$1" session_list)"; then :
  elif [ "$1" = claude ]; then v=claude
  else v=off; fi
  [ "$v" = claude ] && printf 'claude\n'
  return 0
}

# Claude Code keeps one <session-id>.jsonl per chat under <config dir>/projects/<folder>,
# the config dir being CLAUDE_CONFIG_DIR or ~/.claude. The folder name encodes the chat's
# working folder lossily, so the real folder is read from the file instead.
claude_projects_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; }

# json_unescape <body>: a JSON string body decoded; \" \\ \/ kept as the character,
# \n \r \t \b \f and control-character \u escapes become a space.
# The menu calls _unescape and _title, which set REPLY instead of printing, so reading a
# session forks no subshells for them.
json_unescape() { _unescape "$1"; printf '%s' "$REPLY"; }
_unescape() {
  local s="$1" out="" pre c h ch
  while [ -n "$s" ]; do
    case "$s" in
      \\*)
        c="${s:1:1}"; s="${s:2}"
        case "$c" in
          n|r|t|b|f) out="$out " ;;
          u)
            h="${s:0:4}"
            if ! [[ "$h" =~ ^[0-9a-fA-F]{4}$ ]]; then out="$out?"; continue; fi
            s="${s:4}"
            if [ $((16#$h)) -lt 32 ]; then out="$out "
            else ch=""; printf -v ch "\\u$h" 2>/dev/null || ch="?"; [[ "$ch" == '\u'* ]] && ch="?"; out="$out$ch"; fi ;;
          *) out="$out$c" ;;
        esac ;;
      *) pre="${s%%\\*}"; out="$out$pre"; s="${s:${#pre}}" ;;
    esac
  done
  REPLY="$out"
}

# format_title <text>: whitespace runs collapsed, cut to 60 characters.
format_title() { _title "$1"; printf '%s' "$REPLY"; }
_title() {
  local t="$1"
  t="${t//$'\t'/ }"
  while [[ "$t" == *'  '* ]]; do t="${t//  / }"; done
  t="${t# }"; t="${t% }"
  if [ "${#t}" -gt 60 ]; then t="${t:0:57}..."; fi
  REPLY="$t"
}

# format_age <seconds>: now, 12m, 5h, 3d, then weeks.
format_age() {
  local s="$1"
  if [ "$s" -lt 60 ]; then printf 'now'
  elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%sh' $((s / 3600))
  elif [ "$s" -lt $((14 * 86400)) ]; then printf '%sd' $((s / 86400))
  else printf '%sw' $((s / 604800)); fi
}

# path_under <path> <dir>: exit 0 when path is dir or below it (either separator, any case).
path_under() {
  local p="${1//\\//}" d="${2//\\//}"
  while [[ "$p" == */ ]]; do p="${p%/}"; done
  while [[ "$d" == */ ]]; do d="${d%/}"; done
  [ -n "$d" ] && [ -n "$p" ] || return 1
  local r=1
  shopt -q nocasematch && local had=1 || local had=0
  shopt -s nocasematch
  if [[ "$p" == "$d" || "$p" == "$d"/* ]]; then r=0; fi
  [ "$had" = 1 ] || shopt -u nocasematch
  return $r
}

# skipped_folder <cwd>: exit 0 for a throwaway folder - the temp folders (AGENT_MENU_TEMP_DIR
# replaces them, for tests) and the Windows system folder.
skipped_folder() {
  local t
  if [ -n "${AGENT_MENU_TEMP_DIR:-}" ]; then
    path_under "$1" "$AGENT_MENU_TEMP_DIR" && return 0
  else
    case "${1//\\//}" in */[Aa]pp[Dd]ata/[Ll]ocal/[Tt]emp|*/[Aa]pp[Dd]ata/[Ll]ocal/[Tt]emp/*) return 0 ;; esac
    for t in "${TMPDIR:-}" /tmp /var/tmp /private/tmp /var/folders /private/var/folders "${TEMP:-}" "${TMP:-}"; do
      [ -n "$t" ] && path_under "$1" "$t" && return 0
    done
  fi
  [ -n "${SYSTEMROOT:-}" ] && path_under "$1" "$SYSTEMROOT" && return 0
  return 1
}

# file_mtime <file>...: `<unix-seconds> TAB <bytes> TAB <path>` per file (GNU stat, else BSD).
file_mtime() {
  if stat -c '%Y' / > /dev/null 2>&1; then stat -c '%Y	%s	%n' -- "$@" 2>/dev/null
  else stat -f '%m%t%z%t%N' -- "$@" 2>/dev/null; fi
}

# read_session <file> <bytes>: sets RS_CWD, RS_BRANCH, RS_USER (1 when the file has a user
# message) and RS_TITLE from the head and tail only; exit 1 when the head has no working
# folder. The ORIGINAL folder is the first "cwd"
# in the file (a chat resumed elsewhere records later lines with the new folder). The first
# 40 lines of the first 256 KB are read (4 MB when no folder turns up in those), and the
# last 64 KB. Title: the last ai-title in the tail, else the last last-prompt, else the
# first user message's text (a string or the first text block of an array).
read_session() {
  local f="$1" size="${2:-0}" head limit cut tail_out utext ai lp
  RS_CWD=""; RS_BRANCH=""; RS_USER=0; RS_TITLE=""
  for limit in 262144 4194304; do
    cut=0; [ "$size" -gt "$limit" ] && cut=1
    head="$(head -c "$limit" "$f" 2>/dev/null | awk -v cut="$cut" '
      { lines[NR] = $0 }
      END {
        n = NR; if (cut && n > 1) n = n - 1; if (n > 40) n = 40
        for (i = 1; i <= n; i++) {
          l = lines[i]
          if (!gotcwd && match(l, /"cwd":"([^"\\]|\\.)*"/)) {
            gotcwd = 1; cwd = substr(l, RSTART + 7, RLENGTH - 8)
            if (match(l, /"gitBranch":"([^"\\]|\\.)*"/)) br = substr(l, RSTART + 13, RLENGTH - 14)
          }
          if (!gottext && index(l, "\"type\":\"user\"") && match(l, /"message":\{"role":"user","content":/)) {
            user = 1; rest = substr(l, RSTART + RLENGTH)
            if (match(rest, /^"([^"\\]|\\.)*"/)) { gottext = 1; ut = substr(rest, 2, RLENGTH - 2) }
            else if (match(rest, /"type":"text","text":"([^"\\]|\\.)*"/)) { gottext = 1; ut = substr(rest, RSTART + 22, RLENGTH - 23) }
          }
          if (gotcwd && gottext) break
        }
        if (gotcwd) printf "%s\t%s\t%s\t%s\n", cwd, br, user + 0, ut
      }')"
    [ -n "$head" ] && break
    [ "$size" -gt "$limit" ] || break
  done
  [ -n "$head" ] || return 1
  RS_CWD="${head%%	*}"; head="${head#*	}"
  RS_BRANCH="${head%%	*}"; head="${head#*	}"
  RS_USER="${head%%	*}"; utext="${head#*	}"
  tail_out="$(tail -c 65536 "$f" 2>/dev/null | awk '
    match($0, /^\{"type":"ai-title","aiTitle":"([^"\\]|\\.)*"/) { ai = substr($0, 31, RLENGTH - 31) }
    match($0, /^\{"type":"last-prompt","lastPrompt":"([^"\\]|\\.)*"/) { lp = substr($0, 37, RLENGTH - 37) }
    index($0, "\"type\":\"user\"") { u = 1 }
    END { printf "%s\t%s\t%s\n", u + 0, ai, lp }')"
  [ "${tail_out%%	*}" = 1 ] && RS_USER=1
  tail_out="${tail_out#*	}"; ai="${tail_out%%	*}"; lp="${tail_out#*	}"
  _unescape "$ai"; _title "$REPLY"; RS_TITLE="$REPLY"
  [ -n "$RS_TITLE" ] || { _unescape "$lp"; _title "$REPLY"; RS_TITLE="$REPLY"; }
  [ -n "$RS_TITLE" ] || { _unescape "$utext"; _title "$REPLY"; RS_TITLE="$REPLY"; }
  [ -n "$RS_TITLE" ] || RS_TITLE="(untitled)"
  _unescape "$RS_BRANCH"; RS_BRANCH="$REPLY"; [ "$RS_BRANCH" = HEAD ] && RS_BRANCH=""
  _unescape "$RS_CWD"; RS_CWD="$REPLY"
  return 0
}

# list_sessions [<max>]: the session list, newest first by file time, at most max (40) rows:
# `id TAB cwd TAB branch TAB mtime TAB title`. Only <projects>/<folder>/<id>.jsonl files
# count (subfolders, where subagent transcripts live, are never entered). A file is left
# out when it has no user message, no working folder, a folder that no longer exists, or
# a throwaway folder.
list_sessions() {
  local max="${1:-40}" dir files=() f line mt size path id kept=0
  dir="$(claude_projects_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*/*.jsonl; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  while IFS= read -r line; do
    [ "$kept" -lt "$max" ] || break
    mt="${line%%	*}"; line="${line#*	}"; size="${line%%	*}"; path="${line#*	}"
    id="${path##*/}"; id="${id%.jsonl}"
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    read_session "$path" "$size" || continue
    [ "$RS_USER" = 1 ] || continue
    skipped_folder "$RS_CWD" && continue
    [ -d "$RS_CWD" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$RS_CWD" "$RS_BRANCH" "$mt" "$RS_TITLE"
    kept=$((kept + 1))
  done <<EOF
$(file_mtime "${files[@]}" | LC_ALL=C sort -t '	' -k1,1nr)
EOF
}

# session_folder <cwd> <root>: the folder relative to the projects root when under it, else
# the full path (the root itself shows as its full path).
session_folder() {
  local c="$1" r="$2" rel
  if [ -n "$r" ] && path_under "$c" "$r"; then
    while [[ "$r" == */ || "$r" == *\\ ]]; do r="${r%?}"; done
    rel="${c:${#r}}"; while [[ "$rel" == /* || "$rel" == \\* ]]; do rel="${rel#?}"; done
    if [ -n "$rel" ]; then printf '%s\n' "$rel"; return; fi
  fi
  printf '%s\n' "$c"
}

# --- Self-refresh. Setup writes plugin-source.txt next to the installed script:
#   plugin: <the plugin folder it was copied from>   name: <plugin>   version: <version>
# At start the installed menu looks for a newer copy of that plugin: the recorded folder
# itself (updated in place) and, when the folder is named after its version (a plugin cache
# keeps one folder per version), its sibling version folders. The newest one whose manifest
# names the same plugin and is newer than the recorded version wins.

# record_get <file> <key>: one `key: value` line of a flat file.
record_get() {
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$2: "*) printf '%s\n' "${line#"$2: "}"; return 0 ;; esac
  done < "$1"
  return 1
}

# manifest_field <plugin-root> <name|version>: from .claude-plugin (else .codex-plugin)/plugin.json.
manifest_field() {
  local m text re
  for m in "$1/.claude-plugin/plugin.json" "$1/.codex-plugin/plugin.json"; do
    [ -f "$m" ] || continue
    text="$(< "$m")"
    re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ "$text" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
    [ "$2" = name ] && return 1
  done
  return 1
}

# version_cmp <a> <b>: prints 1, 0 or -1 (1.10.0 > 1.9.9); 0 when either is not a version.
# A suffix after the numbers (-beta, +sha) is ignored.
version_cmp() {
  local re='^[[:space:]]*v?([0-9]+)(\.([0-9]+))?(\.([0-9]+))?' a=() b=() i
  [[ "$1" =~ $re ]] || { echo 0; return; }
  a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}" "${BASH_REMATCH[5]:-0}")
  [[ "$2" =~ $re ]] || { echo 0; return; }
  b=("${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}" "${BASH_REMATCH[5]:-0}")
  for i in 0 1 2; do
    if [ "$((10#${a[$i]}))" -gt "$((10#${b[$i]}))" ]; then echo 1; return; fi
    if [ "$((10#${a[$i]}))" -lt "$((10#${b[$i]}))" ]; then echo -1; return; fi
  done
  echo 0
}

# newer_plugin <root> <name> <version>: prints the newest plugin folder newer than version,
# exit 1 when there is none.
newer_plugin() {
  local root="${1%/}" name="$2" best="" bestv="$3" c v n leaf parent cands=()
  [ -d "$root" ] && cands+=("$root")
  leaf="${root##*/}"; parent="${root%/*}"
  if [[ "$leaf" =~ ^v?[0-9]+\.[0-9]+ ]] && [ -n "$parent" ] && [ "$parent" != "$root" ] && [ -d "$parent" ]; then
    for c in "$parent"/*/; do
      c="${c%/}"
      [ -d "$c" ] && [ "$c" != "$root" ] && [[ "${c##*/}" =~ ^v?[0-9]+\.[0-9]+ ]] && cands+=("$c")
    done
  fi
  for c in ${cands[@]+"${cands[@]}"}; do
    v="$(manifest_field "$c" version)" || continue
    n="$(manifest_field "$c" name)" || n=""
    if [ -n "$name" ] && [ -n "$n" ] && [ "$n" != "$name" ]; then continue; fi
    [ -f "$c/skills/agent-menu/scripts/agent-menu.sh" ] || continue
    if [ "$(version_cmp "$v" "$bestv")" = 1 ]; then best="$c"; bestv="$v"; fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

write_source_record() { # write_source_record <menu-dir> <plugin-root> <name> <version>
  local tmp="$1/plugin-source.txt.tmp.$$"
  {
    echo '# Written by the agent-menu setup: the plugin folder these scripts came from. The menu'
    echo '# refreshes itself from a newer copy of that plugin. Safe to delete.'
    printf 'plugin: %s\nname: %s\nversion: %s\n' "$2" "$3" "$4"
  } > "$tmp" && mv -f "$tmp" "$1/plugin-source.txt"
}

# refresh_menu <menu-dir>: exit 0 when the script there was replaced from a newer plugin
# (the caller then runs the new copy); exit 1 when there is no record, nothing newer, or
# any step fails - the menu then runs as it is, without a message.
refresh_menu() {
  local d="$1" rec root name version newer
  rec="$d/plugin-source.txt"
  [ -f "$rec" ] || return 1
  root="$(record_get "$rec" plugin)" && version="$(record_get "$rec" version)" || return 1
  name="$(record_get "$rec" name)" || name=""
  [ -n "$root" ] && [ -n "$version" ] || return 1
  newer="$(newer_plugin "$root" "$name" "$version")" || return 1
  cp -f "$newer/skills/agent-menu/scripts/agent-menu.sh" "$d/agent-menu.sh.tmp.$$" 2>/dev/null &&
    mv -f "$d/agent-menu.sh.tmp.$$" "$d/agent-menu.sh" || { rm -f "$d/agent-menu.sh.tmp.$$"; return 1; }
  write_source_record "$d" "$newer" "$(manifest_field "$newer" name || true)" "$(manifest_field "$newer" version)" 2>/dev/null || true
  return 0
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
      resume)
        labels+=("Resume")
        if [ -n "$SESSION_KIND" ]; then notes+=("past $AGENT chats from every folder, newest first")
        else notes+=("the $AGENT resume list in ${line#*	}"); fi ;;
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

# project_picker [<chat title>]: sets CHOICE_DIR and CHOICE_MODE (new_project for the pinned
# row), or CHOICE_DIR="" on Esc. With a chat title it only picks a folder to reopen that
# chat in: no Tab toggle and no pinned row.
project_picker() {
  local pick_for="${1:-}" names=() paths=() scopes=() sums=() line rest
  while IFS= read -r line; do
    names+=("${line%%	*}"); rest="${line#*	}"
    paths+=("${rest%%	*}"); rest="${rest#*	}"
    scopes+=("${rest%%	*}"); sums+=("${rest#*	}")
  done <<EOF
$(list_projects "$ROOT")
EOF
  local filter="" mode=new sel=0 offset=0 nrows i r view=() rows head hint more text
  local pin=0 on_pin=0 prows
  [ -n "$pick_for" ] && mode=pick
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
    if [ "$mode" = pick ]; then head=" $AGENT  -  REOPEN in a folder: "; hint="$pick_for"
    elif [ "$mode" = resume ]; then head=" $AGENT  -  RESUME a session"; hint="(Tab: switch to new)"
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
    if [ "$mode" = pick ]; then
      rows+=(" filter: ${filter}_" " type to filter   Up/Down move   Enter reopen the chat here   Esc back to the chats")
    else
      rows+=(" filter: ${filter}_" " type to filter   Up/Down move   Tab new/resume   Enter select   Esc back")
    fi
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
      tab) if [ "$mode" = new ]; then mode=resume; elif [ "$mode" = resume ]; then mode=new; fi ;;
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

# session_picker: the session list (SESSIONS, list_sessions rows). Sets SESSION_IDX (an
# index into SESSIONS) and SESSION_OTHER (1: Tab, pick another folder), or SESSION_IDX=""
# on Esc. Filters on title and folder.
session_picker() {
  local ids=() cwds=() branches=() ages=() titles=() folders=() line rest now
  now="$(date +%s)"
  for line in "${SESSIONS[@]}"; do
    ids+=("${line%%	*}"); rest="${line#*	}"
    cwds+=("${rest%%	*}"); rest="${rest#*	}"
    branches+=("${rest%%	*}"); rest="${rest#*	}"
    ages+=("$(format_age $((now - ${rest%%	*})))"); titles+=("${rest#*	}")
    folders+=("$(session_folder "${cwds[${#cwds[@]} - 1]}" "$ROOT")")
  done
  local filter="" sel=0 offset=0 nrows i r j view=() rows more text
  nrows=$((TTY_H - 8)); [ "$nrows" -gt 15 ] && nrows=15; [ "$nrows" -lt 3 ] && nrows=3
  shopt -s nocasematch
  while :; do
    view=()
    for ((i = 0; i < ${#ids[@]}; i++)); do
      if [ -z "$filter" ] || [[ "${titles[$i]}" == *"$filter"* ]] || [[ "${folders[$i]}" == *"$filter"* ]]; then view+=("$i"); fi
    done
    [ "$sel" -ge "${#view[@]}" ] && sel=$(( ${#view[@]} > 0 ? ${#view[@]} - 1 : 0 ))
    [ "$sel" -lt "$offset" ] && offset=$sel
    [ "$sel" -ge $((offset + nrows)) ] && offset=$((sel - nrows + 1))
    rows=("$(printf '%-44s%s' " $AGENT  -  RESUME a chat from any folder" "(Tab: reopen in another folder)")" "")
    for ((r = 0; r < nrows; r++)); do
      i=$((offset + r))
      if [ "$i" -lt "${#view[@]}" ]; then
        j="${view[$i]}"
        text="$(printf '%-50s %-24s %4s  %s' "${titles[$j]}" "${folders[$j]}" "${ages[$j]}" "${branches[$j]}")"
        if [ "$i" = "$sel" ]; then rows+=(" > $text"); else rows+=("   $text"); fi
      else
        rows+=("")
      fi
    done
    more=$(( ${#view[@]} - offset - nrows ))
    if [ "$more" -gt 0 ]; then rows+=("   ... $more more")
    elif [ "${#view[@]}" -eq 0 ]; then rows+=("   no match")
    else rows+=(""); fi
    rows+=(" filter: ${filter}_" " type to filter   Up/Down move   Enter reopen in its folder   Tab another folder   Esc back")
    draw "${rows[@]}"
    read_key
    case "$KEY" in
      up) [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
      down) [ "$sel" -lt $(( ${#view[@]} - 1 )) ] && sel=$((sel + 1)) ;;
      backspace) [ -n "$filter" ] && { filter="${filter%?}"; sel=0; } ;;
      esc) shopt -u nocasematch; clear_region; SESSION_IDX=""; return ;;
      enter|tab)
        if [ "${#view[@]}" -gt 0 ]; then
          shopt -u nocasematch; clear_region
          SESSION_IDX="${view[$sel]}"; SESSION_OTHER=0; [ "$KEY" = tab ] && SESSION_OTHER=1
          return
        fi ;;
      char:*) filter="$filter${KEY#char:}"; sel=0 ;;
    esac
  done
}

# shell_quote <s>: one single-quoted word for the evaluating shell.
shell_quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }

main() {
  # Self-refresh: an installed copy (plugin-source.txt beside it) that finds a newer plugin
  # replaces itself and runs the new copy with the same arguments.
  local self_dir="."
  case "${BASH_SOURCE[0]}" in */*) self_dir="${BASH_SOURCE[0]%/*}" ;; esac
  if [ -z "${AGENT_MENU_REFRESHED:-}" ] && refresh_menu "$self_dir" 2>/dev/null; then
    AGENT_MENU_REFRESHED=1 exec bash "$self_dir/agent-menu.sh" "$@"
  fi
  case "${1:-}" in
    --print)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: agent-menu.sh --print <agent> <new|resume|resume_all|new_project>" >&2; return 2; }
      agent_command "$2" "$3" || { echo "agent-menu: no '$3' line for '$2' in $(menu_dir)/agents.yaml" >&2; return 1; }
      return 0 ;;
    --list)
      if [ -n "${2:-}" ] && has_new_project "$2"; then printf '%s\t%s\t\t\n' "$NEW_PROJECT_LABEL" "$(projects_root)"; fi
      list_projects "$(projects_root)"; return 0 ;;
    --entries) home_entries; return 0 ;;
    --sessions)
      [ -n "${2:-}" ] || { echo "usage: agent-menu.sh --sessions <agent>" >&2; return 2; }
      cfg_has_block "$2" || return 0
      if [ -n "$(session_list_kind "$2")" ]; then
        list_sessions | while IFS= read -r line; do
          local id="${line%%	*}" rest="${line#*	}" cwd branch
          cwd="${rest%%	*}"; rest="${rest#*	}"; branch="${rest%%	*}"; rest="${rest#*	}"
          printf '%s\t%s\t%s\t%s\n' "$id" "$cwd" "$branch" "${rest#*	}"
        done
      fi
      return 0 ;;
    ''|-*) echo "usage: agent-menu.sh <agent> | --print <agent> <mode> | --list [<agent>] | --entries | --sessions <agent>" >&2; return 2 ;;
  esac
  AGENT="$1"; CONFIG="$(menu_dir)/agents.yaml"
  if [ ! -f "$CONFIG" ]; then echo "agent-menu: no config at $CONFIG - run the agent-menu setup" >&2; return 1; fi
  if ! cfg_has_block "$AGENT"; then echo "agent-menu: $CONFIG has no '$AGENT' block" >&2; return 1; fi
  ROOT="$(projects_root)"
  HAS_NP=0; has_new_project "$AGENT" && HAS_NP=1
  SESSION_KIND="$(session_list_kind "$AGENT")"; SESSIONS=(); local loaded=0
  # Keys come from fd 4 and drawing goes to fd 3, both the terminal; the two
  # AGENT_MENU_TTY_* variables swap in files so tests can script a session.
  exec 3>"${AGENT_MENU_TTY_OUT:-/dev/tty}" 4<"${AGENT_MENU_TTY_IN:-/dev/tty}" || { echo "agent-menu: no terminal" >&2; return 1; }
  tty_size
  printf '\033[?25l' >&3
  trap 'printf "\033[?25h" >&3' EXIT
  trap 'clear_region; exit 130' INT
  local dir="" mode="" sid="" s
  while :; do
    home_menu
    case "$PICK" in
      '') return 0 ;;
      root) dir="$ROOT"; mode=new; break ;;
      home) dir="$HOME"; mode=new; break ;;
      resume)
        if [ -n "$SESSION_KIND" ]; then
          if [ "$loaded" = 0 ]; then
            while IFS= read -r s; do [ -n "$s" ] && SESSIONS+=("$s"); done <<EOF
$(list_sessions)
EOF
            loaded=1
          fi
          if [ "${#SESSIONS[@]}" -gt 0 ]; then
            while :; do
              session_picker
              [ -n "$SESSION_IDX" ] || break
              s="${SESSIONS[$SESSION_IDX]}"
              if [ "$SESSION_OTHER" = 0 ]; then sid="${s%%	*}"; s="${s#*	}"; dir="${s%%	*}"; break; fi
              [ -n "$ROOT" ] && [ -d "$ROOT" ] || continue
              project_picker "${s##*	}"
              if [ -n "$CHOICE_DIR" ]; then sid="${s%%	*}"; dir="$CHOICE_DIR"; break; fi
            done
            [ -n "$sid" ] || continue
            mode=resume; break
          fi
        fi
        dir="$(home_entries | sed -n 's/^resume	//p')"; mode=resume_all; break ;;
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
  [ -z "$sid" ] || line="$line $sid"
  printf '%s> %s\n' "$dir" "$line" >&3
  printf 'cd -- %s && %s\n' "$(shell_quote "$dir")" "$line"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
