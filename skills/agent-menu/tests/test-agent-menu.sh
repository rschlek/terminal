#!/usr/bin/env bash
# Tests for agent-menu.sh and setup.sh (macOS, Linux; also runs under Git Bash on
# Windows): the agents.yaml reader ({args} substitution, quoted values verbatim), the
# project listing (project.yaml fields, sort order, recent.tsv), scripted menu sessions
# (keys from a file through AGENT_MENU_TTY_IN), and the setup script.
#
# Everything runs in a temp folder: AGENT_MENU_DIR, WARP_TAB_CONFIGS_DIR and HOME point
# into it, so no real config, tab config or Warp tab is touched.
#   bash test-agent-menu.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../scripts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" AGENT_MENU_DIR="$work/menu" WARP_TAB_CONFIGS_DIR="$work/tab_configs"
unset CLAUDE_CONFIG_DIR AGENT_MENU_TEMP_DIR AGENT_MENU_REFRESHED
mkdir -p "$HOME" "$AGENT_MENU_DIR" "$WARP_TAB_CONFIGS_DIR"
# shellcheck source=../scripts/agent-menu.sh
. "$scripts/agent-menu.sh"

total=0; failures=0
check() { # check <name> <expected> <actual>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then echo "PASS  $1"
  else failures=$((failures + 1)); echo "FAIL  $1"; echo "      expected: <$2>"; echo "      got:      <$3>"; fi
}

# --- 1. The config reader.
root="$work/projects"
quoted="--fixture-flag --model fixture-model --config 'model_reasoning_effort=\"high\"'"
{
  echo "# a comment"
  echo "projects_root: \"$root\""
  echo
  echo "claude:"; echo "  args: --fixture-flag"; echo "  new: claude {args}"; echo "  resume: claude {args} --resume"
  echo
  echo "codex:"; echo "  args: $quoted"; echo "  new: codex {args}"; echo "  resume: codex resume {args}"
  echo "  resume_all: codex resume --all {args}"
  echo
  printf 'bare:\r\n    # an indented comment\r\n  args:\r\n  resume: bare {args} --resume\r\n  note: keeps # this and '"'"'quotes'"'"'   \r\n'
  echo
  echo "np:"; echo "  args: --fixture-flag"; echo "  resume: np {args} --resume"
  echo '  new_project: np {args} "Create a new project in this folder."'
  echo "npbare:"; echo "  args:"; echo '  new_project: npbare {args} "Create a new project."'
} > "$AGENT_MENU_DIR/agents.yaml"
check config-projects-root-unquoted "$root" "$(projects_root)"
check config-codex-new-verbatim "codex $quoted" "$(agent_command codex new)"
check config-codex-resume "codex resume $quoted" "$(agent_command codex resume)"
check config-codex-resume-all "codex resume --all $quoted" "$(agent_command codex resume_all)"
check config-claude-resume "claude --fixture-flag --resume" "$(agent_command claude resume)"
check config-resume-all-falls-back "claude --fixture-flag --resume" "$(agent_command claude resume_all)"
check config-empty-args-dropped "bare --resume" "$(agent_command bare resume)"
check config-missing-new-defaults "bare" "$(agent_command bare new)"
check config-missing-block "1" "$(agent_command nope new >/dev/null 2>&1; echo $?)"
check config-hash-and-quotes-kept "keeps # this and 'quotes'" "$(cfg_get bare note)"
check menu-print-mode "codex resume $quoted" "$(bash "$scripts/agent-menu.sh" --print codex resume)"
check config-new-project 'np --fixture-flag "Create a new project in this folder."' "$(agent_command np new_project)"
check config-new-project-empty-args 'npbare "Create a new project."' "$(agent_command npbare new_project)"
check config-new-project-absent "1" "$(agent_command claude new_project >/dev/null 2>&1; echo $?)"
check menu-print-new-project 'np --fixture-flag "Create a new project in this folder."' "$(bash "$scripts/agent-menu.sh" --print np new_project)"
check menu-print-new-project-absent "1|agent-menu: no 'new_project' line for 'claude' in $AGENT_MENU_DIR/agents.yaml" "$(e="$(bash "$scripts/agent-menu.sh" --print claude new_project 2>&1 >/dev/null)"; echo "$?|$e")"

