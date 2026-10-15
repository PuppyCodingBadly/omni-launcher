# Omni Launcher (Flutter)

One window for every game on your machine, whatever packaging it came in.
A Flutter desktop launcher in the spirit of Playnite and Cartridges: a cover
wall first, details on demand.

## What it finds

| Source | Detected from | Started with |
| --- | --- | --- |
| Steam | `steamapps/libraryfolders.vdf` + `appmanifest_*.acf` (installed only) | `steam -applaunch <appid>` |
| Flatpak | exported `.desktop` entries with `Categories=Game` | `flatpak run <app-id>` |
| AppImage | AppImage magic bytes (`41 49 02` at offset 8) in the configured folders | the file itself (`chmod +x` if needed) |
| Heroic / Epic | Heroic's `legendaryConfig`/`gog_store`/`nile_config`, standalone `legendary`/`nile` | `xdg-open heroic://launch/<id>` or `legendary launch <id>` |
| Epic Games Launcher | the new native launcher's data (`~/.local/share/com.epicgames.eglv2`) | `xdg-open com.epicgames.launcher://apps/<ns>:<item>:<app>?action=launch&silent=true` |
| Lutris | `~/.config/lutris/games/*.yml` | `lutris lutris:rungameid/<id>` |
| Faugus | Faugus' `games.json` (flatpak or native) | `flatpak run io.github.Faugus.faugus-launcher --game <title>` |
| Desktop entries | `*.desktop` with `Categories=Game` outside flatpak exports | `gtk-launch <file>` |
| By hand | the `manual` list in the config | your command |

Steam covers come from Steam's own library cache when present, otherwise the
portrait capsule is downloaded once from the Steam CDN into
`~/.cache/omnilauncher-flutter/covers`. Everything else uses its icon file, a
raster icon-theme lookup, or a letter tile.

## Cover art

Artwork is resolved in this order, and only the last two steps touch the
network:

1. art you picked for that game (SteamGridDB, remembered in the config)
2. Steam's own `librarycache` portrait capsule
3. the Steam CDN (`library_600x900.jpg`, `library_600x900_2x.jpg`, `header.jpg`),
   cached once per app id, failures remembered in a `.missing` marker
4. the game's icon file, then a raster icon-theme lookup, then a letter tile

### SteamGridDB

SteamGridDB has no anonymous tier, so it needs your own API key
(`steamgriddb.com/profile/preferences/api`). Paste it under
**Settings → Artwork**, press *Test* to confirm it, then either

* turn on **Fetch SteamGridDB art automatically** — games with no local cover
  are looked up by Steam app id first, then by name, and the first grid is
  cached and remembered, or
* use **Find art (SteamGridDB)** on any game to browse the candidates (thumb,
  style, size, author) and pin one. *Reset to automatic artwork* undoes it.

Picked art is stored per game id in the config, so it survives rescans. Only
`www.steamgriddb.com` and its CDN are contacted, and only while a key is set.

Nothing else ever touches the network.

## Layout

```
lib/
  main.dart                     app entry point
  src/
    model/game.dart             Game + SourceKind (pure Dart, no Flutter import)
    config.dart                 ~/.config/omnilauncher-flutter/config.json
    paths.dart                  XDG paths
    covers.dart                 artwork resolution + Steam CDN cache
    launcher.dart               detached launch, launch log
    state/library_controller.dart   discovery, filtering, persistence
    sources/                    one file per source + registry.dart
    ui/                         theme, library page, tile, detail panel, settings
    util/                       desktop entries, Steam VDF, JSON, shell quoting
```

## Build and run

The Linux build needs a GTK3 development toolchain (`clang`, `cmake`, `ninja`,
`pkg-config`, `libgtk-3-dev`); on an immutable distribution, build inside a
container that has those:

```sh
flutter build linux --release
./build/linux/x64/release/bundle/omni_launcher
```

`install.sh` copies the bundle to `~/.local/opt/omni-launcher`, adds the
desktop entry and icon, and puts `omni-launcher` on `PATH`.

### Flatpak

