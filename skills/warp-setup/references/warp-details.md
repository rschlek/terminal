# Warp setup - details

Reference for the `warp-setup` skill: the assets and how they merge, detection
and the onboarding precondition, install steps for the user, per-OS paths and
commands, the self-host guard, why the order is quit -> write -> relaunch, and
the Windows Git-probe check. Everything runs as inline commands; the skill
ships no script.

## The assets

```
warp-setup/assets/
  settings.toml          # the default look; carries the {{DEFAULT_TAB_CONFIG_PATH}} token
  settings.windows.toml  # Windows-only overlay: the Shell (PS1) safeguard
  settings.linux.toml    # Linux-only overlay: comments only today
```

Reference them as `${CLAUDE_PLUGIN_ROOT}/skills/warp-setup/assets/...`.

The default look: theme `adeberry` (one of Warp's built-in themes), font size
13, notebook font size 14, zoom 125, vertical tabs on, the system theme off,
Warp AI off, Warp Drive off, the code editor's review button / project explorer
/ global search off, the CLI agent toolbar off, the sticky command header off
(`snackbar_enabled = false`, a misleadingly generic key name per Warp issue
#12865), OSC 52 clipboard write-only, no quit warning, and new sessions opening
the default tab config. The asset is the authority; this list only summarizes
it.

**Merge rules.** The managed keys are exactly those present in the applicable
asset set: `settings.toml`, plus the overlay for the current OS. Each managed
key is written at the asset value and wins on conflict - most importantly
`default_tab_config_path`, which a configured Warp already points at some other
tab. Every key and section that is not managed is preserved. An overlay for
another OS is ignored and its keys stay user-owned. Read the existing file
first and keep that copy to prove nothing was dropped.

**The token.** `default_tab_config_path` ships as `'{{DEFAULT_TAB_CONFIG_PATH}}'`.
Replace it, as a plain string replace, with the absolute path to
`<tab_configs>/claude.toml` joined with the OS separator (`\` on Windows, `/`
elsewhere), `~` expanded: Warp stores the resolved path and does not expand a
literal `~`. The `claude` tab config itself is written by the `agent-menu`
setup.

**The Windows overlay.** `[terminal.input] input_box_type_setting = "classic"`
and `honor_ps1 = true` switch Warp to Shell (PS1) input, which stops Warp's
native Git prompt polling. On Windows that polling can repeatedly spawn
PowerShell + Git probes and amplify endpoint-security scanning. The keys are
cross-platform but the problem is Windows-only, so on macOS and Linux
`[terminal.input]` stays unmanaged: never written, never removed.

**The Linux overlay** manages no keys; it exists so the apply logic stays
uniform and a future Linux-only key has one home. Warp's Linux-only `[system]`
keys (`force_x11`, `linux_selection_clipboard`) are deliberately unmanaged.

## Detect Warp

- Windows: `Test-Path "$env:LOCALAPPDATA\Programs\Warp\warp.exe"`
- macOS: `/Applications/Warp.app`
- Linux: `command -v warp-terminal` (`/usr/bin/warp-terminal`, a symlink into
  `/opt/warpdotdev/warp-terminal/`); desktop entry
  `/usr/share/applications/dev.warp.Warp.desktop`, which registers the
  `warp://` handler. Flatpak and AppImage layouts are not covered: if Warp is
  clearly installed some other way, stop and ask rather than guess paths.

## Onboarded check

Warp flushes its in-memory settings to `settings.toml` on first launch and when
onboarding completes, overwriting anything written before. So require that
Warp has been opened once and onboarded: `settings.toml` exists at the settings
dir and is not empty. If it is absent or empty, ask the user to open Warp, click
through onboarding to the prompt, and reply. `warp.sqlite` (account email,
command history) is never read, so this file check plus the user's word is the
check.

## Installing Warp (the user does it)

Hand these over and wait; afterwards the user opens Warp once and finishes
onboarding.

- macOS: download from https://www.warp.dev/ (Apple Silicon or Intel build)
  and drag it into `/Applications`, or `brew install --cask warp`.
- Windows: the installer from https://www.warp.dev/, or
  `winget install --id Warp.Warp --exact`. winget's download step has been seen
  to hang for a long time; if it sits at "Downloading...", cancel and use the
  direct download.
- Linux: the `.rpm` / `.deb` package from https://www.warp.dev/.

## Paths

| What            | Windows                                | macOS                 | Linux                                                         |
| --------------- | -------------------------------------- | --------------------- | ------------------------------------------------------------- |
| settings dir    | `%LOCALAPPDATA%\warp\Warp\config`      | `~/.warp`             | `${XDG_CONFIG_HOME:-~/.config}/warp-terminal`                 |
| tab_configs dir | `%APPDATA%\warp\Warp\data\tab_configs` | `~/.warp/tab_configs` | `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/tab_configs`  |
| custom themes   | -                                      | `~/.warp/themes`      | `${XDG_DATA_HOME:-~/.local/share}/warp-terminal/themes`       |
| state (never touched) | -                                | -                     | `${XDG_STATE_HOME:-~/.local/state}/warp-terminal`             |

On Linux Warp follows the XDG Base Directory spec: resolve the variables, fall
back to the defaults. The settings dir also holds `user_preferences.json`
(onboarding flags), which is not managed. The state dir holds `warp.sqlite*`
and `warp.log*`. Sources: Warp's docs on file locations, tab configs, and
custom themes.

## Launch and quit

- Windows launch: `Start-Process "$env:LOCALAPPDATA\Programs\Warp\warp.exe"`;
  quit: `Get-Process Warp -ErrorAction SilentlyContinue | Stop-Process -Force`.
  Inline `powershell -Command` calls may need `-ExecutionPolicy Bypass` on a
  machine at the default `Restricted` policy; it applies to that child only.
- macOS launch: `open -a Warp`; quit: `osascript -e 'quit app "Warp"'`.
- Linux launch, detached so it survives the shell:
  `setsid nohup warp-terminal > /dev/null 2>&1 < /dev/null &`
  (`gtk-launch dev.warp.Warp` is the desktop-entry equivalent). There is no
  documented CLI quit: prefer the user closing Warp, confirmed by an empty
  `pgrep -x warp-terminal`. Scripted: `pkill -TERM -x warp-terminal`, then poll
  `pgrep` until empty (about 10 s). Never `-9`: Warp keeps state in a SQLite
  WAL, and a hard kill is the reported route to settings that revert.
- Wait about 5 s after a launch before opening a tab.

## Self-host guard

Never quit the Warp this session runs in: it would kill the session mid-step.
Either signal means self-host:

- `TERM_PROGRAM=WarpTerminal` in the environment (Warp also exports
  `WARP_TERMINAL_SESSION_UUID` and `WARP_CLIENT_VERSION`). Do not rely on
  `TERM_PROGRAM_VERSION`; it can be empty.
- A Warp ancestor process. Windows:

  ```powershell
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
  for ($i = 0; $i -lt 8 -and $p; $i++) {
      if ($p.Name -eq 'warp.exe') { 'self-host'; break }
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
  }
  ```

  Linux (the usual case there, since the agent typically runs in a Warp tab):

  ```bash
  p=$$; for i in $(seq 1 8); do c=$(cat /proc/$p/comm 2>/dev/null) || break
    case "$c" in warp|warp-terminal) echo self-host; break;; esac
    p=$(awk '{print $4}' /proc/$p/stat 2>/dev/null); [ -n "$p" ] || break; done
  ```

Self-hosted: write `settings.toml` live (Warp hot-reloads it, so the look
applies now) and skip the quit and relaunch; the tab configs persist regardless
(Warp never flushes that directory). Tell the user that one full quit and
relaunch with no agent session inside Warp, or a re-run from another terminal,
makes the settings durable.

## Why quit -> write -> relaunch

Warp hot-reloads `settings.toml`, but a running Warp also writes its in-memory
settings back to the file, including on exit, which can overwrite an edit made
while it ran. Writing while Warp is stopped and letting a fresh launch read the
file avoids that race. The first-launch and onboarding flushes are covered by
the onboarded precondition.

## Verification details

- No BOM: the first three bytes of `settings.toml` are not `239 187 191`.
  Windows: `[System.IO.File]::ReadAllBytes('<settings.toml>')[0..2]`; elsewhere:
  `head -c 3 '<settings.toml>' | od -An -tu1`.
- On Windows also confirm `input_box_type_setting = "classic"` and
  `honor_ps1 = true`; elsewhere `[terminal.input]` is not checked.
- Linux: report the Git-probe check as not applicable, never as passed.
- If Warp on Linux comes back with a blank or missing window, that is Warp's
  GPU / Wayland territory (`WGPU_BACKEND=gl`, `WARP_ENABLE_WAYLAND=1` in the
  environment), not `settings.toml`; say so rather than writing rendering keys.

## Open a tab config

- Windows: `Start-Process "warp://tab_config/claude"`
- macOS: `open "warp://tab_config/claude"`
- Linux: `xdg-open "warp://tab_config/claude"`; the handler is registered when
  `xdg-mime query default x-scheme-handler/warp` prints `dev.warp.Warp.desktop`.
  Append `?new_window=true` for a new window.

## Windows Git-probe check

Run only after a clean-path relaunch. It samples Warp's direct PowerShell
children for 10 seconds and fails if Warp still launches the native Git probes
the Shell (PS1) setting exists to stop. The command this skill runs is not a
direct child of Warp, so it does not match itself.

```powershell
$seen = @{}
1..5 | ForEach-Object {
  $all = @(Get-CimInstance Win32_Process)
  $warp = $all | Where-Object Name -eq 'warp.exe' |
    Sort-Object CreationDate | Select-Object -First 1
  if ($warp) {
    $all | Where-Object {
      $_.Name -eq 'powershell.exe' -and
      $_.ParentProcessId -eq $warp.ProcessId -and
      $_.CommandLine -match 'git (?:-c .* )?diff --shortstat|git symbolic-ref|git rev-parse'
    } | ForEach-Object { $seen[$_.ProcessId] = $true }
  }
  Start-Sleep -Seconds 2
}
if ($seen.Count -gt 0) {
  throw "Warp Git-probe regression detected: $($seen.Count) unique probe process(es) in 10 seconds."
}
```

Total `powershell.exe` or `git.exe` counts are not the gate: agent sessions and
user commands use them too. Parentage plus the command signatures are. On a
match, report the count and stop; do not install a process killer or a security
exclusion.