# --- 2. project.yaml fields.
y="$work/p.yaml"
{
  echo 'project: demo'; echo 'scope: personal   # trailing comment'; echo 'summary: >'
  echo '  A folded summary'; echo '  over two lines.'; echo 'title: "Quoted # not a comment"'
  echo "other: 'it''s single'"; echo 'links:'; echo '  repo: x'
} > "$y"
check yaml-comment-stripped "personal" "$(yaml_field "$y" scope)"
check yaml-folded-joined "A folded summary over two lines." "$(yaml_field "$y" summary)"
check yaml-double-quoted "Quoted # not a comment" "$(yaml_field "$y" title)"
check yaml-single-quoted "it's single" "$(yaml_field "$y" other)"
check yaml-absent "" "$(yaml_field "$y" missing)"

# --- 3. Listing and sort order.
for n in alpha Beta gamma .hidden delta; do mkdir -p "$root/$n"; done
echo x > "$root/loose-file.txt"
printf 'project: gamma\nscope: work # c\nsummary: "The gamma project"\n' > "$root/gamma/project.yaml"
printf 'project: alpha\nsummary: >-\n  Folded\n  alpha.\n' > "$root/alpha/project.yaml"
names() { list_projects "$root" | while IFS= read -r l; do printf '%s,' "${l%%	*}"; done; }
check list-alphabetical-when-no-recent "alpha,Beta,delta,gamma," "$(names)"
check list-reads-project-yaml "gamma	$root/gamma	work	The gamma project" "$(list_projects "$root" | grep '^gamma')"
check list-folded-summary "alpha	$root/alpha		Folded alpha." "$(list_projects "$root" | grep '^alpha')"
save_recent "$root/gamma"; save_recent "$root/delta"; save_recent "$work/not-under-root"; save_recent "$root/gamma"
check list-recent-first-then-alpha "gamma,delta,alpha,Beta," "$(names)"
check recent-file-deduped "3" "$(wc -l < "$(recent_file)" | tr -d ' ')"
check recent-file-newest-first "$root/gamma" "$(head -1 "$(recent_file)" | cut -f2)"
check list-missing-root "" "$(list_projects "$work/nope")"
check menu-list-mode "gamma" "$(bash "$scripts/agent-menu.sh" --list | head -1 | cut -f1)"
check menu-list-pinned-row "+ new project	$root		|5" "$(bash "$scripts/agent-menu.sh" --list np | head -1)|$(bash "$scripts/agent-menu.sh" --list np | wc -l | tr -d ' ')"
check menu-list-key-absent-unchanged "$(bash "$scripts/agent-menu.sh" --list)" "$(bash "$scripts/agent-menu.sh" --list claude)"

# --- 4. Scripted sessions: keys from a file, the drawing to another, stdout = the eval line.
UP=$'\033[A'; DOWN=$'\033[B'; ENTER=$'\n'; TAB=$'\t'; ESC=$'\033'
session() { # session <agent> <keys>
  printf '%s' "$2" > "$work/keys"
  AGENT_MENU_TTY_IN="$work/keys" AGENT_MENU_TTY_OUT="$work/screen" bash "$scripts/agent-menu.sh" "$1"
}
check session-home "cd -- '$HOME' && claude --fixture-flag" "$(session claude "$ENTER")"
check session-resume-all "cd -- '$HOME' && codex resume --all $quoted" "$(session codex "$DOWN$DOWN$ENTER")"
check session-escape "" "$(session claude "$ESC")"
check session-project-filter "cd -- '$root/alpha' && codex $quoted" "$(session codex "${DOWN}${ENTER}alp${ENTER}")"
check session-recorded "$root/alpha" "$(head -1 "$(recent_file)" | cut -f2)"
check session-project-resume "cd -- '$root/alpha' && claude --fixture-flag --resume" "$(session claude "${DOWN}${ENTER}${TAB}${ENTER}")"
# The recent order is now alpha, gamma, delta, then Beta: down three, up one = delta.
check session-project-move "cd -- '$root/delta' && claude --fixture-flag" "$(session claude "${DOWN}${ENTER}${DOWN}${DOWN}${DOWN}${UP}${ENTER}")"
check session-screen-drawn "yes" "$(grep -q 'NEW session' "$work/screen" && echo yes || echo no)"
# The eval line works: run it in a subshell with a stub agent on PATH.
mkdir -p "$work/bin"; printf '#!/usr/bin/env bash\npwd > "%s"\nprintf "%%s\\n" "$@" >> "%s"\n' "$work/ran" "$work/ran" > "$work/bin/codex"
chmod +x "$work/bin/codex"
line="$(session codex "${DOWN}${ENTER}gam${ENTER}")"
( PATH="$work/bin:$PATH"; eval "$line" )
check session-eval-runs-in-folder "$(cd "$root/gamma" && pwd)|--fixture-flag|--model|fixture-model|--config|model_reasoning_effort=\"high\"" "$(paste -sd'|' "$work/ran")"

