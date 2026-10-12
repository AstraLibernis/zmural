# zmural architecture

How zmural is put together, the principles behind it, and the full feature plan. For what works today, see the README's [What it does](../README.md#what-it-does) and [MILESTONES.md](MILESTONES.md).

## Design principles

1. **Game-first.** Fullscreen means pause, by default. No debugger attach, no DLL injection, no drivers, no hooks into other processes. Nothing an anti-cheat could flag.
2. **Hidden costs nothing.** A paused wallpaper renders zero frames. A stopped one has no process at all.
3. **Crash-contained.** Every wallpaper runs in its own process. A broken web page or video file can't take the manager down.
4. **Thin edges, one brain.** One daemon makes every decision. Everything else (renderers, desktop integrations, CLI) is a small, replaceable client; the settings window is a thread in zmural.
5. **Event-driven, not polling.** React to OS events and coalesce them, with a slow poll only as a safety net. (Not yet true everywhere: on Linux the battery, lock, GameMode and power-profile state is read once a second.)
6. **Secure by default.** Control goes over per-user local sockets or pipes, never TCP. Updates will be signed. Wallpapers should get no more access than they need. **Today that is only partly true;** see [Security](../README.md#security) for exactly where it falls short.

## Overview

```
            ┌────────────┐   ┌──────────┐   ┌──────────┐
            │  Settings  │   │   CLI    │   │   Tray   │
            └─────┬──────┘   └────┬─────┘   └────┬─────┘
                  └──── control protocol ────────┘
                  (Unix socket / named pipe, per-user)
                               │
                     ┌─────────▼─────────┐
                     │      zmural      │  policy, library, playlists,
                     │   (the daemon)    │  pause rules, layout, routing
                     └──┬────────────┬───┘
          renderer      │            │      display protocol
          protocol      │            │
     ┌──────────────────▼──┐     ┌───▼──────────────────────────┐
     │ renderers (1/wallp.)│     │ display hosts (1/desktop)    │
     │  video  (libmpv)    │     │  Windows: WorkerW host       │
     │  image              │ ──► │  Linux:   layer-shell client │
     │  web (WebView2 /    │     │           KDE Plasma plugin  │
     │       WebKitGTK)    │     │           GNOME extension    │
     └─────────────────────┘     └──────────────────────────────┘
```

### The daemon (`zmural`)
- The only process with opinions. It owns the library, settings, playlists, pause policy, per-monitor layout, and which renderer feeds which monitor.
- It routes frames and **never touches pixels** (waywallen's key idea).
- Renderers never outlive it. On Windows they live in a kill-on-close Job Object, so Windows itself ends them if the daemon dies, and a tiny watchdog then restores the normal wallpaper (Lively's key idea). On Linux each renderer exits when its socket to the daemon closes, and the display host keeps the last background until a new zmural connects.

### Renderers
- One process per active wallpaper, shared across monitors when possible. A renderer is zmural started again in its renderer mode, not a separate program.
- Built in, all of them: video and pictures (libmpv) and web pages. zmural never loads a renderer it didn't ship, and the renderer protocol is private to it (see [Security](../README.md#security)).
- A still image renders once and then sleeps; a video or a page renders until it is paused.
- A small, uniform command set: *init, add/remove surface, play, pause, set-volume, stop*, and *set-property* for a wallpaper's properties.

### Display hosts: putting pixels behind the icons
The one part that has to differ per OS. zmural uses the cheapest correct method on each:

**Linux: shared GPU buffers (DMA-BUF), zero copy**
- The renderer draws into a pool of GPU buffers, and the daemon forwards their handles plus explicit sync fences to the display host.
- The host shows the buffer and signals when it's done. Nothing is ever copied through the CPU.
- The two sides negotiate formats up front, and fall back to linear or host-visible memory on hybrid-GPU laptops.
- Hosts:
  - a **layer-shell** client for Sway, labwc, Wayfire, Niri and COSMIC (River is untested; Hyprland 0.56 is tested nested in a headless KWin): zmural started again as `zmural --layer-shell`, by zmural itself. It lives as long as zmural does, is started again if it dies, and only one runs per display,
  - a **KDE Plasma 6** wallpaper plugin and a **GNOME Shell** extension, both vendored from waywallen-display and installed by zmural itself.

**Windows: window parenting under WorkerW, composited by DWM**
- The host asks Explorer to create the desktop's WorkerW layer.
- It parents each renderer's borderless, tool-style window behind the desktop icons. It handles both the classic layout and the Windows 11 24H2 "raised desktop" layout.
- DWM composites the window directly, so again there is no copy.
- It recovers automatically when Explorer restarts or recreates the WorkerW.
- Planned: transitions by cross-fading two layered child windows, and shared D3D11 textures for effects that need them (neither exists yet).

**Fallback:** on Linux, if no live host is available, zmural sets a still frame as the desktop's own wallpaper through the XDG wallpaper portal. On Windows, when zmural stops, it repaints the desktop so the normal wallpaper shows again.

### Pausing, done cheaply
- **Windows:**
  - Listens for foreground, minimise, move and show events, coalesced into one re-check.
  - Coverage is estimated with a coarse tile grid per monitor, where a maximised window short-circuits the check. Cloaked and minimised windows are skipped.
  - Fullscreen games are detected through the shell's own "running fullscreen D3D" state.
- **Linux:**
  - Display hosts report the windows on their monitor: the layer-shell host through wlr-foreign-toplevel, the KDE plugin through KWin's task model. They never filter; the daemon decides. On Sway, zmural reads Sway's IPC instead, which also knows which workspace is showing and where windows are (for the "covered" rule and the app rule); on Niri, its IPC says which program is in front. On Hyprland, and on Wayfire with its `ipc` and `ipc-rules` plugins on, zmural reads their IPC the same way (Wayfire without them: the log says which to turn on).
  - On KDE Plasma, a small KWin script zmural loads reports which program is in front, for the "one of your apps" rule; on Sway, Niri, Hyprland and Wayfire, their IPC does.
  - GameMode, logind, UPower and power-profiles-daemon provide the game, session, battery and power-profile state over D-Bus.
- **Web wallpapers** are paused with the engine's **official** suspend API (WebView2 `TrySuspendAsync` on Windows), not by attaching a debugger to the browser process.

### Protocols
There are three wire protocols. The control and renderer protocols are plain Zig types (`src/protocol/`): one shared framing, and the encoder and decoder for every message are derived from the type at compile time, so the two ends can't drift apart. There is no separate schema file or code generator. The Linux display protocol is waywallen-display-v1, so that waywallen-display's KDE plugin and GNOME extension work unchanged; zmural's codec for it is checked byte for byte against waywallen's own C codec.

| Protocol | Between | Linux transport | Windows transport |
|---|---|---|---|
| control | UI / CLI / tray ↔ daemon | Unix socket in `$XDG_RUNTIME_DIR` | named pipe, current-user ACL |
| renderer | daemon ↔ renderer | Unix socket + fd passing | named pipe + handle duplication |
| display | daemon ↔ display host | Unix socket + DMA-BUF / sync fds (waywallen-display-v1) | in-process (the host lives in the daemon) |

- Every protocol carries a version and a **capability list**. Clients check features, not version strings.
- A **content token**, kept separate from the buffer generation, means "the user changed the wallpaper" (animate a transition) and never "a renderer restarted" (don't animate).

### Monitor identity
The goal is one canonical ID everywhere: a hash of the EDID manufacturer, product code and serial number, falling back to connector name plus resolution, so the same monitor keeps the same settings whatever cable, port or OS you use. Today only the layer-shell host reads the EDID; Windows and the KDE Plasma and GNOME hosts identify a monitor by its connector name.

## Tech stack
- **Zig** for the daemon, the protocols, the renderers' shared library, the settings window, the Windows host and the layer-shell client. One language, easy cross-compilation, a C ABI for everything else.
- **waywallen-display's own C library**, vendored in `third_party/`, which the KDE Plasma plugin and the GNOME extension are built on; zmural speaks its protocol (waywallen-display-v1).
- **libmpv** (an LGPL build, loaded at runtime) for video, images and GIFs on both platforms.
- **WebView2** (Windows) and **WebKitGTK** (Linux, planned) for web wallpapers.
- **UI:** the settings window, one immediate-mode UI shared by both OSes with no UI framework. The pages and widgets are common code; only the drawing backend and the window differ: Direct2D and DirectWrite over the Mica backdrop on Windows, Cairo and Pango in a plain Wayland (xdg-shell) window on Linux. It holds no state of its own and talks to zmural over the control protocol, from a thread of its own inside zmural's process. That is deliberate: if the window breaks, zmural stops with it and you see it, instead of settings quietly not working. The tray icon opens it, and so does `zmural --settings`. It works by keyboard too: Tab moves between the sidebar, the player card and the page, the arrows move in the direction pressed, Enter or Space presses, the Menu key opens a wallpaper's menu, and Escape closes the window.

## Roadmap
The plan, release by release, is in [MILESTONES.md](MILESTONES.md): 0.1.1 makes every control work and be tested with real input; 0.2 is stability on both OSes; 0.3 monitors; 0.4 web wallpapers on Linux and wallpapers that react; 0.5 the renderer sandbox, signed releases and Linux packages; then 1.0. There will be no online gallery: zmural imports wallpapers you download yourself.

## Project layout
```
zmural/
├── build.zig / build.zig.zon     # Zig 0.16
├── src/
│   ├── zmural.zig                # shared library module: @import("zmural")
│   ├── protocol/                 # wire framing + control / renderer / display protocols
│   ├── core/                     # pure logic: layout, coverage, pause policy, monitor IDs, manifest
│   ├── os/                       # thin OS layers (Win32, D-Bus, libmpv, log files, autostart)
│   ├── sdk/                      # what every renderer process shares, per OS
│   ├── daemon/                   # zmural: settings, library, playlists, router, tray;
│   │                             #   shared logic plus runtime_windows.zig / runtime_linux.zig.
│   │                             #   Its other modes: the renderers, the Windows watchdog
│   ├── hosts/
│   │   ├── windows/workerw.zig   # in-process WorkerW desktop host
│   │   └── linux/                # backend selection + the layer-shell host (`zmural --layer-shell`)
│   ├── settings/                 # the settings window (a thread inside zmural): shared pages and widgets, a backend per OS
│   └── cli/                      # zmural-console (command-line client)
├── .github/workflows/ci.yml      # builds and unit-tests both OSes; boots zmural on both
├── third_party/                  # vendored waywallen-display (the KDE plugin and GNOME extension)
├── tools/                        # generators and the Linux test scripts
├── docs/                         # build plan, building, releasing, architecture, wallpaper format
├── notes/                        # dated dev notes: research, audits, test reports
└── reference/                    # upstream source for study (git-ignored, never committed)
```

## The full feature plan

This is the goal, not what works today; [MILESTONES.md](MILESTONES.md) has the current state.

**Wallpapers**
- Video (mp4, mkv, webm, mov…) with hardware decoding, looping, speed and volume.
- Images, including **animated** GIF / WebP / APNG.
- Web wallpapers: an HTML page saved on your computer, WebGL included. They run offline; a web address can't be a wallpaper.
- Per-wallpaper **properties** (sliders, colours, dropdowns, toggles) that update live.
- Audio-reactive wallpapers (a 128-bin spectrum), plus now-playing and system stats (CPU/GPU/RAM/network) exposed to web wallpapers.

**Library**
- Drag and drop files onto a library folder in the settings window to copy them there, or import a wallpaper package (`.zip`).
- Auto-detects `Videos/Wallpapers` and `Pictures/Wallpapers`.
- **Imports Lively wallpaper packages** (reads their `LivelyInfo.json` metadata format).

**Playlists**
- Sequential, shuffle or random, with a rotation interval.
- Per monitor, or synchronised across all monitors.

**Multi-monitor**
- A different wallpaper per monitor, **span** one wallpaper across several, or **duplicate** it.
- Per-monitor fill mode (crop / fit / stretch / centre), alignment and rotation.
- Monitors keep their settings when unplugged and replugged.
- One renderer is shared when several monitors show the same wallpaper.

**Smart pausing.** Each condition maps to an action (*nothing / mute / pause / stop*), scoped to *this monitor* or *all monitors*, with a resume delay.

| Condition | Windows | Linux |
|---|---|---|
| Fullscreen app or game | ✓ | ✓ |
| Maximised window / monitor mostly covered | ✓ | ✓ |
| Any focused window | ✓ | ✓ |
| Specific apps running (app rules) | ✓ | ✓ |
| On battery / power saver | ✓ | ✓ |
| Screen locked / session inactive | ✓ | ✓ |
| Remote session | ✓ | ✓ |
| GameMode active | – | ✓ |
| Another app playing audio (mute only) | ✓ | ✓ |

This is the plan. Today Linux detects "mostly covered" only on Sway, Hyprland and Wayfire, and specific apps on KDE Plasma, Sway, Niri, Hyprland and Wayfire (not GNOME); neither OS detects other apps' audio; [MILESTONES.md](MILESTONES.md) has the current state.

**Also**
- Fade / wipe transitions between wallpapers, and blur-while-paused.
- Mouse interaction with wallpapers.
- Tray menu (pause, mute, next, previous, shuffle, open, quit).
- A full CLI.
- Start at login.
- Screensaver mode (later).

