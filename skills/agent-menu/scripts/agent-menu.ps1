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
                (in projects_root with `start_in: projects_root`, below); for an
                agent with a session list (below), the list of past chats instead
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

  Session list: when the agent's block has `session_list: claude` (the default for
  a block named `claude`), Resume opens the past chats of every folder, newest
  first, read from Claude Code's session store: title, folder, age, branch. Type
  to filter, Enter reopens the chat in the folder it was started in (the
  `resume` line plus the session id), Tab picks another folder from the project
  view and reopens it there, Esc goes back. With no readable chats, Resume runs
  the plain resume line as before.

  Modes: when the agent's block lists `mode:` lines, a mode line at the top of
  every screen shows the modes, the selected one in brackets (the first mode in
  cyan, any other in magenta). M on the home screen, Shift+M in the pickers
  (where a lower-case m is filter text), selects the next mode; new, resume,
  new_project and the session list all follow it. The choice is remembered per
  agent in modes.tsv. A block with no mode lines shows no mode line.

  Self-refresh: the installed copy carries plugin-source.txt (written by setup).
  When the plugin it came from has a newer version, the menu copies the newer
  scripts over itself and runs them; on any failure it runs as it is. agents.yaml
  is never touched.

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
    -Sessions                      print the agent's session list, one
                                   `<id><TAB><folder><TAB><branch><TAB><title>` row
                                   each (nothing when the list is off)
    -Modes                         print the agent's modes in order, one
                                   `<mode><TAB><selected><TAB><session store>` row
                                   each, <selected> being `*` for the remembered one
    -Mode <name>                   with any of the above or the menu: use that mode
                                   instead of the remembered one (not saved)
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
    [switch]$Sessions,                                                                 # print the session list and stop
    [switch]$Modes,                                                                    # print the agent's modes and stop
    [string]$Mode,                                                                     # use this mode instead of the remembered one
    [switch]$NoLaunch                                                                 # interactive, but print the launch instead of running it
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-config.ps1')

# --- Self-refresh: an installed copy (plugin-source.txt beside it) that finds a newer
# plugin replaces its scripts and runs the new copy with the same arguments.
if (-not $env:AGENT_MENU_REFRESHED -and (Update-InstalledMenu $PSScriptRoot)) {
    $env:AGENT_MENU_REFRESHED = '1'
    try { & (Join-Path $PSScriptRoot 'agent-menu.ps1') @PSBoundParameters }
    finally { Remove-Item Env:\AGENT_MENU_REFRESHED -ErrorAction SilentlyContinue }
    return
}

$menuDir    = Get-AgentMenuDir
$configPath = Join-Path $menuDir 'agents.yaml'
$config     = Read-AgentConfig $configPath
$root       = Get-ProjectsRoot $config
$newProjectLabel = '+ new project'

# --- The agent's modes and the selected one ('' when the block lists none). Everything
# that depends on the mode is recomputed by Set-AgentMode when M cycles it.
$agentModes = @()
$agentMode = ''
if ($Agent -and $null -ne $config -and $config.Blocks.ContainsKey($Agent)) {
    $agentModes = Get-AgentModes $config $Agent
    if ($Mode) {
        $agentMode = Resolve-AgentMode $config $Agent $Mode
        if ($null -eq $agentMode) { Write-Host "agent-menu: the '$Agent' block has no mode '$Mode' (modes: $($agentModes -join ', '))" -ForegroundColor Yellow; return }
    } else {
        $agentMode = Get-SelectedMode $config $Agent
    }
}
function Set-AgentMode([string]$Name) {
    $script:agentMode = $Name
    # The pinned `+ new project` row: only when the agent's block (or mode) has a
    # new_project line and the projects root exists.
    $script:hasNewProject = [bool]($Agent -and $root -and (Test-Path -LiteralPath $root -PathType Container) -and $null -ne (Get-AgentCommand $config $Agent 'new_project' $Name))
    $script:sessionKind = Get-SessionListKind $config $Agent $Name
}
Set-AgentMode $agentMode

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
    $line = Get-AgentCommand $config $Agent $Print $agentMode
    if ($null -eq $line) { Write-Host "agent-menu: the '$Agent' block has no '$Print' line" -ForegroundColor Yellow; return }
    $line
    return
}
if ($Modes) {
    $remembered = Get-SelectedMode $config $Agent
    foreach ($m in $agentModes) { "{0}`t{1}`t{2}" -f $m, $(if ($m -ceq $remembered) { '*' } else { '' }), (Get-SessionsDir $config $Agent $m) }
    return
}
$homeEntries = Get-HomeEntries $config
if ($Entries) {
    foreach ($e in $homeEntries) { "{0}`t{1}" -f $e.Key, $e.Dir }
    return
}
if ($Sessions) {
    if ($sessionKind -eq 'claude') {
        $sessionRows = Get-ClaudeSessions (Get-SessionsDir $config $Agent $agentMode)
        foreach ($s in $sessionRows) { "{0}`t{1}`t{2}`t{3}" -f $s.Id, $s.Cwd, $s.Branch, $s.Title }
    }
    return
}

