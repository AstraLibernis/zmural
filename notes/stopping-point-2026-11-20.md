# Stopping point: 2026-11-20

**Read this first.** A full audit of zmural (four review agents: Windows runtime, security,
Linux and shared code, politeness checked against zstrata's measurements of this machine), then a
day of **Windows-only** fixes, tested natively on Windows 11. Linux fixes were left for later on
the maintainer's word ("single out the Windows-only bugs for now").

## How it was tested

- `zig build test` runs natively on Windows now (no Wine): 223 pass, 17 skip, 0 fail.
- **zmural can't show anything in the sandbox:** it runs in session 0, with no desktop and no
  Explorer. zmural itself, the control pipe, `zmural-console`, renderer processes and libmpv all
  run; the video window and the desktop attach don't. New testing aid **`ZMURAL_TEST_VO=null`**
  (Windows renderer) plays with no picture, so playback logic (watchdog, priorities, audio) runs
  for real here. Rig: a PowerShell script that starts zmural with `ZMURAL_CONFIG_DIR` in a scratch
  folder, applies the Sintel trailer, samples the renderer's priority/threads/CPU/memory, and can
  cut the file to 0 or 4096 bytes mid-play.
- With no picture mpv decodes with `d3d11va-copy`, not the `d3d11va` a real window gets, so mpv's
  own behaviour on a broken file differs from the 2026-10-14 pass. The new watchdog check doesn't
  depend on mpv's behaviour (below).
- Trap: piping `zig build test` output (`| grep`) makes Zig's build runner on Windows exit with
  code 3 now and then. It isn't zmural: redirect to a file and read that.
- Priority tests skip in the sandbox: its own job pins every process to below normal.

## Fixed (Windows), each tested

| What | How it was proven |
|---|---|
| **Watchdog: a video cut short while it plays** (the 2026-10-14 pass, FAIL 2a/2b) is now caught within ~1 s: the renderer notices the file's size or write time changed (`sdk/file_stamp.zig`), ends, and the restart reports the broken file and falls back | Live: cut to 0 and to 4096 bytes, both caught in the first second, fallback to Prism. Before: ~3 cores spinning (12 s here, forever on the maintainer's PC). Unit test cuts and deletes a real file |
| Network videos waiting for mpv's cache no longer count as stuck (`paused-for-cache`) | Code only (no share here) |
| **Control pipe could stop listening for good** after one failed open: now one instance is always kept waiting, retried every tick | New test (fails without the retry) |
| **Uninstall wiped the whole `ZMURAL_CONFIG_DIR` folder** and skipped the Start menu/Apps cleanup: now only zmural's files (settings, properties, the two logs) | Live: a user's file in that folder survived, the rest of the uninstall ran |
| **Renderers run below normal priority** (job limit; covers WebView2's children too). The daemon stays normal so it can pause wallpapers at once | Unit test (skips in the sandbox, runs elsewhere) |
| **Renderers lower their own GPU priority** (`D3DKMTSetProcessSchedulingPriorityClass`, below normal; a warning is logged if refused) | Unit test sets and reads it back; live renderer logged no warning |
| **Decoder threads capped at 2** for CPU decoding, and **no audio track while muted** (the default) | mpv CLI, same build, 1080p H.264, n=3: 35 → 19 threads, private memory 160 → 70 MB; CPU difference within noise |
| **Window-event hooks quiet during a fullscreen game:** the show/hide and location hooks (which fire with every cursor move) are removed while a fullscreen app pauses every monitor, and come back after | Live: log says so on entering, and again when the rule changed |
| **Desktop attach retry backs off** (0.5, 1, 2, 4, 8, then every 10 s) and logs once, instead of every 500 ms forever without Explorer | Live: 1 warning in 25 s (was 50) |
| Raised layout (Win11 24H2+): waits for the icon layer instead of attaching above the icons; looks it up each time instead of keeping a handle that goes stale; a failed attach now retries | Code only (needs a real Explorer restart) |
| Logoff: settings are saved first, before anything that can wait | Code only |
| Tray menu: nothing runs after a logoff shut zmural down while the menu was open | Code only |
| A failed mpv load is torn down off the UI thread (the file's own deadlock rule) | Code only |
| Closing the settings window during an import no longer leaks the import's process handle | Code only |
| Imported files get the Mark of the Web **while still in the hidden staging folder**, so none reaches the library unmarked (`BeforePublish` step in `package_zip.unpack`) | Live: imported file carries the zip's Zone.Identifier, no staging folder left; new unit test (a failing step imports nothing) |

## Left over

### Needs the maintainer

- **CI's pinned libmpv is gone upstream.** `ci.yml` downloads
  `zhongfly/mpv-winbuild` 2026-09-26-a1bf4b6559, which now returns "Not Found": the Windows CI
  job and releases can't fetch it. That repo keeps only recent builds, so any pin to it breaks
  again. Options: pin a current build and update often; or keep our own copy of the archive (for
  example as an asset on a zmural release) with its hash. The local test build used
  2026-11-20-ee54be6e1d (sha256 aa07b7e9…), which also changes `licenses/libmpv-credits.txt`
  if adopted. CI is still on hold, so nothing was run.
- **Shortcut-type files in imports** (`.lnk`, `.url`, `.scf`, `.library-ms`, `desktop.ini`):
  browsing such a folder in Explorer can leak the Windows login hash to a remote server
  (CVE-2025-24054 class). Not changed, because the standing rule is that what a package
  holds is the user's call. Choices: refuse them, leave them out (like Lively's unsupported
  parts), or keep as is.
- **A live Windows pass of today's fixes** on a real desktop: the watchdog with `d3d11va` (cut
  a playing video to 0 and 4096 bytes), an Explorer restart (wallpaper below the icons), a
  logoff with the settings window open, CPU/GPU priority in Task Manager (renderers below
  normal), and a 60 fps clip's CPU before and after.
