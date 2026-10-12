# Every control, and what tests it

Every button, menu item, key and command a user can reach, what it does, and what proves it
works on each OS. Made on 2026-10-12, after a blind test of the v0.1.0 release
(`notes/blind-test-2026-10-12.md`) found a tray menu that never opens on Sway and buttons that
fail without a word, none of which any test had pressed. **Keep it current:** a new control gets
a row, and a row's test column changes when a test starts (or stops) pressing it. The goal is a
real-input test (`R:`) for every control on Linux, and a recorded pass for every one on Windows.

File:line references are as of 2026-10-12.

**Since 2026-10-12 every settings-window control on Linux is pressed by `tools/controls-test.sh`**
with a virtual mouse, and what it did is checked (`status`, settings.toml, the bus, the log). The
window says where it drew each control (`ZMURAL_TEST_CONTROLS`), so the rig finds them by name and
scrolls to them; file pickers are the one part answered by a hook (`ZMURAL_TEST_PICK`), since they
are the desktop's own windows. Windows has no such rig: its column is the manual pass.

## Legend

| Code | Meaning |
|---|---|
| `U` | unit test (`test "..."`), named in the cell or the notes under the table |
| `R:<script>` | rig with **real input**: a wlr virtual pointer click (`zig-out/bin/zmural-test-input`, `tools/wl-input.zig`) or real keys typed by `wtype`, on headless Sway |
| `H:<script>` | rig that **bypasses the control**: a test hook (`ZMURAL_TEST_PICK`, `ZMURAL_TEST_SLOW_UNINSTALL`), a `zmural-console`/control-socket call, a `sed` edit of settings.toml, or a D-Bus call made by the script (gdbus/busctl) instead of a real tray host |
| `CI` | `.github/workflows/ci.yml`, Windows job (no input is ever sent to the window there) |
| `M:<date>` | manual, once, recorded in `notes/host-test-*.md`, `notes/windows-check-*.md` or `notes/milestones-2026-08-to-10-12.md` (the retired plan). Linux manual = owner's Plasma 6.7.5 desktop. Windows manual = Windows 11 25H2 |
| `M(dbus):<date>` | manual, but the "click" was a `busctl`/`gdbus` call from a shell, not a pointer |
| `—` | nothing found |

For CLI rows, running the command in a rig *is* the real use, so those are `R:`.

