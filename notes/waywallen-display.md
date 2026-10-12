# waywallen-display: reference notes

Source: `reference/waywallen-display` (github.com/waywallen/waywallen-display, MIT, shallow clone at merge `eba4ae6`, crate version 0.4.0).
Companion daemon: `reference/waywallen`. "(inference)" marks anything not read directly in code.

## 1. Overview

- **What it is:** the display side of waywallen. The daemon (a separate process) runs the wallpaper renderers. This repo takes those rendered frames and puts them on the desktop through each shell's own mechanism (`README.md`, `BUILD.md`).
- **Languages:**
  - C11 core library `libwaywallen_display` (`src/*.c`, `include/*.h`).
  - C++/Qt 6 QML plugin (`plugins/qml`).
  - C GObject/GIR plugin (`plugins/gobject`).
  - QML for the KDE package, GJS (ES modules) for the GNOME extension.
  - Rust for the layer-shell client (`src/bin/layer_shell`) and the FFI crate (`src/lib.rs`).
- **Build systems:** two, side by side.
  - CMake ≥ 3.16 builds the C lib, the QML/GObject plugins, tests, examples, translations and the CPack zips. The version is parsed out of `Cargo.toml` (`CMakeLists.txt`).
  - Cargo builds the Rust crate. Its `build.rs` compiles the same C sources with the `cc` crate, linking them statically, and also compiles the layer-shell shaders. The `waywallen-layer-shell` binary is Cargo-only (`BUILD.md`).
- **Dependencies:**
  - Build headers: EGL/GLESv2 and Vulkan. At runtime these libraries are `dlopen`-ed, not linked (`CMakeLists.txt` comments, `waywallen_vk_ctx_t` doc).
  - Plugins: Qt 6 (Quick/Gui/Qml/DBus) for QML; GTK4/GIR for GObject.
  - Rust: `ash`, `wayland-client`, `wayland-protocols(-wlr)`, `niri-ipc`, `gettext-rs`, `md-5`, `serde_json` (`Cargo.toml`).
  - `glibc-2.17.h` is force-included to target an old glibc baseline on x86_64 (`CMakeLists.txt:282`). The likely purpose is portable release binaries (inference).
- **Integrations:**
  - **KDE Plasma 6:** a wallpaper kpackage, `org.waywallen.kde` (`extensions/kde`).
  - **GNOME Shell 48–50:** an extension, `org.waywallen.gnome@waywallen.io`. It is Wayland-focused, and its launcher also has an X11 path (`extensions/gnome/extension/launcher.js`).
  - **wlr layer-shell:** a standalone client for Hyprland, Sway, Niri, River, COSMIC, Wayfire, labwc and others (`src/bin/layer_shell`).

## 2. How it works

### Transport
- The transport is a Unix domain socket (SOCK_STREAM) at `$XDG_RUNTIME_DIR/waywallen/display.sock`, protocol `waywallen-display-v1`, wire **version 9**. The daemon accepts exactly v9 (`include/waywallen_display.h`, `../waywallen/protocol/waywallen_display_v1.xml`).
- **Frame format:** a u16 opcode, a u16 total length, then a 4-byte-aligned positional body. File descriptors travel as SCM_RIGHTS on the same `sendmsg` call. Limits are 65531 body bytes and 64 fds per message (`src/codec.h`).
- **Code generation:** the C bindings (`src/generated/ww_proto.{c,h}`, `include/waywallen_display_protocol_types.h`) are generated from the daemon repo's XML by `wayproto-gen`, and they are checked in. Only `-DWAYWALLEN_DISPLAY_REGEN_PROTO=ON` needs the sibling repo (`CMakeLists.txt`).

### Roles and messages
- **Division of responsibility** (protocol XML header):
  - The client is a passive consumer. It reports display identity, metrics, window facts, input and GPU import capabilities.
  - The daemon owns routing, renderer lifecycle, buffer negotiation, composition, presentation effects and recovery.
- **Requests:** `hello`, `register_display`, `set_display_metrics`, `buffer_import_failed`, `pointer_motion/button/axis`, `ack_unbind`, `set_window_state`, `frame_release_armed`.
- **Events:** `welcome`, `display_accepted`, `bind_buffers`, `set_composition_config`, `frame_ready`, `unbind`, `error`, `set_presentation_snapshot/state`.

