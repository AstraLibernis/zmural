# Stopping point: 2026-09-28

**Read this first. `stopping-point-2026-09-27.md` is history, but its queued work (below) is still open.**

## Where things stand

Everything is on `main` and pushed. There is no CI (removed at the owner's request): the owner tests Windows by hand, so say when a change touches Windows or shared code. The stale `m6-linux` branch on GitHub is for the owner to delete (MILESTONES, Housekeeping).

**M6 (Linux) did most of its work today.** See the M6 section of `docs/MILESTONES.md` for what's done and how it was tested. In short:
- **Display:** zero-copy video and images on wlr-layer-shell compositors. The display protocol is waywallen-display-v1 v9.
- **KDE and GNOME:** waywallen-display's Plasma plugin and GNOME extension are vendored. zmurald installs them itself and says so in a notification.
- **Daemon:** a control socket and CLI, one zmurald per session (with takeover), and start at login.
- **Settings window:** shared with Windows. The tray icon is StatusNotifierItem.
- **Launcher:** one settings window per user, plus a `.desktop` launcher and icons.

**The settings UI is shared by both OSes now:**
- `src/settings/app.zig` holds the pages and `gui.zig` the widgets.
- The drawing backends are `gui_d2d.zig` and `gui_cairo.zig`.
- The platform files are `platform_windows.zig` and `platform_linux.zig`.
- `settings/main.zig` only dispatches.

Any change to the pages therefore touches Windows. The Windows side of this refactor has only been cross-compiled; **the owner still has to test it on Windows.**

## Tests on Linux (all headless, in the dev container)

- `zig build test`, and `zig build check` (compile only; zcanon's background compiler uses it).
- `tools/instance-test.sh`: single-instance and takeover, 22 scenarios.
- `tools/kde-test/run.sh`: Plasma 6 tray, menu, launcher, one settings window. 8 checks.
- `tools/gnome-test/run.sh`: GNOME Shell extension install, then the wallpaper after re-login (screenshots). It installs the extension into the real `~`, since GNOME Shell reads it from there.
- `tools/linux-matrix.sh`: the desktop matrix.
- Scripted clicks in the settings window: `zmural-test-input` (`tools/wl-input.zig`) on Sway.

Test scripts must point `XDG_CONFIG_HOME` / `XDG_DATA_HOME` at a temp dir. Otherwise zmurald writes its autostart entry, launcher and plugins into the real home. Since today an empty or relative XDG variable counts as unset (`os/xdg.zig`); before that, zmurald wrote into its working directory.

## Open, in rough order

- **Owner:** test the shared settings window on Windows. Delete `m6-linux`.
- **M6 gaps:**
  - zmurald spawning `zmural-layer-shell` itself (backend selection);
  - UPower / logind / GameMode pause rules; compositor IPC for workspaces and `covered`;
  - the renderer's real acquire fence (it uses `glFinish` today);
  - multi-plane buffers; WebKitGTK web wallpapers; an X11 / portal static fallback. (The Linux log file was done on 2026-09-30.)
- **From 2026-09-27, still queued:**
  - the Customise panel. Its plan is in the older note; the code now goes in `app.zig`, and the colour picker needs a Linux counterpart, e.g. the Screenshot portal's `PickColor`, or a swatch grid;
  - one exe instead of seven;
  - settings only in the window;
  - the rest of M7.
