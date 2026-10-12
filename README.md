# zmural

**A free, open-source live wallpaper manager for Windows and Linux.**

Set videos, pictures and animated GIFs as your desktop wallpaper, with one app and one library on both operating systems. zmural stays out of your way: it pauses the moment a game or fullscreen app takes over, uses almost nothing while it's hidden, and never does anything that could trip anti-cheat.

> **Status: early pre-release (0.1).** zmural works day to day on Windows 11 and on Linux (KDE Plasma, GNOME, Sway and other Wayland desktops), but it has had little time on other people's desktops yet. Download it from [Releases](https://github.com/AstraLibernis/zmural/releases), and please report what breaks. [docs/MILESTONES.md](docs/MILESTONES.md) says exactly what's done on each OS.

## Contents

- [What it does](#what-it-does)
- [What you need](#what-you-need)
- [Install](#install)
- [First run](#first-run)
- [Everyday use](#everyday-use)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Why another one?](#why-another-one)
- [For developers](#for-developers)
- [Acknowledgements](#acknowledgements) · [License](#license)

## What it does

Working today on both Windows and Linux:

- **Wallpapers:** videos (mp4, mkv, webm, mov…), pictures, and animated GIFs, played on the GPU where your system can.
- **A library:** drop files into a `Wallpapers` folder and pick them up with Rescan (on the Welcome page they appear by themselves). `.zip` wallpaper packages import and export, and so do [Lively Wallpaper](https://github.com/rocksdanister/lively) packages.
- **Rotation:** change the wallpaper every few minutes, in order, shuffled or at random.
- **More than one monitor:** each monitor can show its own wallpaper and fill mode. So far this is tested only on Linux, with two virtual screens in a test setup; nobody has tried it with two real monitors yet, on either OS.
- **Adjustments:** speed, brightness, contrast, saturation, gamma and hue for videos (brightness, contrast and gamma for pictures), remembered per wallpaper.
- **Automatic pausing:** when a game or fullscreen app is in front, when the screen is locked, on battery, and more. You choose what each rule does.
- **A settings window, a tray icon** for quick actions, **and a command line** (`zmural-console`) that does everything the window does and more.

**Windows only, so far:** web-page wallpapers (an HTML page saved on your computer; always offline).

**Coming next:** fixes from the first public test (0.1.1), then a view of every monitor in the settings window, then web wallpapers on Linux. [docs/MILESTONES.md](docs/MILESTONES.md) has the plan.

## What you need

**Windows:** Windows 11 on an x86-64 PC. That's all.

**Linux:** an x86-64 PC with a GPU, a **Wayland** session, and one of these desktops:

| Desktop | Needs |
|---|---|
| KDE Plasma | Plasma 6, with Qt 6.8 or newer |
| GNOME | GNOME 48, 49, 50 or 51 |
| Sway, Hyprland, labwc, Wayfire, Niri, COSMIC | any recent version (Sway 1.8 / wlroots 0.16 or newer) |

Debian 13, Ubuntu 25.10 and newer, Fedora 42 and newer, openSUSE Leap 16 and Tumbleweed, Arch, and Pop!_OS 24.04 all meet this today. If your system falls short, zmural tells you what it's missing (in a notification, or for a missing library in its log) and installs nothing itself. The exact library versions are in [docs/BUILDING.md](docs/BUILDING.md#what-zmural-needs-exactly).

## Install

There is no installer: you unpack a folder and run zmural from it.

| | Windows | Linux |
|---|---|---|
| 1. Get it | Download `zmural-<version>-windows-x86_64.zip` from [Releases](https://github.com/AstraLibernis/zmural/releases) and unzip it somewhere it can stay, for example into `%LOCALAPPDATA%\Programs` (it makes a `zmural-<version>-windows-x86_64` folder there). | Download `zmural-<version>-linux-x86_64.tar.gz` from [Releases](https://github.com/AstraLibernis/zmural/releases) and extract it somewhere it can stay, for example into `~/.local/opt` (it makes a `zmural-<version>-linux-x86_64` folder there). Keep its `bin` and `share` side by side. |
| 2. Libraries | Nothing to install. | Install these from your system's package manager (see below). |
| 3. Start it | Run `zmural.exe`. | Run `bin/zmural`. |

Linux libraries, step 2:

```
Fedora:          sudo dnf install mpv-libs mesa-libEGL mesa-libgbm pango cairo
Debian, Ubuntu:  sudo apt install libmpv2 libegl1 libgbm1 libpango-1.0-0 libpangocairo-1.0-0 libcairo2
Arch:            sudo pacman -S mpv mesa pango cairo
openSUSE:        sudo zypper install libmpv2 Mesa-libEGL1 libgbm1 libpango-1_0-0 libcairo2
```

Both downloads are on the [Releases](https://github.com/AstraLibernis/zmural/releases) page, with their SHA-256 checksums. [docs/BUILDING.md](docs/BUILDING.md) makes the same zip or tarball from the source.

## First run

When zmural starts for the first time:

- A **star icon** appears in the tray (next to the clock on Windows; on Linux, if your desktop or bar shows tray icons).
- **Prism**, the wallpaper zmural comes with, shows on your desktop.
- The **settings window** opens on a **Welcome** page. It shows the folders zmural looks in, with a button that opens (and if needed creates) each one.

Put your videos, pictures or GIFs into either folder and they appear on Welcome within a few seconds (elsewhere, use Rescan in the tray menu or `zmural-console rescan`). Click one to make it your wallpaper.

| | Windows | Linux |
|---|---|---|
| Wallpaper folders | `Videos\Wallpapers` and `Pictures\Wallpapers` (wherever Windows keeps your Videos and Pictures, OneDrive included) | `Wallpapers` inside your Videos and Pictures folders |
| zmural also adds itself to | the Start menu, Search, and Settings > Apps | your app menu |
| Start at login | on; turn it off in the settings window, the tray menu, or Windows' own Startup apps | on; turn it off in the settings window, the tray menu, or your desktop's Autostart settings |

On Linux, how the wallpaper reaches the desktop depends on the desktop, and zmural sets it up itself:

- **KDE Plasma:** zmural installs its Plasma wallpaper plugin and switches to it (a notification says so).
- **GNOME:** zmural installs its GNOME Shell extension. **Log out and back in once**; until then your wallpaper shows as a still picture. GNOME also needs the AppIndicator extension to show a tray icon.
- **Sway, Hyprland, labwc, Wayfire, Niri, COSMIC:** zmural shows the wallpaper itself. On Wayfire, turn on its `ipc` and `ipc-rules` plugins so zmural knows which workspace is showing.

Until you pick a wallpaper or change a setting, zmural saves no settings, so the next start is a first run again (Welcome and Prism). It does add itself to your menus and to start at login (and on Linux sets up your desktop's plugin) on the first start.

## Everyday use

**The tray icon:** click it to open the settings window. Right-click it for the quick menu: pause, mute, next, previous, shuffle, rescan the library, start at login, and quit. (Sway's bar can't show an app's menu, so there a right click opens the settings window too; its player card has pause, mute, next and previous.)

**The settings window** has your wallpapers as thumbnails (click one to show it, right-click for more, including which monitor), plus pages for playback, pausing rules and general settings. Its **Customise** section adjusts the wallpaper that's showing. It works by keyboard too: Tab moves between areas, the arrow keys move within one, Enter or Space presses, and Escape closes the window. You can also open it from the app menu, or with `zmural --settings`.

**Screen readers are not supported** in the settings window (it draws its own controls, so a screen reader sees nothing). `zmural-console` does everything the window does, from a terminal.

**From a terminal** (`zmural-console help` lists everything):

```
zmural-console status                    what's showing, on which monitors
zmural-console apply <file>              show a video, picture or GIF
zmural-console apply <file> --monitor 2  give one monitor its own wallpaper
zmural-console next | previous           step through the library
zmural-console rescan                    pick up files you just added
zmural-console pause | play
zmural-console mute | unmute
zmural-console fill crop|fit|stretch|center
zmural-console rotate 15 | off           change the wallpaper every 15 minutes
zmural-console props                     list the wallpaper's adjustments
zmural-console prop brightness -20       change one (prop --reset undoes them all)
zmural-console import Sunsets.zip        unpack a zip of wallpapers into your library
zmural-console export <wallpaper>        pack a wallpaper into a zip
zmural-console autostart on|off|status
zmural-console quit
```

On Linux, run these as `bin/zmural-console` from zmural's folder.

**Wallpapers from a `.zip`:** pick the zip with **Open file** in the settings window, or run `zmural-console import`. zmural checks the zip first and refuses one that could write outside its folder, contains links, or is encrypted or damaged, or is bigger than any wallpaper needs: more than 10,000 files, more than 4 GiB unpacked (a long 4K video is a GiB or two), or, past 256 MiB, more than 20 times the zip's own size, as a zip bomb unpacks; a failed import leaves nothing behind. Lively Wallpaper packages are converted to zmural's own format as they import. Lively wallpapers that run a program, show a web address or play a stream are refused. If you make wallpapers yourself, see [docs/WALLPAPER-FORMAT.md](docs/WALLPAPER-FORMAT.md).

**Where zmural keeps things:**

| | Windows | Linux |
|---|---|---|
| Settings | `%APPDATA%\zmural\settings.toml` | `~/.config/zmural/settings.toml` |
| Log | `%LOCALAPPDATA%\zmural\zmural.log` | `~/.local/state/zmural/zmural.log` |
| Start at login | a registry Run entry (turned off the way Windows' Startup apps does it) | `~/.config/autostart/zmural.desktop` |

`settings.toml` is a commented text file. You can edit it by hand while zmural runs; it picks up the change within a couple of seconds. The settings window is the easier way.

## Updating

1. Quit zmural (tray menu > Quit, or `zmural-console quit`).
2. Unpack the new zip or tarball over the old folder, replacing its files.
3. Start zmural again.

Your settings and library are kept. On KDE Plasma and GNOME, zmural updates its own plugin or extension when it starts; on GNOME the new extension runs from your next login.

## Uninstalling

Use **Uninstall** on the settings window's General page, or run `zmural-console uninstall`. On Windows, Uninstall in Settings > Apps does the same. It stops zmural and removes everything zmural added: its settings, log, thumbnails, start at login and menu entries, and on Linux its Plasma plugin or GNOME extension (your desktop gets its own wallpaper back). Then delete zmural's folder.

**Your wallpapers and their folders are never touched.**

## Troubleshooting

**zmural says it stopped unexpectedly.** The notification includes a line like `zmural 0.1.0 linux crash: 1216a76 10fab48`. To report it, post that line; it's also near the end of zmural's log, which the settings window's General page opens. zmural never sends anything anywhere itself.

**Nothing shows on Linux.** zmural only plays live wallpapers in a Wayland session. On X11, or on a desktop older than the ones under [What you need](#what-you-need), it says what's missing and sets your wallpaper as a still picture instead. The settings window needs Wayland too, so on X11 use `zmural-console`. To see which session you're in, run `echo $XDG_SESSION_TYPE` (`wayland` or `x11`); most desktops let you choose at the login screen, and KDE Plasma 6 and GNOME use Wayland by default.

**"No file picker available" (Linux).** Add folder and Open file use your desktop's file picker through xdg-desktop-portal. KDE Plasma and GNOME have it; on Sway and other minimal desktops install `xdg-desktop-portal` and `xdg-desktop-portal-gtk`. `zmural-console apply` and `import` work without it.

**No tray icon on GNOME.** Install and turn on the AppIndicator extension. The settings window still opens from the app menu.

**"No GPU decoder for H.264 found" (Linux).** zmural plays that video on the CPU instead, which works but uses more power. Fedora and openSUSE leave H.264 and H.265 out of their own Mesa and FFmpeg; on Fedora, RPM Fusion's `mesa-va-drivers-freeworld` and `libavcodec-freeworld` add them. Whether a format decodes on the GPU also depends on your GPU and its driver; [docs/BUILDING.md](docs/BUILDING.md#gpu-video-decoding-on-linux) has the details. zmural checks again each time a video starts, so after installing codecs, the next wallpaper change uses them. zmural never installs codecs or drivers itself.

**A wallpaper doesn't play.** zmural shows a notification saying what was wrong and goes back to the last wallpaper that played (or Prism).

**Windows warns before running zmural.** zmural isn't code-signed yet, so SmartScreen may warn about it.

**Anything else:** the log usually says why. Open it from the settings window's General page, and include it in a report.

## Security

Wallpapers are files people download, so zmural treats them as untrusted. It shows them only with its own built-in players. There are no plugins, no third-party players and no programs as wallpapers, and no wallpaper is given network access. This section lists what protects you today and, just as plainly, what doesn't yet. [docs/MILESTONES.md](docs/MILESTONES.md) tracks the fixes.

**What protects you today**
- **Control is local only.** There is no network port, and clients check that whoever answers really is your zmural before sending anything.
  - *Windows:* a named pipe for your account and session only; its access list names your user.
  - *Linux:* Unix sockets in a folder under `$XDG_RUNTIME_DIR` that only you can open, and the kernel tells each side which user is on the other end; another user's process is refused.
- **Wallpapers run in separate processes**, so a wallpaper's crash never takes zmural down, and none outlives it. (The settings window is the opposite on purpose: it lives inside zmural.)
  - *Windows:* renderers live in a kill-on-close job. zmural checks that each one is the process it started and that it only places its own windows on monitors it feeds, and it strips control characters from anything a renderer logs.
  - *Linux:* each renderer talks to zmural over a socket it was handed at start, which nothing else can connect to, and exits when that socket closes. Control characters in anything logged (a file's name, what a renderer says) are written escaped, so nothing can fake a line of the log.
- **mpv (video and images)** runs without scripts, youtube-dl, your mpv config, or files the media points to. On Windows, device paths such as `\\.\` are refused.
- **Web wallpapers** (Windows only so far) run in WebView2, so the page itself is inside Chromium's sandbox. Dev tools, the context menu, pop-up dialogs, new windows, downloads and permission prompts (camera, microphone, location, notifications) are all blocked.
  - **Every page is offline, and nothing turns that off.** Its browser is pointed at a proxy that doesn't exist (localhost included), and WebRTC may only use proxied connections, so web requests, WebSockets and UDP all fail. A web address (`http://`, `https://`) is refused as a wallpaper, and an older package's `network = true` is ignored.
  - **A page can't leave its own folder:** any navigation to another address is cancelled.
  - **Every wallpaper is kept apart:** each local folder is its own web origin, and every web wallpaper gets its own browser profile (cookies, storage, cache), so one can't read another's data.
  - Property values are checked against the wallpaper's manifest before they are stored or passed to it.
- **Zip imports** run in `zmural-console`, never inside zmural, and are checked before anything is written (see [Everyday use](#everyday-use)). On Windows, unpacked files keep the zip's "downloaded from the internet" mark, so SmartScreen still warns before any program among them runs.
- **Game-safe:** no code injection, no debugger attach, no drivers, no hooks into other processes.

**Known limitations** (2 to 5 and 7 concern web wallpapers, which are Windows-only so far)
1. **Video and image renderers aren't sandboxed.** They run with your normal user rights. On Windows their job only limits what they can do to the user interface (the clipboard, the desktop, display and system settings, logoff); on Linux nothing restricts them. A malicious media file that exploits a bug in the decoder (FFmpeg) could read your files. A real sandbox is planned (0.5; a restricted token or AppContainer on Windows; the Linux design isn't chosen yet).
2. **Web renderers have no job limits at all.** Chromium's sandbox refuses to start inside a job with UI limits (each limit was tested). The *page* is still sandboxed by Chromium, but zmural's web renderer process and the WebView2 browser process run with your normal rights.
3. **A web page can read every file in its own folder and the folders below it.** It is offline, so it has no way to send them anywhere short of getting around the offline mode (4). Keep each web wallpaper in its own folder, and never put an `.html` wallpaper next to personal files.
4. **The offline mode relies on Chromium's proxy settings.** It stops HTTP(S), WebSockets and WebRTC, but it is a configuration, not a firewall rule; a flaw in Chromium could get around it. A sandbox with no network access at all is planned (0.5).
5. **Web pages can play sound on their own.** Wallpapers start muted by default; if you unmute, a page can play audio without a click.
6. **Releases aren't code-signed yet**, and there is no updater. Windows SmartScreen may warn when you run it; on Linux there is no distro package yet. Signed update checks on Windows and distro packages on Linux are planned (0.5).
7. **Browser profiles pile up (Windows):** each web wallpaper you've shown keeps a profile folder under `%LOCALAPPDATA%\zmural\webview2`, with whatever that page stored. Nothing cleans them up while zmural stays installed; uninstalling deletes them.

## Why another one?

The two best free options each cover only half the problem:

| | [Lively](https://github.com/rocksdanister/lively) (Windows) | [waywallen](https://github.com/waywallen/waywallen) (Linux) | **zmural** |
|---|---|---|---|
| Platforms | Windows only | Linux + Wayland only | **Windows + Linux** |
| Playlists / rotation | ✗ (random only) | ✓ | ✓ |
| Battery / power-saver pause | ✓ | ✗ | ✓ |
| Detailed pause rules (per condition, per monitor) | partial | ✓ | ✓ |
| Customisable wallpapers + JS API | ✓ | via plugin | ✓ |
| Zero-copy GPU frames | n/a (window parenting) | ✓ | ✓ |
| Stack | 5 .NET UI/runtime stacks | Rust + C++ modules + Qt 6.10 + custom build tool | **one language, mainstream tooling** |

zmural takes the proven ideas from both and drops the weight. The zmural column is the goal; [What it does](#what-it-does) says what works today, and [notes/parity-2026-09-30.md](notes/parity-2026-09-30.md) compares the three feature by feature.

## For developers

- [docs/BUILDING.md](docs/BUILDING.md): building from source, tests, cross-compiling, and the exact system requirements.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how zmural is put together, its design principles, and the full feature plan.
- [docs/WALLPAPER-FORMAT.md](docs/WALLPAPER-FORMAT.md): making wallpaper packages (`zmural.toml`, properties, the JS API).
- [docs/MILESTONES.md](docs/MILESTONES.md): the plan, release by release, and what works on each OS.
- [docs/RELEASING.md](docs/RELEASING.md): working builds versus released builds, publishing a release, and reading crash reports.
- [docs/CONTROLS.md](docs/CONTROLS.md): every button, menu item and command, and what tests it.
- [docs/WINDOWS-PASS.md](docs/WINDOWS-PASS.md): the by-hand check on a real Windows desktop before each release.

## Acknowledgements

zmural stands on the shoulders of two excellent free projects. We studied both closely, and this design would not exist without them:

- **[waywallen](https://github.com/waywallen/waywallen)** and **[waywallen-display](https://github.com/waywallen/waywallen-display)** by **hypengw** (MIT). The core architecture comes from them: the frame-routing daemon, out-of-process renderers, per-desktop display clients, zero-copy DMA-BUF frames with explicit sync, and the pause-policy model. Any code or protocol definitions adapted from them keep their original copyright notice.
- **[Lively Wallpaper](https://github.com/rocksdanister/lively)** by **rocksdanister** and contributors (GPL-3.0). Most of zmural's Windows behaviour and many of its user features were inspired by Lively: the WorkerW desktop placement, the watchdog, coverage-based and battery pausing, customisable properties, the web-wallpaper API, and span/duplicate layouts. **zmural contains no code from Lively.** It was studied for design only and zmural's implementation is written independently.

zmural is also built with, and thankful for:
- **[mpv](https://mpv.io)** and **[FFmpeg](https://ffmpeg.org)**, which play every video and picture;
- **[Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons)** (Microsoft, MIT), the settings window's icons on Linux, and Microsoft's **WebView2** for web wallpapers on Windows;
- **[Zig](https://ziglang.org)**, the language it is written in;
- **[Hidamari](https://github.com/jeffshee/hidamari)**, whose still-frame fallback on GNOME zmural's follows, and **Inigo Quilez**, whose triangle distance function draws Prism;
- Cairo, Pango, Mesa, Wayland, wlroots, KDE Plasma, GNOME and Qt, which it uses from your system on Linux.

The full notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

GPL-3.0-or-later · Copyright (C) 2026 AstraLibernis

zmural is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See `LICENSE`.

Versions from before the relicensing on 2026-09-28 were released under the MIT License; copies obtained under those terms keep them.

Contributions are welcome under the [Developer Certificate of Origin](https://developercertificate.org/): sign off each commit with `git commit -s`. You keep the copyright on your contribution.