- Still not done from 2026-10-14: lock/sleep/wake, an exclusive-fullscreen game, SmartScreen on
  a downloaded zip, a web wallpaper through an Explorer restart, the soak test.

### Windows, not fixed yet

- **S11 (new):** thumbnails decoded inside zmural (MILESTONES security table, README limitation 8).
- **The fps cap only applies to the test pattern:** mpv and web wallpapers render at the content's
  (or the monitor's) rate. Needs a real display to tune; don't cap through mpv's `fps` filter or
  a `-copy` hwdec (both pull frames through system memory, the slow direction per zstrata).
- **One mpv per monitor** even when monitors share a wallpaper (Linux decodes once).
- A long fullscreen pause keeps decoder and WebView2 memory: could turn into a stop after ~60 s
  (a policy default change: the maintainer's call).
- Desktop attach (classic layout only, Win10/early Win11) can block the UI thread ~2 s.
- EcoQoS: zstrata measured no effect on this desktop, so not added.

### Linux and shared code (found, not fixed: out of today's scope)

- **High:** `lifecycle.zig:199` respawns from `policy_stopped` while the old renderer is still
  stopping; the old pidfd/socket leak, and the armed SIGKILL then hits the *new* pid (counts as a
  crash; 5 give up for good). Trigger: a fullscreen flicker shorter than the stop grace.
- **Medium:** `router.zig` keeps a borrowed wallpaper path that the Linux daemon can free while
  another monitor shares the entry (Windows rebuilds the router first, so it is safe there).
  Fix: the router owns a copy.
- **Medium:** two identical monitors with no EDID serial get the same `m-` ID (`core/monitor.zig`).
- **Medium (security, both):** the zip-bomb ratio trusts the zip's declared compressed sizes. A
  299 KB zip with edited sizes imported as 300 MiB (proven); the real limit is the 4 GiB cap.
  Fix: read each local header and check its real span stays inside the file.
- Low: quitting can hang on a SIGSTOPped renderer; layer-shell host leak on OOM; the session bus
  never comes back after one bad message; stale `.release` after a pool rebuild; no timeout
  before `ready`; manifest defaults can carry control bytes into the property list; the D-Bus
  reader has no depth limit and loops on `a()`.
- Linux probably has the same blind spot for a video cut while it plays (mpv loops on broken
  packets, `core-idle` never holds); the file-stamp check is Windows-only so far.
- The Linux side hasn't run on a desktop since the Zig 0.17 port (the old rigs lived in the WSL
  sandbox). It cross-compiles cleanly.
- Politeness on Linux: nothing lowers renderer priority (nice/ioprio), no decoder thread cap,
  EGL context priority not requested.

### Housekeeping

- The code still uses std APIs deprecated in Zig 0.17 (`std.fs.path`, `std.fmt.bufPrint`,
  `allocPrint`, `@intFromFloat`): build and tests are fine; new code today uses the current ones.
