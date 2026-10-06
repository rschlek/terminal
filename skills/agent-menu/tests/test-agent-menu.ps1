<#
.SYNOPSIS
  Tests for the agent menu's non-interactive parts on Windows: the agents.yaml
  reader ({args} substitution, quoted values verbatim), the project listing
  (project.yaml fields, sort order, the recent-projects file), the menu's -Print
  and -List modes, and the setup script against temp folders.

.DESCRIPTION
  Everything runs against a temp folder: AGENT_MENU_DIR and WARP_TAB_CONFIGS_DIR
  point into it, so no real config, tab config or Warp tab is touched. The key
  loop itself is not exercised (it needs a console). Run under Windows
  PowerShell 5.1: powershell -NoProfile -File test-agent-menu.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP ("agent-menu-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8)))
)
$ErrorActionPreference = "Stop"
$scripts = Join-Path $PSScriptRoot "..\scripts"
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$saved = @{ AGENT_MENU_DIR = $env:AGENT_MENU_DIR; WARP_TAB_CONFIGS_DIR = $env:WARP_TAB_CONFIGS_DIR; CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR; AGENT_MENU_TEMP_DIR = $env:AGENT_MENU_TEMP_DIR; AGENT_MENU_REFRESHED = $env:AGENT_MENU_REFRESHED }
Remove-Item Env:\AGENT_MENU_REFRESHED -ErrorAction SilentlyContinue
# Never read the user's real session store: point Claude Code's config dir into the temp folder.
$env:CLAUDE_CONFIG_DIR = Join-Path $WorkDir "claude-none"
$env:AGENT_MENU_DIR = Join-Path $WorkDir "menu"
$env:WARP_TAB_CONFIGS_DIR = Join-Path $WorkDir "tab_configs"
New-Item -ItemType Directory -Force -Path $env:AGENT_MENU_DIR, $env:WARP_TAB_CONFIGS_DIR | Out-Null
. (Join-Path $scripts "agent-config.ps1")

$failures = 0
$total = 0
function Report([string]$name, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { Write-Output ("PASS  {0}" -f $name) }
    else { $script:failures++; Write-Output ("FAIL  {0}" -f $name); if ($detail) { Write-Output ("      {0}" -f $detail) } }
}
function Write-Text([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $utf8) }