### Zero-copy frames
1. **Buffer pool:** `bind_buffers` sends a pool of DMA-BUFs (count, size, fourcc, modifier, per-plane stride/offset) along with the initial composition config (source/dest rect, transform, clear colour).
2. **Per frame:** `frame_ready` carries two fds, an acquire sync_file and a release drm_syncobj.
3. **Release:** the consumer attaches its GPU fence to the syncobj (`waywallen_display_release_after_sync_file`) or signals it, then sends `frame_release_armed`. There is no "buffer_release" message; GPU completion is observed through the syncobj (XML header, `waywallen_display.h`).
4. **GPU selection:** during registration the consumer advertises its formats, modifiers, DRM render node and device/driver UUIDs. If the render node is unknown (0,0), the daemon falls back to HOST_VISIBLE placement so cross-GPU PRIME import still works (`waywallen_display_set_drm_render_node` doc).

### Import backends in the C lib
- **EGL:** `EGL_EXT_image_dma_buf_import`. The host creates GL textures on its render thread with `create_gl_texture`.
- **VULKAN:** the host passes its own VkInstance/Device. Frames can be consumed directly (`vulkan_direct_frame`) or copied into a sampler-friendly image (`vulkan_consume_frame`, then commit/discard).
- **DMABUF_RELAY:** the lib creates a private Vulkan device and blits each frame into a LINEAR "shadow" image that it re-exports as a DMA-BUF. This mode exists for toolkits like GTK4 that can import DMA-BUFs but don't expose their renderer (`waywallen_display.h`, `src/backend_vulkan_blit.c`).

### Lifecycle
- **Connect:** non-blocking, in the style of libwayland. `begin_connect` → `advance_handshake`, which returns NEED_READ, NEED_WRITE, PROGRESS or DONE. The handshake states are IDLE → CONNECTING → HELLO_PENDING → WELCOME_WAIT → REGISTER_PEND → ACCEPTED_WAIT → READY.
- **Running:** `dispatch` runs on POLLIN. An "outbox" with `wants_writable`/`handle_writable` handles POLLOUT. In the outbox, acks are reliable, button/axis events stay ordered, and metrics/motion/window-state are latest-value-wins.
- **Errors:** they latch the session into DEAD. `on_disconnected` fires on the next call into the library, and `last_disconnect_reason` gives a categorised cause.
- **Shutdown:** `close` (any thread) → `drain` (the GPU-owning thread) → `free`. `free` deliberately aborts if pools were never drained (`waywallen_display.h`, `src/display.c`).
- **Threading:** one handle is not thread-safe. `get_fd` and `drain` are the exceptions, so a QML host can run I/O on the GUI thread and drain on the render thread.
- **Transitions:** a presentation controller (`src/presentation.c`, `include/waywallen_display_presentation.h`) compares each binding's `content_token` with the content last presented. It then decides between direct present, queue, or a transition (fade/wipe/grow), so replacing the renderer or the buffer pool does not animate.

### Per-desktop integration
- **KDE:**
  - `package/contents/ui/main.qml` is a `WallpaperItem`. It lazy-loads `WaywallenSurface.qml`, which wraps the C++ `WaywallenDisplay` QQuickItem.
  - The plugin checks Qt's scene-graph graphics API and binds EGL for OpenGL or Vulkan for Vulkan (`plugins/qml/WaywallenDisplay.cpp` ~L1388).
  - Pause blur uses a QML `MultiEffect`.
  - It sets `loading = false` right away, so a missing daemon never blocks ksplash.
  - `WindowModel.qml` uses `TaskManager.TasksModel`, filtered to the screen's global geometry, to compute window-state flags.