# The pinned `+ new project` row (np has a new_project line; claude does not).
first="$(list_projects "$root" | head -1 | cut -f2)"
recent_before="$(cat "$(recent_file)")"
check session-new-project "cd -- '$root' && np --fixture-flag \"Create a new project in this folder.\"" "$(session np "${DOWN}${ENTER}${UP}${ENTER}")"
check session-new-project-screen "yes" "$(grep -qF '> + new project' "$work/screen" && echo yes || echo no)"
check session-new-project-not-recorded "$recent_before" "$(cat "$(recent_file)")"
check session-new-project-default-first "cd -- '$first' && np --fixture-flag" "$(session np "${DOWN}${ENTER}${ENTER}")"
check session-new-project-survives-filter "cd -- '$root' && np --fixture-flag \"Create a new project in this folder.\"" "$(session np "${DOWN}${ENTER}zzz${ENTER}")"
check session-new-project-hidden-in-resume "cd -- '$first' && np --fixture-flag --resume" "$(session np "${DOWN}${ENTER}${TAB}${UP}${ENTER}")"
session claude "${DOWN}${ENTER}${ESC}${ESC}" > /dev/null
check session-no-row-without-key "no" "$(grep -qF '+ new project' "$work/screen" && echo yes || echo no)"
# An empty projects root: the view still opens, with the pinned row selected.
mkdir -p "$work/empty-root" "$work/menu-empty"
printf 'projects_root: %s\nnp:\n  new_project: np {args} new\n' "$work/empty-root" > "$work/menu-empty/agents.yaml"
# start_in: projects_root adds a first, preselected Projects root entry, then Project... and
# Resume, with Home last; Resume opens in the projects root instead of the home folder.
check entries-default "home,project,resume" "$(bash "$scripts/agent-menu.sh" --entries | cut -f1 | paste -sd,)"
check entries-default-resume-home "resume	$HOME" "$(bash "$scripts/agent-menu.sh" --entries | grep '^resume')"
cp "$AGENT_MENU_DIR/agents.yaml" "$work/agents.base"
{ echo "start_in: projects_root"; cat "$work/agents.base"; } > "$AGENT_MENU_DIR/agents.yaml"
check entries-start-in-root "root	$root|project	$root|resume	$root|home	$HOME" "$(bash "$scripts/agent-menu.sh" --entries | paste -sd'|')"
check session-root-default "cd -- '$root' && claude --fixture-flag" "$(session claude "$ENTER")"
check session-root-screen "yes" "$(grep -qF '> Projects root' "$work/screen" && echo yes || echo no)"
check session-root-project "cd -- '$root/gamma' && codex $quoted" "$(session codex "${DOWN}${ENTER}gam${ENTER}")"
check session-root-resume "cd -- '$root' && codex resume --all $quoted" "$(session codex "$DOWN$DOWN$ENTER")"
check session-root-home "cd -- '$HOME' && claude --fixture-flag" "$(session claude "$DOWN$DOWN$DOWN$ENTER")"
{ echo "start_in: projects_root"; echo "projects_root: $work/nope"; grep -v '^projects_root:' "$work/agents.base"; } > "$AGENT_MENU_DIR/agents.yaml"
check entries-start-in-missing-root "home,project,resume|resume	$HOME" "$(bash "$scripts/agent-menu.sh" --entries | cut -f1 | paste -sd,)|$(bash "$scripts/agent-menu.sh" --entries | grep '^resume')"
cp "$work/agents.base" "$AGENT_MENU_DIR/agents.yaml"
check session-new-project-empty-root "cd -- '$work/empty-root' && np new" "$(AGENT_MENU_DIR="$work/menu-empty" session np "${DOWN}${ENTER}${ENTER}")"

