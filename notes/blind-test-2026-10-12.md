# Blind test of the v0.1.0 release: 2026-10-12

A tester that had never seen zmural (an agent given only the public GitHub page, the release, and
what the app itself shows; no source, no notes) downloaded v0.1.0, installed the Linux tarball by
the README, used it, broke it, and uninstalled it. Desktop: headless Sway 1.11 on the real GPU,
with swaybar showing tray icons, mako for notifications, a session bus, and a fresh empty home.
Input: a wlr virtual pointer and `wtype`. No file manager, no working xdg-desktop-portal. Windows:
checksum and contents only (no Windows desktop here). Screenshots were in `/tmp/blind/shots/`
(not kept); the claims below were checked against them and against the code.

## Worked as the README says

First run (tray star, Prism on the GPU, the window on Welcome, the start-at-login notification);
files dropped into `Videos/Wallpapers` appearing on Welcome within ~6 s; a tile click setting the
wallpaper; all four fill modes, brightness and the other adjustments, pause/play, mute,
next/previous, rotation, `settings.toml` edited by hand; a fake `.mp4`, a truncated video and a
folder each refused with a notification and the previous wallpaper back; corrupt zips and zips
with `../` or absolute paths refused with nothing written; import, re-import as `name (2)`,
export to a path; uninstall from the window and from the terminal, nothing left running, the
wallpapers kept, only empty folders left.

## Found

1. **Medium: no tray menu on Sway.** Right-click on the tray icon in swaybar shows nothing.
   swaybar calls the item's `ContextMenu`, which zmural answers with nothing
   (`daemon/tray_linux.zig`, "ContextMenu, Scroll: nothing to do") while saying
   `ItemIsMenu=false`. Every tray menu item is unreachable there; the tray only opens the window.
2. **Medium: a zip bomb was imported.** A 3 MB zip of one 3 GiB file of zeros unpacked in full;
   the only size check was 8 GiB in all. **Fixed the same day** (fd39888): 4 GiB at most, and past
   256 MiB no more than 20 times the packed size.
3. Low: the VP9 "no GPU decoder … you won't be told again" notice came a second time.
4. Low: `zmural-console apply` on a file that can't play exits 0; only a notification says it failed.
5. Low: `zmural-console export <name>` with a library name says FileNotFound; only a path works.
6. Low: Welcome's folder **Open** and General's **Log file > Open** do nothing, with no message,
   when nothing can open them: `xdg-open` is started and its result never looked at.
7. Low: after **Yes** in the uninstall dialog, the dialog shows a lone "Yes" for ~4 s with no
   sign of progress (the "No" button is skipped on the frame Yes was pressed; the wait is likely
   the window's 3 s settings request while zmural waits for the window to close).
8. Low: the mini-player said "Playing, muted" while `status` said paused (covered); two imports
   of the same zip show identical tile names.
9. Low: a bad value in `settings.toml` is only logged ("using defaults"); the user isn't told.
10. Low: the log notes "library: N wallpapers" every 3 s; "Cannot load libcuda.so.1" on stderr
    and a CUDA line in the log on an AMD machine; empty folders left after uninstall.

Docs: the Welcome page lists web pages as a wallpaper type on Linux (Windows-only); the README's
`~/.local/opt/zmural` example gives a folder inside a folder (the tarball has its own top
folder); nothing says the Linux pickers need xdg-desktop-portal; `export <wallpaper>` doesn't
say it takes a path; `prop speed` is videos only; the tarball's `README.txt` lists fewer
commands than the README; waywallen-display's MIT licence text isn't in `licenses/`.

## Why the tests missed it

`docs/CONTROLS.md` has the whole inventory. In short: no rig had a tray host anyone clicks (the
Sway rigs run without a session bus and without swaybar; the KDE rig and the manual passes drive
the tray with `gdbus`/`busctl`), no rig presses the Open buttons or watches for a toast, and the
uninstall rig checks only the end state. Real pointer input reached three controls.
