# Stopping point: 2026-09-29

**Superseded: read `stopping-point-2026-09-30.md` first.**

**2026-09-30: read `host-test-2026-09-30.md` first** (three bugs from the owner's real Plasma session + the container loses its headless test tools on every restart).

**Read this first; `stopping-point-2026-09-28.md` still holds the open M6 list.**

The owner runs zmural on their Linux desktop in place of waywallen. Two requests from that:

- **Timer and shuffle (done).** `daemon/rotation.zig` plus wiring in both runtimes, the tray, the CLI, the settings window (Playback → "Change wallpaper automatically") and `settings.toml` `[rotation]`. The code was written on 2026-09-28 night but the session was interrupted before commit; it was verified and committed 2026-09-29. Live test on headless Sway: sequential and shuffle `next`, a one-minute timer firing, pause freezing the clock, window clicks reaching zmurald.
- **Settings only in the window (done).** The General page no longer offers "Settings file → Open" (it opened settings.toml in a text editor). The log file row stays (Linux has a log file since 2026-09-30: `~/.local/state/zmural/zmurald.log`).

Also: `settings/main.zig`'s test block now references `app.zig`, so the settings-window tests run (they were silently skipped before).

**Owner:** the shared settings page and the Windows runtime/tray changed, so test on Windows: the Shuffle tray item, the Playback page rotation controls, and a timed change.

## Later the same day: M6 system facts

The owner runs **KDE Plasma** (migrated from GNOME). On Plasma the vendored plugin already reports fullscreen/maximized windows, so fullscreen pausing worked; the gap was every system-wide rule. `daemon/facts_linux.zig` now reports battery, Power Saver, lock, session inactive, remote session and GameMode (see MILESTONES M6). Test script: `tools/facts-test.sh` (python-dbusmock, a private bus standing in for the system bus).

Next M6 candidates for a Plasma user (the Linux log file and `app_rule` on KDE are done, 2026-09-30; the app in front comes from a KWin script, not the plugin): explicit sync on the renderer side. The layer-shell auto-spawn matters only off KDE/GNOME.
