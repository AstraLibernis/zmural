# zmural milestones

The plan from the first public release (0.1.0, 2026-10-12) on. Each milestone is a release.
Items are taken top to bottom; a milestone ships when its boxes are ticked and its tests pass in
CI ([RELEASING.md](RELEASING.md)). The plan before the repository went public, with how
everything that exists was built, is kept in
[notes/milestones-2026-08-to-10-12.md](../notes/milestones-2026-08-to-10-12.md).

**What "done" means.** A feature is ticked for an OS only when a test uses it the way a person
would: a real click or key on the real control, with its effect checked on screen, in `status` or
in the log ([CONTROLS.md](CONTROLS.md) says which test presses each control). A script that goes
around the control (`zmural-console`, an edited `settings.toml`, a D-Bus call) proves the logic
behind it, not the control. What only a real desktop can show is said plainly in the item.

## Where it stands (0.1.0)

| | Windows 11 | Linux (Wayland) |
|---|---|---|
| Videos, pictures, GIFs | ✅ | ✅ |
| Web-page wallpapers | ✅ | ⬜ (0.4) |
| Library, rotation, adjustments, zip import/export, Lively import | ✅ | ✅ |
| Pause rules | ✅ | ✅ (which rules work depends on the desktop: [ARCHITECTURE.md](ARCHITECTURE.md)) |
| A wallpaper per monitor | logic tested; never seen on two real monitors | tested on two virtual screens |
| Settings window | ✅, but nobody has looked at it on Windows since it moved into zmural (2026-09-30) | ✅ |
| Tray menu | ✅ | ✅ on KDE, GNOME (AppIndicator) and hosts that read its menu; **nothing on swaybar** (0.1.1) |
| Desktops | Windows 11 | KDE Plasma 6, GNOME 48–51, Sway, Hyprland, labwc, Wayfire, Niri, COSMIC |

## 0.1.1: Every control works, and a test presses it

From the blind test of 0.1.0 ([notes/blind-test-2026-10-12.md](../notes/blind-test-2026-10-12.md))
and the controls inventory ([CONTROLS.md](CONTROLS.md)), which found controls no test had pressed.