- **GNOME:** a two-process design.
  - The Shell extension (`extension.js`) watches the daemon's D-Bus name. It then spawns `renderer/renderer.js`, a separate GJS + GTK4 process, as a Wayland client via `Meta.WaylandClient`.
  - The renderer opens one `Gtk.ApplicationWindow` per `Gdk.Monitor` and one display connection per monitor, using DMABUF_RELAY through the GObject plugin (`WwPresentationWidget` / `WwShadowPaintable`).
  - In the Shell, `gnomeShellOverride.js` monkey-patches `BackgroundManager._createBackgroundActor`. It inserts a `LiveWallpaper` actor holding a `Clutter.Clone` of the renderer's window actor (`wallpaper.js`), and hides renderer windows from window lists.
  - `windowManager.js` keeps those windows minimised, at the bottom and in place. The desired state is encoded as JSON in the window title: `@<APP_ID>!<json>|<index>`.
  - Shell → renderer control goes over the renderer's **stdin** as text lines (`M`/`B`/`A` pointer, `W` window state, `R` presentation ack), routed by global coordinates. Renderer → Shell uses JSON control frames on **stdout** (`controlCodec.js`).
  - When the renderer disconnects it exits, and the extension respawns it with backoff from 2 s to 30 s. The backoff resets after the renderer has run for 20 s.
- **layer-shell (Rust):**
  - Creates one `zwlr_layer_surface_v1` per `wl_output`: `Layer::Background`, anchored on all edges, exclusive zone −1, no keyboard (`app/mod.rs:223-233`).
  - Renders through its own Vulkan swapchain (`vulkan/swapchain.rs`, `render.rs`), with shaders for blur, downsample and transitions (`shaders/`). Frames come in via `bind_vulkan`.
  - Supports fractional-scale, viewporter and linux-dmabuf feedback (imports in `app/mod.rs`).
  - Window-state watchers are picked per compositor: Hyprland, Niri or Wayfire IPC if their socket is present, otherwise COSMIC protocols, otherwise `zwlr_foreign_toplevel_management_v1` (`watcher/mod.rs::spawn_all`).
  - The wlr fallback can't see workspace visibility, and the module docs say so (`watcher/wlr.rs`).

### How the daemon picks a display backend (in `../waywallen`)
- `src/plugin/display_registry.rs` has built-in defs:
  - `kde-plasma` and `gnome-shell` use `SpawnMode::External` (the DE loads them).
  - `layer-shell` uses `SpawnMode::Daemon`: the daemon spawns the binary for hyprland, sway, niri, river or cosmic, and requires `wlr-layer-shell` + `linux-dmabuf-v4`.
- Matching is on the first token of `XDG_CURRENT_DESKTOP`, ranked by priority. The AppImage bundles the layer-shell binary (README note).

## 3. Modules

