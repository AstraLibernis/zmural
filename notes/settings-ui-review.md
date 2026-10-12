# Settings UI review: Lively and waywallen, and what zmural should do

Written 2026-09-26 from the UI source in `reference/lively` (GPL-3.0: ideas only, no code) and
`reference/waywallen` (MIT). Paths are relative to each repo. Values quoted are the real ones in the files.

---

## 1. Lively Wallpaper (WinUI 3)

### Structure
- **One window**, `Views/MainWindow.xaml`: 875x875 at start, minimum 700x700. It has a custom 48 px title bar
  (16 px icon, "Lively Wallpaper" caption, a 360 px-wide search box in the middle).
- **Navigation is a `NavigationView` with `PaneDisplayMode="Top"`**, so the tabs sit along the top, not in a sidebar.
  The main tabs are **Library** (glyph E8A9), **Gallery** (E719) and **Updates** (E777, with an InfoBadge when an update is waiting).
- **Settings use the same bar.** The gear button in the pane footer swaps the top items for five settings tabs:
  **General, Performance, Wallpaper, Screensaver, System**. A back arrow then appears, and pressing it returns to
  Library (`MainViewModel.GetPages`, `IsSettingsPage`). It's a neat trick, but the swap is disorienting: the tab bar
  you were using disappears.
- **Pane footer command bar:** Add wallpaper (+), Active wallpapers / control panel (a monitor glyph showing
  the count, which bobs 5 px when it changes), Patreon, Settings. An overflow menu holds Theme, Help and About.
- Errors and progress appear as `InfoBar`s stacked over the content (errors, WebView2 install, import progress).

### Settings: section by section (headers are SemiBold `TextBlock`s with a 10 px bottom margin)
| Page | Group | Controls |
|---|---|---|
| General | Appearance and behaviour | Start with Windows (toggle), Tray icon (toggle), UI effects (toggle), Theme (clickable card, then a dialog), Language (combo) + a "help translate" InfoBar |
| | Audio | Volume **slider** 0-100 (the header icon changes with the level), Audio output screen (expander: combo + a 450x150 display picker), "Only play audio when desktop is focused" (checkbox) |
| | Wallpaper directory | Expander: a path button plus a folder button, and a "move existing files" checkbox |
| Performance | Wallpaper playback | Applications fullscreen, Applications focused |
| | Laptop | On battery power, On battery saver |
| | System | Remote Desktop, Restart after lock screen (toggle), Display pause rule (per screen / all screens), Pause algorithm (4 options, one literally named "Grid") + a "?" InfoBar that links to the wiki |
| | Application | "Application Rules" expander: a list (500 px minimum, 100-200 px tall, radius 5) with +/- buttons |
| Wallpaper | (none) | Lock screen picture, Desktop picture, **Fit** (None/Fill/Uniform/UniformToFill), Input (Off/Mouse/Keyboard), Video player (+HW decode, colour), Web browser (+disk cache, debug port), GIF player, stream quality, stream detect, visualizer device, music exclusion |
| Screensaver | | Wait time, lock on resume, fade in, audio |
| System | | Taskbar theme (7 options) |

- **Pause rules are a two-icon segmented `ListBox`** (Pause glyph E769 / Play glyph E768) inside a 1 px bordered
  grid with `CornerRadius="5"`. That's compact, but it's binary (pause or keep playing) and the icons have no text.
- **How many at once:** General about 9, Performance 9, Wallpaper about 11 top-level plus about 6 hidden in expanders.
  **About 35 settings over 5 pages.**

### Wallpaper chooser (`Views/Pages/LibraryView.xaml`)
- A `GridView` of **272x153 (16:9) tiles**, `CornerRadius="5"`, 5 px item margin. The thumbnail fills the whole tile
  (`UniformToFill`), with a transparent-to-`SystemAltHighColor` gradient over the lower part. The title is Body style
  and the description is Caption style, up to 2 lines at medium opacity, in a 60 px bottom band.
