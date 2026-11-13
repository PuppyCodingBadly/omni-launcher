---
name: Omni Launcher
description: One quiet graphite shelf for every game on a Linux machine.
colors:
  copper: "#B87433"
  copper-soft: "#D4AC85"
  graphite: "#0F1113"
  graphite-panel: "#14171A"
  graphite-surface: "#1A1D20"
  graphite-raised: "#24282C"
  hairline-dark: "#2B3035"
  ink: "#ECEDEA"
  ink-dim: "#9BA1A6"
  paper: "#F4F2EE"
  paper-panel: "#ECE8E1"
  paper-raised: "#FFFFFF"
  hairline-light: "#D6D0C6"
  paper-ink: "#1A1C1D"
  paper-ink-dim: "#5C6266"
  warning: "#E06C5A"
typography:
  headline:
    fontFamily: "Cantarell, Noto Sans, sans-serif"
    fontSize: "20px"
    fontWeight: 700
    lineHeight: 1.25
  title:
    fontFamily: "Cantarell, Noto Sans, sans-serif"
    fontSize: "17px"
    fontWeight: 700
    lineHeight: 1.3
  body:
    fontFamily: "Cantarell, Noto Sans, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: "Cantarell, Noto Sans, sans-serif"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.2
rounded:
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "14px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "18px"
  xl: "24px"
  xxl: "40px"
components:
  button-primary:
    backgroundColor: "{colors.copper}"
    textColor: "{colors.graphite}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
    height: "36px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
    height: "36px"
  icon-button:
    backgroundColor: "transparent"
    textColor: "{colors.ink-dim}"
    rounded: "{rounded.md}"
    size: "34px"
  search:
    backgroundColor: "{colors.graphite-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    height: "38px"
  cover-tile:
    backgroundColor: "{colors.graphite-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
  chip:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "2px 8px"
---

# Design System: Omni Launcher

## Overview

**Creative North Star: "The Graphite Shelf"**

Omni Launcher is an Operate surface: a media console for a Linux library that is spread across Steam, Heroic, Lutris, flatpaks, AppImages, and hand-added commands. The room is dark graphite; the covers are the only saturated objects in it. Chrome stays quiet and close to the content, like the milled edge of a shelf rather than a dashboard frame. The light mode is the same room in warm paper, not a different product.

The interface is warm-tactile inside a precise grid. Copper marks the one action that matters on each surface, surfaces separate by tone and a hairline rather than by stacked cards, and every label sits at a size the eye can scan without decoration. Nothing glows, nothing floats without a reason, and no element is uppercase for atmosphere.

**Key Characteristics:**
- Warm graphite and paper, not blue-black and not pure white.
- One copper accent, used for primary action, selection, and state.
- Covers carry the color; chrome carries the hierarchy.
- Soft radii, hairline edges, short state shadows.
- Dense where the library is, generous only between sections.

## Colors

A warm neutral room with a single burnished copper signal. The accent is deliberately darker than a display copper so it clears the 3:1 non-text floor on the paper background and keeps dark labels readable.

