# Windows pass: 0.1.1, 2026-10-12

The Windows pass of [WINDOWS-PASS.md](../docs/WINDOWS-PASS.md) on the v0.1.1 draft's zip
(CI run 38317696495 from e6c99dc, SHA256 5fda09f7…6e32), done by a **blind tester**: an agent
given only the zip, its README, the checklist and a window-driving helper (posted mouse and key
messages, PrintWindow of zmural's own windows; never a full-screen capture), with no source code.
Windows 11 Pro 26200, one 2560x1440 monitor, Do Not Disturb on (it drops every tray balloon).

Before it: on Windows, `zig build test` 213 pass, 32 skip (Linux-only), 0 fail;
`zig build check -Dtarget=x86_64-linux` compiles. CI by hand on `main`: windows, linux, release
all green. (Git Bash: `zig build` fails with "unable to read results of configure phase";
PowerShell works.)

**Result: 45 lines, 41 PASS, 1 FAIL, 3 N/A.** N/A: SmartScreen (`gh release download` leaves no
Mark of the Web), two monitors (one here), the hand-edit balloon (see F1).

## How it ran

- **A. Uninstall 0.1.0** from its own window (General > Uninstall > Yes): asked first; the done
  message listed every step and ended "To finish, delete zmural's own folder". Processes, Run
  value, `zmural.lnk`, the Uninstall key, Roaming\zmural and Local\zmural all gone; only the
  program folder left, as it said.
- **B. Install 0.1.1** by the zip's README into `%LOCALAPPDATA%\Programs` (it made
  `zmural-0.1.1-windows-x86_64`; renamed to `zmural`, see F8).
- **C. The checklist:** every line below Install passed: the tray (left click, and every item of
  the right-click menu by a real right click), sidebar, player card (incl. "Paused: a window is
  maximized"), Welcome (tiles, Open, Add folder, Open file, zip import), Wallpapers (Rescan, tile
  click, Show on desktop / in folder, "sun.png · Beaches" / "sun.png · Sunsets"), Playback (fill
  modes seen on the desktop, volume, mute, pause, rotation, order, Customise brightness 39 → 226
  → Reset 39), Pausing (Nothing/Mute/Pause/Stop with a borderless fullscreen window, Add app and
  ×, a 3800 ms resume wait measured at 4.0 s), General (start with Windows via StartupApproved,
  folders, Log file > Open, Reset No/Yes, Uninstall No), keyboard, video/picture/GIF/web page,
  a `.txt` renamed `.mp4` (refused, the picture came back), the CLI (`status`, `apply` bad → 1,
  good → 0, `export`, `import`), Explorer restart (wallpaper and tray icon back).
- **D. Uninstall 0.1.1:** gone within 1.5 s, every entry and both folders removed;
  `Videos\Wallpapers` matched its baseline exactly.
- **E. Reinstalled** 0.1.1; a `zmural.surface` under Progman showing Prism; `status` answers.
  The owner's settings were restored from a backup afterwards.

No crash, panic or renderer death in the log.

## Findings

| # | Sev | Finding | What was done |
|---|---|---|---|
| F1 | med | The "zmural will start with Windows" balloon left nothing in the log, so with Do Not Disturb on there was no proof it was sent (the FAIL). The hand-edit balloon, likewise. | **Fixed:** every Windows tray balloon logs `notice: <title>: <text>` (`Tray.balloon`); the can't-show notice no longer logs twice. Seen live: the hand-edit notice logged once. |
| F3 | low | The settings warning said `line 31: BadValue; using defaults` even mid-run, when the running settings were kept. | **Fixed:** the log line uses the notice's words ("line 31 has a value zmural can't use") and says "keeping the current settings" unless the file was bad at start. Seen live, both cases. |
| F8 | low (docs) | The zip makes a versioned folder, so "unzip the new version over this folder" makes a second folder instead. | **Fixed docs:** README, both packages' README.txt and the 0.1.1 notes say: unpack next to the old folder, start the new one (start at login, Start menu and Settings > Apps follow it: zmural rewrites them when it has moved), delete the old one. |
| F6 | — | A change in the window while settings.toml has a bad line isn't saved. | By design: the notice (F1, now in the log) says zmural "won't change the file until it reads again". |
| F2 | low-med | General's library folder rows cut long paths at the end; three folders under one parent read alike, so which × removes which is unclear. | Open (0.2), with the narrow-width row bug. |
| F9 | cosmetic | Descriptions cut off at the default 1000x680 window (Playback > Change wallpaper automatically, Pausing > Wait before resuming). | Open (0.2), same row-layout bug. |
| F4 | low | "Show in folder" once opened the folder with nothing selected; later tries selected the file. | Open (0.2), not reproduced. |
| F5 | low | The folder picker opened in C:\Windows\System32 (zmural started from a shell in System32). | Open (0.2): start pickers in the library folder. |
| F7 | cosmetic | The Stop rule shows as "Paused: an app is fullscreen" (the renderer is stopped). | Open (0.2). |
| F10 | cosmetic | A failed `apply` followed at once by a good one: the late notice said "That monitor shows the main wallpaper again". End state right. | Open (0.2). |
| F11 | cosmetic | The bundled Prism.webm logs mpv's "Discarding potentially broken or useless index" each time. | Open (0.2): remux Prism with a cue index. |
