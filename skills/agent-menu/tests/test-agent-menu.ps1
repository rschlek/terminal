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
$saved = @{ AGENT_MENU_DIR = $env:AGENT_MENU_DIR; WARP_TAB_CONFIGS_DIR = $env:WARP_TAB_CONFIGS_DIR }
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

foreach ($k in $saved.Keys) {
    if ($null -ne $saved[$k]) { Set-Item -Path "Env:\$k" -Value $saved[$k] } else { Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue }
}
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Output "$failures FAILURE(S)"; exit 1 }
Write-Output "All $total cases passed."
