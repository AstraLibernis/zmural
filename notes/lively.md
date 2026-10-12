# Lively Wallpaper: reference notes for zmural

Source: `reference/lively` (rocksdanister/lively, shallow clone, HEAD `6dab5a6`), GPL-3.0.
**Clean-room rule:** these notes describe mechanisms in our own words. Do not copy code from it.
All paths below are relative to `reference/lively/src/Lively/` unless noted otherwise.
Anything marked *(inference)* is my reading between the lines. It is not stated directly in the code.

---

## 1. Overview

- **What:** a free Windows live-wallpaper manager. It can use videos, GIFs, pictures, web pages (local HTML or URLs),
  Shadertoy links, YouTube streams, and arbitrary `.exe` programs (including Unity and Godot games) as the desktop wallpaper.
  It also does screensavers, an automation CLI, a JS "Lively API" for web wallpapers, and depth-map ("parallax") wallpapers made by ML.
- **Language:** C# only. About 430 `.cs` files, 5 `.proto` files, and XAML. There is no native C/C++ code. All Win32 access goes through P/Invoke
  (`Lively.Common/Helpers/Pinvoke/`).
- **Frameworks, per the `.csproj` files:**
  - Core service `Lively`: **.NET 9 WPF** (`net9.0-windows10.0.18362.0`). The tray uses a WinForms `NotifyIcon`.
  - UI `Lively.UI.WinUI`: **.NET 9 + WinUI 3 / Windows App SDK 1.7** (`net9.0-windows10.0.22621.0`), self-contained WinAppSDK.
    The csproj pins SDK 1.7 because 1.8 breaks `ResourceLoader` when unpackaged. It builds for x86/x64/arm64.
  - Shared libraries target `netstandard2.0`, `net8.0` or `net9.0`.
  - The player executables (WebView2, CefSharp, VLC, WMF), the screensaver `.scr` shim and the watchdog are **.NET Framework 4.7.2**.
    The screensaver comment says this keeps them tiny.
- **Main dependencies:**
  - mpv (external `plugins/mpv/mpv.exe`, which is the default video, GIF and picture player), plus yt-dlp/youtube-dl for streams.
  - WebView2 (`Microsoft.Web.WebView2` 1.0.3595, the default web engine) and CefSharp.WinForms 141 as an alternative web engine.
  - LibVLCSharp 3.9 and external `vlc.exe` (alternative video players).
  - gRPC over named pipes (`GrpcDotNetNamedPipes`, `Grpc.Core`, `Google.Protobuf`).
  - NAudio and MathNet.Numerics (audio FFT), NPSMLib (now-playing info), and `PerformanceCounter` (system stats).
  - ONNX Runtime and Magick.NET (MiDaS depth estimation, image handling).
  - CommandLineParser, Newtonsoft.Json, NLog, CommunityToolkit.Mvvm/WinUI, WinUIEx, H.Hooks, RawInput.Sharp, WinEventHook, Octokit (updater).
- **Distribution:** an Inno Setup installer (`src/installer/Script_x64.iss`) that bundles the .NET 9 desktop runtime and VC++ redist, and an MSIX
  Store package (`Lively.UI.WinUI/Package.appxmanifest`). *(inference)* The mpv, VLC and yt-dlp binaries are not in the repo and get bundled
  into `plugins/` at release time.

## 2. How it works

### 2.1 Process model
Lively runs as several processes:

| Process | Role |
|---|---|
| `Lively.exe` (core, WPF, headless + tray) | The single-instance owner. Owns wallpapers, WorkerW parenting, pause logic, screensaver, settings, and the gRPC server. |
| `Lively.UI.WinUI.exe` | The control panel. Core launches it on demand (`Lively/Services/RunnerService.cs`) and can kill it, so the UI is disposable. |
| One player process per wallpaper per screen | `mpv.exe`, `Lively.Player.WebView2.exe`, `Lively.Player.CefSharp.exe`, `vlc.exe`, `Lively.Player.Vlc.exe`, `Lively.PlayerWmf.exe`, or the user's `.exe`. |
| `Lively.Watchdog` | Started with core's PID. Keeps a PID list sent over stdin (`ADD`/`RMV`/`CLR`). When core dies, it kills every listed wallpaper process and the UI, then forces a desktop repaint (`Lively.Utility.Watchdog/Program.cs`). |
| `Lively.Utility.Commandline` / `Lively.Utility.Screensaver` | Thin clients that forward to core over gRPC or command-line args. |