### Primary
- **Burnished Copper** (#B87433): filled primary buttons, selected tile ring, switches, current filter, running state, brand mark. On light paper the same hue is used; filled buttons take dark labels.

### Neutral
- **Graphite** (#0F1113): the page behind the wall in dark mode.
- **Graphite Panel** (#14171A): sidebar and detail panel, one tonal step above the page.
- **Graphite Surface** (#1A1D20): inputs, dialogs, cover placeholders and menu surfaces.
- **Graphite Raised** (#24282C): selected navigation rows, hover backgrounds, chips.
- **Hairline Dark** (#2B3035): the only border colour at rest.
- **Ink** (#ECEDEA) / **Ink Dim** (#9BA1A6): body and secondary text. Both pass WCAG AA on every dark surface.
- **Warm Paper** (#F4F2EE) / **Paper Panel** (#ECE8E1) / **Paper Raised** (#FFFFFF): the light-mode equivalents.
- **Paper Ink** (#1A1C1D) / **Paper Ink Dim** (#5C6266): light-mode text.
- **Warning** (#E06C5A dark, #A83B2E light): only for a failed launch, update, or missing files.

**The Copper Rarity Rule.** Copper appears on one primary action and one selected state per region. It never becomes a background fill for a whole panel, a gradient, or a decorative line.

## Typography

**Display Font:** Cantarell (with Noto Sans, sans-serif)
**Body Font:** Cantarell (same stack)
**Mono Font:** the platform monospace, only for commands, paths, and log output.

**Character:** Cantarell is the GNOME desktop's own voice: humanist, compact, and legible at small sizes without looking like a web template. One family carries the whole product; hierarchy comes from weight and size, not from a second display face.

### Hierarchy
- **Headline** (700, 20px, 1.25): detail-panel game titles only.
- **Title** (700, 17px, 1.3): the product name and the Settings title.
- **Title small** (600, 12px, 1.35): section headings such as Recently played and Library.
- **Body** (400, 13px, 1.4): navigation, tile names, settings rows.
- **Label** (500, 11px, 1.2): counts, source labels, metadata keys, search hints.

**The No Eyebrow Rule.** A section starts with a heading at its own size. No all-caps, letter-spaced kicker sits above it.

## Layout

The window is a three-column task surface: a 232px library sidebar (64px when folded), the cover wall, and a 360px detail panel that opens only when a game is selected. The wall uses a 168x252 poster cell with a 16px gap and 24px page margin; the shelf uses a 96x144 compact cell with a 12px gap and prints the name and playtime over the poster. The header is one 38px search field capped at 560px with the tool buttons at the right edge; when the detail panel opens, the search gives width back instead of pushing the toolbar out.

Settings is a single 800px column with the title and content on the same left edge, 28px of inner padding, and 24px between sections. Dense rows are allowed there: 44-48px per switch row, not a card per setting.

## Elevation & Depth

A hybrid system. Surfaces separate first by tone and a 1px hairline; shadows exist only as a response to state. Cover tiles are matte at rest with a short 8px ambient shadow. Hover and keyboard focus lift a tile to a 24px blur and a 10px offset. Dialogs and menus use a 10-16px soft elevation, never a colored halo.

### Shadow Vocabulary
- **cover-rest** (`0 4px 8px rgba(0,0,0,0.22)` dark, `0 4px 8px rgba(0,0,0,0.08)` light): the resting tile.
- **cover-lift** (`0 10px 24px rgba(0,0,0,0.48)` dark, `0 10px 24px rgba(0,0,0,0.20)` light): hover and focus only.
- **overlay** (`0 8px 24px rgba(0,0,0,0.35)`): menus and dialogs.

**The Matte-at-Rest Rule.** If nothing is hovered, focused, or elevated, it casts no decorative shadow.

## Shapes

A four-step radius scale: 6px chips and small badges, 8px controls and inputs, 10px cover tiles and cards, 14px dialogs. Borders are 1px hairlines; selected tiles get a 2px copper ring inside the tile's bounds. No side accent bars, no pill-shaped buttons, no radius on a surface that is not a container.

## Components

### Buttons
- **Shape:** 8px radius, 36px high, 16px horizontal padding.
- **Primary:** burnished copper with dark labels (black on copper clears 4.5:1). One per region.
- **Secondary:** transparent with a hairline border and ink label.
- **Hover / Focus:** tone changes to the raised surface; no scale, no glow.
- **Disabled:** raised surface with dim label.

### Chips
- **Style:** transparent fill, hairline border, 6px radius, 11px label.
- **State:** a filter chip is removable; selection is represented by the filter bar and the wall, not by a filled pill.

### Cards / Containers
- **Corner Style:** 10px for cover tiles; 8px for inputs; 14px for dialogs.
- **Background:** graphite surface on graphite page; paper raised on paper page.
- **Shadow Strategy:** state-only, see Elevation.
- **Border:** 1px hairline; selected tile 2px copper.
- **Internal Padding:** 24px page, 18px panel, 8px tile label.

### Inputs / Fields
- **Style:** filled surface, 1px hairline, 8px radius, 38px search height.
- **Focus:** 1.4px copper border; no glow.
- **Hint:** dim ink at label size; the real shortcut stays visible as plain text.

### Navigation
- **Sidebar:** 34px rows, 7px radius, 16px icons, source name and count. Selected row uses the raised surface, copper icon, and ink label; no accent bar.
- **Rail:** 64px wide, 38px icon targets, tooltips carry the label and count.
- **Header:** icon buttons are 34px ghost targets; the sort mode is a labelled menu, not a mystery icon.

### Cover Tile
The signature component. A 2:3 poster with a 2px inner inset and 10px outer radius. On the wall the name sits under it at 13px semibold with one dim metadata line. On the shelf the name (up to two lines) and short playtime/recency sit on the poster over a bottom gradient. On hover the cover lifts, a top-down scrim appears, a compact Play button sits at the bottom centre (centre on the shelf), and a 26px actions button sits at the top right. Running games show a static dot and the word Playing; no pulse.

### Detail Panel
A 360px panel with a hairline left edge, a 112px poster beside the title, one primary Launch/Stop button, tags, plugin sections, and quiet key/value facts. Labels sit in a fixed 88px column; values wrap and remain selectable.

## Do's and Don'ts

### Do:
- **Do** let cover art provide the colour; keep chrome to graphite, paper, and copper.
- **Do** use the raised surface plus a hairline to show selection and grouping.
- **Do** keep one primary action per region and give it 8px radius, not a pill.
- **Do** preserve the 4.5:1 contrast floor for body, dim, and button labels in both modes.
- **Do** keep motion at 150-250ms and use it only for state, reveal, or focus.

### Don't:
- **Don't** use purple-blue gradients, gradient text, glows, or blurred blobs.
- **Don't** use all-caps letter-spaced eyebrows or decorative status pulses.
- **Don't** paint a colored left border on cards, rows, or alerts.
- **Don't** stack cards inside cards or give every surface a shadow at rest.
- **Don't** use monospace outside code, commands, paths, and log output.
- **Don't** turn an icon into a primary action without a tooltip and a reachable keyboard path.
