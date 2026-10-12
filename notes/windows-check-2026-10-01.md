# Windows test report: 2026-10-01

The first Windows run since 2026-09-29 (everything from the 96 commits made on Linux and WSL
since then). Windows 11 25H2, one 2560x1440 monitor, RX 9070 XT. In three passes: while the
owner played a fullscreen game (builds, the release zip, crash reports, then zmural from the
command line with an isolated `ZMURAL_CONFIG_DIR`), then with the desktop (the settings
window driven by keyboard, screenshots of zmural's own windows only), then installing the
release for real. The detailed log follows the summary.

## Summary

**Result:** everything since 2026-09-29 works on Windows after eleven fixes, all tried there.
`zig build test`: 172/186 pass, 14 skipped (Linux-only). The release is installed at
`%LOCALAPPDATA%\Programs\zmural` and left running with the owner's own settings.

| Area | Result |
|---|---|
| Unit tests | ✅ after the dbus test got its Linux-only skip (db0964c) |
| One program (watchdog and renderers as modes of `zmural.exe`) | ✅ |
| `status` names why it paused (`fullscreen, covered`, `by you; ...`) | ✅ |
| Settings folder made on first start | ✅ |
| Command line: fill (main and per monitor), props, mute, order, rotate, refusals | ✅ |
| Rotation: clock waits while paused; a change while playing | ✅ |
| `settings.toml` edited by hand, picked up live | ✅ |
| Renderer killed: restarted after its backoff | ✅ |
| Settings window: drawing, Customise section, keyboard, Menu key, Escape, No-default question | ✅ after 81cd693, 3b20fdd |
| Uninstall | ✅ after bdd94d0 (it raced zmural's shutdown: FileBusy) |
| Release zip: contents, stripped, runs from an empty folder (video with `d3d11va`) | ✅ after 4ea0507 (it shipped stale exes) |
| Crash lines, codes, `crash-code` (zmural and a renderer, panic and fault) | ✅ |
| `zig build crashcode` on a Windows code | ✅ after cf61d47 (it only printed an unusable command) |
| Invalid UTF-8 in drawn text (S11) | ✅ fixed in 9ae02d5, unit-tested |
| Crash tray notice | ⚠️ sent and accepted, but unseen: Windows drops tray balloons under Do Not Disturb |
| Start menu, Search, Settings > Apps | ✅ new in b9f7b34 (owner's request) |
| Rescan button in the settings window | ✅ new in 40e2f0a (owner's request) |
| Uninstall with the registered command, then a fresh reinstall | ✅ everything zmural added removed, wallpapers kept; the reinstall set itself up again |
| Explorer restart | ✅ wallpaper re-attached in ~2.5 s, same renderer; the tray icon only after the fix below |
| Switching wallpapers (Next, Previous, rotation, fill, a pick) | ✅ after 90e9000: the desktop no longer shows through for ~1 s |

**Commits from this test:** db0964c (dbus test skip, findings, S11 noted), bdd94d0 (uninstall
waits for the process), 81cd693 (No default; held keys), 3b20fdd (Menu key), 9ae02d5 (S11),
4ea0507 (archives list their files), cf61d47 (crashcode via dbghelp), 62f28c4 and a358185
(notes; a log line when a tray notice fails), b9f7b34 (listed as an app), 40e2f0a (Rescan),
b9fc210 (the tray icon after an Explorer restart), 90e9000 (no desktop flash on a switch).

**Still open** (also in MILESTONES, M8 "From the Windows test of 2026-10-01"):
- A crash notice nobody sees is lost (the code is taken as the balloon is sent), and a
  renderer crashing in a loop sends one per crash.
- Review finding 5: Zig's crash handler, now in the process the settings window runs in,
  treats a shell extension's caught access violation as fatal. Not seen, not fixed.
- Review finding 6 (minor) and `status` not showing the main fill mode.
- A web wallpaper has no first-frame signal yet, so on a switch to one the old wallpaper
  stays its full 4 s (seamless, just slower).
- Windows' own "Next desktop background" in the desktop menu (Spotlight, here) changes the
  hidden Windows picture behind zmural; left alone by the owner's decision (see below).
- Not tried: clicking Uninstall in the Settings > Apps page itself (its command was run
  directly instead, which is what that button runs), web wallpapers, multi-monitor (one
  monitor here).

## Ran while the owner played (no desktop)

- `zig build test`: one failure, `os/dbus.zig`'s re-entry test calls `linux.socketpair`
  without the Linux-only skip. Fixed in db0964c. Then 170/184 pass, 14 skip.
- `zig build package -Doptimize=ReleaseSafe`: builds, but **the zip ships whatever is
  already in `zig-out/package/<name>/`**: here six 2026-09-27 exes (`zmurald.exe`,
  `zmural-video/image/web/watchdog/settings.exe`). CI never sees it (fresh runner).
  Fixed in 4ea0507 (the archives name their files). After a clean: the right files, no
  build paths in the exes (only the `zmural.pdb` / `zmural-console.pdb` names).
- Crash reports from the release build, `ZMURAL_TEST_CRASH` = `zmural:panic|fault` and
  `renderer:panic|fault` (`--renderer image`), isolated `ZMURAL_CONFIG_DIR`: all four
  logged in local time with the part name, addresses and a code, plus `crash-code`.
  Exit code 3. The tray balloon wasn't tried (needs a real start).
- **Decoding Windows codes:** `zig build crashcode` only prints an `llvm-symbolizer`
  command (not installed here, not shipped with Zig, and it wants the exe, not the
  `.pdb`). Decoded instead with the system `dbghelp.dll` (SymLoadModuleExW on the
  packaged exe at a fixed base, search path = the debug folder): every address came out
  right (`testCrash` main.zig:150/152, `main` main.zig:76/77, `WinStartup`). The tool
  does this itself since cf61d47, from the `.pdb` alone.

## Live, from the command line (owner in a fullscreen game; no window, no screenshot)

Debug build, isolated `ZMURAL_CONFIG_DIR`, `zmural.exe --apply webb-cosmic-cliffs.jpg`:

- Finding 2: the settings folder didn't exist and was made at start. **Works.**
- Finding 1: `paused : yes (fullscreen, covered)` with the game in front; after `pause`,
  `yes (by you; fullscreen, covered)`. **Works.**
- One program: zmural started `zmural.exe --watchdog --parent <pid>` and
  `zmural.exe --renderer image --ipc ...`; `next`/`previous` swapped image and video
  renderers (video got `hwdec=d3d11va`). **Works.**
- `fill fit`, `fill center --monitor 1` (shown in status), `fill default --monitor 1`;
  `props`, `prop brightness -20`, out-of-range refused, `prop --reset`; a web address and
  a missing file refused with clear messages; mute/unmute, order, rotate. **All work.**
  (Status shows a monitor's own fill but not the main fill mode.)
- Rotation 1 min with 3 wallpapers: the clock stayed at "next in 1:00" for 75 s while
  the fullscreen rule held the pause. **Works.** (Advancing while playing: not seen.)
- `settings.toml` edited by hand (library folder) was picked up live. **Works.**
- Renderer killed with `taskkill /f`: "connection ended", restarted after 2000 ms. **Works.**
- **`uninstall --yes`: fails, review finding 1 confirmed.** zmural stops, then
  `couldn't remove its settings and log (...): FileBusy`, exit 1; `settings.toml` and
  `zmural.log` remain, even though no zmural process was left 0 s later. On Windows the
  default (non-`ZMURAL_CONFIG_DIR`) case has the same log, in `%LOCALAPPDATA%\zmural`.

## Static review of the Windows paths (since 2026-09-29), to check live

1. Uninstall races the daemon's shutdown: the uninstaller deletes once the pipe closes,
   while zmurald still saves `settings.toml` and holds `zmural.log` open (no
   FILE_SHARE_DELETE). Expect "couldn't remove its log" or a recreated settings.toml.
   Fix: wait on the daemon's process handle.
2. **Confirmed in code:** the Uninstall/Reset question is `MB_YESNO` with Yes as default
   (`platform_windows.zig:214`, no `MB_DEFBUTTON2`), unlike "No focused" in the docs.
   And `keyDown` ignores WM_KEYDOWN repeats (Linux repeats only Tab/arrows), so a held
   Enter can press Uninstall and then answer Yes.
3. Menu key / Shift+F10: `lp == -1` likely never matches on x64 (lParam is
   0x00000000FFFFFFFF); compare the low 32 bits.
4. **Confirmed in code:** invalid UTF-8 in drawn text panics in `gui_d2d.zig` `toWide`.
   Security item S11 (README limitation 8).
5. The settings window inside the daemon: Zig's vectored segfault handler treats any
   first-chance access violation as fatal, and the file picker / thumbnails load
   third-party shell extensions that raise and catch their own. Could now kill zmural.
6. Minor: right-click after keyboard use opens the menu at the focused tile; queued
   thumbnails leak on close; a second `zmural --settings` may only flash the taskbar;
   `raise()` uses ShowWindow across threads (ShowWindowAsync avoids a stall).

## Fixed the same evening (each its own commit), and retested

| Finding | Commit | Retest |
|---|---|---|
| Uninstall FileBusy race | bdd94d0 waits on the process | 3/3 debug runs + the unzipped release: exit 0, folder gone, not recreated |
| Default Yes in reset/uninstall; held keys repeat | 81cd693 MB_DEFBUTTON2, repeats only Tab/arrows | in the window: No focused, Enter answers No; held Enter/Space do nothing |
| Menu key / Shift+F10 | 3b20fdd low half of lParam | in the window: both open the wallpaper's menu |
| S11 invalid UTF-8 | 9ae02d5 lenient `toUtf16` | unit test (186 tests now) |
| Zip ships stale files | 4ea0507 archives list their files | a planted stale exe stayed out of the zip |
| crashcode on Windows | cf61d47 dbghelp.dll + the .pdb alone | fresh release crash decoded to testCrash main.zig:152 |

Release zip unzipped into an empty folder: starts, the Sintel trailer plays
(`hwdec=d3d11va`), status answers, uninstall is clean.

The window, the crash notice and rotation while playing were tried with the desktop next.

## With the owner's desktop (19:15-19:25)

Debug build, isolated settings folder, keys posted to the window or sent as real key presses,
screenshots of the zmural window only.

- Settings window draws right (wallpapers, player card, Playback, General).
- Tab walks the groups (pages, player card, buttons above the wallpapers, the page; on
  General there are three). Right/Left/Down/Home/End in the grid as designed. **Works.**
- Held Enter and held Space do nothing; a plain Enter applies the focused wallpaper; a held
  Tab repeats. **Fix 81cd693 works.**
- The real Menu key and Shift+F10 open a wallpaper's menu ("Show on desktop", "Show in
  folder"); Escape closes the menu, then a second Escape closes the window, and zmural keeps
  running. **Fix 3b20fdd works.**
- Uninstall's question opens with **No** focused; Enter answers No and nothing is removed.
  **Fix 81cd693 works.** Its text named a "desktop plugin", which Windows doesn't have
  (worded per OS since b9f7b34).
- Customise: Brightness/Contrast/Gamma sliders drawn; the arrow keys move one live (gamma 20
  in `props`). **Works.** Home/End on a choice row or slider pick its first/last value
  (Windows' own convention; End on Fit set Center).
- Rotation while playing: 1 min, webb → rotating-earth after 66 s. **Works.**
- Crash notice: both kinds are sent (`told the user about a crash`, `crash-code` removed),
  and `Shell_NotifyIconW` returns success (now logged when it doesn't). **But nothing showed,
  not even in the notification list, and neither did a PowerShell NotifyIcon balloon sent as a
  control:** with Do Not Disturb on, Windows drops tray balloons entirely. So a crash
  can go unnoticed: the code is taken (file removed) as it's "told". Ideas: keep it for the
  settings window to show next time it opens, or only remove it once a balloon was clicked.
  Also, a renderer crashing in a loop sends a notice per crash (every 8-10 s) until give-up.
- Test-only: with `ZMURAL_CONFIG_DIR`'s parent missing, zmural runs without a log (the log is
  opened before the folder is made, non-recursively). Real installs always have the parent.

## Installed for the owner, and two requests (19:25-19:40)

- The release zip, unzipped to `%LOCALAPPDATA%\Programs\zmural`, runs with the owner's own
  settings (`%APPDATA%\zmural`); library `Videos\Wallpapers`, now holding the owner's videos.
  Start at login is off.
- Search found zmural only as a folder. b9f7b34: zmural writes a Start menu shortcut
  (`--settings`) and an HKCU Uninstall entry when it starts. Checked: both written once, not
  rewritten on a restart, the shortcut's target, arguments and icon right; the entry's
  UninstallString is `"...\zmural.exe" --uninstall --from-window`.
- 40e2f0a: a Rescan button left of Open file. A file added to a library folder appeared after
  it (9 -> 10); the row fits at 1000, 870 and 600 px wide (labels drop, Rescan's first).
- A saved wallpaper whose file was deleted leaves zmural showing nothing at the next start
  (`not showing '...': no such file`), as designed.

## Uninstall, reinstall and an Explorer restart (19:43-19:49)

- **Uninstall** with the exact UninstallString Settings > Apps runs (`"...\zmural.exe"
  --uninstall --from-window`), the owner's settings backed up first. Its message box listed:
  stopped zmural, removed start at login, the Start menu shortcut, the Settings > Apps entry,
  `%APPDATA%\zmural` and `%LOCALAPPDATA%\zmural`; "Not touched: your wallpapers"; "To finish,
  delete zmural's own folder". Checked afterwards: all of those gone, no zmural running, the 7
  videos in `Videos\Wallpapers` still there. The program folder was then deleted by hand.
- **Reinstall** (unzip, run `zmural.exe` with no arguments): settings folder and log made, the
  shortcut and Apps entry written, the 7 videos found. The owner's `settings.toml` was put
  back and start at login turned on again (uninstall removes it, by design).
- **Explorer restart** (`taskkill /f /im explorer.exe`, then `explorer.exe`): zmural logged
  "desktop layer destroyed; re-attaching", retried every 0.5 s until the new Progman existed,
  and re-attached in ~2.5 s (raised layout, new Explorer pid), its surface again a child of
  Progman. The video renderer kept running (same process, 4K60 `d3d11va`). **But the tray icon
  didn't come back** (owner checked): the TaskbarCreated handler re-added it only when the
  Explorer pid differed from the host's, and the desktop's own re-attach had already recorded
  the new pid. Fixed: TaskbarCreated always restores the icon (NIM_MODIFY, else NIM_ADD, so a
  DPI-change broadcast doesn't add a second), and logs "tray: icon added again". Retried with
  the installed release: logged, and the owner saw the star back and opening the window.

## Switching flashed the desktop wallpaper (19:50-20:00)

Owner: "> Next or < Previous causes the current background to disappear, the standard windows
wallpaper to appear for a second, then the next one to appear."

- **Cause.** Every switch goes through `reroute()`, which stopped every renderer and then
  started the new one. Sampling the desktop's `zmural.surface` windows every 30 ms around a
  Next showed the old window gone at ~80 ms and the new one attached at ~140 ms, but the new
  window is a layered child of Progman (raised layout) and stays see-through until mpv draws
  its first frame, about a second later for a 4K video: that was the Windows wallpaper showing.
- **Fix (90e9000).** What shows now stays until its replacement has drawn. `reroute()` keeps
  the running renderers as *outgoing* for the monitors they fed; the new renderer's window is
  attached directly beneath the old one; the new renderer sends a new `shown` message
  (protocol op 9) at mpv's first playback-restart, and the old renderer is retired then, after
  4 s at the latest, or at once if a pause rule keeps the new one from starting. New monitors
  still re-route from scratch (`rerouteFresh`). Next, Previous, rotation, a fill change and a
  wallpaper picked in the window all take this path.
- **Measured** with the same sampling: old over new for ~0.3 s, then the new one alone, never
  a moment without a zmural window, three Nexts in a row and two Nexts 120 ms apart (it
  settled on the newest, the other two retired). Installed on the owner's copy.

**Not zmural:** right-click desktop > "Next desktop background" did nothing visible. The
owner's Windows background is Windows Spotlight (`BackgroundType` 3), and that item is
Spotlight's own: it changes the Windows picture behind zmural. Options offered (set the
Windows background to a picture, or zmural-owned Next/Previous verbs, which Windows 11 would
put under "Show more options"); the owner chose to leave it.