- **Single instance:** a named mutex, `LIVELY:DESKTOPWALLPAPERSYSTEM`. A second launch opens a gRPC client and forwards its argv through
  `CommandsService.AutomationCommand`, then exits. With no args it forwards `--showApp true` (`Lively/App.xaml.cs`).
- **DI:** `Microsoft.Extensions.DependencyInjection`. `App.ConfigureServices` wires the singletons: settings, desktop core, display manager,
  playback, screensaver, watchdog, tray, updater, and the gRPC servers.

### 2.2 IPC
- **Core and UI/CLI:** **gRPC over a named pipe** named `Grpc_LIVELY:DESKTOPWALLPAPERSYSTEM<username>` (`Lively.Common/Constants.cs`).
  Services are defined in `Lively.Grpc.Common/Proto/`:
  - `DesktopService` (wallpaper.proto): set, close, preview and screenshot wallpapers; `SendMessageWallpaper` (pushes property changes);
    and server-streaming `Subscribe*` calls for wallpaper-changed and wallpaper-error events.
  - `SettingsService`: get or set the whole settings object and app rules.
  - `DisplayService`: screen list, virtual bounds, and a display-changed stream.
  - `CommandsService`: show, close or restart the UI, the screensaver, shutdown, and `AutomationCommand(args[])`.
  - `UpdateService`: GitHub release checks.
  The UI-side wrappers live in `Lively.Grpc.Client/`. Core-side implementations live in `Lively/RPC/`. The UI subscribes to the streams in background tasks.
