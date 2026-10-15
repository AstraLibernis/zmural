# Windows pass: main after 0.1.1, 2026-10-14

The Windows-only items left by the commits after the 0.1.1 pass (ae58779..17fd1b7), and a fresh
install from scratch. Windows 11 Pro 26200, one 2560x1440 monitor, main at 17fd1b7.

- `zig build test`: 223 pass, 16 skip (Linux-only), 0 fail.
- Live tests: a dev build with `ZMURAL_CONFIG_DIR` in a scratch folder, the owner's zmural quit
  first (the control pipe is per user and session, so two can't run side by side).
- Fresh install: `zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-windows` from main.

## Results

| # | Check | Result |
|---|---|---|
| 1 | Video renderer suspended (NtSuspendProcess, as Resource Monitor does) | **PASS**: "no answer for 10 s (stopped or hung)", replaced 14.8 s after the suspend, playing again |
| 2a | Video cut to 0 bytes while it plays | **FAIL**: not caught in 60 s. The renderer goes on using ~3.4 cores (34 s of CPU in 10 s; a healthy one: 0.67 s), logs nothing after the first few mpv errors, and is never restarted |
| 2b | Video cut to 4096 bytes while it plays | **FAIL**: not caught in 60 s. mpv loops about every 0.3 s on broken packets (~14 log lines a second); `core-idle` never stays on for 10 s |
| 3 | No false restarts: video paused 30 s, still picture 30 s, GIF 30 s, a GIF holding one frame 16 s (40 s) | **PASS**: the same renderer throughout, no warnings |
| 4 | Picture, then a video; the video's renderer frozen and its file cut to 0: the restart can't load it | **PASS**: "cannot play 'gone.mp4': unrecognized file format", the picture back, the notice logged |
| 5 | `zmural-console status` gives the main fill mode | **PASS**: `fill      : crop` (and `fit` with the owner's settings) |
| 6 | `ZMURAL_CONFIG_DIR` with two missing folders above it | **PASS**: the folders and the log were made |

Linux's `tools/watchdog-test.sh` cuts a small mpeg4 clip to 0 bytes, and there mpv goes idle. On
Windows the 1080p H.264 Sintel trailer (13.9 MB, d3d11va) never goes idle: `core-idle` is not
enough of a sign by itself here. Candidates: also count "time-pos hasn't moved" (with care for
the loop's seek back and for a GIF's long frame), or end on a run of decode errors with no new
frame. Whether Linux catches an H.264 file cut to its header is untested.

## Fresh install ("a new user")

The owner's settings were backed up first (scratchpad) and put back at the end.

- **Uninstall** with the installed 0.1.1's `zmural-console uninstall`: it asks first; with its
  console's input not a terminal it says "Nothing was removed" (a piped `y` isn't read; `--yes`
  is the scripted way). With `--yes`: start at login, Start menu shortcut, the Apps entry,
  Roaming\zmural and Local\zmural removed, each named; the library untouched (7 files, same
  bytes). It ends "To finish, delete zmural's own folder".
- **Install:** the zip unpacked into `%LOCALAPPDATA%\Programs` (`zmural-0.1.1-windows-x86_64`,
  renamed `zmural`). First start: Welcome opens, Prism plays (a `zmural.surface` under Progman,
  visible), start at login on (with its notice logged), Start menu and Apps entries made, the
  watchdog process running, no settings.toml yet.
- **First-run rules:** quit with nothing chosen leaves no settings.toml, and the next start is a
  first run again (Welcome); after an `apply` of a library video settings.toml is saved, and the
  next start is not a first run.
- The owner's settings.toml put back; their wallpaper, fill, shuffle and rotation came back;
  start at login on. Their install is now this build of main (still says 0.1.1).

## Not done here (needs the owner at the PC)

Lock screen, sleep and wake; a game in exclusive fullscreen; SmartScreen on a browser-downloaded
zip; a web wallpaper through an Explorer restart; a second `zmural --settings`; the soak test;
a real login after the fresh install (start at login is set, not yet seen at a login).
