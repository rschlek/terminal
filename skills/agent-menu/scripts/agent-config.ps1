<#
.SYNOPSIS
  agent-config - the shared reader for the agent menu's per-user config file
  (agents.yaml), dot-sourced by agent-menu.ps1, by the setup script and by the
  new-warp-chat launcher. Defines functions only; running it does nothing.

.DESCRIPTION
  THE FILE. <AGENT_MENU_DIR>\agents.yaml, where AGENT_MENU_DIR defaults to
  %LOCALAPPDATA%\agent-menu on Windows (${XDG_CONFIG_HOME:-~/.config}/agent-menu
  on macOS and Linux, see agent-menu.sh). It survives plugin updates because it
  never lives inside the plugin directory.

  THE FORMAT is deliberately flat, so it parses line by line with no YAML library:
    - top-level `key: value` lines (e.g. projects_root);
    - an agent block: `name:` alone on a line, then indented (two spaces by
      convention) `key: value` lines (args, new, resume, resume_all);
    - blank lines and lines whose first non-blank character is # are skipped.
  A value is everything after `key:` and its following spaces, VERBATIM to the
  end of the line (trailing whitespace dropped). Quotes are kept and a # is part
  of the value - there are no inline comments. The one exception is
  projects_root, a path: surrounding quotes are removed and a leading ~ expands.
  The optional top-level start_in (home | projects_root, default home) picks the
  menu's first entry; see Get-HomeEntries.

  `{args}` in a block's command lines is replaced by the block's `args` value;
  when args is empty the placeholder and the spaces before it are removed, so
  `claude {args} --resume` becomes `claude --resume`.

  This file also holds the project listing (the menu's Project view) and the
  recent-projects state file, so both are testable without the key loop.
#>

# --- Where the per-user files live. One rule; AGENT_MENU_DIR overrides it (tests).
function Get-AgentMenuDir {
    if ($env:AGENT_MENU_DIR) { return $env:AGENT_MENU_DIR }
    return (Join-Path $env:LOCALAPPDATA 'agent-menu')
}

# --- Parse agents.yaml. Returns @{ Top = @{key=value}; Blocks = @{name=@{key=value}} },
# or $null when the file does not exist. Keys compare case-insensitively.
function Read-AgentConfig([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $top = @{}
    $blocks = @{}
    $current = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
        $line = $raw.TrimEnd()
        if ($line.Trim() -eq '' -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '^([A-Za-z0-9_.-]+):(?:\s+(.*))?$') {
            $key = $Matches[1]
            $value = if ($Matches[2]) { $Matches[2] } else { '' }
            $top[$key] = $value
            # A bare `name:` opens an agent block; a top-level line with a value closes one.
            if ($value -eq '') {
                $current = @{}
                $blocks[$key] = $current
            } else {
                $current = $null
            }
        } elseif ($line -match '^[ \t]+([A-Za-z0-9_.-]+):(?:\s+(.*))?$' -and $null -ne $current) {
            $current[$Matches[1]] = if ($Matches[2]) { $Matches[2] } else { '' }
        } else {
            Write-Warning "agent-config: ignoring a line in $Path that is neither 'key: value' nor a two-space-indented block line: $line"
        }
    }
    return @{ Top = $top; Blocks = $blocks }
}

# --- The configured projects root, or '' when unset.
function Get-ProjectsRoot($Config) {
    if ($null -eq $Config -or -not $Config.Top.ContainsKey('projects_root')) { return '' }
    $v = $Config.Top['projects_root'].Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    if ($v -eq '~' -or $v.StartsWith('~/') -or $v.StartsWith('~\')) { $v = $HOME + $v.Substring(1) }
    return $v
}

# --- The home screen's entries, in order, as @{ Key; Dir }: root (a fresh session in
# the projects root), home, project, resume. The root entry is there only when
# `start_in: projects_root` is set and the root exists; it then comes first, so it is
# the one selected when the menu opens. Without the key the menu is home, project, resume.
function Get-HomeEntries($Config) {
    $root = Get-ProjectsRoot $Config
    $entries = @()
    $startIn = ''
    if ($null -ne $Config -and $Config.Top.ContainsKey('start_in')) { $startIn = $Config.Top['start_in'].Trim() }
    if ($startIn -eq 'projects_root' -and $root -and (Test-Path -LiteralPath $root -PathType Container)) {
        $entries += @{ Key = 'root'; Dir = $root }
    }
    $entries += @{ Key = 'home'; Dir = $HOME }
    $entries += @{ Key = 'project'; Dir = $root }
    $entries += @{ Key = 'resume'; Dir = $HOME }
    return , $entries
}

# --- The composed command line for one agent and mode (new | resume | resume_all),
# or $null when the config has no such block or line. resume_all falls back to
# resume; a block with no `new` line launches the bare agent name plus args.
function Get-AgentCommand($Config, [string]$Agent, [string]$Mode) {
    if ($null -eq $Config -or -not $Config.Blocks.ContainsKey($Agent)) { return $null }
    $block = $Config.Blocks[$Agent]
    $line = $null
    if ($block.ContainsKey($Mode)) { $line = $block[$Mode] }
    elseif ($Mode -eq 'resume_all' -and $block.ContainsKey('resume')) { $line = $block['resume'] }
    elseif ($Mode -eq 'new') { $line = "$Agent {args}" }
    if ($null -eq $line -or $line.Trim() -eq '') { return $null }
    $argsValue = ''
    if ($block.ContainsKey('args')) { $argsValue = $block['args'] }
    if ($argsValue -eq '') {
        $line = $line -replace '\s*\{args\}', ''
    } else {
        $line = $line.Replace('{args}', $argsValue)
    }
    return $line.Trim()
}

# --- One top-level scalar from a project.yaml: tolerates a trailing # comment,
# single or double quotes, and a folded (>) or literal (|) block scalar, whose
# indented lines are joined with spaces. '' when the key is absent.
function Get-YamlField([string[]]$Lines, [string]$Name) {
    $pattern = '^' + [regex]::Escape($Name) + ':(?:\s+(.*))?$'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch $pattern) { continue }
        $v = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
        if ($v.StartsWith('"')) {
            $m = [regex]::Match($v, '^"((?:[^"\\]|\\.)*)"')
            if ($m.Success) { return ($m.Groups[1].Value -replace '\\(.)', '$1') }
            return $v.Substring(1)
        }
        if ($v.StartsWith("'")) {
            $m = [regex]::Match($v, "^'((?:[^']|'')*)'")
            if ($m.Success) { return $m.Groups[1].Value.Replace("''", "'") }
            return $v.Substring(1)
        }
        $v = ($v -replace '(^|\s+)#.*$', '').Trim()
        if ($v -match '^[>|][+-]?[0-9]?$' -or $v -eq '') {
            $parts = @()
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j].Trim() -eq '') { continue }
                if ($Lines[$j] -notmatch '^\s') { break }
                $parts += $Lines[$j].Trim()
            }
            return ($parts -join ' ')
        }
        return $v
    }
    return ''
}