# --- 1. The config reader.
$root = Join-Path $WorkDir "projects"
$quoted = "--fixture-flag --model fixture-model --config 'model_reasoning_effort=`"high`"'"
$configPath = Join-Path $env:AGENT_MENU_DIR "agents.yaml"
Write-Text $configPath (@(
    "# a comment", "projects_root: `"$root`"", "",
    "claude:", "  args: --fixture-flag", "  new: claude {args}", "  resume: claude {args} --resume", "",
    "codex:", "  args: $quoted", "  new: codex {args}", "  resume: codex resume {args}", "  resume_all: codex resume --all {args}", "",
    "bare:", "    # an indented comment", "  args:", "  resume: bare {args} --resume", "  note: keeps # this and 'quotes'   ", "",
    "np:", "  args: --fixture-flag", "  new_project: np {args} `"Create a new project in this folder.`"",
    "npbare:", "  args:", "  new_project: npbare {args} `"Create a new project.`""
) -join "`r`n")
$c = Read-AgentConfig $configPath
Report "config-projects-root-unquoted" ((Get-ProjectsRoot $c) -ceq $root) (Get-ProjectsRoot $c)
Report "config-codex-new-verbatim" ((Get-AgentCommand $c 'codex' 'new') -ceq "codex $quoted") (Get-AgentCommand $c 'codex' 'new')
Report "config-codex-resume" ((Get-AgentCommand $c 'codex' 'resume') -ceq "codex resume $quoted") (Get-AgentCommand $c 'codex' 'resume')
Report "config-codex-resume-all" ((Get-AgentCommand $c 'codex' 'resume_all') -ceq "codex resume --all $quoted") (Get-AgentCommand $c 'codex' 'resume_all')
Report "config-claude-resume" ((Get-AgentCommand $c 'claude' 'resume') -ceq "claude --fixture-flag --resume") (Get-AgentCommand $c 'claude' 'resume')
Report "config-resume-all-falls-back" ((Get-AgentCommand $c 'claude' 'resume_all') -ceq "claude --fixture-flag --resume") (Get-AgentCommand $c 'claude' 'resume_all')
Report "config-empty-args-dropped" ((Get-AgentCommand $c 'bare' 'resume') -ceq "bare --resume") (Get-AgentCommand $c 'bare' 'resume')
Report "config-missing-new-defaults" ((Get-AgentCommand $c 'bare' 'new') -ceq "bare") (Get-AgentCommand $c 'bare' 'new')
Report "config-missing-block" ($null -eq (Get-AgentCommand $c 'nope' 'new')) ""
Report "config-hash-and-quotes-kept" ($c.Blocks['bare']['note'] -ceq "keeps # this and 'quotes'") $c.Blocks['bare']['note']
Report "config-new-project" ((Get-AgentCommand $c 'np' 'new_project') -ceq 'np --fixture-flag "Create a new project in this folder."') (Get-AgentCommand $c 'np' 'new_project')
Report "config-new-project-empty-args" ((Get-AgentCommand $c 'npbare' 'new_project') -ceq 'npbare "Create a new project."') (Get-AgentCommand $c 'npbare' 'new_project')
Report "config-new-project-absent" ($null -eq (Get-AgentCommand $c 'claude' 'new_project')) ""
$c2 = @{ Top = @{ projects_root = '~\src' }; Blocks = @{} }
Report "config-tilde-expands" ((Get-ProjectsRoot $c2) -ceq ($HOME + '\src')) (Get-ProjectsRoot $c2)

# --- 2. project.yaml fields.
$y = @(
    'project: demo', 'scope: personal   # trailing comment', 'summary: >', '  A folded summary', '  over two lines.',
    'title: "Quoted # not a comment"', "other: 'it''s single'", 'links:', '  repo: x'
)
Report "yaml-comment-stripped" ((Get-YamlField $y 'scope') -ceq 'personal') (Get-YamlField $y 'scope')
Report "yaml-folded-joined" ((Get-YamlField $y 'summary') -ceq 'A folded summary over two lines.') (Get-YamlField $y 'summary')
Report "yaml-double-quoted" ((Get-YamlField $y 'title') -ceq 'Quoted # not a comment') (Get-YamlField $y 'title')
Report "yaml-single-quoted" ((Get-YamlField $y 'other') -ceq "it's single") (Get-YamlField $y 'other')
Report "yaml-absent" ((Get-YamlField $y 'missing') -ceq '') ""

# --- 3. Listing and sort order.
foreach ($n in @('alpha', 'Beta', 'gamma', '.hidden', 'delta')) { New-Item -ItemType Directory -Force -Path (Join-Path $root $n) | Out-Null }
Write-Text (Join-Path $root 'loose-file.txt') 'x'
Write-Text (Join-Path $root 'gamma\project.yaml') "project: gamma`nscope: work # c`nsummary: `"The gamma project`"`n"
Write-Text (Join-Path $root 'alpha\project.yaml') "project: alpha`nsummary: >-`n  Folded`n  alpha.`n"
$names = (Get-ProjectList $root | ForEach-Object { $_.Name }) -join ','
Report "list-alphabetical-when-no-recent" ($names -ceq 'alpha,Beta,delta,gamma') $names
$g = Get-ProjectList $root | Where-Object { $_.Name -eq 'gamma' }
Report "list-reads-project-yaml" (($g.Scope -ceq 'work') -and ($g.Summary -ceq 'The gamma project')) "$($g.Scope) / $($g.Summary)"
$a = Get-ProjectList $root | Where-Object { $_.Name -eq 'alpha' }
Report "list-folded-summary" (($a.Scope -ceq '') -and ($a.Summary -ceq 'Folded alpha.')) "$($a.Scope) / $($a.Summary)"
Save-RecentProject (Join-Path $root 'gamma')
Save-RecentProject (Join-Path $root 'delta')
Save-RecentProject (Join-Path $WorkDir 'not-under-root')
Save-RecentProject (Join-Path $root 'gamma')
$names = (Get-ProjectList $root | ForEach-Object { $_.Name }) -join ','
Report "list-recent-first-then-alpha" ($names -ceq 'gamma,delta,alpha,Beta') $names
$state = [System.IO.File]::ReadAllLines((Get-RecentStatePath))
Report "recent-file-deduped" (($state.Count -eq 3) -and ($state[0] -match "^\d+`t.*\\gamma$")) ($state -join ' | ')
Report "list-missing-root" ((Get-ProjectList (Join-Path $WorkDir 'nope')).Count -eq 0) ""

