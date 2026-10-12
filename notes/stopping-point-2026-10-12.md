# Stopping point: 2026-10-12

**Read this first.** The day zmural went public: 0.1.0 published, a release path through CI, a
new plan (docs/MILESTONES.md), and 0.1.1 built out of two blind tests. 0.1.1 is done on Linux and
waits for one thing: **the maintainer's Windows pass** (docs/WINDOWS-PASS.md).

## Where things are

- **Released:** v0.1.0, a pre-release (tag at 7d18338). It has the bugs both blind tests found.
- **Draft:** v0.1.1 on GitHub, made by a CI run by hand from b53d896. It is **stale**: every fix
  from the adversarial test came after. Next: Actions > CI > Run workflow on `main` (it replaces
  the draft's files), then the Windows pass on that zip, then `tools/release.sh`.
- **Version:** build.zig.zon says 0.1.1; notes in docs/releases/v0.1.1.md (updated tonight with
  the adversarial test's fixes, committed with this note).
- **Builds:** releases are ReleaseFast since today (the maintainer's call: same CPU as Safe, a
  few MB either way; crash codes still work). Tests stay Debug.

## Done today (main, 7d18338..here)

- Public-readiness review: no personal data; "private" wording fixed.
- Release path: CI builds and tests both packages; a run by hand makes a draft, a `v*` tag
  publishes (tools/release.sh, tools/release-publish.sh, docs/RELEASING.md).
- Plan: docs/MILESTONES.md rewritten from 0.1.0 on (0.1.1 to 1.0); the pre-public plan retired to
  notes/milestones-2026-08-to-10-12.md. Tags dropped (decided against); drag and drop onto the
  library folders added to 0.3.
- Blind test of 0.1.0 (notes/blind-test-2026-10-12.md): every finding fixed or decided.
- Adversarial blind test of the 0.1.1 draft (notes/adversarial-test-2026-10-12.md): two highs, six
  mediums and the lows fixed, each with a test that fails without it; the frame watchdog moved to
  0.2.
- New rigs: soak-test (a day of use in rounds; 100 rounds flat, notes/soak-2026-10-12.md),
  tray-test (swaybar's real tray), open-test (Open buttons with and without an opener),
  controls-test (every settings-window control by a real pointer; the window writes where its
  controls are with `ZMURAL_TEST_CONTROLS`).
- docs/CONTROLS.md: every control and what tests it. docs/WINDOWS-PASS.md: the by-hand checklist.

## Tests at the end

Every fix was checked with its rig and a mutation as it went in, and `zig build test` passes
(232 tests, 8 skipped). A final run of all rigs was stopped at the maintainer's request after 8 of
16, all passing: instance, settings, keyboard, controls, open, tray, broken, import. Not re-run
after the last commits: uninstall (passed when its fix went in), monitors, props, still, sway,
decode, packages, facts (passed after the morning's changes; not since the evening's). **Run
them before tagging 0.1.1**, then the soak test on a release build, then the CI-built tarball
through package-test, package-debian-test and crash-test (docs/RELEASING.md).

## Next

1. CI by hand on `main` (rebuilds the v0.1.1 draft), the rigs above, the Linux tarball checks.
2. The maintainer's Windows pass on the draft's zip. Windows changes today are compiled only:
   Open-button and settings-save notices, the size and "no media" checks in the renderer, the
   full-path check, notification dedupe, uninstall's settings folder.
3. tools/release.sh publishes 0.1.1.
4. Then 0.2 (docs/MILESTONES.md): the frame watchdog first.

## Traps found today

- Bash reads a script as it runs: never edit a rig while a run of it is going (copy it first).
- Rigs need a short `$TMPDIR` (the Wayland socket path limit).
- A virtual pointer's absolute coordinates span the whole layout (both outputs), not one output.
- `awk -v` turns `\x0a` back into a newline; pass such text through the environment.
- `pgrep -f`/`pkill -f` with a word from your own command line kills your own shell.
- A mutation that doesn't compile proves nothing: check the build before reading the rig.
- Daemon files' tests run only if daemon/main.zig's test block imports them (desktop_linux.zig
  hadn't been, until today).
- GLib looks up a desktop entry's program before it turns `%%` into `%`: a `%` in zmural's path
  goes through `env`.
