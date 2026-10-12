# Working builds and released builds

zmural is built two ways. They come from the same source; what differs is how they are
compiled and what goes into them.

| | Working build | Released build |
|---|---|---|
| For | Development, the test rigs, CI, trying a change | What users download |
| How | `zig build` (and `zig build test`) | `zig build package` (below) |
| Mode | Debug | ReleaseFast |
| Safety checks (bounds, overflow, bad casts) | on | off |
| Speed | slow: never measure speed or timing on it | full |
| Debugging info | inside the programs | **taken out**, kept beside the download (Linux keeps the symbol table, so `file` still says "not stripped") |
| Where | `zig-out/bin` | `zig-out/package` |

**Released builds are ReleaseFast (maintainer's decision, 2026-10-12).** Playing a video,
ReleaseSafe, ReleaseFast and ReleaseSmall use the same CPU (the GPU and libmpv do the
work), and the programs are a few MB in any mode. The cost of ReleaseFast: a memory bug
that ReleaseSafe would stop with a message can corrupt memory silently instead. So
correctness is judged where the checks are on: the unit tests and the working build
(Debug). Panics and faults are still logged with a crash code in ReleaseFast
(`tools/crash-test.sh`).

**Measuring:** speed, CPU and timing are measured on ReleaseSafe or ReleaseFast builds,
never on the working (Debug) build, which can be ten times slower.

## Publishing a release (CI)

A release goes from the source on `main` to GitHub by a tag; CI builds, tests and
publishes it. Nothing is built on a developer's machine.

1. Set the version in `build.zig.zon` (`.version`), and write the release notes in
   `docs/releases/v<version>.md` (what's new, known limitations). Commit and push to `main`.
2. **Preview (optional):** Actions > CI > Run workflow on `main`. It runs every test, builds
   both packages, and puts them in a **draft** release with those notes, which only the
   maintainer can see. Run it again after a fix: the draft's files are replaced.
3. `tools/release.sh` checks the version, the notes and that `main` is pushed, then tags
   `v<version>` and pushes the tag. CI runs everything again on the tagged commit and
   **publishes** the release (a 0.x version as a pre-release), replacing a preview draft
   of the same version if there is one.

Each release has the Windows zip, the Linux tarball, their debugging info
(`*-debug.zip`, `*-debug.tar.gz`) and `SHA256SUMS.txt`; the checksums are added to the
notes. If a test fails, nothing is published; fix it on `main` and make a new version, since
a published tag is never moved.

What CI tests before publishing: the unit tests on both OSes; on Windows the zip itself,
unzipped into an empty folder and run (playback through libmpv, the CLI, crash codes,
start with Windows, the uninstaller); on Linux the tarball's contents, its glibc ceiling and
its debugging info. A hosted Linux runner has no GPU, so the tarball's desktop tests
(`tools/package-test.sh`, `tools/package-debian-test.sh`, `tools/crash-test.sh`) run on a
machine with one before tagging.

## Building a package by hand

```
# Windows (on Windows): zmural-<version>-windows-x86_64.zip
# The -Dtarget builds for every x86-64 PC, not just this machine's CPU.
zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-windows

# Linux: zmural-<version>-linux-x86_64.tar.gz
# The -Dtarget sets the oldest glibc (Debian 12) and a baseline x86-64 CPU; the KDE
# plugin and GNOME extension are built inside a Debian 13 root (tools/plugin-root.sh
# makes it once), the oldest system that meets what they declare, so they load there
# and on everything newer.
zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)
```

The Linux target names the oldest glibc the tarball must run on (Debian 12); without it
the step refuses to run, so no newer symbol slips in.

Each package step leaves two things in `zig-out/package`:

- **the download:** the zip or tarball, with no debugging info in its programs and no
  build-folder paths;
- **`debug/<package name>/`:** the debugging info taken out of it (`.pdb` files on
  Windows; `.debug` files on Linux, each tied to its program by a build ID).

**Keep the `debug/` folder of every release you publish**, for example as a separate
asset of the GitHub release (it holds nothing secret; the source is public anyway). Without it a user's crash report can't be read, and
it can't be rebuilt later: a new build has a new build ID and different addresses.

Before publishing:
- **Windows, libmpv (2026-10-12):** `licenses/libmpv-credits.txt` credits every project
  inside `libmpv-2.dll`, listed from mpv-winbuild-cmake's recipe (`packages/*.cmake`,
  following DEPENDS from mpv, minus what zhongfly's `compile-lgpl-libmpv.patch` drops).
  Redo it whenever the pinned libmpv changes. Still open before the first Windows
  release: keep a copy of the mpv and FFmpeg sources that build used, so the LGPL source
  offer doesn't depend on the zhongfly release staying up.
- Linux: `tools/package-test.sh` (the tarball extracted into an empty home) and
  `tools/package-debian-test.sh` (inside Debian 12).
- Windows: CI unzips the package into an empty folder on the Windows runner and runs it;
  also try it once on a real Windows desktop before publishing (that step isn't automated:
  no runner shows a picture).

## Reading a crash report from a released build

A released build that crashes still prints what went wrong and where, as addresses:

```
thread 4462 panic: index out of bounds: index 6, len 3
???:?:?: 0x101cc84 in ??? (zmural)
```

Linux: turn each address into a function and a line with that release's debug file.
zmural isn't position-independent, so the printed addresses are used as they are:

```
addr2line -f -i -e zig-out/package/debug/zmural-0.1.0-linux-x86_64/zmural.debug 0x101cc84
```

`readelf -n` on the user's program and on the `.debug` file shows the build ID; they must
match. (Checked on a stripped ReleaseSafe test program, 2026-09-30.)

Windows: `zig build crashcode` (below) reads the addresses against that release's
`zmural.pdb` with the system's dbghelp.dll; the `.pdb` alone is enough. Checked on
2026-10-01 with test crashes of a stripped ReleaseSafe build (zmural and a renderer,
a panic and a bad pointer).

**Where the report comes from:** `zmural.log`. Every part of zmural (zmural itself, a
renderer, the display host, the watchdog) appends a crash to it before the usual report on
stderr, so a zmural started at login leaves it there too:

```
2026-09-30 14:21:20 CRASH: zmural 0.1.0 (renderer video, pid 4755): panic: index out of bounds: index 6, len 3
    at 0x120a275
    at 0x10f5fd5
```

The last line is the **crash code**, the one line a user needs to pass on:

```
    code: zmural 0.1.0 linux crash: 1216a76 10fab48 10e8401
```

It holds only the addresses in zmural's own code (Windows: from the program's base),
and it is what the user is shown: zmural notifies them after a crash (Linux: a desktop
notification; Windows: a balloon from the tray icon) with that line and where the log is.
Nothing is sent anywhere. Turn a code back into functions and lines with

```
zig build crashcode -- "zmural 0.1.0 linux crash: 1216a76 10fab48 10e8401"
```

which looks for that release's debug files in `zig-out/package/debug/` (or
`$ZMURAL_DEBUG_DIR`) and runs `addr2line`, or for a Windows code (run on Windows)
looks them up in `zmural.pdb` through dbghelp.dll.

The time is local, like the rest of the log. Ask the user for the log (Linux
`~/.local/state/zmural/zmural.log`, Windows `%LOCALAPPDATA%\zmural\zmural.log`), take the
release named in the line, and look the addresses up as above. `tools/crash-test.sh` makes
crashes on purpose (`ZMURAL_TEST_CRASH=zmural:panic`, `zmural:fault`, `renderer:panic`,
`host:panic`) and checks they land there; on Windows, CI's zip test does the same for zmural's own panic.
