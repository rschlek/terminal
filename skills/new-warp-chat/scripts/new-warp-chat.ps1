<#
.SYNOPSIS
  new-warp-chat - open a new, self-deleting Warp tab on Windows that auto-runs a
  given command, optionally seeded with a prompt/argument baked in. Owns the
  PowerShell seed-escaping that the model-driven inline path keeps getting wrong.

.DESCRIPTION
  The shared seeded-tab launcher: any skill that needs a fresh Warp tab running a
  command (a breakout chat, an onboarding getting-started tab) calls this on the
  Windows / PowerShell path. It bakes the seed into the new tab's launch command
  as a single-quoted PowerShell literal with embedded double quotes escaped per
  CommandLineToArgvW - because PowerShell 5.1 does NOT escape interior " when
  invoking a native exe, so a bare seed splits at the first " and the prompt
  silently truncates. That truncation is the exact bug this script exists to
  kill; keeping the escaping in code (not inline prose) is why it cannot regress.

  LAUNCH ARGS - ONE SOURCE OF TRUTH. When the caller omits -LaunchArgs, the
  arguments are INHERITED from the user's own standing Warp tab config for
  that command, when it exists: <tab_configs>\<LaunchCmd>.toml (or <LaunchCmd>-resume.toml with
  -Resume). The launcher takes the config's `commands` entry, strips the leading
  command name, and uses the rest VERBATIM - so whatever flags the standing tab
  carries on this machine (permission mode, a model or reasoning pin, anything)
  reach the new tab unchanged, and nothing about them lives in this script.
  -ExtraArgs appends caller additions (e.g. `-C <dir>`, a session id) without
  replacing the inherited set. An explicit -LaunchArgs replaces the whole set.
  With no standing config the launcher falls back to the documented defaults
  below (no extra flags; a resume keeps only what resume needs) and says so. It always prints which args it used and where they came
  from.

  The seed reaches this script through a FILE, never a command line - pass
  -SeedFile, not the text - so quotes / newlines / $ / backticks in the prompt
  survive regardless of the caller's shell. The script reads it, bakes the
  escaped literal into the tab config, then deletes the seed file (the launched
  tab runs the baked literal and never re-reads the file).

  Each caller names its tab via -TabName; the config self-deletes as the tab's
  first command (Warp has already read it - race-free), so no entry lingers in
  Warp's + menu. The tab name may not collide with a standing config name.

  The tab_configs dir defaults to Warp's; set WARP_TAB_CONFIGS_DIR (or pass
  -TabConfigsDir) to point it elsewhere - tests use a temp dir.

.EXAMPLE
  new-warp-chat.ps1 -TabName breakout -LaunchCmd claude -SeedFile C:\tmp\seed.txt
  # args inherited from <tab_configs>\claude.toml
.EXAMPLE
  new-warp-chat.ps1 -TabName breakout -LaunchCmd codex -ExtraArgs '-C C:\work\proj' -SeedFile C:\tmp\seed.txt
  # args inherited from <tab_configs>\codex.toml, then `-C C:\work\proj` appended
.EXAMPLE
  new-warp-chat.ps1 -TabName codex-chat -LaunchCmd codex -Resume -ExtraArgs '<session-id>'
  # args inherited from <tab_configs>\codex-resume.toml (the `resume` subcommand
  # and its flags kept verbatim), the session id appended
.EXAMPLE
  new-warp-chat.ps1 -TabName codex-chat -LaunchCmd codex -LaunchArgs ''
  # explicit override: nothing inherited, plain `codex`, empty fresh chat, no seed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LaunchCmd,                                          # e.g. claude | codex
    [string]$LaunchArgs,                                                               # explicit override; OMIT to inherit from the standing tab config
    [string]$ExtraArgs = "",                                                           # appended after the inherited/explicit/default args, verbatim
    [switch]$Resume,                                                                   # inherit from <LaunchCmd>-resume.toml instead of <LaunchCmd>.toml
    [string]$SeedFile = "",                                                            # path to a file holding the seed (robust; never transits a command line)
    [string]$TabName = "new-warp-chat",                                                # names the tab, its config file, and the warp:// URI
    [string]$TabConfigsDir = $(if ($env:WARP_TAB_CONFIGS_DIR) { $env:WARP_TAB_CONFIGS_DIR } else { Join-Path $env:APPDATA "warp\Warp\data\tab_configs" }),
    [switch]$NoLaunch                                                                  # write the config but skip the warp:// launch (tests / batch prep)
)
$ErrorActionPreference = "Stop"

# --- Documented fallback defaults, used ONLY when no standing tab config exists
# for the command on this machine. They add nothing beyond what a resume itself
# needs: no permission mode, model, tenant, or machine pin belongs here - those
# live in the user's own standing Warp tab configs, or are passed explicitly.
$documentedDefaults = @{
    'claude'        = ''
    'claude-resume' = '--resume'
    'codex'         = ''
    'codex-resume'  = 'resume'
}

# --- The tab name lands in a filename, a TOML basic string, and a warp:// URI;
# constrain it so it needs no escaping in any of the three.
if ($TabName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "new-warp-chat: -TabName may only contain letters, digits, '.', '_', '-' (got: $TabName)"
}
# The throwaway config self-deletes; it must never be written over a standing one.
if (($TabName -ieq $LaunchCmd) -or ($TabName -ieq "$LaunchCmd-resume")) {
    throw "new-warp-chat: -TabName '$TabName' collides with the standing tab config for '$LaunchCmd'; pick another name"
}

