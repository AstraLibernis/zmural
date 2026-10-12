# Release review: 2026-10-05

**Read this first.** The owner asked whether zmural is ready for a public release, stable on
Windows and Linux. Answer given: not yet as a stable release. Everything runnable here is
green; what's missing is time on real desktops. A public beta is realistic after this
review's fixes, a real Windows pass with two monitors, and a week of daily use on both OSes.
Worked in the sandbox (headless rigs, Wine, no real desktop); the Windows fixes were proven
by a CI run (below).

## Checked before any change (main at 7371771)

- `zig build test`: 196/201 (5 skipped). Under `-Dtsan`: the same, no race.
- Windows unit tests under Wine: 187/203, the one failure the known Wine `access` quirk.
- Every Linux rig (16 scripts, release package built first) and kde-test (18): all pass.
- No secrets in the history (156 commits).

## Fixed (each test fails with its fix disabled; checked)

1. **Windows: quitting could hang forever.** `requestClose` found no window while the
   settings thread was still creating it, so nothing was sent and `close()` joined forever.
   The request is now a flag `run` reads once the window can be found. Test in
   `settings/window.zig` (open then close 20 times); without the fix it hangs (timeout).
2. **Log rotation race, both OSes.** A thread could pass the `rotating` check and write to a
   handle another thread had just closed (and the OS may have reused). Writes and rotation
   now share one lock. New threaded test at 1, 3 and 16 threads, per OS; without the lock
   TSan reports the race and the plain run fails too.
3. **Windows: Mark of the Web.** Files imported from a marked zip are marked like it
   (`Zone.Identifier`, as Explorer's Extract All does); if marking fails the import is
   undone. Checked only in CI (Wine has no alternate streams): step 6 of the zip step.
4. **Zip entries sharing data** (a tiny zip unpacking to the 8 GiB cap): refused as
   `error.Overlap` in `check`, before anything is written. Unit-tested.

Also: README status and roadmap no longer say zip/Lively import are next, nor promise a gallery.

## Not done (minor, from the same review)

- Zips with CP437 names (no UTF-8 flag) and names that differ only in non-ASCII case fail
  with "can't be read or written" instead of saying why. Fails safe.
- `pipe.zig`/`unix.zig` `send` put a 64 KiB buffer on the stack per message; in ReleaseSafe
  that is a 64 KiB fill per send. Measured cost not taken; left alone.
- The temp folder name `.zmural-import-<name>-<hex>` can pass 255 bytes for a very long name.
- Export reads each file twice; a file changed mid-export makes a zip that fails import.

## Release readiness (what a public release still needs)

- A real Windows desktop pass: web wallpapers, two monitors, the Uninstall button in
  Settings > Apps, the crash notice, Open file importing a zip (all listed in the 2026-10-02
  note as untried there).
- Linux beyond the owner's Plasma: live-USB sessions of GNOME and another Plasma version.
  The tarball's Plasma plugin needs Qt 6.11+, which most distros don't ship yet.
- A week of daily use on both OSes (sleep and resume, monitor hotplug); no soak test exists.
- Decide whether `notes/` (internal dev logs) goes public with the repo.

## CI (f01dc3c, then the fix after it)

- f01dc3c: Linux all green. Windows: one failure, the new threaded log test's check on
  `t.log` (Wine had passed it). First guessed as a failed `MoveFileExW` (antivirus); that was
  **wrong**. The same check later failed on Linux about 1 run in 30, and printing the file
  showed it **empty**: when the last line written is the one that crosses the limit, the log
  rotates and the new file is legitimately empty. The test's `len > 0` was wrong for the
  current file. Fixed on both OSes (current may be empty, old may not; both keep the strict
  size bound); 520e9da's Windows-only loosening of the bound is undone.

## Later the same day: polish and doc hygiene

- Zip import: names that aren't UTF-8 are refused as `NameEncoding` with their own message
  (on Windows they failed as "can't be written"; on Linux they landed as raw bytes); two names
  that differ only in case are `SameName`, also when only the file system notices
  (non-ASCII case on Windows and macOS: `PathAlreadyExists` during unpack). The hidden import
  folder is `.zmural-import-<16 hex>`, never too long.
- Export: each file goes through a CRC-checking reader; a file written to, grown or cut short
  between measuring and packing is refused as `Changed` instead of making a zip that fails
  import. Unit-tested; every new check mutation-tested.
- Docs: old program names gone from code comments, THIRD_PARTY_NOTICES and the help texts;
  README (CI claims, features heading, a contradiction about app wallpapers, zip protections
  in Security), RELEASING (debug path, what CI does run), MILESTONES (old placeholder map
  labelled history, superseded lines). Left as is: "the owner" in MILESTONES (reads as the
  maintainer) and the "v0.1 not published" lines (the owner's call).

## Evening: requirements (owner: lowest common denominator, not a blacklist)

Decisions and the inventory: `notes/compat-2026-10-05.md`; done list: MILESTONES "Requirements".
- Windows 11 only; the Windows package refuses a native-CPU build (baseline x86-64, no AVX
  measured in the exes).
- KDE plugin and GNOME extension built inside Debian 13 (`tools/plugin-root.sh`,
  `-Dplugin-root`, required by `zig build package`): plugin needs Qt 6.8 (was 6.11), resolves
  against Debian 13's libraries, passes kde-test (18) on Qt 6.11; GNOME extension seen
  drawing on headless GNOME 50.
- Startup check (`daemon/requirements_linux.zig`): one notification per shortfall, nothing
  installed; host-test 6 new checks. Layer-shell host refuses old wl_output, no dmabuf, no
  render node as "unsupported" (still picture) instead of blank or endless restarts.
- host.zig's tests weren't reachable from any test root (now via layer_shell/main.zig).
- Verified: unit 206/213, TSan clean, Wine 192/209 (the known Wine quirk), every Linux rig
  (17) + kde + gnome, all on the new package.
