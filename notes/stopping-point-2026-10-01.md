# End of day: 2026-10-01

**Read this first.** Worked from another machine (a WSL box with Zig but no GPU, no Wayland
compositor, no mpv): unit tests and `zig build check` for both OSes ran there; the headless
rigs and the desktop did not. Everything is on `main`; no CI run (no `[full ci]`).

## Done

Last night's findings (`notes/host-test-2026-09-30.md`, each marked there with its commit):

- 1 `status` names the rules behind an automatic pause or mute: `paused : yes (fullscreen)`.
- 2 the settings folder is made on first start. 3 the uninstaller names the top folder.
- 4 crash lines in local time. 8 a plugin upgrade isn't announced as an install.
  9 RELEASING.md says what "stripped" means.
- 12 the 4 s freeze on KDE: the theme is re-read on the next loop turn, only for the
  appearance keys; `dbus.call()` refuses re-entry (`error.Reentered`). Socketpair test.
- 11 Escape closes the window when no menu or question is open.
- 10 the keyboard: Tab between groups (pages, the player card, the buttons above the
  wallpapers, the page), arrows to the nearest control that way in the group (Left/Right
  stay on the row), Home/End the group's ends.
- 7 looked into, no change: a stripped ReleaseSafe build logs and resolves its own
  addresses (in-process fault and an outside `kill -SEGV` both checked); the empty trace
  on Plasma was most likely the signal landing inside libmpv or the driver.
- 5 explained by 12; 6 harmless.

Also:

- **Crash codes.** Every crash report ends in `code: zmural 0.1.0 linux crash: 1216a76 ...`
  (own addresses only; Windows from the program's base), also left in `crash-code` next to
  the log. zmural shows it once at its next start or after a renderer dies (Linux: a
  notification; Windows: a tray balloon). Nothing is sent anywhere (owner: users copy the
  line and post it themselves). `zig build crashcode -- "<code>"` decodes it with that
  release's debug files. Tried end to end on a stripped release build.
- The Linux settings window's own tests weren't referenced by `zig build test`; they run now.

## Not yet seen

- On the owner's Plasma: no freeze on open, the new keys, Escape, `status` during a pause,
  the crash notification.
- `tools/keyboard-test.sh` (rewritten for the new keys) and `tools/crash-test.sh` (new crash
  code checks): not run since the change.
- Windows: everything since 2026-09-29, now also the crash balloon and decoding Windows codes.

## Next

Proposed, not yet agreed: work order item 6 (`.zip` packages, Lively import, search and
tags; M7), which can be proven without a desktop. Loose ends unchanged: the once-seen exit
that didn't happen, three files not `zig fmt`-clean, the Windows CI's slow Zig download.