# --- 4. The menu's non-interactive modes, run as the tab would run it.
$menu = Join-Path $scripts "agent-menu.ps1"
$out = & $menu codex -Print resume
Report "menu-print-resume" ($out -ceq "codex resume $quoted") "$out"
$rows = @(& $menu -List)
Report "menu-list" (($rows.Count -eq 4) -and ($rows[0] -ceq ("gamma`t" + (Join-Path $root 'gamma') + "`twork`tThe gamma project"))) ($rows -join ' | ')
$out = & $menu np -Print new_project
Report "menu-print-new-project" ($out -ceq 'np --fixture-flag "Create a new project in this folder."') "$out"
$info = @(& $menu claude -Print new_project 6>&1)
$printed = @($info | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
Report "menu-print-new-project-absent" (($printed.Count -eq 0) -and (($info -join ' ') -like "*has no 'new_project' line*")) ($info -join ' | ')
$pinned = @(& $menu np -List)
Report "menu-list-pinned-row" (($pinned.Count -eq 5) -and ($pinned[0] -ceq "+ new project`t$root`t`t") -and (($pinned[1..4] -join '|') -ceq ($rows -join '|'))) ($pinned -join ' | ')
$plain = @(& $menu claude -List)
Report "menu-list-key-absent-unchanged" (($plain -join '|') -ceq ($rows -join '|')) ($plain -join ' | ')

# The home screen's entries: start_in absent keeps home, project, resume; start_in:
# projects_root, only when the root exists, gives root, project, resume, home (Home last)
# and opens Resume in the root.
$out = (@(& $menu claude -Entries) | ForEach-Object { ($_ -split "`t")[0] }) -join ','
Report "entries-default" ($out -ceq 'home,project,resume') $out
$r = @(& $menu claude -Entries)[-1]
Report "entries-default-resume-home" ($r -ceq "resume`t$HOME") $r
$base = [System.IO.File]::ReadAllText($configPath)
Write-Text $configPath ("start_in: projects_root`r`n" + $base)
$e = @(& $menu claude -Entries)
Report "entries-start-in-root" ((($e | ForEach-Object { ($_ -split "`t")[0] }) -join ',') -ceq 'root,project,resume,home' -and ($e[0] -ceq "root`t$root") -and ($e[1] -ceq "project`t$root") -and ($e[2] -ceq "resume`t$root") -and ($e[3] -ceq "home`t$HOME")) ($e -join ' | ')
Write-Text $configPath ("start_in: projects_root`r`nprojects_root: $(Join-Path $WorkDir 'nope')`r`n" + ($base -replace '(?m)^projects_root:.*$', ''))
$out = (@(& $menu claude -Entries) | ForEach-Object { ($_ -split "`t")[0] }) -join ','
$r = @(& $menu claude -Entries)[-1]
Report "entries-start-in-missing-root" (($out -ceq 'home,project,resume') -and ($r -ceq "resume`t$HOME")) "$out | $r"
Write-Text $configPath $base

# --- 4b. The session list: fake Claude Code session files in a temp config dir. The temp
# folder check is pointed at a fixture folder, since the whole test lives in a temp dir.
$env:CLAUDE_CONFIG_DIR = Join-Path $WorkDir "claude"
$env:AGENT_MENU_TEMP_DIR = Join-Path $WorkDir "fake-temp"
$P = Join-Path $env:CLAUDE_CONFIG_DIR "projects"
New-Item -ItemType Directory -Force -Path (Join-Path $env:AGENT_MENU_TEMP_DIR 'x') | Out-Null
function JEsc([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }
function New-Session([string]$Folder, [string]$Id, [int]$Minute, [string[]]$Lines, [string]$Tail = '') {
    $d = Join-Path $P $Folder
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $f = Join-Path $d "$Id.jsonl"
    [System.IO.File]::WriteAllText($f, (($Lines -join "`n") + "`n" + $Tail), $utf8)
    (Get-Item -LiteralPath $f).LastWriteTimeUtc = (New-Object DateTime 2026, 1, 1, 0, $Minute, 0, ([DateTimeKind]::Utc))
}
function ULine([string]$cwd, [string]$content, [string]$branch = '') {
    return '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":' + $content + '},"uuid":"u1","cwd":"' + (JEsc $cwd) + '","sessionId":"x","version":"2.1.290","gitBranch":"' + $branch + '"}'
}
function ALine([string]$cwd) { return '{"parentUuid":"u1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"cwd":"' + (JEsc $cwd) + '","sessionId":"x"}' }
$mode = '{"type":"mode","mode":"normal","sessionId":"x"}'
$long = '01234567890123456789012345678901234567890123456789012345678901234567890123456789'
$ra = Join-Path $root 'alpha'; $rg = Join-Path $root 'gamma'; $rd = Join-Path $root 'delta'; $rb = Join-Path $root 'Beta'
New-Session 'f-alpha' 's-ai' 59 @($mode, (ULine $ra '"first prompt"' 'feature/x'), (ALine $ra),
    '{"type":"ai-title","aiTitle":"Old title","sessionId":"x"}', '{"type":"last-prompt","lastPrompt":"later prompt","sessionId":"x"}',
    '{"type":"ai-title","aiTitle":"Second title","sessionId":"x"}', '{"type":"ai-title","aiTitle":"Second title","sessionId":"x"}')
New-Session 'f-gamma' 's-noai' 58 @($mode, (ULine $rg '"first gamma prompt"' 'HEAD'),
    '{"type":"last-prompt","lastPrompt":"an earlier prompt","sessionId":"x"}', '{"type":"last-prompt","lastPrompt":"the last prompt","sessionId":"x"}')
New-Session 'f-root' 's-array' 57 @('{"type":"queue-operation","operation":"enqueue","sessionId":"x"}',
    (ULine $root '[{"type":"text","text":"array text  with\nnewline"},{"type":"text","text":"second block"}]'))
New-Session 'f-delta' 's-multi' 56 @($mode, (ULine $rd '"multi first"'), (ALine $rd), (ULine $ra '"resumed elsewhere"'), (ALine $ra))
New-Session 'f-beta' 's-partial' 55 @((ULine $rb '"partial"'), '{"type":"ai-title","aiTitle":"Complete title","sessionId":"x"}') '{"type":"ai-title","aiTitle":"cut of'
New-Session 'f-alpha' 's-long' 54 @((ULine $ra '"long"'), ('{"type":"ai-title","aiTitle":"' + $long + '","sessionId":"x"}'))
New-Session 'f-alpha' 's-escape' 53 @((ULine $ra '"esc"'), '{"type":"ai-title","aiTitle":"say \"hi\" \\ tab\u0009end","sessionId":"x"}')
New-Session 'f-temp' 's-temp' 59 @((ULine (Join-Path $env:AGENT_MENU_TEMP_DIR 'x') '"in temp"'))
New-Session 'f-alpha' 's-nouser' 59 @($mode, ('{"type":"attachment","cwd":"' + (JEsc $ra) + '","sessionId":"x"}'), '{"type":"ai-title","aiTitle":"No user","sessionId":"x"}')
New-Session 'f-gone' 's-gone' 59 @((ULine (Join-Path $WorkDir 'deleted-folder') '"gone"'))
New-Session 'f-sys' 's-system' 59 @((ULine (Join-Path $env:SystemRoot 'System32') '"system"'))
New-Session 'f-alpha\s-ai\subagents' 'agent-1' 59 @((ULine $ra '"subagent"'))
Write-Text (Join-Path $P 'f-alpha\notes.txt') 'not a session'
# Temp-folder ordering: s-temp etc. share minute 59 with s-ai, so give s-ai the newest time.
(Get-Item -LiteralPath (Join-Path $P 'f-alpha\s-ai.jsonl')).LastWriteTimeUtc = (New-Object DateTime 2026, 1, 1, 1, 0, 0, ([DateTimeKind]::Utc))
$expected = @(
    "s-ai`t$ra`tfeature/x`tSecond title", "s-noai`t$rg`t`tthe last prompt", "s-array`t$root`t`tarray text with newline",
    "s-multi`t$rd`t`tmulti first", "s-partial`t$rb`t`tComplete title", ("s-long`t$ra`t`t" + $long.Substring(0, 57) + '...'),
    "s-escape`t$ra`t`tsay `"hi`" \ tab end"
)
$got = @(& $menu claude -Sessions)
Report "sessions-list" (($got -join "`n") -ceq ($expected -join "`n")) ($got -join ' | ')
$ids = (Get-ClaudeSessions $P | ForEach-Object { $_.Id }) -join ','
Report "sessions-ids" ($ids -ceq 's-ai,s-noai,s-array,s-multi,s-partial,s-long,s-escape') $ids
Report "sessions-cap" ((Get-ClaudeSessions $P 2).Count -eq 2) ""
Report "sessions-off-for-codex" (@(& $menu codex -Sessions).Count -eq 0) ""
$fs = "$(Format-SessionFolder $ra $root)|$(Format-SessionFolder $root $root)|$(Format-SessionFolder (Join-Path $WorkDir 'elsewhere') $root)"
Report "sessions-folder-relative" ($fs -ceq "alpha|$root|$(Join-Path $WorkDir 'elsewhere')") $fs
$ages = "$(Format-Age 30)|$(Format-Age 300)|$(Format-Age 10800)|$(Format-Age 172800)|$(Format-Age 1900000)"
Report "sessions-age" ($ages -ceq 'now|5m|3h|2d|3w') $ages
$un = ConvertFrom-JsonStringBody 'a \"q\" \\ b\nc\uZZd'
Report "sessions-unescape" ($un -ceq 'a "q" \ b c?ZZd') $un
Report "sessions-resume-command" ((Get-SessionResumeCommand $c 'claude' 's-ai') -ceq 'claude --fixture-flag --resume s-ai') (Get-SessionResumeCommand $c 'claude' 's-ai')
Report "sessions-resume-command-codex" ((Get-SessionResumeCommand $c 'codex' 's-ai') -ceq "codex resume $quoted s-ai") (Get-SessionResumeCommand $c 'codex' 's-ai')
$kinds = "$(Get-SessionListKind $c 'claude')|$(Get-SessionListKind $c 'codex')"
$c3 = Read-AgentConfig $configPath
$c3.Blocks['claude']['session_list'] = 'off'; $c3.Blocks['codex']['session_list'] = 'claude'
$kinds += "|$(Get-SessionListKind $c3 'claude')|$(Get-SessionListKind $c3 'codex')"
Report "sessions-kind-default-and-keys" ($kinds -ceq 'claude|||claude') $kinds
$env:CLAUDE_CONFIG_DIR = Join-Path $WorkDir "claude-empty"
Report "sessions-missing-store" (@(& $menu claude -Sessions).Count -eq 0) ""
$env:CLAUDE_CONFIG_DIR = Join-Path $WorkDir "claude-none"
Remove-Item Env:\AGENT_MENU_TEMP_DIR

# --- 5. Setup, against temp folders only.
$tabs = $env:WARP_TAB_CONFIGS_DIR
$env:AGENT_MENU_DIR = Join-Path $WorkDir "menu2"
$installedMenu = Join-Path $env:AGENT_MENU_DIR "agent-menu.ps1"
$newConfig = Join-Path $env:AGENT_MENU_DIR "agents.yaml"
function Write-Standing([string]$name, [string]$command) {
    $enc = ($command -replace '\\', '\\') -replace '"', '\"'
    Write-Text (Join-Path $tabs "$name.toml") "name = `"$name`"`n`n[[panes]]`nid = `"main`"`ntype = `"terminal`"`ncommands = [`"$enc`"]`n"
}
Write-Standing 'claude' 'claude --fixture-flag'
Write-Standing 'codex' "codex $quoted"
Write-Standing 'claude-resume' 'claude --fixture-flag --resume'
$before = [System.IO.File]::ReadAllText((Join-Path $tabs 'claude.toml'))
$setup = Join-Path $scripts "setup.ps1"

$msg = (& $setup -Check) -join "`n"
$unchanged = (-not (Test-Path $newConfig)) -and (-not (Test-Path $installedMenu)) -and ([System.IO.File]::ReadAllText((Join-Path $tabs 'claude.toml')) -ceq $before)
Report "setup-check-changes-nothing" ($unchanged -and ($msg -like "*check only*")) $msg
Report "setup-check-reports-flags" (($msg -like "*launches 'codex' with flags: $quoted*") -and ($msg -like "*claude-resume.toml is redundant*")) $msg

$msg = (& $setup -CarryArgs -ProjectsRoot 'D:\fixture root') -join "`n"
$cfg = Read-AgentConfig $newConfig
Report "setup-created-config" ((Test-Path $newConfig) -and ((Get-ProjectsRoot $cfg) -ceq 'D:\fixture root')) $msg
Report "setup-template-starts-home" (((Get-HomeEntries $cfg) | ForEach-Object { $_.Key }) -join ',' -ceq 'home,project,resume') ""
Report "setup-carried-args" (((Get-AgentCommand $cfg 'codex' 'resume') -ceq "codex resume $quoted") -and ((Get-AgentCommand $cfg 'claude' 'new') -ceq 'claude --fixture-flag')) (Get-AgentCommand $cfg 'codex' 'resume')
Report "setup-installed-scripts" ((Test-Path $installedMenu) -and (Test-Path (Join-Path $env:AGENT_MENU_DIR 'agent-config.ps1'))) ""
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $tabs 'claude.toml'))
Report "setup-tab-config-no-bom" (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) ""
$m = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $tabs 'codex.toml')), '(?m)^commands = \["((?:[^"\\]|\\.)*)"\]')
$tabCmd = $m.Groups[1].Value -replace '\\(["\\])', '$1'
Report "setup-tab-command" ($tabCmd -ceq "& '$installedMenu' codex") $tabCmd
$printed = Invoke-Expression "$tabCmd -Print new"
Report "setup-tab-command-runs-menu" ($printed -ceq "codex $quoted") "$printed"
Report "setup-kept-resume-file" (Test-Path (Join-Path $tabs 'claude-resume.toml')) ""
$backups = @(Get-ChildItem -LiteralPath (Join-Path $env:AGENT_MENU_DIR 'backup') -Filter 'claude.*.toml')
Report "setup-backed-up-old-tab" (($backups.Count -eq 1) -and ([System.IO.File]::ReadAllText($backups[0].FullName) -ceq $before)) ""

