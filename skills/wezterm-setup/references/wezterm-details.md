# WezTerm setup - details

Reference for the `wezterm-setup` skill: the release to install, per-OS install
commands (including a no-admin Linux route), config file locations, and the
socket and class mechanics that the verification and the `shared-pane` helpers
depend on. Everything runs as inline commands; the skill ships no script.

## Use the `nightly` release, not `latest`

WezTerm's `latest` stable tag is a 2024 build with known Wayland problems on a
current Linux desktop. The `nightly` release is what every route below uses:

```
https://github.com/wezterm/wezterm/releases/tag/nightly
```

| System | Asset |
| --- | --- |
| Fedora | `wezterm-nightly-fedora<N>.rpm` |
| Debian / Ubuntu | `wezterm-nightly-Ubuntu<NN.NN>.deb` |
| Any Linux, no admin | `WezTerm-nightly-Ubuntu26.04.AppImage` |
| Windows | `WezTerm-nightly-setup.exe` |
| macOS | `WezTerm-nightly-macos.zip` (prefer Homebrew) |

Do **not** use `WezTerm-nightly-Ubuntu16.04.AppImage` from the same page:
despite the nightly release it is a 2021 binary.

## Install with admin rights (preferred)

```sh
sudo dnf install ./wezterm-nightly-fedora<N>.rpm        # Fedora
sudo apt install ./wezterm-nightly-Ubuntu<NN.NN>.deb    # Debian / Ubuntu
brew install --cask wezterm                              # macOS
```

```powershell
winget install wez.wezterm                               # Windows
```

If the native package needs a sudo password the agent cannot type, take the
no-admin route below or hand the user the install command.

## Install without admin rights (Linux)

Checked on a Fedora / GNOME Wayland desktop, where the resulting binary passed
the full shared-pane round trip (open, send, wait, read, alive, close).

```sh
mkdir -p ~/.local/opt ~/.local/bin
cd /tmp
curl -fL -o wezterm.AppImage \
  https://github.com/wezterm/wezterm/releases/download/nightly/WezTerm-nightly-Ubuntu26.04.AppImage
chmod +x wezterm.AppImage
./wezterm.AppImage --appimage-extract
rm -rf ~/.local/opt/wezterm
mv squashfs-root ~/.local/opt/wezterm
for b in wezterm wezterm-gui wezterm-mux-server; do
  ln -sf ~/.local/opt/wezterm/usr/bin/$b ~/.local/bin/$b
done
wezterm --version
```

`~/.local/bin` must be on `PATH`. Extracting avoids FUSE, which a locked-down
machine may lack. `WEZTERM_BIN` lets the shared-pane helper use a binary that is
not on `PATH`.

## Config file location

| OS | Path |
| --- | --- |
| Linux / macOS | `~/.config/wezterm/wezterm.lua` (create the directory) |
| Windows | `%USERPROFILE%\.wezterm.lua` (WezTerm also reads `%USERPROFILE%\.config\wezterm\wezterm.lua`) |

The managed region runs from `-- wezterm-setup: managed block start` to
`-- wezterm-setup: managed block end`. The asset is a complete, valid
`wezterm.lua` on its own; its `return config` sits after the end marker.

## How a `wezterm cli` call finds one specific GUI

Several WezTerm GUI processes can share the default window class, and a bare
`wezterm cli` answers for whichever instance it finds first - so it can type
into the wrong window. The documented resolution order
(https://wezterm.org/cli/cli/index.html):

1. `--prefer-mux` - the first unix domain in `wezterm.lua`. Never used here,
   which is why the managed config leaves `unix_domains` unset.
2. `$WEZTERM_UNIX_SOCKET` - "use that location to identify the running
   instance."
3. GUI discovery by `--class`, if that GUI was also spawned with `--class`.

Shared panes start each GUI as `wezterm start --class shared-pane-<name>-<pid>`
and then use **rung 2 only**, on every platform:

- Find the socket the new GUI publishes and set `WEZTERM_UNIX_SOCKET` to it for
  every later call; drop an inherited `WEZTERM_PANE`.
  - Linux / macOS: watch `$XDG_RUNTIME_DIR/wezterm/` for the new `gui-sock-*`.
  - Windows: the socket is `%USERPROFILE%\.local\share\wezterm\gui-sock-<pid>`,
    `<pid>` being the `wezterm-gui.exe` process id (`Start-Process -PassThru`).
    Not documented by wezterm.org but observed on Windows 11 with WezTerm
    20240203; the value is a Windows-style path. Sockets of dead GUIs can
    linger, so liveness also checks the pid.
- Rung 3 (`wezterm cli --class <class>`) did not select the right GUI on
  Windows (`cli list` came back empty or from another instance). The class only
  keeps the window identifiable.

`--class` is not X11-only: `wezterm start --help` says "Under X11 and Windows
this changes the window class. Under Wayland this changes the app_id."

## Launching a GUI from a script

- Linux / macOS: `setsid nohup wezterm start --class <class> -- bash -l &`
- Windows: use `wezterm-gui.exe`, not `wezterm.exe`, so Windows does not open a
  console host for its logging (https://wezterm.org/cli/general.html), with
  `--always-new-process` so it does not hand off to an existing instance.
  Resolve it by full path (`C:\Program Files\WezTerm\wezterm-gui.exe`) when it
  is not on the agent's `PATH`. A GUI start has taken longer than 15 s to
  publish its socket; allow up to 120 s. Per the issue tracker,
  `--always-new-process` may not force a new instance across an elevation
  boundary.

## Deliberately not configured

- `default_prog`: the login shell stays the user's; a shared pane opens it and
  the agent runs `ssh` or `sudo` inside.
- `unix_domains` / the mux server: shared panes are independent GUI processes
  on purpose; a mux domain would collapse them into one addressable instance.
- Fonts, colours, keybindings: no opinions imposed on a terminal the user may
  rarely open by hand.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `wezterm GUI did not publish a socket` | No desktop session, or the GUI died at start. Run `wezterm start` by hand and read the error. |
| Keystrokes land in the wrong window | A bare `wezterm cli`, or a stale `WEZTERM_UNIX_SOCKET` inherited from the surrounding terminal. Pin by socket. |
| First command in a Windows pane is mangled | Text piped through the PowerShell 5.1 pipeline gains a BOM, or LF was sent instead of CR. Pass the text as one `send-text` argument ending in CR (what the shared-pane Windows helper does). |
| Wayland glitches, blank window | A `2024*` stable build. Reinstall from `nightly`. |
| `wezterm: command not found` after the AppImage route | `~/.local/bin` not on `PATH`, or the symlinks point into a moved `squashfs-root`. |