- **Core to UI side-channel:** stdin text lines such as `LM SHOWBUSY` or `LM SHOWAPPUPDATEPAGE` (`RunnerService.cs`; parsed in `Lively.UI.WinUI/Views/MainWindow.xaml.cs`).
- **Core and players:** these do not use gRPC. Every channel is one JSON message per line.
  - mpv: mpv's own **JSON IPC over a named pipe** (`--input-ipc-server=mpvsocket<random>`). Commands are `set_property pause`, `volume`, `seek`,
    `screenshot-to-file`, and so on (`Lively/Core/Wallpapers/VideoMpvPlayer.cs`).
  - Lively's own players (WebView2, CEF, WMF, LibVLC): **redirected stdin/stdout carrying newline-delimited JSON** `IpcMessage` objects with a
    numeric `Type` discriminator (`Lively.Models/Message/*.cs`).
    - Commands include `cmd_suspend`, `cmd_resume`, `cmd_volume`, `cmd_close`, `cmd_screenshot`, and `lp_*` property updates.
    - Replies include `msg_hwnd` (the player's window handle), `msg_wploaded`, `msg_console` (log forwarding) and `msg_screenshot`.
  - Players get their configuration through command-line args (for example `--wallpaper-url`, `--wallpaper-property`, `--wallpaper-geometry`, `--wallpaper-audio`),
    parsed with CommandLineParser (`Lively.Player.WebView2/StartArgs.cs`).

### 2.3 Putting a window behind the desktop icons (the WorkerW trick)
All of this lives in `Lively/Core/WinDesktopCore.cs` (`SetupDesktopLayer`, `TryAttachToDesktop`).
1. Find `Progman`. Send it the undocumented message **`0x052C`** (wParam `0xD`, lParam `1`) with `SendMessageTimeout`. Explorer responds by
   splitting the desktop into a separate **WorkerW** behind the icon layer. If that WorkerW already exists, nothing happens.
2. **Classic layout (Win10 and older Win11):** enumerate top-level windows. Find the one that has a `SHELLDLL_DefView` child, and take the
   **next top-level `WorkerW` sibling** after it. That sibling is the wallpaper host.
3. **New layout, the "raised desktop with layered ShellView" (recent Win11 / 24H2):** detected when `Progman` has `WS_EX_NOREDIRECTIONBITMAP`.
   Here the WorkerW is a *child* of Progman, z-ordered under the DefView. The code quotes Microsoft guidance for this case. Lively
   gives the player window `WS_CHILD` and `WS_EX_LAYERED` with alpha 255, parents it to **Progman**, and z-orders it directly below
   `SHELLDLL_DefView`. It then makes sure WorkerW stays the last child, and pushes it to `HWND_BOTTOM` if it is not.
   Comment: Godot fails to take `WS_EX_LAYERED` if you set it after `SetParent`, so the order matters.
4. **Windows 7:** hide the WorkerW and parent to Progman directly.
5. **Positioning:** the player window is first moved to the monitor's absolute bounds. Then `MapWindowPoints` converts those to the parent's
   client coordinates, `SetParent` runs, and the window is moved to the mapped rect. Span mode instead fills the whole WorkerW rect.
6. **Cleanup:** `SystemParametersInfo(SPI_SETDESKWALLPAPER, null)` forces a repaint so a frame from a closed wallpaper does not linger.
   This is skipped in raised mode, where the comment says it would destroy the WorkerW.
7. **Robustness hooks:**
   - A `WinEventHook` (`EVENT_OBJECT_DESTROY`) on the WorkerW's thread notices when Explorer destroys the WorkerW. Lively then re-runs the setup and re-parents, or does a full reset.
   - A `WM_TASKBARCREATED` handler (`Lively/Views/WindowMsg/WndProcMsgWindow`) catches Explorer restarts. It compares the PID of the `Shell_TrayWnd`
     process, because DPI changes also send this message. If Explorer restarts repeatedly inside a timeout window, Lively shows an error and closes the wallpapers.
   - On session unlock, Lively checks that the WorkerW is still valid and that no player has crashed. If either check fails, it resets.
8. **Preparing player windows before parenting:** Lively launches the window off-screen (mpv `--geometry=-9999:0`, WinForms `Location(-9999,0)`),
   minimised, borderless, with `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, and removed from the taskbar. A comment names this as the "TaskView crash fix".
   Finding the window: `WaitForInputIdle`, then poll `EnumWindows` for a window owned by the PID, with a 20 s default timeout
   (`Lively.Common/Extensions/ProcessExtensions.cs`). Special cases: Godot is found by the `Engine` window class. Unity's
   launcher dialog is dismissed by sending `BM_CLICK` to its "Play!" button.

### 2.4 Wallpaper players per type
`Lively/Factories/WallpaperPluginFactory.cs` maps `WallpaperType` and user settings to an `IWallpaper` implementation (`Lively/Core/IWallpaper.cs`:
Show, Play, Pause, Close, Terminate, SetVolume, SetMute, SetPlaybackPos, ScreenCapture, SendMessage, plus Handle, InputHandle and Pid).

| Type | Default player | Alternatives | Pause mechanism |
|---|---|---|---|
| video | `VideoMpvPlayer` (mpv) | WMF (WPF MediaElement), LibVLC, `vlc.exe` | mpv `pause` property. The `vlc.exe` player's Pause is a `//todo` no-op. |
| gif, picture | mpv (GIFs get `--scale=nearest`) | LibVLC; `PictureWinApi` (sets the real Windows wallpaper through `IDesktopWallpaper` COM and restores the old one on close) | mpv pause |
| web, webaudio, url | `WebWebView2` → `Lively.Player.WebView2.exe` | `WebCefSharpProcess` | See below. |
| videostream | mpv + yt-dlp (`--ytdl-format` chosen by a quality setting), only if `plugins/mpv/youtube-dl.exe` exists | otherwise the web player loads the YouTube embed | |
| app, unity, godot, bizhawk | `ExtPrograms` (launches the `.exe` with the `Arguments` from `LivelyInfo`) | none; blocked when running as MSIX | **None.** The Pause/Play bodies are commented-out attempts (DebugActiveProcess, NtSuspendProcess, thread suspend). Volume is set through the per-app volume mixer. |

- **Web pause trick:** on suspend, the WebView2 and CEF players find Chromium's `Intermediate D3D Window`, get the GPU/render subprocess PID from it,
  and call **`DebugActiveProcess` on it**. Attaching a debugger freezes that process. Resume calls `DebugActiveProcessStop` from the same thread. The player then ignores the
  resulting "Unresponsive" `ProcessFailed` event. It also pauses `<video>` elements and calls `livelyWallpaperPlaybackChanged` in JS
  (`Lively.Player.WebView2/Form1.cs`, `Extensions/WebView2/CoreWebView2Extensions.cs`).
- **WebView2 details:**
  - Launch flags: `--autoplay-policy=no-user-gesture-required` and `HardwareMediaKeyHandling` disabled (keeps wallpapers out of SMTC).
  - Context menu and accelerator keys are disabled. Popups open in the default browser. Downloads are cancelled.
  - On multi-monitor setups, `RasterizationScale` is forced through reflection, because a child of WorkerW does not pick up the right DPI.
  - Each arrangement and screen gets its own user-data folder. A comment says a shared renderer process can start paused (`Lively/Factories/WebView2UserDataFactory.cs`).
- **Loaded signal:** web players report `msg_wploaded` after `NavigationCompleted`. Core waits another 1 s before it allows pause, so page transitions can finish.
  mpv has no ready signal, so the code applies properties and then does a fixed `Task.Delay(69)` (a "Todo" comment admits this).
- **Input forwarding:**
  - A hidden window registers **Raw Input** for mouse and keyboard with `RIDEV_INPUTSINK`, so it receives input even when not foreground.
  - When the foreground window is the desktop (Progman or WorkerW), core converts the cursor position to display-local or span-local coordinates and **`PostMessage`s**
    synthetic mouse and keyboard messages to the wallpaper's `InputHandle`.
  - For web players, `InputHandle` is Chromium's inner `Chrome_WidgetWin_1`. For apps it is the main window (`WinDesktopCore.cs` + `Lively.Common/Helpers/InputUtil.cs`).

### 2.5 Pause / resume policy
`Lively/Core/Suspend/Playback.cs` runs a **500 ms polling DispatcherTimer**. The code comments that it chose polling over `EVENT_OBJECT_LOCATIONCHANGE` hooks because they are too noisy and unreliable.
- **System-state pause (checked first):** a screensaver running in process mode, the user's "always paused" choice, a locked session (`SessionSwitch` events,
  plus checking for a `LockApp` foreground window at startup), an RDP session (optional), running on battery (optional; `GetSystemPowerStatus`), and battery saver on (optional).