Add-Content -LiteralPath $newConfig -Value "# user edit"
$edited = [System.IO.File]::ReadAllText($newConfig)
$msg = (& $setup) -join "`n"
Report "setup-rerun-keeps-config" ([System.IO.File]::ReadAllText($newConfig) -ceq $edited) $msg
Report "setup-rerun-tab-current" ($msg -like "*claude.toml is current*") $msg

# Explicit -AgentArgs wins over -CarryArgs for its agent, and may be empty.
$env:AGENT_MENU_DIR = Join-Path $WorkDir "menu3"
Write-Standing 'claude' 'claude --fixture-flag'
Write-Standing 'codex' "codex $quoted"
$msg = (& $setup -CarryArgs -AgentArgs 'claude=--explicit-flag', 'codex=' -TabConfigsDir $tabs) -join "`n"
$cfg = Read-AgentConfig (Join-Path $env:AGENT_MENU_DIR "agents.yaml")
Report "setup-explicit-args" (((Get-AgentCommand $cfg 'claude' 'resume') -ceq 'claude --explicit-flag --resume') -and ((Get-AgentCommand $cfg 'codex' 'new') -ceq 'codex')) $msg
$msg = (& $setup -AgentArgs 'claude=--other') -join "`n"
Report "setup-explicit-args-existing-config" (($msg -like "*not applied*") -and ((Get-AgentCommand (Read-AgentConfig (Join-Path $env:AGENT_MENU_DIR "agents.yaml")) 'claude' 'new') -ceq 'claude --explicit-flag')) $msg