```sh
flatpak install --user flathub org.flatpak.Builder \
    org.freedesktop.Sdk//25.08 org.freedesktop.Sdk.Extension.llvm20//25.08
flatpak/build.sh
```

The LLVM extension is required, not optional: Flutter's Linux build hard-codes
`CC=clang`/`CXX=clang++`, and the base freedesktop SDK only ships gcc.

The flatpak manifest in `flatpak/` builds the Flutter SDK and the app inside
the freedesktop SDK. The permissions it asks for, and why:

| Permission | Why |
| --- | --- |
| `--filesystem=host` | the library *is* the host's games: Steam libraries, Heroic/Lutris/Faugus data, the Epic launcher's data root, other apps' flatpak data, the desktop entries |
| `--talk-name=org.freedesktop.Flatpak` | launching a game means running the host's `steam`/`flatpak`/`xdg-open`/`lutris`, which needs `flatpak-spawn --host` |
| `--share=network` | Steam CDN and SteamGridDB cover art |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | a GTK window with GPU rendering |
| `--socket=pulseaudio` | games that make noise |

## Use

Launch "Omni Launcher" from the app grid. Click a tile to select it, double
click (or the Play button on hover) to start the game. `Ctrl+F` search,
`Ctrl+R` rescan, `Esc` close the details panel. The sidebar filters by source;
hidden games live behind *Show hidden*.

## Appearance

Settings → **Appearance** carries three things:

* **System / Dark / Light.** Dark is the default and is unchanged from the first
  release; Light is a full second palette. The GTK header bar and the window
  background follow the choice too (they are drawn by GTK, not by Flutter, so the
  palette is pushed to the runner over a small platform channel).
* **Accent colour**, from the GNOME/Adwaita basic palette — Default (the shipped
  violet), Blue, Teal, Green, Yellow, Orange, Red, Pink, Purple, Slate. Pale
  accents get a darker `accentSoft` and black-on-accent text automatically so
  contrast stays readable in both modes.
* **SteamGridDB key** (see below).

## Playtime

Every launch starts a session; the launcher polls the game's pid and closes the
session when the process goes away. Totals and "last played" show up in the
detail panel.

A session is only ever credited with time that was actually observed. The
launcher refreshes a heartbeat at most every 30 seconds and, on the next start,
closes any session still open at the last heartbeat — so a crash costs at most
one tick and can never invent hours. History lives in
`~/.local/state/omnilauncher-flutter/playtime.json`, separate from the config.

## Launching through Steam

A game that is also a Steam **non-Steam shortcut** is launched through Steam
(`steam -applaunch <shortcut id>`) instead of its own command, because that is
what gives it Steam Input, the overlay and Steam's own playtime tracking.
RetroDECK is the case this exists for: its shortcut carries
`FlatpakAppID=net.retrodeck.retrodeck`, so the flatpak entry becomes a Steam
launch. Matching is by that flatpak id first, then by name, and a visible
shortcut always beats a hidden one. The detail panel's COMMAND row always shows
which argv is actually used.

## Renaming and poster shape

* **Rename** (tile menu and detail panel) changes the name the launcher shows,
  searches and — importantly — sends to SteamGridDB, so an awkward entry such as
  `epic games launcher` can be renamed to the title SteamGridDB knows. The
  discovered name is kept, so the override can be reset.
* **Poster shape** follows the window: a square-ish window (aspect 0.9-1.1) asks
  SteamGridDB for square grids (`512x512`, `1024x1024`) and uses square tiles so
  nothing is cropped. Every other aspect keeps the portrait wall.

## Files

| Path | Contents |
| --- | --- |
| `~/.config/omnilauncher-flutter/config.json` | hidden games, AppImage folders, hand-added games, appearance, SteamGridDB key, pinned artwork, renames |
| `~/.cache/omnilauncher-flutter/games.json` | last scan, for an instant start |
| `~/.cache/omnilauncher-flutter/covers/` | downloaded Steam capsules and picked SteamGridDB art |
| `~/.local/state/omnilauncher-flutter/launch.log` | every launch, with argv, plus the game's own output |
| `~/.local/state/omnilauncher-flutter/playtime.json` | played time and last-played per game |
