# End of day: 2026-10-02

**Read this first.** Worked in the sandbox container (headless Sway and Plasma rigs, no real
desktop, no Windows). Everything is on `main`; no CI run (no `[full ci]`). Windows changes
today are compiled and cross-tested only: **run the Windows unit tests and a desktop pass before
trusting them** (list below).

## Where things stand (end of day)

- `main` is the only branch, local and on GitHub (the stale `m6-linux` branch was deleted by
  the owner on 2026-09-30, as MILESTONES' Housekeeping already said). Working tree clean.
- Last CI run (by hand, bf168c9): green on Windows and Linux. Every Linux rig passes here.
- Work order: items 1 (except span) and 2 done; item 6 done except search and tags (needs a
  text field, owner to decide) and the Lively JS shim (Windows). Next proposed: the owner's
  call between the text field (search/tags, text settings) and the small leftovers below.
- v0.1 stays an unpublished draft (owner's decision, 2026-09-30).
- Not cleaned up yet (the owner declined a bulk delete; asked which to remove): the project's
  24 GB `.zig-cache`, old `/tmp/zmural-*` rig folders (overlay, gone on restart anyway), and the
  session scratch folder. `/tmp/zmural-debian12` is the Debian root package-debian-test reuses.

## Done

**Linux parity with the Windows work of 2026-10-01** (`notes/windows-check-2026-10-01.md`):

- No wallpaper-switch flash on Linux: both display hosts keep the last frame through an unbind
  (measured on Sway with grim and on the Plasma plugin via KWin's ScreenShot2 every ~6 ms, also
  with a deliberate 600 ms gap). `shown` stays Windows-only. Uninstall has no race on Linux.
- S11 on Linux: Pango drew a box and warned on stderr every frame; `gui_cairo` now mends text to
  U+FFFD per bad byte, like `gui_d2d` (1a9a2c5).
- `tools/uninstall-test.sh` used the pre-rework keys; fixed (06dc1f6).
- File names that aren't UTF-8 are listed on Linux, and **every D-Bus string is mended**: before,
  applying such a file put its name in the tray tooltip and the bus disconnected zmural (its tray
  icon vanished), seen on headless Plasma (4b0440f).
- Crash notices: one per run, and the line stays in `status` (`crash : ...`) and on General's
  Troubleshooting for the run (8c8f18e). **Both OSes.**

**Work order item 6** (owner said go ahead; online gallery dropped by the owner, 2a9f81d):

- `zmural-console import <zip> [--to] [--apply]` (b3c7fb4), checked before anything is written,
  unpacked into a hidden folder, CRC-checked, renamed into place; runs in the console's process.
- Video and picture packages on Linux (304977d); package tiles and the tray use the folder's name.
- `zmural-console export` (d3b41f3); `unzip -t` passes our zips.
- The window's Open file takes a zip and runs the import as a separate process (9ac2e5b);
  `ZMURAL_TEST_PICK` answers pickers in the rigs.
- Lively import (c3d019f), from Lively's own source; 11 of its author's wallpapers import.

New rigs: `tools/import-test.sh` (25 checks), `tools/packages-test.sh` (12). Both pass; so do
settings, keyboard, props, monitors, crash (12, after `zig build package`) and uninstall.

## Tested at the end of the day (owner: "test it as much as possible")

- **CI, run by hand, green on both OSes** (bf168c9): Windows unit tests, release build, a new
  step that imports and exports zips against Windows' own zip tools (Compress-Archive,
  ZipArchive, Expand-Archive; hostile names refused, nothing written), the boot test, the
  release zip unzipped and run. Linux: unit tests, codec check, Windows cross-build, boot test.
  The first run found a real Windows test bug (a "/" in a joined path), fixed in d108524.
- **Windows unit tests under Wine here** (`zig build test -Dtarget=x86_64-windows -fwine`):
  all but settings' first-start test, which uses a dir-relative `access` that Wine gets wrong
  (it passes on real Windows). That quirk also hid two package tests; the code now opens files
  instead of `access`ing them, and the import folder name is unique per run (d108524).
- **Every Linux rig, 20 of them:** sway, host, instance (30), facts, decode, crash (12, after
  `zig build package`), still, niri, monitors (21), props (15), settings (14), keyboard (14),
  uninstall (7, fixed to accept a tarball-like zig-out), import (25), packages (12), package
  (13), package-debian (Debian 12), kde-test (18 on headless Plasma), gnome-test (needed
  `mesa-vulkan-drivers` in the container, now in sandbox-deps.sh; the test pattern shows).

## Windows: compiled only, needs trying there

(CI now covers import/export and the unit tests there; these still need a real desktop.)

- Crash notice once per run + `status.crash` + the Troubleshooting row (8c8f18e).
- Package names in the tray and window (`media.displayName`), 304977d.
- Import/export from the console, and Open file importing a zip (no console window should
  flash: it uses `zmural.os.process.spawn`), 9ac2e5b. Package thumbnails on Windows still use the
  manifest's path (no thumbnail): not done.

## Open, next

- Item 6: search and tags need a text field in the shared widgets (there is none); zip64 for
  exports over 4 GiB; the Lively JS shim (`livelyPropertyListener`) in the Windows web renderer.
- Smaller, from the Windows report: `status` lacks the main fill mode; the log is missing when
  `ZMURAL_CONFIG_DIR`'s parent doesn't exist (tests only); Zig's segfault handler vs shell
  extensions in the window (Windows); web `shown`.
