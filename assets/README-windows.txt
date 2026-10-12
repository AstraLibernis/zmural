zmural: free, open-source live wallpapers (Windows build)
==========================================================

WHAT IT NEEDS
  Windows 11, x86-64. Web wallpapers use the WebView2 Runtime, which comes
  with Windows 11.

QUICK START
  1. Unzip this folder somewhere it can stay (for example
     %LOCALAPPDATA%\Programs\zmural).
     Keep the wallpapers folder next to zmural.exe.
  2. Run zmural.exe. A star icon appears next to the clock, Prism (the
     wallpaper zmural comes with) shows, and the settings window opens on
     its Welcome page.
  3. Put your own videos, images or GIFs in  Videos\Wallpapers  or
     Pictures\Wallpapers  (Welcome's Open buttons make the folders, wherever
     Windows keeps your Videos and Pictures). They appear on Welcome within
     a few seconds; click one to show it.

THE TRAY MENU
  Paused / Muted       toggle playback and sound (wallpapers start muted)
  > Next, < Previous   step through your library
  Shuffle              play the library in a random order
  Rescan library       pick up files you just added
  Start with Windows   start zmural when you log in (on from the first
                       run; Windows' Startup apps can turn it off too)
  Settings...          the settings window: wallpapers, fill mode, volume,
                       library folders, pause rules (a left click opens it too)
                       Screen readers are not supported there: it draws its
                       own controls. zmural-console does everything it does.
  Open log file        what zmural has been doing
  Quit zmural          stop it and put your normal wallpaper back

  zmural gets out of the way by itself: it pauses (using no CPU or GPU)
  when a game or app is fullscreen, when a window is maximized, when the
  screen is locked, and on battery. The settings window lets you change
  each of these rules.

FROM A TERMINAL
  zmural-console status              what's showing
  zmural-console apply <file>        show a specific video, image or GIF
  zmural-console next | previous     step through the library
  zmural-console pause | play        pause or resume
  zmural-console mute | unmute
  zmural-console autostart on|off|status
  zmural-console quit

FILES
  Settings:  %APPDATA%\zmural\settings.toml
  Log:       %LOCALAPPDATA%\zmural\zmural.log

UPDATING
  Quit zmural (tray menu > Quit zmural), unzip the new version over this
  folder, replacing its files, and start zmural.exe again. Your settings and
  library are kept.

UNINSTALL
  Press Uninstall on the settings window's General page, or in Windows
  Settings > Apps, or run "zmural-console uninstall". It stops zmural and
  removes what it added: Start with Windows, its Start menu and Settings >
  Apps entries, its settings, its log and its web wallpapers' browser data.
  Your wallpapers and their folders are not touched. Then delete this folder.

LICENSES
  zmural is free software under the GNU GPL, version 3 or later
  (LICENSE.txt). It uses libmpv (libmpv-2.dll), an LGPL-2.1 build of mpv
  with FFmpeg under the LGPL-3.0 (licenses\LGPL-2.1.txt,
  licenses\LGPL-3.0.txt; everyone whose work is inside it is credited in
  licenses\libmpv-credits.txt), and Microsoft's WebView2Loader.dll for web
  wallpapers (licenses\WebView2-LICENSE.txt). It is written in Zig
  (licenses\Zig-LICENSE.txt). Details and thanks are in
  THIRD_PARTY_NOTICES.md. libmpv-2.dll is a separate file and can be replaced
  with any compatible build.