# --- Read the launch args out of a standing tab config: decode the first
# `commands` string (inverting the TOML basic-string escapes \\ and \"), drop the
# leading command name, return the rest verbatim. $null when the file is not a
# usable source (no commands line, or a command that is not $cmd).
function Get-StandingLaunchArgs([string]$path, [string]$cmd) {
    $text = [System.IO.File]::ReadAllText($path)
    $m = [regex]::Match($text, '(?m)^\s*commands\s*=\s*\[\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) {
        Write-Warning "new-warp-chat: $path has no `"commands`" entry; not inheriting from it"
        return $null
    }
    $command = ($m.Groups[1].Value -replace '\\(["\\])', '$1').Trim()
    $parts = $command -split '\s+', 2
    if ($parts[0] -ine $cmd) {
        Write-Warning "new-warp-chat: $path runs '$($parts[0])', not '$cmd'; not inheriting from it"
        return $null
    }
    if ($parts.Count -gt 1) { return $parts[1].Trim() }
    return ""
}

# --- Resolve the launch args: explicit > inherited from the standing config >
# documented default. -ExtraArgs is appended to whichever won.
$standingName = if ($Resume) { "$LaunchCmd-resume" } else { $LaunchCmd }
$standingPath = Join-Path $TabConfigsDir "$standingName.toml"
if ($PSBoundParameters.ContainsKey('LaunchArgs')) {
    $resolvedArgs = $LaunchArgs
    $argsSource   = "explicit -LaunchArgs (nothing inherited)"
} else {
    $inherited = $null
    if (Test-Path -LiteralPath $standingPath) { $inherited = Get-StandingLaunchArgs $standingPath $LaunchCmd }
    if ($null -ne $inherited) {
        $resolvedArgs = $inherited
        $argsSource   = "inherited from $standingPath"
    } else {
        $resolvedArgs = if ($documentedDefaults.ContainsKey($standingName)) { $documentedDefaults[$standingName] } else { "" }
        $argsSource   = "no standing tab config at $standingPath - using the documented default for '$standingName'"
    }
}
if ($ExtraArgs) {
    $resolvedArgs = (@($resolvedArgs, $ExtraArgs) | Where-Object { $_ }) -join ' '
    $argsSource  += "; -ExtraArgs appended"
}
Write-Output "new-warp-chat: launch args [$resolvedArgs] - $argsSource"

# --- Build the launch command, baking in the seed (if any). The seed becomes a
# single-quoted PowerShell literal so $, backticks, and backslashes survive
# verbatim (interior ' are doubled). Interior " are escaped per CommandLineToArgvW
# (double any run of \ before a ", add one more) so the whole prompt reaches the
# native exe as ONE argument under PowerShell 5.1 instead of splitting at the ".
$launch = $LaunchCmd
if ($resolvedArgs) { $launch += " $resolvedArgs" }
if ($SeedFile) {
    if (-not (Test-Path -LiteralPath $SeedFile)) { throw "new-warp-chat: -SeedFile not found: $SeedFile" }
    $seed = [System.IO.File]::ReadAllText($SeedFile)
    $seed = ($seed -replace "[\r\n]+", " ").Trim()
    $seed = $seed -replace '(\\*)"', '$1$1\"'
    # Second half of the CommandLineToArgvW rule: when the argument contains
    # whitespace, PowerShell wraps it in double quotes at spawn time, so a
    # trailing run of backslashes would escape that closing quote and corrupt
    # the last characters ('C:\' arrives as 'C:"'). Double the trailing run -
    # but ONLY when PowerShell will quote (whitespace present); an unquoted
    # argument keeps its trailing backslashes literal and must not be touched.
    if ($seed -match '\s' -and $seed -match '\\$') {
        $seed = $seed -replace '(\\+)$', '$1$1'
    }
    # PowerShell 5.1 silently DROPS an empty '' argument to a native exe, so an
    # empty seed cannot reach the CLI anyway - skip it explicitly.
    if ($seed -ne '') {
        $launch += " '" + ($seed -replace "'", "''") + "'"
    }
}

# --- Compose the tab command: delete this config first (Warp has already read it,
# so it is race-free and leaves no lingering entry in the + menu), then run the
# command with the baked seed.
if (-not (Test-Path $TabConfigsDir)) { New-Item -ItemType Directory -Path $TabConfigsDir -Force | Out-Null }
$cfgPath = Join-Path $TabConfigsDir "$TabName.toml"
$qCfg    = "'" + ($cfgPath -replace "'", "''") + "'"
$tabCmd  = "Remove-Item -LiteralPath $qCfg -ErrorAction SilentlyContinue; $launch"

# --- Embed in a TOML basic string: escape backslashes first, then double quotes.
$tabCmdToml = ($tabCmd -replace '\\', '\\') -replace '"', '\"'
$toml = @"
# Warp tab config - generated by the new-warp-chat launcher (self-deleting; overwritten each run).
name = "$TabName"

[[panes]]
id = "main"
type = "terminal"
commands = ["$tabCmdToml"]
"@
# Write UTF-8 without BOM - Warp's TOML parser chokes on a BOM.
[System.IO.File]::WriteAllText($cfgPath, $toml, (New-Object System.Text.UTF8Encoding($false)))

# --- The seed is now baked into the config; the temp file is no longer needed.
if ($SeedFile -and (Test-Path -LiteralPath $SeedFile)) { Remove-Item -LiteralPath $SeedFile -ErrorAction SilentlyContinue }

if ($NoLaunch) {
    Write-Output "new-warp-chat: wrote $cfgPath (launch skipped) -> $launch"
    return
}

# Open the tab in the RUNNING Warp via the URI handler - never relaunch warp.exe
# directly (that path trips Warp's session restore).
Start-Process "warp://tab_config/$TabName"
Write-Output "new-warp-chat: opened a new Warp tab '$TabName' -> $launch"