# The session list per mode, read once each.
$sessionCache = @{}
function Get-ModeSessions {
    if (-not $script:sessionCache.ContainsKey($script:agentMode)) {
        $list = @()
        if ($script:sessionKind) { $list = Get-ClaudeSessions (Get-SessionsDir $config $Agent $script:agentMode) }
        $script:sessionCache[$script:agentMode] = $list
    }
    return , $script:sessionCache[$script:agentMode]
}
# M cycles the mode and remembers it.
function Step-AgentMode {
    if ($agentModes.Count -lt 2) { return $false }
    Set-AgentMode (Get-NextMode $agentModes $script:agentMode)
    try { Save-SelectedMode $Agent $script:agentMode } catch { }
    return $true
}

# --- Drawing. Each screen owns a fixed block of rows below the cursor and redraws
# them in place; every row is padded to the window width so nothing wraps.
# With modes, every region gets one more row on top for the mode line; Write-Row's row
# numbers start below it.
function Open-Region([int]$Height) {
    $script:base = 0
    if ($agentModes.Count -gt 0) { $script:base = 1 }
    $Height += $script:base
    1..$Height | ForEach-Object { Write-Host '' }
    $script:top = [Math]::Max(0, [Console]::CursorTop - $Height)
    $script:height = $Height
}
function Write-Row([int]$Row, [string]$Text, [string]$Color = 'Gray') {
    $width = [Math]::Max(40, [Console]::WindowWidth - 1)
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
    [Console]::SetCursorPosition(0, $script:top + $script:base + $Row)
    Write-Host ($Text.PadRight($width)) -ForegroundColor $Color -NoNewline
}
function Close-Region {
    for ($r = 0 - $script:base; $r -lt $script:height - $script:base; $r++) { Write-Row $r '' }
    [Console]::SetCursorPosition(0, $script:top)
}
# The colour of the selected mode: the first (default) mode cyan, any other magenta.
function Get-ModeColor {
    if ($agentModes.Count -gt 0 -and $script:agentMode -cne $agentModes[0]) { return 'Magenta' }
    return 'Cyan'
}
# The mode line: ` mode  [first] | second    (M: next mode)`, the selected mode in
# brackets and in its colour, the others dark. Drawn on the region's top row.
function Write-ModeLine([string]$Hint = 'M: next mode') {
    if ($agentModes.Count -eq 0) { return }
    $width = [Math]::Max(40, [Console]::WindowWidth - 1)
    [Console]::SetCursorPosition(0, $script:top)
    $segments = @(@{ T = ' mode  '; C = 'DarkGray' })
    for ($i = 0; $i -lt $agentModes.Count; $i++) {
        if ($i -gt 0) { $segments += @{ T = '|'; C = 'DarkGray' } }
        if ($agentModes[$i] -ceq $script:agentMode) { $segments += @{ T = "[$($agentModes[$i])]"; C = (Get-ModeColor) } }
        else { $segments += @{ T = " $($agentModes[$i]) "; C = 'DarkGray' } }
    }
    if ($agentModes.Count -gt 1) { $segments += @{ T = "    ($Hint)"; C = 'DarkGray' } }
    $used = 0
    foreach ($s in $segments) {
        $t = $s.T
        if ($used + $t.Length -gt $width) { $t = $t.Substring(0, [Math]::Max(0, $width - $used)) }
        if ($t.Length -gt 0) { Write-Host $t -ForegroundColor $s.C -NoNewline }
        $used += $t.Length
        if ($used -ge $width) { break }
    }
    if ($used -lt $width) { Write-Host (''.PadRight($width - $used)) -NoNewline }
}
$modeKeyHome = ''
$modeKeyPick = ''
if ($agentModes.Count -gt 1) { $modeKeyHome = 'M mode   '; $modeKeyPick = 'Shift+M mode   ' }

