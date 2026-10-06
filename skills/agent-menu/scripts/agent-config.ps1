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
  menu's first entry and the folder Resume opens in; see Get-HomeEntries.

  `{args}` in a block's command lines is replaced by the block's `args` value;
  when args is empty the placeholder and the spaces before it are removed, so
  `claude {args} --resume` becomes `claude --resume`.

  An agent block may carry `session_list` (claude | off): with `claude` the menu's
  Resume lists past chats from every folder, read from Claude Code's session
  store; a block named `claude` gets it by default, every other block `off`.

  This file also holds the project listing (the menu's Project view), the
  recent-projects state file, the session list and the self-refresh, so all of
  them are testable without the key loop.
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

# --- The home screen's entries, in order, as @{ Key; Dir }. Without `start_in:
# projects_root` the menu is home, project, resume, with resume in the home folder.
# With the key set and an existing projects root it is root (a fresh session in the
# projects root), project, resume, home: everything in the projects root together and
# home last. Root comes first, so it is the one selected when the menu opens, and resume
# opens in the projects root too, where those sessions were started.
function Get-HomeEntries($Config) {
    $root = Get-ProjectsRoot $Config
    $startIn = ''
    if ($null -ne $Config -and $Config.Top.ContainsKey('start_in')) { $startIn = $Config.Top['start_in'].Trim() }
    if ($startIn -eq 'projects_root' -and $root -and (Test-Path -LiteralPath $root -PathType Container)) {
        $entries = @(
            @{ Key = 'root'; Dir = $root },
            @{ Key = 'project'; Dir = $root },
            @{ Key = 'resume'; Dir = $root },
            @{ Key = 'home'; Dir = $HOME }
        )
    } else {
        $entries = @(
            @{ Key = 'home'; Dir = $HOME },
            @{ Key = 'project'; Dir = $root },
            @{ Key = 'resume'; Dir = $HOME }
        )
    }
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

# --- The session list: past chats from every folder, for an agent whose block turns it
# on. `session_list: claude` reads Claude Code's on-disk session store; `off` (or any
# other value) keeps the agent's own resume command. With no key, a block named `claude`
# gets `claude` and every other block gets `off`, so existing configs need no change.
function Get-SessionListKind($Config, [string]$Agent) {
    if ($null -eq $Config -or -not $Config.Blocks.ContainsKey($Agent)) { return '' }
    $block = $Config.Blocks[$Agent]
    if ($block.ContainsKey('session_list')) { $kind = $block['session_list'].Trim() }
    elseif ($Agent -eq 'claude') { $kind = 'claude' }
    else { $kind = 'off' }
    if ($kind -eq 'claude') { return 'claude' }
    return ''
}

# Claude Code keeps one <session-id>.jsonl per chat under <config dir>\projects\<folder>,
# where the config dir is CLAUDE_CONFIG_DIR or ~\.claude. The folder name encodes the
# chat's working folder lossily, so the real folder is read from the file instead.
function Get-ClaudeProjectsDir {
    if ($env:CLAUDE_CONFIG_DIR) { return (Join-Path $env:CLAUDE_CONFIG_DIR 'projects') }
    return (Join-Path $HOME '.claude\projects')
}

# A JSON string body (the text between the quotes) decoded: \" \\ \/ kept as the
# character, \n \r \t \b \f and control-character \u escapes become a space.
function ConvertFrom-JsonStringBody([string]$Text) {
    if ($Text.IndexOf('\') -lt 0) { return $Text }
    $eval = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $e = $m.Groups[1].Value
        if ($e.Length -eq 5) {
            $code = [Convert]::ToInt32($e.Substring(1), 16)
            if ($code -lt 32) { return ' ' }
            return [string][char]$code
        }
        if ($e -ceq 'u') { return '?' }
        if ('nrtbf'.IndexOf($e) -ge 0) { return ' ' }
        return $e
    }
    return [regex]::Replace($Text, '\\(u[0-9a-fA-F]{4}|.)', $eval)
}

# A title for one row: whitespace runs collapsed, cut to 60 characters.
function Format-SessionTitle([string]$Text) {
    $t = ($Text -replace '[ \t]+', ' ').Trim(' ')
    if ($t.Length -gt 60) { $t = $t.Substring(0, 57) + '...' }
    return $t
}

# Relative age: now, 12m, 5h, 3d, then weeks.
function Format-Age([double]$Seconds) {
    if ($Seconds -lt 60) { return 'now' }
    if ($Seconds -lt 3600) { return ('{0}m' -f [Math]::Floor($Seconds / 60)) }
    if ($Seconds -lt 86400) { return ('{0}h' -f [Math]::Floor($Seconds / 3600)) }
    if ($Seconds -lt 14 * 86400) { return ('{0}d' -f [Math]::Floor($Seconds / 86400)) }
    return ('{0}w' -f [Math]::Floor($Seconds / 604800))
}

# Path containment, either separator, case-insensitive: the folder itself or below it.
function Test-PathUnder([string]$Path, [string]$Dir) {
    if (-not $Path -or -not $Dir) { return $false }
    $p = $Path.Replace('/', '\').TrimEnd('\')
    $d = $Dir.Replace('/', '\').TrimEnd('\')
    if ($d -eq '') { return $false }
    return ($p -ieq $d) -or $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Sessions that run in throwaway folders are left out: the temp folders (AGENT_MENU_TEMP_DIR
# replaces them, for tests) and the Windows system folder.
function Test-SkippedSessionFolder([string]$Cwd) {
    if ($env:AGENT_MENU_TEMP_DIR) { $temps = @($env:AGENT_MENU_TEMP_DIR) }
    else {
        $temps = @($env:TEMP, $env:TMP, [System.IO.Path]::GetTempPath())
        if ($Cwd -match '[\\/]AppData[\\/]Local[\\/]Temp([\\/]|$)') { return $true }
    }
    foreach ($t in $temps) { if ($t -and (Test-PathUnder $Cwd $t)) { return $true } }
    if ($env:SystemRoot -and (Test-PathUnder $Cwd $env:SystemRoot)) { return $true }
    return $false
}

# Read part of a file that may still be written to; '' when it cannot be read.
function Read-FileBytes([string]$Path, [long]$Offset, [int]$Count) {
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($Offset -gt 0) { [void]$fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) }
        $buf = New-Object byte[] $Count
        $n = 0
        while ($n -lt $Count) {
            $r = $fs.Read($buf, $n, $Count - $n)
            if ($r -le 0) { break }
            $n += $r
        }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# One session file, head and tail only: @{ Cwd; Branch; Title; HasUser }, or $null when
# the head has no working folder. The ORIGINAL folder is the first "cwd" in the file (a
# chat resumed elsewhere records later lines with the new folder). The first 40 lines of
# the first 256 KB are read (4 MB when no folder turns up in those), and the last 64 KB.
# Title: the last ai-title in the tail, else the last last-prompt, else the first user
# message's text (a string or the first text block of an array).
function Read-ClaudeSession([string]$Path) {
    $len = (Get-Item -LiteralPath $Path).Length
    $cwd = $null; $branch = ''; $userText = $null; $hasUser = $false
    foreach ($limit in @(262144, 4194304)) {
        $head = Read-FileBytes $Path 0 ([int][Math]::Min($len, $limit))
        $lines = $head -split "`n"
        if ($len -gt $limit -and $lines.Count -gt 1) { $lines = $lines[0..($lines.Count - 2)] }     # drop a cut last line
        $n = [Math]::Min(40, $lines.Count)
        for ($i = 0; $i -lt $n; $i++) {
            $line = $lines[$i]
            if ($null -eq $cwd) {
                $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
                if ($m.Success) {
                    $cwd = ConvertFrom-JsonStringBody $m.Groups[1].Value
                    $b = [regex]::Match($line, '"gitBranch":"((?:[^"\\]|\\.)*)"')
                    if ($b.Success) { $branch = ConvertFrom-JsonStringBody $b.Groups[1].Value }
                }
            }
            if ($null -eq $userText -and $line.Contains('"type":"user"')) {
                $u = [regex]::Match($line, '"message":\{"role":"user","content":')
                if ($u.Success) {
                    $hasUser = $true
                    $rest = $line.Substring($u.Index + $u.Length)
                    $s = [regex]::Match($rest, '^"((?:[^"\\]|\\.)*)"')
                    if (-not $s.Success) { $s = [regex]::Match($rest, '"type":"text","text":"((?:[^"\\]|\\.)*)"') }
                    if ($s.Success) { $userText = ConvertFrom-JsonStringBody $s.Groups[1].Value }
                }
            }
            if ($null -ne $cwd -and $null -ne $userText) { break }
        }
        if ($null -ne $cwd -or $len -le $limit) { break }
    }
    if ($null -eq $cwd) { return $null }
    $tailStart = [Math]::Max(0, $len - 65536)
    $tail = Read-FileBytes $Path $tailStart ([int]($len - $tailStart))
    if (-not $hasUser -and $tail.Contains('"type":"user"')) { $hasUser = $true }
    $title = ''
    $t = [regex]::Matches($tail, '(?m)^\{"type":"ai-title","aiTitle":"((?:[^"\\\n]|\\.)*)"')
    if ($t.Count -gt 0) { $title = ConvertFrom-JsonStringBody $t[$t.Count - 1].Groups[1].Value }
    if (($title -replace '\s', '') -eq '') {
        $t = [regex]::Matches($tail, '(?m)^\{"type":"last-prompt","lastPrompt":"((?:[^"\\\n]|\\.)*)"')
        if ($t.Count -gt 0) { $title = ConvertFrom-JsonStringBody $t[$t.Count - 1].Groups[1].Value }
    }
    if (($title -replace '\s', '') -eq '' -and $null -ne $userText) { $title = $userText }
    $title = Format-SessionTitle $title
    if ($title -eq '') { $title = '(untitled)' }
    if ($branch -eq 'HEAD') { $branch = '' }
    return @{ Cwd = $cwd; Branch = $branch; Title = $title; HasUser = $hasUser }
}

# The session list, newest first by file time, at most $Max rows: Id, Cwd, Branch,
# Title, Modified (UTC). Only <projects>\<folder>\<id>.jsonl files count (subfolders, where
# subagent transcripts live, are never entered). A file is left out when it has no user
# message, no working folder, a folder that no longer exists, or a throwaway folder.
function Get-ClaudeSessions([string]$ProjectsDir, [int]$Max = 40) {
    $rows = @()
    if (-not $ProjectsDir -or -not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) { return , $rows }
    $files = @(foreach ($d in Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue) {
        Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.jsonl' }
    })
    $files = @($files | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($f in $files) {
        if ($rows.Count -ge $Max) { break }
        $id = $f.BaseName
        if ($id -notmatch '^[A-Za-z0-9._-]+$') { continue }
        $s = $null
        try { $s = Read-ClaudeSession $f.FullName } catch { $s = $null }
        if ($null -eq $s -or -not $s.HasUser) { continue }
        if (Test-SkippedSessionFolder $s.Cwd) { continue }
        if (-not (Test-Path -LiteralPath $s.Cwd -PathType Container)) { continue }
        $rows += [pscustomobject]@{ Id = $id; Cwd = $s.Cwd; Branch = $s.Branch; Title = $s.Title; Modified = $f.LastWriteTimeUtc }
    }
    return , $rows
}

# The Project column: the folder relative to the projects root when under it, else the
# full path (the root itself shows as its full path).
function Format-SessionFolder([string]$Cwd, [string]$Root) {
    if ($Root -and (Test-PathUnder $Cwd $Root)) {
        $rel = $Cwd.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/')
        if ($rel -ne '') { return $rel }
    }
    return $Cwd
}

# The line that reopens one chat: the agent's `resume` line with the session id appended.
function Get-SessionResumeCommand($Config, [string]$Agent, [string]$SessionId) {
    $line = Get-AgentCommand $Config $Agent 'resume'
    if ($null -eq $line) { return $null }
    return "$line $SessionId"
}

# --- Self-refresh. Setup writes plugin-source.txt next to the installed scripts:
#   plugin: <the plugin folder the scripts were copied from>
#   name: <the plugin's name>       version: <its version>
# At start the installed menu looks for a newer copy of that plugin: the recorded folder
# itself (updated in place), and, when the folder is named after its version (a plugin
# cache keeps one folder per version), its sibling version folders. The newest one whose
# manifest names the same plugin and is newer than the recorded version wins.
function Get-PluginManifest([string]$PluginRoot) {
    foreach ($rel in @('.claude-plugin\plugin.json', '.codex-plugin\plugin.json')) {
        $p = Join-Path $PluginRoot $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $text = [System.IO.File]::ReadAllText($p)
            $v = [regex]::Match($text, '"version"\s*:\s*"([^"]*)"')
            $n = [regex]::Match($text, '"name"\s*:\s*"([^"]*)"')
            if ($v.Success) { return @{ Version = $v.Groups[1].Value; Name = $(if ($n.Success) { $n.Groups[1].Value } else { '' }) } }
        }
    }
    return $null
}

# Compare two dotted versions numerically (1.10.0 > 1.9.9): 1, 0 or -1; 0 when either is
# not a version. A suffix after the numbers (-beta, +sha) is ignored.
function Compare-PluginVersion([string]$A, [string]$B) {
    $ma = [regex]::Match("$A", '^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    $mb = [regex]::Match("$B", '^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $ma.Success -or -not $mb.Success) { return 0 }
    for ($g = 1; $g -le 3; $g++) {
        $x = 0; $y = 0
        if ($ma.Groups[$g].Success) { $x = [int64]$ma.Groups[$g].Value }
        if ($mb.Groups[$g].Success) { $y = [int64]$mb.Groups[$g].Value }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# The newest plugin folder for a record, as @{ Root; Version; Name }, or $null when none
# is newer than the recorded version. $Script is the file a candidate must ship.
function Find-NewerPlugin([string]$Root, [string]$Name, [string]$Version, [string]$Script) {
    $candidates = @()
    if (Test-Path -LiteralPath $Root -PathType Container) { $candidates += $Root }
    $leaf = Split-Path -Leaf $Root
    $parent = Split-Path -Parent $Root
    if ($leaf -match '^v?\d+\.\d+' -and $parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
        foreach ($d in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name -match '^v?\d+\.\d+' -and $d.FullName -ine $Root) { $candidates += $d.FullName }
        }
    }
    $best = $null
    $bestVersion = $Version
    foreach ($c in $candidates) {
        $m = Get-PluginManifest $c
        if ($null -eq $m) { continue }
        if ($Name -and $m.Name -and $m.Name -ne $Name) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $c $Script) -PathType Leaf)) { continue }
        if ((Compare-PluginVersion $m.Version $bestVersion) -gt 0) {
            $best = @{ Root = $c; Version = $m.Version; Name = $m.Name }
            $bestVersion = $m.Version
        }
    }
    return $best
}

function Write-PluginSourceRecord([string]$MenuDir, [string]$PluginRoot, [string]$Name, [string]$Version) {
    $lines = @(
        '# Written by the agent-menu setup: the plugin folder these scripts came from. The menu',
        '# refreshes itself from a newer copy of that plugin. Safe to delete.',
        "plugin: $PluginRoot", "name: $Name", "version: $Version"
    )
    [System.IO.File]::WriteAllText((Join-Path $MenuDir 'plugin-source.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Refresh the scripts in $MenuDir from a newer plugin. $true when they were replaced (the
# caller then runs the new copy); $false when there is no record, nothing newer, or any
# step fails - the menu then runs as it is, without a message.
function Update-InstalledMenu([string]$MenuDir) {
    try {
        $recordPath = Join-Path $MenuDir 'plugin-source.txt'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $false }
        $rec = Read-AgentConfig $recordPath
        $root = '' + $rec.Top['plugin']; $version = '' + $rec.Top['version']; $name = '' + $rec.Top['name']
        if (-not $root -or -not $version) { return $false }
        $scripts = 'skills\agent-menu\scripts'
        $newer = Find-NewerPlugin $root $name $version "$scripts\agent-menu.ps1"
        if ($null -eq $newer) { return $false }
        foreach ($f in @('agent-config.ps1', 'agent-menu.ps1')) {
            $src = Join-Path (Join-Path $newer.Root $scripts) $f
            $tmp = Join-Path $MenuDir "$f.new"
            Copy-Item -LiteralPath $src -Destination $tmp -Force
            Move-Item -LiteralPath $tmp -Destination (Join-Path $MenuDir $f) -Force
        }
        Write-PluginSourceRecord $MenuDir $newer.Root $newer.Name $newer.Version
        return $true
    } catch {
        return $false
    }
}