# --- 4b. The session list: fake Claude Code session files in a temp config dir. The temp
# folder check is pointed at a fixture folder, since the whole test lives in a temp dir.
export CLAUDE_CONFIG_DIR="$work/claude" AGENT_MENU_TEMP_DIR="$work/fake-temp"
P="$CLAUDE_CONFIG_DIR/projects"
mkdir -p "$work/fake-temp/x"
jesc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
sess() { # sess <folder> <id> <touch-stamp> <line>...: one session file, newline after each line
  local d="$P/$1" id="$2" t="$3"; shift 3
  mkdir -p "$d"; printf '%s\n' "$@" > "$d/$id.jsonl"; touch -t "$t" "$d/$id.jsonl"
}
uline() { # uline <cwd> <content-json> [branch]: a user line carrying the folder
  printf '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":%s},"uuid":"u1","cwd":"%s","sessionId":"x","version":"2.1.290","gitBranch":"%s"}' "$2" "$(jesc "$1")" "${3:-}"
}
mline() { printf '{"type":"mode","mode":"normal","sessionId":"x"}'; }
aline() { printf '{"parentUuid":"u1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"cwd":"%s","sessionId":"x"}' "$(jesc "$1")"; }
long="01234567890123456789012345678901234567890123456789012345678901234567890123456789"
sess f-alpha s-ai 202601010900 "$(mline)" "$(uline "$root/alpha" '"first prompt"' feature/x)" "$(aline "$root/alpha")" \
  '{"type":"ai-title","aiTitle":"Old title","sessionId":"x"}' '{"type":"last-prompt","lastPrompt":"later prompt","sessionId":"x"}' \
  '{"type":"ai-title","aiTitle":"Second title","sessionId":"x"}' '{"type":"ai-title","aiTitle":"Second title","sessionId":"x"}'
sess f-gamma s-noai 202601010800 "$(mline)" "$(uline "$root/gamma" '"first gamma prompt"' HEAD)" \
  '{"type":"last-prompt","lastPrompt":"an earlier prompt","sessionId":"x"}' '{"type":"last-prompt","lastPrompt":"the last prompt","sessionId":"x"}'
sess f-root s-array 202601010700 '{"type":"queue-operation","operation":"enqueue","sessionId":"x"}' \
  "$(uline "$root" '[{"type":"text","text":"array text  with\nnewline"},{"type":"text","text":"second block"}]')"
