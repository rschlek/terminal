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

if [ "$failures" -gt 0 ]; then echo "$failures FAILURE(S)"; exit 1; fi
echo "All $total cases passed."
