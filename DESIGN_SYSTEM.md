# Design system

The Mac menu bar panel, read from `Sources/ModelShelf/ShelfView.swift` and `App.swift`. It is native macOS: system
font, system colors and SF Symbols, so it follows light and dark mode on its own. There is no theme file; the values
below are the ones in the code. Change them there and here in the same commit.

## Layout

- Menu bar icon `square.stack.3d.up`. Clicking it opens an `NSPopover` under the icon that closes when you click
  anywhere else. No Dock icon.
- Panel: 380 pt wide. Header, divider, scrolling list (fixed 520 pt tall, because a menu bar panel shrinks a scroll
  list to nothing without a set height), divider, footer. Dividers at 50% opacity.
- While the first scan runs: a small spinner and "Reading the disk", at least 120 pt tall.

## Color

| Use | Color |
|---|---|
| Used (its usage bar segment and legend swatch) | `systemGreen` |
| Idle | `systemOrange` |
| Not used | `systemGray` |
| Model icon tile | the model's `color` from the settings: `pink`, `orange`, `blue`, `teal`, `purple`, `indigo`, `red`, `mint`, `cyan`, `yellow`, `green`, `gray` (the matching `system*` color); default `gray` |
| "Loaded" pill | `.blue` |
| "New" pill | `.purple` |
| Warnings | `.orange` |
| "Used by" dot | `systemGreen` for a loaded job, `systemGray` for a skill or a job that is not loaded |
| Secondary and tertiary text | `.secondary`, `.tertiary` |
| Row hover / open row | primary at 6% / 5% opacity |
| Snapshot background | `windowBackgroundColor` |

Icons and pill text are white.

## Typography

System font everywhere; sizes in points. Numbers use monospaced digits.

| Element | Size and weight |
|---|---|
| Panel title "Models" | 15 bold |
| Header total ("30 GB · 12 models") | 12, secondary |
| Section header (name and total) | 11 semibold, secondary |
| Model name | 13 semibold, one line |
| Row subtitle | 11, secondary, one line |
| Row size | 12, secondary |
| Detail description | 12.5 |
| "Used by" label | 11 semibold, secondary |
| Used-by line | 12: name semibold, how secondary |
| Note | 11.5, secondary |
| Store path | 11 monospaced, tertiary, selectable |
| Legend, warnings, footer | 11 (secondary; warnings orange) |
| Pill | 10 bold, white |
| Icon in tile / refresh icon / chevron | 13 semibold / 11 semibold / 10 bold tertiary |

## Spacing and shape

| Element | Values |
|---|---|
| Header | padding 18 sides, 16 top, 12 bottom; 9 between lines |
| Usage bar | 8 tall, corner radius 4; segments radius 2, 2 apart, at least 2 wide |
| Legend | 14 between items; 8 by 8 swatch, radius 2, 5 from its label |
| List | padding 8 sides, 6 top and bottom; 2 between rows |
| Section header | padding 10 sides, 10 top, 2 bottom |
| Row | padding 10 sides, 7 top and bottom; 10 between parts; background radius 10 (continuous) |
| Icon tile | 28 by 28, radius 7 (continuous) |
| Detail | padding 48 left (lines up under the name), 12 right, 12 bottom, 2 top; 10 between blocks; used-by dot 6 by 6 |
| Pill | capsule, padding 6 sides, 1 top and bottom |
| Footer | padding 18 sides, 9 top and bottom |

## Components

- **Header.** Title, total size and count, refresh button (`arrow.clockwise`, help text "Check again", spins while a
  scan runs), the usage bar split by section, the legend, then any warnings (`exclamationmark.triangle`).
- **Section.** Used, Idle, Not used, in that order, each with its total. Empty sections are hidden.
- **Model row.** Icon tile, name with "Loaded" and "New" pills, a one-line subtitle (who uses it, or "Nothing uses
  it", "New on disk", "In memory now, no job names it"), size, and a chevron that turns 90 degrees when open. Click to
  open; one row open at a time.
- **Row detail.** What the model does, "Used by" (or "Can be used by" for Idle) with one line per job or skill, the
  note from the settings, and the store path.
- **Footer.** "Checked 3:42 PM · only reads" and a Quit button.
- **Kind icons** (SF Symbols, when the settings give none): `photo.on.rectangle` picture or video model,
  `text.alignleft` text reader, `puzzlepiece` add-on, `photo` image decoder, `waveform` sound reader, `text.bubble`
  Ollama writing model, `shippingbox` anything else.

## Motion

- Opening and closing a row: spring, response 0.3, no bounce (damping 1). The detail fades in and slides from the top.
- Refresh icon: one full turn per second, repeating, while a scan runs.

## Words and numbers

- Plain words, no jargon: "Used", "Idle", "Not used", "Check again", "Reading the disk", "only reads".
- Sizes from `gbText`: under 0.1 GB in MB ("480 MB"), under 10 GB with one decimal ("1.6 GB"), else whole ("30 GB").

## Terminal list (Linux, Windows, `--list`)

Same sections and order as the panel, from `listText` in `Sources/ShelfCore/Model.swift`: a total line, then each
section with its size, one line per model (name padded to the longest name up to 40 characters, size right-aligned,
then who uses it). Warnings print first as "Note: ...".
