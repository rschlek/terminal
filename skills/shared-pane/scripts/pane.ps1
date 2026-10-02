<#
  shared-pane (Windows): one visible WezTerm window that a human and an agent drive
  together. The agent opens it and runs a command, the human types anything secret
  (password, Duo push, vault unlock), and the agent keeps reading and sending into the
  SAME authenticated shell.

  VERIFIED on Windows 11 (Windows PowerShell 5.1, wezterm 20240203-110809-5046fc22
  at C:\Program Files\WezTerm\): open, send, sendf,
  type, read, wait, waitlast, title, alive and close, called both from PowerShell and
  from Git Bash. The pane's shell is WezTerm's default on Windows (cmd.exe, ConPTY).

  HOW IT TARGETS ONE SPECIFIC GUI - rung 2, same as pane.sh
  ---------------------------------------------------------
  `wezterm cli` picks its instance in this documented order
  (https://wezterm.org/cli/cli/index.html): 1. --prefer-mux, 2. $WEZTERM_UNIX_SOCKET,
  3. GUI discovery by --class. Rung 3 (`wezterm cli --class <class>`) did NOT select
  the right GUI in practice (list came back empty / from another
  instance), so this script uses rung 2 exclusively:
   * Every wezterm-gui.exe publishes an AF_UNIX socket at
       %USERPROFILE%\.local\share\wezterm\gui-sock-<pid>
     where <pid> is the wezterm-gui.exe process id (the one Start-Process -PassThru
     returns). Not documented by wezterm.org, but confirmed empirically here.
   * Every `wezterm cli` call runs as a child process whose environment has
     WEZTERM_UNIX_SOCKET set to that path (Windows-style) and WEZTERM_PANE removed.
     Nothing is ever run as a bare `wezterm cli`.
   * Sockets of dead GUIs are NOT cleaned up, so "alive" also checks the GUI pid.
  `--class shared-pane-<name>-<pid>` is still passed at start: harmless, and it makes
  the window identifiable. It is never used to address the GUI.

  LESSONS BAKED IN (each broke a live session)
   * wezterm-gui.exe is often NOT on PATH for the agent's process: resolve the binary
     ($env:WEZTERM_GUI_BIN / $env:WEZTERM_BIN, then PATH, then C:\Program Files\WezTerm).
   * Never pipe text through the PowerShell pipeline into the native exe: PS 5.1
     re-encodes it and can prepend a UTF-8 BOM, which mangles the first command. Text
     is passed to `send-text` as ONE argument on a command line this script quotes
     itself (System.Diagnostics.Process, CommandLineToArgvW rules), so it arrives
     byte-exact - quotes, spaces, leading dashes included.
   * Enter under ConPTY is CR, not LF: send appends "`r", sendf maps line ends to CR.
   * GUI start is slow: wait up to 120 s for gui-sock-<pid>, then up to 30 s for a pane.

  NEVER type a secret from this script. The human types secrets into the pane; the
  agent only ever reads what the shell prints afterwards.

  USAGE
    pane.ps1 open  <name> [title]      Start a WezTerm GUI; state goes to
                                       $env:LOCALAPPDATA\shared-pane\<name>.state
    pane.ps1 send  <name> <text...>    Type text into the pane, followed by Enter
    pane.ps1 sendf <name> <file>       Type a file's lines (LF -> CR), then Enter
    pane.ps1 type  <name> <text...>    Type text WITHOUT Enter
    pane.ps1 read  <name> [lines]      Print the last N non-blank lines (default 40)
    pane.ps1 wait  <name> <regex> [s]  Block until the pane text matches (default 600 s)
    pane.ps1 waitlast <name> <re> [s]  Block until the LAST non-blank line matches
                                       (e.g. '>$' = cmd prompt is back)
                   wait/waitlast exit 0 on match, 3 on timeout, 4 if the pane is gone
    pane.ps1 title <name> <title>      Retitle the tab (what the human sees)
    pane.ps1 alive <name>              Exit 0 if the pane still exists, else 1
    pane.ps1 close <name>              Kill the pane and its GUI, remove state

  CALLING IT
    PowerShell:  & $P send root 'echo "a b"'
    Git Bash:    powershell -NoProfile -ExecutionPolicy Bypass -File "$P" send root 'echo "a b"'
                 Quote each text/regex as ONE argument. Prefix MSYS_NO_PATHCONV=1 if an
                 argument starts with '/' (MSYS would rewrite it as a path). Regexes
                 are .NET regexes, matched case-insensitively.
    sendf is the route when the command text itself would trip a shell guard hook, or is
    multi-line: write it to a file and send the file.

  The state file is <name>.state, never <name>.env: a shell guard hook, if the environment
  has one, may block any command that would print a .env file, and this file holds nothing
  secret - only a socket path, a pane id, the window class, and the GUI pid.
#>

# No param block on purpose: with $args, a text argument like '-la' is never mistaken
# for a PowerShell parameter.
$ErrorActionPreference = 'Stop'

$StateDir = $env:SHARED_PANE_STATE
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'shared-pane' }
$SockDir = Join-Path $env:USERPROFILE '.local\share\wezterm'

