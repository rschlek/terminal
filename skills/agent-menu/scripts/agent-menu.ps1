<#
.SYNOPSIS
  agent-menu - the menu a standing Warp tab runs for one agent CLI: a fresh
  session in the home folder, a fresh or resumed session in a project, or the
  agent's own resume list. Windows PowerShell 5.1.

.DESCRIPTION
  A Warp tab config runs it with one argument, the agent name:
      & '<AGENT_MENU_DIR>\agent-menu.ps1' claude
  It runs in the tab's own PowerShell session, so the Set-Location before the
  launch sticks: when the agent exits, the user is at a prompt in that folder.
  Esc on the home screen returns to a plain prompt without launching anything.

  Home screen (Up/Down, Enter, Esc):
    Home        the agent's `new` line, in the home folder
    Project...  the project view below
    Resume      the agent's `resume_all` line (else `resume`), in the home folder
                (in projects_root with `start_in: projects_root`, below)
  With `start_in: projects_root` in the config and an existing projects root, a
  first entry `Projects root` (the agent's `new` line, in projects_root) is added
  and selected when the menu opens, and the order becomes Projects root,
  Project..., Resume, Home: everything in projects_root together, Home last.
  Resume then opens in projects_root instead of the home folder.
  Project view: the directories directly under projects_root, recently opened
  first. Type to filter, Up/Down, Enter launches `new` there, Tab toggles to
  `resume` there, Esc goes back. When the agent's block has a `new_project`
  line, a pinned first row `+ new project` (new mode only, never filtered out)
  runs that line in projects_root itself and records nothing in recent.tsv.

  Every command line comes from <AGENT_MENU_DIR>\agents.yaml, read through
  agent-config.ps1 (installed next to this script); the format and the
  {args} rule are documented there. Recent projects go to recent.tsv in the
  same folder.

  Non-interactive modes (tests, and a quick check of a config edit):
    -Print new|resume|resume_all|new_project   print the composed command line
    -List                          print the project rows, tab-separated; with an
                                   agent whose block has `new_project`, the pinned
                                   `+ new project` row comes first
    -Entries                       print the home screen's entries in order,
                                   one `<key><TAB><folder>` row each
    -NoLaunch                      run the menu, print what it would run instead

.EXAMPLE
  agent-menu.ps1 codex -Print resume
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Agent,                                           # the agent block to use, e.g. claude | codex
    [ValidateSet('new', 'resume', 'resume_all', 'new_project')][string]$Print,         # print the composed command line and stop
    [switch]$List,                                                                     # print the project rows and stop
    [switch]$Entries,                                                                  # print the home screen's entries and stop
    [switch]$NoLaunch                                                                  # interactive, but print the launch instead of running it
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-config.ps1')

$menuDir    = Get-AgentMenuDir
$configPath = Join-Path $menuDir 'agents.yaml'
$config     = Read-AgentConfig $configPath
$root       = Get-ProjectsRoot $config
# The pinned `+ new project` row: only when the agent's block has a new_project line
# and the projects root exists.
$hasNewProject = $false
if ($Agent -and $root -and (Test-Path -LiteralPath $root -PathType Container) -and $null -ne (Get-AgentCommand $config $Agent 'new_project')) { $hasNewProject = $true }
$newProjectLabel = '+ new project'

if ($List) {
    if ($hasNewProject) { "{0}`t{1}`t`t" -f $newProjectLabel, $root }
    $projects = Get-ProjectList $root
    foreach ($p in $projects) { "{0}`t{1}`t{2}`t{3}" -f $p.Name, $p.Path, $p.Scope, $p.Summary }
    return
}
if (-not $Agent) { Write-Host "agent-menu: name the agent, e.g. agent-menu.ps1 claude" -ForegroundColor Yellow; return }
if ($null -eq $config) { Write-Host "agent-menu: no config at $configPath - run the agent-menu setup" -ForegroundColor Yellow; return }
if (-not $config.Blocks.ContainsKey($Agent)) { Write-Host "agent-menu: $configPath has no '$Agent' block" -ForegroundColor Yellow; return }
if ($Print) {
    $line = Get-AgentCommand $config $Agent $Print
    if ($null -eq $line) { Write-Host "agent-menu: the '$Agent' block has no '$Print' line" -ForegroundColor Yellow; return }
    $line
    return
}
$homeEntries = Get-HomeEntries $config
if ($Entries) {
    foreach ($e in $homeEntries) { "{0}`t{1}" -f $e.Key, $e.Dir }
    return
}

# --- Drawing. Each screen owns a fixed block of rows below the cursor and redraws
# them in place; every row is padded to the window width so nothing wraps.
function Open-Region([int]$Height) {
    1..$Height | ForEach-Object { Write-Host '' }
    $script:top = [Math]::Max(0, [Console]::CursorTop - $Height)
    $script:height = $Height
}
function Write-Row([int]$Row, [string]$Text, [string]$Color = 'Gray') {
    $width = [Math]::Max(40, [Console]::WindowWidth - 1)
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
    [Console]::SetCursorPosition(0, $script:top + $Row)
    Write-Host ($Text.PadRight($width)) -ForegroundColor $Color -NoNewline
}
function Close-Region {
    for ($r = 0; $r -lt $script:height; $r++) { Write-Row $r '' }
    [Console]::SetCursorPosition(0, $script:top)
}

function Show-HomeMenu {
    $projectNote = 'pick a project, fresh session there (Tab there: resume)'
    $resumeDir = ($homeEntries | Where-Object { $_.Key -eq 'resume' }).Dir
    if (-not $root) { $projectNote = "no projects root - set projects_root in $configPath" }
    elseif (-not (Test-Path -LiteralPath $root -PathType Container)) { $projectNote = "projects root $root not found - set projects_root in $configPath" }
    $menuItems = @(foreach ($e in $homeEntries) {
        switch ($e.Key) {
            'root'    { @{ Key = 'root';    Label = 'Projects root'; Note = "fresh session in $root" } }
            'home'    { @{ Key = 'home';    Label = 'Home';          Note = "fresh session in $HOME" } }
            'project' { @{ Key = 'project'; Label = 'Project...';    Note = $projectNote } }
            'resume'  { @{ Key = 'resume';  Label = 'Resume';        Note = "the $Agent resume list in $resumeDir" } }
        }
    })
    Open-Region ($menuItems.Count + 4)
    $sel = 0
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Write-Row 0 " $Agent" 'Cyan'
            Write-Row 1 ''
            for ($i = 0; $i -lt $menuItems.Count; $i++) {
                $text = '{0,-14} {1}' -f $menuItems[$i].Label, $menuItems[$i].Note
                if ($i -eq $sel) { Write-Row (2 + $i) (" > $text") 'White' } else { Write-Row (2 + $i) ("   $text") 'DarkGray' }
            }
            Write-Row ($menuItems.Count + 2) ''
            Write-Row ($menuItems.Count + 3) ' Up/Down move   Enter select   Esc cancel' 'DarkGray'
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') { if ($sel -gt 0) { $sel-- } }
            elseif ($key.Key -eq 'DownArrow') { if ($sel -lt $menuItems.Count - 1) { $sel++ } }
            elseif ($key.Key -eq 'Escape') { Close-Region; return $null }
            elseif ($key.Key -eq 'Enter') { Close-Region; return $menuItems[$sel].Key }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- The project view. Returns @{ Item; Mode }, @{ NewProject = $true } for the
# pinned row, or $null on Esc.
function Show-ProjectPicker([object[]]$Items) {
    $rows = [Math]::Max(3, [Math]::Min(12, [Console]::WindowHeight - 8))
    Open-Region ($rows + 5)
    $filter = ''
    $mode = 'new'
    $sel = 0
    $offset = 0
    $onPin = $hasNewProject -and $Items.Count -eq 0                                 # the pinned row is selected
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $view = @($Items | Where-Object { $filter -eq '' -or $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $pin = 0
            if ($hasNewProject -and $mode -eq 'new') { $pin = 1 }
            if ($pin -eq 0) { $onPin = $false } elseif ($view.Count -eq 0) { $onPin = $true }
            $projRows = $rows - $pin
            if ($sel -ge $view.Count) { $sel = [Math]::Max(0, $view.Count - 1) }
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge $offset + $projRows) { $offset = $sel - $projRows + 1 }

            if ($mode -eq 'resume') { $head = " $Agent  -  RESUME a session"; $headColor = 'Yellow'; $hint = '(Tab: switch to new)' }
            else { $head = " $Agent  -  NEW session"; $headColor = 'Cyan'; $hint = '(Tab: switch to resume)' }
            Write-Row 0 ($head.PadRight(34) + $hint) $headColor
            Write-Row 1 ''
            if ($pin -eq 1) {
                if ($onPin) { Write-Row 2 (" > $newProjectLabel") 'White' } else { Write-Row 2 ("   $newProjectLabel") 'DarkGray' }
            }
            for ($r = 0; $r -lt $projRows; $r++) {
                $i = $offset + $r
                if ($i -lt $view.Count) {
                    $it = $view[$i]
                    $text = '{0,-24} {1,-10} {2}' -f $it.Name, $it.Scope, $it.Summary
                    if ($i -eq $sel -and -not $onPin) { Write-Row (2 + $pin + $r) (" > $text") 'White' } else { Write-Row (2 + $pin + $r) ("   $text") 'DarkGray' }
                } else {
                    Write-Row (2 + $pin + $r) ''
                }
            }
            $more = $view.Count - ($offset + $projRows)
            if ($more -gt 0) { Write-Row ($rows + 2) "   ... $more more" 'DarkGray' }
            elseif ($view.Count -eq 0) { Write-Row ($rows + 2) '   no match' 'DarkGray' }
            else { Write-Row ($rows + 2) '' }
            Write-Row ($rows + 3) " filter: ${filter}_" 'Green'
            Write-Row ($rows + 4) ' type to filter   Up/Down move   Tab new/resume   Enter select   Esc back' 'DarkGray'

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') { if ($onPin) { } elseif ($sel -gt 0) { $sel-- } elseif ($pin -eq 1) { $onPin = $true } }
            elseif ($key.Key -eq 'DownArrow') { if ($onPin) { if ($view.Count -gt 0) { $onPin = $false; $sel = 0 } } elseif ($sel -lt $view.Count - 1) { $sel++ } }
            elseif ($key.Key -eq 'Tab') { if ($mode -eq 'new') { $mode = 'resume' } else { $mode = 'new' } }
            elseif ($key.Key -eq 'Backspace') { if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0; $onPin = $false } }
            elseif ($key.Key -eq 'Escape') { Close-Region; return $null }
            elseif ($key.Key -eq 'Enter') {
                if ($onPin) { Close-Region; return @{ NewProject = $true } }
                if ($view.Count -gt 0) { Close-Region; return @{ Item = $view[$sel]; Mode = $mode } }
            }
            elseif ("$($key.KeyChar)" -match '^[A-Za-z0-9._ -]$') { $filter += $key.KeyChar; $sel = 0; $onPin = $false }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- Home screen loop: only Project opens a second view, and Esc there comes back.
$launchDir = $null
$launchMode = $null
while ($true) {
    $pick = Show-HomeMenu
    if ($null -eq $pick) { return }
    if ($pick -eq 'root') { $launchDir = $root; $launchMode = 'new'; break }
    if ($pick -eq 'home') { $launchDir = $HOME; $launchMode = 'new'; break }
    if ($pick -eq 'resume') { $launchDir = ($homeEntries | Where-Object { $_.Key -eq 'resume' }).Dir; $launchMode = 'resume_all'; break }
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    $projects = Get-ProjectList $root
    if ($projects.Count -eq 0 -and -not $hasNewProject) { continue }
    $choice = Show-ProjectPicker $projects
    if ($null -ne $choice -and $choice.NewProject) {
        $launchDir = $root
        $launchMode = 'new_project'
        break
    }
    if ($null -ne $choice) {
        $launchDir = $choice.Item.Path
        $launchMode = $choice.Mode
        if (-not $NoLaunch) { Save-RecentProject $launchDir }
        break
    }
}

$line = Get-AgentCommand $config $Agent $launchMode
if ($null -eq $line) { Write-Host "agent-menu: the '$Agent' block in $configPath has no '$launchMode' line" -ForegroundColor Yellow; return }
if ($NoLaunch) {
    Write-Host "agent-menu: would run, in ${launchDir}:"
    Write-Host "  $line"
    return
}
Set-Location -LiteralPath $launchDir
Write-Host "$launchDir> $line" -ForegroundColor DarkGray
Invoke-Expression $line
