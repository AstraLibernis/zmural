# Adversarial blind test of 0.1.1 (draft): 2026-10-12

A tester that had never seen zmural (an agent with only the draft's files, its release notes and
the public docs; no source, no notes) was asked to break the Linux build on headless Sway with a
tray bar, mako, a virtual mouse and a fresh home. ~600 commands, 90 window open/close cycles,
15 monitor hot-plugs, helpers killed with SIGKILL/SIGSTOP. Windows: zip contents only.

**Held:** no crash of zmural itself; memory, files and processes flat; zip import security (path
tricks, links, encryption, every bomb shape tried, lying headers); hostile names, links to
`/dev/zero` and `/etc/shadow`, FIFOs and unreadable files in the library; single instance;
renderer and display-host restarts; uninstall. Every 0.1.1 fix held except `apply` (below).

**Found** (H = high, M = medium, L = low). Checked by hand on main: H1, H2, M2 reproduce.
- H1 `apply` of a picture that can't be decoded (text as `.jpg`, 0-byte `.png`, absurd sizes)
  exits 0, shows nothing new, no notification, and mpv logs "No media data to loop" 4 times a
  second for as long as it stays applied. The 0.1.1 fix covers videos only.
- H2 Linux: a web package (or a Lively web package) is accepted, its renderer fails 5 times and
  zmural gives up silently; status says it plays, and it is saved for the next start. Web is
  Windows-only: refuse it up front.
- M1 A file name with a newline splits into two tiles (the library list's separator); one
  applies a relative path from zmural's working folder. (Not reproduced by hand yet.)
- M2 Linux: file names go into the log unfiltered: a newline in one forges a log line. The
  README says control characters are stripped (Windows does).
- M3 A 46 KB GIF with a 10000x10000 canvas: the renderer takes 2.1 GB and 123 % CPU; apply 0.
- M4 The 10,000-file zip limit doesn't count folders: 300,000 empty folders imported.
- M5 Commands in parallel: many fail with a bare "error: Disconnected" (state stays right).
- M6 The app-menu and autostart `Exec=` lines aren't escaped: a `$ " \` % ` in zmural's folder
  path breaks both.
- L1 A hung renderer (SIGSTOP, a FIFO named .mp4, the file truncated while playing) is never
  noticed: frozen frame, "paused: no".
- L2 Settings changes that can't be saved (read-only folder) return 0; a read-only or symlinked
  settings.toml is replaced by a plain file.
- L3 The settings.toml notice isn't repeated for a different mistake in the same bad streak; at
  startup it says "keeps its current settings" where the log (rightly) says "using defaults".
- L4 Raw error names in messages (MissingArgument, BadValue, StreamTooLong, BodyTooLarge...);
  wrong reasons for several zip refusals (same name twice called "differ only in case", ...).
- L5 A file failing again and again stacks a notification each time.
- L6 A failed import still makes its `--to` folder.
- L7 Uninstall deletes all of `~/.config/zmural`, files the user put there too; it says
  "removed" when it couldn't delete the thumbnails.
- L8 The window doesn't reflow when very small (400x300: clipped, no player card).
- L9 A package's `type` isn't checked against its entry (`image` with a `.webm`).
- L10 Exported zips are dated 1980-00-00; `status` "next in 10080:00"; `version extra` accepted;
  About credits libmpv's LGPL build on Linux, where the system's libmpv is used.

Docs: the release notes say the packages' README.txt lists every command (not `follow`,
`order`, `shuffle`, `--monitor`, `version`); the picker troubleshooting also needs
`XDG_CURRENT_DESKTOP` set; the README crash example says 0.1.0; settings.toml's header text
predates the notification.

Not tested: Windows, the real file pickers (the GTK portal can't run in this container), KDE,
GNOME, real monitors, battery/lock rules, a 24-hour log.
