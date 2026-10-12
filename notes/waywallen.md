# waywallen — reference notes for zmural

Source: `reference/waywallen` (github.com/waywallen/waywallen, MIT, shallow clone at tag v0.4.3, commit `2bdf9af`).
Everything below comes from code I read in that tree. Anything I inferred is marked **(inference)**.
The companion repo `waywallen-display` is **not** in the clone, so what it does is only known from the protocol XML, the daemon's side of the socket, and the README.

---

## 1. Overview

- **What it is:** a live/dynamic wallpaper manager for Linux desktops. The README says it "started life as a Wallpaper Engine plugin for KDE". Ships as an AppImage (x86_64 and aarch64 CI in `.github/workflows/appimage.yml`), on Flathub (`org.waywallen.waywallen`), and as a Nix flake.
- **Languages:**
  - **Rust** for the daemon (`src/`, about 20k lines in `src/*/*.rs`).
  - **C99** for the renderer-side IPC library (`bridge/`).
  - **C++ modules (`.cppm`)** for the renderer plugins and the Qt tool (`plugins/`, `tools/i18n`).
  - **Qt6/QML** for the UI (`ui/`).
  - **Lua 5.4** for plugin "source" logic (`plugins/*/main.lua`), embedded in the daemon via `mlua`.
- **Build system:** [Lito](https://github.com/litocpp/lito) ≥ 0.8.1 is the top-level driver (`lito.toml`, `BUILD.md`). Lito drives Cargo for the daemon: the daemon is declared as a cargo external dependency of `waywallen-ui`. CMake/Ninja are used only inside Lito's dependency providers. Clang 22+ is required because of C++ modules.
- **Main dependencies:**
  - Daemon (`Cargo.toml`): tokio, tokio-tungstenite (WebSocket), prost (protobuf), zbus 4 (D-Bus), ashpd (xdg portals), sea-orm + sqlx-sqlite (DB), mlua (Lua), ash (Vulkan), nix/libc, reqwest (rustls), zip.
  - Renderers: FFmpeg (libavformat, libavcodec, libavutil, libswscale), GBM, the Vulkan loader, and the author's own libraries `wavsen` (video/audio decode+playback), `vvk`, `rstd-*` and `ncrequest`.
  - UI: Qt ≥ 6.10 (Quick, DBus, Protobuf, WebSockets) plus the author's `QmlMaterial` and `QExtra`.
- **Platforms/compositors:** Linux only. **Wayland only in practice**; there is no X11 display backend. X11 only comes up for UI raising in `src/daemon/runtime.rs`. The built-in display backends are in `src/plugin/display_registry.rs`:
  - `kde-plasma`: `spawn = External`, a Plasma wallpaper plugin that Plasma itself loads.
  - `gnome-shell`: `External`, a GNOME Shell extension **(inference from the name, the README and `GnomeDisplaysHelp.qml`)**.
  - `layer-shell`: `Daemon`-spawned `waywallen-layer-shell` binary for Hyprland, Sway, Niri, River and COSMIC. It requires `wlr-layer-shell` and `linux-dmabuf-v4`. The README also lists Wayfire.
  - The README table says auto-pause works everywhere except Sway.
  - Layer-shell is disabled inside Flatpak (`preflight_daemon_backend` → `flatpak_restricted`).

## 2. How it works

### Process model (four kinds of process)
```
 waywallen-ui (Qt/QML) ──WS+protobuf (127.0.0.1:random)──┐
 tray / CLI tools ─────────────D-Bus (Daemon1)───────────┤
                                                          ▼
                                   waywallen (Rust daemon, tokio)
             ┌── Lua source plugins (in-process, mlua) — scan, metadata, remote catalogs
             ├── SQLite catalog + config.toml
   UDS ipc_v3│ (per-renderer temp socket)          UDS display_v1 ($XDG_RUNTIME_DIR/waywallen/display.sock)
             ▼                                                  ▼
  renderer subprocesses (C++/C, one per wallpaper)    display clients (waywallen-display repo:
  waywallen-video-renderer, -image-renderer,          Plasma plugin, GNOME ext, layer-shell bin)
  third-party (open-wallpaper-engine)                 — import DMA-BUF, present behind desktop
```
- **Daemon startup (`src/daemon/bootstrap.rs`)**, in order:
  1. Detect the DE from `XDG_CURRENT_DESKTOP`, `WAYLAND_DISPLAY`, `XDG_SESSION_TYPE` and `FLATPAK_ID` (`display/spawner.rs::detect_de`).
  2. Pick a display backend.
  3. Take the single-instance gate: acquire the D-Bus name. If it's already owned, hand off to the running instance (`system::dbus::acquire_or_handoff`).
  4. Bind `display.sock`.
  5. Scan plugin roots and load `config.toml` and the SQLite DB.
  6. Enumerate GPUs.
  7. Start the long-running tasks: the rotator, plugin update checker, session monitor, GameMode monitor, MPRIS, display endpoint, display-backend supervisor, source loading/scanning, restore, hotplug watcher, and media-probe scheduler.
  8. Bind the WebSocket on `127.0.0.1:<port 0>`, spawn the UI, publish D-Bus `org.waywallen.waywallen.Daemon1`, then start the tray.
- **Shutdown (`daemon/runtime.rs`):** triggered by SIGINT/SIGTERM, the D-Bus connection dropping, or an internal request. It stops renderers in order with a 1 s ack, flushes settings, and emits the D-Bus `ShuttingDown` signal.
- **Display backend supervision (`display/spawner.rs::run_backend`):**
  - Spawns with `--socket` and `WAYWALLEN_SOCKET`.
  - Sets `PR_SET_PDEATHSIG=SIGTERM` so the backend dies with the daemon.
  - Restarts with exponential backoff from 2 s up to 10 s.
  - Captures stderr for error reasons.

### IPC surfaces
| Channel | Peers | Format | Defined in |
|---|---|---|---|
| Control plane | UI ↔ daemon | WebSocket on localhost, protobuf `Request` / `ServerFrame{Response, Event}` with `request_id` correlation and server-push events | `proto/control.proto` (2056 lines), `src/api/websocket*.rs` |
| Bus | tray, scripts, UI discovery ↔ daemon | D-Bus `org.waywallen.waywallen.Daemon1` | `src/system/dbus.rs` |
| Renderer IPC v3 | daemon (server) ↔ renderer (client) | UDS SOCK_STREAM, `[u16 opcode][u16 len]` + 4-byte-aligned positional body + SCM_RIGHTS fds | `protocol/waywallen_ipc_v3.xml`, `bridge/`, `src/wallframe/ipc/uds.rs` |
| Display v1 (protocol version 9) | daemon (server) ↔ display consumer (client) | same framing as above | `protocol/waywallen_display_v1.xml`, `src/wallframe/display/{endpoint,proto}` |

- **D-Bus `Daemon1` methods and properties:**
  - Info: `Version`, `Capabilities` (first entry is `control.v1`; clients feature-check instead of comparing versions), `DisplaySocketPath`, `WsPort`, `CurrentWallpaperId`, `QueueStatus`.
  - Playback: `QueueMode`, `RotationSecs`, `Next`, `Previous`, `Pause`, `Resume`, `Mute`, `Unmute`, `SetShuffle`, `SetRotationInterval`.
  - Wallpapers and displays: `ApplyById`, `ApplyViaPortal`, `Rescan`, `RefreshDisplays`.
  - App and tasks: `OpenUi`, `Quit`, `ListTasks`, `CancelTask`.
  - Signals: `Ready` and `ShuttingDown`.
  - The UI finds the WS port through this interface (`runtime.rs` comment).
- **Codegen:** protocol XML files are Wayland-style but not libwayland. They are turned into C (`bridge/src/ipc_v3.c`) and Rust by the in-repo tool `tools/wayproto-gen` (parser plus `codegen_c.rs` and `codegen_rust.rs`), invoked from `build.rs`.

### How pixels get behind the desktop
1. **Apply:** the user picks a wallpaper (`application/playback/apply.rs`).
   - The item's `wp_type` (for example `video`, `image`, or third-party types) resolves to a renderer through the `[renderers.*]` tables in each `plugin.toml` (`plugin/renderer_registry.rs`).
   - The Lua `wallpaper.apply(entry)` returns `extras` (for example `path`) plus default user properties.
2. **Spawn (`renderer_manager/mod.rs::spawn_for_generation`):**
   - The daemon binds a temporary UDS and runs `<renderer-bin> --ipc <sock> --path <resource> [--<extra> ...]` in its own process group, with `WW_LOG` set.
   - It waits for connect-back. The renderer dying early or timing out becomes an error that includes captured stderr.
   - It sends a typed `init` message carrying the settings key/value list. A user GPU choice (`gpu_drm_dev`) is translated to a render-node path here.
3. **Buffer negotiation (`wallframe/dma/negotiate.rs`):**
   - The renderer sends `ready` (its DRM render node), then `release_syncobj`, then `format_caps` (fourcc/modifier list plus device and driver UUIDs).
   - Each display client sends its `consumer_capabilities` in `register_display`.
   - `pick()` intersects the two sides:
     - Same GPU (checked by Vulkan UUID first, DRM node as fallback): prefers non-linear tiled modifiers.
     - Cross-GPU: falls back to `compat_linear` / host-visible memory.
     - Paths are `optimized_same_device`, `optimized_same_vendor`, `compat_linear` and `compat_cpu_readback`.
     - Formats that fail to import are blacklisted and renegotiated (`buffer_import_failed` → `blacklist_format`).
4. **Frames:**
   - The renderer allocates a pool of DMA-BUF slots (`bridge/src/pool_vulkan.c` or `pool_egl_gbm.c`), renders, and sends `frame_ready` with an acquire `sync_file` and a release point on its timeline syncobj.
   - The daemon **never touches pixels**. It forwards fds (SCM_RIGHTS) to every linked display as `bind_buffers` (once per pool) and `frame_ready` (acquire sync_file + release syncobj).
   - The display imports the DMA-BUF, presents it, and answers `frame_release_armed`.
   - `wallframe/sync/reaper.rs` waits on all consumers' release fences (DRM syncobj) before a slot is recycled. This is explicit sync fan-out.
5. **Composition:** the daemon computes `source_rect`/`dest_rect`, transform and clear colour for each display. The consumer only blits.
   - Layout settings are `FillMode` (Stretched, PreserveAspectFit, PreserveAspectCrop [default], Centered), `Location`, `Align` and `Rotation` (`display/layout.rs`, `display/placement.rs`).
   - The daemon also does inverse pointer mapping, so mouse input from the display is translated into renderer texture space and forwarded (`pointer_*` in both protocols).
6. **Presentation effects are done by the consumer:**
   - Declared through `presentation_capabilities`: blur while paused, and transitions (fade, wipe, grow) when `content_token` changes.
   - The daemon only sends config. This keeps transitions compositor-side and cheap **(inference)**.
- **Reference renderer:** `src/bin/waywallen_renderer.rs` is a minimal Rust/ash Vulkan renderer with 3 slots and RGBA→AB24 that only clears a colour. It works as a protocol reference or test. `waywallen_display_demo.rs` is a matching fake display client.

### Renderers in this repo
- **Video (`plugins/org.waywallen.video/src/entry.cpp`, 1789 lines):**
  - Decode and audio go through `wavsen::video` and `wavsen::audio`.
  - The `hwdec` setting is `auto` (Vulkan → VA-API → software), `vulkan`, `vaapi` or `none`. There is no NVDEC path; the README tells NVIDIA users to use nvidia-vaapi-driver.
  - The manifest comment describes the pipeline: HW decode → software landing frame → swscale to NV12 → GPU NV12→RGBA compute pass into the bridge slot, paced by PTS.
  - Settings: `loop_file`, `fps` (default 30), `resolution` cap (720p to 2160p, never upscales), `render_node`, `volume`, `enable_audio`. Per-wallpaper properties: playback speed 10–400 %, audio toggle, scheme colour.
  - Settings marked `identity = true` force a renderer respawn when changed.
  - hwdec changes apply at the next loop boundary.
  - Pause and play carry a fade duration for audio.
  - The renderer reports the hwdec actually in use as a runtime tag that the UI shows.
- **Image (`plugins/org.waywallen.image`):** decodes with libavformat/libavcodec (`av_image.cpp`) and handles png, jpg, webp, bmp, tiff, avif and gif. **Only the first frame is decoded**; there is a code comment that animation "lands in M5". Activity mode is `on_demand`, so it doesn't render continuously.
- **Wallpaper Engine scene/web:** **not in this repo.** It lives in the third-party plugin `waywallen/open-wallpaper-engine` (README). What this repo provides for it:
  - `RendererDef.extras` passes through keys like `assets` and `external_id` (renderer_manager comment).
  - An MPRIS snapshot is forwarded to renderers (`system/mpris.rs`, `send_mpris`), which **(inference)** serves WE media widgets.
  - PulseAudio PCM capture windows of 4096 frames, 48 kHz stereo, are sent to renderers that subscribe (`system/audio/*`, `audio_window` opcode) for audio-reactive wallpapers.
  - The QR-login flow (`plugin/qr_login.rs`) plus remote subscribe/download messages point to a Steam-Workshop-style source **(inference)**.

### Config and data flow
- **Config:** `$XDG_CONFIG_HOME/waywallen/config.toml` (`settings/paths.rs`). It holds global settings, per-plugin settings, per-display prefs (layout, auto-replay, `last_wallpaper`, alias, active playlist) and canvases (`settings/schema.rs`). It is written by a background writer and flushed on shutdown (`SettingsStore`).
- **Catalog:** SQLite at `$XDG_DATA_HOME/waywallen/waywallen-v2.db` through sea-orm, with migrations in `src/model/migration`.
  - Tables: item, library, tag, item_tag, playlist, playlist_item, source_plugin.
  - FTS search is in `model/fts.rs`; filters are in `proto/filter.proto`.
  - Items keep per-item user-property overrides and a layout override as JSON columns.
- **Scanning:** each Lua source plugin's `scan(ctx)` globs its libraries and returns entries. `model/sync.rs` upserts them. A background `probe/task.rs` scheduler fills in width, height and mtime through libavformat, with cooldowns.
- **Lua `ctx` API** (functions registered in `plugin/source/runtime.rs`): `glob`, `read_file`, `file_exists`, `remove_file`, `remove_dir`, `list_dirs`, `env`, `http`, `json_*`, `html`, `library_meta_get` / `library_meta_set`, `plugin_config`, `probe`, `tr`, `log`, `time`, `random`, and more.
- **Restore:** at startup the last wallpaper for each display (`DisplayPrefs.last_wallpaper`) and the active playlist are re-applied when a display registers. Display hotplug is watched (`application/playback/restore.rs`). `--no-restore` disables this.
- **Logs:** daily rolling logs in `$XDG_STATE_HOME/waywallen/logs/daemon/`, 8 kept (README, `src/logging`).

## 3. Modules

| Path | Responsibility | Key files |
|---|---|---|
| `src/daemon/` | CLI, bootstrap/service wiring, shutdown, UI spawn/raise | `cli.rs`, `bootstrap.rs`, `runtime.rs`, `context.rs` |
| `src/api/` | WebSocket protobuf control plane | `websocket.rs`, `websocket/handlers.rs`, `mapping.rs`, `wire.rs` |
| `src/application/` | Use cases: apply, playlist, queue, navigation, restore, catalog/remote, plugin install/update/reload | `playback/apply.rs`, `playback/restore.rs`, `plugins/update.rs`, `catalog/remote.rs` |
| `src/wallframe/renderer_manager/` | Spawn and supervise renderer processes, the IPC reader/writer, subscriptions, reported state | `mod.rs` (2984 lines), `handshake.rs`, `reader.rs`, `writer.rs` |
| `src/wallframe/routing/` | Renderer→display link table, router (assignment, lifecycle, composition, canvas projection, pause/stop policy, deadlines, health) | `table.rs`, `router/mod.rs` (8580 lines), `router/composition.rs`, `router/auto_policy.rs`, `auto_replay.rs` |
| `src/wallframe/display/` | Display socket endpoint, backend selection/spawning, layout math, canvas placement | `endpoint.rs`, `spawner.rs`, `layout.rs`, `placement.rs`, `proto/codec.rs` |
| `src/wallframe/dma/` | DMA-BUF format/modifier/device negotiation | `negotiate.rs` |
| `src/wallframe/sync/` | DRM syncobj wrappers, release-fence reaper | `drm_syncobj.rs`, `reaper.rs` |
| `src/wallframe/ipc/` | Blocking UDS framing and fd passing for renderer IPC | `uds.rs`, `proto.rs` |
| `src/plugin/` | Plugin manifest scan, renderer and display registries, Lua source runtime, zip installer, updater, i18n, QR login | `renderer_registry.rs`, `display_registry.rs`, `source/runtime.rs`, `installer.rs`, `update.rs` |
| `src/playback/` | Queue modes, rotation timer handle, playlist engine/cursor | `mode.rs`, `rotation.rs`, `playlist/engine.rs`, `playlist/cursor.rs` |
| `src/model/`, `src/catalog/` | SQLite entities, repos, migrations, FTS, filters; wallpaper entry and properties | `model/entities/*.rs`, `model/repo/*.rs`, `catalog/properties.rs` |
| `src/settings/` | TOML schema, store, paths | `schema.rs`, `store.rs`, `paths.rs` |
| `src/system/` | D-Bus, tray (SNI + dbusmenu), session lock, GameMode, MPRIS, PulseAudio capture/observer, autostart and notifications via portals, GPU enumeration | `dbus.rs`, `tray/`, `session.rs`, `gamemode.rs`, `mpris.rs`, `audio/`, `gpu.rs` |
| `src/probe/` | libavformat media probe and stat scheduler | `media.rs`, `task.rs` |
| `src/bin/` | Reference Vulkan renderer and demo display client | `waywallen_renderer.rs`, `waywallen_display_demo.rs` |
| `bridge/` | C99 shared lib for renderers: framing, generated codecs, Vulkan/EGL+GBM DMA-BUF pools, release sync, GPU probes | `include/waywallen-bridge/bridge.h`, `src/pool_vulkan.c`, `src/pool_egl_gbm.c`, `src/sync_release.c` |
| `plugins/` | First-party plugins (manifest + Lua + C++ renderer) and a shared C++ bridge wrapper | `Bridge.cppm`, `org.waywallen.{video,image,wallhaven}/` |
| `protocol/`, `proto/` | Wire schemas (XML for UDS, protobuf for WS) | `waywallen_display_v1.xml`, `waywallen_ipc_v3.xml`, `control.proto`, `filter.proto` |
| `tools/` | `wayproto-gen` code generator (Rust), i18n tooling (C++) | `wayproto-gen/src/{parser,codegen_c,codegen_rust}.rs` |
| `ui/` | Qt6/QML Material UI talking WS+protobuf, plus D-Bus to find the daemon | `qml/Window.qml`, `qml/page/*.qml`, `src/backend.cpp`, `src/daemon_dbus.cpp` |
| `tests/` | Integration tests: display protocol, renderer IPC, syncobj e2e, logging | `display.rs`, `ipc_renderer.rs`, `release_syncobj_e2e.rs` |

## 4. User features

- **Wallpaper types in this repo:** video (mp4, mkv, webm, mov, avi, flv, wmv, mpg, ts, ogv…), static image (png, jpg, webp, bmp, tiff, avif; gif shows its first frame only), and Wallhaven online images. **Scene and web types come only from the third-party open-wallpaper-engine plugin.** The README notes that web wallpapers on NVIDIA need `shared_texture_enabled` turned off.
- **Libraries:**
  - Users add folders per source plugin. Auto-detect finds `~/Videos/Wallpapers` and `~/Pictures/Wallpapers` (or the XDG equivalents), and scans go 2 levels deep (`video/source.lua`).
  - Rescan is available from the UI, the tray and D-Bus.
- **Catalog UI (`ui/qml/page/`):**
  - Pages: Wallpapers grid with a detail panel, Discover (remote sources), Displays, Status, Plugins, Settings, About.
  - Filters: type, tag, content rating, int/string rules; search is FTS-backed.
  - A per-wallpaper "Tweak" sheet edits user properties such as speed, audio and colour, plus a per-wallpaper layout override. Wallpapers can be removed.
- **Remote/Discover:** Wallhaven search, filter, sort and download (`plugins/org.waywallen.wallhaven`). Remote sources can also offer subscribe, QR login and plugin action forms (`control.proto` Remote*/Subscription*/QrLogin*/PluginAction*).
- **Playlists:** create and edit them. Each has a mode (sequential, shuffle or random), an interval, and `synchronized_selection` (all targets show the same item, or each gets its own cursor). A playlist can be attached per display or as a global auto-attach playlist, with per-display opt-out.
- **Rotation:** global queue mode and rotation interval, plus next and previous.
- **Multi-monitor:**
  - Each display gets its own wallpaper, layout (fill mode, location, alignment, rotation) and alias.
  - **Canvases** span one wallpaper across several displays, with member rectangles and aspect lock edited in `CanvasDialog.qml` (`LinkProjection::Canvas`).
  - By default, one renderer is shared by every display showing the same wallpaper. The "Allow duplicate renderers" setting changes that.
- **Auto replay (pause policy):**
  - Seven conditions, each mapped to an action of None, Mute, Pause or Stop, with scope set to current display or all displays, plus a resume delay (`settings/schema.rs`, `routing/auto_replay.rs`).
  - Per-display conditions: any window, focused window, maximized, fullscreen. The display client reports these as `set_window_state` flags.
  - Global conditions: session locked (ScreenSaver / login1 / portal), session inactive, and Feral GameMode active.
  - "Stop" kills the renderer.
  - Policies can be set globally or per display.
- **No battery or power-profile handling.** A grep for battery, UPower and power found nothing.
- **Effects:** blur while paused (radius setting) and wallpaper transitions (fade, wipe with angle, grow with origin, duration), all rendered by the display consumer.
- **Audio:**
  - Global enable and volume.
  - Manual mute.
  - "Mute for other active playback streams": the PulseAudio observer ignores the daemon's own renderer process groups (`audio/playback.rs`), with a fade time.
  - Optional audio capture for audio-reactive wallpapers.
  - MPRIS now-playing appears in the UI sidebar (`SidebarNowPlaying.qml`) and is forwarded to renderers.
- **Mouse input:** pointer motion, buttons and axis are forwarded to the renderer. There's a global toggle.
- **Performance knobs:**
  - Per-renderer fps cap (default 30).
  - Resolution cap.
  - GPU/render-node choice per plugin; stale GPU picks are cleared at boot.
  - hwdec mode.
  - Health monitoring flags a renderer as hung after 10 s with no frame progress, or when a consumer doesn't release (`router/mod.rs`).
- **Status page:** GPUs, renderer state (starting, running, failed, with exit reason), display backend state (ready, binary_missing, flatpak_restricted, unmatched), runtime tags, and a log viewer.
- **Tray (SNI):** Open UI, Pause/Resume, Mute/Unmute, Next, Previous, Rotate, Shuffle, Rescan, Quit. The tray can be hidden.
- **Other:**
  - Autostart through the Background portal.
  - Desktop notifications through the portal.
  - `ApplyViaPortal` sets a static image through `org.freedesktop.portal.Wallpaper`, for desktops with no display backend.
  - Theme, accent colour and language settings (en/ru/zh-CN).
  - Network image cache with a size limit.
  - Plugin zip install, and update notifications that check the `sha256` from each plugin's own update manifest.
- **CLI (`waywallen`):** `--ws-port`, `--ui PATH`, `--no-ui`, `--no-tray`, `--plugin PATH` (repeatable), `--display-backend {kde-plasma|gnome-shell|layer-shell|custom}`, `--no-display`, `--no-restore`. There is no separate control CLI; scripting goes through D-Bus `Daemon1` (for example with `busctl`).

## 5. Design choices and lessons for zmural

**Clever / worth copying**
- **The three-way split of UI, daemon and renderer, with the daemon as a pure router.**
  - Renderers are isolated processes; a crash in FFmpeg or a WE scene doesn't take the daemon down.
  - The daemon forwards DMA-BUF fds and fences and never copies pixels.
  - The display side is thin and swappable per desktop.
  - This is the core idea to reuse.
- **A display-client abstraction instead of hard-wiring layer-shell.** Plasma and GNOME can't use wlr-layer-shell, so they get an in-shell plugin that speaks the same socket protocol. Backends are TOML manifests (`de`, `priority`, `requires`, `spawn = daemon|external`), with user overrides in `displays/*.toml`, a KDE hard rule, and an explicit `--display-backend` pin.
- **Explicit sync done properly:**
  - acquire `sync_file` plus a release point on a timeline syncobj;
  - a reaper that waits for every consumer before a slot is reused;
  - strictly increasing buffer and frame generations;
  - a `content_token` separate from the generation, so a technical renderer restart doesn't trigger a visual transition.
  - The protocol header comment in `waywallen_display_v1.xml` is a good spec template.
- **Format negotiation with fallbacks and learning:** matches devices by UUID, falls back to linear or host-visible memory across GPUs, and blacklists modifiers that fail to import. This handles hybrid-GPU laptops.
- **Renderer sharing across displays, plus canvas projection** done entirely through src/dst rects computed in the daemon. Pointer inverse mapping is also done by the daemon.
- **Declarative plugin manifests.** A `plugin.toml` holds typed settings (type, default, min, max, choices, group, label msgid, `identity` = respawn on change), which the UI renders generically. An `activity = continuous|on_demand` hint changes health checks, and `spawn_version` / `entry_version` are ABI gates.
- **The auto-replay policy model:** for each condition, an action (mute, pause or stop) and a scope, plus per-rule resume deadlines. It's more expressive than a simple "pause on fullscreen" toggle.
- **Feature discovery through a `Capabilities` D-Bus property** instead of comparing version strings.
- **Portal-first integration** for autostart, notifications, static-wallpaper fallback and session lock, which works in Flatpak.
- **Wire schemas in XML with an in-repo generator** for both C and Rust (`tools/wayproto-gen`). A small, dependency-free way to keep a C renderer SDK and the daemon in sync.

**Weak spots / cautions**
- **Complexity:**
  - `router/mod.rs` is 8580 lines and `renderer_manager/mod.rs` is 2984.
  - The toolchain (Lito, Clang 22 C++ modules, Qt 6.10, plus several of the author's own libraries: wavsen, rstd, QExtra, QmlMaterial) is a high bar for contributors.
  - For zmural, keep the router smaller and use mainstream tooling.
- **Security:**
  - The WS control plane is on `127.0.0.1` with no auth or Origin check that I found in `api/websocket.rs`. The random port reduces exposure, but any local process, and possibly a browser page that finds the port, could drive it **(inference)**.
  - Lua plugins run in-process with `http`, `remove_file` and filesystem access (the README warns about this).
  - Update integrity is a sha256 taken from the same remote manifest, with no signature.
  - For zmural: use a UDS or D-Bus instead of TCP, or add a token; sandbox or capability-limit plugin scripts; sign updates.
- **Gaps:**
  - No X11 support.
  - No battery or AC-power policy.
  - GIFs don't animate.
  - WE scene/web live out of tree.
  - Sway doesn't get window-state auto-pause.
  - Fullscreen/maximized detection depends on each display client's compositor knowledge, which isn't in this repo.
- **The in-shell backends (Plasma, GNOME)** mean maintaining JS/QML plugins against moving shell APIs **(inference; code not in this clone)**.

**Concrete reuse candidates (MIT, keep attribution)**
- `protocol/waywallen_display_v1.xml` and `waywallen_ipc_v3.xml`, as a design reference, or adopt them directly to be compatible with waywallen-display clients and open-wallpaper-engine renderers.
- `src/wallframe/dma/negotiate.rs` (pure logic, well unit-tested) and `settings/schema.rs::AutoReplayPolicy` semantics.
- `display/spawner.rs` backend-selection rules and the supervision loop (PDEATHSIG + backoff).
- `display/layout.rs` fill-mode and rotation math.
- The `plugin.toml` settings schema idea; the Lua source-plugin `scan`/`auto_detect`/`apply` contract.
- `system/audio/playback.rs`: "mute when another app plays audio", excluding our own renderer process groups.