- **App rules:** a list of process names. If one of them is in the foreground, or visible, depending on the algorithm, wallpapers pause.
- **Algorithms (`ProcessMonitorAlgorithm`):**
  - `foreground`: look only at `GetForegroundWindow`. The display counts as "covered" if that window is maximised or covers at least 95% of the working area.
  - `all`: any visible top-level window covers its display.
  - `grid` (**default**): split each display's working area into 50 px tiles and mark the tiles covered by visible windows. If only 5% or fewer
    tiles stay uncovered, treat the display as covered. A maximised window short-circuits this check (`Lively.Common/Helpers/WindowUtil.cs`).
    Visible windows exclude cloaked, layered or transparent, and minimised windows. Some desktop window classes are also excluded (`Lively.Common/WindowClassExclusions.cs`).
  - `gamemode`: use `SHQueryUserNotificationState`, and pause only on `QUNS_RUNNING_D3D_FULL_SCREEN`.
- **Scope:** `perdisplay` pauses only the covered monitor. `all` pauses every wallpaper if any display is covered. Span requires all displays to be covered;
  duplicate is always treated as `all`. Audio rules: "audio only on desktop", and which display's wallpaper is allowed to make sound.
- `DeferPlayback()` gives a disposable scope that suppresses changes while displays are reconfigured.

### 2.6 Multi-monitor and arrangements
- **`DisplayManager`** (`Lively/Core/Display/DisplayManager.cs`):
  - Enumerates monitors with `EnumDisplayMonitors` / `GetMonitorInfo` and refreshes on `WM_DISPLAYCHANGE`.
  - Monitor identity (`Equals`) is the **device-interface ID** from `EnumDisplayDevices`.
  - Fallback ID: a SHA-256 of the bounds with a `LOCALDISPLAY` / `REMOTEDISPLAY` prefix.
- **`per`** (default): one player per screen. When a screen disappears, its wallpaper is disposed and remembered in a "disconnected" list, then
  restored if the same monitor ID comes back.
- **`span`:** one player sized to the virtual-screen / WorkerW rect. On display changes Lively only resizes it.
- **`duplicate`:** one player instance per screen, all playing the same file. Non-primary screens are muted, and every copy is seeked to 0 to sync them.
  A new screen gets a new instance.
- Restoring after reboot: `WallpaperLayout.json` holds a list of (display, LivelyInfo folder) pairs.

### 2.7 Screensaver
- **Built-in idle timer:** `WinDesktopCore` polls `GetLastInputInfo`. It skips starting if an exclusive-fullscreen app is running or an SMTC media
  session is playing. Optionally it also skips if any audio session belongs to a process that is not a wallpaper (`SystemIdleUtil`).
- **`ScreensaverService`** has two modes:
  - **process mode** opens topmost borderless `WallpaperPreview` windows, one per screen, or one spanning window. They show either the current wallpaper layout
    or a separate screensaver layout (`ScreenSaverLayout.json`). Screens without a wallpaper get black `BlankWindow`s.
  - **dwmThumbnail mode** shows a topmost window with a **live DWM thumbnail of Progman**. This reuses the running wallpaper without a second player (clever).