# --- 6. Self-refresh: a fake plugin cache with one folder per version.
$cmp = @(
    (Compare-PluginVersion '1.10.0' '1.9.9'), (Compare-PluginVersion '1.4.0' '1.4.0'), (Compare-PluginVersion '1.4' '1.4.0'),
    (Compare-PluginVersion 'v2.0.0' '1.99.99'), (Compare-PluginVersion '1.4.0-beta' '1.4.0'), (Compare-PluginVersion 'garbage' '1.4.0'),
    (Compare-PluginVersion '1.3.1' '1.4.0'), (Compare-PluginVersion '1.4.1' '1.4.0')
) -join '|'
Report "version-compare" ($cmp -ceq '1|0|0|1|0|0|-1|1') $cmp
function New-FakePlugin([string]$Dir, [string]$Version, [string]$Marker = '', [string]$Name = 'terminal') {
    if (Test-Path -LiteralPath $Dir) { Remove-Item -Recurse -Force -LiteralPath $Dir }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir '.claude-plugin'), (Join-Path $Dir 'skills\agent-menu') | Out-Null
    Write-Text (Join-Path $Dir '.claude-plugin\plugin.json') "{`n  `"name`": `"$Name`",`n  `"version`": `"$Version`"`n}`n"
    Copy-Item -Recurse -LiteralPath $scripts -Destination (Join-Path $Dir 'skills\agent-menu\scripts')
    Copy-Item -Recurse -LiteralPath (Join-Path $PSScriptRoot '..\templates') -Destination (Join-Path $Dir 'skills\agent-menu\templates')
    if ($Marker) { Add-Content -LiteralPath (Join-Path $Dir 'skills\agent-menu\scripts\agent-menu.ps1') -Value "# $Marker" }
}
function Get-Record { return (Read-AgentConfig (Join-Path $env:AGENT_MENU_DIR 'plugin-source.txt')).Top }
function Test-Marker([string]$m) { return [bool](Select-String -LiteralPath (Join-Path $env:AGENT_MENU_DIR 'agent-menu.ps1') -SimpleMatch $m -Quiet) }
$env:AGENT_MENU_DIR = Join-Path $WorkDir "menu4"
$cache = Join-Path $WorkDir "cache\terminal"
New-FakePlugin (Join-Path $cache '1.4.0') '1.4.0'
& (Join-Path $cache '1.4.0\skills\agent-menu\scripts\setup.ps1') -ProjectsRoot $root | Out-Null
$rec = Get-Record
Report "refresh-record-written" (($rec['plugin'] -ceq (Join-Path $cache '1.4.0')) -and ($rec['name'] -ceq 'terminal') -and ($rec['version'] -ceq '1.4.0')) (($rec.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
$installed = Join-Path $env:AGENT_MENU_DIR 'agent-menu.ps1'
$out = (@(& $installed claude -Entries) | ForEach-Object { ($_ -split "`t")[0] }) -join ','
Report "refresh-same-version-untouched" (($out -ceq 'home,project,resume') -and -not (Test-Marker 'marker-1.5.0')) $out
$cfgBefore = [System.IO.File]::ReadAllText((Join-Path $env:AGENT_MENU_DIR 'agents.yaml'))
New-FakePlugin (Join-Path $cache '1.5.0') '1.5.0' 'marker-1.5.0'
New-FakePlugin (Join-Path $cache '1.3.1') '1.3.1' 'marker-1.3.1'
$all = @(& $installed claude -Entries 6>&1 3>&1 2>&1)
$out = ($all | Where-Object { $_ -is [string] } | ForEach-Object { ($_ -split "`t")[0] }) -join ','
$rec = Get-Record
Report "refresh-newer-sibling" (($out -ceq 'home,project,resume') -and (Test-Marker 'marker-1.5.0') -and ($rec['plugin'] -ceq (Join-Path $cache '1.5.0')) -and ($rec['version'] -ceq '1.5.0')) "$out | $($rec['plugin']) $($rec['version'])"
Report "refresh-quiet" (@($all | Where-Object { $_ -isnot [string] }).Count -eq 0) (($all | Where-Object { $_ -isnot [string] }) -join ' | ')
Report "refresh-keeps-config" ([System.IO.File]::ReadAllText((Join-Path $env:AGENT_MENU_DIR 'agents.yaml')) -ceq $cfgBefore) ""
Report "refresh-env-cleared" (-not $env:AGENT_MENU_REFRESHED) ""
& $installed claude -Entries | Out-Null
Report "refresh-not-again" (@(Select-String -LiteralPath $installed -SimpleMatch 'marker-1.5.0').Count -eq 1) ""
Write-PluginSourceRecord $env:AGENT_MENU_DIR (Join-Path $cache '1.5.0') 'terminal' 'garbage'
New-FakePlugin (Join-Path $cache '1.6.0') '1.6.0' 'marker-1.6.0'
& $installed claude -Entries | Out-Null
Report "refresh-garbage-version" (-not (Test-Marker 'marker-1.6.0')) ""
Remove-Item -Recurse -Force (Join-Path $WorkDir "cache")
Write-PluginSourceRecord $env:AGENT_MENU_DIR (Join-Path $cache '1.5.0') 'terminal' '1.5.0'
$all = @(& $installed claude -Entries 6>&1 3>&1 2>&1)
$out = ($all | Where-Object { $_ -is [string] } | ForEach-Object { ($_ -split "`t")[0] }) -join ','
Report "refresh-source-gone" (($out -ceq 'home,project,resume') -and @($all | Where-Object { $_ -isnot [string] }).Count -eq 0) $out
$checkout = Join-Path $WorkDir "checkout"
New-FakePlugin $checkout '1.5.0'
Write-PluginSourceRecord $env:AGENT_MENU_DIR $checkout 'terminal' '1.5.0'
& $installed claude -Entries | Out-Null
Report "refresh-in-place-same" (-not (Test-Marker 'marker-in-place')) ""
New-FakePlugin $checkout '1.5.1' 'marker-in-place'
& $installed claude -Entries | Out-Null
Report "refresh-in-place-newer" ((Test-Marker 'marker-in-place') -and ((Get-Record)['version'] -ceq '1.5.1')) ""
$cache2 = Join-Path $WorkDir "cache2\x"
New-FakePlugin (Join-Path $cache2 '2.0.0') '2.0.0' 'marker-other' 'other'
New-FakePlugin (Join-Path $cache2 '1.0.0') '1.0.0'
Write-PluginSourceRecord $env:AGENT_MENU_DIR (Join-Path $cache2 '1.0.0') 'terminal' '1.0.0'
& $installed claude -Entries | Out-Null
Report "refresh-other-plugin-ignored" (-not (Test-Marker 'marker-other')) ""

foreach ($k in $saved.Keys) {
    if ($null -ne $saved[$k]) { Set-Item -Path "Env:\$k" -Value $saved[$k] } else { Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue }
}
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Output "$failures FAILURE(S)"; exit 1 }
Write-Output "All $total cases passed."