sess f-delta s-multi 202601010600 "$(mline)" "$(uline "$root/delta" '"multi first"')" "$(aline "$root/delta")" "$(uline "$root/alpha" '"resumed elsewhere"')" "$(aline "$root/alpha")"
sess f-beta s-partial 202601010500 "$(uline "$root/Beta" '"partial"')" '{"type":"ai-title","aiTitle":"Complete title","sessionId":"x"}'
printf '%s' '{"type":"ai-title","aiTitle":"cut of' >> "$P/f-beta/s-partial.jsonl"; touch -t 202601010500 "$P/f-beta/s-partial.jsonl"
sess f-alpha s-long 202601010400 "$(uline "$root/alpha" '"long"')" "{\"type\":\"ai-title\",\"aiTitle\":\"$long\",\"sessionId\":\"x\"}"
sess f-alpha s-escape 202601010300 "$(uline "$root/alpha" '"esc"')" '{"type":"ai-title","aiTitle":"say \"hi\" \\ tab\u0009end","sessionId":"x"}'
sess f-temp s-temp 202601011000 "$(uline "$work/fake-temp/x" '"in temp"')"
sess f-alpha s-nouser 202601010950 "$(mline)" "{\"type\":\"attachment\",\"cwd\":\"$(jesc "$root/alpha")\",\"sessionId\":\"x\"}" '{"type":"ai-title","aiTitle":"No user","sessionId":"x"}'
sess f-gone s-gone 202601010850 "$(uline "$work/deleted-folder" '"gone"')"
mkdir -p "$P/f-alpha/s-ai/subagents"
printf '%s\n' "$(uline "$root/alpha" '"subagent"')" > "$P/f-alpha/s-ai/subagents/agent-1.jsonl"; touch -t 202601011100 "$P/f-alpha/s-ai/subagents/agent-1.jsonl"
echo "not a session" > "$P/f-alpha/notes.txt"
expected="s-ai	$root/alpha	feature/x	Second title
s-noai	$root/gamma		the last prompt
s-array	$root		array text with newline
s-multi	$root/delta		multi first
s-partial	$root/Beta		Complete title
s-long	$root/alpha		${long:0:57}...
s-escape	$root/alpha		say \"hi\" \\ tab end"
got="$(bash "$scripts/agent-menu.sh" --sessions claude)"
check sessions-list "$expected" "$got"
check sessions-ids "s-ai,s-noai,s-array,s-multi,s-partial,s-long,s-escape" "$(printf '%s\n' "$got" | cut -f1 | paste -sd,)"
check sessions-cap "2" "$(list_sessions 2 | wc -l | tr -d ' ')"
check sessions-off-for-codex "" "$(bash "$scripts/agent-menu.sh" --sessions codex)"
check sessions-folder-relative "alpha|$root|$work/elsewhere" "$(session_folder "$root/alpha" "$root")|$(session_folder "$root" "$root")|$(session_folder "$work/elsewhere" "$root")"
check sessions-age "now|5m|3h|2d|3w" "$(format_age 30)|$(format_age 300)|$(format_age 10800)|$(format_age 172800)|$(format_age 1900000)"
check sessions-unescape 'a "q" \ b c?ZZd' "$(json_unescape 'a \"q\" \\ b\nc\uZZd')"
check session-resume-original "cd -- '$root/alpha' && claude --fixture-flag --resume s-ai" "$(session claude "$DOWN$DOWN$ENTER$ENTER")"
check session-resume-screen "yes" "$(grep -q 'RESUME a chat from any folder' "$work/screen" && echo yes || echo no)"
check session-resume-filter "cd -- '$root/gamma' && claude --fixture-flag --resume s-noai" "$(session claude "$DOWN$DOWN${ENTER}last$ENTER")"
check session-resume-root "cd -- '$root' && claude --fixture-flag --resume s-array" "$(session claude "$DOWN$DOWN${ENTER}array$ENTER")"
check session-resume-move "cd -- '$root/delta' && claude --fixture-flag --resume s-multi" "$(session claude "$DOWN$DOWN$ENTER$DOWN$DOWN$DOWN$UP$DOWN$ENTER")"
check session-resume-other-folder "cd -- '$root/gamma' && claude --fixture-flag --resume s-ai" "$(session claude "$DOWN$DOWN$ENTER${TAB}gam$ENTER")"
check session-resume-other-screen "yes" "$(grep -q 'REOPEN in a folder' "$work/screen" && echo yes || echo no)"
check session-resume-escape "" "$(session claude "$DOWN$DOWN$ENTER$TAB")"
recent_before="$(cat "$(recent_file)")"
session claude "$DOWN$DOWN$ENTER${TAB}gam$ENTER" > /dev/null
check session-resume-not-recorded "$recent_before" "$(cat "$(recent_file)")"
# Opting in another block, opting out the claude block, and an empty store.
awk '{ print } $0 == "codex:" { print "  session_list: claude" } $0 == "claude:" { print "  session_list: off" }' "$work/agents.base" > "$AGENT_MENU_DIR/agents.yaml"
check session-list-opt-in "cd -- '$root/alpha' && codex resume $quoted s-ai" "$(session codex "$DOWN$DOWN$ENTER$ENTER")"
check session-list-opt-out "cd -- '$HOME' && claude --fixture-flag --resume" "$(session claude "$DOWN$DOWN$ENTER")"
cp "$work/agents.base" "$AGENT_MENU_DIR/agents.yaml"
mkdir -p "$work/claude-empty/projects"
check session-list-empty-falls-back "cd -- '$HOME' && claude --fixture-flag --resume" "$(CLAUDE_CONFIG_DIR="$work/claude-empty" session claude "$DOWN$DOWN$ENTER")"
check session-list-missing-store-falls-back "cd -- '$HOME' && claude --fixture-flag --resume" "$(CLAUDE_CONFIG_DIR="$work/no-claude" session claude "$DOWN$DOWN$ENTER")"
unset CLAUDE_CONFIG_DIR AGENT_MENU_TEMP_DIR