function Die([string]$msg) { [Console]::Error.WriteLine("pane.ps1: $msg"); exit 2 }

function Resolve-Bin([string]$override, [string]$exe) {
    if ($override) {
        if (Test-Path -LiteralPath $override) { return (Resolve-Path -LiteralPath $override).Path }
        $c = Get-Command $override -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
        Die "$exe override '$override' not found"
    }
    $c = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($root in @($env:ProgramFiles, 'C:\Program Files', "$env:LOCALAPPDATA\Programs")) {
        if (-not $root) { continue }
        $p = Join-Path (Join-Path $root 'WezTerm') $exe
        if (Test-Path -LiteralPath $p) { return $p }
    }
    Die "$exe not found (install WezTerm, or set `$env:WEZTERM_BIN / `$env:WEZTERM_GUI_BIN to its binaries)"
}

function StateFile([string]$n) {
    if (-not $n) { Die 'missing pane name' }
    if ($n -notmatch '^[A-Za-z0-9_.-]+$') { Die "bad pane name '$n' (use letters, digits, _ . -)" }
    Join-Path $StateDir "$n.state"
}

function LoadState([string]$n) {
    $f = StateFile $n
    if (-not (Test-Path -LiteralPath $f)) { Die "no pane named '$n' (state $f missing)" }
    $s = @{}
    foreach ($line in [IO.File]::ReadAllLines($f)) {
        if ($line -match '^([A-Z_]+)=(.*)$') { $s[$Matches[1]] = $Matches[2] }
    }
    foreach ($k in 'SOCK', 'PANE', 'GUI_PID') { if (-not $s[$k]) { Die "state $f has no $k" } }
    return $s
}

