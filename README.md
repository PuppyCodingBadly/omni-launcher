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
| Prism Launcher | the `instances/*/instance.cfg` of a native or flatpak install | `prismlauncher -l <instance>` |
| Bottles | each bottle's `library.yml` (native or flatpak) | `bottles-cli run -b <bottle> -p <program>` |
| Desktop entries | `*.desktop` with `Categories=Game` outside flatpak exports | `gtk-launch <file>` |
| By hand | the `manual` list in the config | your command, with `~` and `$VAR` expanded |

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
* **Playing, Stop, and what happened.** A running game says `PLAYING` on its
  tile, and the panel's Launch button becomes Stop (SIGTERM, then SIGKILL after
  five seconds). Two quick clicks cannot start the same game twice. A game that
  exits within ten seconds is reported with a **View log** action instead of
  looking like a success. These follow the process the launcher starts; a
  launcher that hands the game to a client and exits (`steam -applaunch`,
  Heroic/Epic through `xdg-open`) is not reported as a quick exit and does not
  get a lasting `PLAYING` state.
* **Tags and collections.** Steam collections and Lutris categories arrive as
  tags; any game can get your own from its cog. **Filters** (the funnel in the
  header) stacks tags with status filters: Unplayed, Not played in 90 days, No
  cover, Not installed. Search reads tags, paths and commands too, and matches
  acronyms (`tf2` finds Team Fortress 2) and subsequences.
* **Per-game launch options.** A wrapper (`gamemoderun`, `mangohud`,
  `prime-run`), extra arguments, environment variables and a working folder,
  all under the game's cog and applied only to that game.
* **Installs that are not ready.** Steam's update flags and download progress
  show on the tile and in the panel; a game you played that disappears from its
  source stays in the library as **Not installed**, with its playtime, until
  you remove it.
* **A command palette.** `Ctrl+K` searches games and commands from the
  keyboard: Enter opens, Ctrl+Enter launches.
* **Window behaviour.** A second launch of the app brings the existing window
  back instead of opening a duplicate; **Settings → Window** can hide it
  while a game runs and keep a tray icon (a GTK3 tray icon, so shells without a
  tray host, including GNOME on Wayland, show nothing). Hiding keeps the window
  mapped, so the session watcher keeps running and brings it back when the game
  exits. Coming back to the window rescans, so a game installed meanwhile
  appears without `Ctrl+R`.
* **Launch log.** Every launch's argv and the game's own output are in
  **Settings → Files**; the cog opens the same log per game.
* **A wall you can sort and walk.** Order it by name, recently played or most
  played; favorites stay first whichever you pick. Arrow keys or a gamepad's
  D-pad step one tile sideways and one row up or down, `Enter` (or A) launches
  the focused tile and `Space` (or B) selects it.
* **Bulk hide.** The checklist button marks games instead of opening them, and
  hides every marked one at once.
* **Recently played**, on a shelf above the wall: the last ten games you
  started, newest first, each with how much and how recently you played it.
  The shelf follows the wall's filters and steps aside while you search.
* **Plugins**: a folder with a `plugin.json` in it and a program the launcher
  runs, JSON in and JSON out, in any language. A plugin can answer lookups,
  offer **actions** for a game, and run **pre-launch** and **post-exit** hooks.
  Each capability is declared in its manifest and allowed or refused from its
  shield button; actions and hooks are off until you allow them. **Settings →
  Plugins** is a store: it lists what the launcher's repository offers,
  installs one into your plugin folder and removes it again. HowLongToBeat is
  in the list, and ships with the launcher too.
* **Rename** any entry. The new name is what the wall, the search and the
  SteamGridDB lookup use, so an awkward name can be turned into the title
  SteamGridDB knows. The discovered name is kept, so it can be reset.
* **Hide** entries you never launch and add games by hand.
* **Close a launcher with its game**: under **Settings → Launchers**, choose
  which launcher clients (Steam, Heroic, Lutris, …) quit once the game they
  started exits. The choice is per launcher, not per game; a launcher that was
  already running before the game stays alone.
* **Appearance**: System / Dark / Light, plus an accent colour from the GNOME
  basic palette. The window's title bar follows the palette too, and the window
  reopens at the size it was last resized to.

![Settings](docs/screenshots/settings.jpg)

Settings holds the theme mode, the accent colour, the SteamGridDB key, the
AppImage folders, hidden games, hand-added games, which launchers close with
their games, the window behaviour, plugin permissions and the plugin store.
Tags, launch options and the rest of a single game live in its cog.

## Install

### Flatpak

```sh
flatpak install --user --from \
  https://github.com/PuppyCodingBadly/omni-launcher/releases/latest/download/io.github.PuppyCodingBadly.OmniLauncher.flatpakref
```