# --- The recent-projects state file: one `<unix-seconds><TAB><full path>` line
# per project, most recently opened first. File order is the sort order.
function Get-RecentStatePath { return (Join-Path (Get-AgentMenuDir) 'recent.tsv') }

function Read-RecentProjects {
    $path = Get-RecentStatePath
    $list = @()
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $cols = $line -split "`t", 2
            if ($cols.Count -eq 2 -and $cols[1] -ne '') { $list += $cols[1] }
        }
    }
    return , $list
}

function Save-RecentProject([string]$ProjectPath) {
    $path = Get-RecentStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $stamp = [int64]([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds
    $lines = @("$stamp`t$ProjectPath")
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $cols = $line -split "`t", 2
            if ($cols.Count -eq 2 -and $cols[1] -ne '' -and $cols[1] -ine $ProjectPath) { $lines += $line }
        }
    }
    if ($lines.Count -gt 200) { $lines = $lines[0..199] }
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

# --- The Project view's rows: every directory directly under the root (dot-folders
# skipped), recently opened first in state-file order, then the rest by name.
# Each row carries Name, Path, Scope and Summary (the last two from project.yaml).
function Get-ProjectList([string]$Root) {
    $rows = @()
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return , $rows }
    $recent = Read-RecentProjects
    foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name.StartsWith('.')) { continue }
        $scope = ''
        $summary = ''
        $yaml = Join-Path $d.FullName 'project.yaml'
        if (Test-Path -LiteralPath $yaml) {
            $lines = [System.IO.File]::ReadAllLines($yaml)
            $scope = Get-YamlField $lines 'scope'
            $summary = Get-YamlField $lines 'summary'
        }
        $rank = [int]::MaxValue
        for ($k = 0; $k -lt $recent.Count; $k++) {
            if ($recent[$k] -ieq $d.FullName) { $rank = $k; break }
        }
        $rows += [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Scope = $scope; Summary = $summary; Rank = $rank }
    }
    $sorted = @($rows | Sort-Object Rank, Name)
    return , $sorted
}
