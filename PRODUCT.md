# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Flutter desktop application for Linux (GTK window/header bar, X11 and Wayland), shipped natively and as a Flatpak.

## Users

Linux gamers whose libraries are spread across Steam, Heroic, Epic, GOG, Amazon, Lutris, Faugus, Prism, Bottles, Flatpak, AppImage, and desktop entries. They want one place to see and start what is installed without opening each store or launcher first.

## Product Purpose

Omni Launcher discovers installed games from every store and packaging on the machine, presents them as one cover wall, and launches them through the client that owns them. It also keeps the play history, tags, favorites, launch options, and plugin actions that a store client would keep separately. Success means the user stops checking five launchers to find one game, and a game starts with the same Steam Input, overlay, and environment it would have had from its own client.

## Positioning

The launcher does not replace store clients or reimplement their sandboxes. It keeps their data authoritative, launches through them when they are the thing that makes the game work, and adds a single library, history, and organizing layer on top. That cross-packaging model, including Steam shortcuts for RetroDECK-style games and per-launcher close-with-game behavior, is the part a single-store client cannot truthfully copy.

## Operating Context

Desktop Linux, usually GNOME, on X11 or Wayland. Mouse and keyboard are primary; gamepad traversal and launching are first-class. The window is resizable down to 900x600 and remembers its last size. Games may be installed, updating, missing, or hidden. Network access is optional: cover fetching needs a SteamGridDB key, plugins need their own endpoints, and the rest of the library works offline.

## Capabilities and Constraints

- Discovery is read-only for every store; launching goes through the owning client (`steam -applaunch`, `xdg-open heroic://…`, `lutris lutris:rungameid/…`, `flatpak run`, the AppImage itself, or a user command).
- The library, playtime, tags, favorites, launch options, hidden set, renames, skips, window size, and plugin grants persist in the user's config, cache, and state directories shared by the native build and the Flatpak.
- Playtime only counts observed sessions. A launch handed to a client with no process record is not invented as a quick exit.
- Plugins are external programs, JSON in and JSON out, with declared and per-capability allowed actions and hooks.
- Keyboard shortcuts: `Ctrl+F` search, `Ctrl+R` rescan, `Ctrl+K` command palette. Arrow keys/D-pad walk the wall, Enter/A launches, Space/B selects.
- No server, account, telemetry, or bundled recommendation feed.
- The app is a native desktop surface, not a web page; browser-only assumptions do not transfer.

## Brand Commitments

The product name is Omni Launcher. The existing application icon and desktop entry name are binding. The product voice is concrete and technical, not marketing copy.

## Evidence on Hand

- `README.md`: feature inventory, source table, install paths, and configuration layout.
- `docs/screenshots/`: the current interface at 1400x900, captured from the real library.
- A real local library (about 95 games across five sources) and the Steam/SteamGridDB cover caches were used to review the current interface at 1400x900.

## Product Principles

1. One wall, real sources: every entry is launchable through the mechanism its store already trusts.
2. History is earned: show only playtime and exits that were observed.
3. The keyboard is a first-class controller: every core action has a key or gamepad path.
4. Offline is a normal state: discovery, launching, and organizing never depend on a network call.
5. The library is the content: chrome and ornament stay subordinate to cover art, names, and state.

## Accessibility & Inclusion

WCAG AA contrast is enforced by tests for body, muted, warning, link, and button-label colors in both appearance modes. Core actions are reachable by keyboard and gamepad, text scaling is followed by the wall and shelf, and the user chose a best-effort rather than formal certification target.
