# Third-party notices

zmural uses or learned from the projects below. We're grateful to their authors.

## waywallen and waywallen-display

- https://github.com/waywallen/waywallen
- https://github.com/waywallen/waywallen-display
- Copyright (c) 2026 hypengw, MIT License

zmural's architecture follows waywallen's design:
- a daemon that routes frames but never touches pixels,
- out-of-process renderers,
- thin per-desktop display clients,
- zero-copy DMA-BUF frames with explicit sync,
- format negotiation,
- the condition → action pause-policy model,
- typed renderer settings in manifests,
- content tokens for transitions.

zmural also uses their work directly:
- **Protocol:** zmural's Linux display protocol *is* waywallen's
  `waywallen-display-v1` (version 9, `protocol/waywallen_display_v1.xml`).
  `src/protocol/ww_display.zig` is zmural's own Zig implementation of it.
- **Vendored code:** `third_party/waywallen-display/` is waywallen-display
  0.4.1 (commit `8ca3938`): the C display library, the Qt QML plugin, the
  KDE Plasma wallpaper package and the GNOME Shell extension. zmural ships
  it as its KDE and GNOME display plugins. Its only changes are renames
  (socket path, D-Bus name, plugin IDs, QML module URIs) and zmural's
  wording, all applied by `tools/vendor-waywallen-display.sh`; see
  `third_party/waywallen-display/VENDORED.md`. Its `glibc-2.17.h` is MIT,
  Copyright 2021 Bill Zissimopoulos (notice in the file).
- **Ported logic:** zmural's Hyprland and Wayfire window watchers
  (`src/daemon/compositor_hyprland.zig`, `compositor_wayfire.zig`) follow
  waywallen-display's watchers.

For all of the above, this notice applies:

