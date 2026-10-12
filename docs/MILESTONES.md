# zmural milestones

The plan from the first public release (0.1.0, 2026-10-12) on. Each milestone is a release.
Items are taken top to bottom; a milestone ships when its boxes are ticked and its tests pass in
CI ([RELEASING.md](RELEASING.md)). The plan before the repository went public, with how
everything that exists was built, is kept in
[notes/milestones-2026-08-to-10-12.md](../notes/milestones-2026-08-to-10-12.md).

**What "done" means.** A feature is ticked for an OS only when a test uses it the way a person
would: a real click or key on the real control, with its effect checked on screen, in `status` or
in the log ([CONTROLS.md](CONTROLS.md) says which test presses each control). A script that goes
around the control (`zmural-console`, an edited `settings.toml`, a D-Bus call) proves the logic
behind it, not the control. What only a real desktop can show is said plainly in the item.

## Where it stands (0.1.0)

| | Windows 11 | Linux (Wayland) |
|---|---|---|
| Videos, pictures, GIFs | ✅ | ✅ |
| Web-page wallpapers | ✅ | ⬜ (0.4) |
| Library, rotation, adjustments, zip import/export, Lively import | ✅ | ✅ |
| Pause rules | ✅ | ✅ (which rules work depends on the desktop: [ARCHITECTURE.md](ARCHITECTURE.md)) |
| A wallpaper per monitor | logic tested; never seen on two real monitors | tested on two virtual screens |
| Settings window | ✅, but nobody has looked at it on Windows since it moved into zmural (2026-09-30) | ✅ |
| Tray menu | ✅ | ✅ on KDE, GNOME (AppIndicator) and hosts that read its menu; **nothing on swaybar** (0.1.1) |
| Desktops | Windows 11 | KDE Plasma 6, GNOME 48–51, Sway, Hyprland, labwc, Wayfire, Niri, COSMIC |

## 0.1.1: Every control works, and a test presses it

From the blind test of 0.1.0 ([notes/blind-test-2026-10-12.md](../notes/blind-test-2026-10-12.md))
and the controls inventory ([CONTROLS.md](CONTROLS.md)), which found controls no test had pressed.

**Where it stands (end of 2026-10-12):** everything here is done on Linux except the Windows pass,
which waits for the maintainer. The draft release v0.1.1 on GitHub was built from b53d896, before
the adversarial test's fixes: run CI by hand on `main` to rebuild it before the Windows pass. See
[notes/stopping-point-2026-10-12.md](../notes/stopping-point-2026-10-12.md).

