<#
.SYNOPSIS
  agent-menu setup (Windows) - install the agent menu for the current user and
  point the standing Warp tab configs at it.

.DESCRIPTION
  Safe to re-run. It:
    1. copies agent-menu.ps1 and agent-config.ps1 to <AGENT_MENU_DIR> (refreshed
       every run; AGENT_MENU_DIR defaults to %LOCALAPPDATA%\agent-menu), so the
       tab configs never point into the versioned plugin directory;
    2. creates <AGENT_MENU_DIR>\agents.yaml from the template ONLY when it does not
       exist - an existing config is never touched;
    3. writes <tab_configs>\<agent>.toml for each agent, running the menu; a
       replaced tab config is first copied to <AGENT_MENU_DIR>\backup\;
    4. reports any <agent>-resume.toml as redundant - it never deletes one.

  -Check reports what it found and would do, and changes nothing. Its report
  includes the flags each existing standing tab config launches with, so the
  caller can ask the user whether to keep them: -CarryArgs writes those flags
  into each block's `args` line when the config is created now. -AgentArgs
  'name=<args>' sets a block's `args` explicitly (it wins over -CarryArgs for
  that agent). -ProjectsRoot fills projects_root in a newly created config.
  All three apply only when the config is created; an existing one is never
  rewritten.

  The tab_configs dir defaults to Warp's; WARP_TAB_CONFIGS_DIR (or
  -TabConfigsDir) points it elsewhere, as for the new-warp-chat launcher.

.EXAMPLE
  setup.ps1 -Check
.EXAMPLE
  setup.ps1 -CarryArgs -ProjectsRoot 'D:\src'
.EXAMPLE
  setup.ps1 -AgentArgs 'claude=--some-flag', 'codex=--model some-model'