- [x] Zip bombs refused by ratio, and a zip capped at 4 GiB (fd39888)
- [ ] **Tray menu on hosts that call `ContextMenu`** (swaybar): show the menu there, and do something sensible with middle click and scroll
- [ ] **Open folder, Open log, Show in folder:** say so when nothing could open it (Linux: `xdg-open`'s exit status; Windows: `ShellExecuteW`'s result)
- [ ] **Uninstall from the window:** no lone "Yes", show that it's working, no ~4 s wait
- [ ] **A test desktop like a user's:** a Sway rig with a session bus, swaybar's tray, a notification daemon, and real pointer input; it right-clicks the real tray icon
- [ ] **Every settings-window control pressed with real input, its effect checked, toasts included:** every row of [CONTROLS.md](CONTROLS.md) gets an `R:` on Linux
- [ ] **A Windows pass:** the same list, by hand, on a real Windows 11 desktop, recorded in `notes/` (the window hasn't been looked at on Windows since it moved into zmural)
- [ ] Small bugs from the blind test:
  - [ ] `zmural-console apply` of a file that can't play exits 0; it should fail like the notification says
  - [ ] `zmural-console export <name>` takes only a path; take a library name too
  - [ ] the VP9 "you won't be told again" notice came twice
  - [ ] the mini-player says "Playing" while `status` says paused (covered)
  - [ ] two imports of the same zip show the same tile name
  - [ ] a bad value in `settings.toml` is only logged; tell the user once
  - [ ] the log notes the library every 3 s; a CUDA line on machines without NVIDIA; empty folders left after uninstall
- [ ] Doc fixes from the blind test: the Welcome page lists web pages on Linux; the README's install folder example nests; pickers need xdg-desktop-portal; `export` takes a path; `prop speed` is for videos; the tarball's `README.txt` lists fewer commands; waywallen-display's MIT text in `licenses/`

## 0.2: Solid on both OSes

Stability and the loose ends of what exists, before anything new.

- [ ] Windows: the settings window runs inside zmural, and Zig's crash handler treats any first-chance access violation as fatal, so a shell extension (file picker, thumbnails) that raises and catches its own would take zmural down. An unhandled-exception filter for the crash log instead of the segfault handler.
- [ ] Windows: a second `zmural --settings` may only flash the taskbar (`AllowSetForegroundWindow`); a right-click after keyboard use opens the menu at the focused tile
- [ ] Windows web wallpapers: send `shown` once the page has painted, so switching to one doesn't wait 4 s; a frozen last frame while paused (black today); an fps cap; an Explorer-restart test
- [ ] KDE: when the plugin installed but Plasma couldn't be switched to it, nothing shows and no still picture is set
- [ ] `status` shows a monitor's own fill mode but not the main one
- [ ] With `$ZMURAL_CONFIG_DIR`'s parent missing, zmural runs without a log (test setups only)
- [ ] A week of daily use on both OSes (sleep and resume, monitor hotplug), with a soak test for the parts a rig can run
- [ ] Two real monitors on Windows, once someone has them

## 0.3: Monitors

- [ ] A view of what each monitor shows, in the window (today only `zmural-console status` says)
- [ ] Properties per monitor (a monitor's own wallpaper has none, and one wallpaper on two monitors shares one set)
- [ ] Rotation per monitor; pausing one monitor (`pause --monitor` is refused)
- [ ] Windows: a wallpaper package as a monitor's own wallpaper (only plain files today)
- [ ] zip64, so `export` can write more than 4 GiB

## 0.4: Web wallpapers on Linux, and wallpapers that react

- [ ] Web wallpapers on Linux: WebKitGTK, always offline, the Windows renderer's hardening, and only with WebKit's own sandbox on
- [ ] The JS API beyond properties, both OSes: audio spectrum (WASAPI loopback / PipeWire, 128 bins), now playing, system stats, pause events
- [ ] Mouse input for web wallpapers
- [ ] The Lively JS shim (`livelyPropertyListener`), so imported Lively pages hear property changes

## 0.5: Trust and distribution

The open security issues (below) and the ways zmural reaches people and updates.

- [ ] Renderer sandbox (S1): Windows a restricted token or AppContainer; Linux to be designed (seccomp and Landlock are the candidates)
- [ ] An AppContainer without network for the Windows web renderer (S2, S9)
- [ ] Clean up web wallpapers' browser profiles that nothing uses any more (S10)
- [ ] Code-signed Windows releases, and a GitHub Releases update check verified against a key built into zmural (off until the first signed release) (S8)
- [ ] Linux packages that bring their own updates: a Flatpak (it also brings H.264/H.265 GPU decoding to Fedora and openSUSE) and a Fedora COPR
- [ ] The plugin self-upgrade zmural has for KDE, for the GNOME extension too

## 1.0: Stable

When there is no open high or medium bug, every control has a real-input test on Linux and a
recorded pass on Windows, a week of daily use on both OSes went clean, and Windows releases are
signed.

## Later

- Span one wallpaper across monitors (the Linux daemon doesn't know where monitors are yet: xdg-output, or a layout setting)
- Transitions between wallpapers; blur while paused
- Screensaver mode (Windows `.scr`; Linux not designed)
- Languages other than English
- A name filter for the library, if libraries grow past what thumbnails show at a glance (tags: decided against, below)
- Niri: `covered` and fullscreen on hidden workspaces, once its IPC says where windows are (upstream)

## Decided against

Settled, so they aren't proposed again: an online gallery (zmural is not a service); an installer
(unzip is enough; zmural has an uninstaller); plugins, third-party renderers or programs as
wallpapers; web addresses as wallpapers or any network for a wallpaper; screen-reader support
in the settings window (`zmural-console` does everything it does); restarting itself after a
crash; tags for wallpapers (a library is the user's own folders, which thumbnails show; tags are for big catalogues like waywallen's Wallhaven and Workshop sources, which zmural doesn't have); choosing or combining GPUs (zmural stays on the desktop's own); Windows 10.

## Known security issues

Open issues, in the README's words under [Security](../README.md#security). Every new one found goes here and there.

| # | OS | Issue | Plan |
|---|---|---|---|
| S1 | both | Video/image renderers aren't sandboxed: a decoder exploit could read the user's files | 0.5 |
| S2 | Windows | The web renderer's job has no UI limits (Chromium's sandbox won't start under any); the web renderer and WebView2's browser process run with the user's rights; pages are in Chromium's sandbox | 0.5: an AppContainer for the whole web renderer |
| S3 | Windows | A page can read its whole folder tree; it is offline, so only a way around the offline mode (S9) could send files out | with S9 |
| S7 | Windows | Web pages may play sound once the user unmutes | by design (muted by default); documented |
| S8 | both | Releases aren't code-signed and there is no updater | 0.5 |
| S9 | Windows | Offline mode is Chromium proxy flags, not a firewall rule | 0.5: an AppContainer without network capabilities |
| S10 | Windows | Every web wallpaper's browser profile stays in `%LOCALAPPDATA%\zmural\webview2` until uninstall | 0.5 |

Fixed issues and audits are in the retired plan.
