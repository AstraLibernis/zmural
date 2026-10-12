# Welcome page: 2026-10-06

**Read this first.** The owner asked for a welcome page that explains how to use zmural and
lets the user quickly pick a wallpaper (or see where to put them). It answers host-test
finding 2 (`notes/host-test-2026-10-05.md`: first run left an empty desktop and nothing said
to pick a wallpaper) on the "nothing says what to do" half. The other half is not done:
on Plasma the first run still switches the desktop to zmural's plugin before anything is
picked, so the desktop behind the window stays black until a click. How the others handle
it (read in their source, 2026-10-06): Lively draws over the untouched Windows picture, so
nothing changes until a wallpaper runs; Hidamari saves the GNOME picture and puts it back
when it quits; Smart Video Wallpaper Reborn shows "No video source" on the desktop itself.

## What it does

- A Welcome page, first in the sidebar (`settings/app.zig`, `pageWelcome`). It has:
  - an intro paragraph (word-wrapped by `paragraph`)
  - up to four wallpapers as tiles (`wallpaperTile`, shared with the Wallpapers page)
  - the standard folders with Open (`platform.openFolder`, which makes the folder first), plus
    Add folder and Open file
  - what can be a wallpaper (the extension lists come from `core/media.zig` at comptime)
  - three pointers to Pausing, Playback and General
- The window opens on Welcome when nothing is showing, neither the main wallpaper nor any
  monitor's own. Otherwise it opens on Wallpapers, as before.
- First run: `Store.fresh` (no settings.toml) with no `--apply` opens the window by itself,
  on both OSes (`daemon/main.zig`, `firstRun`). It is off under `$ZMURAL_CONFIG_DIR`: every
  rig uses a fresh folder and would otherwise get a window. The settings file is written on
  the first change, so until the user picks something, every start counts as a first run.
- On Welcome with an empty library, the window asks for a rescan every 3 s, so files dropped
  into a folder show up by themselves. It only does this while the library is empty, because
  a rescan restarts a shuffle round.

## Verified

- `zig build test`: 206/213 (7 skipped), as before. The `fresh` assertions fail with the
  flag never set (mutation-checked).
- `tools/settings-test.sh`: 18/18 with the new step 8. The window opens by itself on first
  run, on Welcome; a picture dropped into Videos/Wallpapers appears; a click on its tile shows
  it; the next start opens no window. Each of three mutations (no first run, no auto-rescan,
  never Welcome) fails the step.
- `tools/keyboard-test.sh`: 12/12. Its Home/Down counts now step past Welcome.
- Screenshots on Sway in light, dark, and the minimum size (780x560 output). Descriptions were
  shortened until nothing is cut off at the minimum width; long folder paths still end in "…".
- Windows: cross-build OK; unit tests under Wine: see the commit. The page itself and
  `openFolder` (ShellExecute "open" on a folder) are unseen on Windows.

## Not done

- ~~Plasma first run: the desktop stays black until a wallpaper is picked.~~ Fixed later
  the same day by Prism (below): something shows from the first start.
- ~~Applying a file that can't be played still replaces the previous wallpaper (host-test
  3).~~ Fixed later the same day (the last section).

# Later: Prism, the wallpaper zmural ships with

The owner wanted zmural to come with one wallpaper, so a first run never shows an empty
desktop. I made three candidates (Prism, Aurora, Orbits), each a seamless 12 s loop drawn
from code, and the owner picked **Prism**.