#>
[CmdletBinding()]
param(
    [string[]]$Agents = @('claude', 'codex'),                                          # one tab config per agent; each needs a block in agents.yaml
    [string]$ProjectsRoot = '',                                                        # projects_root for a NEWLY created config
    [switch]$CarryArgs,                                                                # carry flags from existing standing tab configs into a new config
    [string[]]$AgentArgs = @(),                                                        # 'name=<args>': explicit args for a block in a new config
    [switch]$Check,                                                                    # report only; change nothing
    [string]$TabConfigsDir = $(if ($env:WARP_TAB_CONFIGS_DIR) { $env:WARP_TAB_CONFIGS_DIR } else { Join-Path $env:APPDATA "warp\Warp\data\tab_configs" })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-config.ps1')

$skillDir   = Split-Path -Parent $PSScriptRoot
$menuDir    = Get-AgentMenuDir
$configPath = Join-Path $menuDir 'agents.yaml'
$menuPath   = Join-Path $menuDir 'agent-menu.ps1'
$utf8       = New-Object System.Text.UTF8Encoding($false)
function Say([string]$Text) { Write-Output "agent-menu setup: $Text" }

foreach ($a in $Agents) {
    if ($a -notmatch '^[A-Za-z0-9._-]+$') { throw "agent-menu setup: an agent name may only contain letters, digits, '.', '_', '-' (got: $a)" }
}
# --- Explicit args: 'name=<args>', the args verbatim (an empty value is allowed).
$explicit = @{}
foreach ($pair in $AgentArgs) {
    if ($pair -notmatch '^([A-Za-z0-9._-]+)=(.*)$') { throw "agent-menu setup: -AgentArgs takes 'name=<args>' (got: $pair)" }
    $explicit[$Matches[1]] = $Matches[2].Trim()
}

# --- What each existing standing tab config runs today. Flags = the command minus a
# leading agent name; a config that already opens the menu has nothing to carry.
$found = @{}
foreach ($a in $Agents) {
    $path = Join-Path $TabConfigsDir "$a.toml"
    $info = @{ Path = $path; Exists = $false; Menu = $false; Flags = ''; Command = '' }
    if (Test-Path -LiteralPath $path) {
        $info.Exists = $true
        $m = [regex]::Match([System.IO.File]::ReadAllText($path), '(?m)^\s*commands\s*=\s*\[\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) {
            $info.Command = ($m.Groups[1].Value -replace '\\(["\\])', '$1').Trim()
            $parts = $info.Command -split '\s+', 2
            if ($info.Command -like '*agent-menu*') { $info.Menu = $true }
            elseif ($parts[0] -ieq $a -and $parts.Count -gt 1) { $info.Flags = $parts[1].Trim() }
        }
    }
    $found[$a] = $info
    if (-not $info.Exists) { Say "no $path yet" }
    elseif ($info.Menu) { Say "$path already opens the agent menu" }
    elseif ($info.Flags) { Say "$path launches '$a' with flags: $($info.Flags)" }
    else { Say "$path runs: $($info.Command)" }
}
foreach ($a in $Agents) {
    $resumePath = Join-Path $TabConfigsDir "$a-resume.toml"
    if (Test-Path -LiteralPath $resumePath) { Say "$resumePath is redundant once the menu is in place (Resume is on the menu); it was NOT deleted" }
}

$configExists = Test-Path -LiteralPath $configPath
if ($configExists) {
    Say "config $configPath exists; it is left as it is"
    $existing = Read-AgentConfig $configPath
    foreach ($a in $Agents) {
        if (-not $existing.Blocks.ContainsKey($a)) { Say "WARNING: $configPath has no '$a' block; add one before using the $a tab" }
        elseif ($found[$a].Flags) {
            $have = ''
            if ($existing.Blocks[$a].ContainsKey('args')) { $have = $existing.Blocks[$a]['args'] }
            if ($have -ne $found[$a].Flags) { Say "the '$a' block's args are [$have]; the old tab config used [$($found[$a].Flags)] - edit the config to keep them" }
        }
    }
    foreach ($k in $explicit.Keys) { Say "-AgentArgs for '$k' not applied: the config exists; edit its '$k' block instead" }
} else {
    Say "config $configPath will be created from the template"
    foreach ($k in $explicit.Keys) { Say "  '$k' args: [$($explicit[$k])] (from -AgentArgs)" }
    foreach ($a in $Agents) {
        if ($explicit.ContainsKey($a)) { continue }
        if ($found[$a].Flags) {
            if ($CarryArgs) { Say "  '$a' args: $($found[$a].Flags) (carried from the old tab config)" }
            else { Say "  '$a' args left empty; -CarryArgs would keep: $($found[$a].Flags)" }
        }
    }
}

# --- The tab runs the menu as a script file, so the execution policy must allow it.
# The Process scope is skipped: it belongs to this session, not to a new Warp tab.
$policy = 'Undefined'
foreach ($p in Get-ExecutionPolicy -List) {
    if ($p.Scope -eq 'Process') { continue }
    if ("$($p.ExecutionPolicy)" -ne 'Undefined') { $policy = "$($p.ExecutionPolicy)"; break }
}
if ($policy -in @('Undefined', 'Restricted', 'AllSigned')) {
    Say "WARNING: the PowerShell execution policy ($policy) will stop a new tab from running the menu script; the user decides whether to change it (for example: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned)"
}

if ($Check) { Say "check only - nothing changed"; return }

# --- 1. The menu scripts, refreshed every run.
if (-not (Test-Path -LiteralPath $menuDir)) { New-Item -ItemType Directory -Force -Path $menuDir | Out-Null }
foreach ($f in @('agent-menu.ps1', 'agent-config.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $menuDir $f) -Force
}
Say "installed the menu at $menuPath"

# --- 2. The config, only when absent.
if (-not $configExists) {
    $out = New-Object System.Collections.Generic.List[string]
    $block = $null
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $skillDir 'templates\agents.yaml'))) {
        if ($line -match '^([A-Za-z0-9_.-]+):\s*$') { $block = $Matches[1] }
        elseif ($line -match '^\S') { $block = $null }
        if ($line -match '^projects_root:' -and $ProjectsRoot) { $line = "projects_root: $ProjectsRoot" }
        elseif ($line -match '^  args:' -and $block -and $explicit.ContainsKey($block)) {
            $line = ("  args: " + $explicit[$block]).TrimEnd()
        }
        elseif ($line -match '^  args:' -and $CarryArgs -and $block -and $found.ContainsKey($block) -and $found[$block].Flags) {
            $line = "  args: $($found[$block].Flags)"
        }
        $out.Add($line)
    }
    [System.IO.File]::WriteAllText($configPath, (($out -join "`n") + "`n"), $utf8)
    Say "created $configPath"
    $created = Read-AgentConfig $configPath
    foreach ($a in $Agents) {
        if (-not $created.Blocks.ContainsKey($a)) { Say "WARNING: the template has no '$a' block; add one to $configPath before using the $a tab" }
    }
}

# --- 3. The standing tab configs. TOML basic string: escape \ then ".
if (-not (Test-Path -LiteralPath $TabConfigsDir)) { New-Item -ItemType Directory -Force -Path $TabConfigsDir | Out-Null }
$template = [System.IO.File]::ReadAllText((Join-Path $skillDir 'templates\tab-config.windows.toml'))
$menuToml = (($menuPath -replace "'", "''") -replace '\\', '\\') -replace '"', '\"'
foreach ($a in $Agents) {
    $info = $found[$a]
    $toml = $template.Replace('{menu}', $menuToml).Replace('{agent}', $a)
    if ($info.Exists) {
        $current = [System.IO.File]::ReadAllText($info.Path)
        if ($current -eq $toml) { Say "$($info.Path) is current"; continue }
        $backupDir = Join-Path $menuDir 'backup'
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
        $backup = Join-Path $backupDir ("{0}.{1}.toml" -f $a, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $info.Path -Destination $backup -Force
        Say "saved the previous $($info.Path) as $backup"
    }
    [System.IO.File]::WriteAllText($info.Path, $toml, $utf8)
    Say "wrote $($info.Path)"
}