Two facts that matter for every Linux rig row: **every Sway rig unsets `DBUS_SESSION_BUS_ADDRESS`**
(`settings-test.sh:19`, `keyboard-test.sh:20`, `uninstall-test.sh:26`, `import-test.sh`, `sway-test.sh:118`, and 9 more;
only `compositors-test.sh` doesn't mention it), and their `sway.conf` holds only an `output` line (no `bar {}` block).
So in those rigs there is no tray, no StatusNotifierWatcher/Host, no portal, no FileManager1 and no notification
daemon. The settings window there runs with `st.bus == null`.

Windows manual passes: `M:2026-09-26` and `M:2026-09-27` (the retired plan, `notes/milestones-2026-08-to-10-12.md`, M5) were done when the window
was still a separate `zmural-settings.exe` and before the Welcome page, Rescan and Customise existed. `M:2026-10-01` is
`notes/windows-check-2026-10-01.md` (keyboard mostly, "keys posted to the window or sent as real key presses").

---

## 1. Settings window, shared parts (`src/settings/app.zig`)

Click → `app.pending` → `perform()` (`app.zig:384-455`) after the frame. Linux menus/dialogs are drawn in the window
(`platform_linux.zig:849-905`); Windows uses native `TrackPopupMenuEx` / `MessageBoxW` (`platform_windows.zig:203-235`).

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Sidebar pages Welcome / Wallpapers / Playback / Pausing / General (`app.zig:676-688`) | sets `app.page` | `R:controls-test`; `R:keyboard-test` (wtype Home/Down/Return, steps 4-5), `R:uninstall-test` (same keys); pointer: `M:2026-10-11` | `M:2026-10-01` (keys); `M:2026-09-27` (pre-Welcome) | No rig clicks the sidebar with the pointer |
| Now-playing card: Previous (`app.zig:718-727`, key `np`,0) | `.previous` request | `R:controls-test`; — | — (09-27 lists next, pause, unmute only) | untested anywhere |
| Now-playing: Pause/Play (`np`,1) | `.pause`/`.play` | `R:controls-test`; `R:settings-test` step 4 (pointer at 115,680, `settings-test.sh:62`); `R:keyboard-test` step 1 (Enter) | `M:2026-09-27` | — |
| Now-playing: Next (`np`,2) | `.next` | `R:controls-test`; — | `M:2026-09-27` | untested on Linux |
| Now-playing: Mute/Unmute (`np`,3) | `.set_muted` | `R:controls-test`; — | `M:2026-09-27` (unmute) | untested on Linux |
| Offline banner "Start zmural" (`app.zig:843`) | `platform.startDaemon` (Linux: spawn `<exe_dir>/zmural`, `platform_linux.zig:1027`; Win: `ShellExecuteW`, `platform_windows.zig:303`) | — | `M:2026-09-27` | Since 09-30 the window is a thread *inside* zmural, so the banner only shows while it is reconnecting; untested on Linux |
| Toast (`app.zig:565`, drawn `app.zig:1400-1412`, 4 s) | every failure message in the window | — (no rig ever asserts a toast; `import-test` reads the report file, not the toast) | — | The only error channel for Open/Show in folder/pickers is never checked |
| Escape closes the window (`app.zig:648`, `:658`) | `platform.requestClose` | `R:keyboard-test` step 6; `M:2026-10-06`, `M:2026-10-11` | `M:2026-10-01` | — |
| Mouse wheel scroll (`app.zig:777`) | scrolls the page | — | `M:2026-09-27` | — |
| Own title bar: minimize / maximize / close (`platform_linux.zig:822-842`, only when the compositor gives no server decorations, i.e. GNOME) | xdg-toplevel requests / quit | — (Sway and KWin decorate; `tools/gnome-test/run.sh` never opens the window) | n/a | GNOME window chrome never exercised |
| Window closed by the compositor | thread ends, zmural keeps running | `H:settings-test` (`swaymsg kill`, step 5), `H:kde-test` (KWin `closeWindow()`, `run.sh:102-106`) | — (CI only opens it) | — |

### Keyboard (Linux keys: `platform_linux.zig:613-640` via `keymap.zig`; Windows: `platform_windows.zig:341-370`, `WM_CONTEXTMENU` `:449`)

| Key | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Tab / Shift+Tab | between groups | `U` `gui.zig:776` "Tab moves between groups…"; `R:keyboard-test` (Tab only) | `M:2026-10-01` | Shift+Tab never typed in a rig |
| Arrows, Home, End | inside a group; sliders/segments | `U` `gui.zig:752`, `:798`; `R:keyboard-test` (Right, Down, Up, End, Home), `R:uninstall-test` (Left) | `M:2026-10-01` | — |
| Enter / Space | press | `R:keyboard-test` (Return only) | `M:2026-10-01` (held Enter/Space do nothing) | Space never typed in a rig |
| Escape | closes menu/dialog, else window | `R:keyboard-test` steps 3, 6 | `M:2026-10-01` | — |
| Menu key / Shift+F10 | tile menu | `R:keyboard-test` step 3 (Menu only) | `M:2026-10-01` (both) | Shift+F10 never typed on Linux |
| Keymap parsing | real codes from the compositor | `U` `keymap.zig:150`, `:205`, `:228` | n/a | — |

## 2. Settings window, by page

### Welcome (`pageWelcome`, `app.zig:926-989`)

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Up to 4 wallpaper tiles (`wallpaperTile("welcome-tile")`, `app.zig:946`) | `.apply` | `R:controls-test`; `R:settings-test` step 8 (pointer at 415,250, `settings-test.sh:107`); `M:2026-10-06`, `M:2026-10-11` | — (Welcome never tested on Windows: `host-test-2026-10-06.md:115`) | — |
| Tile right-click (same tiles) | tile menu | `R:controls-test`; — | — | — |
| "Wallpapers" button (`app.zig:950`) | `show_page = .wallpapers` | `R:controls-test`; — | — | untested |
| Folder row **Open** ×2 (`app.zig:964`) | `.open_folder` → `platform.openFolder`: **Linux** `createDirPath` then `spawn xdg-open <dir>` (`platform_linux.zig:1043-1048`); **Windows** `createDirPath` then `ShellExecuteW "open"` (`platform_windows.zig:255-261`) | `R:controls-test`; `M:2026-10-06` (KDE: made `~/Pictures/Wallpapers`, opened Dolphin) | — | **Linux: toast only if `spawn` itself fails (xdg-open binary missing). If xdg-open runs and finds no handler (Sway with no file manager) it exits non-zero, the `Child` is discarded (`_ =`), never waited (also left a zombie until zmural exits), and the user sees nothing.** Windows ignores `ShellExecuteW`'s return. Matches the blind-test finding |
| **Add folder** (`app.zig:969`) | `platform.pick(.folder)`: Linux portal `FileChooser.OpenFile` with `directory=true` (`platform_linux.zig:1067-1135`), toast if no bus/portal; Windows `IFileDialog` (`platform_windows.zig:183-200`) | `R:controls-test`; `M:2026-10-06` (dialog opened, cancelled with Escape); no rig | — | Never completed on Linux; the `ZMURAL_TEST_PICK` hook exists but no rig uses it for `.folder` |
| **Open file** (`app.zig:972`) | `pick(.wallpaper)`: a `.zip` → `startImport` (spawns `zmural-console import … --apply --report`), else `.apply` | `R:controls-test`; `M:2026-10-06` (dialog opened, cancelled) | — | Welcome's copy never clicked by a rig (import-test clicks the Wallpapers page one) |
| Auto-rescan every 3 s while Welcome shows (`app.zig:368-376`) | `.rescan` | `R:settings-test` step 8 ("Welcome finds a new picture by itself") | — | — |

### Wallpapers (`pageWallpapers` `app.zig:991`, `drawWallpaperButtons` `:817-832`, `wallpaperTile` `:1029-1053`)

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| **Rescan** (`app.zig:829`) | `.rescan`, reload list ×3 polls | `R:controls-test`; — | `M:2026-10-01` (40e2f0a, 9→10) | untested on Linux |
| **Open file** (`app.zig:830`) | `pick(.wallpaper)` → apply or zip import | `R:controls-test`; `H:import-test` step 6 (`import-test.sh:122-138`): **real pointer click** at 1057,61, but the picker is answered by `ZMURAL_TEST_PICK` (`platform_linux.zig:1068`), so the portal is never called; `M:2026-10-06` (portal dialog seen, cancelled) | — | Portal round trip (Request/Response signal, `uriPath`) only covered by `U` `platform_linux.zig:1423` (uriPath) |
| **Add folder** (`app.zig:831`) | `pick(.folder)` | `R:controls-test`; — | (General's copy `M:2026-09-27`) | — |
| Tile left click (`app.zig:1051`) | `.apply` path | `R:controls-test`; `R:settings-test` step 4 (pointer 415,190); `R:keyboard-test` step 2 (Enter); `M:2026-10-11` | `M:2026-09-27`; `M:2026-10-01` (Enter) | — |
| Tile right-click / Menu key (`app.zig:1052`) | `tileMenu()` (`app.zig:321-334`) → `platform.menu` (Linux overlay `platform_linux.zig:947`; Win `TrackPopupMenuEx` `platform_windows.zig:203-226`) | `R:controls-test`; Menu key: `R:keyboard-test` step 3; **pointer right-click: no rig** (`wl-input.zig` supports `rclick`, no script uses it); `M:2026-10-06`, `M:2026-10-11` (menu seen) | `M:2026-10-01` (Menu key, Shift+F10) | — |
| Menu: "Show on desktop" / "Show on every monitor" | `menuChosen` choice 0 → `.apply` (`app.zig:490-503`) | `R:controls-test`; `R:keyboard-test` step 3 (Menu, Return) | — | pointer selection in the overlay (`platform_linux.zig:872`) never clicked |
| Menu: "Show on monitor N (name)" (only with >1 monitor) | `.apply` with monitor id | `R:controls-test`; — (`monitors-test` uses the CLI only) | — | untested |
| Menu: **"Show in folder"** | `platform.showInFolder`: **Linux** D-Bus `org.freedesktop.FileManager1.ShowItems` (`platform_linux.zig:1051-1063`), toast "the file manager didn't answer" / "no session bus"; **Windows** `explorer.exe /select,"…"` (`platform_windows.zig:245-251`), result ignored | `R:controls-test`; — | — | **Never chosen in any test, on either OS** (06/11 only saw the line) |
| Click outside the menu closes it (`platform_linux.zig:879`) | close overlay | `R:controls-test`; — | n/a | — |

### Playback (`pagePlayback` `app.zig:1055-1123`, `pageProperties` `:1127-1195`)

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Fit: Crop/Fit/Stretch/Center (`app.zig:1070`) | `.set_fill` | `R:controls-test`; `R:keyboard-test` step 4 (Right → `fill = "fit"`); `M:2026-10-11` (click) | `M:2026-09-27`; `M:2026-10-01` (End) | — |
| Volume slider (`app.zig:1075`) | live `.set_volume` every 80 ms while dragging, final on release | `R:controls-test`; `R:keyboard-test` step 4 (Right ×2 → 60, End → 100) | `M:2026-09-27` | pointer drag (the live-throttle path) never tested |
| Mute wallpapers toggle (`app.zig:1094`) | `.set_muted` | `R:controls-test`; `M:2026-10-11` (click) | — | no rig |
| Pause wallpapers toggle (`app.zig:1097`) | `.pause`/`.play` | `R:controls-test`; — | `M:2026-09-27` | untested on Linux |
| Customise: slider per property (`app.zig:1145`) | live `.set_property` + on release | `R:controls-test`; `U` `app.zig:1414` (propValue only); the effect via `H:props-test` (CLI `prop`) | `M:2026-10-01` (arrow keys moved gamma) | never driven in the window on Linux |
| Customise: checkbox toggle (`app.zig:1166`) | `.set_property` "true"/"false" | `R:controls-test`; — | — | untested (only packages bring checkboxes) |
| Customise: dropdown (2-4 options) segmented (`app.zig:1181`) | `.set_property` | `R:controls-test`; — | — | untested |
| Customise: Reset (`app.zig:1194`) | `.reset_properties` | `R:controls-test`; `H:props-test` (CLI `prop --reset`) | — | button never pressed |
| Change every: Off/5/15/30 min/1 h/3 h (`app.zig:1108`) | `.set_rotation minutes` | `R:controls-test`; `U` `app.zig:1227` (nearestPreset) | — | button never pressed (CLI `rotate` is `M` only) |
| Order: By name/Shuffle/Random (`app.zig:1120`) | `.set_rotation order` | `R:controls-test`; — | — | untested in the window |

### Pausing (`pagePausing` `app.zig:1259-1307`)

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Rule segmented Nothing/Mute/Pause/Stop, per exposed condition (12 conditions, `app.zig:1280`) | `.set_rule` | `R:controls-test`; `M:2026-10-11` (fullscreen rule, click). The *rules' effect* is rig-tested by editing settings.toml (`H:sway-test` `:158`, `H:kde-test` `:129`, `H:compositors-test`, `H:niri-test`), never via this control | `M:2026-09-27` (Stop) | — |
| App list: **Add app** (`app.zig:1337`) | `pick(.app)` → basename → `.set_list app_rules` | `R:controls-test`; — | `M:2026-09-27` (notepad.exe) | Linux: never; rigs `sed` the `apps =` line |
| App list: remove × (`app.zig:1333`) | `.set_list` without it | `R:controls-test`; — | — | untested |
| Wait before resuming slider (`app.zig:1293`) | `.set_resume_after` on release | `R:controls-test`; — | — | untested |

### General (`pageGeneral` `app.zig:1341-1398`)

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| Start at login toggle (`app.zig:1347`) | `platform.setAutostart` (Linux `autostart_linux.write`, `platform_linux.zig:985`; Win HKCU Run `platform_windows.zig:316`), toast on error | `R:controls-test`; `M:2026-10-11` (click → `Hidden=true`, back). Entry format: `U` `autostart_linux.zig:98`, `:107`; `H:instance-test` (CLI `autostart`) | `M:2026-09-27`; `U` `autostart.zig:142`; `CI` (CLI `autostart` only) | button never pressed by a rig |
| Library folder remove × (`app.zig:1370`) | `.set_list library_dirs` | `R:controls-test`; — | `M:2026-09-27` | untested on Linux |
| Add folder (`app.zig:1375`) | `pick(.folder)` | `R:controls-test`; — | `M:2026-09-27` | untested on Linux |
| Crash row (read-only, `app.zig:1384`) | shows `status.crash` | `M:2026-10-11` | — | — |
| **Log file > Open** (`app.zig:1387`) | `platform.openFile(log)`: **Linux** `spawn xdg-open <log>` (`platform_linux.zig:1035-1039`; doc comment still says "the settings file"); **Windows** `ShellExecuteW notepad.exe <log>` (`platform_windows.zig:264-270`) | `R:controls-test`; — (10-11 lists the *row* only) | — | **Never pressed on either OS.** Linux has the same silent-failure path as Welcome's Open (exit status of xdg-open ignored; a `.log` with no text-editor association does nothing). Windows ignores `ShellExecuteW`'s result |
| Reset playback and pausing (`app.zig:1390`) | `confirm` → `.reset_settings` | `R:controls-test`; `R:keyboard-test` step 5: only the **No** path (Enter on focused No; checks nothing changed). Yes never pressed | `M:2026-09-27` (reset done); `M:2026-10-01` (opens on No) | the Yes path on Linux is untested |
| **Uninstall** (`app.zig:1393`) | `confirm` → `.uninstall_confirmed` (`app.zig:441-444`). Linux: set `uninstall_on_exit`, send `.quit`; zmural runs `uninstall.run` after shutdown (`daemon/main.zig:290-291`), ends with a notification (`uninstall.zig:252-259`). Windows: spawn `zmural --uninstall --from-window` (`platform_windows.zig:273-279`), ends with a MessageBox (`uninstall.zig:244-251`) | `R:controls-test`; `R:uninstall-test` steps 2-3 (wtype keys, Left+Return for Yes; part 3 adds `ZMURAL_TEST_SLOW_UNINSTALL=1500` and a session kill). **Checks only the end state** (process gone, files gone). `M:2026-10-11` was the old child-process code, fixed 10-12; the new path was not tried on a desktop | `CI` and `M:2026-10-01` ran the uninstaller **command** (`zmural-console uninstall --yes`; the registered `--uninstall --from-window`), not the button's Yes | No progress UI exists. See "lone Yes" below |
| Confirm dialog Yes / No (Linux in-window `platform_linux.zig:881-903`; Windows `MessageBoxW` MB_YESNO+MB_DEFBUTTON2 `platform_windows.zig:228-234`) | `app_mod.confirmed` | `R:controls-test`; Yes: `R:uninstall-test` (keys); No: `R:keyboard-test`; pointer: — | `M:2026-10-01` (No) | **Lone Yes:** `if (ui.button(yes)) {…} else if (ui.button(no))` (`platform_linux.zig:897-903`) skips drawing No on the frame Yes is pressed, and that frame is presented |
| About row (read-only) | — | — | — | — |

## 3. Tray, Linux (`src/daemon/tray_linux.zig`, dispatch `runtime_linux.zig:318-366`)

StatusNotifierItem at `/StatusNotifierItem` (`org.kde.StatusNotifierItem`), dbusmenu at `/MenuBar`. Properties
`ItemIsMenu = false` (`tray_linux.zig:229-231`) and `Menu = /MenuBar` (`:233-235`). Registers with
`org.kde.StatusNotifierWatcher` and re-registers when it reappears (`:64-82`, `:85-92`). No `Open log file` item (Windows has one).

| Control / method | What it does | Linux test | Gap/risk |
|---|---|---|---|
| Registration with the watcher | icon appears | `R:tray-test` (swaybar's watcher, the icon found on screen); `R:kde-test` "the tray host knows the icon" (real kded6 watcher + plasmashell, `run.sh:75-76`); `M:2026-09-30` (icon in the panel, screenshot) | — |
| Left click → `Activate(x,y)` (`tray_linux.zig`) | open/raise settings window (with the `ProvideXdgActivationToken` token) | `R:tray-test` (a real pointer click on swaybar's icon); `H:kde-test` (gdbus `Activate` ×3 + `ProvideXdgActivationToken`, `run.sh:86-91`, `:134`); `M(dbus):2026-09-30`, `-10-05`, `-10-11` | Plasma's systray never clicked with a pointer |
| Middle click → `SecondaryActivate` (same branch, `:97`) | same as left click | — | untested |
| Right click → `ContextMenu(x,y)` (swaybar; hosts that show the menu themselves never call it) | opens the settings window, as a left click (owner, 2026-10-12: swaybar can't show the menu) | `R:tray-test` (a real right click; the call seen on the bus; fails with the old no-op) | — |
| Scroll → `Scroll(delta, orientation)` (`:110`) | nothing | — | untested; no behaviour |
| dbusmenu `GetLayout` (`:115`, `:286-293`), `GetGroupProperties` (`:143`), `AboutToShow`/`AboutToShowGroup` (`:128-141`), `Event` (`:119-126`), `EventGroup` (`:127`, `:317-338`), `LayoutUpdated` signal (`:156-165`), `Introspect` | the menu | `U` `tray_linux.zig:471` "the menu layout round trips through a generic reader" (encoding + `actionFor` ids 3, 13, 1); `Event`: `H:kde-test` (gdbus ids 3, 4). `EventGroup`, `AboutToShow*`, `GetGroupProperties`: — | A real host opening and rendering the menu is never asserted (kde-test's `panel.png` screenshot, `run.sh:97`, is not checked and the menu is never opened) |
| Item "Showing: <name>" / "Nothing showing" (id 1, disabled) | label | — | — |
| Paused ✓ (id 3) | toggle `settings.paused` directly (not via `tray.zig`) | `H:kde-test` (`run.sh:80`, `:111`); `M(dbus):2026-09-30`, `10-05`, `10-11` | — |
| Muted ✓ (id 4) | toggle muted | `H:kde-test` (`run.sh:81`) | — |
| Next wallpaper (id 5) | `stepWallpaper(true)` | `M(dbus):2026-09-30`, `10-05`, `10-11` | no rig |
| Previous wallpaper (id 6) | `stepWallpaper(false)` | — | untested |
| Shuffle ✓ (id 13) | sequential ↔ shuffle | `U` (id only, `tray_linux.zig:481`); `M(dbus):2026-09-30` | — |
| Rescan library (id 8) | `rescan()` | — | untested |
| Start at login ✓ (id 9) | `autostart.write` toggle, warn in log on error (no user message) | — | untested |
| Settings... (id 10) | `openSettings` | `M(dbus):2026-10-05` | no rig |
| Quit zmural (id 12) | `rt.quit = true` | — | untested |
| Tooltip (`ToolTip`, `NewToolTip`, `tray_linux.zig:216-224`, `:422`) | wallpaper + state | `M:2026-10-05` (tooltip text seen) | — |
| Icon pixmaps (`IconPixmap`) | 22/32/48/64 px | `U` `tray_linux.zig:486` "the pixmaps are well formed"; `M:2026-09-30` | — |

## 4. Tray, Windows (`src/daemon/tray_windows.zig`, dispatch `runtime_windows.zig:1127-1156`)

| Control | What it does | Windows test | Gap/risk |
|---|---|---|---|
| Left click / Enter on icon (`NIN_SELECT`, `NIN_KEYSELECT`, `tray_windows.zig:87-95`) | `openSettings()` | `U` `tray_windows.zig:157` "a left click opens the window once; a right click opens the menu (audit L10)"; `M:2026-09-27` (real click); `M:2026-10-01` (after Explorer restart) | — |
| Right click / menu key (`WM_CONTEXTMENU`) | `TrackPopupMenuEx` menu (`tray_windows.zig:100-136`) | `U` same test; `M:2026-09-26` ("its menu used by hand"); `M:2026-10-01` | — |
| Middle click, scroll, `WM_LBUTTONUP`, balloon click | nothing (`.nothing`) | `U` (LBUTTONUP only) | — |
| Title line (greyed) | — | — | — |
| Paused ✓ / Muted ✓ | `Item.request` → `handleRequest` (`tray.zig:28-40`) | `U` `tray.zig:43` "toggles flip the current state"; `M:2026-09-26` (items not itemised) | — |
| > Next / < Previous (greyed with an empty library) | `.next`/`.previous` | `M:2026-10-01` (owner used them; led to fix 90e9000) | — |
| Shuffle ✓ | `.set_rotation order` | `U` `tray.zig:43` | not recorded manually |
| Rescan library | `.rescan` | `M:2026-09-26` (rescan, likely CLI) | — |
| Start with Windows ✓ | `toggleAutostart()` (`runtime_windows.zig:1200`), errors to the log only | `M:2026-09-26` | — |
| Settings... | `openSettings()` | — explicitly | — |
| Open log file | `ShellExecuteW notepad.exe <log>` (`runtime_windows.zig:1164-1169`), result ignored | — | never recorded |
| Quit zmural | `.quit` | — | never recorded via the tray |
| Balloons: can't show (`runtime_windows.zig:600`), crash (`:642`), start with Windows (`:1195`) | info only, no action | `M:2026-10-01` (crash balloon sent, dropped by Do Not Disturb) | a click on a balloon does nothing |
| Icon re-added after Explorer restart (`restore`, `tray_windows.zig:53-60`) | — | `M:2026-10-01` (after fix b9fc210) | — |

CI: no tray interaction at all.

## 5. CLI `zmural-console` (`src/cli/main.zig:13-43`)

| Command | Request | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| `status` | `.status` | `R:` nearly every rig; `U` `main.zig:456` | `CI` | — |
| `apply <path>` | `.apply` | `R:instance-test`, `monitors-test`, `props-test`, `broken-test`, `decode-test`, `still-test`, … ; `U` `test parse` `main.zig:474` | `CI` | — |
| `apply <path> --monitor M` (either order) | `.apply` + monitor | `R:monitors-test`; `U` parse | `CI` | — |
| `follow --monitor M` | `.apply ""` + monitor | `R:monitors-test`, `props-test`; `U` | `CI` | — |
| `next [--monitor M]` | `.next` | `R:monitors-test` (both forms); `U` | `M:2026-09-26` | — |
| `previous [--monitor M]` | `.previous` | `M:2026-09-30`, `M:2026-10-05`, `M:2026-10-11`; no rig | `M:2026-09-26` | — |
| `fill crop\|fit\|stretch\|center [--monitor M]` | `.set_fill` | `R:monitors-test`; `U` | `CI`; `M:2026-10-01` | — |
| `fill default --monitor M` | `.set_fill main` | `R:monitors-test`; `U` | `CI` | — |
| `pause` / `play` | `.pause`/`.play` | `R:instance-test` (`:57-58`); `U` | `CI` (pause) | — |
| `rotate <min>\|off` | `.set_rotation` | `U` `main.zig:515`; `M:2026-10-11` (timer fired) | `M:2026-10-01` | no rig |
| `order sequential\|shuffle\|random` | `.set_rotation` | `U`; `M:2026-10-11` | `M:2026-10-01` | no rig |
| `shuffle on\|off` | `.set_rotation` | `U`; `M:2026-10-11` | — | no rig |
| `mute` / `unmute` | `.set_muted` | `R:instance-test` (`:112-121`); `U` | `M:2026-10-01` | — |
| `rescan` | `.rescan` | `M:2026-10-11`; no rig | `M:2026-09-26` | no rig |
| `import <zip> [--to F] [--apply]` (+ hidden `--report`) | runs in-process (`cli/import.zig`) | `R:import-test`, `packages-test` | `CI` (zip step, `ci.yml:121-174`) | — |
| `export <wallpaper> [<zip>]` | in-process | `R:import-test` | `CI` | — |
| `props` / `prop <n> <v>` / `prop --reset` | `.get_properties` / `.set_property` / `.reset_properties` | `R:props-test`, `packages-test`; `U` `main.zig:465` | `CI` (props, prop) | — |
| `quit` | `.quit` | `R:` most rigs | `CI` | — |
| `autostart on\|off\|status` | in-process | `R:instance-test` (`:67-76`) | `CI` (`ci.yml:346-398`) | — |
| `uninstall [--yes]` | in-process (`uninstall.run`) | `R:uninstall-test` step 1 (stdin n / y) | `CI` (`--yes`) | — |
| `version` | — | CI Linux tarball step (`ci.yml:82`); `package-debian-test` (`--version`) | — | — |
| `help` | usage | — | — | trivial |

## 6. Other entry points

| Control | What it does | Linux test | Windows test | Gap/risk |
|---|---|---|---|---|
| `zmural --settings` (`daemon/main.zig:39`) | asks a running zmural for the window, or starts one with it | `R:settings-test` steps 1, 2, 7; `R:kde-test` (`run.sh:92`); `R:package-test`, `package-debian-test` | `CI` (`ci.yml:238-245`, `:315`) | — |
| App-menu entry `org.zmural.Settings.desktop` (`Exec="…/zmural" --settings`, `desktop_linux.zig:345`) | same as above | `U` `desktop_linux.zig:369`; `H:package-test` (greps the Exec line, then runs `zmural --settings` itself, `:69-70`); `H:kde-test` (`run.sh:77`) | n/a | never launched from a real menu/launcher |
| Windows Start menu shortcut + Settings > Apps uninstall entry (`os/apps_windows.zig`) | `--settings`; `--uninstall --from-window` | n/a | `M:2026-10-01` (written; the uninstall command run directly, "not tried: clicking Uninstall in the Settings > Apps page") | — |
| Autostart entry (`os/autostart_linux.zig`) / HKCU Run | start at login | `U`; `R:instance-test`; `M:2026-09-30` (real re-login) | `CI` (registry values) | — |
| First run opens the window on Welcome | — | `R:settings-test` steps 8-9; `R:package-test` | — | — |
| `zmural --uninstall` | uninstall, asks nothing | — (Linux) | `M:2026-10-01` (`--uninstall --from-window`) | — |
| `zmural --apply`, `--paused`, `--version`, `--layer-shell` | — | `R:` most rigs (`--apply`), `host-test` (`--layer-shell`), `package-debian-test` (`--version`); `--paused`: — | `U` `runtime_windows.zig:1946` (`--paused`) | — |
| Linux notifications (`desktop_linux.zig:510`, `uninstall.zig:258`) | **no actions** (`dbus.zig:571` "actions: none") | text only: `H:still-test` (dbusmock notification daemon). The uninstall-done notification: — (rigs have no bus, so it falls back to stdout) | n/a | — |

---

## Gaps, ranked by user impact

1. ~~**Linux tray right-click on hosts that call `ContextMenu`**~~ **Fixed 2026-10-12:** it opens the settings window; `tools/tray-test.sh`. Was: (swaybar; possibly other minimal hosts): `ContextMenu` is a no-op (`tray_linux.zig:110`) while `ItemIsMenu=false`. On those desktops every tray menu item (pause, mute, next, quit…) is unreachable, so the tray only opens the window. Middle-click and Scroll are also no-ops. **No test of any kind**, and no rig has a real StatusNotifierHost click.
2. ~~**"Open" buttons on Linux fail silently.**~~ **Fixed 2026-10-12** (`tools/open-test.sh`; Windows compiled only). Was: Welcome's folder Open and General's Log file > Open spawn `xdg-open` and never look at its exit status (`platform_linux.zig:1035-1048`). The toast covers only a missing binary. Log > Open has **never been pressed on either OS**. Welcome Open was pressed once, on KDE where Dolphin exists (`M:2026-10-06`). Windows ignores `ShellExecuteW` results the same way.
3. ~~**"Show in folder"** (tile menu) never chosen in any test~~ **Linux: `R:open-test` since 2026-10-12**, with and without a file manager. Was: Linux depends on `org.freedesktop.FileManager1` (absent on Sway without a file manager). A toast exists for the failure, but it has never been seen.
4. ~~**Uninstall from the window gives no progress, and shows a lone "Yes"**~~ **Fixed 2026-10-12** (51 ms; timed in `uninstall-test.sh`). Was: (blind test). The rig checks only the end state (`uninstall-test.sh:73-76`, `:89-93`). The 10-12 in-process path has never been tried on a desktop. Code evidence for both symptoms is in the last section.
5. **Linux file pickers** (Add folder ×3, Add app, Open file ×2) never complete a real portal round trip in any test. The rig path uses `ZMURAL_TEST_PICK`. Only `M:2026-10-06` opened two dialogs and cancelled them. Add app and both Add folder buttons have never been completed on Linux. The "no file picker available (xdg-desktop-portal)" toast on a portal-less Sway has never been seen.
6. **Linux tray items Previous, Rescan, Start at login, Quit** have never been invoked, not even over D-Bus. Settings... and Next only via `busctl` by hand. Start at login errors go to the log only.
7. **Never tested in the window on either OS:** Playback's Change every and Order segments, the Customise checkbox, dropdown and Reset, Pausing's app remove and resume slider, the tile menu's "Show on monitor N", Welcome's "Wallpapers" button, now-playing Previous. Also the GNOME-only title bar buttons and the confirm dialog's **Yes** for Reset on Linux.
8. **Linux never-pressed counterparts of Windows-tested controls** (only `M:2026-09-27` on Windows, before the window moved into zmural): now-playing Next/Mute, Pause toggle, Rescan, General folder remove and Add folder, offline "Start zmural", wheel scroll.
9. **Toasts are never asserted** anywhere. They are the only error channel for 2, 3, 5 and autostart.
10. **Windows overall:** CI never sends input to the window or the tray (it only checks `window: open` in the log). Everything interactive rests on one or two manual passes (09-26/27, 10-01). Never tested on Windows: Welcome, Open log file (tray and window), Show in folder, tray Quit/Settings....

## Why the blind test found what the rigs missed

- **No rig has a tray host you can click.** All 14 Sway rigs unset `DBUS_SESSION_BUS_ADDRESS` (e.g. `settings-test.sh:19`), and their `sway.conf` is a single `output` line (`settings-test.sh:23`). So no swaybar, no watcher, and the tray never registers. The only tray rig, `tools/kde-test/run.sh`, runs a real Plasma, but it drives the item itself with `gdbus`: `com.canonical.dbusmenu.Event 3/4` (`:80-81`, `:111`) and `StatusNotifierItem.Activate` (`:88`, `:134`). It never clicks Plasma's systray, never calls `ContextMenu`, and never asserts its `panel.png`. Plasma reads the `Menu` property, so even a real click there would never reach `ContextMenu`.
- **Manual tray tests were D-Bus calls on Plasma, never Sway.** `host-test-2026-09-30.md:153` and the harness note `:294-296` (`busctl … dbusmenu Event … clicked`). 10-05 (`:58`) and 10-11 (`:94-95`, "dbusmenu ids unchanged: 3 Paused, 5 Next") did the same. 10-05 states "No mouse or keyboard input was possible" (`:7-9`). `compat-2026-10-05.md:72` lists the tray as working on "KDE, Cinnamon, XFCE, waybar, Ubuntu GNOME" from docs, not from runs. Swaybar is not mentioned anywhere in `notes/` or `docs/`.
- **The Open buttons only ever met a desktop with a working opener.** The one manual press was on KDE (Dolphin, `host-test-2026-10-06.md:85-86`). No rig presses Open or Log > Open, and a rig has neither xdg-open handlers nor a bus. Their failure path only reports a *spawn* failure (`platform_linux.zig:1037`, `:1046`). The `Child` is discarded, so "xdg-open ran and found nothing" can't be seen.
- **The uninstall rig never looks at the screen.** It types `Left Return` and then polls for the process to die and the files to go (`uninstall-test.sh:74-76`). From the code, without running it:
  - **Lone "Yes":** on the frame where Yes is pressed, `ui.button(yes)` returns true, so the `else if (ui.button(no))` branch is never evaluated. "No" is not drawn, and `ui.end()` presents that frame (`platform_linux.zig:897-903`, `app.zig:650-657`).
  - **~4 s freeze (likely; needs a run to confirm):** `perform(.uninstall_confirmed)` sends `.quit` and then falls through to `refreshSettings()`/`refreshStatus()` (`app.zig:441-454`). The daemon leaves its loop on `rt.quit` (`runtime_linux.zig:555`) and `shutdown()` first calls `settings_window.close()`, which joins the window thread (`runtime_linux.zig:1885-1887`, `window.zig:55-59`). The window thread is then blocked in a `get_settings` request with a 3000 ms receive timeout (`platform_linux.zig:975`, `control_client_linux.zig:61-62`). So the lone-Yes frame stays up for about the timeout, then shutdown and removal run. The only feedback is a notification at the very end (`uninstall.zig:252-259`).
  - No "Uninstalling…" state exists anywhere in `app.zig`.
- **Pickers are hooked out.** `ZMURAL_TEST_PICK` (`env.zig:28-31`, `platform_linux.zig:1068`) answers the picker before the portal is touched. The one rig that uses it (`import-test.sh:126`) clicks only the Wallpapers page's Open file.
- **Most "settings" rig coverage goes around the window.** Pause rules and app lists are set by `sed` on settings.toml (`sway-test.sh:158`, `kde-test/run.sh:129`), properties by `zmural-console prop` (`props-test.sh`), autostart by `zmural-console autostart` (`instance-test.sh:67-76`). Real pointer input is used by only three rig clicks: `settings-test.sh:62`, `:64`, `:107`. Add the one `import-test.sh:128` click (whose picker is hooked), and `keyboard-test.sh`/`uninstall-test.sh` by keys.
