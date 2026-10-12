# Building zmural

zmural is written in Zig 0.16 and built with `zig build`. One codebase builds a separate program for each OS; either OS can cross-compile the other's programs. The Windows release zip can only be made on Windows (it uses Windows' own `tar.exe`).

## Windows

You need Zig 0.16 and two third-party runtimes, which aren't in git; `.github/workflows/ci.yml` fetches the pinned builds and shows where they come from (see also [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)):

- `third_party/mpv/`: `libmpv-2.dll` (an LGPL build of mpv) and `SOURCE.txt`.
- `third_party/webview2/`: `WebView2Loader.dll`, `LICENSE.txt`, `NOTICE.txt` and `SOURCE.txt`, for web wallpapers.

`zig build` runs with just `libmpv-2.dll`; `zig build package` needs all of them.

```
zig build                                                          # the programs, in zig-out/bin
zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-windows   # the release zip, in zig-out/package
```

## Linux

You need Zig 0.16 and the runtime libraries from the README's [Install](../README.md#install) section. The KDE plugin and the GNOME extension have build tools of their own: CMake, Ninja, pkg-config, gettext, EGL/GLES/GBM dev files, and Qt 6 (KDE) or GTK 4.10+ and GObject-Introspection (GNOME). The full list is the package list in `tools/plugin-root.sh`. `-Dplugin-root` also needs `bwrap` (bubblewrap), and `package` needs `objcopy` (binutils).

```
zig build -Doptimize=ReleaseFast                   # the programs, in zig-out/bin
zig build kde-plugin -Doptimize=ReleaseFast        # KDE Plasma only (build tools above)
zig build gnome-extension -Doptimize=ReleaseFast   # GNOME only (build tools above)
zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)   # all of it, as the release tarball in zig-out/package
```

zmural itself is tried on Debian 12 (glibc 2.36). The KDE plugin and GNOME extension are built inside a Debian 13 root (`tools/plugin-root.sh` makes it once, in `~/.cache/zmural-build/debian13`; `$ZMURAL_PLUGIN_ROOT` puts it elsewhere), the oldest system with what they declare, so they load there and on everything newer. It is kept out of `~/.cache/zmural`, which `zmural-console uninstall` deletes.

## Working builds and released builds

A plain `zig build` is a working (Debug) build: slow, and full of debugging info. What is released is a separate, stripped ReleaseFast build. [RELEASING.md](RELEASING.md) explains the two, how to make a release, and how to read a crash report from one. Never measure speed on a working build.

## Everyday commands

```
zig build                          # build everything for this OS into zig-out/bin
zig build test                     # unit tests
zig build run -- --help            # run zmural
zig build cli -- apply <path>      # run zmural-console
zig build -Dtarget=x86_64-linux-gnu  # cross-compile for Linux (from Windows; plain x86_64-linux means static musl, which can't load libmpv)
zig build -Dtarget=x86_64-windows  # cross-compile for Windows (from Linux)
zig build starter-wallpaper        # remake Prism, the wallpaper zmural ships (tools/wallgen.zig)
```

The Linux test rigs (headless compositors, packaging, crashes) are the `tools/*-test.sh` scripts; `tools/sandbox-deps.sh --check` lists what they need.

## What zmural needs, exactly

Each line is the lowest version that part needs, taken from the part itself; it isn't a list of systems picked by hand. Where something falls short, zmural says what it needs (a notification for a desktop or compositor it can't use, the log for a missing Cairo, Pango or Fontconfig) and installs nothing for it. A glibc older than 2.36 stops it from starting at all.

**Windows:** Windows 11, x86-64. Web wallpapers use the WebView2 Runtime, which comes with Windows 11.

**Linux:** x86-64, a Wayland session, a GPU, and:

| For | Needs | Because |
|---|---|---|
| zmural itself | glibc 2.36, libmpv 0.35 (`libmpv.so.2`), Mesa 21.3 (GBM), Linux 5.3 | the oldest versions of what zmural's code calls into |
| KDE Plasma | Plasma 6, with Qt 6.8 or newer | zmural's wallpaper plugin is a Plasma 6 plugin (as waywallen-display, which it comes from, declares), built against Qt 6.8 |
| GNOME | GNOME 48, 49, 50 or 51 | the versions zmural's GNOME extension declares (from waywallen-display); newer ones follow when it adds them |
| Sway, labwc, Wayfire, Niri, Hyprland, COSMIC and other compositors with wlr-layer-shell | wlr-layer-shell v3, linux-dmabuf v4, wl_output v4, wl_subcompositor and wp_viewporter (wlroots 0.16, Sway 1.8 or newer) | zmural's own display host draws the wallpaper through them |

zmural doesn't draw on X11 sessions; on a compositor without the parts above it sets your picture as the desktop's own still wallpaper instead.

## GPU video decoding on Linux

Video decoding on the GPU uses VA-API. Whether a format decodes on the GPU depends on the GPU's hardware and its VA-API driver. With Mesa (AMD), AV1 and VP9 work on any distribution where the GPU has hardware for them; H.264 and H.265 only work where both Mesa and FFmpeg were built with them. Fedora and openSUSE leave them out, so on Fedora with an AMD GPU you need RPM Fusion's `mesa-va-drivers-freeworld` and `libavcodec-freeworld`. Intel and NVIDIA GPUs use their own VA-API drivers. zmural installs no codecs or drivers itself. When the GPU can't decode a video it plays it on the CPU instead (a 1440p60 H.264 clip: about 13% of one core instead of about 1.4%), and the first time that happens for a format it shows one notification, "No GPU decoder for H.264 found". It checks afresh every time a video starts, so installed codecs are used from the next wallpaper change. The log always says which decoder a wallpaper got: `decoding h264 on the GPU (vaapi)`.