# --- 5. Setup, against temp folders only.
export AGENT_MENU_DIR="$work/menu2"
tabs="$WARP_TAB_CONFIGS_DIR"
standing() { # standing <name> <command>
  local enc="${2//\\/\\\\}"; enc="${enc//\"/\\\"}"
  printf 'name = "%s"\n\n[[panes]]\nid = "main"\ntype = "terminal"\ncommands = ["%s"]\n' "$1" "$enc" > "$tabs/$1.toml"
}
standing claude "claude --fixture-flag"
standing codex "codex $quoted"
standing claude-resume "claude --fixture-flag --resume"
before="$(cat "$tabs/claude.toml")"
msg="$(bash "$scripts/setup.sh" --check)"
check setup-check-changes-nothing "no|no|same" "$([ -f "$AGENT_MENU_DIR/agents.yaml" ] && echo yes || echo no)|$([ -f "$AGENT_MENU_DIR/agent-menu.sh" ] && echo yes || echo no)|$([ "$(cat "$tabs/claude.toml")" = "$before" ] && echo same || echo changed)"
check setup-check-reports-flags "yes" "$(printf '%s' "$msg" | grep -qF "launches 'codex' with flags: $quoted" && printf '%s' "$msg" | grep -q 'claude-resume.toml is redundant' && echo yes || echo no)"
msg="$(bash "$scripts/setup.sh" --carry-args --projects-root "$work/fixture root")"
check setup-created-config "$work/fixture root" "$(projects_root)"
check setup-template-starts-home "home|home,project,resume" "$(cfg_get "" start_in)|$(home_entries | cut -f1 | paste -sd,)"
check setup-carried-args "codex resume $quoted" "$(agent_command codex resume)"
check setup-installed-script "yes" "$([ -f "$AGENT_MENU_DIR/agent-menu.sh" ] && echo yes || echo no)"
check setup-tab-command "commands = [\"eval \\\"\$(bash '$AGENT_MENU_DIR/agent-menu.sh' codex)\\\"\"]" "$(grep '^commands' "$tabs/codex.toml")"
check setup-kept-resume-file "yes" "$([ -f "$tabs/claude-resume.toml" ] && echo yes || echo no)"
check setup-backed-up-old-tab "$before" "$(cat "$AGENT_MENU_DIR"/backup/claude.*.toml)"
echo "# user edit" >> "$AGENT_MENU_DIR/agents.yaml"
edited="$(cat "$AGENT_MENU_DIR/agents.yaml")"
msg="$(bash "$scripts/setup.sh")"
check setup-rerun-keeps-config "$edited" "$(cat "$AGENT_MENU_DIR/agents.yaml")"
check setup-rerun-tab-current "yes" "$(printf '%s' "$msg" | grep -q 'claude.toml is current' && echo yes || echo no)"

# Explicit --agent-args wins over --carry-args for its agent, and may be empty.
export AGENT_MENU_DIR="$work/menu3"
standing claude "claude --fixture-flag"
standing codex "codex $quoted"
bash "$scripts/setup.sh" --carry-args --agent-args 'claude=--explicit-flag' --agent-args 'codex=' > /dev/null
check setup-explicit-args "claude --explicit-flag --resume|codex" "$(agent_command claude resume)|$(agent_command codex new)"
msg="$(bash "$scripts/setup.sh" --agent-args 'claude=--other')"
check setup-explicit-args-existing-config "yes|claude --explicit-flag" "$(printf '%s' "$msg" | grep -q 'not applied' && echo yes || echo no)|$(agent_command claude new)"