- `tools/wallgen.zig` draws it. `zig build starter-wallpaper` pipes it through ffmpeg
  (libvpx-vp9, crf 20) into `assets/wallpapers/Prism.webm`, which is committed (646 KB), so
  normal builds need neither the generator run nor ffmpeg. The Zig version was checked
  against the numpy original it was ported from: at t = 1/3 no pixel is more than 1/255
  apart. The numpy script is not kept (the owner's rule: Zig, with Python only as the check).
- Installed to `share/zmural/wallpapers/` beside `bin` (Linux) or `wallpapers\` beside the
  programs (Windows), in normal builds and in both packages. `daemon/starter.zig` finds it
  (it opens the file instead of calling `access`, because of Wine).
- With no wallpaper set and none asked for, `main.zig` (`useStarter`) fills Prism in as the
  wallpaper. The next save writes it like any wallpaper, so a saved Prism whose install has
  moved (`starter.isStale`: named Prism.webm, in a `wallpapers` folder, gone) is replaced by
  the current one, not left black. The window still opens on Welcome on a first run
  (`Env.welcome`, cleared after the first opening).
- The library lists it after the user's files (`Library.scanLast`), so Welcome's tiles show
  the user's own first. Welcome now rescans every 3 s while it is open (the library is never
  empty any more).
- Windows: the standard folders come from `SHGetKnownFolderPath` (Videos, Pictures), so a
  folder moved to OneDrive is followed; `%USERPROFILE%` is only the fallback.
- This also fixes host-test finding 2 on Plasma: something shows on the very first start.

# Later still: a wallpaper that can't be played

The owner asked for a broken file to show an error and go back to the last wallpaper that
played, or to Prism if nothing ever had (host-test finding 3).

- `daemon/fallback.zig` remembers the last main wallpaper that reached the screen. On Linux
  that is the first `frame_ready` for it; on Windows it is `shown`. A renderer's
  `cannot play` / `cannot show` failure is queued there and handled on the runtime's next
  tick, not inside the renderer's own message handler, because switching wallpaper stops
  that renderer.
- On the tick:
  - Monitors that had the file as their own follow the main wallpaper again.
  - If it was the main wallpaper, `instead` picks the last one that played, else Prism,
    never the broken file. If that is gone too, it falls to Prism. If Prism itself fails
    (for example, no VP9 decoder), nothing changes but the notice, so it never loops.
  - A notification ("zmural can't show <file>": what the renderer said, then "Showing X
    again" or "That monitor shows the main wallpaper again") replaces the old one-line
    "Pick another wallpaper" notice.
- The broken file is saved for a moment (apply saves at once), then replaced by the
  fallback's save. If zmural died in that second, the next start would fail on it and fall
  to Prism.
- Rotation that lands on a broken file goes back too. The next timed change then steps on
  from the restored wallpaper, so it can land on the broken one again (one notice each time).
  Skipping known-broken files in rotation is not done.
- `tools/broken-test.sh` (9 checks), mutation-checked three ways. The `instead` guard got
  its own assertion after a mutant survived (`failed` already drops a broken last-good, so
  the guard was masked).

# End of the day

- Commits:
  - 13ab45c: Welcome page and the first-run window
  - dcdcc66: Prism, Windows known folders, rig fixes
  - 9cf222d: fallback for files that can't be played
  - plus this docs commit
- CI: 13ab45c, dcdcc66 and 9cf222d all green on both OSes (the last of them finished
  after this note was first written).
- **CI is on hold (owner, 2026-10-06):** no `[full ci]` and no manual runs until the owner
  says so. Test with the rigs and Wine. Batch the Windows-touching work for one run later.
  The next run should cover what nobody has seen on Windows yet: the Welcome page, Prism in
  the zip, the OneDrive/known-folder path, and the fallback.
- Every Linux rig passes (19 including the new `broken-test.sh`, plus KDE 18; GNOME
  screenshots as before). Wine 199/216, the known `access` quirk.
- This container's overlay needed `zip` (packages/import rigs), `xorg-x11-server-Xvfb`
  (Wine tests) and `tools/sandbox-deps.sh plugins` (the GNOME rig builds its extension on
  the host). All are gone after a restart.
- Open from today:
  - Rotation can land on a known-broken file again (one notice each round); skipping files
    that already failed this run would fix it.
  - Quit still leaves Plasma black (owner's earlier decision).
  - None of today's work has been seen on a real Windows desktop.

# Evening: research, then M6's open items (owner: drop GNOME's app rule)

The owner asked whether other Linux live-wallpaper projects cover M6's open items. They were
checked in source, not READMEs: waywallen and waywallen-display, linux-wallpaperengine,
mpvpaper, gSlapper, swww, Hidamari, Komorebi, Wallpaper Engine for KDE, Smart Video
Wallpaper Reborn, Hanabi and Gnome Live Wallpaper.

Findings:
- Only waywallen reads Hyprland's and Wayfire's IPC. Nobody has a GNOME app rule or
  window coverage on GNOME.
- Hidamari sets a video frame as GNOME's background (it saves the original first).
- Only waywallen does multi-plane and cross-GPU buffers; nobody else shares frames by
  DMA-BUF at all.
- waywallen-display v0.4.1 added GNOME 51 today; Hanabi and Gnome Live Wallpaper haven't.

Owner's decisions:
- Drop the GNOME app rule and coverage.
- Do the rest.
- On the GPU: no deep tuning of compressed layouts. Instead, detect a cheaper GPU (the
  CPU's integrated graphics) on hybrid machines and use it instead of the main GPU. My
  reading, stated to the owner and not yet confirmed: draw the wallpaper there, keeping
  the main GPU free; frames crossing GPUs take the plain linear path; measured before it
  becomes the default.

Done:
1. **waywallen-display v0.4.1 (GNOME 51)**, its own commit. It exposed a build bug: the
   plugin builds copied `zmural-*.zip`, and the old version's zip matched too.
2. **The still picture on KDE and GNOME, and of videos.**
   - `desktop.setUp` now returns `{short, still}`.
   - A video's frame comes from `zmural --still-frame` (`still_frame.zig`, libmpv
     `vo=image`), run as a child and polled with `wait4` on the tick.
   - The GNOME background is kept in the state dir (`gnome-background`) and restored by
     uninstall, which also removes `~/.cache/zmural`.
   - A user who turned the extension off in the Extensions app gets nothing: their call.
   - Not done: Plasma's previous picture isn't restored (it can't be read back); a Plasma
     whose plugin couldn't be switched to gets no still.
3. **Hyprland and Wayfire window facts.**
   - `compositor.zig` replaces the runtime's Sway-only slot.
   - Hyprland: reads its sockets directly; `fullscreen` is handled both as 0.42+'s number
     and as the older bool + `fullscreenMode`; layout coordinates are the monitor's pixels
     divided by its scale.
   - Wayfire: length-prefixed JSON; `list-views` plus `output-info`; a window outside the
     output is on another workspace.
   - Rig traps:
     - Hyprland can't nest in Sway (it needs `xdg_wm_base` v6; Sway 1.11 has v5), and its
       headless mode can't stand alone; it runs nested in `kwin_wayland --virtual`.
     - Its 62-character instance name makes the socket path pass 108 bytes under a long
       test folder, hence `/tmp/zmc`. A real `/run/user/UID` path is about 96 bytes.
     - `pkill -f "<text>"` killed my own shell again; use `kill` on PIDs from `jobs` or
       `pgrep -f '^...'`.
   - Hyprland comes from a third-party COPR (sdegler/hyprland, 0.56.2): overlay-only, gone
     after a restart.

## The GPU question, measured (2026-10-06, not built)

Owner: on a machine with a cheap built-in GPU, use it instead of the main one. Measured on
this desktop (RX 9070 XT as renderD128, the Ryzen's built-in GPU as renderD129). A
throwaway `ZMURAL_RENDER_NODE` override (reverted) put the renderer on either GPU. Prism
played at 2560x1440 through a headless Sway on the 9070 XT, 30 s per run, interleaved,
two full rounds:

| | 9070 XT power | 9070 XT busy | built-in GPU busy | CPU package (PPT, raw/1000) |
|---|---|---|---|---|
| nothing playing | 16.0 W | 0 % | 0 % | ~28 |
| drawn on the 9070 XT | 22.8-22.9 W | 4-5 % | 0 % | ~28 |
| drawn on the built-in GPU | 16.0 W | 0 % | 27 % | ~32 |

- The 9070 XT saves about 6.9 W. The package rises about 4, assuming PPT is in mW (the
  kernel docs say µW, which can't be right here). The net saving is about 3 W, and that is
  the best case.
- A headless Sway doesn't show the real cost: Plasma on the 9070 XT still composites every
  frame, now reading the wallpaper from system memory over PCIe, so the 9070 XT can't stay
  idle as it did here. That can't be measured from this container.
- Games: the wallpaper already pauses for fullscreen, so freeing the main GPU only helps
  windowed games.
- Laptops: their compositor already runs on the built-in GPU, and zmural already draws
  where the compositor is. So "use the cheap GPU" already happens there.
- No sysfs flag says "integrated". The built-in GPU has no `mem_info_vram_vendor`; a
  Vulkan query would be exact.

Waiting for the owner's decision.

**Owner's decision: skip it.** zmural stays on the GPU the desktop runs on. Multi-plane
buffers and the cross-GPU path are dropped too (MILESTONES M6).

# Where things stand (end of 2026-10-06)

Commits today, all on `main`:
- 13ab45c Welcome page
- dcdcc66 Prism
- 9cf222d fallback for unplayable files
- 8cf3c50 docs
- b10a68a GNOME 51 re-vendor
- 997b52b still picture and Hyprland/Wayfire
- 71a4a02 GPU measurement
- these notes

CI ran green on the first three. It has been on hold since (owner).

Verified here at the end:
- every Linux rig: 21, including the new `compositors-test.sh` and `broken-test.sh`
- KDE 18
- headless GNOME 50
- unit tests 218/226
- Windows cross-build
- Wine 199/216 earlier in the day (the known `access` quirk). Not re-run after the Linux-only
  work.

Nobody has seen any of today's work on a real desktop. On Windows that is the Welcome page,
Prism in the zip, the OneDrive/known-folder path and the fallback. On Linux it is the still
picture on a real GNOME before re-login, Hyprland and Wayfire outside a test rig, and
GNOME 51.

Next, for the owner to pick:
1. A Windows desktop session, then one batched CI run once the hold lifts.
2. The Windows crash-handler risk (first-chance exceptions in the settings thread can take
   zmural down).
3. Web wallpapers on Linux.
4. Close the M5 installer sub-item (it contradicts "no installer").

Small open items:
- rotation landing on a known-broken file (one notice per round)
- Plasma's old picture can't be restored after a still was set
- Niri `covered` (upstream)

Container overlay this session needed:
- rigs/tests/plugins: `tools/sandbox-deps.sh`
- `zip`
- `xorg-x11-server-Xvfb`
- Hyprland, from the third-party COPR sdegler/hyprland

All of it is gone after a restart.

# Host test that evening (new-user install of cfaf8f8 on Plasma)

See `notes/host-test-2026-10-06.md`: a crash on quit with the settings window open (KDE,
`shutdown` calls KWin after freeing the displays), Welcome reopening on every start until a
save, the thumbnail cause (desktop cache only; proven with a spec thumbnail), and the
passes: Welcome buttons clicked for real (uinput mouse), Prism, fallback three ways, stale
Prism, uninstall.

# Night: the host test's findings (`notes/host-test-2026-10-06.md`)

The owner ran the release tarball of cfaf8f8 on their Plasma desktop as a new user. The
findings were fixed in the order the note lists them, except 2 (kept as it is, owner). Each fix comes with a rig check that
fails without it (mutation-checked). None has been seen on the desktop yet, and CI is still
on hold.

1. **Crash on quit with the settings window open (KDE)**, 9432528. `shutdown` now clears
   the bus hook and unloads KWin's foreground script right after the window closes, before
   anything is freed. `tools/kde-test/run.sh` quits with the window open: before the fix it
   crashed with the host's stack, after it 2 of 2 runs are clean (20/20).
2. **Welcome at every start: kept, by the owner's decision.** df80a0e saved Prism as soon
   as it was filled in, so Welcome opened once. The owner reverted that: Welcome and Prism
   should come back at every start until the user adds their own or changes something.
   Nothing is saved until then. `settings-test.sh` step 9 now checks exactly that (two
   starts, two Welcomes, no settings.toml). The stale-Prism log line from df80a0e stays
   ("zmural's own wallpaper moved"); the stale path is rewritten at the next save, as
   before (finding 4c).
3. **Thumbnails**, aadee4c. When neither the desktop's cache nor the file itself (a PNG)
   gives one, the settings window runs `zmural --still-frame <file> <out> 400`, up to 3 at
   a time, and keeps the result in `~/.cache/zmural/thumbs/<md5 of URI>.png`. The file is
   made again when the source is newer. It goes in zmural's cache, not the desktop's, so
   uninstall still leaves nothing (its line now says "still pictures and thumbnails").
   `--still-frame` takes the optional longest side (an mpv `vf` scale), and pictures work
   too (mpv opens them). Prism's tile now shows Prism. Windows is unchanged (shell
   thumbnails). Whether Explorer has a thumbnail for `Prism.webm` there is not known, so
   no `Prism.png` was added.
4. **Labels**, 196f4d4. Status shows `muted : yes (the setting)`, since zmural starts
   muted; a pause still says "by you". The broken-file notice says "Showing X again" only
   when X played before, else "instead" (both OSes). `broken-test.sh` checks both.
5. **Not fixed: the first-start renderer at 1920x1080.** 1920x1080 is the upstream QML
   plugin's built-in default (`m_displayWidth { 1920 }` in `WaywallenDisplay.hpp`). It
   registers before Qt has given it its size, then sends the real size. The KDE rig shows
   it on every (fresh) start. Fixing it means changing vendored upstream code, or making
   zmural wait before the first renderer on every start. It is left for the owner to
   decide; it costs one renderer start of about 0.3 s. **Owner, 2026-10-06: leave it.** It
   only sizes zmural's picture, never the monitor: zmural opens only the render node, which
   can't set modes, and Plasma scales whatever it is given.
6. Not a bug (a file dropped into a folder shows on Rescan); unchanged.
7. **The 0.4.0 version string**, 82b0f6b. CMake reads the version from `Cargo.toml` only
   when it configures, and the reused `.zig-cache/kde-plugin` folder never configured
   again after the bump (this tree's still said 0.4.0). The plugin steps now start fresh
   when `Cargo.toml` is newer than `CMakeCache.txt`.

Verified: `zig build test` 219/227 (8 skipped), TSan
via the pre-commit hook. Rigs: settings 22/22, kde 20/20, still 15, uninstall 7,
keyboard 14, packages 12, broken 9. Windows cross-builds after each change. Not run:
Wine unit tests (the Windows change is one notice string), CI (on hold).

For the next host test: quit with the window open; second start after a first run; a video
folder's tiles; `status` on a fresh install; the display line's version (Plasma keeps the
old plugin loaded until plasmashell restarts, so log out and back in after reinstalling).

