# waywallen-display, vendored

- Upstream: https://github.com/waywallen/waywallen-display
- Commit: `8ca393885a13634c1e674c33be33c83cfe9e6f02` (version 0.4.1)
- Licence: MIT, Copyright (c) 2026 hypengw (see `LICENSE`). `glibc-2.17.h`
  is MIT, Copyright 2021 Bill Zissimopoulos (its header).
- Vendored by `tools/vendor-waywallen-display.sh`, which also applies every
  change: the socket path (`$XDG_RUNTIME_DIR/zmural/display.sock`), the
  D-Bus name (`org.zmural.Daemon`), the Plasma plugin ID (`org.zmural.kde`),
  the private QML module URIs (`Zmural.Display*`), the GNOME extension's
  UUID (`org.zmural.gnome@zmural`), settings schema, translation domain and
  renderer app ID (`org.zmural.Renderer`), package names, and zmural's
  wording in the KDE and GNOME packages. Don't edit files here by hand:
  change the script and re-run it.
- zmural speaks the same protocol (waywallen-display-v1 v9), so these
  clients work against it unchanged apart from the names.
