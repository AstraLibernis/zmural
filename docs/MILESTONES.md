# zmural milestones

The build plan, from an empty scaffold to a cross-platform release. It expands the README's roadmap and says which placeholder each milestone replaces.

**Commit IDs:** the public repository starts on 2026-10-12 with one commit, the first public release. Commit IDs written before then, here and in `notes/`, refer to the private development history and aren't in this repository.

**Ground rules**
- Tackle the riskiest thing first, and make every milestone end in something you can **see** working.
- Pure logic lives in `src/core/` and `src/protocol/` and is unit-tested. OS-specific code stays thin and is checked against each milestone's **Done when** list by hand.
- One milestone = one or more commits. Nothing is merged with failing `zig build test`, and both targets must keep compiling (`zig build -Dtarget=x86_64-windows` from Linux, `-Dtarget=x86_64-linux` from Windows). CI (`.github/workflows/ci.yml`) does both on each OS natively, boots the real zmural on Windows, and builds and runs the Windows release zip. It runs only for a finished milestone or a major push (by hand, a `v*` or `milestone-*` tag, or `[full ci]` in the commit message: owner's decision, 2026-09-30, to save Actions minutes); in between, the cross-builds and the Linux rigs here are the check, and the owner tests Linux on real desktops. What CI can't see is said where it matters: the Linux runner has no GPU, and no runner shows a picture.
- Working builds (`zig build`, Debug) and released builds (`zig build package`, ReleaseSafe, stripped, their debugging info kept per release) are different: [RELEASING.md](RELEASING.md). Nothing is measured on a working build.
- One codebase for both OSes, built as a separate program for each. Windows came first (M1 to M5) and Linux followed (M6); neither is the default. Shared logic is written once, and anything that has to differ says which OS it is for. A feature is only ticked for the OS it was tested on, and the item names it.

**Legend:** ✅ done · 🔶 in progress · ⬜ not started

| # | Milestone | Platform | Outcome | Status |
|---|---|---|---|---|
| M0 | Foundation | both | Scaffold, protocols, core logic, tests | ✅ |
| M1 | Behind the icons | Windows | A test animation plays behind the desktop icons | ✅ |
| M2 | Process split | Windows | The renderer runs in its own process; crashes are contained | ✅ |
| M3 | Real wallpapers | Windows | Videos and images play as wallpaper | ✅ |
| M4 | Smart pausing | Windows | Games and fullscreen apps pause the wallpaper; 0 % GPU while hidden | ✅ |
| M5 | Windows MVP | Windows | Tray, CLI, settings, library → **v0.1** (not published: the owner waits until most milestones are done) | 🔶 |
| M6 | Linux MVP | Linux | Same experience on wlr-layer-shell compositors, KDE Plasma and GNOME → **v0.2** | 🔶 |
| M7 | Wallpapers that do more | both | Web wallpapers, properties and adjustments, JS API, audio, Lively import | 🔶 |
| M8 | Polish | both | Rotation, a wallpaper and fill mode per monitor, span, transitions, updates and packages, sandbox, screensaver | 🔶 |
| M9 | Later | both | Whatever comes after M8 (the online gallery is dropped) | ⬜ |

---

**Where it stands (end of 2026-10-06).** Counting top-level items: M0–M4 all done · M5 all done (screen readers not supported, owner) · M6 33 done, 3 open (Niri's `covered`, KDE when its plugin couldn't be switched to, and app rule/`covered` on GNOME, which the owner dropped) · M7 7 done, 7 open · M8 8 done, 7 open · Requirements 6 done. Since 2026-09-30: the release review and its fixes, the platform floors (Requirements), zip import and export with Lively import, and on 2026-10-06 the Welcome page, Prism (the wallpaper zmural ships with) and the fallback for files that can't be played. The latest report: `notes/stopping-point-2026-10-06.md`.

What landed on 2026-09-30, each under its milestone below:

| Area | What | Milestone |
|---|---|---|
| Linux | A log file; `settings.toml` reloaded while running; GPU video decoding through VA-API, with one notice when a format can't be; the app rule on KDE Plasma | M6 |
| Linux | Three bugs from the first real Plasma session fixed (fullscreen pause, settings window crash and zombie); a clean exit when there is no GPU node | M6 |
| Linux | zmural starts and supervises its own layer-shell host; renamed Videos/Pictures folders followed; window facts from Sway's IPC (hidden workspaces, `covered`, app rule); the app rule on Niri; frames carry their GPU fence; a still picture where nothing live can show | M6 |
| Both | A different wallpaper and fill mode per monitor: command line, settings file, and the settings window's right-click menu | M8 |
| Both | Adjustments for plain videos and pictures, and the Customise section in the settings window | M7 |
| Both | Web wallpapers always offline, web addresses refused, built-in renderers only | M7 |
| Both | Two programs instead of seven: `zmural` (renderers, watchdog and host are its modes; the settings window a thread in it) and `zmural-console` | M5 |
| Both | Keyboard navigation in the settings window; an uninstaller that removes only what zmural added | M5, M8 |
| Both | Releases: a Linux tarball (runs on Debian 12 and newer), stripped release builds with their debug info kept aside, crashes written into `zmural.log` | M8 |
| Both | CI: native builds, unit tests and a Windows boot test, now also the Windows release zip run from an empty folder; runs only for milestones and major pushes | ground rules |
| Docs | Both OSes side by side; the comparison with Lively and waywallen and the work order below; the owner's decisions (below); `docs/RELEASING.md` | |

**How each claim is tested.** Every script fails on the code before its feature, or on a deliberately broken build. Counts are from the run at the end of 2026-09-30, all passing.

| What runs | Where | What it proves |
|---|---|---|
| `zig build test` | CI, both OSes natively; here | Pure logic: protocols, policy, rotation, settings, monitors, adjustments, notices, keymaps, focus order, Sway and Niri replies, the crash log (164 pass, 5 skipped on Linux) |
| CI boot and zip test | a Windows runner | The real zmural starts, answers `zmural-console`, gives a monitor its own wallpaper and fill, sets a picture's adjustments, refuses a web address, opens its settings window, quits; then the release zip, unzipped into an empty folder: a picture through libmpv, the settings window, a crash in the log, the uninstaller. No picture is looked at |
| `tools/instance-test.sh` | here; CI for the no-GPU refusal | One zmural per session, takeover, the console, a web address refused, `settings.toml` edits, renamed folders (30) |
| `tools/host-test.sh` | here, Sway (and Mutter) | zmural's own display host: started, restarted, never two, gone on quit or kill; tried once where there's no layer-shell (15) |
| `tools/sway-test.sh`, `tools/niri-test.sh` | here, Sway; Niri nested in Sway | Window facts from Sway's IPC; the app rule on Niri (8, 4) |
| `tools/monitors-test.sh`, `tools/props-test.sh` | here, Sway with two outputs | Per-monitor wallpapers and fill; each adjustment, read off screenshots (21, 15) |
| `tools/settings-test.sh`, `tools/keyboard-test.sh` | here, Sway | The settings window inside zmural, and the first run opening it on Welcome with Prism showing; the window by keyboard alone (20, 12) |
| `tools/decode-test.sh`, `tools/facts-test.sh`, `tools/still-test.sh` | here, Sway + mock services | GPU decoding and its notice; battery, lock, GameMode and the other system rules; the still picture through the wallpaper portal, a video's frame, GNOME before its extension runs and an old Plasma (10, 8, 15) |
| `tools/compositors-test.sh` | here, Wayfire headless and Hyprland nested in KWin | Window facts from their IPC: fullscreen, hidden workspaces, maximized, the app rule; Wayfire's missing-plugin hint (11) |
| `tools/broken-test.sh` | here, Sway with two outputs + mock notifications | A file that can't be played: back to the last wallpaper that played, or Prism; a monitor's own broken one follows the main again; never saved (9) |
| `tools/crash-test.sh`, `tools/uninstall-test.sh` | here, Sway | Crashes in the log, from zmural and a renderer, and a released build's addresses read back; the uninstaller, file by file (7, 7) |
| `tools/package-test.sh`, `tools/package-debian-test.sh` | here; inside a Debian 12 root | The Linux tarball as a user gets it; on glibc 2.36 with Debian's own libraries (13, 5) |
| `tools/kde-test/run.sh` | here, a virtual Plasma 6 | Tray, launcher, the settings window, fullscreen pause through the plugin, the app rule (18) |
| `tools/linux-matrix.sh` | here | Shows on Sway, labwc, Wayfire, Niri, COSMIC and bare KWin; Plasma needs the plugin, Mutter the extension; River inconclusive |
| The owner's desktops | real Plasma, real Windows | Plasma: `main` e0815f5 as the release tarball, the full pass in `notes/host-test-2026-09-30.md` ("Evening redeploy" and "Later the same evening"): CLI, tray, settings window, every pause rule but battery and remote, the CPU-decode notice, audio, adjustments and fill modes on screen, watchdog, crash log, uninstall and reinstall. Windows as of 2026-09-29 |

## Work order (owner's decision, 2026-09-30)

The order open items are taken in, from the comparison with Lively and waywallen
(`notes/parity-2026-09-30.md`): the gaps a user notices first come first. Each stays listed under
its milestone below; this is only the queue. Tick a line here when its milestone item is ticked.

1. [ ] Monitors (M8)
   - [x] A different wallpaper per monitor: command line, file, and the settings window's right-click menu (2026-09-30)
   - [x] Fill mode per monitor: command line and file (2026-09-30)
   - [ ] Span one wallpaper across monitors: deferred; the Linux daemon doesn't know where the monitors are (see the M8 item)
2. [x] The Customise panel for a wallpaper's properties, and video adjustments (M7): **done 2026-09-30**
3. [ ] Mouse interaction with wallpapers (M7). Only web wallpapers can use it, and those are Windows-only so far: nothing built here could be seen working
4. [ ] Audio-reactive wallpapers, now-playing and system stats in the JS API (M7). Web wallpapers only, as 3
5. [ ] Web wallpapers on Linux (M7). Large; it is what makes 3 and 4 testable on Linux
6. [ ] `.zip` packages, importing Lively's, search and tags; wallpaper packages on Linux (M7). Taken 2026-10-02 (owner: "go ahead"); no online gallery (dropped, owner).
   - [x] `.zip` import, both OSes (2026-10-02)
   - [x] Video and picture packages on Linux (2026-10-02); web packages wait for web on Linux (5)
   - [x] Export, both OSes (2026-10-02)
   - [x] Import from the window's Open file, both OSes (2026-10-02)
   - [x] Lively import, both OSes (2026-10-02); the JS shim for Lively pages is still to do (Windows)
   - [ ] Search and tags; zip64 for exports over 4 GiB
7. [ ] Transitions and blur while paused (M8); screensaver mode (M8)
8. [ ] Installers and packages, updates (M8). Partly done 2026-09-30: the Linux tarball, stripped releases, the Windows zip tested in CI, an uninstaller. No installer: unzipping is enough (owner). Left: updates and distro packages (Flatpak, COPR), code signing
9. [ ] Languages other than English (not yet a milestone item)

Also done on 2026-09-30, outside this queue: most of M6 (the owner asked for it), keyboard
navigation (M5), crashes in the log, and the layout decisions below.

Work that can't be seen working without a live desktop is done as far as the headless rigs and
CI can prove it, and the rest is said plainly in the item.

---

## Known security issues

Open issues, in the README's words under [Security](../README.md#security). Every new one found goes here and there. The OS column says where each applies; the web-wallpaper ones are Windows-only because the web renderer doesn't exist on Linux yet, and they will need revisiting for WebKitGTK.

| # | OS | Issue | Plan |
|---|---|---|---|
| S1 | both | Video/image renderers aren't sandboxed: a decoder exploit could read the user's files (audit #2 F13) | Windows: a restricted token or AppContainer (M8). Linux: nothing restricts the renderers today and the design isn't chosen (seccomp and Landlock are the candidates) |
| S2 | Windows | Web renderers' job has no UI limits: Chromium's sandbox won't start under any (all tested, 2026-09-27). The web renderer process and the WebView2 browser process run with the user's rights; pages are in Chromium's sandbox | Try an AppContainer for the whole web renderer (M8) |
| S3 | Windows | A page can read its whole folder tree. Every page is offline (since 2026-09-30 nothing can turn that off), so only a way around the offline mode (S9) could send those files out | The firewall-level block (S9) |
| S7 | Windows | Web pages may autoplay sound once the user unmutes | By design (muted by default); documented |
| S8 | both | Releases aren't code-signed and there is no updater | Windows: signing and signed update checks. Linux: distro packages, which bring their own signing and updates (M8) |
| S9 | Windows | Offline mode is Chromium proxy flags (dead proxy, loopback included, WebRTC proxied-only), not a firewall rule | An AppContainer without network capabilities for the web renderer (with S2, M8). Every page is offline now, so this is the one remaining wall between a hostile page and the network |
| S10 | Windows | Every web wallpaper's browser profile stays in `%LOCALAPPDATA%\zmural\webview2` forever | Clean up profiles of wallpapers no longer in the library (M8) |

Fixed:
- audit #1 and audit #2 (see those sections);
- web wallpapers sharing one origin: each local folder is its own origin (2026-09-27);
- S5, one shared browser profile: every web wallpaper has its own (2026-09-27);
- S6, pages navigating away: local pages are locked to their origin (2026-09-27);
- network access for local pages: offline unless the package asks (2026-09-27; superseded by S4 below: always offline);
- S11, invalid UTF-8 in drawn text panicking the settings window (and so zmural): `gui_d2d.zig` decodes leniently, U+FFFD per bad byte, unit-tested (2026-10-01). Linux never panicked (Pango drew a box per bad byte and warned on stderr every frame); `gui_cairo.zig` now mends the text the same way, U+FFFD per bad byte, unit-tested and seen on Sway with a Latin-1 file name (2026-10-02). Such a file is now listed in the library on Linux (it was skipped, a rule meant for Windows names mpv can't open), and every string zmural puts on D-Bus is mended the same way: before, applying one got zmural thrown off the session bus and its tray icon vanished (seen on headless Plasma; kept after the fix) (2026-10-02);
- from the release review of 2026-10-05 (`notes/stopping-point-2026-10-05.md`): files imported from a downloaded zip kept no Mark of the Web, so a program in a package opened from the library without SmartScreen's warning (Windows; now every file gets the zip's mark, or the import is undone; checked in CI); a zip whose entries share their data could unpack a few MB into 8 GiB (both; refused now, unit-tested);
- S4, URL wallpapers and `network = true` packages with full internet access: web addresses are refused as wallpapers and `network = true` is ignored, so no wallpaper has the network (2026-09-30).

---

## Placeholder map

History: where each stub of the first scaffold was replaced. Paths are as they were then; since 2026-09-30 the renderers and the watchdog are modes of `src/daemon/main.zig`.

| Placeholder | Replaced in |
|---|---|
| `src/hosts/windows/workerw.zig` (`Host.init/attach/detach` → `NotImplemented`) | M1 |
| `src/protocol/transport.zig` (TODO: Unix-socket listener, fd passing) | M2 (Windows: `pipe.zig`) ✅, M6 (Linux: `unix.zig`) ✅ |
| `src/sdk/renderer.zig` (`stub()`; TODO: connect-back + command loop) | M2 ✅ (`Session`) |
| `src/watchdog/main.zig` | M2 ✅ (Windows) |
| `src/renderers/image/main.zig` | M2 ✅ (test pattern), M3 ✅ (libmpv) |
| `src/renderers/video/main.zig` | M3 ✅ (libmpv) |
| `src/daemon/daemon.zig` (`run()` prints and exits; no event loop) | M1 → M5 ✅ (Windows: `runtime_windows.zig`), M6 ✅ (Linux: `runtime_linux.zig`) |
| `src/cli/main.zig` (encodes the request, then "not implemented") | M5 ✅ |
| `src/daemon/settings.zig` (TODO: load/save TOML) | M5 ✅ |
| `src/daemon/library.zig` (TODO: scan, zip import, Lively import) | M5 ✅ (scan), M7 (imports) |
| `src/daemon/tray.zig` | M5 ✅ |
| `src/hosts/linux/layer_shell/main.zig` | M6 ✅ |
| `src/renderers/web/main.zig` | M7 ✅ (Windows: WebView2); Linux (WebKitGTK) open |

---

## M0: Foundation ✅

**Goal:** a project that builds, tests and cross-compiles, with the parts shared by every platform already written.

- [x] `build.zig` with the `zmural` library module, 6 executables (+ `zmural-layer-shell` on Linux), and `test` / `run` / `cli` steps
- [x] Wire framing + control / renderer / display protocols (`src/protocol/`)
- [x] Core logic with tests: layout, coverage grid, pause policy, monitor IDs (EDID), `zmural.toml` manifest parser
- [x] Daemon logic with tests: playlists (sequential / shuffle / random), renderer router with sharing
- [x] CLI argument parsing, Linux backend selection
- [x] README, LICENSE, THIRD_PARTY_NOTICES, reference notes
- [x] `git init`, first commit, GitHub repo (`AstraLibernis/zmural`, private for now)
- [x] CI: GitHub Actions running `zig build test` on Windows + Linux, plus the Linux cross-build
  - Removed 2026-09-28 (tests run by hand), and back since 2026-09-30 with a boot test of the real daemon on Windows (see the ground rules and the CI item in M6).

**Done when:** a fresh clone passes `zig build test` in CI on both OSes.

## M1: Behind the icons ✅ (Windows)

**Goal:** prove the riskiest Windows trick on the real machine (Win11 25H2 uses the "raised desktop" layout) before building anything on top of it.

Files: `src/hosts/windows/workerw.zig`, new `src/hosts/windows/win32.zig` (our own minimal user32/gdi32 declarations, no binding package), `src/hosts/windows/monitors.zig`, `src/daemon/demo.zig`.

- [x] Minimal Win32 declarations: FindWindow, SendMessageTimeout, EnumWindows, FindWindowEx, SetParent, SetWindowLongPtr, SetWindowPos, MapWindowPoints, SetLayeredWindowAttributes, EnumDisplayMonitors, GetMonitorInfo, SystemParametersInfo, SetWinEventHook, RegisterWindowMessage
- [x] `Host.init`: send Progman 0x052C, detect **classic** vs **raised** layout, find the parent window
- [x] Monitor enumeration → `layout.Rect` per monitor (virtual-screen coords, per-monitor DPI aware)
- [x] `Host.attach`: tame the window (borderless, tool window, no-activate, off-screen), then parent it (raised: WS_CHILD + WS_EX_LAYERED set **before** SetParent, z-ordered under SHELLDLL_DefView), map and position it
- [x] `zmural --demo`: an in-process test window per monitor drawing a moving gradient (plain GDI is fine; the point is placement, not rendering). Removed after the audit, since real renderers replaced it.
- [x] Recovery: TaskbarCreated (with an Explorer PID check) and an EVENT_OBJECT_DESTROY hook on the parent → re-attach
- [x] Clean exit restores the static wallpaper (classic layout only)

**Verified 2026-09-26** on Win11 build 26200 (raised layout), one 2560×1440 monitor, by inspecting the window tree:
- The demo window is a layered child of Progman, directly below SHELLDLL_DefView, and covers the full monitor. There are no top-level zmural windows.
- CPU: 0.03 s over the first 3 s, at 30 fps with GDI.
- Force-killing Explorer: the destroy hook fired and the demo re-attached to the new Explorer PID.
- `taskkill` (without /f) → clean exit in 0.1 s with no windows left.

Not yet verified: the classic layout (no classic-layout machine here) and multiple monitors.

**Done when:**
- The gradient shows behind the icons on every monitor, and the icons stay clickable.
- `taskkill /f /im explorer.exe` followed by restarting Explorer brings the wallpaper back within about 2 s.
- Quitting leaves the normal wallpaper and no stray windows (Alt-Tab, taskbar, Task View all clean).
- It works in the raised layout (this machine). The classic layout is at least code-reviewed.

## M2: Process split ✅ (Windows)

**Goal:** the architecture from the README. The daemon routes; renderers live in their own processes.

Files: `src/protocol/pipe.zig`, `src/os/{win32,process,desktop}.zig`, `src/sdk/{renderer,testpattern}.zig`, `src/renderers/image/windows.zig`, `src/watchdog/main.zig`, `src/daemon/runtime_windows.zig`.

- [x] Transport (Windows): overlapped named pipes (single instance, remote clients rejected, owner-only DACL), framed over `protocol.wire`. Reader threads hand frames to the UI thread with PostMessage.
- [x] The daemon spawns `zmural-<kind> --ipc <pipe> --path <wp>` and waits up to 10 s for it to connect back (it gives up early if the child exits). The child shares the daemon's stderr.
- [x] Renderer SDK: connect → `ready` → `init` → `add_surface`… → `play` / `pause` / `stop`. A renderer exits when the daemon's end of the pipe closes.
- [x] `zmural-image` draws the test pattern in one window per **surface** and reports `window { surface, handle }`; the daemon attaches it through the WorkerW host
- [x] Router in use: monitors showing the same wallpaper share one renderer, which gets one surface per monitor; unused renderers are stopped
- [x] Renderer supervision: restart with backoff (2 s → 4 s → 8 s → 10 s), giving up after 5 crashes within a minute
- [x] Crash cleanup: **changed from the plan.** Renderers live in a kill-on-close Job Object, so the kernel reaps them however the daemon dies. `zmural-watchdog --parent <pid>` only repaints the static wallpaper afterwards.
- [x] Protocol version + capability check on `ready`

**Verified 2026-09-26** on Win11 26200 (raised layout), one monitor:
- The renderer's window (owned by the renderer process) sits directly below SHELLDLL_DefView, full monitor. CPU is about 0.02 s per process.
- `taskkill /f` on the renderer → "connection ended" → restarted after 2 s, and its window is back in place.
- `taskkill /f` on the daemon → **0** zmural processes and 0 windows left.
- An always-crashing renderer (the video stub) → backoff of 2/4/8/10 s, then gave up after the 5th crash (25 s).
- Explorer force-killed → the same renderer process survived, recreated its surface, and was re-attached to the new Explorer.
- `taskkill` (without /f) → "stopped, desktop restored", with no processes left.

Not yet verified live: sharing one renderer across **2 monitors** (only one monitor here). The router logic is unit-tested.

## M3: Real wallpapers ✅ (Windows)

**Goal:** your own videos and images as wallpaper.

Files: `src/os/libmpv.zig`, `src/sdk/windows_renderer.zig` (shared by `zmural-video` and `zmural-image`).

- [x] libmpv loaded at runtime (`LoadLibraryW` on `libmpv-2.dll` next to the exes), bound by hand from mpv's `client.h`, API major version checked. A missing DLL is reported to the daemon as a renderer failure.
- [x] Video: `wid` into the surface window, `loop-file=inf`, `hwdec=auto-safe`, volume and mute (**muted by default**), pause via the `pause` property
- [x] Wallpaper-safe mpv: no user config, no OSD/OSC, no input, and `stop-screensaver=no`, so a wallpaper never keeps the screen awake
- [x] Image: the same libmpv path. Still images show once and idle (`image-display-duration=inf`); GIFs loop.
- [x] Fill modes mapped onto mpv (`crop`→`panscan=1`, `fit`→`panscan=0`, `stretch`→`keepaspect=no`, `center`→`video-unscaled`)
- [x] `set_property` → mpv property (the manifest name is the mpv property name)
- [x] `zmural --apply <file>` (plus the `--paused` testing aid) until the CLI works (M5)
- [x] mpv teardown runs on a worker thread, so its window messages can't deadlock our message loop
- [x] `zig build` installs `third_party/mpv/libmpv-2.dll` (git-ignored) next to the exes when it's present
- [x] **LGPL, not GPL:** uses zhongfly/mpv-winbuild's `mpv-dev-lgpl` build (`-Dgpl=false`; no x265 and no other GPL-only components). Re-measured with it, with identical results.

**Verified 2026-09-26** on Win11 26200, RX 9070 XT, 2560×1440. Test media (git-ignored in `media/`, never distributed): Blender *Sintel* trailer (CC BY 3.0, © Blender Foundation), Webb "Cosmic Cliffs" (credit: NASA, ESA, CSA, STScI), rotating Earth GIF (CC BY-SA 3.0, Marvel / Wikimedia Commons, based on NASA imagery).

| Wallpaper | Result | CPU | GPU |
|---|---|---|---|
| 1080p24 H.264 video, playing | `hwdec=d3d11va` | 0.0–1.3% | 3D 1.3%, video decode 2.7% |
| same video, **paused** | | **0.00%** | **0.00%** |
| still JPEG | shown once, then idle | 0.0% | idle |
| animated GIF | animates at 11 fps | 0.6–1.9% | 0.3% |

Not yet verified: 4K60 video (no 4K test file here).

## M4: Smart pausing ✅ (Windows)

**Goal:** the "game-first" promise. Wallpapers get out of the way.

Files: `src/hosts/windows/facts.zig`, `src/daemon/runtime_windows.zig`, using `core/policy.zig` and `core/coverage.zig`.

- [x] Window events (foreground, minimise/restore, move/size end, show/hide, cloak/uncloak, location changes of top-level windows) via out-of-context SetWinEventHook, **coalesced** into one re-check 100 ms after the first event, plus a 2 s backstop
- [x] Only windows that hide the desktop count: minimised, cloaked (other virtual desktops), click-through overlays (Steam/Discord/GPU overlays), floating tool windows and shell windows are skipped, and bounds come from DWM (no invisible borders)
- [x] Per-monitor facts: fullscreen (a window covers the whole monitor, or the shell reports a D3D-fullscreen/busy/presentation state), maximised, covered (coverage grid), focused
- [x] System facts: battery and battery saver (`GetSystemPowerStatus`, re-checked on `WM_POWERBROADCAST`), session lock (`WTSRegisterSessionNotification`), remote session, app rules (foreground executable name, `settings.app_rules`)
- [x] `Policy.decide` → per renderer: play / mute / pause / stop. A shared renderer takes the **weakest** action of its monitors (keeps playing while any of them can see it). Stronger actions apply at once; relaxing waits 400 ms, so brief changes don't flicker. `stop` kills the renderer and restarts it when lifted.
- [x] Log line with the facts per monitor, the system facts and the foreground app, plus every renderer transition

**Verified 2026-09-26** on Win11 26200 (driving a test window through each state):

| Change | Reaction | Time |
|---|---|---|
| small window in front | keeps playing | — |
| maximise | pause; GPU **0.00 %** | **140 ms** |
| minimise | resume | 539 ms (incl. the 400 ms relax delay) |
| borderless fullscreen | pause (`fullscreen maximized covered focused`) | **122 ms** |
| close it | resume | 632 ms |

Not yet verified live: an exclusive-fullscreen game (the shell's D3D-fullscreen state), battery / battery saver (desktop PC), session lock.

## M5: Windows MVP → v0.1 🔶

**Goal:** something to use every day.

Files: `src/daemon/control_windows.zig`, `src/sdk/control_client.zig`, `src/cli/main.zig`, `src/core/toml.zig`, `src/daemon/settings.zig`, `src/daemon/library.zig`, `src/daemon/tray*.zig`, `src/os/{logfile,autostart}.zig`, `tools/icongen.zig`.

- [x] Control pipe server in the daemon: `\\.\pipe\zmural-<SID>-s<session>-control`, owner-only, multi-client, hello/welcome with the capability list, every request in `protocol.control`
- [x] The CLI connects for real: status, apply, pause/play, mute/unmute, next/previous, rescan, quit, autostart; exit codes 0 / 1 refused / 2 usage / 3 not running
- [x] Single instance: a second `zmural` hands its `--apply` to the running one (the control pipe doubles as the check)
- [x] Settings load/save: `%APPDATA%\zmural\settings.toml`, self-documenting, with `[playback]`, `[library]` and `[pause]` (every automatic pause rule editable). Saved atomically; a broken file is never overwritten.
- [x] Library: scans `Videos\Wallpapers`, `Pictures\Wallpapers` and extra folders (one level of subfolders); next/previous with wraparound; rescan
- [x] Restore the last wallpaper and its paused/muted state at startup; monitor changes re-route
- [x] Tray: current wallpaper, Paused, Muted, > Next, < Previous, Rescan library, Start with Windows, Open settings file, Open log file, Quit; the tooltip shows the state; the icon is re-added after Explorer restarts
- [x] **Start with Windows on by default (owner, 2026-10-12)**, as on Linux: the first run turns it on and says so in a balloon. Off keeps the Run value and marks it disabled under `Explorer\StartupApproved\Run`, the way Task Manager and Settings > Apps > Startup do, so off is remembered and a switch made there is read back; the uninstaller removes both. Checked under Wine, then on CI's Windows runner (run 38256111421, `202cb3e`: the release zip run as a real first run, on → off → still off after a restart → on → uninstalled, reading the registry each time). Not yet across a real login.
- [x] Start at login: HKCU Run key, via the CLI or the tray; off by default
- [x] No console windows: the daemon, watchdog and renderers are GUI-subsystem programs; the daemon logs to `%LOCALAPPDATA%\zmural\zmural.log` (timestamped, rotated at 1 MiB)
- [x] The zmural icon (comet trail into a four-pointed star), generated by `tools/icongen.zig` and embedded in every executable
- [x] Release: `zig build package -Doptimize=ReleaseSafe` → `zmural-0.1.0-windows-x86_64.zip`; README install section
- [x] **Licensing:** the zip ships the LGPL libmpv build as a separate, replaceable DLL with the LGPL-2.1 text, THIRD_PARTY_NOTICES and libmpv's source record

**Verified 2026-09-26:** every CLI command and exit code; the second-instance handoff; settings save, restore and a broken file left alone; library next/previous/rescan; the tray icon located via `Shell_NotifyIconGetRect` and its menu used by hand; autostart on/status/off in the registry; zero console hosts; the zip extracted into a clean folder plays video with libmpv loaded from that folder.

Deferred: per-monitor overrides (done 2026-09-30 as `[monitors]` and `[monitor_fill]`, M8), pushed control events (the settings window asks instead), `.zip` packages and Lively import (M7). Not yet verified: an actual reboot with autostart on.

### Audit fixes (before v0.1 ships) ✅

A blind adversarial audit (`notes/audit-2026-09-26.md`) found 1 high, 5 medium and 13 low issues. All of them are fixed:

- [x] **H1** A `stop` pause rule was treated as a crash and respawned in a loop. The renderer lifecycle is now a pure state machine (`src/daemon/lifecycle.zig`, 12 tests), and the runtime only executes its commands.
- [x] **M1** Crash backoff never gave up when spawning itself failed. Attempts are now counted from the attempt, not from success, so it gives up after 5.
- [x] **M2** Any local user could squat the control pipe. The pipe is named per SID and session (`zmural-<SID>-s<N>-control`), and clients check that the server process belongs to the same user (`src/os/identity.zig`).
- [x] **M3** A slow libmpv teardown could release the wrong player slot. Teardown now carries its slot.
- [x] **M4** Overlapping library folders listed wallpapers twice. The scan now removes duplicates.
- [x] **M5** Folders and web pages could be "applied". They are now refused with a plain message, and so is the startup wallpaper.
- [x] **Low findings:**
  - clients that never send hello are dropped after 3 s (they can't block the pipe);
  - pipe writes time out;
  - reader shutdown can't hang;
  - renderers are checked by pipe peer pid and window owner;
  - the job forbids desktop and settings changes;
  - mpv is hardened (no ytdl, scripts or external files);
  - the watchdog checks against a reused parent pid;
  - the log rotates while running, and mpv log spam is rate-limited;
  - `--monitor` is refused until per-monitor wallpapers exist;
  - logoff shuts down cleanly;
  - the static wallpaper is repainted on exit;
  - a left click no longer opens the tray menu;
  - `--demo` is removed.

**Verified 2026-09-27:**
- **Tests:** 77/77 tests, on 3 runs from a clean cache (new pipe, control-server and lifecycle tests). Formatting, the Linux cross-build and zsnag are clean.
- **Live `fullscreen = "stop"`:** the renderer is stopped once, stays stopped for 15 s of fullscreen, and restarts 3 ms after the window closes.
- **Missing renderer exe:** it gives up after exactly 5 attempts, and there are no more attempts after that.
- **Refusals:** folder, web page and `--monitor` are all refused.
- **Everything else:** the SID pipe name, status, pause, next, previous and a full library loop work; video plays under the restricted job; Explorer restart re-attaches; stop is clean.

### Settings window ✅

`zmural-settings.exe` (`src/settings/`): the "simple but aesthetic" way to reach the settings, instead of the text file. The design follows `notes/settings-ui-review.md`.

- [x] **Look:** one window with Mica, following the Windows light/dark app theme and accent colour. It is drawn with Direct2D + DirectWrite through hand-written COM bindings (`sys.zig`), as immediate-mode widgets (`gui.zig`): cards, a toggle switch, a segmented control, a slider, buttons, animated hover and selection.
- [x] **Wallpapers:** a thumbnail grid of the library (shell thumbnails made on a worker thread). Click to show; right-click for Show on desktop / Show in folder. There are also Open file and Add folder buttons, and an empty state.
- [x] **Playback:** fill mode (Crop / Fit / Stretch / Center), volume (live while dragging), mute, pause.
- [x] **Pausing:** each detected situation with Nothing / Mute / Pause / Stop, the app list (add a program with the file picker, remove), and the resume delay.
- [x] **General:** Start with Windows, library folders (the standard ones shown as always included), open the settings / log file, reset playback and pausing (with confirmation), and About.
- [x] **Welcome (2026-10-06):** the first page in the sidebar: what zmural is, up to four wallpapers to click, the standard folders with Open (made if missing), Add folder and Open file, what can be a wallpaper, and pointers to Pausing, Playback and General. The window opens there whenever nothing is showing, and opens by itself on zmural's first run (no settings file, no `--apply`; not under `$ZMURAL_CONFIG_DIR`). While it shows, it rescans every 3 s, so files put in a folder appear without Rescan. Seen on Sway in both themes and at the minimum size; `tools/settings-test.sh` step 8. Windows: compiled and unit-tested under Wine only, not yet seen.
- [x] **Prism, the wallpaper zmural ships with (2026-10-06):** a 12-second VP9 loop (646 KB) drawn by `tools/wallgen.zig` (`zig build starter-wallpaper`; checked against an independent numpy version, max 1/255 apart). Installed as `share/zmural/wallpapers` beside `bin` (Linux) or `wallpapers` beside the programs (Windows), and in both packages. It shows whenever no wallpaper is set (filled in, never saved as the user's choice), so a first run, Plasma's included, never leaves the desktop empty; the library lists it after the user's own files (`Library.scanLast`). Windows' standard folders now follow where Windows keeps Videos and Pictures (`SHGetKnownFolderPath`, so a OneDrive move is followed).
- [x] **A wallpaper that can't be played (2026-10-06):** a renderer saying "cannot play" or "cannot show" (a text file named .mp4, a format nothing reads) now brings back the last wallpaper that reached the screen, or Prism when none has in this run; a monitor that had it as its own follows the main one again. A notification names the file, what was wrong and what shows instead, and the broken file is not left saved. Never a loop: if Prism itself can't play, nothing changes but the notice. `daemon/fallback.zig` (unit-tested), both runtimes on their next tick; `tools/broken-test.sh`. Windows: compiled and unit-tested under Wine, not yet seen.
- [x] **Sidebar:** a now-playing card with its thumbnail and previous / pause / next / mute.
- [x] **When zmural isn't running:** a banner with Start zmural; the window reconnects by itself.
- [x] **Tray:** a left click opens the window (one at a time: a second launch brings it forward); a right click opens the menu, which now has Settings....
- [x] **Protocol:** new control requests `get_settings`, `library` (paged), `set_fill`, `set_volume`, `set_rule`, `set_resume_after`, `set_list` and `reset_settings`; the wire format now carries fixed arrays. Lists are capped (32 items, 600 bytes each), so a reply never cuts one short. Pipe reads can time out, and `send` fits a full 64 KiB frame (it used to be 8 KiB).

**Verified 2026-09-27**, against a scratch config and checked each time in the saved `settings.toml` or `zmural-console status`:
- **Every page:** screenshots in both themes.
- **Wallpapers:** a thumbnail click switches the wallpaper.
- **Playback:** Fit restarts the renderer with the new fill; volume and pause save.
- **Pausing:** a rule set to Stop saves; notepad.exe added through the file picker saves; wheel scrolling works.
- **General:** a folder removed, then added back through the folder picker (the library goes 3 → 0 → 3); Start with Windows on and off in the registry; Reset back to defaults.
- **Sidebar and window:** the now-playing buttons (next, pause, unmute); the offline banner starting zmural and the window reconnecting; a second launch keeping one window.
- **Tray:** a real left click on the tray icon opens the window.

- [x] **Keyboard navigation (2026-09-30)**, on both OSes, in the shared widgets (`settings/gui.zig`), so every control has it: Tab and Shift+Tab walk the pages, the player card's buttons and the page's controls in order; Enter or Space presses; Left and Right (Home, End) change a slider by a twentieth or a choice row by one, and otherwise move like Tab, as do Up and Down; the Menu key or Shift+F10 opens a wallpaper's menu under it (first line focused, Escape closes it, the focus comes back); the reset question opens with No focused, so Enter never resets by accident. A focus ring shows once a key is used and hides on a click, and the page scrolls to what has the focus, wallpapers scrolled out of sight included. Linux reads the compositor's keymap (`settings/keymap.zig`) instead of assuming a keyboard's codes, which a virtual keyboard (on-screen, remote desktop, test tools) doesn't follow; held Tab and arrows repeat at the desktop's rate; keys pressed faster than frames are drawn each get their own frame. `tools/keyboard-test.sh` drives the window by keyboard alone on headless Sway (12 checks). Windows: the same widgets, keys from `WM_KEYDOWN` and the context-menu message; compiled, not yet tried with a keyboard. **Tried by the owner on Plasma (2026-09-30, after a re-login): works as described, felt awkward. Two changes wanted: arrows should move in the direction pressed (along and between rows of the grid, between pages in the sidebar) instead of acting as Tab, and Escape should close the window when no menu is open** (`notes/host-test-2026-09-30.md`, findings 10 and 11). **Bug seen there too (finding 12): on KDE the window is frozen for ~4 s after opening, because the portal's `SettingChanged` signals for `org.kde.VirtualKeyboard` make the hook call `theme()` from inside a pending `dbus.call()`, which eats the outer reply and waits out the 2 s receive timeout, twice.** **All three changed 2026-10-01:** Tab moves between groups (the pages, the player card's buttons, the buttons above the wallpapers, the page) and comes back to where each was; the arrows move to the nearest control that way inside the group (Left and Right stay on the row); Home and End go to the group's ends; Escape closes the window when no menu or question is open; the theme is re-read on the next loop turn and only for the appearance keys, and `dbus.call()` refuses to run inside another call's wait. Unit-tested here; `tools/keyboard-test.sh` rewritten for the new keys but not yet run (no rig on this machine); not yet tried on a desktop. **Tried on Windows 2026-10-01** (keys posted to the window and pressed for real): Tab between groups, the arrows in the grid, Home/End, Escape, the Menu key and Shift+F10 (after 3b20fdd) and held keys (only Tab and the arrows repeat, after 81cd693) all work; the reset/uninstall question opens on No. `notes/windows-check-2026-10-01.md`.
  - Seen once and not reproduced since (seven tries): a zmural that logged the quit and the window closing during a keyboard-test run, then didn't exit.
- [x] ~~Screen-reader support (UI Automation on Windows, AT-SPI on Linux)~~ **Not supported (owner, 2026-10-06).** The settings window draws everything itself, so a screen reader sees nothing in it; the README says so, and `zmural-console` does everything the window does from a terminal.

### Audit #2 fixes ✅

Every finding in `notes/audit-2026-09-27.md` except F15, which was already fixed:

- [x] **F1** After a logoff shutdown, still-queued messages only have their payloads freed (`afterShutdown`); the loop then quits.
- [x] **F2** A window handle of 0 is refused instead of panicking the daemon.
- [x] **F3** A startup wallpaper that's missing for now is kept in settings.toml and shown as soon as it turns up (checked every 5 s).
- [x] **F4** Give-up is now "5 short-lived runs in a row" (a run under 30 s). The old 60 s window never slid, so a renderer crashing every 25 s retried forever.
- [x] **F5** Hand edits to settings.toml are picked up live (checked every second) and applied, so saves no longer overwrite them.
- [x] **F6** `--paused` holds for that run only; the file keeps its own value until the user pauses or plays.
- [x] **F7** Renderer pipe names carry 64 random bits.
- [x] **F8** Library scans run on a worker thread; the old library stays in use until the new one is ready.
- [x] **F9** Device and raw NT paths (`\\.\`, `\\?\`, `\??\`, either slash) are refused.
- [x] **F10** CLI replies time out after 10 s; the busy-pipe wait is bounded in total.
- [x] **F11** Renderer log text has control characters replaced and is capped at 512 bytes; a renderer can only place windows on monitors it feeds.
- [x] **F12** Pipe DACLs name the user's SID, so an elevated zmural still admits the user's normal CLI and settings window.
- [x] **F13** The README now says plainly that renderers aren't sandboxed yet; a sandbox is on M8.
- [x] **F14** App rules match Unicode exe names of any length.
- [x] **F16** Everything is freed at shutdown and on run()'s early-error paths.
- [x] **D1–D4** Removed `set_property` / `seek` / `screenshot`, `loaded`, the never-sent control pushes, `st.kind` and `SW_HIDE`; fixed the stale comments and docs.

**Verified 2026-09-27:**
- 96/96 tests pass, including new ones for F3, F4 (the 25 s trace and a late burst), F6, F9 and F11. fmt, zsnag and the Linux cross-build are clean.
- Live, against a scratch config:
  - `--paused` with a missing startup wallpaper: a save keeps the wallpaper path and writes `paused = false`.
  - Copying the file into place shows it within 5 s.
  - A hand edit (volume 77, fit) is reloaded, restarts the renderer with Fit, and survives the next save.
  - `//?/C:/…` is refused.
  - The library scan and renderer pipes work.
- Not tested live: logoff (F1), an elevated daemon (F12), a hung daemon (F10) and a hostile renderer (F2/F11). These are covered by code review and unit tests only.

### User requests (2026-09-27) ⬜

To do after the audit #2 fixes:

- [x] **One zmural to install and launch, not seven programs.** Reworded 2026-09-30 from "one exe": what the owner wants is one install and one icon, with the layout under "How zmural is put together" above. The package shipped `zmurald` (the app), `zmural` (the command line), `zmural-settings`, `zmural-watchdog`, `zmural-video`, `zmural-image` and `zmural-web` (and `zmural-layer-shell` on Linux).
  - [x] **Renderers, the watchdog and the layer-shell host are modes of zmural (2026-09-30).** zmural starts itself again as `--renderer video|image|web`, `--watchdog` (Windows) or, run by the user for now, `--layer-shell` (Linux). Each is still its own process, so a renderer crash stays out of the daemon. Seven Windows programs became three (the app, the command line and `zmural-settings`), and Linux had the same three, until the settings window moved too (next item). On Linux zmural now links libc, which the renderers always did. Proven on Linux by every rig in the table at the top (they all start renderers and the host this way) and on Windows by CI's boot test, which starts a renderer for the test pattern; the Windows watchdog's new start line is compiled and unseen.
  - [x] **The settings window runs inside zmural (2026-09-30).** It is a thread of zmural with its own window loop, still talking to the daemon over the control protocol. The tray opens it; `zmural --settings` asks a running zmural for it (the new `open_settings` request) or starts one with it open, and the app-menu entry on Linux now runs that. A second ask raises the one window. `zmural-settings` is gone: two programs ship per OS, the app and the command line. Its own log file is gone too; its lines are in `zmural.log`. Cairo and Pango stay loaded once used: unloading them crashed zmural when the window's thread ended (found by the new test).
    - **Proven on Linux:** `tools/settings-test.sh` on headless Sway (open, raise, the pages drawn, a click on pause and on a thumbnail reaching the daemon, close, open again, `zmural-console quit` with the window open exiting 0, `--settings` with no zmural running), and `tools/kde-test/run.sh` on Plasma (tray clicks, the launcher hand-over, a clean close).
    - **Windows:** CI's boot test asks for the window twice and quits with it open: on the runner it opened, the second ask raised it, it closed on quit and zmural exited 0. That is from the log; nobody has looked at the window on Windows since it moved.
  - [x] **Names (owner, 2026-09-30): the app is `zmural`, the command line is `zmural-console`.** They were `zmurald` and `zmural`. The same two programs ship on both OSes: on Windows the command line has to be its own console program, and Linux keeps the same pair so the two stay alike. The log file is `zmural.log` now. An upgrade still replaces a running or hung `zmurald`. On a machine that ran the old names, the Windows "Start with Windows" entry points at `zmurald.exe` and needs switching off and on once; the Linux autostart entry and launcher fix themselves on the first run.
  - [x] ~~An installer on Windows and a package on Linux with one launcher entry (M8).~~ **Closed (owner, 2026-10-06): no installer.** Unzipping is enough; zmural adds its own menu entry and start at login on first run, and the uninstaller removes them. Distro packages stay under M8's updates and distribution.
- [x] **Settings live in the window, not the text file (done 2026-09-29, checked key by key 2026-09-30).** The user wanted settings as a window of options, each with a short explanation, rather than a text file. Every key `settings.toml` holds has its control: the wallpaper (Wallpapers page), fill, volume, rotation and order (Playback), each pause rule, the app list and the resume delay (Pausing), library folders and start at login (General), paused and muted (the player card). Nothing in the tray or the window opens the file any more; it stays as the storage format and can still be edited by hand. This settles F5 in `notes/audit-2026-09-27.md`.

## Requirements (decided 2026-10-05)

zmural's floors are the lowest versions of the parts it builds on, taken from those parts
(README [Requirements](../README.md#requirements); the full inventory in
`notes/compat-2026-10-05.md`). Not a list of chosen systems, and no per-system workarounds:
where a known requirement falls short, zmural says what it needs once and installs nothing.

- [x] Windows: Windows 11 only (Windows 10 is not a target). The release is built for a
  baseline x86-64 CPU: `zig build package` refuses a native-CPU Windows build (it was
  native before, so a zip built on an AVX-512 machine could crash on other PCs).
- [x] KDE plugin and GNOME extension built inside Debian 13 (`-Dplugin-root`), the oldest
  system with what they declare: Qt 6.8 measured on the plugin (was 6.11); loads on Debian
  13's libraries and on headless Plasma with Qt 6.11 (kde-test, 18).
- [x] GNOME: exactly the versions the extension's metadata.json lists (48 to 50); a unit
  test keeps zmural's copy of the list the same. New versions come with upstream updates.
- [x] The check at startup (`daemon/requirements_linux.zig`): X11 session, Plasma below 6,
  Qt below 6.8, a GNOME the extension doesn't list, GNOME named but not running; one
  notification each, nothing installed (`tools/host-test.sh`, 6 checks).
- [x] The layer-shell host refuses a compositor below its needs with the version it found
  (wl_output below v4, i.e. wlroots before 0.16; no linux-dmabuf; no GPU render node)
  instead of a blank desktop or endless restarts; zmural falls back to the still picture.
- [x] Re-vendor waywallen-display when it adds GNOME 51 (out since September 2026). **Done 2026-10-06:** upstream v0.4.1 (released that day) declares GNOME 48–51; vendored, and zmural's startup check and docs follow. Seen on headless GNOME 50 (`tools/gnome-test/run.sh`); GNOME 51 itself not run here.

## Housekeeping

- [x] The stale `m6-linux` branch on GitHub is deleted (by the owner, 2026-09-30); `main` is the only branch.

## M6: Linux MVP → v0.2 🔶

**Goal:** the same experience on Linux, using the zero-copy path.

Work started 2026-09-28 and is on `main`. Architecture: one codebase; the platform-neutral daemon logic (`lifecycle`, `router`, `policy`, `desire`, `kind`, settings, mpv options) is shared, and each OS has its own runtime shell (`runtime_windows.zig` / `runtime_linux.zig`), transport (`pipe.zig` / `unix.zig`) and renderer runtime (`windows_renderer.zig` / `linux_renderer.zig`).

- [x] Transport: `protocol/unix.zig`. SOCK_SEQPACKET (one frame per `sendmsg`, fds ride on their frame), socketpairs for spawned children (`--ipc fd:N`), `$XDG_RUNTIME_DIR/zmural/` checked to be 0700 and ours, SO_PEERCRED uid check on accept. 7 tests.
- [x] Renderer side: `os/gpu.zig` (GBM + EGL + GLES, all dlopen'd) and `sdk/linux_renderer.zig`. A pool of 3 single-plane DMA-BUFs per surface on the compositor's GPU, in the compositor's preferred modifier (compressed multi-plane layouts are skipped; linear is the last resort). `buffers` once, then `frame_ready` per frame; slots come back with `release`.
- [x] Video and images via the libmpv render API into those buffers. One mpv feeds every surface. Pause is mpv's `pause`: 0 CPU while paused (measured: 0 ticks in 3 s), 0 for a still image.
- [x] Daemon: `daemon/runtime_linux.zig`. `display.sock` for hosts, renderers reaped through pidfds, restarts and pause/stop through the shared `Supervisor`, fan-out of buffers and frames with their fds, releases routed back.
- [x] `zmural-layer-shell`: a pure-Zig Wayland client (`os/wayland.zig`, no libwayland). One background layer surface per output; the wallpaper is a subsurface whose `wp_viewport` crops and scales, so the compositor imports the DMA-BUFs directly (no Vulkan in the host, no copy). Frames are latest-wins on `wl_surface.frame`. Reconnects with backoff when the daemon restarts. Monitor IDs from the sysfs EDID when there is one.
- [x] Window state from `zwlr_foreign_toplevel_management_v1` (fullscreen, maximized, focused per output). Works on Sway, where waywallen has no auto-pause.
- [x] **Display protocol is now waywallen-display-v1 v9 (2026-09-28)**, so waywallen-display's KDE Plasma plugin and GNOME extension can be vendored and pointed at zmural. Zig codec (`protocol/ww_display.zig`) checked byte for byte against waywallen's generated C codec (`zig build ww-codec-check -Dwaywallen-display=<checkout>`). zmural: handshake, registration, `bind_buffers`, and per-frame acquire sync_file + release syncobj (`os/syncobj.zig`, raw DRM ioctls); a slot returns to the renderer only when the display's release fence signals (polled). Our layer-shell host speaks it too. The old `protocol/display.zig` is gone.
- [x] **Explicit sync, renderer side (2026-09-30).** A frame no longer waits for its GPU work (`glFinish`): the renderer makes an EGL native fence (`EGL_ANDROID_native_fence_sync`), sends its sync_file with `frame_ready`, and zmural passes it on as the frame's acquire fence, which the display waits on. A driver without native fences falls back to `glFinish` and the already-signaled fence as before; the renderer logs which. Checked: every screenshot rig and the Plasma and desktop-matrix runs pass with fences on (the log says so). Measured: no CPU difference for a 1440p60 VP9 video on headless Sway (11 to 15 ticks per 10 s before, 12 to 13 after, three runs each); what it buys is that the renderer no longer stalls on the GPU, not CPU.
- [x] **Sway's IPC for window facts (2026-09-30)**, `daemon/compositor_sway.zig`. The display host's window list (wlr-foreign-toplevel) can't see workspaces or where windows are, so on Sway zmural reads the window tree from `$SWAYSOCK` on every window, workspace and output event, and uses it instead of the host's flags: fullscreen counts only where the window's workspace is showing (a fullscreen window left on another workspace used to keep the wallpaper paused for good), `covered` when the showing windows and their title bars cover almost all of an output (the coverage grid Windows uses), focused per output, and the focused window's process for the app rule. The Pausing page now offers `covered` and the app rule on Sway. `tools/sway-test.sh` checks each on headless Sway; with zmural blind to the IPC, six of its eight checks fail.
- [x] **The app rule on Niri (2026-09-30)**, `daemon/compositor_niri.zig`: the focused window's process from Niri's IPC (`$NIRI_SOCKET`, its event stream, then `FocusedWindow`). Only the app rule: Niri 26.04 reports no fullscreen state and no reliable on-screen position, so the other window facts stay the display host's. `tools/niri-test.sh` runs Niri nested in headless Sway; with zmural blind to the IPC three of its four checks fail.
- [x] **Hyprland's and Wayfire's IPC (2026-10-06)**, `daemon/compositor_hyprland.zig` and `compositor_wayfire.zig`, behind one watcher with Sway's (`compositor.zig`). Per monitor: fullscreen and maximized only for a window on a workspace that is showing (Hyprland: the monitor's active or open special workspace; Wayfire: windows are placed relative to the workspace showing, so one elsewhere lies outside the output), `covered`, focused, and the process in front for the app rule. Hyprland: its event socket, then `j/clients`, `j/monitors`, `j/activewindow` on its request socket (waywallen runs `hyprctl`; zmural reads the socket itself). Wayfire: needs its `ipc` and `ipc-rules` plugins; without them the log says which to turn on. `tools/compositors-test.sh` (11): Wayfire 0.10 headless, Hyprland 0.56 (a third-party COPR build, sdegler/hyprland: Fedora 44 doesn't package it) nested in a headless KWin, since Sway's xdg-shell v5 is too old for it. Designed after waywallen-display's watchers (MIT).
- [ ] `covered` and hidden-workspace fullscreen on Niri, once its IPC says where windows are (upstream). Until then a fullscreen window on a hidden Niri workspace still pauses.
- [x] ~~App rule and `covered` on GNOME: need them from zmural's GNOME extension.~~ **Dropped (owner, 2026-10-06):** no other GNOME live wallpaper does it either, and it would mean carrying changes to waywallen-display's extension.
- [x] **System facts (2026-09-29)**, `daemon/facts_linux.zig`: on battery (UPower), the Power Saver profile (power-profiles-daemon, either bus name), screen locked (logind `LockedHint`, or the desktop's org.freedesktop.ScreenSaver as KDE's locker has it), session inactive and remote session (logind), and GameMode (a game registered). Read every second on a thread with its own bus connections, so a hung service can't stall frames; services that aren't running count as "no" and are never started. The Pausing page offers them on Linux. Tested against python-dbusmock stand-ins on headless Sway: each one pauses the wallpaper and resumes it; a service stalling for 30 s leaves `zmural-console status` at 3 ms. On the owner's real Plasma session (2026-09-30, evening) GameMode, screen locked, session inactive (`chvt`), Power Saver (tuned-ppd), fullscreen, maximized and the app rule each paused and resumed the wallpaper; battery and remote session can't be triggered on that desktop. Idle (logind `IdleHint`) isn't a rule yet.
- [x] Control socket (`control.sock`, 2026-09-28): `zmural-console` works on Linux (status, apply, pause/play, mute, quit, autostart at first; since 2026-09-30 every request the Windows daemon answers, so the whole settings window works too). The wallpaper, paused and muted are saved, so zmural started at login shows the last wallpaper.
- [x] **One zmural per session, and takeover (2026-09-28).** A starting zmural checks `control.sock` first: a healthy one of the same version gets the `--apply` and keeps running; an older/newer version is asked to quit and replaced; one that doesn't answer within 3 s is stopped (SIGTERM + SIGCONT, then SIGKILL) and replaced, but only after the kernel confirms it's this user's zmural (SO_PEERCRED, `/proc/<pid>/exe`); anything else on the socket is never killed, and zmural refuses to start. `tools/instance-test.sh`: 22 scenarios pass.
- [x] **Start at login (2026-09-28)**, on by default with an off switch: an XDG autostart entry (`~/.config/autostart/zmural.desktop`) that zmural writes on first run. The file is the setting: `zmural-console autostart off` writes `Hidden=true` (what KDE's and GNOME's own Autostart settings write too), and zmural never turns it back on; an entry pointing at a moved zmural is fixed. The entry passes `desktop-file-validate`. Not yet tried on a real login (the container has no session manager). The settings window's General page has the toggle.
- [x] **zmural starts its layer-shell host itself (2026-09-30).** On a desktop that isn't KDE Plasma or GNOME and has a Wayland display, zmural starts `zmural --layer-shell --parent <pid>` and supervises it: started again if it dies (1 s, 2 s ... 30 s apart when it keeps dying quickly), never twice on one display (the host holds a lock per display; one started by hand is used instead), and gone when zmural quits or is killed (the kernel's parent-death signal). A compositor without wlr-layer-shell or DMA-BUF is tried once: the host exits with a code that says so, and zmural logs that live wallpapers can't show there. `tools/host-test.sh` on headless Sway checks each of these by screenshot and process count, and the no-layer-shell case on Mutter; the other rigs now start only zmural.
- [x] **Still-picture fallback (2026-09-30).** Where nothing live can show (no Wayland display, as in an X11 session, or a compositor without wlr-layer-shell), zmural sets the showing picture as the desktop's own wallpaper through the XDG wallpaper portal (`SetWallpaperURI`, background, no preview), again whenever it changes, and tells the user once. A video can't be set that way; the log says so. `tools/still-test.sh` checks the calls against a python-dbusmock portal. Not used on KDE Plasma or GNOME: setting the portal there would switch the desktop away from zmural's plugin or extension. **2026-10-06:** a video now gets one of its frames, and KDE and GNOME get the still where zmural's plugin or extension can't run (below).
- [x] **The still picture on KDE Plasma and GNOME, and of a video (2026-10-06).** Where zmural's plugin or extension can't show anything yet (a Plasma or Qt too old for the plugin, an X11 session, an unsupported GNOME, or GNOME before the next login after installing the extension), the showing wallpaper is set as the desktop's own through the wallpaper portal. Never where zmural's own plugin runs, so Plasma isn't switched away from it. A video becomes one of its frames: `zmural --still-frame` (libmpv's image output, a tenth of the way in) in a process of its own, cached in `~/.cache/zmural/stills`. On GNOME the user's own background (`picture-uri`, `picture-uri-dark`) is kept first and put back by uninstall, which also removes the cache. Not on Plasma: there is no way to read its current picture back. `tools/still-test.sh` (15, with stand-ins for GNOME's and Plasma's programs).
- [ ] KDE Plasma whose plugin installed but couldn't be switched to (Plasma not reachable at the time): nothing shows until the user picks zmural, and no still is set (the plugin may still be chosen).
- [x] State and cache under the XDG base directories: settings in `$XDG_CONFIG_HOME/zmural`, the log and the "already told" notes in `$XDG_STATE_HOME/zmural`, thumbnails from the freedesktop cache in `$XDG_CACHE_HOME`, sockets in `$XDG_RUNTIME_DIR/zmural`.
- [x] **Renamed or translated Videos and Pictures folders are followed (2026-09-30).** The folders always scanned are `Wallpapers` in the user's Videos and Pictures folders, found through `$XDG_VIDEOS_DIR` / `$XDG_PICTURES_DIR`, else xdg-user-dirs' `user-dirs.dirs`, else `~/Videos` and `~/Pictures` (`os/xdg.zig`). The log names them at startup. `tools/instance-test.sh` gives a home with `~/Vidéos` and `~/Bilder` and checks the library holds their wallpapers and not `~/Videos`' (it fails on the code before).
- [x] **Settings window on Linux (2026-09-28).** The Windows window's pages and widgets are shared (`settings/app.zig`, `settings/gui.zig`); each OS has a drawing backend (Direct2D `gui_d2d.zig`, Cairo + Pango `gui_cairo.zig`, dlopen'd) and a platform file (`platform_windows.zig`, `platform_linux.zig`). On Linux it's a pure-Zig xdg-shell window: server-side decorations where offered, else its own title bar (move, resize, minimise, maximise, close); icons from a Fluent UI System Icons subset; light/dark and accent from the Settings portal, followed live; folder and file pickers through the FileChooser portal; thumbnails from the freedesktop thumbnail cache. Tested on headless Sway with scripted clicks (`tools/wl-input.zig`): apply, the right-click menu, fill, mute, a pause rule, and Reset through its confirm dialog, each checked in `settings.toml` and `zmural-console status`; and on GNOME with its own title bar.
- [x] **One settings window, and a launcher (2026-09-28).** The window owns `org.zmural.Settings` on the session bus; a second launch passes its xdg-activation token to the first (`Activate`) and exits, and the first raises itself with `xdg_activation_v1`. zmural installs `~/.local/share/applications/org.zmural.Settings.desktop` and hicolor icons (16–256 px), so app menus and docks show zmural's icon; they are rewritten when they differ. Tested on Plasma 6: three tray clicks and a shell launch leave one window.
- [x] **Tray via StatusNotifierItem + dbusmenu (2026-09-28)**, in zmural (`daemon/tray_linux.zig`): the icon (embedded pixmaps, so no icon theme is needed), a tooltip with the wallpaper and state, a left click that opens the settings window (with the host's activation token), and a menu: the showing wallpaper, Paused, Muted, Next, Previous, Rescan library, Start at login, Settings..., Quit. It re-registers when the tray host (re)starts. Tested on Plasma 6 (headless, with kded6's watcher): the icon in the panel, menu clicks toggling pause and mute, a left click opening the window. GNOME has no tray without the AppIndicator extension; zmural doesn't install that.
- [x] **Log file (2026-09-30)**, `os/logfile_linux.zig`: zmural appends to `$XDG_STATE_HOME/zmural/zmural.log` (the settings window had `zmural-settings.log` until it moved into zmural the same day; its lines are in `zmural.log` now) (`~/.local/state/zmural` by default), readable only by the user, capped at 1 MiB with one `.old.log` kept, as on Windows. Lines carry a local timestamp with milliseconds; stderr (the terminal or the journal) still gets each line as before, unstamped. zmural links no libc, so the local time comes from `os/localtime.zig`: it reads `/etc/localtime` or `$TZ` (TZif transitions, then the POSIX rule in the footer) and was checked against Python's `zoneinfo` for all 599 zones in Fedora's tzdata at 4,455 instants each (1900 to 2100), with no difference. The settings window's General page shows the "Log file" row on Linux. Renderers send their lines (mpv's warnings included) to zmural, which logs them as `[video 1] ...`; only a renderer that fails before it connects, and the layer-shell host, write to stderr alone.
- [x] **Fixes from the first real Plasma session (2026-09-30)**, `notes/host-test-2026-09-30.md`: fullscreen and maximized windows now pause the wallpaper on KDE (the plugin reports them with `set_window_observation_state`, which zmural used to drop); the settings window no longer aborts on close (thumbnails were freed after Cairo was unloaded); zmural collects the settings windows it starts instead of leaving zombies. `tools/kde-test/run.sh` runs a whole headless Plasma session with zmural's plugin as the wallpaper and checks all three. Not yet re-run on the real desktop.
- [x] **App rule on KDE Plasma (2026-09-30)**, `daemon/foreground_linux.zig`: "one of your apps is in front" pauses the wallpaper. zmural loads a small KWin script over D-Bus that reports the active window's process id; the id is turned into the program's names through /proc (executable, the name it was started as, the kernel's short name) and compared with the list, so a Windows game under Proton matches as `eldenring.exe`. The Pausing page offers the rule and its app list only where something reports the app in front. Tested in `tools/kde-test/run.sh` (a listed app in front pauses, another resumes). Other desktops: not yet (wlroots needs the app id from foreign-toplevel, GNOME its extension).
- [x] **CI (2026-09-30)**, `.github/workflows/ci.yml`: on GitHub's Linux and Windows runners, each OS builds natively and runs its own unit tests, and Windows also boots the real zmural (test pattern, `status`, `pause`, `quit`). A Linux runner has no GPU render node, so there only zmural's refusal is checked; the full Linux boot tests stay in the dev container. zmural used to crash in that case (its teardown ran before startup had finished); it now exits with a message.
- [x] **Hardware video decoding (2026-09-30):** the renderer now tells mpv its render node (`MPV_RENDER_PARAM_DRM_DISPLAY_V2`), so VA-API decodes on the GPU the compositor uses and hands frames over as DMA-BUFs. Before, mpv could only use Vulkan decode with a copy back through the CPU. Measured on headless Sway (Radeon iGPU, 1440p60, CPU of `zmural-video` over 10 s): VP9 4.1% → 1.3% of one core, AV1 2.8% → 1.6%. H.264 stays on the CPU at about 13% with Fedora's own packages, because its Mesa and its FFmpeg both leave H.264/H.265 out; with RPM Fusion's `mesa-va-drivers-freeworld` and `libavcodec-freeworld` installed it drops to 1.4% (both are needed; the Mesa one alone changes nothing). The renderer tells zmural what each video got (a `decoder` message), which logs it (`decoding h264 on the GPU (vaapi)` / `... on the CPU`). zmural installs no codecs: the first time a format lands on the CPU the user gets one desktop notification ("No GPU decoder for H.264 found"), remembered per format in `<state>/notices` so it is never repeated; with no notification service it is left for the next start. `tools/decode-test.sh` checks this on headless Sway with a mock notification service. The picture was checked upright against the source, fds don't grow over loops, and a paused video still uses 0 CPU. The "Device does not support decoding h264" errors seen on the owner's desktop did not appear here and weren't reproduced.
- [x] **`settings.toml` edits are picked up while zmural runs (2026-09-30)**, as on Windows: the file is checked once a second, a changed one is reloaded (wallpaper, fill, volume, rules, folders, rotation), and one with a mistake is left alone until it is fixed. `tools/instance-test.sh` edits the file under a running zmural.
- [x] ~~Multi-plane buffers (AMD DCC and friends) and cross-GPU fallback.~~ **Dropped (owner, 2026-10-06):** no deeper GPU control. zmural stays on the GPU the desktop runs on (the compositor's main device), single-plane buffers as now. Drawing on a built-in GPU instead was measured (about 3 W saved at best on a 9070 XT desktop, likely less with real compositing; `notes/stopping-point-2026-10-06.md`) and skipped. Laptops already draw on their built-in GPU, where their desktop runs.
- [x] **KDE Plasma (2026-09-28):** zmural's Plasma wallpaper plugin is waywallen-display's, vendored and renamed (`third_party/waywallen-display`, `tools/vendor-waywallen-display.sh`), built with `zig build kde-plugin` into `zig-out/share/zmural/zmural-kde.zip`. On startup in a KDE session zmural installs it (or upgrades it when the bundled one changed), switches every desktop to it over D-Bus, and shows a notification ("Installed the zmural plugin for KDE Plasma"). zmural also owns `org.zmural.Daemon` and emits `Ready`, so the plugin reconnects at once when zmural (re)starts (`os/dbus.zig`, a small D-Bus client). Tested on plasmashell 6.7 (virtual KWin) from a clean install: popup, then zmural's video on the desktop under the Plasma panel; a second start neither reinstalls nor notifies.
- [x] **GNOME (2026-09-28):** zmural's GNOME Shell extension is waywallen-display's (renamed UUID `org.zmural.gnome@zmural`, settings schema, translation domain and renderer app ID, so it can't fight an installed waywallen extension over windows), built with `zig build gnome-extension`. In a GNOME session zmural installs it, enables it and notifies; GNOME starts new extensions at login, so the notification says "log out and back in" unless it's already running. Tested on real GNOME Shell 50, headless, with a mocked logind (`tools/gnome-test/run.sh`): session 1 installs and notifies; after the re-login the test pattern and the VP9 clip are the desktop background (the extension's renderer imports on the RX 9070 XT, and zmural's renderer follows it there); a second start doesn't notify; when zmural exits the extension falls back to GNOME's own wallpaper.
- [x] **Desktops that need a plugin or extension (owner's request, 2026-09-28; done the same day):** zmural ships them itself, so a user never hunts for them. On start the daemon detects the desktop (`hosts/linux/backend.zig`) and installs its bundled KDE Plasma plugin or GNOME Shell extension at user level (`kpackagetool6` / `gnome-extensions install`), upgrades it when the bundled one changed, and says so in a notification ("log out and back in to finish" on GNOME). What is still missing is the still-image fallback for the time before the plugin is active and for desktops with neither; it is part of the backend-selection item above.

**Done when:** on Hyprland or Sway, a video wallpaper plays with zero copies (checked with a frame-path log), pauses for fullscreen apps and GameMode, and survives the daemon restarting.

That much holds on headless Sway. It is not yet "the same experience" or a v0.2: the items open above stand, zmural doesn't start the layer-shell host, and there is no way to install zmural on Linux short of building it (the package is an M8 item).

**Tested so far (2026-09-28, headless Sway 1.11 on the AMD iGPU, gles2 renderer):**
- The test pattern animates and a VP9 clip plays upright (compared against ffmpeg's frame) through renderer → daemon → host → compositor, in a tiled modifier (`0x200000000401b03`), with no copy.
- No fd growth over time in any process.
- Killing zmural: the renderer exits with it, the host keeps the background and reconnects; a new zmural shows the new wallpaper.
- `swaymsg fullscreen enable` pauses the renderer (0 CPU); disabling it resumes after `resume_after_ms`.
- On a real session (the owner's Plasma 6.7 desktop, one 1440p monitor, 2026-09-30, `notes/host-test-2026-09-30.md`): video under the panel through the KDE plugin, the tray, the CLI, the settings window, rotation and the GameMode rule worked; three bugs were found and fixed the same day, and the fixes were confirmed on the same desktop that evening with `main` e0815f5 (the note's "Evening redeploy" section, which also lists the full pass and six small findings).
- Two outputs: tested on headless Sway since 2026-09-30 (`tools/monitors-test.sh`).
- Not yet tested on Hyprland, or on a real wlroots or GNOME session.

**Desktop matrix (2026-09-28, `tools/linux-matrix.sh`, all in the dev container):**

| Desktop | Result | Notes |
|---|---|---|
| Sway 1.11 | ✅ shows | headless |
| labwc 0.9 | ✅ shows | headless |
| Wayfire 0.10 | ✅ shows | headless; no foreign-toplevel, so no window-state pausing yet (needs its IPC) |
| Niri 26.04 | ✅ shows | nested in sway; needed the wl_shm background fallback (no single-pixel buffers) |
| COSMIC (cosmic-comp 1.8) | ✅ shows | nested in sway; no foreign-toplevel (needs the COSMIC protocols) |
| KWin 6.7, bare | ✅ shows | virtual backend |
| KDE Plasma 6.7 | ⛔ covered | through the layer-shell host, Plasma's own wallpaper sits on top. Shown through zmural's Plasma plugin instead (done the same day, see the KDE Plasma item above) |
| GNOME (Mutter 50) | ⛔ unsupported | no layer-shell; the host says so and exits. Shown through zmural's GNOME extension instead (done the same day, see the GNOME item above) |
| River 0.4 | ❓ inconclusive | closes layer surfaces unless the window manager handles them; untested with a real River window manager |
| Hyprland | ❓ untested | not packaged for Fedora 44 (its COPR only builds Rawhide) |
| X11 (Xvfb + Openbox / xfwm4) | ⬜ rig works | no X11 host yet |

## M7: Wallpapers that do more 🔶

M7 started while M6 was on hold, Windows side first.

- [x] **`zmural-web` on Windows (2026-09-27):** WebView2 in each surface window (`src/sdk/web_renderer.zig`).
  - **What it shows:** a local `.html` page, served from its own folder as `https://<folder hash>.zmural.example/`. It also took an `http(s)://` address until 2026-09-30 (see "always offline" below).
  - **Pausing:** the view is hidden, then `TrySuspend` freezes it.
  - **Sound:** mute follows the setting. WebView2 has no per-page volume.
  - **Hardening:** no dev tools, context menu, dialogs, new windows, downloads or permission prompts.
  - **Bindings:** generated from the SDK's `WebView2.h` by `tools/gen_webview2.py` (`src/os/webview2.zig`). `WebView2Loader.dll` (BSD-3-Clause) is loaded at runtime from `third_party/webview2`.
  - **Daemon:** `.html`/`.htm` join the library.
  - **Job:** web renderers get their own job, kill-on-close with **no UI limits**. Any UI limit made Chromium's sandboxed page process exit at once (each limit tested alone); pages are sandboxed by Chromium instead.
  - **Verified live:**
    - A local animated page with an image from its folder renders at 2560×1440.
    - Pausing: about 0.5 CPU s per 3 s while playing, 0.00 while paused, and the frame counter only advances while playing.
    - `https://example.com` renders; quitting leaves no browser processes behind.
- [x] Each local page's folder is its own origin (`<hash>.zmural.example`), so wallpapers can't read each other's storage.
- [x] Web security (2026-09-27): local pages offline unless their package says `network = true`, a browser profile per wallpaper, local pages locked to their origin. Verified live: with the default, `fetch` and a WebSocket to the internet fail and a navigation away is cancelled; with `network = true` both connect.
- [x] **Web wallpapers are always offline, and a web address is not a wallpaper (2026-09-30; owner's decision, security first).** `zmural-console apply https://...` is refused on both OSes with the reason, as is one written into `settings.toml`. The web renderer refuses an address too, runs every page behind the dead proxy with no switch to turn it off, and won't show a page if it can't lock it to its own origin. `network = true` in a package still parses, so older packages load, and is ignored with a line in the log; the renderer protocol (now v4) no longer carries a network flag. This removes what the 2026-09-27 items above describe for addresses and `network = true`.
  - **Proven:** unit tests on both OSes; `tools/instance-test.sh` on Linux and CI's boot test on Windows apply a web address and see the refusal, its reason, and the wallpaper unchanged (both fail on the code before).
  - **Not proven:** nobody has watched a real page fail to reach the network since the change. The offline mode itself is unchanged from 2026-09-27, when that was checked by hand; CI has no WebView2 loader.
- [x] **Packages and properties (2026-09-27):** a folder with `zmural.toml` (`src/core/manifest.zig`, now on `core/toml.zig`, with dropdown `options` and `network`) is one library entry.
  - **Linux (2026-10-02):** a video or picture package shows the file it names, as the type it declares, with its own properties (any of `sdk/mpv_options.zig`'s names reach mpv; values kept per package as everywhere). `adjust.loadPackage` reads it (shared; Windows still has its own copy in `runtime_windows.zig`). A broken package (bad manifest, missing file, a type that doesn't match its file) is refused before anything changes, with the reason in the log; a package can only be the main wallpaper, as on Windows. The window and both trays call a package by its folder's name instead of "zmural.toml" (`media.displayName`), and on Linux its tile's thumbnail is made from the file it names (Windows: not yet). `tools/packages-test.sh` (10 checks, colours off screenshots; 8 fail on the code before): picture and video packages, a property darkening the picture, the refusals, a restart, and an imported package applied straight away. Web packages wait for web wallpapers on Linux.
  - **Checks:** the entry must stay inside the folder, and property names are identifiers.
  - **Values** (`src/core/properties.zig`): checked against the manifest and saved per wallpaper in `<config>/properties/<id>.toml`, only where they differ from the default.
  - **Control requests:** `get_properties`, `set_property` and `reset_properties`, with `zmural-console props` / `zmural-console prop <name> <value>` / `zmural-console prop --reset` in the CLI.
  - **Renderer protocol v2:** `set_property` (a JSON literal) and `Init.network`.
  - **Pages:** a local page gets `window.zmural.properties` and `window.zmural.on("property", fn)`. Remote sites get nothing.
  - **Verified live:**
    - the five property kinds listed;
    - four changes arriving as four events, and the page recolouring;
    - out-of-range, badly formed and unknown values refused;
    - values surviving a restart, and reset.
- [x] **Settings window: the Customise section (2026-09-30).** The Playback page lists the main wallpaper's properties under "Customise <name>": a slider per number (live while dragged), a switch per checkbox, a segmented control for a dropdown of up to four choices, and Reset. Colours, text and longer dropdowns are shown but still changed with `zmural-console prop`. Tried on the Sway rig with scripted clicks: the brightness slider took a plain red picture to near black on the other output, and Reset brought it back. Seen on Windows 2026-10-01: drawn right, and an arrow-key slider change reached the renderer (`notes/windows-check-2026-10-01.md`).
- [x] **Video and picture adjustments (2026-09-30)**, `daemon/adjust.zig`, both OSes. A plain video has speed, brightness, contrast, saturation, gamma and hue; a plain picture has brightness, contrast and gamma (mpv applies saturation and hue only to video colours: on a PNG they did nothing, seen on screen). They are the wallpaper's properties, through the requests packages already used (`zmural-console props`, `zmural-console prop <name> <value>`, `prop --reset`), kept per wallpaper in `<config>/properties/`. Renderers set only the names on `sdk/mpv_options.zig`'s list on mpv, as numbers, so a wallpaper's property can't reach mpv's scripting or file options. With this the Linux daemon answers every control request.
  - **Proven on Linux** by `tools/props-test.sh` (15 checks, read off screenshots): brightness, contrast and gamma on a picture; saturation, brightness and speed on a video; values kept per wallpaper and across a restart; a monitor showing its own wallpaper untouched; bad values refused.
  - **Windows:** the same daemon logic (CI lists, sets and refuses a picture's adjustments on the Windows runner, which has no libmpv to show it); the renderer side is compiled only.
  - [ ] Only the main wallpaper has properties; a monitor's own wallpaper doesn't yet (the "Properties per monitor" item below).
- [ ] Web wallpaper follow-ups:
  - a frozen last frame while paused (today it's black while hidden);
  - an fps cap (pages run at the monitor's refresh rate);
  - an Explorer-restart test (Windows).
- [ ] Web wallpapers on Linux (the `--renderer web` mode is a stub there): WebKitGTK, always offline and with the same hardening as the Windows one, and only with WebKit's own sandbox on (owner's decision, 2026-09-30)
- [ ] Properties per monitor: a monitor showing its own wallpaper has none yet, and the same wallpaper on two monitors shares one set of values
- [ ] JS API, beyond properties (done on Windows, above): audio spectrum (WASAPI loopback / PipeWire + FFT, 128 bins), now-playing, system stats, pause events
- [ ] Lively compatibility: import `LivelyInfo.json` packages, plus a JS shim for Lively web wallpapers
  - [x] **Import (2026-10-02), both OSes** (`core/lively.zig`, from Lively's own source at 25a0a5f: `LivelyInfoModel.cs`, `WallpaperType.cs`, `schemas/livelyPropertiesSchema.json`). A zip with `LivelyInfo.json` (and no `zmural.toml`) gets a `zmural.toml` written as it is unpacked, before it is checked and moved into place: title, author, licence, type (video; gif and picture as image; web, webaudio with `audio = true`), entry (backslashes as slashes, checked to stay inside). `Type` is read as Newtonsoft writes it (a number) or as a name. Of the controls, slider, checkbox, color, textbox and dropdown (index → its item) convert; button, label and folderDropdown have no counterpart and are named to the user. Lively's own files have comments and trailing commas (Newtonsoft takes them), so those are dropped first. Refused with the reason: programs (app, unity, godot, bizhawk, unityaudio), web addresses (url), streams (videostream), a file outside the package (`IsAbsolutePath`, `..`). Checked on 11 of the Lively author's own wallpapers (clouds, audiorbits, lively-audio-visualizer, depthmap-wallpaper and the 7 in audio-visualizer-wallpaper): all import, every control converted or named (none lost silently). `tools/packages-test.sh`: a Lively video package imports, plays, and its slider named `brightness` darkens it as Lively's would; `tools/import-test.sh`: a Lively program package is refused.
  - [ ] The JS shim: a Lively page listens with `livelyPropertyListener(name, value)` (dropdowns as an index), so imported Lively web wallpapers show their defaults but don't hear changes yet. Windows renderer; needs Windows to test.
- [ ] `.zip` wallpaper package import/export. **Owner, 2026-10-02:** what a downloaded package contains is the user's call, as with any file they download. zmural's part is to unpack it safely (no entry may land outside the new wallpaper's folder, no links, size limits) and to apply its usual rules to what is inside: pages offline, no programs as wallpapers.
  - [x] **Import (2026-10-02), both OSes:** `zmural-console import <file.zip> [--to <folder>] [--apply]` (`core/package_zip.zig`, `cli/import.zig`), run in the console's process so a bad zip can't take zmural down. Before writing anything it reads the zip's directory and refuses absolute paths, drives, `..`, streams (`a:b`), Windows device names, trailing dots and spaces, control bytes, names equal but for case, links, encryption, compression other than stored/deflate, more than 10 000 files or 8 GiB, a Lively package (not yet) and a zip with nothing playable at its top. It unpacks into a hidden folder beside the target, checks every file's CRC (`std.zip` doesn't) and a package's manifest and entry, then renames it into place (`name (2)` when taken), dropping a single top folder; zmural rescans. 8 unit tests with zips written in memory, each check mutation-tested (7 of 7 caught); `tools/import-test.sh` (18 checks) imports `zip`-made deflated zips on Sway (listed, shown) and refuses seven hostile or wrong ones made with Python's zipfile, with nothing written anywhere. Windows: compiled, not run.
  - [x] **Export (2026-10-02), both OSes:** `zmural-console export <wallpaper, package or folder> [<file.zip>]` (`package_zip.exportTo`). A package or folder goes in as one top folder named like it, a single file on its own; files are stored (videos and pictures are compressed already) and streamed from disk, CRC taken in a first pass. Every name must pass import's own checks (so an export always imports), links are refused, an existing zip is never overwritten, and it writes `<file>.part` and renames when complete. Classic zip only: under 4 GiB in all (zip64 not written yet). Checked by a unit round trip and in `tools/import-test.sh` (23 checks now): Info-ZIP's `unzip -t` passes our zips, a folder comes back byte for byte, and a 300 MB file round-trips.
  - [x] **The settings window (2026-10-02), both OSes:** Open file also takes a `.zip` (its filter says so). The window runs `zmural-console import <zip> --apply --report <file>` as a process of its own, so a bad zip can't take zmural (and the window inside it) down, polls for it to end, and shows its one-line report as a toast ("imported Sunsets", or "escape.zip wasn't imported: <why>"), then reloads the list. Proven on Sway by `tools/import-test.sh` with `ZMURAL_TEST_PICK` answering the picker (the desktop's own file dialog can't be driven in this container: GTK's portal dies in its image loader's sandbox). Windows: compiled only.
- [ ] Mouse input forwarding to interactive wallpapers (web wallpapers: nothing else takes input)

## M8: Polish 🔶

- [x] Timed rotation and play order, on both OSes (`daemon/rotation.zig`, 2026-09-29): change every N minutes of *playing* time (the clock waits while paused or stopped); order by name, shuffle (every wallpaper once per round) or random. In the settings window (Playback), the tray (Shuffle check item), the CLI (`zmural-console rotate <min>|off`, `order`, `shuffle on|off`) and `settings.toml` `[rotation]`. Tested live on headless Sway (Linux); on Windows (2026-10-01) the clock waited under the fullscreen rule and a 1-minute change happened while playing
- [x] **A different wallpaper per monitor (2026-09-30)**, `daemon/monitors.zig`, shared by both runtimes. There is one main wallpaper; `zmural-console apply <file> --monitor <number, name or ID>` gives a monitor its own, `zmural-console follow --monitor ...` takes it back, `zmural-console apply <file>` puts one on every monitor again, and `next`/`previous --monitor` step one monitor. `zmural-console status` lists the monitors. `settings.toml` keeps them under `[monitors]`, by monitor ID, so an unplugged monitor shows the same thing when it returns. Monitors showing the same file still share one renderer. Timed rotation and the tray change the main wallpaper only.
  - **Proven on Linux** by `tools/monitors-test.sh`: a headless Sway with two outputs, each screenshotted and its colour read after every step (15 checks; 6 fail when routing ignores a monitor's own wallpaper).
  - **Windows:** the same logic, compiled and unit-tested there, and CI's boot test gives the runner's one monitor its own wallpaper, checks the file and `status`, and takes it back. Nobody has seen two real monitors show two wallpapers on Windows.
  - [x] Choosing the monitor in the settings window (2026-09-30): with more than one monitor, a wallpaper's right-click menu offers "Show on every monitor" and "Show on monitor N (name)" for each. Tried on the two-output Sway rig with scripted clicks: the menu listed both outputs, the second output turned green, and "every monitor" put blue on both. On Windows the menu is the native popup with the same lines; unseen.
  - [ ] A view of what each monitor shows, in the window (today only `zmural-console status` says).
  - [ ] Windows: a wallpaper package can only be the main wallpaper (a monitor's own must be a plain file).
  - [ ] Pausing one monitor (`pause --monitor` is refused).
- [x] **Fill mode per monitor (2026-09-30):** `zmural-console fill fit --monitor M` gives one monitor its own fill mode, `zmural-console fill default --monitor M` takes it back, and `zmural-console fill <mode>` sets the main one; `settings.toml` keeps them under `[monitor_fill]`. Monitors share a renderer only when wallpaper and fill mode both match (the router's `variant`). `tools/monitors-test.sh` checks it on the screen: a 16:9 picture on a 4:3 output has bars with "fit" and none with "crop", while the other output is unchanged. Windows: same logic; CI's boot test sets and clears it; unseen. Not in the settings window (its Fill control is the main mode).
- [ ] Rotation per monitor, once wallpapers are per monitor
- [ ] Span one wallpaper across monitors. (Duplicate is what happens already: the same wallpaper everywhere, from one renderer.) What it needs, found 2026-09-30:
  - **Where the monitors are.** Windows knows each monitor's rectangle. The Linux daemon doesn't: a display registers with a name and a size only, and the waywallen-display protocol has no position (waywallen makes the user draw the layout). Either zmural reads the outputs' positions from the compositor itself (`os/wayland.zig`, xdg-output: works on every desktop), or the layout is a setting.
  - **One picture, several buffers.** Linux: the renderer draws the whole canvas once and copies each monitor's part into that monitor's buffers (or one shared pool is published to every display with its own source rectangle, which needs the release of a slot to wait for every display). Windows: one surface covering the union rectangle under the desktop layer.
  - A setting (`[playback] arrangement`), the command line and the Playback page.
- [ ] Transitions (fade/wipe) and blur-while-paused
- [x] KDE Plasma 6 wallpaper plugin: done in M6 by vendoring waywallen-display's plugin (and its GNOME extension) instead of writing one
- [x] GUI: no toolkit; one immediate-mode UI shared by both OSes (Direct2D on Windows, Cairo + Pango on Linux), see M6
- [ ] Screensaver mode (Windows: a `.scr` shim; Linux: not designed)
- [ ] **Updates and distribution** (surveyed 2026-09-30 against waywallen and Lively: neither self-updates the app; waywallen rides Flathub / Nix / a re-downloaded AppImage and only its *plugins* have an updater, sha256 from the plugin's own manifest, unsigned; Lively is Store-updated or polls GitHub Releases through Octokit and runs the new installer, also unsigned. zmural today: a zip on Windows, no Linux install path, no check, no signing — README security item 6, S8):
  - [x] **Linux tarball (2026-09-30), the counterpart of the Windows zip.** `zig build package -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.36` builds `zig-out/package/zmural-<version>-linux-x86_64.tar.gz`: `bin/zmural`, `bin/zmural-console` (static, no libc), the KDE plugin and GNOME extension zips in `share/zmural`, the licence and `README.txt` (install, libraries per distro, uninstall). Extract anywhere and run; zmural sets up its app-menu entry, autostart and plugin from wherever it was extracted. The libraries it loads are the system's (libmpv is not bundled: on Linux it would drag in FFmpeg). `tools/package-test.sh` checks the tarball extracted into an empty home on headless Sway (picture on screen, console, settings window, autostart and launcher paths, clean quit, glibc ≤ 2.36); `tools/package-debian-test.sh` runs it inside a Debian 12 root with Debian's own libmpv 0.35, Mesa 22.3, Cairo and Pango: picture, console and settings window all work. Not solved by a tarball: updates, H.264 on Fedora, and the KDE plugin, which was built against Qt 6.11 and so needs Qt 6.11 or newer. **Since 2026-10-05** the plugin and extension are built inside a Debian 13 root (`-Dplugin-root`, `tools/plugin-root.sh`), so the plugin needs Qt 6.8 (measured on the built `.so`) and loads on every Plasma 6 distro; checked against Debian 13's own libraries and on headless Plasma with Qt 6.11.
  - [x] **Released builds are stripped (2026-09-30), their debugging info kept aside.** `zig build package` on both OSes leaves the download without debugging info or build-folder paths, and puts it in `zig-out/package/debug/<package>/` (Windows `.pdb`; Linux `.debug`, matched by build ID). The Linux tarball went from 3.7 to 1.4 MB (`zmural` 8.7 to 2.5 MB, `zmural-console` 4.0 to 0.7 MB). How the two kinds of build differ, and how to read a crash with the kept info: [RELEASING.md](RELEASING.md). `tools/package-test.sh` checks the stripping and the build IDs; the Windows side is compiled, not yet packaged on Windows.
    - [x] **The Windows release zip is built and run in CI (2026-09-30).** CI fetches the exact libmpv and WebView2 loader `THIRD_PARTY_NOTICES.md` names, refusing any whose hash differs, builds the zip, checks what is in it (and that the `.pdb` files are kept beside it, not in it), unzips it into an empty folder and runs zmural from there: a picture through libmpv, `zmural-console`, the settings window, a clean quit.
- [x] **Crashes into the log file (2026-09-30)**, `os/crashlog.zig`. A panic or a fault in any part of zmural (itself, a renderer, the display host, the watchdog) appends a `CRASH:` line (version, which part, pid, what happened) and its return addresses to `zmural.log`, then reports on stderr as before. `tools/crash-test.sh` crashes each on purpose (`ZMURAL_TEST_CRASH`) on Linux: zmural's own panic and a fault, a renderer's panic while zmural carries on, and a released build whose first address the kept debug file turns into the crashing function. Windows: CI's zip test crashes it on purpose and finds the report in `zmural.log` (2026-09-30). **Windows, 2026-10-01:** crash lines, codes and the `crash-code` file checked from a stripped release (zmural and a renderer, panic and bad pointer), and `zig build crashcode` decodes Windows codes itself through dbghelp.dll (cf61d47). The tray notice is sent and accepted, but with Do Not Disturb on Windows drops tray balloons entirely, so it went unseen (see the open items below).
  - [x] **An uninstaller (2026-09-30)**, `daemon/uninstall.zig`, on both OSes: `zmural-console uninstall` asks first (nothing happens on no), and the settings window's General page has an Uninstall button with its own question (No focused). It stops zmural, which gives the desktop its own wallpaper back, then removes what zmural added: start at login; on Linux the app-menu entry and icons, the KDE Plasma plugin (Plasma's desktops switched back to its picture wallpaper first) and the GNOME Shell extension; its settings, log and state (on Windows also the web wallpapers' browser profiles); its sockets. It never touches the user's wallpapers or their folders, and names zmural's own program folder for the user to delete. `tools/uninstall-test.sh` checks both ways in on headless Sway, file by file, including that the wallpapers stay. Windows: CI's zip test runs `zmural-console uninstall --yes` and checks the settings and log are gone and the wallpaper and the program aren't (2026-09-30); the button is unseen there. No real installer: unzipping is enough, as the owner decided. **Windows, 2026-10-01:** it raced zmural's shutdown (FileBusy on the open log); it now waits for the process to exit (bdd94d0), tried 4 times including from the unzipped release.
  - [ ] Linux: no updater of our own. Ship through channels that already update: a Flatpak (layer-shell is restricted inside Flatpak, as waywallen found; the KDE/GNOME plugin paths work) and a Fedora COPR RPM, so the distro's updater handles it. The Flatpak also solves GPU decoding of H.264/H.265 on Fedora and openSUSE, whose Mesa and FFmpeg leave those out: the Flathub runtime brings its own Mesa with them (`GL.default//25.08-extra`) and `codecs-extra`, installed automatically (checked 2026-09-30, `notes/linux-video-codecs.md`). An RPM can't, so it needs the RPM Fusion hint. A README "Install (Linux)" section that names them
  - [ ] Windows: a GitHub Releases check like Lively's, but the download is verified against an Ed25519/minisign public key baked into the binary before anything runs — the gap both peers leave open. Off by default until the first signed release exists; a "check for updates" row in Settings → General
  - [ ] Keep the plugin self-upgrade zmural already has (it re-installs the bundled KDE zip when its hash changes; verified on the owner's desktop 2026-09-30) as the one in-app update path, and extend it to the GNOME extension
- [ ] Renderer sandbox, so a decoder exploit can't read the user's files (audit #2, F13). Windows: a restricted token or AppContainer. Linux: not designed (seccomp and Landlock are the candidates)
- [x] **Windows: zmural lists itself as an app (2026-10-01, b9f7b34)**, `os/apps_windows.zig`: a Start menu shortcut (`zmural.exe --settings`) and an HKCU Uninstall entry (Settings > Apps, with Uninstall), written at start, rewritten when the folder or version changes, skipped under `$ZMURAL_CONFIG_DIR`, removed by the uninstaller. Tried on the installed release, and uninstalled with its UninstallString then reinstalled fresh (2026-10-01).
- [x] **Settings window: a Rescan button beside Open file (2026-10-01, 40e2f0a).** The list reloads for a few polls after it; Rescan, then Open file, drop their labels in a narrow window. Tried on Windows; drawn on Linux (Sway rig, 2026-10-02), where `tools/settings-test.sh` and `tools/keyboard-test.sh` still pass with it.
- [ ] **From the Windows test of 2026-10-01** (`notes/windows-check-2026-10-01.md`):
  - [x] A crash notice nobody saw is lost: the code is taken as soon as the balloon is sent, and with Do Not Disturb on Windows drops it. **2026-10-02, both OSes:** the latest line to report stays in `status` (`crash     : ...`) for the rest of the run, and the settings window shows it at the top of General's Troubleshooting. Seen on Sway; Windows compiled only.
  - [x] A renderer crashing in a loop sends a notice per crash (every 8 to 10 s) until zmural gives up; one per run is enough. **2026-10-02, both OSes:** one notice per run; later crashes are logged (`another crash this run (not told again)`) and update the line in `status`. `tools/crash-test.sh` checks both (3 crashes, 1 notice; fails with the guard removed). Windows compiled only.
  - [ ] The settings window now runs inside zmural, and Zig's crash handler treats any first-chance access violation as fatal: a shell extension loaded by the file picker or thumbnails that raises and catches its own would take zmural down. Consider `enable_segfault_handler = false` plus an unhandled-exception filter for the crash log.
  - [ ] Minor: a right-click after keyboard use opens the menu at the focused tile; ~~thumbnails queued when the window closes are leaked~~ (fixed 2026-10-10: the worker keeps finished thumbnails itself and frees what the window never took; it was the window test's rare 99-allocation leak); a second `zmural --settings` may only flash the taskbar (no `AllowSetForegroundWindow`); `raise()` calls ShowWindow across threads (ShowWindowAsync avoids a stall).
  - [x] Explorer restart: the wallpaper re-attached, but the tray icon stayed gone (TaskbarCreated was ignored once the desktop re-attach had seen the new Explorer). Fixed: the icon is always restored on TaskbarCreated; the owner saw it back.
  - [x] A wallpaper switch showed the desktop's own wallpaper for ~1 s (the old renderer stopped first; the new window is see-through until mpv draws). Fixed in 90e9000: the old one stays above the new until the new one sends `shown`, at most 4 s.
    - **Linux has no such gap, so `shown` stays Windows-only (checked 2026-10-02):** both display hosts keep the last frame after an unbind until the next pool's first frame. Sampled around switches between a picture and a 4K video: layer-shell on Sway (grim) and the Plasma plugin on headless KWin (KWin's ScreenShot2, a sample every ~6 ms) went straight from old to new. With 600 ms added on purpose between the unbind and the new renderer, the switch took 600 ms longer and still never showed black or the desktop.
  - [ ] Web wallpapers: send `shown` once the page has painted, so a switch to one doesn't wait the full 4 s.
  - [ ] `status` shows a monitor's own fill mode but not the main one.
  - [ ] Test-only: with `$ZMURAL_CONFIG_DIR`'s parent missing, zmural runs without a log (it is opened before the folder is made).

## M9: Later ⬜

- [x] GNOME Shell extension: done in M6 by vendoring waywallen-display's (expect upkeep with every Shell release)
- ~~Online wallpaper gallery~~ **Dropped (owner, 2026-10-02):** zmural is not a service, and a gallery is one someone has to host and run (Lively runs its own server with logins; Wallpaper Engine has Steam's Workshop; waywallen pulls from Wallhaven). Wallpapers come from wherever the user gets them, as files or `.zip` packages.