- Other behaviour:
  - An optional 10 s fade-in, which the user can cancel with input.
  - The cursor is moved off-screen.
  - Raw-input listeners stop it.
  - An optional lock on resume after a grace period.
  - Any display change stops it.
- **Windows `.scr` integration:** `Lively.Utility.Screensaver` parses the standard `/s`, `/p <hwnd>` and `/c` args. It either launches `Lively.exe screensaver --show`
  or `--showExclusive` (the latter starts core in a screensaver-only mode that quits afterwards), or activates the Store app through `ApplicationActivationManager`.
  Preview mode parents into the control-panel preview hwnd, but only on single-monitor setups.

### 2.8 Storage format
- **App data:** `%LOCALAPPDATA%\Lively Wallpaper\` holds `Settings.json`, `WallpaperLayout.json`, `AppRules.json`, `ScreenSaverLayout.json`,
  `MusicAppExclusionRules.json`, `WeatherSettings.json`, and `Tokens.dat` (the gallery login, probably DPAPI-protected since `ProtectedData` is referenced *(inference)*).
  Folders: `logs/`, `temp/`, `Screenshots/`, `WebView2/`, `Cef/`, `Mpv/`, `Themes/`, `ML/Midas/`. All files are plain Newtonsoft JSON (`JsonStorage<T>`).
- **Library root:** the `WallpaperDir` setting (default `%LOCALAPPDATA%\Lively Wallpaper\Library`) contains:
  - `wallpapers/<random-folder>/` for installed wallpapers,
  - `SaveData/wptmp/` for staging,
  - `SaveData/wpdata/<folder>/<screenIndex|span|duplicate>/LivelyProperties.json` for **per-screen copies of customisation values**.
    The original file is copied on first use, and later edits go to the copy (`Lively/Factories/LivelyPropertyFactory.cs`).
- **Per-wallpaper folder:**
  - `LivelyInfo.json` (`Lively.Models/LivelyInfoModel.cs`) has these fields: AppVersion, Title, Desc, Author, License, Contact, Thumbnail, Preview (clip),
    `Type` (enum: app, web, webaudio, url, bizhawk, unity, godot, video, gif, unityaudio, videostream, picture, heic), FileName, `Arguments`,
    `IsAbsolutePath` (true means FileName points outside the library, for example "set this video I dragged in"), Id (gallery), Tags, and Version.
  - Optional files: `LivelyProperties.json`, and `LivelyInfo.loc.json` / `LivelyProperties.loc.json` for localisation.
  - Media wallpapers without their own properties file fall back to a default mpv property file in `Mpv/`.
- **Package format:** a `.zip` counts as a Lively package if it contains `LivelyInfo.json` (`Lively.Common/FileTypes.cs`).

## 3. Modules

| Project / folder | Responsibility | Key files |
|---|---|---|
| `Lively/` (core) | Single-instance WPF host, DI, startup | `App.xaml.cs`, `AppInitializer.cs` (creates dirs, extracts bundled wallpapers and themes) |
| `Lively/Core/` | Desktop layer and wallpaper lifecycle | `WinDesktopCore.cs`, `IWallpaper.cs`, `IDesktopCore.cs` |
| `Lively/Core/Wallpapers/` | One `IWallpaper` class per player | `VideoMpvPlayer.cs`, `WebWebView2.cs`, `WebCefSharpProcess.cs`, `ExtPrograms.cs`, `PictureWinAPI.cs`, `VideoLibVlcPlayer.cs`, `VideoVlcPlayer.cs`, `VideoWmfProcess.cs`, `DwmThumbnailPlayer.cs` |
| `Lively/Core/Suspend/` | Pause and resume policy | `Playback.cs`, `PlaybackDeferrer.cs` |
| `Lively/Core/Display/` | Monitor enumeration and identity | `DisplayManager.cs` |
| `Lively/Core/Watchdog/` | Talks to the watchdog process | `WatchdogProcess.cs` |
| `Lively/RPC/` | gRPC service implementations | `WinDesktopCoreServer.cs`, `UserSettingsServer.cs`, `CommandsServer.cs`, `DisplayManagerServer.cs`, `AppUpdateServer.cs` |
| `Lively/Services/` | Screensaver, tray, UI launcher, settings, taskbar theming | `ScreensaverService.cs`, `Systray.cs`, `RunnerService.cs`, `UserSettingsService.cs`, `TranslucentTBService.cs` |
| `Lively/Commandline/` | Handles CLI verbs forwarded over gRPC | `CommandHandler.cs` |
| `Lively/Factories/` | Player selection, property copies, WebView2 profiles | `WallpaperPluginFactory.cs`, `LivelyPropertyFactory.cs`, `WebView2UserDataFactory.cs` |
| `Lively/Views/` | Helper WPF windows | `WindowMsg/RawInputMsgWindow`, `WindowMsg/WndProcMsgWindow`, `WallpaperPreview`, `DwmThumbnailWindow`, `BlankWindow`, `DebugLog`, `WindowCoverageDebugOverlay` |
| `Lively.Common/` | Shared helpers, P/Invoke, constants, CLI verb definitions, library factory | `Constants.cs`, `CommandlineArgs.cs`, `FileTypes.cs`, `Factories/WallpaperLibraryFactory.cs`, `Helpers/WindowUtil.cs`, `Helpers/InputUtil.cs`, `Helpers/Shell/DesktopUtil.cs`, `Helpers/Pinvoke/*`, `Com/IDesktopWallpaper.cs`, `Extensions/ProcessExtensions.cs` |
| `Lively.Common.Services/` | Data feeds shared by the players and UI | `NAudioVisualizerService.cs`, `HardwareUsageService.cs`, `NpsmNowPlayingService.cs`, `GithubUpdaterService.cs`, `HttpDownloadService.cs` |
| `Lively.Models/` | DTOs, enums, IPC messages, LivelyProperties control models | `LivelyInfoModel.cs`, `SettingsModel.cs`, `DisplayMonitor.cs`, `Message/*`, `LivelyControls/*`, `Enums/*` |
| `Lively.Grpc.Common/` | `.proto` contracts | `Proto/wallpaper.proto`, `settings.proto`, `display.proto`, `commands.proto`, `update.proto` |
| `Lively.Grpc.Client/` | Typed gRPC clients for the UI and CLI | `WinDesktopCoreClient.cs`, `UserSettingsClient.cs`, `CommandsClient.cs`, `DisplayManagerClient.cs` |
| `Lively.UI.WinUI/` | WinUI 3 control panel | `App.xaml.cs`, `Views/MainWindow.xaml`, `Views/Pages/*` (Library, AddWallpaper*, ControlPanel, Settings/*, Gallery/*, DepthEstimate…), `Views/LivelyProperty/LivelyPropertiesView.xaml` |
| `Lively.UI.Shared/` (shproj) | ViewModels shared by the UI | `ViewModels/LibraryViewModel.cs`, `CustomiseWallpaperViewModel.cs`, `DepthEstimateWallpaperViewModel.cs`, `ControlPanel/*`, `Settings/*`, `Gallery/*` |
| `Lively.Gallery.Client/` | HTTP client for the online wallpaper gallery (login, subscriptions, search) | `GalleryClient.cs`, `JsonTokenStore.cs`, `SearchQueryBuilder.cs` |
| `Lively.ML/` | MiDaS monocular depth estimation through ONNX Runtime | `DepthEstimate/MiDaS.cs` |
| `Lively.Player.WebView2/` | WinForms host for WebView2 wallpapers; implements the JS API | `Form1.cs`, `StartArgs.cs`, `Extensions/WebView2/CoreWebView2Extensions.cs` |
| `Lively.Player.CefSharp/` | Same role, using CefSharp (legacy/alternative) | `Form1.cs`, `StartArgs.cs` |
| `Lively.Player.Vlc/` | LibVLCSharp WinForms player | `Form1.cs` |
| `Lively.Player.Wmf/` | WPF `MediaElement` player | `MainWindow.xaml.cs` |
| `Lively.Utility.Watchdog/` | Kills orphaned players if core dies | `Program.cs` |
| `Lively.Utility.Screensaver/` | Tiny `.scr` shim that forwards to core | `Program.cs` |
| `Lively.Utility.Commandline/` | Standalone CLI; validates args, then forwards the raw argv over gRPC | `Program.cs` |
| `Lively.Utility.ConsoleDemo/` | Sample gRPC client | `Program.cs` |
| repo `schemas/` | JSON Schema for `LivelyProperties.json` | `schemas/livelyPropertiesSchema.json` |
| repo `src/installer/` | Inno Setup scripts | `Script_x64.iss` |

## 4. User features

- **Wallpaper types:**
  - Video (mkv/mov/mp4/webm/ogv…), GIF, and pictures (jpg/png…). HEIC is present but commented out.
  - Web: a local `.html` project, or a URL. Shadertoy URLs get special handling: the embed is loaded and its GUI hidden.
  - YouTube/streams: through mpv + yt-dlp with a quality preset, or through the YouTube embed.
  - Apps: any `.exe`, with Unity and Godot special-cased. There is also a `bizhawk` emulator type.
  - "webaudio" and "unityaudio": audio-reactive variants.
  - There is **no dedicated GLSL shader runtime**. Shaders come either from Shadertoy through the browser, or from WebGL in HTML *(inference from the code paths)*.
- **Adding and importing:**
  - Drag-and-drop or a file picker. A media file becomes a library entry with `IsAbsolutePath=true`.
  - A Lively `.zip` is extracted into the library and is not auto-applied.
  - Export or share a wallpaper as a `.zip`. Media files get packaged with their metadata (`LibraryViewModel.cs`).
  - Create/edit metadata pages (`AddWallpaperCreate/Data`).
  - Bundled default wallpapers are extracted on first run and on version bumps.
- **Customisation (LivelyProperties):**
  - The wallpaper ships a `LivelyProperties.json`. It is a map from name to a control: slider, textbox, dropdown, folderDropdown, button, label, color, or checkbox.
  - The UI renders these as controls. Edits are written to the per-screen copy and pushed live over gRPC as `lp_*` messages.
  - Web players deliver them through the JS global `livelyPropertyListener(name, value)`. All saved values are replayed on load.
  - For mpv, the control **name is the mpv property**, so a slider named `saturation` sets mpv's `saturation`. That is how the video filters work.
  - A scaler dropdown maps to mpv `keepaspect` / `panscan` / `video-unscaled`.
  - A "restore default" button re-applies the defaults. There is an eyedropper for colours.
- **Audio visualisation:** WASAPI loopback capture of the chosen output device, then an FFT (MathNet), then 128 bins smoothed over time and across neighbouring bins.
  The result is pushed to `livelyAudioListener(array)` in the page. It is enabled by `--audio` in `LivelyInfo.Arguments`, which the player remaps to `--wallpaper-audio`.
  (`NAudioVisualizerService.cs`)
- **System info in wallpapers:** `--system-information` enables `livelySystemInformation(json)`, sent about once a second. It carries CPU, RAM, network up/down and GPU-3D
  usage from Windows performance counters. `--system-nowplaying` enables `livelyCurrentTrack(json)`, built from NPSM media sessions and including album art
  as base64. `--pause-event` enables `livelyWallpaperPlaybackChanged`.
- **Playlists:** **not implemented** in this code. The only trace is a localized string, `TitlePlaylist`, that nothing uses. The closest feature
  is `setwp --file random`, which picks a random library wallpaper per screen and avoids repeats.
- **Command-line interface** (`Lively.Common/CommandlineArgs.cs`):
  - `app --showApp/--showTray/--showIcons/--volume (0-100 or ±)/--play/--startup/--shutdown/--restart/--layout per|span|duplicate`
  - `setwp --file <folder|media|random> --monitor N`
  - `closewp --monitor N|-1`
  - `seekwp --value [+/-]pct`
  - `setprop --property key=value`
  - `screensaver --show/--showExclusive/--preview/--configure/--fadeIn`
  - `screenshot --file x.jpg --monitor N`
  The same verbs work when passed to `Lively.exe` itself.
- **Screensaver:** the current wallpaper or a separate layout, fade-in, lock-on-resume, and a real Windows `.scr` entry (see 2.7).
- **Performance settings:** the pause algorithm (foreground, all, grid, gamemode), per-display versus all, app rules, battery and battery-saver pause, remote-desktop pause, and audio only on desktop.
- **Other features:**
  - Mouse and keyboard interaction with wallpapers (input forwarding).
  - Hide desktop icons: sends `WM_COMMAND 0x7402` to DefView.
  - Start with Windows.
  - Set the real Windows wallpaper or lock screen to a screenshot of the live wallpaper.
  - Taskbar theming, TranslucentTB-style: clear, blur, fluent, or an accent colour averaged from the wallpaper, applied through `SetWindowCompositionAttribute` on a 500 ms timer.
  - App themes and backgrounds.
  - A tray menu.
  - GitHub auto-updater with release channels.
  - A debug log window and a window-coverage debug overlay.
  - Weather settings (OpenWeatherMap key constant).
- **Depth (ML) wallpapers:** MiDaS ONNX estimates a depth map from a photo. Lively copies a bundled HTML template and writes `image.jpg` and `depth.jpg` into it, which gives a parallax web wallpaper.
- **Online gallery:** login, subscribe/download, report, restore subscriptions, manage account (`Lively.Gallery.Client`, `Views/Pages/Gallery/*`).

## 5. Notable design choices and lessons for zmural

**Clever / worth borrowing (as ideas):**
- **Out-of-process players with a tiny, uniform contract:** start, get HWND, set parent, then pause, resume, volume, seek, screenshot and properties. A crashing web page or
  game cannot take down the manager, and adding a player means one class plus one factory case. A **watchdog** process cleans up if the manager dies.
- **Reusing mpv as-is:** mpv already covers video, GIF, pictures, streams (yt-dlp), hardware decode, filters, and a JSON IPC. Mapping property names straight to mpv
  properties gets you "customisation" almost for free.
- **Grid-coverage heuristic** for deciding when a monitor's wallpaper is hidden. It is cheap, works per monitor, and ships with a debug overlay.
- **Freezing Chromium's GPU process with `DebugActiveProcess`** to get a truly zero-cost pause for web wallpapers.
- **DWM-thumbnail screensaver:** reuses the running wallpaper instead of spawning a second copy.
- **A single gRPC pipe as the public API:** the UI, the CLI and the `.scr` shim are all thin clients. The UI can be killed to save memory.
- **Per-screen copies of the property file:** the pristine defaults stay untouched, and different monitors can have different settings.
- **Handles the Win11 24H2 "raised desktop" layout**, plus Explorer-restart and WorkerW-destroyed recovery.

**Heavy / fragile:**
- **Stack sprawl:** five UI and runtime stacks (WPF core, WinUI 3 UI, WinForms and .NET Framework 4.7.2 players, netstandard libraries), two web engines,
  and four video backends, several of them partly deprecated (`DepreciatedException`, `//todo` Pause in VLC). The install is large *(inference)*.
- **Timing hacks:** fixed delays (`Task.Delay(69)`, a 1 s post-load wait, a 1 s wait after unlock) and 1 ms polling loops to find windows by PID,
  with a 20 s timeout.
- **App wallpapers cannot be paused at all**, so every commented-out suspend approach failed for them. Expect games-as-wallpaper to keep burning GPU.
- **Everything polls:** playback every 500 ms, taskbar every 500 ms, and performance counters every second.
- **Relies on undocumented Explorer behaviour** (`0x052C`, WorkerW z-order), so every major Windows update is a risk. The code carries three layout branches.
- **Pausing through the debugger API** is clever, but it could confuse security tools or anti-cheat *(inference)*, and it has to run on the thread that attached.
- The `.scr` shim and MSIX paths add special cases: no app wallpapers under MSIX, and a different activation path.
- JSON over stdin with a numeric `Type` enum is simple, but the schema is not versioned.

**Windows tricks zmural must reimplement itself:**
1. Progman `0x052C` → find the WorkerW (classic sibling layout, *and* the 24H2 child-of-Progman layout with `WS_EX_LAYERED` + z-order under DefView).
2. Reparent and position with `SetParent` + `MapWindowPoints` + `SetWindowPos`. Clear stale frames with `SPI_SETDESKWALLPAPER`, but not in raised mode.
3. Recover from Explorer restarts (`TaskbarCreated` + PID check) and from WorkerW destruction (a WinEvent hook on `EVENT_OBJECT_DESTROY`).
4. Tame player windows: create them off-screen or minimised, add `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, strip borders, and remove them from the taskbar and Alt-Tab.
5. Monitor enumeration with a stable ID (device interface path), handling `WM_DISPLAYCHANGE`, and per-monitor DPI for child windows.
6. Occlusion detection: enumerate visible top-level windows, skip cloaked (`DWMWA_CLOAKED`) and minimised ones, compute coverage, and use `SHQueryUserNotificationState` for fullscreen D3D.
7. Raw Input with `RIDEV_INPUTSINK`, then `PostMessage` mouse and keyboard events to the wallpaper when the desktop is in the foreground.
8. Power state (`GetSystemPowerStatus`, battery saver), session lock and RDP (`WTS`/SessionSwitch), and idle time (`GetLastInputInfo`).
9. WASAPI loopback + FFT for visualisers. SMTC/NPSM for now-playing. Performance counters or PDH for CPU, GPU and network.
10. `IDesktopWallpaper` COM for setting or restoring the static wallpaper. `SHGetSetSettings` / DefView `0x7402` for desktop icons. A DWM thumbnail for a cheap mirror.
11. The screensaver `.scr` argument protocol (`/s`, `/p hwnd`, `/c`).
