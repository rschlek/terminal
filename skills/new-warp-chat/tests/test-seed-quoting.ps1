<#
.SYNOPSIS
  Seed-quoting regression tests for new-warp-chat.ps1 - the CommandLineToArgvW
  escaping is the fiddly part that has regressed before, so it gets a test.
  The second block covers launch-arg inheritance from the standing tab configs
  (inherit, inherit + -ExtraArgs, explicit override, -Resume, quoted-flag
  round-trip, missing-config fallback, WARP_TAB_CONFIGS_DIR, name collision).
  The third covers the agent menu's config (agents.yaml) and the resolution
  order explicit > agents.yaml > standing tab config > documented default,
  including -Resume for claude and codex with no -resume.toml present.

.DESCRIPTION
  For each edge-case seed, the harness runs the launcher with -NoLaunch, decodes
  the tab command out of the generated TOML, and EXECUTES it in this PowerShell
  5.1 session - exactly what a Warp pane does with commands[0] - with the CLI
  swapped for a probe script that records the argv it actually received. A case
  passes when the probe got the seed back as ONE argument, byte-identical to the
  original (after the launcher's documented newline-collapse + trim). The
  Remove-Item prefix runs too, so the config self-delete is exercised each case.

  MUST run under Windows PowerShell 5.1 - the quoting bug under test is 5.1's
  native-exe argument passing. Run: powershell -File test-seed-quoting.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $env:TEMP ("nwc-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8)))
)
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "These tests must run under Windows PowerShell 5.1 (the quoting behavior under test); got $($PSVersionTable.PSVersion)"
}

