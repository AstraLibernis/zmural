# Stopping point: 2026-09-27 (evening update)

**Read this part first; the older notes below it are history.**

## Where things stand

Last commits: `1deb859` audit #2 fixes, `80b83d5` the M7 web renderer, `1a351e0` M7 packages and properties. All are pushed, and CI was green through `80b83d5`.

- **Audit #2:** fully fixed; see the MILESTONES "Audit #2 fixes" section.
- **M6 (Linux):** on hold until the user works on Linux.
- **M7 web renderer (WebView2):** done.
  - **Packages** (`zmural.toml`) with properties: done.
  - **Properties:** `zmural props` / `prop <name> <value>` / `prop --reset`; `window.zmural` in local pages.
  - **Security:** local pages offline by default, locked to their origin, and a browser profile per wallpaper.
- **Security issues** are tracked in README `## Security` **and** the MILESTONES "Known security issues" table (S1–S10). The user asked that every new one goes in both.

## What I was working on when stopped

The **"Customise" panel in the settings window** (`src/settings/main.zig`), for the showing wallpaper's properties. I had only read the code; nothing was written yet.

Plan:
1. `refreshProperties()` calls `get_properties` and parses the reply with `zmural.properties.parseList` into an arena. It runs when the wallpaper changes (it's in `refreshStatus`).
2. **Where:** a new card group, "Customise <title>", at the top of the Playback page (or its own sidebar page). It's hidden when the wallpaper isn't a package.
3. **Controls,** using the existing gui.zig widgets:
   - `slider`: `ui.slider`, mapping min..max and snapping to step. Send live while dragging, throttled like the volume slider; send on release.
   - `checkbox`: `ui.toggle`.
   - `dropdown`: `ui.segmented` for up to 4 options; otherwise a button that cycles or opens a menu.
   - `color`: a swatch button that opens `ChooseColorW` (comdlg32).
   - `text`: no text input widget exists yet, so show the value and point to `zmural prop`.
4. **Actions:** new `set_property` and `reset_properties` actions ("Reset to defaults" button), each followed by a refresh.
5. **Each row:** the label, plus a short explanation (per the user's request for explanations).

After that, M7 continues with:
- the JS API: pause events, now-playing, system stats, the audio spectrum;
- Lively import;
- `.zip` import/export;
- mouse input;
- mpv properties, through a safe allow-list.

The user's queued requests are still open: **one exe instead of seven**, and **settings only in the window** (explanations on every option, no "open settings file" links).

## Testing notes

- **Screenshots:** capture only the surface window with PrintWindow; the helper is the scratchpad `cap.ps1` / `web-test.ps1`.
- **PowerShell `$s` and `$S` are the same variable.**
- **Mixed native and PowerShell output gets lost,** so route everything through `[Console]::Out.WriteLine`.
- **Never live-test with the pause rules off while a fullscreen game is running;** check `Get-Process` first.
- **Patch scripts:** write Python patch scripts with the Write tool using raw strings; bash heredocs mangle backslashes.

---

# Stopping point: 2026-09-27

Where zmural stands, and what to pick up next. The last commit before this note is `6296ed8` (CI green).

## Done since v0.1.0 was packaged

1. **Audit #1 fixes** (`2b2c269`): all 19 findings from `notes/audit-2026-09-26.md`. Their test and live results are in `docs/MILESTONES.md` under "Audit fixes". Main changes:
   - the renderer lifecycle is now a pure state machine (`src/daemon/lifecycle.zig`);
   - the control pipe is per SID and session, and the owner is verified;
   - renderers are hardened: pipe peer pid checks, job UI limits, mpv options.
2. **Dead-code tidy** (`e01d888`), plus a CI fix: Windows-only tests are no longer compiled on Linux (`948196f`).
3. **Blind audit #2** on the fixed code: `notes/audit-2026-09-27.md`. **Not fixed yet, waiting for the user's review** (see below).
4. **Settings window** (`6296ed8`): `zmural-settings.exe`, in `src/settings/`.
   - Built with Direct2D, DirectWrite and Mica, using hand-written COM bindings.
   - Pages: Wallpapers, Playback, Pausing, General, plus a now-playing card.
   - It opens when you left-click the tray icon.
   - New control requests: get_settings, library (paged), set_fill, set_volume, set_rule, set_resume_after, set_list and reset_settings.
   - Every page was tested live in light and dark mode; see the MILESTONES "Settings window" section.

State: 90/90 tests pass. fmt, zsnag, the Linux cross-build and `zig build package -Doptimize=ReleaseSafe` are all clean.

## Next, in order

1. **Decide on audit #2** (`notes/audit-2026-09-27.md`). The five medium findings:
   - F1: a logoff shutdown keeps dispatching messages over freed lists.
   - F2: a renderer that reports HWND 0 panics the daemon.
   - F3: a startup wallpaper that's briefly missing gets erased from settings.
   - F4: the crash give-up window never slides.
   - F5: hand edits to settings.toml are overwritten while zmural runs.

   There are also 10 low findings (F6–F14, F16) and dead code (D1–D4), for example the unused `set_property` / `screenshot` renderer commands. The user wanted to review these before anything is fixed.
2. **Settings window follow-ups:**
   - keyboard navigation (Tab / arrows) and screen-reader support, since it's mouse-only today;
   - the "Settings file → Open" caveat ties into F5.
3. **Release:** the draft GitHub release v0.1.0 still holds the **old** zip, without the settings window or the audit fixes. Rebuild with `zig build package -Doptimize=ReleaseSafe` and replace the asset. Publish **only when the user says so**.
4. **M6: Linux MVP** (see MILESTONES).

## How to test (scratchpad scripts, re-creatable from MILESTONES)

- **Live daemon regression:** start zmurald with `ZMURAL_CONFIG_DIR` set to a scratch folder whose settings.toml lists `media/` as the library. Drive a fullscreen test window with the WinForms test window started through PowerShell `-EncodedCommand`. Use `zmural status` for state.
- **Settings UI:**
  - `ZMURAL_THEME=dark|light` forces a theme.
  - Screenshot only the window (DwmGetWindowAttribute extended frame bounds), never the whole screen.
  - Click at client coordinates in DIPs.
  - File dialogs: Alt+N focuses the file name box. For the folder picker, click "Select Folder".
- **Build:** stop any running zmurald or zmural-settings before `zig build`; they lock their exes.