```
MIT License

Copyright (c) 2026 hypengw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Fluent UI System Icons

- https://github.com/microsoft/fluentui-system-icons
- Copyright (c) 2020 Microsoft Corporation, MIT License (`assets/fonts/FluentSystemIcons-LICENSE.txt`)

The Linux settings window's icons are a 31-glyph subset of the Regular font
(`assets/fonts/zmural-icons.ttf`, made with fontTools' subsetter), embedded in
zmural (the settings window): the same design family as Windows 11's Segoe Fluent Icons.
The Linux release ships the full licence as `licenses/FluentSystemIcons-LICENSE.txt`.

## mpv / libmpv (and the FFmpeg inside it)

- mpv: https://github.com/mpv-player/mpv. The Windows release ships an **LGPL-2.1-or-later** build (mpv configured with `-Dgpl=false`). On Linux zmural ships no libmpv: it uses the one your distribution installs.
- FFmpeg: https://ffmpeg.org, statically linked into that libmpv under **LGPL-3.0-or-later** (as the build's README states: "libmpv under LGPLv2.1+ license, which … statically links to ffmpeg under LGPLv3").
- That libmpv also links in, statically, the libraries mpv-winbuild builds mpv and FFmpeg with (libass, FreeType, HarfBuzz, FriBidi, libplacebo, dav1d, libvpx, libwebp, Opus, LuaJIT, libcurl and others), each under its own licence. All of them, about seventy projects, are credited with a link and their licence in [`licenses/libmpv-credits.txt`](licenses/libmpv-credits.txt), which ships in the Windows release.
- Windows build used: [zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild) (built publicly on GitHub Actions), release `2026-09-26-a1bf4b6559`, asset `mpv-dev-lgpl-x86_64-20260926-git-a1bf4b6559.7z`, from mpv commit `a1bf4b6559`.

zmural does not link against libmpv. It loads it at runtime, so the library can be replaced with any compatible build (an LGPL requirement): `libmpv-2.dll` from next to its executables on Windows, the system's `libmpv.so.2` on Linux. The function and struct layouts in `src/os/libmpv.zig` follow mpv's public headers `client.h`, `render.h` and `render_gl.h`. libmpv is **not** in this repository; for Windows development it goes in `third_party/mpv/` (git-ignored, with a `SOURCE.txt` recording its origin and hashes).

Each Windows release ships `libmpv-2.dll` with the LGPL-2.1 and LGPL-3.0 licence texts (`licenses/LGPL-2.1.txt`, `licenses/LGPL-3.0.txt`; LGPL-3.0 builds on the GPL-3.0 in `LICENSE.txt`), this notice, and where to get the exact mpv and FFmpeg sources used (`licenses/libmpv-SOURCE.txt`).

## Microsoft Edge WebView2 SDK

- Package: [Microsoft.Web.WebView2 1.0.4191.47](https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.4191.47), Copyright (C) Microsoft Corporation, **BSD-3-Clause**.
- zmural ships the SDK's `WebView2Loader.dll` (x64) and loads it at runtime for web wallpapers (`zmural --renderer web`). The WebView2 Runtime itself comes with Windows 11 and isn't bundled.
- `src/os/webview2.zig` is generated by `tools/gen_webview2.py` from the SDK's `WebView2.h`: the COM interface layouts and IIDs are copied from it.
- A release includes the SDK's licence and notice files (`licenses/WebView2-LICENSE.txt`, `licenses/WebView2-NOTICE.txt`) and its origin and hashes (`licenses/WebView2-SOURCE.txt`). For development the DLL goes in `third_party/webview2/` (git-ignored).

The BSD-3-Clause licence, as the SDK states it:

> Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met: (1) Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer. (2) Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution. (3) The name of Microsoft Corporation, or the names of its contributors may not be used to endorse or promote products derived from this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Lively Wallpaper

- https://github.com/rocksdanister/lively
- by rocksdanister and contributors, GPL-3.0

Lively inspired many of zmural's Windows behaviours and user features:
- placing the wallpaper behind the desktop icons through WorkerW, including the Windows 11 24H2 layout,
- recovering when Explorer restarts,
- a watchdog that cleans up players,
- coverage-based pausing, and battery, lock and remote-desktop pause rules,
- customisable wallpaper properties and the web-wallpaper JS API,
- span and duplicate layouts, and the screensaver.

**zmural contains no code from Lively.** Lively was studied for design only, and zmural's implementation is written independently. Support for importing Lively wallpaper packages reads their published metadata format; it doesn't use Lively's code.

## Zig

- https://ziglang.org, Copyright (c) Zig contributors, MIT License (`licenses/Zig-LICENSE.txt`, shipped in both releases).

zmural is written in Zig, and parts of Zig's standard library (zip and deflate, time zones, formatting and more) are compiled into its programs.

## Hidamari

- https://github.com/jeffshee/hidamari, by jeffshee, GPL-3.0

zmural's GNOME fallback follows Hidamari's idea: where no live wallpaper can show, set a still frame of the video as the desktop background, and keep the user's own background to put back afterwards. No code was taken.

## Inigo Quilez

- https://iquilezles.org/articles/distfunctions2d/

Prism, the wallpaper zmural ships (`tools/wallgen.zig`), draws its triangles with the equilateral-triangle distance function from Inigo Quilez's 2D distance functions article.

## Standards and system libraries

zmural speaks these protocols with its own code (the names and message numbers come from their published specifications; no code from them is included):
- Wayland and wayland-protocols (xdg-shell, linux-dmabuf, viewporter, single-pixel-buffer, xdg-activation, xdg-decoration, cursor-shape), and wlroots' wlr-protocols (wlr-layer-shell, wlr-foreign-toplevel-management), each under the permissive licence stated in its protocol file.
- freedesktop.org D-Bus interfaces (StatusNotifierItem, the desktop notifications and portal interfaces), Canonical's dbusmenu, systemd-logind, UPower, power-profiles-daemon, Feral Interactive's GameMode, and KDE's KWin scripting and Plasma shell interfaces.

On Linux zmural uses these from your system, loaded at runtime and not shipped with it: mpv's libmpv and the FFmpeg it uses, Mesa (EGL and GBM), Cairo, Pango and Fontconfig, and, for the KDE plugin and GNOME extension, Qt, KDE Plasma, GTK, GLib and GNOME Shell.

## Also studied

Other free projects that were read while designing zmural, for what they do well: linux-wallpaperengine, mpvpaper, swww, Komorebi, ScreenPlay, Hanabi and Smart Video Wallpaper Reborn. None of their code is in zmural.