$launcher = Join-Path $PSScriptRoot "..\scripts\new-warp-chat.ps1"
if ($WorkDir -match '\s') { throw "WorkDir must not contain spaces (keeps the probe invocation quote-free): $WorkDir" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$cfgDir = Join-Path $WorkDir "tab_configs"
# Never read the user's real agent menu config: point AGENT_MENU_DIR at a temp
# folder that holds no agents.yaml until the third block writes one.
$savedAgentMenuDir = $env:AGENT_MENU_DIR
$agentMenuDir = Join-Path $WorkDir "agent-menu"
$env:AGENT_MENU_DIR = $agentMenuDir

# The probe stands in for the launched CLI: it records how many args it received
# and each arg verbatim, one per line (seeds are single-line by the time they are
# passed - the launcher collapses newlines - so lines are a safe delimiter).
$probe = Join-Path $WorkDir "probe.ps1"
@'
$out = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
$lines = @("COUNT=$($rest.Count)") + $rest
[System.IO.File]::WriteAllLines($out, $lines)
'@ | Set-Content -Path $probe -Encoding Ascii

$cases = @(
    @{ Name = "plain";              Seed = 'echo hello test tab, then you may exit' }
    @{ Name = "interior-dquotes";   Seed = 'say "hello world" twice' }
    @{ Name = "trailing-dquote";    Seed = 'end with a quote "' }
    @{ Name = "backslash-quote";    Seed = 'literal \" backslash-quote and \\" a doubled run' }
    @{ Name = "plain-backslashes";  Seed = 'path C:\temp\dir and a trailing one C:\' }
    @{ Name = "bare-trailing-bslash"; Seed = 'C:\temp\' }  # no whitespace -> PS passes it unquoted; must NOT be doubled
    @{ Name = "dollar-subexpr";     Seed = 'cost is $5, $HOME must survive, and so must $(Get-Date)' }
    @{ Name = "backticks";          Seed = 'back`tick, a `n escape, and `"' }
    @{ Name = "single-quotes";      Seed = "it's got 'single quotes' inside" }
    @{ Name = "kitchen-sink";       Seed = @'
mix "dq" 'sq' $var `bt` \" and a backslash tail\
'@ }
    @{ Name = "multiline-collapse"; Seed = "line one`r`nline two`nline three" }
    # PS 5.1 drops an empty '' native-exe argument, so the launcher treats an
    # empty seed as no seed at all - the probe must see zero arguments.
    @{ Name = "empty-seed";         Seed = ''; ExpectNoArg = $true }
)

function Decode-TomlCommand([string]$cfgPath) {
    $line = (Get-Content -LiteralPath $cfgPath) | Where-Object { $_ -match '^commands = \["(.*)"\]$' } | Select-Object -First 1
    if (-not $line) { throw "no commands line in $cfgPath" }
    # Invert the launcher's TOML escaping in one left-to-right pass:
    # encoded \\ -> \ and \" -> "
    ([regex]::Match($line, '^commands = \["(.*)"\]$').Groups[1].Value) -replace '\\(\\|")', '$1'
}

$failures = 0
$i = 0
foreach ($case in $cases) {
    $i++
    $seedFile = Join-Path $WorkDir "seed$i.txt"
    $outFile  = Join-Path $WorkDir "out$i.txt"
    [System.IO.File]::WriteAllText($seedFile, $case.Seed, (New-Object System.Text.UTF8Encoding($false)))

    & $launcher -TabName "nwc-test" -LaunchCmd powershell `
        -LaunchArgs "-NoProfile -ExecutionPolicy Bypass -File $probe $outFile" `
        -SeedFile $seedFile -TabConfigsDir $cfgDir -NoLaunch | Out-Null

    $cfgPath = Join-Path $cfgDir "nwc-test.toml"
    $tabCmd = Decode-TomlCommand $cfgPath

    # Execute the tab command exactly as the Warp pane would (PS 5.1 input line).
    Invoke-Expression $tabCmd

    $expected = ($case.Seed -replace "[\r\n]+", " ").Trim()
    $lines = [System.IO.File]::ReadAllLines($outFile)
    $got = if ($lines.Count -gt 1) { $lines[1] } else { $null }
    if ($case.ExpectNoArg) {
        $ok = ($lines[0] -eq "COUNT=0") -and (-not (Test-Path $cfgPath)) -and (-not (Test-Path $seedFile))
        $expected = "<no argument>"
    } else {
        $ok = ($lines[0] -eq "COUNT=1") -and ($got -ceq $expected) -and (-not (Test-Path $cfgPath)) -and (-not (Test-Path $seedFile))
    }

    if ($ok) {
        Write-Output ("PASS  {0}" -f $case.Name)
    } else {
        $failures++
        Write-Output ("FAIL  {0}" -f $case.Name)
        Write-Output ("      argv:     {0}" -f $lines[0])
        Write-Output ("      expected: <{0}>" -f $expected)
        Write-Output ("      got:      <{0}>" -f $got)
        if (Test-Path $cfgPath)  { Write-Output "      config was NOT self-deleted" }
        if (Test-Path $seedFile) { Write-Output "      seed file was NOT cleaned up" }
    }
}

# No-seed case: the tab command must carry no trailing argument at all.
$i++
$outFile = Join-Path $WorkDir "out$i.txt"
& $launcher -TabName "nwc-test" -LaunchCmd powershell `
    -LaunchArgs "-NoProfile -ExecutionPolicy Bypass -File $probe $outFile" `
    -TabConfigsDir $cfgDir -NoLaunch | Out-Null
$tabCmd = Decode-TomlCommand (Join-Path $cfgDir "nwc-test.toml")
Invoke-Expression $tabCmd
$lines = [System.IO.File]::ReadAllLines($outFile)
if ($lines[0] -eq "COUNT=0") { Write-Output "PASS  no-seed" } else { $failures++; Write-Output "FAIL  no-seed ($($lines[0]))" }


# ---------------------------------------------------------------------------
# Launch-arg inheritance: with -LaunchArgs omitted the launcher must take the
# args from the standing <tab_configs>\<cmd>.toml (or <cmd>-resume.toml under
# -Resume), strip the leading command name, and pass the rest through VERBATIM -
# the same TOML round-trip and PS 5.1 argv guarantees as the seed. The standing
# config stands in for the user's own Warp tab config on a real machine; the launch
# command is `powershell` so the probe can record what actually arrived.
# ---------------------------------------------------------------------------
$total = $cases.Count + 1
$probeBase = "-NoProfile -ExecutionPolicy Bypass -File $probe"

function Write-StandingConfig([string]$name, [string]$command) {
    $enc  = ($command -replace '\\', '\\') -replace '"', '\"'
    $toml = "# standing tab config (test fixture)`nname = `"$name`"`n`n[[panes]]`nid = `"main`"`ntype = `"terminal`"`ncommands = [`"$enc`"]`n"
    $path = Join-Path $cfgDir "$name.toml"
    [System.IO.File]::WriteAllText($path, $toml, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
function Report([string]$name, [bool]$ok, [string]$detail) {
    $script:total++
    if ($ok) { Write-Output ("PASS  {0}" -f $name) }
    else     { $script:failures++; Write-Output ("FAIL  {0}" -f $name); if ($detail) { Write-Output ("      {0}" -f $detail) } }
}
function Run-Inherit([hashtable]$launcherArgs, [string]$outFile) {
    $cfg = Join-Path $cfgDir "nwc-test.toml"
    $msg = & $launcher -TabName "nwc-test" -LaunchCmd powershell -TabConfigsDir $cfgDir -NoLaunch @launcherArgs
    $cmd = Decode-TomlCommand $cfg
    Invoke-Expression $cmd
    return @{ Msg = ($msg -join "`n"); Cmd = $cmd; Lines = [System.IO.File]::ReadAllLines($outFile); CfgGone = -not (Test-Path $cfg) }
}

# 1. inherited args: standing powershell.toml carries flags after the probe;
#    the launcher must strip only the command name and pass the flags + seed.
$i++; $outFile = Join-Path $WorkDir "out$i.txt"; $seedFile = Join-Path $WorkDir "seed$i.txt"
[System.IO.File]::WriteAllText($seedFile, 'say "hi" $there', (New-Object System.Text.UTF8Encoding($false)))
$flags = "--fixture-flag --profile 'work profile' --trailing"
$standing = Write-StandingConfig "powershell" "powershell $probeBase $outFile $flags"
$r = Run-Inherit @{ SeedFile = $seedFile } $outFile
$ok = ($r.Lines[0] -eq "COUNT=5") -and ($r.Lines[1] -ceq '--fixture-flag') -and ($r.Lines[3] -ceq 'work profile') -and
      ($r.Lines[2] -ceq '--profile') -and ($r.Lines[4] -ceq '--trailing') -and ($r.Lines[5] -ceq 'say "hi" $there') -and
      ($r.Cmd -like "*$flags 'say*") -and ($r.Msg -like "*inherited from $standing*") -and
      $r.CfgGone -and (Test-Path $standing)
Report "inherited-args" $ok ("argv: " + ($r.Lines -join ' | ') + "`n      msg: " + $r.Msg)

# 2. inherited + -ExtraArgs: the caller's additions land AFTER the inherited set,
#    before the seed, and the inherited set is untouched.
$i++; $outFile = Join-Path $WorkDir "out$i.txt"; $seedFile = Join-Path $WorkDir "seed$i.txt"
[System.IO.File]::WriteAllText($seedFile, 'go', (New-Object System.Text.UTF8Encoding($false)))
Write-StandingConfig "powershell" "powershell $probeBase $outFile --fixture-flag" | Out-Null
$r = Run-Inherit @{ SeedFile = $seedFile; ExtraArgs = "-C C:\work\proj" } $outFile
$ok = ($r.Lines[0] -eq "COUNT=4") -and ($r.Lines[1] -ceq '--fixture-flag') -and ($r.Lines[2] -ceq '-C') -and
      ($r.Lines[3] -ceq 'C:\work\proj') -and ($r.Lines[4] -ceq 'go') -and ($r.Msg -like "*ExtraArgs appended*") -and $r.CfgGone
Report "inherited-plus-extra" $ok ("argv: " + ($r.Lines -join ' | '))

# 3. explicit -LaunchArgs wins: the standing config exists but must be ignored.
$i++; $outFile = Join-Path $WorkDir "out$i.txt"
Write-StandingConfig "powershell" "powershell $probeBase $outFile --must-not-appear" | Out-Null
$r = Run-Inherit @{ LaunchArgs = "$probeBase $outFile --explicit" } $outFile
$ok = ($r.Lines[0] -eq "COUNT=1") -and ($r.Lines[1] -ceq '--explicit') -and ($r.Msg -like "*nothing inherited*") -and $r.CfgGone
Report "explicit-launchargs-wins" $ok ("argv: " + ($r.Lines -join ' | '))

# 4. resume variant: -Resume reads <cmd>-resume.toml; its subcommand + flags are
#    kept verbatim and the caller's session id rides in via -ExtraArgs.
$i++; $outFile = Join-Path $WorkDir "out$i.txt"
$standingResume = Write-StandingConfig "powershell-resume" "powershell $probeBase $outFile resume --fixture-flag"
$r = Run-Inherit @{ Resume = $true; ExtraArgs = "sess-123" } $outFile
$ok = ($r.Lines[0] -eq "COUNT=3") -and ($r.Lines[1] -ceq 'resume') -and ($r.Lines[2] -ceq '--fixture-flag') -and
      ($r.Lines[3] -ceq 'sess-123') -and ($r.Msg -like "*inherited from $standingResume*") -and $r.CfgGone -and (Test-Path $standingResume)
Report "inherited-resume" $ok ("argv: " + ($r.Lines -join ' | ') + "`n      msg: " + $r.Msg)

# 5. TOML round-trip of a standing config that carries escaped double quotes
#    (the `--config 'key="value"'` shape): the generated tab command must hold
#    the flag text verbatim. Static check - not executed.
$i++
$quoted = "--fixture-flag --config 'effort=`"high`"'"
Write-StandingConfig "powershell" "powershell $quoted" | Out-Null
& $launcher -TabName "nwc-test" -LaunchCmd powershell -TabConfigsDir $cfgDir -NoLaunch | Out-Null
$cmd = Decode-TomlCommand (Join-Path $cfgDir "nwc-test.toml")
Report "inherited-quoted-roundtrip" ($cmd -clike "*; powershell $quoted") ("cmd: $cmd")
Remove-Item -LiteralPath (Join-Path $cfgDir "nwc-test.toml") -ErrorAction SilentlyContinue

# 6. missing standing config -> documented defaults (no extra flags; a resume
#    keeps only what resume needs), and the launcher says so.
#    Static: decode the config rather than launch a real CLI.
$i++; $seedFile = Join-Path $WorkDir "seed$i.txt"
[System.IO.File]::WriteAllText($seedFile, 'hi', (New-Object System.Text.UTF8Encoding($false)))
$msg = (& $launcher -TabName "nwc-test" -LaunchCmd claude -TabConfigsDir $cfgDir -SeedFile $seedFile -NoLaunch) -join "`n"
$cmd = Decode-TomlCommand (Join-Path $cfgDir "nwc-test.toml")
$ok = ($cmd -clike "*; claude 'hi'") -and ($msg -like "*no standing tab config*") -and ($msg -like "*documented default*")
Report "missing-config-fallback" $ok ("cmd: $cmd`n      msg: $msg")
$msg = (& $launcher -TabName "nwc-test" -LaunchCmd codex -Resume -ExtraArgs "sess-9" -TabConfigsDir $cfgDir -NoLaunch) -join "`n"
$cmd = Decode-TomlCommand (Join-Path $cfgDir "nwc-test.toml")
Report "missing-config-fallback-resume" (($cmd -clike "*; codex resume sess-9") -and ($msg -like "*documented default*")) ("cmd: $cmd")
Remove-Item -LiteralPath (Join-Path $cfgDir "nwc-test.toml") -ErrorAction SilentlyContinue

# 7. WARP_TAB_CONFIGS_DIR overrides the default dir when -TabConfigsDir is omitted
#    (both where the throwaway config is written and where the standing one is read).
$i++
$envDir = Join-Path $WorkDir "envcfg"
New-Item -ItemType Directory -Force -Path $envDir | Out-Null
$envStanding = Join-Path $envDir "claude.toml"
[System.IO.File]::WriteAllText($envStanding, "name = `"claude`"`n[[panes]]`nid = `"main`"`ntype = `"terminal`"`ncommands = [`"claude --from-env`"]`n", (New-Object System.Text.UTF8Encoding($false)))
$env:WARP_TAB_CONFIGS_DIR = $envDir
try {
    $msg = (& $launcher -TabName "nwc-test" -LaunchCmd claude -NoLaunch) -join "`n"
} finally {
    Remove-Item Env:\WARP_TAB_CONFIGS_DIR -ErrorAction SilentlyContinue
}
$envCfg = Join-Path $envDir "nwc-test.toml"
$ok = (Test-Path $envCfg) -and ((Decode-TomlCommand $envCfg) -clike "*; claude --from-env") -and ($msg -like "*inherited from $envStanding*")
Report "env-var-tab-configs-dir" $ok ("msg: $msg")

# 8. The throwaway tab may never be named after a standing config (it self-deletes).
$threw = $false
try { & $launcher -TabName "powershell" -LaunchCmd powershell -TabConfigsDir $cfgDir -NoLaunch | Out-Null } catch { $threw = $true }
Report "tabname-collision-guard" ($threw -and (Test-Path $standing)) ""


# ---------------------------------------------------------------------------
# The agent menu's config: with -LaunchArgs omitted, the <cmd> block's `new`
# line (`resume` under -Resume) in <AGENT_MENU_DIR>\agents.yaml wins over the
# standing tab config; a missing block falls through to the standing config,
# then to the documented defaults. Values are taken verbatim to end of line.
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $agentMenuDir | Out-Null
$agentsYaml = Join-Path $agentMenuDir "agents.yaml"
function Write-AgentsYaml([string]$text) {
    [System.IO.File]::WriteAllText($agentsYaml, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-TabCommand([hashtable]$launcherArgs) {
    $msg = & $launcher -TabName "nwc-test" -TabConfigsDir $cfgDir -NoLaunch @launcherArgs
    $cfg = Join-Path $cfgDir "nwc-test.toml"
    $cmd = Decode-TomlCommand $cfg
    Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
    return @{ Msg = ($msg -join "`n"); Cmd = $cmd }
}
$quotedArgs = "--fixture-flag --model fixture-model --config 'effort=`"high`"'"

# 9. agents.yaml beats the standing config (executed: the probe records argv).
$i++; $outFile = Join-Path $WorkDir "out$i.txt"; $seedFile = Join-Path $WorkDir "seed$i.txt"
[System.IO.File]::WriteAllText($seedFile, 'say "hi"', (New-Object System.Text.UTF8Encoding($false)))
Write-StandingConfig "powershell" "powershell $probeBase $outFile --must-not-appear" | Out-Null
Write-AgentsYaml "powershell:`n  args: --from-config 'two words'`n  new: powershell $probeBase $outFile {args}`n"
$r = Run-Inherit @{ SeedFile = $seedFile } $outFile
$ok = ($r.Lines[0] -eq "COUNT=3") -and ($r.Lines[1] -ceq '--from-config') -and ($r.Lines[2] -ceq 'two words') -and
      ($r.Lines[3] -ceq 'say "hi"') -and ($r.Msg -like "*inherited from $agentsYaml ('powershell' block, 'new' line)*") -and $r.CfgGone
Report "config-beats-standing" $ok ("argv: " + ($r.Lines -join ' | ') + "`n      msg: " + $r.Msg)

# 10. -Resume uses the block's `resume` line, subcommand first, the session id
#     appended after the flags (executed), with no powershell-resume.toml present.
$i++; $outFile = Join-Path $WorkDir "out$i.txt"
Remove-Item -LiteralPath (Join-Path $cfgDir "powershell-resume.toml") -ErrorAction SilentlyContinue
Write-AgentsYaml "powershell:`n  args: --from-config`n  new: powershell {args}`n  resume: powershell $probeBase $outFile resume {args}`n"
$r = Run-Inherit @{ Resume = $true; ExtraArgs = "sess-123" } $outFile
$ok = ($r.Lines[0] -eq "COUNT=3") -and ($r.Lines[1] -ceq 'resume') -and ($r.Lines[2] -ceq '--from-config') -and
      ($r.Lines[3] -ceq 'sess-123') -and ($r.Msg -like "*'resume' line*") -and $r.CfgGone
Report "config-resume-executed" $ok ("argv: " + ($r.Lines -join ' | ') + "`n      msg: " + $r.Msg)

# 11. The shipped shape for both agents, -resume.toml files absent: codex keeps
#     `resume` before the flags, claude puts --resume after them; the quoted
#     --config value round-trips verbatim. Static checks of the tab command.
Write-AgentsYaml (@(
    "projects_root: C:\fixture\root", "",
    "claude:", "  args: --fixture-flag", "  new: claude {args}", "  resume: claude {args} --resume", "",
    "codex:", "  args: $quotedArgs", "  new: codex {args}", "  resume: codex resume {args}", "  resume_all: codex resume --all {args}"
) -join "`n")
Remove-Item -LiteralPath (Join-Path $cfgDir "claude-resume.toml"), (Join-Path $cfgDir "codex-resume.toml") -ErrorAction SilentlyContinue
$r = Get-TabCommand @{ LaunchCmd = "codex" }
Report "config-codex-new-quoted" ($r.Cmd -clike "*; codex $quotedArgs") ("cmd: " + $r.Cmd)
$r = Get-TabCommand @{ LaunchCmd = "codex"; Resume = $true; ExtraArgs = "sess-9" }
Report "config-codex-resume" (($r.Cmd -clike "*; codex resume $quotedArgs sess-9") -and ($r.Msg -like "*'codex' block, 'resume' line*")) ("cmd: " + $r.Cmd)
$r = Get-TabCommand @{ LaunchCmd = "claude" }
Report "config-claude-new" ($r.Cmd -clike "*; claude --fixture-flag") ("cmd: " + $r.Cmd)
$r = Get-TabCommand @{ LaunchCmd = "claude"; Resume = $true; ExtraArgs = "sess-8" }
Report "config-claude-resume" ($r.Cmd -clike "*; claude --fixture-flag --resume sess-8") ("cmd: " + $r.Cmd)

# 12. Explicit -LaunchArgs still wins over agents.yaml.
$r = Get-TabCommand @{ LaunchCmd = "codex"; LaunchArgs = "--explicit" }
Report "explicit-beats-config" (($r.Cmd -clike "*; codex --explicit") -and ($r.Msg -like "*nothing inherited*")) ("cmd: " + $r.Cmd)

# 13. Empty args: {args} and the space before it disappear.
Write-AgentsYaml "claude:`n  args:`n  new: claude {args}`n  resume: claude {args} --resume`n"
$r = Get-TabCommand @{ LaunchCmd = "claude"; Resume = $true }
Report "config-empty-args" ($r.Cmd -clike "*; claude --resume") ("cmd: " + $r.Cmd)

# 14. No block for the command: fall through to the standing tab config.
Write-StandingConfig "claude" "claude --from-standing" | Out-Null
Write-AgentsYaml "codex:`n  new: codex {args}`n"
$r = Get-TabCommand @{ LaunchCmd = "claude" }
Report "config-no-block-falls-to-standing" (($r.Cmd -clike "*; claude --from-standing") -and ($r.Msg -like "*inherited from*claude.toml*")) ("cmd: " + $r.Cmd)
Remove-Item -LiteralPath (Join-Path $cfgDir "claude.toml") -ErrorAction SilentlyContinue

# 15. A block whose line runs another command is skipped (warning), then the
#     documented default applies when no standing config exists either.
Write-AgentsYaml "claude:`n  new: wrapper claude {args}`n"
$r = Get-TabCommand @{ LaunchCmd = "claude"; WarningAction = "SilentlyContinue" }
Report "config-wrong-command-skipped" (($r.Cmd -clike "*; claude") -and ($r.Msg -like "*documented default*")) ("cmd: " + $r.Cmd + "`n      msg: " + $r.Msg)

if ($null -ne $savedAgentMenuDir) { $env:AGENT_MENU_DIR = $savedAgentMenuDir } else { Remove-Item Env:\AGENT_MENU_DIR -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Output "$failures FAILURE(S)"; exit 1 }
Write-Output "All $total cases passed."