That installs from the project's flatpak repository, so `flatpak update` picks
up later releases. Each release also carries `OmniLauncher-x86_64.flatpak`, a
standalone bundle of that release's build, for installing without a repository:

```sh
flatpak install --user ./OmniLauncher-x86_64.flatpak
```

### From source

Needs the Flutter SDK and a GTK3 development toolchain (clang, cmake, ninja,
pkg-config, libgtk-3-dev). On an immutable distribution, build inside a
container that has those:

```sh
git clone https://github.com/PuppyCodingBadly/omni-launcher.git
cd omni-launcher
flutter build linux --release
./dev.sh              # runs the build from this checkout, nothing installed
```

`./install.sh` is for a real install instead: it copies the bundle to
`~/.local/opt/omni-launcher`, links it as `~/.local/bin/omni-launcher` and
writes a desktop entry and an icon, which is what puts it in the app grid.
`./dev.sh` runs a build you are working on where it is, so nothing outside the
checkout is touched.

## Use

Launch "Omni Launcher" from your app grid. Click a tile to select it, double
click (or the Play button on hover) to start the game; with a tile focused,
`Enter` (or a gamepad's A) launches it and `Space` (or B) selects it. The arrow
keys and a D-pad walk the wall, one tile sideways and one row up or down, and
the tile the keyboard or gamepad is on lifts the way a hovered one does.
`Ctrl+F` search, `Ctrl+K` the command palette, `Ctrl+R` rescan, `Esc` close the
details panel.

A running tile says `PLAYING`; `Enter` on it (or its hover button) stops it.
Search ranks matches, understands acronyms and subsequences, and looks at tags,
paths and commands. A rescan asked for while one is already running joins it
rather than starting a second; a source that throws is named in the status bar
and the rest of the library still arrives. Coming back to the window rescans a
library older than thirty seconds.

The sort button in the header orders the wall by name, recently played or most
played. Whichever is picked, favorites stay in front. The checklist beside it
is selection mode: taps mark games instead of opening them, and one button
hides every marked game.

The star in a game's detail panel pins it as a favorite: favorites sort first
on the wall and keep a star on their cover. The same pin is in each tile's
actions menu.

The sidebar filters by source and folds to an icon rail with the chevron in its
header: the same filters, each with its label and count in the tooltip. It
stays folded next time, and hidden games live behind *Show hidden*, which the
rail keeps too. The funnel in the header stacks tag and status filters; the
chips under it remove one at a time.

The detail panel keeps *Launch* (or *Stop*) and the game's facts to itself;
*Open folder*, *Copy* (the exact argv, launch options included), *Launch
options…*, *Edit tags…*, *Find art*, *Rename*, *Launch log*, *Hide* and *Remove*
live behind the cog in its header. *Close the launcher with the game* is a
launcher-wide choice, so it lives in Settings, not on a single game. A game that
went missing keeps its panel and gains *Not installed*, *Open store page* and
*Remove from library*. Under the facts, each plugin gets a section with what it
answered and any actions it may run; the button that asks it is there until it
has an answer.

## Configuration and files

| Path | Contents |
| --- | --- |
| `~/.config/omnilauncher-flutter/config.json` | hidden games, AppImage folders, hand-added games, appearance, the folded sidebar, SteamGridDB key, pinned artwork, renames, favorites, sort order, tags, launch options, forgotten games, which launchers close with their games, plugin permissions, window size and behaviour |
| `~/.cache/omnilauncher-flutter/games.json` | last scan, for an instant start |
| `~/.cache/omnilauncher-flutter/covers/` | downloaded Steam capsules and picked SteamGridDB art |
| `~/.local/state/omnilauncher-flutter/launch.log` | every launch, with argv, plus the game's own output |
| `~/.local/state/omnilauncher-flutter/playtime.json` | played time and last played per game |
| `~/.cache/omnilauncher-flutter/plugin_answers.json` | what the plugins answered, per plugin and game |
| `~/.local/share/omnilauncher-flutter/plugins/` | the plugins themselves, one folder each |

Nothing is uploaded anywhere. The launcher's own network use is cover art:
Steam's CDN, and SteamGridDB when you set a key — plus the plugin catalogue and
any plugin you install from it. A plugin does whatever its author wrote, which
is why you get to see what you are running.

The config and the scan cache are written through a sibling temporary file and
a rename, so a crash halfway through writing leaves the previous file intact.
Both carry a version number, and a file an older build wrote still loads. The
config is `chmod 600`, because it holds the SteamGridDB key.

The flatpak keeps its files in those same places: it uses the host's XDG
folders rather than the sandbox's own, so a native build and the flatpak share
one set of hidden games, renames and playtime.

## SteamGridDB

SteamGridDB has no anonymous tier, so it needs your own API key
(steamgriddb.com → Preferences → API). Paste it under **Settings → Artwork**,
press *Test*, then either turn on **Fetch SteamGridDB art automatically** or use
**Find art** on a single game to browse the candidates (thumb, style, size,
author) and pin one. Picked art is stored per game, so it survives rescans.

![Picking cover art from SteamGridDB](docs/screenshots/steamgriddb.jpg)

## Plugins

A plugin teaches the launcher one more thing about your games. The one that
ships with it is a HowLongToBeat lookup: how long the game takes, main story
through completionist, next to the game's own facts in the detail panel.

A plugin is a folder with a `plugin.json` in it and a program it names:

```
~/.local/share/omnilauncher-flutter/plugins/
  howlongtobeat/
    plugin.json
    hltb.py
```

```json
{
  "id": "howlongtobeat",
  "name": "HowLongToBeat",
  "description": "How long the game is.",
  "author": "PuppyCodingBadly",
  "action": "Look up on HowLongToBeat",
  "command": ["python3", "hltb.py"],
  "version": 1
}
```

The launcher runs `command` in the plugin's own folder and writes one JSON
object to its stdin:

```json
{
  "action": "lookup",
  "game": {
    "id": "steam:427410",
    "key": "427410",
    "name": "Abiotic Factor",
    "source": "steam",
    "path": "/games/abiotic",
    "cwd": null,
    "command": ["steam", "-applaunch", "427410"],
    "extra": {"appid": "427410"}
  }
}
```

`source` is `search` when the lookup came from the settings page instead of
from a game. The plugin answers with one JSON object on its stdout:

```json
{
  "fields": [
    {"label": "Main story", "value": "54h 32m"},
    {"label": "Main + extra", "value": "75h 28m"}
  ],
  "url": "https://howlongtobeat.com/game/149774"
}
```

`fields` are shown in that order, `url` (optional) becomes a link to the page
the answer came from, and `{"error": "…"}` says why there is no answer. Every
other way a plugin can go wrong — a crash, a non-zero exit, silence for 30
seconds, more than 256 KiB of output, a reply that is not JSON — is reported in
the panel as that plugin's answer, so a broken plugin is visible rather than
silent. Answers are cached per plugin and game
(`~/.cache/omnilauncher-flutter/plugin_answers.json`), so selecting a game
again does not ask the site again.

### Actions and hooks

A plugin can declare more than lookups:

```json
{
  "capabilities": ["lookup", "actions", "hooks"],
  "actions": [
    {"id": "backup", "name": "Back up saves", "description": "Copy them aside"}
  ],
  "hooks": ["pre_launch", "post_exit"]
}
```

A manifest without `capabilities` keeps the one every older plugin had:
`lookup`. `actions` become buttons in the plugin's panel section; `hooks` run
before the game starts and after it exits. Each request is one JSON object on
stdin, with the same `game` payload as a lookup (and the game's effective
`tags`):

```json
{"action": "action", "id": "backup", "name": "Back up saves", "game": {…}}
{"action": "pre_launch", "game": {…}}
{"action": "post_exit", "game": {…}}
```

An action answers like a lookup (`fields`/`url`/`error`). A hook may print
nothing and exit 0; a non-zero exit is reported in the status bar. A failing
pre-launch hook does not cancel the launch: the game still starts, and the
failure is visible.

Actions and hooks are off until you allow them: the shield beside an installed
plugin lists its declared capabilities, and installing grants only `lookup`.
A plugin that does not declare a capability is never sent that request.

### The store

**Settings → Plugins** reads a catalogue from the launcher's own repository and
offers what it lists: *Install* unpacks a plugin into your plugin folder and
the launcher starts using it straight away — the plugin gets its section in the
detail panel, with the button that asks it about the game you have selected.
*Update* appears when the catalogue has a higher version than the one you have,
and the bin beside it removes the plugin's folder. The catalogue is read from

```
https://raw.githubusercontent.com/PuppyCodingBadly/omni-launcher/main/plugins/index.json
```

and each entry names a `.zip` beside it, so the list and the archives it points
at always come from the same commit. Each entry also carries the archive's
SHA-256: an install refuses an archive that does not match it. The catalogue
and the archives are fetched over https only — a redirect to plain http is
refused like the address itself. A plugin that is only on your machine —
one you wrote, or one you dropped in by hand — is listed under the catalogue as
*installed here, and not in the list*.

A plugin runs as you, on the host, outside the flatpak sandbox: treat one you
did not write as a program you are running, because that is exactly what it is.

### Writing one

A plugin lives in `plugins/<id>/` in this repository: its files, and a
`plugin.json` naming the program to run. `plugins/build.sh` turns every folder
there into the archive the store hands out and rewrites `plugins/index.json`
from the manifests, so publishing a plugin is a pull request that adds the
folder and the output of that script.

The shipped HowLongToBeat plugin is installed into your plugin folder at start
up as well, so it works before anything has been downloaded; a copy you have
edited stays as it is until the shipped copy's `version` in its manifest is
higher.

## Packaging it yourself

`flatpak-flutter.yml` is the manifest that is written by hand. `flatpak-flutter`
turns it into `io.github.PuppyCodingBadly.OmniLauncher.yml` — the manifest that
is actually built — and into the `generated/` folder that manifest reads: the
Flutter SDK, its engine artifacts and every pub package as sources, so the build
itself needs no network.

```sh
git clone https://github.com/TheAppgineer/flatpak-flutter
./flatpak-flutter/flatpak-flutter.py flatpak-flutter.yml
```

Run that again whenever the dependencies or the Flutter version change, and
commit what it writes. `flatpak/` holds the AppStream metadata and a build
script, and `flathub.json` keeps the Flathub build on x86_64, the architecture
the engine artifacts are verified on.

```sh
flatpak install --user flathub org.flatpak.Builder \
    org.freedesktop.Sdk//26.08 org.freedesktop.Sdk.Extension.llvm22//26.08
flatpak/build.sh
```

The LLVM extension is required rather than optional: Flutter's Linux build
hard-codes `CC=clang`/`CXX=clang++` and the base freedesktop SDK only ships gcc.

The permissions it asks for, and why:

| Permission | Why |
| --- | --- |
| `~/.config`, `~/.cache`, `~/.local/state`, `~/.local/share` + `/omnilauncher-flutter` | the launcher's own config, cache, cover art and plugins, kept on the host so a native build and the flatpak share one library |
| `~/.steam:ro`, `~/.local/share/Steam:ro`, `~/.config/lutris:ro`, `~/.local/share/lutris:ro`, `~/.config/heroic:ro`, `~/.config/legendary:ro`, `~/.config/nile:ro`, `~/.local/share/faugus-launcher:ro`, `~/.local/share/com.epicgames.eglv2:ro` | the launchers whose libraries it reads — read-only, because a game is started on the host, not from in here |
| `~/.var/app/{com.valvesoftware.Steam,net.lutris.Lutris,com.heroicgameslauncher.hgl,io.github.Faugus.faugus-launcher}:ro` | the same launchers, installed as flatpaks |
| `~/.local/share/applications:ro` | the desktop entries that advertise games |
| `~/AppImages:ro`, `~/Applications:ro`, `~/AppImage:ro`, `~/Games:ro`, `~/Downloads:ro`, `~/.local/bin:ro` | the folders AppImages are looked for in by default — read-only, because an AppImage that is not executable yet is chmodded on the host side |
| `/mnt:ro`, `/run/media:ro` | Steam libraries and AppImage folders on other drives |
| `/opt:ro` | the last of the default AppImage folders |
| `host-os:ro` | the host's own desktop entries and icons, where the games that are not flatpaks advertise themselves |
| `--talk-name=org.freedesktop.Flatpak` | launching a game means running the host's `steam`/`flatpak`/`xdg-open`/`lutris` through `flatpak-spawn --host` |
| `--share=network` | cover art |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | a GTK window with GPU rendering |

Not `--filesystem=home`: an AppImage folder outside the list above is not
reachable from inside the flatpak, which is the price of asking for the
narrowest set of paths that still finds everything a default install has.

One honest caveat: `--talk-name=org.freedesktop.Flatpak` plus
`flatpak-spawn --host` means the sandbox is filesystem namespacing, not a
security boundary for what the launcher deliberately runs — a game, a plugin,
or the AppImage it just chmodded all execute on the host as you.

Sharing it with someone else: send them the `.flatpak` file, serve
`flatpak/repo` over the network and hand over a `.flatpakref` whose `Url=`
points at you, or push a `v*` tag, and `.github/workflows/flatpak.yml` runs
`flutter analyze`, `flutter test`, validates the AppStream metadata and checks
that `plugins/` still matches the sources it was built from before it builds
the bundle, publishes the repository and the landing page in `site/` to
`gh-pages`, and attaches the bundle plus the generated `.flatpakref` to the
release. A tag whose manifest pins a commit it does not contain is refused,
rather than released as the wrong code.

## License

MIT. See [LICENSE](LICENSE).