- **Hover scales the tile to 1.05 over 0.5 s**, and pressing it pulses between 1.025 and 1.05. The selected tile gets
  a 2 px accent line along the bottom (`SelectedBorderThickness="0,0,0,2"`), not a full border.
- **Clicking a tile applies it straight away.** With several monitors in per-screen mode, a "choose display" dialog
  opens first, unless "remember selected screen" is on. A "..." button on each tile and right-click open a menu:
  About, Set, Preview, Customise, Show on disk, Share, Delete, Edit.
- Dropping files on the page shows a full-page acrylic overlay with a 2 px dashed border, a 1.5x "+" and 24 pt text.
- **Per-monitor:** the Control panel page (`ControlPanel/WallpaperLayoutView.xaml`) has a `DisplaySelector` that
  draws the monitors to scale (radius 5, accent border on the selected one, the monitor number in 18 pt, "Name
  (WxH)"). Under it are Customise and Close buttons, then a `Segmented` control: **Per screen / Span / Duplicate**.

### Visual style
- `MicaBackdrop` on the main window (`MainWindow.xaml.cs:57`). Theme Auto/Light/Dark comes from a separate Theme
  page, which can also set a custom background image covered by `SystemControlAcrylicElementBrush`.
- Standard WinUI tokens: `SystemAccentColor`, `ControlElevationBorderBrush`, Segoe Fluent Icons glyphs, plus a
  custom icon font (`Assets/CustomIcons.ttf`).
- Layout constants in `App.xaml`: `SettingActionControlMinWidth = 240`, `SettingGroupControlSpacing = 15`.
  Settings pages use `Margin="10,25,10,5"`.
- Settings rows are CommunityToolkit **`SettingsCard` / `SettingsExpander`**: an icon, a header and a description on
  the left, the control on the right. This is the Windows 11 Settings look.
- Animations: InfoBars slide in 15 px (0.4 s) and fade in (0.6 s), the update tip spins its icon 360°, the tiles scale.

### Good (worth imitating)
- The **SettingsCard row** (icon + title + one-line description on the left, control on the right) is instantly familiar on Win11.
- The descriptions are written in plain words ("Lively needs to run in the background for wallpaper playback").
- **Mica** makes a small window look native for free.
- 16:9 thumbnail tiles, the gradient caption, the hover lift, and click-to-apply.
- The **scale drawing of the monitors** is much clearer than a list of display names.
- Grouping the pause rules as "Playback / Laptop / System" makes sense.

### Bad
- **Too many settings**, and a lot of engine plumbing: the video player, web browser, GIF player, CEF debug port, and
  a "Pause algorithm" with an option called "Grid".
- The **five settings tabs replace the main tabs**, and you can only get there through an unlabelled gear.
- Where things live is confusing: *Audio* is under General, *Fit* is under Wallpaper, and *app rules* are under Performance.
- The pause choices are icon-only with no text, and they only offer pause or play (no mute, no stop).
- An expander inside a card inside a page means three levels deep for things like the app list.
- Patreon, the account and the gallery sit in the same bar as the core functions.

---

## 2. waywallen (Qt 6 / QML, Material 3 through the author's `Qcm.Material`)

### Structure (`ui/qml/Window.qml`)
- The window is **948x632** by default, and its size is saved (`Settings { category: "window" }`).
  The background is `surface_container`.
- On the left is a **Material navigation rail** that collapses to an icon strip and expands, with a label, when the
  window is wide (setting: "Auto-expand sidebar"). The header has a menu toggle, a 32x32 logo and "waywallen" in `title_large`.
- There are **four main pages:** Wallpapers, Discover, Displays, Status. In compact width the rail becomes a bottom bar.
- **The rail footer** has "Now playing" mini-cards for the current wallpapers (`SidebarNowPlaying`), then
  **Plugins, Settings and About. These open as popups over the page (`PagePopup`)**, not as pages.
- The content area is a `PageContainer` with `corner.large` rounding (16), so the page looks like a card beside the rail.
- Toasts go through a "snackbar" (`MD.SnakeView`). Ctrl+P toggles pause and shows a "Paused"/"Resumed" toast.

### Settings (`page/SettingsPage.qml`: one scrolling popup page, `implicitWidth: 480`)
- **Row building blocks:** `SettingHeader` (`title_small`, `on_surface_variant`, 16 px above, 6 px below, 4 px left),
  `SettingItem` (a `surface_container` rectangle with **16 px corners only on the first and last row of a group**,
  16 px side padding, content height + 16, and a **2 px gap between rows**). So every group looks like one
  rounded card cut into strips. `FieldLabel` uses `label_large`, and optional help text uses `body_small`.
- There's a **"Reset" action in the header** with a confirmation dialog.

| Group | Controls |
|---|---|
| Appearance | Theme (**segmented button**: Light / Dark / System), Accent colour (segmented: Custom / System + a picker), Language (combo) |
| Auto replay | **7 rule rows** (Any window, Focused, Maximized, Fullscreen, Session locked, Session inactive, GameMode). Each has a 120 px **action combo: None / Mute / Pause / Stop**, and an "Applies to" combo (Current display / All displays) that only appears when it makes sense. Last row: **Resume delay slider 0-2000 ms, step 50**, 220 px wide, with the value shown |
| Behavior | Auto-expand sidebar, Single UI instance, Quit UI with daemon, **Start at login**, Hide tray icon, Debug logging, Log folder (Open), Allow duplicate renderers, Mouse forwarding, Plugin update notifications. All switches |
| Effect | Blur while paused (switch) + blur radius, Transition (combo) + duration (ms slider), Wipe direction, Grow centre H / V (% sliders) |
| Audio | Enable audio, Enable audio capture, **Volume slider (%)**, Mute when other streams play, Mute fade (ms) |
| Rotation | Queue mode (Sequential / Shuffle / Random), Interval (text field, s) |
| Cache | Image cache (Clear), Maximum cache size (slider under the row) |
- **About 35 controls on one long scrolling page.** Sliders always show their value and unit ("ms", "%", "px").

### Wallpaper chooser (`page/WallpaperPage.qml`, `WallpaperCard.qml`, `WallpaperDetailPanel.qml`)
- There's a toolbar (Sort, 120 px Search field, Tweak, Filters, Library Manager, Refresh) over a `VerticalGridView`.
  The cell size is adjustable in a **"Tweak" sheet** (aspect ratio, size in px, fill cell / fixed).
- **Card:** the thumbnail is `PreserveAspectCrop` with 6 px margins and `corner.extra_small`, plus a bottom scrim
  going from transparent to `rgba(0,0,0,0.6)`. The white title is centred in `title_small`, up to 2 lines. When
  selected, the corner radius grows to `corner.large`, the card shrinks by 8 px on each side, the cell fills with
  `primary_container`, and a 32 px round check badge appears. That's a lovely, calm selection effect.
- **Clicking opens a 280 px detail side panel** (SplitView) rather than applying the wallpaper. The panel has a
  200 px preview, the name in `title_large`, and Path / Resolution / Size / Format. Next come **target chips**
  (`FilterChip` "All" + one per display, from `PresentationTargetFlow.qml`), an **Apply** button, and a
  **"Layout override"** with a Fill mode combo (Stretch / Fit / Crop / Center). Ctrl/Shift+click selects several for playlists.
- The empty state reads "No wallpapers found / Click the + button... / **Auto detect libraries**".
- **Displays page:** a canvas of monitors as rounded rectangles (`radius: 10`, a 3 px `primary` stroke when
  selected, `primary_container` fill when something is showing, name + "W × H"). Below them is a details pane:
  pause/resume the display, edit it, and layout (Fill mode, H/V offset sliders, rotation), plus "canvases" for spanning.

### Visual style
- **Material 3** with dynamic colour: the theme follows the system by default, the accent follows the system or a
  custom one (default seed `#6750A4`). Surfaces go `surface_container` → `_highest`. No blur or translucency.
- Type scale tokens throughout (`title_large/small`, `label_large/medium`, `body_medium/small`), Material Symbols icons.
- Radii: 16 (groups and page), 10 (monitor tiles), extra_small → large (cards). Spacing is 2 / 4 / 8 / 12 / 16.
- Motion: the rail expansion is interpolated (`expansionProgress`, and the logo and labels fade with it), the card corner grows on select, snackbars.

### Good (worth imitating)
- **The pause-rule table:** one row per situation with a None / Mute / Pause / Stop dropdown, plus one resume-delay
  slider at the bottom. zmural's model already matches this exactly.
- **Grouped rounded rows with 2 px gaps**: clean, dense, and they read like Win11 settings too.
- Sliders that always show the value and unit, and a Reset-to-defaults button with a confirmation.
- The card selection animation. Display chips for "apply to which monitor". A monitor canvas that shows what is where.
- A rail footer showing **what's playing now**. Settings open over the page, so the library state is kept.

### Bad
- **One 35-control scrolling page.** Rarely used things (debug logging, duplicate renderers, cache size, wipe
  direction, "Grow center, horizontal") sit next to Start at login.
- Clicking a card **doesn't apply it**: it takes two steps (open the panel, then Apply).
- Jargon: "Auto replay" (for pause rules), "Session inactive", "canvas", "renderer", "Quit UI with daemon".
- Fill mode appears in three places (global, per display, per wallpaper override), which makes it hard to know which one wins.
- The Material look feels foreign on Windows. Plugins and Discover make the app bigger than a wallpaper picker needs to be.

---

## 3. Recommendation for zmural

**Shape:** one small window (about 900x600, minimum 720x480) with **Mica**, a **left sidebar with 4 sections**,
and every section fitting on one screen without scrolling at 900x600. No nested pages, and no expanders except the app list.
Changes apply instantly: no Save button, and the daemon persists to `settings.toml` as it does today.

| # | Section | Contents (all current settings are covered) |
|---|---|---|
| 1 | **Wallpapers** | Library grid (16:9 tiles). A "now playing" strip on top: preview, file name, ◀ Previous / Next ▶, ⏸ Pause (the user `paused` flag). Clicking a tile applies it. With more than one monitor, a row of **monitor chips** (All / 1 / 2) above the grid picks the target |
| 2 | **Playback** | Fill mode (**segmented**: Crop / Fit / Stretch / Center, with a one-line hint under it), Volume slider 0-100 with the value shown, Mute toggle (default on: "Wallpapers start silent") |
| 3 | **Pausing** | 9 rows grouped as *Windows* (fullscreen, maximized, covered, focused, app_rule), *Power* (on_battery, power_saver) and *Session* (session_locked, remote_session). Each has a **None / Mute / Pause / Stop dropdown**. The app_rule row has an "Apps..." button that opens a small list (+ Add .exe, remove). At the bottom: **Resume delay** slider 0-2000 ms, step 50, value shown |
| 4 | **General** | Start with Windows (toggle), **Library folders** (list + Add folder / Remove, with the two default folders shown greyed as "always included"), Open settings file, version / About, Reset to defaults |

**Borrow from Lively:** Mica backdrop; SettingsCard-style rows (icon + title + one-line plain description on the left,
control on the right, 240 px control column); 272x153 tiles with a gradient caption; hover lift (keep it ≤1.03 and
≤150 ms); click-to-apply; the drag-and-drop overlay for adding files; the scale drawing of monitors (later, for `arrangement`).

**Borrow from waywallen:** the pause table exactly (None/Mute/Pause/Stop + one resume-delay slider); grouped rows with
radius 8 on the group ends and 2 px gaps; the value and unit always shown on sliders; Reset with a confirmation; the
selected-card style (accent ring + check badge); display chips for choosing the target; a "now playing" strip; a
friendly empty state ("No wallpapers yet. Add a folder or drop a video here").

**Leave out:** Lively's second tab bar for settings, the engine/player choices, the "pause algorithm", taskbar
theming, screensaver, gallery/account/Patreon; waywallen's plugins, Discover, canvases, cache, debug toggles, and
the "Grow center" transition knobs; the Material styling (use the Windows 11 look); two-step apply; fill mode set
in more than one place (keep one global fill mode). `fps_cap`, `share_renderers`, `blur_when_paused`, `transition`
and `arrangement` stay file-only for now. At most, a later "Advanced" group could hold them.

**Wording:** say "Pausing" rather than "auto replay" or "performance"; give each rule's title in plain words ("A game
or app is fullscreen", "A window is maximized", "Windows cover the screen", "Any window is focused", "One of my apps is
open", "On battery", "Battery saver is on", "Screen is locked", "Remote Desktop session"), with the scope as a small
caption ("all monitors" / "that monitor"), taken from the comments in `settings.zig`.

**Style values to start from:** Segoe UI Variable (Body 14, Subtitle 20 for the page title, Caption 12 for hints);
Segoe Fluent Icons; system accent colour; follow the system dark/light theme; 24 px page padding, 16 px row padding,
row height 64 (48 without a description), 2 px between rows, 24 px between groups; radius 8 for rows and tiles,
4 for buttons and inputs.

### Mockup (main window, Pausing section)
```
+--------------------------------------------------------------------------------+
| (z) zmural                                                         _  []  X    |  <- Mica
+----------------+---------------------------------------------------------------+
|                |  Pausing                                                      |
|  [#] Wallpapers|  What wallpapers do when something else needs the screen.     |
|  [>] Playback  |                                                               |
| >[||] Pausing  |  WINDOWS                                                      |
|  [*] General   |  +---------------------------------------------------------+  |
|                |  | A game or app is fullscreen   all monitors   [Pause v]  |  |
|                |  | A window is maximized         that monitor   [Pause v]  |  |
|                |  | Windows cover the screen      that monitor   [Pause v]  |  |
|                |  | Any window is focused         that monitor   [None  v]  |  |
|                |  | One of my apps is open  [Apps (2)...]        [Pause v]  |  |
|                |  +---------------------------------------------------------+  |
|                |  POWER                                                        |
|                |  +---------------------------------------------------------+  |
|                |  | On battery                                   [Pause v]  |  |
|                |  | Battery saver is on                          [Stop  v]  |  |
|                |  +---------------------------------------------------------+  |
|                |  SESSION                                                      |
|                |  +---------------------------------------------------------+  |
|                |  | Screen is locked                             [Pause v]  |  |
|                |  | Remote Desktop session                       [Pause v]  |  |
|                |  +---------------------------------------------------------+  |
| +------------+ |  +---------------------------------------------------------+  |
| |[thumb]     | |  | Resume after          o------O---------------  400 ms   |  |
| | rain.mp4   | |  +---------------------------------------------------------+  |
| |[<] [||] [>]| |                                                               |
| +------------+ |  Choices: None = keep playing, Mute, Pause = freeze, Stop =   |
|                |  close it and free memory                                     |
+----------------+---------------------------------------------------------------+
```

### Mockup (Wallpapers section, the default page)
```
|  Wallpapers                               Show on: (All) (1) (2)   [+ Add]    |
|  +----------+ +----------+ +----------+ +----------+                          |
|  |  thumb   | |  thumb   | |##thumb###| |  thumb   |   ## = playing (accent   |
|  |__name____| |__name____| |__name__(v)| |__name____|        ring + check)     |
|  +----------+ +----------+ +----------+ +----------+                          |
|  click = apply to the chosen monitors . right-click: Show in folder / Remove  |
```
