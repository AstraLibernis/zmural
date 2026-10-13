# Windows pass

A by-hand check of zmural on a real Windows 11 desktop, done before each release. CI builds and
runs the Windows zip on a server, but nothing there clicks the settings window or the tray, so
this is how the Windows column of [CONTROLS.md](CONTROLS.md) gets ticked. About an hour.

Use the release's own zip (or the draft release's, before publishing), unzipped into a new
folder. Tick each line that does what it says; for one that doesn't, write what happened next to
it and keep going. Copy the finished list into `notes/windows-pass-<date>.md`.

## Install and first run

- [ ] SmartScreen may warn (not signed yet); "Run anyway" starts it
- [ ] First start: a star in the tray, Prism on the desktop, the settings window on Welcome
- [ ] A balloon says zmural starts with Windows
- [ ] Start menu has zmural; Settings > Apps lists it

## Tray

- [ ] Left click: the settings window opens (a second click brings it to the front)
- [ ] Right click: the menu. Each item does what it says: Paused, Muted, > Next, < Previous, Shuffle, Rescan library, Start with Windows, Settings..., Open log file, Quit zmural

## Settings window

Sidebar: each of Welcome, Wallpapers, Playback, Pausing, General opens its page.

Player card (bottom left):
- [ ] Previous, Pause/Play, Next, Mute/Unmute each work
- [ ] With a window maximized over the desktop, it says "Paused: a window is maximized" (or another reason), not "Playing"

Welcome:
- [ ] A wallpaper tile shows it
- [ ] Wallpapers (button) opens the Wallpapers page
- [ ] Each folder's Open opens it in Explorer
- [ ] Add folder: Windows' folder picker; the folder joins the library
- [ ] Open file: Windows' file picker; the file shows. A `.zip` imports, and a message says so

Wallpapers:
- [ ] Rescan picks up a file just copied into `Videos\Wallpapers`
- [ ] Open file, Add folder (as on Welcome)
- [ ] Click a tile: it shows
- [ ] Right click a tile: Show on desktop, Show in folder (Explorer opens with the file selected)
- [ ] Two wallpapers with the same name in different folders show their folders: "sun.png · Sunsets"

Playback:
- [ ] Fill: Crop, Fit, Stretch, Center each change the desktop
- [ ] Volume slider; Mute and Pause switches
- [ ] Change every and Order
- [ ] Customise (a video): a slider moves the picture live; Reset puts it back

Pausing:
- [ ] A rule's Nothing / Mute / Pause / Stop changes when it pauses (try Fullscreen with a fullscreen video)
- [ ] Add app (pick an .exe), then its × removes it
- [ ] Wait before resuming slider

General:
- [ ] Start with Windows: off, then on (Task Manager's Startup apps agrees)
- [ ] Library folders: Add folder, and × removes one
- [ ] Log file > Open: Notepad with zmural.log
- [ ] Reset: asks first; No changes nothing; Yes puts playback and pausing back
- [ ] Uninstall: asks first; No changes nothing (Yes at the very end)

Keyboard: Tab, the arrows, Enter, Escape move and press as the README says.

## Wallpapers

- [ ] A video, a picture, an animated GIF
- [ ] A web page (an `.html` file)
- [ ] A file that isn't a video (rename a `.txt` to `.mp4`): a balloon says zmural can't show it, and the last one comes back
- [ ] Two monitors, if you have them: right click a tile, "Show on monitor 2"

## Command line (from the zmural folder)

- [ ] `zmural-console status`
- [ ] `zmural-console apply <a .txt renamed .mp4>` fails, exit code 1, saying why (`echo %errorlevel%`)
- [ ] `zmural-console apply <a real video>` exits 0
- [ ] `zmural-console export <a wallpaper's name>` writes a zip here
- [ ] `zmural-console import <that zip>` imports it

## Hand edits

- [ ] Put `volume = "loud"` in `%APPDATA%\zmural\settings.toml`: a balloon names the line, once

## Crashes and updates

- [ ] Restart Explorer (Task Manager): the wallpaper and the tray icon come back
- [ ] With a video playing, suspend its renderer (Resource Monitor > CPU, right-click the `zmural.exe` whose command line has `--renderer`, Suspend process): within about 20 s it is replaced and the video moves again; the log says "no answer for 10 s"

## Uninstall (last)

- [ ] General > Uninstall > Yes: zmural is gone at once, the desktop gets its own wallpaper back, a message says it's done
- [ ] The Start menu entry, Settings > Apps entry and `%APPDATA%\zmural` are gone; your wallpapers stay
