# Omni Launcher

One window for every game on your machine, whatever packaging it came in.
A Flutter desktop launcher in the spirit of Playnite and Cartridges: a cover
wall first, details on demand.

![The library](docs/screenshots/library.jpg)

## What it finds

| Source | Detected from | Started with |
| --- | --- | --- |
| Steam | `steamapps/libraryfolders.vdf` + `appmanifest_*.acf` (installed only) | `steam -applaunch <appid>` |
| Flatpak | exported `.desktop` entries with `Categories=Game` | `flatpak run <app-id>` |
| AppImage | AppImage magic bytes (`41 49 02` at offset 8) in the configured folders | the file itself |
| Heroic / Epic / GOG / Amazon | Heroic's `legendaryConfig`/`gog_store`/`nile_config`, standalone `legendary`/`nile` | `xdg-open heroic://launch/<id>` |
| Epic Games Launcher | the native launcher's data root | `xdg-open com.epicgames.launcher://apps/…` |
| Lutris | `~/.config/lutris/games/*.yml` | `lutris lutris:rungameid/<id>` |
| Faugus | Faugus' `games.json` (flatpak or native) | `faugus-launcher --game <title>` |
| Desktop entries | `*.desktop` with `Categories=Game` outside flatpak exports | `gtk-launch <file>` |
| By hand | the `manual` list in the config | your command |

## What it does beyond launching

![Game details](docs/screenshots/details.jpg)

* **Cover art** from Steam's own library cache, or from SteamGridDB with your
  own API key: portrait posters on a 168x252 tile, whatever shape the window is.
* **A sidebar that folds** down to an icon rail, for the source list you set up
  once and then never look at again.
* **Games that are also Steam shortcuts** (RetroDECK, for instance) are
  launched through Steam, which is what gives them Steam Input and the overlay.
* **Playtime and last played**, per game. Only time that was actually observed
  is counted, so a launcher that dies mid-game cannot invent hours.
* **Rename** any entry. The new name is what the wall, the search and the
  SteamGridDB lookup use, so an awkward name can be turned into the title
  SteamGridDB knows. The discovered name is kept, so it can be reset.
* **Hide** entries you never launch, **close the launcher with the game** for
  launchers that outlive their game, and add games by hand.
* **Appearance**: System / Dark / Light, plus an accent colour from the GNOME
  basic palette. The window's title bar follows the palette too.

![Settings](docs/screenshots/settings.jpg)

Settings holds the theme mode, the accent colour, the SteamGridDB key, the
AppImage folders, hidden games and hand-added games.

## Install

### Flatpak

Download `OmniLauncher-x86_64.flatpak` from the
[releases page](https://github.com/PuppyCodingBadly/omni-launcher/releases) and
install the single file:

```sh
flatpak install --user ./OmniLauncher-x86_64.flatpak
```

The release also carries a `.flatpakref` pointing at the project's flatpak
repository, which is what lets `flatpak update` pick up later releases:

```sh
flatpak install --user --from \
  https://github.com/PuppyCodingBadly/omni-launcher/releases/latest/download/io.github.PuppyCodingBadly.OmniLauncher.flatpakref
```

### From source

Needs the Flutter SDK and a GTK3 development toolchain (clang, cmake, ninja,
pkg-config, libgtk-3-dev). On an immutable distribution, build inside a
container that has those:

```sh
git clone https://github.com/PuppyCodingBadly/omni-launcher.git
cd omni-launcher
flutter build linux --release
./install.sh          # ~/.local/opt + desktop entry + icon
```

## Use

Launch "Omni Launcher" from your app grid. Click a tile to select it, double
click (or the Play button on hover) to start the game. `Ctrl+F` search,
`Ctrl+R` rescan, `Esc` close the details panel.

The sidebar filters by source and folds to an icon rail with the chevron in its
header: the same filters, each with its label and count in the tooltip. It
stays folded next time, and hidden games live behind *Show hidden*, which the
rail keeps too.

The detail panel has *Launch*, *Open folder*, *Copy* (the exact argv), *Find
art*, *Rename*, *Hide* and *Close the launcher with the game*.

## Configuration and files

| Path | Contents |
| --- | --- |
| `~/.config/omnilauncher-flutter/config.json` | hidden games, AppImage folders, hand-added games, appearance, the folded sidebar, SteamGridDB key, pinned artwork, renames |
| `~/.cache/omnilauncher-flutter/games.json` | last scan, for an instant start |
| `~/.cache/omnilauncher-flutter/covers/` | downloaded Steam capsules and picked SteamGridDB art |
| `~/.local/state/omnilauncher-flutter/launch.log` | every launch, with argv, plus the game's own output |
| `~/.local/state/omnilauncher-flutter/playtime.json` | played time and last played per game |

Nothing is uploaded anywhere. The only network use is cover art: Steam's CDN
and, when you set a key, SteamGridDB.

## SteamGridDB

SteamGridDB has no anonymous tier, so it needs your own API key
(steamgriddb.com → Preferences → API). Paste it under **Settings → Artwork**,
press *Test*, then either turn on **Fetch SteamGridDB art automatically** or use
**Find art** on a single game to browse the candidates (thumb, style, size,
author) and pin one. Picked art is stored per game, so it survives rescans.

![Picking cover art from SteamGridDB](docs/screenshots/steamgriddb.jpg)

## Packaging it yourself

`flatpak/` contains the manifest, the AppStream metadata and a build script:

```sh
flatpak install --user flathub org.flatpak.Builder \
    org.freedesktop.Sdk//25.08 org.freedesktop.Sdk.Extension.llvm20//25.08
flatpak/build.sh
```

The LLVM extension is required rather than optional: Flutter's Linux build
hard-codes `CC=clang`/`CXX=clang++` and the base freedesktop SDK only ships gcc.

The permissions it asks for, and why:

| Permission | Why |
| --- | --- |
| `--filesystem=host` | the library *is* the host's games: Steam libraries, Heroic/Lutris/Faugus data, the Epic launcher's data root, other apps' flatpak data, the desktop entries |
| `--talk-name=org.freedesktop.Flatpak` | launching a game means running the host's `steam`/`flatpak`/`xdg-open`/`lutris` through `flatpak-spawn --host` |
| `--share=network` | cover art |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | a GTK window with GPU rendering |
| `--socket=pulseaudio` | games that make noise |

Sharing it with someone else: send them the `.flatpak` file, serve
`flatpak/repo` over the network and hand over a `.flatpakref` whose `Url=`
points at you, or push a `v*` tag, and `.github/workflows/flatpak.yml` builds
the bundle, publishes the repository and the landing page in `site/` to
`gh-pages`, and attaches the bundle plus the generated `.flatpakref` to the
release.

## License

MIT. See [LICENSE](LICENSE).