| Path | Responsibility | Key files |
|---|---|---|
| `include/` | Public C ABI: lifecycle, backends, callbacks, pointer and window state, presentation controller, generated protocol types | `waywallen_display.h`, `waywallen_display_presentation.h`, `waywallen_display_protocol_types.h`, `waywallen_display_{egl,vulkan}_presenter.h` |
| `src/` (C) | Session state machine, wire codec, DMA-BUF import backends, shadow blitter, transition/presentation logic | `display.c` (3.3k lines), `codec.c`, `backend_egl.c`, `backend_vulkan.c`, `backend_vulkan_blit.c`, `presentation.c`, `egl_presenter.c`, `vulkan_presenter.c` |
| `src/generated/` | Checked-in protocol encoders and decoders generated by wayproto-gen | `ww_proto.c`, `ww_proto.h` |
| `src/lib.rs` | Rust FFI bindings mirroring the C header; the C code is linked statically via `build.rs` | `lib.rs`, `build.rs` |
| `src/bin/layer_shell/app/` | Wayland globals, per-output layer surfaces, display sessions and reconnect, pointer input, presentation | `mod.rs`, `wayland.rs`, `session.rs`, `input.rs`, `presentation.rs` |
| `src/bin/layer_shell/vulkan/` | Vulkan runtime, swapchain, pipelines, direct-sampling path, blur and transition effects | `runtime.rs`, `swapchain.rs`, `render.rs`, `direct.rs`, `effects.rs`, `pipeline.rs` |
| `src/bin/layer_shell/watcher/` | Per-compositor window-state watchers that feed the autopause flags | `mod.rs`, `hyprland.rs`, `niri.rs`, `wayfire.rs`, `cosmic.rs`, `wlr.rs` |
| `src/bin/layer_shell/shaders/` | GLSL for the blit, blur, downsample and transitions | `layer_shell.{vert,frag}`, `blur.frag`, `transition.frag` |
| `plugins/qml/` | Qt 6 QML module `Waywallen.Display` (or the embedded URI `Waywallen.DisplayEmbed`): the QQuickItem, scene-graph node, render resources, D-Bus reconnect | `WaywallenDisplay.{hpp,cpp}`, `WaywallenDisplayRender.cpp`, `QsgPresentationNode.cpp`, `FrameSlotRetirement.hpp` |
| `plugins/gobject/` | GIR namespace `Waywallen` for GJS: a `WwDisplay` wrapper that is DMABUF_RELAY-only, a GTK presentation widget, and the shadow-DMA-BUF paintable | `ww-display.c`, `ww-presentation-widget.c`, `ww-shadow-paintable.c` |
| `extensions/kde/` | Plasma 6 wallpaper kpackage: UI, settings, window model, diagnostics overlay | `package/contents/ui/main.qml`, `WaywallenSurface.qml`, `WindowModel.qml`, `config.qml`, `config/main.xml`, `metadata.json` |
| `extensions/gnome/extension/` | Shell extension: lifecycle and respawn, background-actor injection, renderer window taming, pointer and window-state forwarding, prefs | `extension.js`, `gnomeShellOverride.js`, `wallpaper.js`, `windowManager.js`, `launcher.js`, `controlCodec.js`, `prefs.js`, `schemas/*.gschema.xml` |
| `extensions/gnome/renderer/` | GJS/GTK4 subprocess, one window and one daemon connection per monitor | `renderer.js` |
| `examples/` | Minimal EGL and headless C clients, QML demos (multi-display, controls) | `minimal_egl.c`, `minimal_headless.c`, `qml/*.qml` |
| `tests/` | Codec, display state machine, EGL backend, presentation state, reconnect backoff, frame-slot retirement | `test_*.c`, `test_*.cpp` |
| `scripts/`, `po/`, `.github/` | Packaging (KDE embed zip, GNOME zip), gettext catalogs, CI and release matrix | `build_kde_embed.sh`, `build_gnome_zip.sh`, `workflows/package-release.yml` |

## 4. User features

- **Install flow:** prebuilt artifacts come from GitHub Releases (`README.md`, `package-release.yml`).
  - KDE: `kpackagetool6 -i waywallen-kde-*-embed.zip`, then restart plasmashell. The "embed" zip bundles the QML module privately under the `Waywallen.DisplayEmbed` URI (`scripts/build_kde_embed.sh`, `Wrapper/*Embed.qml`), so no system package is needed. X11 (e.g. Steam Deck) also needs `QT_XCB_GL_INTEGRATION=xcb_egl` set through a systemd drop-in.
  - GNOME: `gnome-extensions install` + `enable`, then log out and back in. The zip bundles `lib/` and `girepository-1.0`, which the extension adds to `LD_LIBRARY_PATH` / `GI_TYPELIB_PATH` for the renderer (`extension.js`).
  - layer-shell: extract the tarball into `~/.local`. The binary takes `--socket`, `--name` and `--version`, and reads the `WAYWALLEN_SOCKET` environment variable (`main.rs`). The waywallen AppImage embeds and manages this binary.
- **KDE settings** (`config/main.xml`, `config.qml`): display-name override, a diagnostics overlay (connection/stream state, frame count, geometry, DPR, covering windows, disconnect reason), a mouse-forward toggle, and "accent colour from wallpaper".
- **GNOME settings** (gschema): `instance-id` (a UUID generated on first enable), `display-name`, `show-diagnostics`, `overview-wallpaper`, `overview-blur`, `overview-blur-strength`. The extension also runs in `unlock-dialog` mode, so the wallpaper shows on the lock screen (`metadata.json.in`).
- **Per-monitor handling:** every output registers with the daemon as its own display, with a stable `instance_id` that the daemon uses as the key for per-display settings.
  - KDE: `kde-` + MD5(name|manufacturer|model|serial) (`WaywallenDisplay.cpp::effectiveInstanceId`). The default name is the EDID model, falling back to the connector.
  - GNOME: `<uuid>:<connector or mfg-model>` (`renderer.js::monitorKey`).
  - layer-shell: `layer-` + MD5(name|description|make|model) (`app/wayland.rs`).
  - Metrics are sent in physical pixels (logical × scale) together with the refresh rate in mHz.