- [x] Zip bombs refused by ratio, and a zip capped at 4 GiB (fd39888)
- [x] **Tray right-click on swaybar** (it calls `ContextMenu` and can't show the menu): opens the settings window (owner's choice, 2026-10-12). `tools/tray-test.sh` clicks swaybar's real icon, left and right, with a virtual pointer; the right-click step fails with the old no-op. Plasma's tray unchanged (`kde-test`, 20 of 20)
- [x] **Open folder, Open log, Show in folder** say so, with the path, when nothing could open it (Linux: `xdg-open`'s exit status, reaped so none is left a zombie as before; Windows: `ShellExecuteW`'s result). Every toast is in the log now too (`told: ...`). Linux: `tools/open-test.sh` presses the three with a virtual mouse, with no opener and with one (4 checks fail with the old code). Windows: compiled; for the Windows pass
- [x] **Uninstall from the window:** gone 51 ms after Yes (was 5.1 s: the window asked the quitting zmural for its settings and waited out the request); the dialog draws both buttons before either acts, so no frame shows a lone "Yes". `tools/uninstall-test.sh` times it (fails at 5124 ms with the old code); the "zmural was removed" notification is the sign it worked
- [x] **A test desktop like a user's:** Sway with two outputs, a session bus, a notification daemon, a file manager and an opener (`controls-test.sh`; swaybar's tray in `tray-test.sh`, `soak-test.sh`)
- [x] **Every settings-window control pressed with real input, its effect checked:** `tools/controls-test.sh`, 92 presses and 81 checks over every page, the player card, the tile menu (two monitors) and the confirm dialogs. The window writes where it drew each control (`ZMURAL_TEST_CONTROLS`); file pickers are answered by `ZMURAL_TEST_PICK`. Two controls broken on purpose fail 3 checks. It found no new bug
- [ ] **A Windows pass:** [WINDOWS-PASS.md](WINDOWS-PASS.md), by hand, on a real Windows 11 desktop, recorded in `notes/` (the window hasn't been looked at on Windows since it moved into zmural, and this release's Windows changes are compiled only)
- [x] Small bugs from the blind test:
  - [x] `zmural-console apply` waits until the wallpaper shows (about 0.2 s) or zmural says it can't, and then exits 1 with the renderer's reason; a file fixed after failing gets a fresh try. `status` carries what last played and what last failed. `tools/broken-test.sh` (each part mutation-checked); Windows compiled
  - [x] `zmural-console export <name>` takes a library name too (a file's or a package's, as `status` names them; two of the same name ask for the path). `tools/import-test.sh`
  - [x] the "you won't be told again" codec notice came twice: the note is now kept for good, as it promises (one file of a codec on the GPU says nothing about the next). `tools/decode-test.sh`
  - [x] the player card said "Playing" while a pause rule held the wallpaper; it says which now ("Paused: windows cover it"), unit-tested for every rule, seen on Sway
  - [x] two imports of the same zip showed the same tile name; a name two wallpapers share now carries its folder ("sun.png · Sunsets (2)"), unit-tested, seen on Sway
  - [x] a bad value in `settings.toml` was only logged; the user is told once, with the line, and again only after it read fine in between (`tools/broken-test.sh`, mutation-checked); Windows: a tray balloon, compiled
  - [x] the log noted the library every 3 s (Welcome's rescans); now only when its size changes, both OSes (seen on Sway: 5 rescans, 2 lines)
  - [x] ~~a CUDA line on machines without NVIDIA~~ left as is: it is FFmpeg trying NVIDIA's decoder (`hwdec=auto-safe`), harmless; silencing it means listing decoders by hand, which could cost NVIDIA users GPU decoding
  - [x] ~~empty folders left after uninstall~~ left as is: they are the desktop's shared folders (`~/.config/autostart`, `~/.local/share/applications`, the icon theme), which other apps use too
- [x] **From the adversarial test** (`notes/adversarial-test-2026-10-12.md`), the two highs:
  - [x] H1 a picture that can't be decoded (text as `.jpg`, empty, too large) applied with exit 0 and froze the old frame while mpv retried 4 times a second: mpv never ends such a file, it says "No media data to loop", so the renderer fails on that (both OSes). `apply` exits 1 in ~0.1 s; `tools/broken-test.sh` (mutation-checked)
  - [x] H2 Linux: a web package or page was accepted, then given up on silently: refused up front ("web wallpapers are Windows-only so far"), and one saved by an older zmural or reached by rotation falls back with a notification instead of starting a renderer. `tools/broken-test.sh` (mutation-checked)
- [x] ...the mediums (each in its own commit, each with a test that fails without it): a newline in a file's name split it in two (lists now NUL-separated; relative paths refused); file names could forge log lines (every log line escaped); a GIF with a huge canvas took 2.1 GB (frames over 50 megapixels refused); folders didn't count toward the zip limit; commands at once failed with "Disconnected" (32 served, the rest retried); desktop entries broke on a `$ " \ %` in zmural's path (quoted per spec and for GLib)
- [x] The lows: messages in words, rotate's range, right reasons for zip refusals; a failed import's folders removed; a package's type checked against its file; one notification per broken file; settings.toml mistakes told as they change, "uses its defaults" at start; failed saves told, read-only files and links respected; uninstall keeps the user's files and says what stuck; a pipe or device refused; exported zips dated 1980-01-01; `status` shows hours; About names the system's libmpv on Linux; docs (`README.txt` commands, the portal's `XDG_CURRENT_DESKTOP`, the crash example, settings.toml's header)
  - left for 0.2: a renderer that stops sending frames (stopped by a signal, its file cut short while playing) isn't noticed: a frame watchdog. The settings window made smaller than its minimum by a tiling desktop scrolls and hides the player card, as designed
- [x] Doc fixes from the blind test: the Welcome page no longer offers web pages on Linux, and says a right click on the tray icon works on most desktops (not Sway's bar); the install examples say the archive makes its own folder; Troubleshooting covers "no file picker available" (xdg-desktop-portal); `export` and `prop` say what they take in `help`; both packages' `README.txt` list the README's commands. waywallen-display's MIT text was already in `THIRD_PARTY_NOTICES.md`, which both packages ship

## 0.2: Solid on both OSes

Stability and the loose ends of what exists, before anything new.

- [ ] A renderer that stops sending frames is noticed and restarted (a frame watchdog): stopped by a signal, or its file cut short while it plays (from the adversarial test)
- [ ] Windows: the settings window runs inside zmural, and Zig's crash handler treats any first-chance access violation as fatal, so a shell extension (file picker, thumbnails) that raises and catches its own would take zmural down. An unhandled-exception filter for the crash log instead of the segfault handler.
- [ ] Windows: a second `zmural --settings` may only flash the taskbar (`AllowSetForegroundWindow`); a right-click after keyboard use opens the menu at the focused tile
- [ ] Windows web wallpapers: send `shown` once the page has painted, so switching to one doesn't wait 4 s; a frozen last frame while paused (black today); an fps cap; an Explorer-restart test
- [ ] KDE: when the plugin installed but Plasma couldn't be switched to it, nothing shows and no still picture is set
- [ ] `status` shows a monitor's own fill mode but not the main one
- [ ] With `$ZMURAL_CONFIG_DIR`'s parent missing, zmural runs without a log (test setups only)
- [x] **A soak test (2026-10-12), Linux:** `tools/soak-test.sh` runs a day of use in rounds on headless Sway with two outputs, a session bus, swaybar's tray and mako: every wallpaper kind and a broken file, next/previous, fill modes, a monitor's own wallpaper, pause, mute, adjustments, the settings window opened and closed, `settings.toml` edited by hand, a zip imported, a monitor unplugged and replugged, a renderer killed every 5 rounds. It samples memory, open files, threads and processes after each round and judges the trend after warm-up; zmural must answer every round, accept every command, never crash, and quit cleanly with nothing left (a Debug build adds its allocator's leak report, proven to catch a planted leak). The verdict is checked on made-up samples (`--judge`).
- [ ] The soak test on Windows (a runner can do the CLI part; the window needs a desktop)
- [ ] A week of daily use on both OSes: sleep and resume (no rig can suspend), real monitor hotplug, a real GPU's driver resets
- [ ] Two real monitors on Windows, once someone has them

## 0.3: Monitors, and dropping files in

- [ ] **Drag and drop into the library folders.** The folder lists that show where wallpapers are kept (Welcome's "Where to put them", General's library folders) take files dropped on them: a file dropped on a folder's row is copied into that folder, so the user sorts as they add. A `.zip` dropped anywhere imports as Open file does. Dropped anywhere else in the window, a file goes to the first folder. Both OSes (Wayland `wl_data_device`; Windows `IDropTarget`), with a real-input test on Linux.

- [ ] A view of what each monitor shows, in the window (today only `zmural-console status` says)
- [ ] Properties per monitor (a monitor's own wallpaper has none, and one wallpaper on two monitors shares one set)
- [ ] Rotation per monitor; pausing one monitor (`pause --monitor` is refused)
- [ ] Windows: a wallpaper package as a monitor's own wallpaper (only plain files today)
- [ ] zip64, so `export` can write more than 4 GiB

## 0.4: Web wallpapers on Linux, and wallpapers that react

- [ ] Web wallpapers on Linux: WebKitGTK, always offline, the Windows renderer's hardening, and only with WebKit's own sandbox on
- [ ] The JS API beyond properties, both OSes: audio spectrum (WASAPI loopback / PipeWire, 128 bins), now playing, system stats, pause events
- [ ] Mouse input for web wallpapers
- [ ] The Lively JS shim (`livelyPropertyListener`), so imported Lively pages hear property changes

## 0.5: Trust and distribution

The open security issues (below) and the ways zmural reaches people and updates.

- [ ] Renderer sandbox (S1): Windows a restricted token or AppContainer; Linux to be designed (seccomp and Landlock are the candidates)
- [ ] An AppContainer without network for the Windows web renderer (S2, S9)
- [ ] Clean up web wallpapers' browser profiles that nothing uses any more (S10)
- [ ] Code-signed Windows releases, and a GitHub Releases update check verified against a key built into zmural (off until the first signed release) (S8)
- [ ] Linux packages that bring their own updates: a Flatpak (it also brings H.264/H.265 GPU decoding to Fedora and openSUSE) and a Fedora COPR
- [ ] The plugin self-upgrade zmural has for KDE, for the GNOME extension too

## 1.0: Stable

When there is no open high or medium bug, every control has a real-input test on Linux and a
recorded pass on Windows, a week of daily use on both OSes went clean, and Windows releases are
signed.

## Later

- Span one wallpaper across monitors (the Linux daemon doesn't know where monitors are yet: xdg-output, or a layout setting)
- Transitions between wallpapers; blur while paused
- Screensaver mode (Windows `.scr`; Linux not designed)
- Languages other than English
- A name filter for the library, if libraries grow past what thumbnails show at a glance (tags: decided against, below)
- Niri: `covered` and fullscreen on hidden workspaces, once its IPC says where windows are (upstream)

## Decided against

Settled, so they aren't proposed again: an online gallery (zmural is not a service); an installer
(unzip is enough; zmural has an uninstaller); plugins, third-party renderers or programs as
wallpapers; web addresses as wallpapers or any network for a wallpaper; screen-reader support
in the settings window (`zmural-console` does everything it does); restarting itself after a
crash; tags for wallpapers (a library is the user's own folders, which thumbnails show; tags are for big catalogues like waywallen's Wallhaven and Workshop sources, which zmural doesn't have); choosing or combining GPUs (zmural stays on the desktop's own); Windows 10.

## Known security issues

Open issues, in the README's words under [Security](../README.md#security). Every new one found goes here and there.

| # | OS | Issue | Plan |
|---|---|---|---|
| S1 | both | Video/image renderers aren't sandboxed: a decoder exploit could read the user's files | 0.5 |
| S2 | Windows | The web renderer's job has no UI limits (Chromium's sandbox won't start under any); the web renderer and WebView2's browser process run with the user's rights; pages are in Chromium's sandbox | 0.5: an AppContainer for the whole web renderer |
| S3 | Windows | A page can read its whole folder tree; it is offline, so only a way around the offline mode (S9) could send files out | with S9 |
| S7 | Windows | Web pages may play sound once the user unmutes | by design (muted by default); documented |
| S8 | both | Releases aren't code-signed and there is no updater | 0.5 |
| S9 | Windows | Offline mode is Chromium proxy flags, not a firewall rule | 0.5: an AppContainer without network capabilities |
| S10 | Windows | Every web wallpaper's browser profile stays in `%LOCALAPPDATA%\zmural\webview2` until uninstall | 0.5 |

Fixed issues and audits are in the retired plan.
