# End of day: 2026-09-30

**Read this first.** What changed today, what the owner decided, how much of it is proven,
and what is waiting on whom. `docs/MILESTONES.md` has each item in detail; `docs/RELEASING.md`
explains working and released builds. 46 commits, all on `main`.

**Names changed today.** The app is `zmural` (it was `zmurald`) and the command line is
`zmural-console` (it was `zmural`); the log is `zmural.log`. Notes from before today use the
old names.

## At a glance

| Milestone | Done | Open | Today |
|---|---|---|---|
| M0–M4 | 39 | 0 | |
| M5 Windows MVP | 47 | 2 | two programs instead of seven, the settings window inside zmural, the renaming, keyboard navigation |
| M6 Linux MVP | 30 | 4 | from 24 done / 7 open this morning |
| M7 Wallpapers that do more | 7 | 7 | adjustments and Customise, web wallpapers always offline |
| M8 Polish | 6 | 6 | per-monitor wallpaper and fill, Linux tarball, stripped releases, crash log, uninstaller |
| M9 Later | 1 | 1 | |

## What changed

**Linux (M6)**
- A log file (`~/.local/state/zmural/zmural.log`) with local time; `settings.toml` edits
  picked up while running.
- Three bugs from the owner's Plasma session fixed: fullscreen pause on Plasma, the settings
  window crashing on close, a leftover zombie process.
- Video decoded on the GPU through VA-API, logged per video, and one notice per format that
  can't be ("No GPU decoder for H.264 found"); never for pictures. zmural installs no codecs.
- The "listed app in front" rule: on KDE Plasma (a KWin script), on Sway and on Niri (their
  IPC).
- zmural starts and supervises its own display host on Sway-like desktops: restarted if it
  dies, never two on one display, gone when zmural quits or is killed.
- Sway's IPC gives the window facts: a fullscreen window on a hidden workspace no longer
  pauses the wallpaper forever; the "covered" rule works on Sway.
- Renamed or translated Videos and Pictures folders are followed (xdg-user-dirs).
- Frames carry their GPU fence instead of waiting for the GPU (no CPU change measured).
- Where nothing live can show (X11, no layer-shell), the picture is set as a still wallpaper
  through the wallpaper portal, and the user is told once.

**Both OSes**
- A different wallpaper and fill mode per monitor (command line, settings file, the window's
  right-click menu).
- Adjustments for plain videos and pictures (brightness, contrast, saturation, gamma, hue,
  speed) and the Customise section in the settings window.
- Web wallpapers are pages saved on the computer, always offline; web addresses are refused.
- Two programs instead of seven: renderers, the watchdog and the display host are modes of
  `zmural`, and the settings window is a thread inside it.
- The settings window works by keyboard: Tab, arrows, Enter/Space, the Menu key, Escape; a
  focus ring after a key is used.
- An uninstaller: `zmural-console uninstall` or the General page's button. It asks first,
  removes only what zmural added, and never touches wallpapers or their folders.
- Crashes, from any part of zmural, are written into `zmural.log` with their addresses.

**Releases and CI**
- A Linux tarball (`zig build package -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.36`,
  about 1.4 MB), tried inside Debian 12 with Debian's own libraries.
- Released builds are stripped, and their debugging info is kept beside the download to read
  crash reports with (`docs/RELEASING.md`).
- CI builds and runs the Windows release zip from an empty folder (libmpv fetched and
  hash-checked). CI now runs only by hand, for a `v*`/`milestone-*` tag, or with `[full ci]` in
  the commit message.

## Decisions the owner made today

- Both OSes are equals in the docs; one codebase, built separately per OS.
- Codecs: use what the system has, fall back to the CPU, tell once; never install or bundle
  them. Linux isn't "Flatpak only".
- Security first: built-in renderers only (no plugins or third-party renderers, no programs as
  wallpapers); web wallpapers always offline, no web addresses.
- One zmural to install and launch; the settings window inside zmural's process ("if it breaks,
  it breaks together"); the names `zmural` and `zmural-console`.
- No publishing until most milestones are done. No real installer: unzipping is enough, plus
  the uninstaller.
- CI only after a milestone or a major push; Linux is tested by the owner at home.
- Bugs are logged (the crash log) and fixed as they come; no symbol maps.

## How much of it is proven

| Where | What |
|---|---|
| Unit tests (164 pass, 5 skipped on Linux) | Pure logic, on both OSes in CI |
| 17 Linux test rigs here, all passing at the end of the day | Everything above that runs on Linux, on headless Sway, Plasma, Niri, Mutter and Debian 12; counts in `docs/MILESTONES.md` |
| CI on a Windows runner (passed at the end of the day) | zmural boots, the settings window opens, the release zip runs from an empty folder, a crash lands in the log, the uninstaller removes zmural's files and keeps the wallpaper and the program |
| The owner's real desktops | Plasma: `main` e0815f5, the evening's full pass in `notes/host-test-2026-09-30.md` (the three morning bugs confirmed fixed; CLI, tray, settings window, pause rules, CPU-decode notice, audio, adjustments, watchdog, crash log, uninstall/reinstall and the tarball install all seen working; nine small findings). Windows: nothing since 2026-09-29 |

Not seen by anyone yet: today's work on Windows (keyboard use, per-monitor menu, uninstaller). The Linux settings window by keyboard was tried by the owner after a re-login: it works as coded, but arrows should be spatial and Escape should close the window (findings 10 and 11 in `notes/host-test-2026-09-30.md`).

## Waiting on the owner

1. ~~**Try Linux at home** on the Plasma desktop.~~ Done the same evening, first as a host build of
   e0815f5, then as the tarball itself (built here after `tools/sandbox-deps.sh plugins`):
   see `notes/host-test-2026-09-30.md`, "Evening redeploy" and "Later the same evening".
   The "No GPU decoder" notice was seen with a VP8 clip. The twelve findings there are the
   next fixes; 12 (4 s freeze on open), 10 and 11 (arrows, Escape) are the ones the owner felt.
2. **A look at Windows**: the settings window by keyboard, the per-monitor menu, the
   uninstaller (all compiled and CI-tested, never seen).
3. Whether the notes should lose the details of the owner's desktop before the repository is
   ever made public (discussed; the owner chose to keep it private for now).

## Loose ends

- Once during a keyboard-test run, zmural logged the quit and the window closing, then didn't
  exit. Not reproduced in seven tries since.
- The Windows CI job's Zig download sometimes stalls for many minutes (ziglang.org).
- `src/cli/main.zig` and two other files aren't `zig fmt`-clean (from before today).

## Next

First, the twelve findings from the owner's desktop in `notes/host-test-2026-09-30.md`,
starting with 12 (the window freezes ~4 s on open: re-entrant D-Bus `call()` from the
`SettingChanged` hook, a real bug), then 10 and 11 (spatial arrows, Escape closes the
window) and 1 (`status` should name an automatic pause). Then the work order at the top of `docs/MILESTONES.md`. What can be proven here: web wallpapers on
Linux (M7, the largest gap between the OSes), then `.zip` packages and Lively import. Left for
a real desktop: Hyprland, the GNOME extension's app rule, the still picture on KDE/GNOME before
their plugin runs, span across monitors, screen-reader support.

## In the dev container

The test stack (`tools/sandbox-deps.sh plugins rigs tests`, now with `wtype`) goes with every
container restart; `--check` says what is missing. `tools/package-debian-test.sh` downloads a
Debian 12 root once (about 100 MB) and needs sudo for apt.