- **Autopause input:** each backend reports which windows cover its display (non-minimised, active, maximised, fullscreen). The daemon owns the policy; the header says consumers "MUST NOT debounce or filter".
- **Interactivity:** pointer motion, buttons and wheel are forwarded to the daemon in surface-local coordinates. The daemon handles inverse mapping.
- **Presentation effects:** blur on pause, plus fade/wipe/grow transitions between wallpapers. Each host declares which of these it supports as capability bits.
- **Resilience:** auto-reconnect with exponential backoff. The QML plugin also subscribes to D-Bus `NameOwnerChanged` and the daemon's `Ready` signal (`org.waywallen.waywallen.Daemon`) to reconnect immediately (`WaywallenDisplay.cpp::setupDBusWatcher`). Translations: ru for all three components.

## 5. Design choices / lessons for zmural

1. **Manager and display are separate processes, connected by a small versioned protocol.** The daemon owns every policy decision (routing, renderer lifecycle, pause, effects, composition). Display clients are "passive" and only report facts: size, window coverage, input, GPU capabilities. The one shared contract is the protocol XML, which generates code for both sides, so new desktops only need a new client. zmural should adopt this split.
2. **One C core, thin per-toolkit adapters.** The protocol, sync and import logic is written once in C with a frozen ABI and callback tables, and `dlopen`s EGL and Vulkan so it adds no link dependencies. Qt, GObject/GIR and Rust each wrap it thinly. For zmural, a Zig core exposing a C ABI could serve the same role (inference).
3. **Zero-copy with explicit sync.** DMA-BUF pools, acquire sync_files and release drm_syncobjs, plus capability negotiation (formats, modifiers, render node, UUIDs) with a HOST_VISIBLE fallback for multi-GPU. The frame-release contract (arm the syncobj, then ack) is subtle; model it early rather than bolting it on.
4. **Adapt to each toolkit's limits.** GTK4/GJS can't hand over a Vulkan device, so they get DMABUF_RELAY (a blit into a shadow LINEAR DMA-BUF, at the cost of one copy per frame). GNOME also has no wallpaper plugin API, so the extension uses a separate renderer process whose window is cloned into the background actor, plus monkey-patching. That path is fragile and version-gated (Shell 48–50, different `Meta.WaylandClient` APIs before and after 49), so budget maintenance for it.
5. **Event-loop-friendly, non-blocking API.** The prepare/advance handshake, `wants_writable` outbox and latest-value coalescing plug into Qt, GLib or poll loops without extra threads. Errors latch to DEAD and are reported on the next call, never mid-callback.
6. **Explicit teardown ordering across threads** (`close`, then `drain` on the GPU thread, then `free`). `free` aborts loudly if resources leak. The GObject paintable exists because JS garbage collection leaked VkImages (`ww-shadow-paintable.h`), which is a useful warning for GC-based shells.
7. **Stable per-monitor identity** comes from a hash of EDID-ish fields rather than connector names, which move when cables do. Each desktop derives it differently, so a zmural spec should define one canonical derivation (inference: the three schemes here differ and won't match across DEs).
8. **Never block the desktop.** KDE sets `loading=false` immediately and shows black until frames arrive. Daemon discovery uses D-Bus signals plus backoff, and GNOME respawns the renderer with backoff.
9. **Content token vs generation.** An opaque `content_token` separates "the user changed the wallpaper" (animate) from "the buffer pool or renderer was rebuilt" (don't animate). This is a clean way to avoid spurious transitions.
10. **Distribution:** self-contained artifacts (an embedded QML module, a bundled GNOME lib/typelib, an old-glibc baseline) avoid distro packaging. The daemon's display registry chooses the backend from `XDG_CURRENT_DESKTOP` and probed Wayland globals.
