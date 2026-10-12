zmural: free, open-source live wallpapers (Linux build)
======================================================

WHAT IT NEEDS
  x86-64, a Wayland session and a GPU; glibc 2.36, libmpv 0.35, Mesa 21.3.
  KDE Plasma: Plasma 6 with Qt 6.8 or newer. GNOME: 48, 49, 50 or 51 (the
  versions zmural's extension declares). Other desktops: wlr-layer-shell v3,
  linux-dmabuf v4 and wl_output v4 (wlroots 0.16, Sway 1.8 or newer).
  Where something falls short, zmural says what it needs and installs
  nothing for it.

QUICK START
  1. Extract the tarball anywhere you like, for example into ~/.local/opt
     (it makes this folder there).
     Keep bin/ and share/ side by side.
  2. Install the libraries zmural uses from your system:
       Fedora:          sudo dnf install mpv-libs mesa-libEGL mesa-libgbm pango cairo
       Debian, Ubuntu:  sudo apt install libmpv2 libegl1 libgbm1 libpango-1.0-0 \
                          libpangocairo-1.0-0 libcairo2
       Arch:            sudo pacman -S mpv mesa pango cairo
       openSUSE:        sudo zypper install libmpv2 Mesa-libEGL1 libgbm1 \
                          libpango-1_0-0 libcairo2
  3. Run bin/zmural. A star icon appears in the tray, Prism (the wallpaper
     zmural comes with) shows, and the settings window opens on its Welcome
     page. zmural adds itself to your app menu and to the programs started
     when you log in.
  4. Put your own videos, images or GIFs in the Wallpapers folder inside your
     Videos or Pictures folder (Welcome's Open buttons make them). They
     appear on Welcome within a few seconds; click one to show it. Later,
     the tray menu's Rescan (or zmural-console rescan) picks up new files.

  How it shows the wallpaper depends on the desktop, and zmural sets it up
  itself:
  - Sway, Hyprland, labwc, Wayfire, Niri, COSMIC: through its own display
    host, which it starts and stops. On Wayfire, turn on its ipc and
    ipc-rules plugins so zmural knows which workspace is showing.
  - KDE Plasma 6 (Qt 6.8 or newer): through its Plasma wallpaper plugin,
    which it installs and switches to (a notification says so).
  - GNOME 48, 49, 50 or 51: through its GNOME Shell extension, which it
    installs; log out and back in once. Until then your wallpaper shows as
    a still picture (your own GNOME background is kept, and uninstalling
    zmural puts it back).
  - An X11 session, an older Plasma or GNOME, or a compositor without the
    Wayland protocols above: zmural says what it needs, and sets your
    wallpaper as a still picture meanwhile (a video as one of its frames).
    On X11 the settings window doesn't open either: use zmural-console.

THE SETTINGS WINDOW
  Click the tray icon, or pick zmural in your app menu, or run
  bin/zmural --settings. Wallpapers, fill mode, volume, rotation, pause rules
  and library folders are all there.
  Screen readers are not supported: the window draws its own controls, so
  a screen reader sees nothing in it. zmural-console (below) does
  everything the window does, from a terminal.

FROM A TERMINAL
  bin/zmural-console status              what's showing
  bin/zmural-console apply <file>        show a specific video, image or GIF
  bin/zmural-console apply <file> --monitor 2   give one monitor its own (follow --monitor 2: back)
  bin/zmural-console next | previous     step through the library
  bin/zmural-console order shuffle       or sequential, random (shuffle on|off too)
  bin/zmural-console pause | play        pause or resume
  bin/zmural-console mute | unmute
  bin/zmural-console fill fit            how it fills the screen (or crop, stretch, center)
  bin/zmural-console rotate 15 | off     change the wallpaper every 15 min
  bin/zmural-console props               the wallpaper's adjustments
  bin/zmural-console prop brightness -20 change one (prop --reset: all back)
  bin/zmural-console import <file.zip>   unpack a zip of wallpapers
  bin/zmural-console export <wallpaper>  pack one into a zip
  bin/zmural-console rescan              pick up files you just added
  bin/zmural-console autostart on|off|status
  bin/zmural-console help                everything it can do
  bin/zmural-console version             which zmural this is
  bin/zmural-console quit

FILES
  Settings:  ~/.config/zmural/settings.toml
  Log:       ~/.local/state/zmural/zmural.log

VIDEO DECODING
  zmural decodes video on the GPU where your system can, and on the CPU
  where it can't; it tells you once per format. Fedora and openSUSE leave
  H.264 and H.265 out of their own Mesa and FFmpeg: RPM Fusion's
  mesa-va-drivers-freeworld and libavcodec-freeworld add them. zmural never
  installs codecs or drivers itself.

UPDATING
  Quit zmural (bin/zmural-console quit) and extract the new version next to
  this folder; it makes a folder named after the new version. Run bin/zmural
  from there (start at login and the app menu entry follow it), then delete
  this folder. Your settings and library are kept; on KDE Plasma and GNOME zmural updates its own plugin or
  extension when it starts (on GNOME it runs from your next login).

UNINSTALL
  Press Uninstall on the settings window's General page, or run
  "bin/zmural-console uninstall". It stops zmural and removes what it
  added: start at login, its menu entry and icons, its KDE Plasma plugin or
  GNOME Shell extension (your desktop gets its own wallpaper back), its
  settings, thumbnails and log. Your wallpapers and their folders are not
  touched. Then delete this folder.

LICENSES
  zmural is free software under the GNU GPL, version 3 or later
  (LICENSE.txt). Its KDE Plasma plugin and GNOME Shell extension come from
  waywallen-display (MIT). The settings window's icons are from Microsoft's
  Fluent UI System Icons (licenses/FluentSystemIcons-LICENSE.txt), and
  zmural is written in Zig (licenses/Zig-LICENSE.txt). Details and thanks
  are in THIRD_PARTY_NOTICES.md.