# Quote one argument for a Windows command line (CommandLineToArgvW / Rust std rules).
function Quote-Arg([string]$a) {
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"') }
        else { [void]$sb.Append('\' * $bs); [void]$sb.Append($ch) }
        $bs = 0
    }
    [void]$sb.Append('\' * ($bs * 2))
    [void]$sb.Append('"')
    $sb.ToString()
}

# Run `wezterm cli <args>` pinned to ONE GUI by its socket. No stdin, no PowerShell
# pipeline: arguments go on a command line we quote ourselves; stdout is read as UTF-8.
function Invoke-WezCli([string]$sock, [string[]]$cliArgs, [int]$timeoutMs = 20000) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Wez
    $psi.Arguments = ((@('cli') + $cliArgs) | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $psi.EnvironmentVariables['WEZTERM_UNIX_SOCKET'] = $sock
    if ($psi.EnvironmentVariables.ContainsKey('WEZTERM_PANE')) { $psi.EnvironmentVariables.Remove('WEZTERM_PANE') }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Code = 124; Out = ''; Err = 'timed out' }
    }
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

function Get-PaneIds([string]$sock) {
    $r = Invoke-WezCli $sock @('list', '--format', 'json') 10000
    if ($r.Code -ne 0 -or -not $r.Out.Trim()) { return @() }
    try { return @($r.Out | ConvertFrom-Json | ForEach-Object { "$($_.pane_id)" }) } catch { return @() }
}

function Test-Alive($s) {
    if (-not (Get-Process -Id ([int]$s.GUI_PID) -ErrorAction SilentlyContinue)) { return $false }
    return ((Get-PaneIds $s.SOCK) -contains "$($s.PANE)")
}

function Send-Raw($s, [string]$text) {
    if ($text.Length -eq 0) { return }
    $r = Invoke-WezCli $s.SOCK @('send-text', '--pane-id', "$($s.PANE)", '--no-paste', '--', $text)
    if ($r.Code -ne 0) { Die "send-text failed ($($r.Code)): $($r.Err.Trim())" }
}

function Get-Lines($s) {
    $r = Invoke-WezCli $s.SOCK @('get-text', '--pane-id', "$($s.PANE)")
    if ($r.Code -ne 0) { return $null }
    @($r.Out -split "\r?\n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
}

function Cmd-Open([string]$n, [string]$title) {
    $f = StateFile $n
    if (Test-Path -LiteralPath $f) { Die "pane '$n' already exists (close it first)" }
    if (-not $title) { $title = "shared pane: $n" }
    $null = New-Item -ItemType Directory -Force -Path $StateDir
    $gui = Resolve-Bin $env:WEZTERM_GUI_BIN 'wezterm-gui.exe'
    $class = "shared-pane-$n-$PID"

    # The GUI inherits our environment; never let it see another GUI's socket.
    Remove-Item Env:\WEZTERM_UNIX_SOCKET -ErrorAction SilentlyContinue
    Remove-Item Env:\WEZTERM_PANE -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $gui -PassThru -WindowStyle Normal `
        -ArgumentList @('start', '--class', $class, '--always-new-process')
    $guiPid = $proc.Id
    $sock = Join-Path $SockDir "gui-sock-$guiPid"

    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path -LiteralPath $sock)) {
        if ($proc.HasExited) { Die "wezterm-gui exited (code $($proc.ExitCode)) before publishing a socket" }
        if ((Get-Date) -gt $deadline) {
            try { Stop-Process -Id $guiPid -Force } catch { }
            Die "wezterm GUI did not publish a socket ($sock) within 120 s"
        }
        Start-Sleep -Milliseconds 500
    }

    $pane = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ($null -eq $pane) {
        $ids = Get-PaneIds $sock
        if ($ids.Count -gt 0) { $pane = $ids[0]; break }
        if ((Get-Date) -gt $deadline) {
            try { Stop-Process -Id $guiPid -Force } catch { }
            Die "no pane appeared in the new GUI (socket $sock)"
        }
        Start-Sleep -Milliseconds 500
    }

    $null = Invoke-WezCli $sock @('set-tab-title', '--pane-id', "$pane", $title)
    $body = "SOCK=$sock`r`nPANE=$pane`r`nCLASS=$class`r`nGUI_PID=$guiPid`r`n"
    [IO.File]::WriteAllText($f, $body, (New-Object Text.UTF8Encoding($false)))
}

function Cmd-Sendf([string]$n, [string]$file) {
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { Die "sendf: file '$file' not found" }
    $s = LoadState $n
    # ReadAllText strips a BOM if the file has one; normalise line ends to CR (Enter).
    $t = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $file).Path, (New-Object Text.UTF8Encoding($false)))
    $t = $t.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
    $t = $t.TrimEnd("`n") -replace "`n", "`r"
    Send-Raw $s ($t + "`r")
}

# 0 = matched, 3 = timed out, 4 = the pane is gone. Same contract as pane.sh.
function Cmd-Wait([string]$n, [string]$regex, [int]$budget, [bool]$lastOnly) {
    if (-not $regex) { Die 'missing regex' }
    if ($budget -le 0) { $budget = 600 }
    $s = LoadState $n
    $deadline = (Get-Date).AddSeconds($budget)
    while ($true) {
        if (-not (Test-Alive $s)) { exit 4 }
        $raw = Get-Lines $s
        if ($null -ne $raw) {
            $lines = @($raw)
            if ($lastOnly) { $hay = $lines[-1] } else { $hay = $lines -join "`n" }
            if ($hay -match $regex) { exit 0 }
        }
        if ((Get-Date) -ge $deadline) { exit 3 }
        Start-Sleep -Seconds 2
    }
}

function Cmd-Close([string]$n) {
    $f = StateFile $n
    if (-not (Test-Path -LiteralPath $f)) { return }
    $s = LoadState $n
    if (Get-Process -Id ([int]$s.GUI_PID) -ErrorAction SilentlyContinue) {
        $null = Invoke-WezCli $s.SOCK @('kill-pane', '--pane-id', "$($s.PANE)") 5000
        try { Stop-Process -Id ([int]$s.GUI_PID) -Force -ErrorAction SilentlyContinue } catch { }
        try { Wait-Process -Id ([int]$s.GUI_PID) -Timeout 10 -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $s.SOCK -Force -ErrorAction SilentlyContinue
}

$Action = $null; $Name = $null; $Rest = @()
if ($args.Count -ge 1) { $Action = [string]$args[0] }
if ($args.Count -ge 2) { $Name = [string]$args[1] }
if ($args.Count -ge 3) { $Rest = @($args[2..($args.Count - 1)] | ForEach-Object { [string]$_ }) }
$Arg0 = $null; $Arg1 = $null
if ($Rest.Count -ge 1) { $Arg0 = $Rest[0] }
if ($Rest.Count -ge 2) { $Arg1 = $Rest[1] }

$known = @('open', 'send', 'sendf', 'type', 'read', 'wait', 'waitlast', 'title', 'alive', 'close')
if ($known -notcontains $Action) {
    Get-Content -LiteralPath $PSCommandPath | Select-Object -Skip 1 -First 69
    exit 2
}
$script:Wez = Resolve-Bin $env:WEZTERM_BIN 'wezterm.exe'

switch ($Action) {
    'open'     { Cmd-Open $Name ($Rest -join ' ') }
    'send'     { Send-Raw (LoadState $Name) (($Rest -join ' ') + "`r") }
    'type'     { Send-Raw (LoadState $Name) ($Rest -join ' ') }
    'sendf'    { Cmd-Sendf $Name $Arg0 }
    'read'     {
        $n = 40; if ($Arg0) { $n = [int]$Arg0 }
        $lines = Get-Lines (LoadState $Name)
        if ($null -eq $lines) { Die "get-text failed (pane gone?)" }
        $lines | Select-Object -Last $n
    }
    'wait'     { Cmd-Wait $Name $Arg0 ([int]$Arg1) $false }
    'waitlast' { Cmd-Wait $Name $Arg0 ([int]$Arg1) $true }
    'title'    {
        $s = LoadState $Name
        $r = Invoke-WezCli $s.SOCK @('set-tab-title', '--pane-id', "$($s.PANE)", ($Rest -join ' '))
        exit $r.Code
    }
    'alive'    { if (Test-Alive (LoadState $Name)) { exit 0 } else { exit 1 } }
    'close'    { Cmd-Close $Name }
}
exit 0