# --- 6. Self-refresh: a fake plugin cache with one folder per version.
check version-cmp "1|0|0|1|0|0|-1|1" "$(version_cmp 1.10.0 1.9.9)|$(version_cmp 1.4.0 1.4.0)|$(version_cmp 1.4 1.4.0)|$(version_cmp v2.0.0 1.99.99)|$(version_cmp 1.4.0-beta 1.4.0)|$(version_cmp garbage 1.4.0)|$(version_cmp 1.3.1 1.4.0)|$(version_cmp 1.4.1 1.4.0)"
fake_plugin() { # fake_plugin <folder> <version> [marker]: a copy of this plugin's agent-menu at that version
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/.claude-plugin" "$d/skills/agent-menu"
  printf '{\n  "name": "terminal",\n  "version": "%s"\n}\n' "$2" > "$d/.claude-plugin/plugin.json"
  cp -R "$scripts" "$d/skills/agent-menu/scripts"; cp -R "$here/../templates" "$d/skills/agent-menu/templates"
  [ -z "${3:-}" ] || printf '# %s\n' "$3" >> "$d/skills/agent-menu/scripts/agent-menu.sh"
}
export AGENT_MENU_DIR="$work/menu4"
cache="$work/cache/terminal"
fake_plugin "$cache/1.4.0" 1.4.0
bash "$cache/1.4.0/skills/agent-menu/scripts/setup.sh" --projects-root "$root" > /dev/null
rec="$AGENT_MENU_DIR/plugin-source.txt"
check refresh-record-written "$cache/1.4.0|terminal|1.4.0" "$(record_get "$rec" plugin)|$(record_get "$rec" name)|$(record_get "$rec" version)"
installed="$AGENT_MENU_DIR/agent-menu.sh"
check refresh-same-version-untouched "home,project,resume|no" "$(bash "$installed" --entries | cut -f1 | paste -sd,)|$(grep -q 'marker-1.5.0' "$installed" && echo yes || echo no)"
cfg_before="$(cat "$AGENT_MENU_DIR/agents.yaml")"
fake_plugin "$cache/1.5.0" 1.5.0 marker-1.5.0
fake_plugin "$cache/1.3.1" 1.3.1 marker-1.3.1
out="$(bash "$installed" --entries 2>"$work/refresh-err")"
check refresh-newer-sibling "home,project,resume|yes|$cache/1.5.0|1.5.0" "$(printf '%s\n' "$out" | cut -f1 | paste -sd,)|$(grep -q 'marker-1.5.0' "$installed" && echo yes || echo no)|$(record_get "$rec" plugin)|$(record_get "$rec" version)"
check refresh-keeps-config "$cfg_before" "$(cat "$AGENT_MENU_DIR/agents.yaml")"
check refresh-quiet "" "$(cat "$work/refresh-err")"
check refresh-not-again "1" "$(bash "$installed" --entries > /dev/null; grep -c 'marker-1.5.0' "$installed")"
# A record that is not a version, or a plugin that is gone: the menu runs as it is, silently.
write_source_record "$AGENT_MENU_DIR" "$cache/1.5.0" terminal garbage
fake_plugin "$cache/1.6.0" 1.6.0 marker-1.6.0
check refresh-garbage-version "no" "$(bash "$installed" --entries > /dev/null; grep -q 'marker-1.6.0' "$installed" && echo yes || echo no)"
rm -rf "$work/cache"
write_source_record "$AGENT_MENU_DIR" "$cache/1.5.0" terminal 1.5.0
check refresh-source-gone "home,project,resume|" "$(bash "$installed" --entries 2>"$work/refresh-err" | cut -f1 | paste -sd,)|$(cat "$work/refresh-err")"
# A plugin folder updated in place (not named after its version): the manifest is compared.
fake_plugin "$work/checkout" 1.5.0
write_source_record "$AGENT_MENU_DIR" "$work/checkout" terminal 1.5.0
check refresh-in-place-same "no" "$(bash "$installed" --entries > /dev/null; grep -q 'marker-in-place' "$installed" && echo yes || echo no)"
fake_plugin "$work/checkout" 1.5.1 marker-in-place
check refresh-in-place-newer "yes|1.5.1" "$(bash "$installed" --entries > /dev/null; grep -q 'marker-in-place' "$installed" && echo yes || echo no)|$(record_get "$rec" version)"
# Another plugin's manifest in a sibling folder is never taken.
mkdir -p "$work/cache2/x"; fake_plugin "$work/cache2/x/2.0.0" 2.0.0 marker-other
sed -i.bak 's/"terminal"/"other"/' "$work/cache2/x/2.0.0/.claude-plugin/plugin.json"
fake_plugin "$work/cache2/x/1.0.0" 1.0.0
write_source_record "$AGENT_MENU_DIR" "$work/cache2/x/1.0.0" terminal 1.0.0
check refresh-other-plugin-ignored "no" "$(bash "$installed" --entries > /dev/null; grep -q 'marker-other' "$installed" && echo yes || echo no)"

if [ "$failures" -gt 0 ]; then echo "$failures FAILURE(S)"; exit 1; fi
echo "All $total cases passed."