function Show-HomeMenu {
    $projectNote = 'pick a project, fresh session there (Tab there: resume)'
    $resumeDir = ($homeEntries | Where-Object { $_.Key -eq 'resume' }).Dir
    if (-not $root) { $projectNote = "no projects root - set projects_root in $configPath" }
    elseif (-not (Test-Path -LiteralPath $root -PathType Container)) { $projectNote = "projects root $root not found - set projects_root in $configPath" }
    Open-Region ($homeEntries.Count + 4)
    $sel = 0
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            # Rebuilt each pass: the Resume note follows the mode's session list.
            $menuItems = @(foreach ($e in $homeEntries) {
                switch ($e.Key) {
                    'root'    { @{ Key = 'root';    Label = 'Projects root'; Note = "fresh session in $root" } }
                    'home'    { @{ Key = 'home';    Label = 'Home';          Note = "fresh session in $HOME" } }
                    'project' { @{ Key = 'project'; Label = 'Project...';    Note = $projectNote } }
                    'resume'  {
                        if ($sessionKind) { @{ Key = 'resume'; Label = 'Resume'; Note = "past $Agent chats from every folder, newest first" } }
                        else { @{ Key = 'resume'; Label = 'Resume'; Note = "the $Agent resume list in $resumeDir" } }
                    }
                }
            })
            Write-ModeLine
            Write-Row 0 " $Agent" (Get-ModeColor)
            Write-Row 1 ''
            for ($i = 0; $i -lt $menuItems.Count; $i++) {
                $text = '{0,-14} {1}' -f $menuItems[$i].Label, $menuItems[$i].Note
                if ($i -eq $sel) { Write-Row (2 + $i) (" > $text") 'White' } else { Write-Row (2 + $i) ("   $text") 'DarkGray' }
            }
            Write-Row ($menuItems.Count + 2) ''
            Write-Row ($menuItems.Count + 3) " Up/Down move   Enter select   ${modeKeyHome}Esc cancel" 'DarkGray'
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') { if ($sel -gt 0) { $sel-- } }
            elseif ($key.Key -eq 'DownArrow') { if ($sel -lt $menuItems.Count - 1) { $sel++ } }
            elseif ("$($key.KeyChar)" -ieq 'm') { [void](Step-AgentMode) }
            elseif ($key.Key -eq 'Escape') { Close-Region; return $null }
            elseif ($key.Key -eq 'Enter') { Close-Region; return $menuItems[$sel].Key }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- The project view. Returns @{ Item; Mode }, @{ NewProject = $true } for the
# pinned row, or $null on Esc. With -PickFor (a chat's title) it only picks a folder
# to reopen that chat in: no Tab toggle and no pinned row.
function Show-ProjectPicker([object[]]$Items, [string]$PickFor = '') {
    $rows = [Math]::Max(3, [Math]::Min(12, [Console]::WindowHeight - 8))
    Open-Region ($rows + 5)
    $filter = ''
    $mode = 'new'
    if ($PickFor) { $mode = 'pick' }
    $sel = 0
    $offset = 0
    $onPin = $hasNewProject -and $Items.Count -eq 0 -and -not $PickFor            # the pinned row is selected
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

            if ($mode -eq 'pick') { $head = " $Agent  -  REOPEN in a folder: "; $headColor = 'Yellow'; $hint = $PickFor }
            elseif ($mode -eq 'resume') { $head = " $Agent  -  RESUME a session"; $headColor = 'Yellow'; $hint = '(Tab: switch to new)' }
            else { $head = " $Agent  -  NEW session"; $headColor = 'Cyan'; $hint = '(Tab: switch to resume)' }
            if ($mode -eq 'pick') { Write-ModeLine 'a chat reopens in the mode it was listed in' } else { Write-ModeLine 'Shift+M: next mode' }
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
            if ($mode -eq 'pick') { Write-Row ($rows + 4) ' type to filter   Up/Down move   Enter reopen the chat here   Esc back to the chats' 'DarkGray' }
            else { Write-Row ($rows + 4) " type to filter   Up/Down move   Tab new/resume   ${modeKeyPick}Enter select   Esc back" 'DarkGray' }

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') { if ($onPin) { } elseif ($sel -gt 0) { $sel-- } elseif ($pin -eq 1) { $onPin = $true } }
            elseif ($key.Key -eq 'DownArrow') { if ($onPin) { if ($view.Count -gt 0) { $onPin = $false; $sel = 0 } } elseif ($sel -lt $view.Count - 1) { $sel++ } }
            elseif ($key.Key -eq 'Tab') { if ($mode -eq 'new') { $mode = 'resume' } elseif ($mode -eq 'resume') { $mode = 'new' } }
            elseif ($key.Key -eq 'Backspace') { if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0; $onPin = $false } }
            elseif ($key.Key -eq 'Escape') { Close-Region; return $null }
            elseif ($key.Key -eq 'Enter') {
                if ($onPin) { Close-Region; return @{ NewProject = $true } }
                if ($view.Count -gt 0) { Close-Region; return @{ Item = $view[$sel]; Mode = $mode } }
            }
            elseif ("$($key.KeyChar)" -ceq 'M' -and $mode -ne 'pick' -and $agentModes.Count -gt 1) { [void](Step-AgentMode) }
            elseif ("$($key.KeyChar)" -match '^[A-Za-z0-9._ -]$') { $filter += $key.KeyChar; $sel = 0; $onPin = $false }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- The session list. Returns @{ Item; Other } (Other: Tab, pick another folder), or
# $null on Esc. Filters on title and folder.
function Show-SessionPicker {
    $rows = [Math]::Max(3, [Math]::Min(15, [Console]::WindowHeight - 8))
    Open-Region ($rows + 5)
    $filter = ''
    $sel = 0
    $offset = 0
    $Items = $null
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            # (Re)load the selected mode's list: on entry, and after Shift+M.
            if ($null -eq $Items) {
                $Items = Get-ModeSessions
                $now = [DateTime]::UtcNow
                foreach ($it in $Items) {
                    $it | Add-Member -NotePropertyName Folder -NotePropertyValue (Format-SessionFolder $it.Cwd $root) -Force
                    $it | Add-Member -NotePropertyName Age -NotePropertyValue (Format-Age ($now - $it.Modified).TotalSeconds) -Force
                }
            }
            $view = @($Items | Where-Object { $filter -eq '' -or $_.Title.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Folder.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            if ($sel -ge $view.Count) { $sel = [Math]::Max(0, $view.Count - 1) }
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge $offset + $rows) { $offset = $sel - $rows + 1 }
            Write-ModeLine 'Shift+M: next mode'
            Write-Row 0 (" $Agent  -  RESUME a chat from any folder".PadRight(44) + '(Tab: reopen in another folder)') 'Yellow'
            Write-Row 1 ''
            for ($r = 0; $r -lt $rows; $r++) {
                $i = $offset + $r
                if ($i -lt $view.Count) {
                    $it = $view[$i]
                    $text = '{0,-50} {1,-24} {2,4}  {3}' -f $it.Title, $it.Folder, $it.Age, $it.Branch
                    if ($i -eq $sel) { Write-Row (2 + $r) (" > $text") 'White' } else { Write-Row (2 + $r) ("   $text") 'DarkGray' }
                } else {
                    Write-Row (2 + $r) ''
                }
            }
            $more = $view.Count - ($offset + $rows)
            if ($more -gt 0) { Write-Row ($rows + 2) "   ... $more more" 'DarkGray' }
            elseif ($Items.Count -eq 0) { Write-Row ($rows + 2) "   no chats in this mode's store" 'DarkGray' }
            elseif ($view.Count -eq 0) { Write-Row ($rows + 2) '   no match' 'DarkGray' }
            else { Write-Row ($rows + 2) '' }
            Write-Row ($rows + 3) " filter: ${filter}_" 'Green'
            Write-Row ($rows + 4) " type to filter   Up/Down move   Enter reopen in its folder   Tab another folder   ${modeKeyPick}Esc back" 'DarkGray'

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') { if ($sel -gt 0) { $sel-- } }
            elseif ($key.Key -eq 'DownArrow') { if ($sel -lt $view.Count - 1) { $sel++ } }
            elseif ($key.Key -eq 'Backspace') { if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1); $sel = 0 } }
            elseif ($key.Key -eq 'Escape') { Close-Region; return $null }
            elseif ($key.Key -eq 'Enter') { if ($view.Count -gt 0) { Close-Region; return @{ Item = $view[$sel]; Other = $false } } }
            elseif ($key.Key -eq 'Tab') { if ($view.Count -gt 0) { Close-Region; return @{ Item = $view[$sel]; Other = $true } } }
            elseif ("$($key.KeyChar)" -ceq 'M' -and $agentModes.Count -gt 1) { if (Step-AgentMode) { $Items = $null; $sel = 0; $offset = 0 } }
            elseif ("$($key.KeyChar)" -match '^[A-Za-z0-9._ -]$') { $filter += $key.KeyChar; $sel = 0 }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

# --- Home screen loop: Project and the session list open a second view, and Esc there
# comes back.
$launchDir = $null
$launchMode = $null
$sessionId = $null
while ($true) {
    $pick = Show-HomeMenu
    if ($null -eq $pick) { return }
    if ($pick -eq 'root') { $launchDir = $root; $launchMode = 'new'; break }
    if ($pick -eq 'home') { $launchDir = $HOME; $launchMode = 'new'; break }
    if ($pick -eq 'resume' -and $sessionKind) {
        if ((Get-ModeSessions).Count -gt 0) {
            $chosen = $null
            while ($true) {
                $s = Show-SessionPicker
                if ($null -eq $s) { break }
                if (-not $s.Other) { $chosen = @{ Dir = $s.Item.Cwd; Id = $s.Item.Id }; break }
                if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
                $f = Show-ProjectPicker (Get-ProjectList $root) $s.Item.Title
                if ($null -ne $f -and $f.Item) { $chosen = @{ Dir = $f.Item.Path; Id = $s.Item.Id }; break }
            }
            if ($null -eq $chosen) { continue }
            $launchDir = $chosen.Dir; $launchMode = 'resume'; $sessionId = $chosen.Id
            break
        }
    }
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

if ($sessionId) { $line = Get-SessionResumeCommand $config $Agent $sessionId $agentMode }
else { $line = Get-AgentCommand $config $Agent $launchMode $agentMode }
if ($null -eq $line) { Write-Host "agent-menu: the '$Agent' block in $configPath has no '$launchMode' line" -ForegroundColor Yellow; return }
if ($NoLaunch) {
    if ($agentMode) { Write-Host "agent-menu: mode $agentMode" }
    Write-Host "agent-menu: would run, in ${launchDir}:"
    Write-Host "  $line"
    return
}
Set-Location -LiteralPath $launchDir
if ($agentMode) { Write-Host "[$agentMode] " -ForegroundColor (Get-ModeColor) -NoNewline }
Write-Host "$launchDir> $line" -ForegroundColor DarkGray
Invoke-Expression $line
