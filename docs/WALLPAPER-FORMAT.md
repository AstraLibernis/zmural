# The wallpaper format

A plain video, picture or GIF needs nothing extra: put it in a library folder. A **wallpaper package** adds a title, an author and settings the user can change.

A package is a folder (or a `.zip` of one):

```
my-wallpaper/
├── zmural.toml        # metadata + typed properties
├── preview.webp       # not used yet
└── index.html | video.mp4 | …
```

```toml
title   = "Neon Rain"
author  = "someone"
license = "CC-BY-4.0"
type    = "web"              # video | image | web
entry   = "index.html"
audio   = true               # reserved: the audio spectrum is planned

[properties.speed]
kind = "slider"
label = "Rain speed"
default = 1.0
min = 0.1
max = 3.0
step = 0.1

[properties.tint]
kind = "color"
label = "Tint"
default = "#3fa9f5"
```

- Video and picture packages work on both OSes; web packages on Windows only, so far.
- A web wallpaper is always offline (see the README's [Security](../README.md#security) section). Packages written for an earlier zmural may say `network = true`; it is ignored.
- Property kinds: `slider` (`min`, `max`, `step`), `color` (`"#rrggbb"`), `dropdown` (`options = ["a", "b"]`), `checkbox` and `text`.
- Property edits are stored per wallpaper (per monitor is planned). The package's own files stay pristine, and "reset" always works: `zmural-console props`, `zmural-console prop <name> <value>`, `zmural-console prop --reset`.
- A web page reads its values from `window.zmural.properties` and hears about changes with `window.zmural.on("property", ({ name, value }) => …)`.
- Web wallpapers are planned to receive audio, now-playing, system stats and pause events through the same small JS API, and a compatibility shim to let Lively web wallpapers work unmodified.

## Sharing a package

`zmural-console export <wallpaper> [file.zip]` packs a wallpaper, a package or a folder of them into a zip that imports anywhere (under 4 GiB for now); `zmural-console import <file.zip>` unpacks one. Lively Wallpaper packages import too: they get a `zmural.toml` made from their `LivelyInfo.json` and `LivelyProperties.json`. Their videos and pictures work everywhere, and their web pages on Windows (Lively's settings don't reach a Lively page yet).
