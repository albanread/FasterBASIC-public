# FasterBASIC Sprite Commands Reference

> GPU-driven sprite system — BASIC command set for the Metal-backed sprite engine.


## Overview 

Sprites are small 16 colour objects, that may have several frames, designed for pixel graphics.

Each sprite has its own pallette.

Colour 0 is transparent, Colour 1 is black, 2..15 are the colours you can change.

The Mac has no 'sprite hardware', however these sprites are hardware accelerated by the GPU.

Sprites are designed to represent small fast moving objects, players, enemies, missiles, bombs.

To animate large background objects also consider using blitter operations, with FLIP.


All sprite commands use a **compound keyword** syntax: `SPRITE <subcommand>`.
The lexer consumes these as single tokens (same technique as `LINE INPUT`
and `END SUB`). Query functions remain single-word keywords for use in
expression context.

---

## Table of Contents

1. [Syntax Design](#syntax-design)
2. [Concepts](#concepts)
3. [Definition Commands](#definition-commands)
4. [Instance Commands](#instance-commands)
5. [Transform Commands](#transform-commands)
6. [Visibility & Appearance](#visibility--appearance)
7. [Animation](#animation)
8. [Effects](#effects)
9. [Palette Override](#palette-override)
10. [Collision](#collision)
11. [Query Functions](#query-functions)
12. [Lifecycle Commands](#lifecycle-commands)
13. [Lexer Implementation](#lexer-implementation)
14. [Complete Example](#complete-example)
15. [Quick Reference](#quick-reference)

---

## Syntax Design

### Statements — compound tokens

All sprite **statements** use the form `SPRITE <subcommand> [<subsubcommand>]`.
The lexer peeks ahead after seeing `SPRITE` and emits a single compound
token.  This avoids any ambiguity with `DEF` (already a keyword) or other
existing tokens.

```
SPRITE DEF 0, 16, 16          → token: kw_sprite_def
SPRITE SHOW 0                 → token: kw_sprite_show
SPRITE FX OFF 0               → token: kw_sprite_fx_off   (three words)
SPRITE REMOVE ALL             → token: kw_sprite_remove_all (three words)
SPRITE 0, 0, 100, 50          → token: kw_sprite           (bare placement)
```

If the word after `SPRITE` doesn't match any known subcommand, the lexer
rewinds and emits `kw_sprite` — the bare placement form.

### Editor Autocomplete

The hierarchical structure maps naturally to progressive autocomplete:
type `SPRITE` → offer subcommands (`DEF`, `SHOW`, `MOVE`, `FX`, …) →
for groups like `FX` or `PAL`, narrow further (`OFF`, `PARAM`, `COLOUR`
/ `OVERRIDE`, `RESET`).  This gives structured drill-down instead of
dumping 35+ flat completions, and the groupings match intent.

### Functions — single-word tokens

All sprite **query functions** are single-word keywords parsed in expression
context.  This keeps them composable in `IF`, `PRINT`, assignments, and
argument lists without any special expression-parser handling.

```
IF SPRITEHIT(0, 1) THEN ...
x = SPRITEX(0)
PRINT SPRITECOUNT()
```

---

## Concepts

| Term           | Description |
|----------------|-------------|
| **Definition** | A sprite template (pixel data + palette). Fixed slot `0–1023`. Up to **1024** definitions. |
| **Instance**   | A placed copy of a definition on screen. Fixed slot `0–512`. Up to **512
** instances. Multiple instances can share one definition. |
| **Atlas**      | GPU-private texture holding all sprite pixel data. Managed automatically. Max sprite size **256×256** pixels. |
| **Palette**    | 16-entry colour table per definition. Index 0 is always transparent. Up to **1024** palettes. |
| **Effect**     | Per-instance GPU post-process: glow, outline, shadow, tint, flash, dissolve. |
| **Collision Group** | An 8-bit tag assigned to instances for group-vs-group overlap testing. |

### Fixed-Slot Model

Both definitions and instances use a **fixed-slot** model — you choose the
slot number yourself.  There is no dynamic allocation or auto-assignment.
A slot is either active or inactive.  Writing to a slot overwrites whatever
was there before.

| Resource    | Slots     | Count |
|-------------|-----------|-------|
| Definitions | 0 – 1023  | 1024  |
| Instances   | 0 – 255   | 256   |

### Coordinate System

- Screen origin `(0, 0)` is the **top-left** corner.
- X increases rightward, Y increases downward.
- Sprite anchor defaults to `(0.5, 0.5)` (centre of the sprite).
- Rotation is specified in **degrees** (clockwise).

### Palette Convention

| Index | Default Usage   |
|-------|-----------------|
| 0     | Transparent     |
| 1     | Black / outline |
| 2–15  | User colours    |

### Palette Ownership

The palette belongs to the **definition**, not the instance.  When you call
`SPRITE PALETTE`, you modify the definition's palette — every instance using
that definition sees the change immediately.  For per-instance palette
variation, use `SPRITE PAL OVERRIDE` to borrow a different definition's
palette, or give each colour variant its own definition.

### Animation Frames

A definition's pixel data is a **horizontal strip** in the GPU atlas.
All frames are laid out side by side, left to right.  `SPRITE FRAMES`
tells the system how to slice the strip.  Each instance independently
tracks its current frame and animation speed.

```
Atlas memory for a 32×8 definition with 4 frames of 8×8:

┌────────┬────────┬────────┬────────┐
│Frame 0 │Frame 1 │Frame 2 │Frame 3 │
│ 8×8    │ 8×8    │ 8×8    │ 8×8    │
└────────┴────────┴────────┴────────┘
 x=0      x=8      x=16     x=24
```

---

## Definition Commands

### SPRITE DEF

Define an empty sprite of a given size.

```
SPRITE DEF id, width, height
```

| Parameter | Type    | Description |
|-----------|---------|-------------|
| `id`      | Integer | Definition slot (0–1023) |
| `width`   | Integer | Width in pixels (1–256) |
| `height`  | Integer | Height in pixels (1–256) |

**Token:** `kw_sprite_def`
**Runtime:** `gfx_sprite_def(id, w, h)`

**Example:**
```
SPRITE DEF 0, 16, 16   ' Define a 16x16 sprite in slot 0
```

---

### SPRITE DATA

Set a single pixel in a sprite definition to a palette index.

```
SPRITE DATA id, x, y, colour_index
```

| Parameter       | Type    | Description |
|-----------------|---------|-------------|
| `id`            | Integer | Definition slot (0–1023) |
| `x`             | Integer | Pixel X within the sprite |
| `y`             | Integer | Pixel Y within the sprite |
| `colour_index`  | Integer | Palette index (0–15) |

**Token:** `kw_sprite_data`
**Runtime:** `gfx_sprite_data(id, x, y, c)`

**Example:**
```
SPRITE DEF 0, 8, 8
FOR y% = 0 TO 7
  FOR x% = 0 TO 7
    SPRITE DATA 0, x%, y%, 2
  NEXT x%
NEXT y%
```

---

### SPRITE PALETTE

Set a colour in a sprite definition's palette.  All instances using
this definition see the change immediately.

```
SPRITE PALETTE id, index, r, g, b
```

| Parameter | Type    | Description |
|-----------|---------|-------------|
| `id`      | Integer | Definition slot (0–1023) |
| `index`   | Integer | Palette entry (0–15) |
| `r`       | Integer | Red component (0–255) |
| `g`       | Integer | Green component (0–255) |
| `b`       | Integer | Blue component (0–255) |

**Token:** `kw_sprite_palette`
**Runtime:** `gfx_sprite_palette(id, idx, r, g, b)`

**Example:**
```
SPRITE PALETTE 0, 0,   0,   0,   0    ' Transparent (alpha=0 by default)
SPRITE PALETTE 0, 1,   0,   0,   0    ' Black outline
SPRITE PALETTE 0, 2, 255,  80,  80    ' Red body
SPRITE PALETTE 0, 3, 255, 180, 180    ' Highlight
```

---

### SPRITE BEGIN / SPRITE END — Canvas Drawing Block

Opens a **canvas drawing context** for a sprite definition.  All drawing
commands inside the block (`GCLS`, `SPRITE ROW`, `PSET`, `GLINE`, `RECT`,
`CIRCLEF`, `TRIANGLE`, `ELLIPSE`, …) write into the definition's pixel
buffer rather than the screen.  `SPRITE END` closes the context and uploads
the buffer to the GPU atlas.

```
SPRITE BEGIN id
    GCLS 0
    SPRITE ROW row, <hex-nibbles>
    ...drawing commands...
SPRITE END
```

| Parameter | Type    | Description |
|-----------|---------|-------------|
| `id`      | Integer | Definition slot (0–1023) |

**Tokens:** `kw_sprite_begin` / `kw_sprite_end`
**Runtime:** `gfx_sprite_begin(id)` / `gfx_sprite_end()`

Nesting is **not** allowed — each `SPRITE BEGIN` must be paired with exactly
one `SPRITE END`.

---

### GCLS — Clear Canvas

Fills the active sprite canvas with a single palette index.  Valid only
inside a `SPRITE BEGIN` / `SPRITE END` block.

```
GCLS colour_index
```

| Parameter       | Type    | Description |
|-----------------|---------|-------------|
| `colour_index`  | Integer | Palette index to fill with (0 = transparent) |

**Token:** `kw_gcls`
**Runtime:** `gfx_gcls(c)`

```
SPRITE BEGIN 0
    GCLS 0          ' clear to transparent
    ...
SPRITE END
```

---

### SPRITE ROW — Write a Pixel Row

Writes a full horizontal row of pixels into the active sprite canvas using
compact hexadecimal nibble notation.  This is the primary tool for
hand-authoring pixel-art sprites directly in source code.

```
SPRITE ROW row, <hex-nibbles>
```

| Parameter      | Type    | Description |
|----------------|---------|-------------|
| `row`          | Integer | Zero-based row index (0 = top) |
| `hex-nibbles`  | Literal | One hex character (`0`–`F`) per pixel, spaces ignored |

**Token:** `kw_sprite_row`
**Runtime:** `gfx_sprite_row(row, data_ptr, count)` — data is a read-only
constant embedded in the binary (no heap allocation).

#### Hex Nibble Format

Each character after the comma maps directly to a palette index:

| Char | Index | Meaning (by convention) |
|------|-------|-------------------------|
| `0`  | 0     | Transparent |
| `1`  | 1     | Outline / shadow |
| `2`–`F` | 2–15 | User palette entries |

Spaces are **ignored** and can be used freely to group pixels:

```
SPRITE ROW 3, 0123 3333 3333 3210   ' 16 pixels, grouped in fours
SPRITE ROW 3, 0123333333333210      ' identical — spaces are optional
```

Only the first `width` nibbles are used; extra characters are silently
dropped.  A `'` comment character ends the pixel data.

#### Editor Visualisation

The editor renders each hex nibble with its **C64 VIC-II palette colour**
as the background, making the source file a live visual sprite editor.
Indices `0` and `1` both display as black with white text.

#### Full Example — 8×8 Smiley

```
SPRITE DEF 0, 8, 8
SPRITE PALETTE 0, 1,   0,   0,   0    ' black
SPRITE PALETTE 0, 2, 255, 220,   0    ' yellow
SPRITE PALETTE 0, 3, 255, 255, 255    ' white eye

SPRITE BEGIN 0
GCLS 0
SPRITE ROW 0, 01111110
SPRITE ROW 1, 12222221
SPRITE ROW 2, 12323221
SPRITE ROW 3, 12222221
SPRITE ROW 4, 12133121
SPRITE ROW 5, 12211221
SPRITE ROW 6, 12111121
SPRITE ROW 7, 01111110
SPRITE END
```

**Token:** `kw_sprite_row`

#### Complete Canvas Block Pattern

```
SPRITE DEF id, width, height          ' 1. declare size
SPRITE PALETTE id, 1, r, g, b        ' 2. set colours (index 0 = transparent)
...
SPRITE BEGIN id                       ' 3. open canvas
GCLS 0                                '    clear to transparent
SPRITE ROW 0, <pixels>               '    paint rows
SPRITE ROW 1, <pixels>
...
SPRITE END                            ' 4. close and upload to GPU
```

---

### SPRITE STD PAL

Apply a standard (built-in) palette to a definition.

```
SPRITE STD PAL id, palette_id
```

**Token:** `kw_sprite_std_pal`
**Runtime:** `gfx_sprite_std_pal(id, pal_id)` *(reserved — not yet implemented)*

---

### SPRITE FRAMES

Configure a sprite definition as an animation strip (horizontal frames).

```
SPRITE FRAMES id, frame_width, frame_height, count
```

| Parameter      | Type    | Description |
|----------------|---------|-------------|
| `id`           | Integer | Definition slot (0–1023) |
| `frame_width`  | Integer | Width of a single frame |
| `frame_height` | Integer | Height of a single frame |
| `count`        | Integer | Number of frames in the strip |

The definition's total pixel width must be `frame_width × count`.

**Token:** `kw_sprite_frames`
**Runtime:** `gfx_sprite_frames(id, fw, fh, count)`

**Example:**
```
' 32x8 strip containing 4 frames of 8x8
SPRITE DEF 3, 32, 8
' ... fill pixel data ...
SPRITE FRAMES 3, 8, 8, 4
```

---

### SPRITE LOAD

Load a sprite definition from a SPRTZ file on disk.

```
SPRITE LOAD id, filename$
```

| Parameter   | Type    | Description |
|-------------|---------|-------------|
| `id`        | Integer | Definition slot (0–1023) |
| `filename$` | String  | Path to a `.sprtz` file |

**Token:** `kw_sprite_load`
**Runtime:** `gfx_sprite_load(id, desc)`

**Example:**
```
SPRITE LOAD 5, "assets/hero.sprtz"
```

---

## Instance Commands

### SPRITE (bare — placement)

Place an instance of a defined sprite at a screen position.
The instance is created active and visible by default.
All previous state in that slot is reset.

```
SPRITE inst, def, x, y
```

| Parameter | Type    | Description |
|-----------|---------|-------------|
| `inst`    | Integer | Instance slot (0–255) |
| `def`     | Integer | Definition slot (0–1023) |
| `x`       | Number  | Initial X position |
| `y`       | Number  | Initial Y position |

**Token:** `kw_sprite` (bare — no subcommand matched)
**Runtime:** `gfx_sprite(inst, def, x, y)`

**Example:**
```
SPRITE DEF 0, 16, 16
' ... define pixels & palette ...
SPRITE 0, 0, 100, 50     ' Place instance 0 using definition 0 at (100, 50)
SPRITE SHOW 0
```

---

### SPRITE POS

Set the absolute position of an instance.

```
SPRITE POS inst, x, y
```

**Token:** `kw_sprite_pos`
**Runtime:** `gfx_sprite_pos(inst, x, y)`

---

### SPRITE MOVE

Move an instance by a relative offset.

```
SPRITE MOVE inst, dx, dy
```

**Token:** `kw_sprite_move`
**Runtime:** `gfx_sprite_move(inst, dx, dy)`

**Example:**
```
SPRITE MOVE 0, 2, 0   ' Move instance 0 right by 2 pixels
```

---

## Transform Commands

### SPRITE ROT

Set the rotation angle (in degrees, clockwise).

```
SPRITE ROT inst, angle
```

**Token:** `kw_sprite_rot`
**Runtime:** `gfx_sprite_rot(inst, angle_deg)` — internally stored in radians.

---

### SPRITE SCALE

Set the X and Y scale factors.  `1.0, 1.0` is normal size.

```
SPRITE SCALE inst, sx, sy
```

**Token:** `kw_sprite_scale`
**Runtime:** `gfx_sprite_scale(inst, sx, sy)`

---

### SPRITE ANCHOR

Set the anchor / pivot point for rotation and scaling.
Values are normalised (0.0–1.0) relative to the sprite's dimensions.
Default is `0.5, 0.5` (centre).

```
SPRITE ANCHOR inst, ax, ay
```

**Token:** `kw_sprite_anchor`
**Runtime:** `gfx_sprite_anchor(inst, ax, ay)`

**Example:**
```
' Centre-pivot rotation on a 16x16 sprite
SPRITE ANCHOR 0, 0.5, 0.5
SPRITE ROT 0, 45
```

---

### SPRITE FLIP

Mirror the sprite horizontally and/or vertically.

```
SPRITE FLIP inst, h, v
```

| Parameter | Type    | Description |
|-----------|---------|-------------|
| `h`       | Boolean | 1 = flip horizontal, 0 = normal |
| `v`       | Boolean | 1 = flip vertical, 0 = normal |

**Token:** `kw_sprite_flip`
**Runtime:** `gfx_sprite_flip(inst, h, v)`

---

## Visibility & Appearance

### SPRITE SHOW / SPRITE HIDE

```
SPRITE SHOW inst          ' Make instance visible
SPRITE HIDE inst          ' Make instance invisible
```

**Tokens:** `kw_sprite_show` / `kw_sprite_hide`
**Runtime:** `gfx_sprite_show(inst)` / `gfx_sprite_hide(inst)`

---

### SPRITE ALPHA

Set the opacity of an instance (0.0 = fully transparent, 1.0 = fully opaque).

```
SPRITE ALPHA inst, alpha
```

**Token:** `kw_sprite_alpha`
**Runtime:** `gfx_sprite_alpha(inst, a)`

---

### SPRITE PRIORITY

Set the draw priority (0–255).  Higher values are drawn on top.

```
SPRITE PRIORITY inst, pri
```

**Token:** `kw_sprite_priority`
**Runtime:** `gfx_sprite_priority(inst, pri)`

---

### SPRITE BLEND

Set the blending mode.

```
SPRITE BLEND inst, mode
```

| Mode | Description |
|------|-------------|
| 0    | Normal (alpha blend) |
| 1    | Additive |

**Token:** `kw_sprite_blend`
**Runtime:** `gfx_sprite_blend(inst, mode)`

---

## Animation

### SPRITE FRAME

Set the current animation frame (0-based).

```
SPRITE FRAME inst, frame
```

**Token:** `kw_sprite_frame`
**Runtime:** `gfx_sprite_frame(inst, frame)`

---

### SPRITE ANIMATE

Start automatic animation at a given speed (frames per tick).
Set speed to 0 to stop animation.

```
SPRITE ANIMATE inst, speed
```

**Token:** `kw_sprite_animate`
**Runtime:** `gfx_sprite_animate(inst, speed)`

**Example:**
```
SPRITE FRAMES 3, 8, 8, 4
SPRITE 10, 3, 100, 100
SPRITE SHOW 10
SPRITE ANIMATE 10, 0.5      ' Advance one frame every 2 VSYNCs
```

---

## Effects

All effects are per-instance and run on the GPU.  Only one effect can be
active on an instance at a time — setting a new effect replaces the old one.

### Effect Type Constants

| Type    | Value | Description |
|---------|-------|-------------|
| none    | 0     | No effect |
| glow    | 1     | Coloured glow around opaque pixels |
| outline | 2     | Solid-colour outline border |
| shadow  | 3     | Drop shadow with offset |
| tint    | 4     | Colour tint blend |
| flash   | 5     | Oscillating colour flash |
| dissolve| 6     | Dissolve / disintegrate |

---

### SPRITE GLOW

```
SPRITE GLOW inst, radius, intensity, r, g, b
```

| Parameter   | Type  | Description |
|-------------|-------|-------------|
| `radius`    | Float | Glow spread in pixels (≥ 1) |
| `intensity` | Float | Glow brightness (0–10) |
| `r, g, b`   | Integer | Glow colour (0–255 each) |

**Token:** `kw_sprite_glow`
**Runtime:** `gfx_sprite_glow(inst, radius, intensity, r, g, b)`

---

### SPRITE OUTLINE

```
SPRITE OUTLINE inst, thickness, r, g, b
```

**Token:** `kw_sprite_outline`
**Runtime:** `gfx_sprite_outline(inst, thickness, r, g, b)`

---

### SPRITE SHADOW

```
SPRITE SHADOW inst, ox, oy, r, g, b, a
```

| Parameter | Type  | Description |
|-----------|-------|-------------|
| `ox, oy`  | Float | Shadow offset in pixels |
| `r,g,b`   | Integer | Shadow colour |
| `a`       | Integer | Shadow alpha (0–255) |

**Token:** `kw_sprite_shadow`
**Runtime:** `gfx_sprite_shadow(inst, ox, oy, r, g, b, a)`

---

### SPRITE TINT

```
SPRITE TINT inst, factor, r, g, b
```

| Parameter | Type  | Description |
|-----------|-------|-------------|
| `factor`  | Float | Tint strength (0.0–1.0) |
| `r,g,b`   | Integer | Tint colour |

**Token:** `kw_sprite_tint`
**Runtime:** `gfx_sprite_tint(inst, factor, r, g, b)`

---

### SPRITE FLASH

```
SPRITE FLASH inst, speed, r, g, b
```

| Parameter | Type  | Description |
|-----------|-------|-------------|
| `speed`   | Float | Flash oscillation speed (≥ 1) |
| `r,g,b`   | Integer | Flash colour |

**Token:** `kw_sprite_flash`
**Runtime:** `gfx_sprite_flash(inst, speed, r, g, b)`

---

### SPRITE FX

Set an effect by type number directly, then configure params/colour separately.

```
SPRITE FX inst, effect_type
SPRITE FX PARAM inst, param1, param2
SPRITE FX COLOUR inst, r, g, b, a
```

**Tokens:** `kw_sprite_fx` / `kw_sprite_fx_param` / `kw_sprite_fx_colour`
**Runtime:** `gfx_sprite_fx(inst, type)`, `gfx_sprite_fx_param(inst, p1, p2)`, `gfx_sprite_fx_colour(inst, r, g, b, a)`

---

### SPRITE FX OFF

Remove all effects from an instance.

```
SPRITE FX OFF inst
```

**Token:** `kw_sprite_fx_off`
**Runtime:** `gfx_sprite_fx_off(inst)`

---

## Palette Override

### SPRITE PAL OVERRIDE

Override an instance's palette with the palette from a different definition.

```
SPRITE PAL OVERRIDE inst, def_id
```

**Token:** `kw_sprite_pal_override`
**Runtime:** `gfx_sprite_pal_override(inst, def_id)`

---

### SPRITE PAL RESET

Reset an instance to use its own definition's palette.

```
SPRITE PAL RESET inst
```

**Token:** `kw_sprite_pal_reset`
**Runtime:** `gfx_sprite_pal_reset(inst)`

---

## Collision

### SPRITE COLLIDE

Assign an instance to a collision group (0–255).

```
SPRITE COLLIDE inst, group
```

**Token:** `kw_sprite_collide`
**Runtime:** `gfx_sprite_collide(inst, group)`

---

### SPRITEHIT(a, b)

Test bounding-box collision between two specific instances.
Returns `1` if overlapping, `0` otherwise.

```
result = SPRITEHIT(inst_a, inst_b)
```

**Token:** `kw_spritehit`  (single-word, expression function)
**Runtime:** `gfx_sprite_hit(a, b)` → `f64`

---

### SPRITEOVERLAP(grpA, grpB)

Test whether any instance in group A overlaps any instance in group B.
Returns `1` if any overlap found, `0` otherwise.

```
result = SPRITEOVERLAP(group_a, group_b)
```

**Token:** `kw_spriteoverlap`  (single-word, expression function)
**Runtime:** `gfx_sprite_overlap(grp_a, grp_b)` → `f64`

---

## Query Functions

These are **single-word keywords** parsed as functions in expression context.
They remain composable in `IF`, `PRINT`, assignments, and arguments.

| BASIC Function          | Returns                    | Token                | Runtime                      |
|-------------------------|----------------------------|----------------------|------------------------------|
| `SPRITEX(inst)`         | X position (float)         | `kw_spritex`         | `gfx_sprite_x(inst)`        |
| `SPRITEY(inst)`         | Y position (float)         | `kw_spritey`         | `gfx_sprite_y(inst)`        |
| `SPRITEGETROT(inst)`    | Rotation in degrees        | `kw_spritegetrot`    | `gfx_sprite_get_rot(inst)`  |
| `SPRITEVISIBLE(inst)`   | 1 if visible, 0 if hidden  | `kw_spritevisible`   | `gfx_sprite_visible(inst)`  |
| `SPRITEGETFRAME(inst)`  | Current animation frame    | `kw_spritegetframe`  | `gfx_sprite_get_frame(inst)`|
| `SPRITEHIT(a, b)`       | 1 if collision, 0 if not   | `kw_spritehit`       | `gfx_sprite_hit(a, b)`      |
| `SPRITECOUNT()`         | Number of active instances | `kw_spritecount`     | `gfx_sprite_count()`        |
| `SPRITEOVERLAP(ga, gb)` | 1 if group overlap, else 0 | `kw_spriteoverlap`   | `gfx_sprite_overlap(ga, gb)`|

**Example:**
```
PRINT "Player at"; SPRITEX(0); ","; SPRITEY(0)
IF SPRITEVISIBLE(0) THEN PRINT "Visible"
IF SPRITEHIT(0, 1) THEN SPRITE REMOVE 0
PRINT "Active sprites:"; SPRITECOUNT()
```

---

## Lifecycle Commands

### SPRITE REMOVE

Remove a single sprite instance.

```
SPRITE REMOVE inst
```

**Token:** `kw_sprite_remove`
**Runtime:** `gfx_sprite_remove(inst)`

---

### SPRITE REMOVE ALL

Remove all sprite instances (definitions are preserved).

```
SPRITE REMOVE ALL
```

**Token:** `kw_sprite_remove_all`
**Runtime:** `gfx_sprite_remove_all()`

---

### SPRITE SYNC

Manually sync sprite instance data to the GPU.  Called automatically
by `VSYNC`.  Only needed if you use `FLIP` instead.

```
SPRITE SYNC
```

**Token:** `kw_sprite_sync`
**Runtime:** `gfx_sprite_sync()`

---

## Important Notes

### VSYNC Synchronisation

Sprite instance data must be synced to the GPU before rendering.
This happens automatically when you call `VSYNC`.  If you use `FLIP`
instead, call `SPRITE SYNC` explicitly:

```
' Option A: VSYNC handles sync + flip + wait
VSYNC

' Option B: Manual sync then flip
SPRITE SYNC
FLIP
```

### Upload Batching

Each `SPRITE DATA` call enqueues a GPU upload.  For large sprites,
define all pixels first, then let `VSYNC` drain the upload queue.
Avoid calling `SPRITE DATA` thousands of times per frame during
gameplay — define sprites during initialisation.

---

## Lexer Implementation

The lexer uses the same compound-keyword technique as `LINE INPUT`
and `END SUB`.  When it encounters `SPRITE`, it peeks ahead (saving
and potentially restoring position) to match subcommands.

### Token Tags

```
// ── Keywords (sprites — compound tokens) ─────────────────────────────
// Definition
kw_sprite_def,            // SPRITE DEF
kw_sprite_data,           // SPRITE DATA
kw_sprite_palette,        // SPRITE PALETTE
kw_sprite_std_pal,        // SPRITE STD PAL       (3 words)
kw_sprite_frames,         // SPRITE FRAMES
kw_sprite_load,           // SPRITE LOAD

// Placement (bare form)
kw_sprite,                // SPRITE                (no subcommand)

// Position & movement
kw_sprite_pos,            // SPRITE POS
kw_sprite_move,           // SPRITE MOVE

// Transforms
kw_sprite_rot,            // SPRITE ROT
kw_sprite_scale,          // SPRITE SCALE
kw_sprite_anchor,         // SPRITE ANCHOR
kw_sprite_flip,           // SPRITE FLIP

// Visibility & appearance
kw_sprite_show,           // SPRITE SHOW
kw_sprite_hide,           // SPRITE HIDE
kw_sprite_alpha,          // SPRITE ALPHA
kw_sprite_priority,       // SPRITE PRIORITY
kw_sprite_blend,          // SPRITE BLEND

// Animation
kw_sprite_frame,          // SPRITE FRAME
kw_sprite_animate,        // SPRITE ANIMATE

// Effects — simple
kw_sprite_glow,           // SPRITE GLOW
kw_sprite_outline,        // SPRITE OUTLINE
kw_sprite_shadow,         // SPRITE SHADOW
kw_sprite_tint,           // SPRITE TINT
kw_sprite_flash,          // SPRITE FLASH

// Effects — FX subgroup    (3-word forms)
kw_sprite_fx,             // SPRITE FX
kw_sprite_fx_param,       // SPRITE FX PARAM       (3 words)
kw_sprite_fx_colour,      // SPRITE FX COLOUR      (3 words)
kw_sprite_fx_off,         // SPRITE FX OFF          (3 words)

// Palette override          (3-word forms)
kw_sprite_pal_override,   // SPRITE PAL OVERRIDE   (3 words)
kw_sprite_pal_reset,      // SPRITE PAL RESET      (3 words)

// Collision
kw_sprite_collide,        // SPRITE COLLIDE

// Lifecycle
kw_sprite_remove,         // SPRITE REMOVE
kw_sprite_remove_all,     // SPRITE REMOVE ALL     (3 words)
kw_sprite_sync,           // SPRITE SYNC

// ── Keywords (sprites — single-word query functions) ─────────────────
kw_spritex,               // SPRITEX(inst)
kw_spritey,               // SPRITEY(inst)
kw_spritegetrot,          // SPRITEGETROT(inst)
kw_spritevisible,         // SPRITEVISIBLE(inst)
kw_spritegetframe,        // SPRITEGETFRAME(inst)
kw_spritehit,             // SPRITEHIT(a, b)
kw_spritecount,           // SPRITECOUNT()
kw_spriteoverlap,         // SPRITEOVERLAP(ga, gb)
```

### Lexer Dispatch Logic

After scanning an identifier that matches `"SPRITE"`, the lexer
saves its position and peeks at the next word:

```
SPRITE → peek word₂:
  ├─ DEF         → kw_sprite_def
  ├─ DATA        → kw_sprite_data
  ├─ PALETTE     → kw_sprite_palette
  ├─ STD         → peek word₃:
  │    └─ PAL    → kw_sprite_std_pal
  │    └─ else   → rewind to word₂, kw_sprite (bare)
  ├─ FRAMES      → kw_sprite_frames
  ├─ LOAD        → kw_sprite_load
  ├─ POS         → kw_sprite_pos
  ├─ MOVE        → kw_sprite_move
  ├─ ROT         → kw_sprite_rot
  ├─ SCALE       → kw_sprite_scale
  ├─ ANCHOR      → kw_sprite_anchor
  ├─ FLIP        → kw_sprite_flip
  ├─ SHOW        → kw_sprite_show
  ├─ HIDE        → kw_sprite_hide
  ├─ ALPHA       → kw_sprite_alpha
  ├─ PRIORITY    → kw_sprite_priority
  ├─ BLEND       → kw_sprite_blend
  ├─ FRAME       → kw_sprite_frame
  ├─ ANIMATE     → kw_sprite_animate
  ├─ GLOW        → kw_sprite_glow
  ├─ OUTLINE     → kw_sprite_outline
  ├─ SHADOW      → kw_sprite_shadow
  ├─ TINT        → kw_sprite_tint
  ├─ FLASH       → kw_sprite_flash
  ├─ FX          → peek word₃:
  │    ├─ PARAM  → kw_sprite_fx_param
  │    ├─ COLOUR → kw_sprite_fx_colour
  │    ├─ OFF    → kw_sprite_fx_off
  │    └─ else   → rewind to after FX, kw_sprite_fx
  ├─ PAL         → peek word₃:
  │    ├─ OVERRIDE → kw_sprite_pal_override
  │    ├─ RESET    → kw_sprite_pal_reset
  │    └─ else     → rewind to word₂, kw_sprite (bare)
  ├─ COLLIDE     → kw_sprite_collide
  ├─ REMOVE      → peek word₃:
  │    ├─ ALL    → kw_sprite_remove_all
  │    └─ else   → rewind to after REMOVE, kw_sprite_remove
  ├─ SYNC        → kw_sprite_sync
  └─ else        → rewind to word₁, kw_sprite (bare placement)
```

The single-word query functions (`SPRITEX`, `SPRITEY`, `SPRITEHIT`, etc.)
are handled by the normal keyword map — no compound logic needed.

### Keyword Map Entries

```
// Compound sprite commands — handled by lexer peek logic
// (SPRITE is the trigger word, not in the keyword map itself)

// Single-word query functions — in the keyword map
.{ "SPRITEX",        .kw_spritex },
.{ "SPRITEY",        .kw_spritey },
.{ "SPRITEGETROT",   .kw_spritegetrot },
.{ "SPRITEVISIBLE",  .kw_spritevisible },
.{ "SPRITEGETFRAME", .kw_spritegetframe },
.{ "SPRITEHIT",      .kw_spritehit },
.{ "SPRITECOUNT",    .kw_spritecount },
.{ "SPRITEOVERLAP",  .kw_spriteoverlap },
```

---

## Complete Example

```
' ── Bouncing sprite demo ──────────────────────────────────

SCREEN 320, 240, 2
SCREENTITLE "Sprite Demo"

' Define a 16x16 sprite
SPRITE DEF 0, 16, 16
SPRITE PALETTE 0, 0,   0,   0,   0     ' transparent
SPRITE PALETTE 0, 1,   0,   0,   0     ' black outline
SPRITE PALETTE 0, 2, 255,  80,  80     ' red body
SPRITE PALETTE 0, 3, 255, 180, 180     ' highlight

' Fill with a diamond shape
FOR y% = 0 TO 15
  FOR x% = 0 TO 15
    dx% = ABS(x% - 7)
    dy% = ABS(y% - 7)
    IF dx% + dy% <= 7 THEN
      IF dx% + dy% = 7 THEN
        SPRITE DATA 0, x%, y%, 1       ' outline
      ELSEIF dx% + dy% <= 2 THEN
        SPRITE DATA 0, x%, y%, 3       ' highlight
      ELSE
        SPRITE DATA 0, x%, y%, 2       ' body
      END IF
    END IF
  NEXT x%
NEXT y%

' Place the instance
SPRITE 0, 0, 160, 120
SPRITE ANCHOR 0, 0.5, 0.5
SPRITE SHOW 0
SPRITE GLOW 0, 3, 2.0, 255, 100, 100

' Animate
vx = 2.0 : vy = 1.5
angle = 0.0

DO WHILE SCREENACTIVE()
  ' Move
  SPRITE MOVE 0, vx, vy

  ' Bounce off edges
  IF SPRITEX(0) < 0 OR SPRITEX(0) > 304 THEN vx = -vx
  IF SPRITEY(0) < 0 OR SPRITEY(0) > 224 THEN vy = -vy

  ' Rotate
  angle = angle + 3
  SPRITE ROT 0, angle

  VSYNC
LOOP

SCREENCLOSE
```

---

## Quick Reference

### Statements (compound tokens)

| BASIC Statement                          | Token                  | Runtime Function                          |
|------------------------------------------|------------------------|-------------------------------------------|
| `SPRITE DEF id, w, h`                   | `kw_sprite_def`        | `gfx_sprite_def(id, w, h)`               |
| `SPRITE DATA id, x, y, c`               | `kw_sprite_data`       | `gfx_sprite_data(id, x, y, c)`           |
| `SPRITE PALETTE id, i, r, g, b`         | `kw_sprite_palette`    | `gfx_sprite_palette(id, i, r, g, b)`     |
| `SPRITE STD PAL id, pid`                | `kw_sprite_std_pal`    | `gfx_sprite_std_pal(id, pid)`            |
| `SPRITE FRAMES id, fw, fh, n`           | `kw_sprite_frames`     | `gfx_sprite_frames(id, fw, fh, n)`       |
| `SPRITE LOAD id, file$`                 | `kw_sprite_load`       | `gfx_sprite_load(id, desc)`              |
| `SPRITE i, d, x, y`                     | `kw_sprite`            | `gfx_sprite(i, d, x, y)`                |
| `SPRITE POS i, x, y`                    | `kw_sprite_pos`        | `gfx_sprite_pos(i, x, y)`               |
| `SPRITE MOVE i, dx, dy`                 | `kw_sprite_move`       | `gfx_sprite_move(i, dx, dy)`             |
| `SPRITE ROT i, deg`                     | `kw_sprite_rot`        | `gfx_sprite_rot(i, deg)`                 |
| `SPRITE SCALE i, sx, sy`                | `kw_sprite_scale`      | `gfx_sprite_scale(i, sx, sy)`            |
| `SPRITE ANCHOR i, ax, ay`               | `kw_sprite_anchor`     | `gfx_sprite_anchor(i, ax, ay)`           |
| `SPRITE SHOW i`                         | `kw_sprite_show`       | `gfx_sprite_show(i)`                     |
| `SPRITE HIDE i`                         | `kw_sprite_hide`       | `gfx_sprite_hide(i)`                     |
| `SPRITE FLIP i, h, v`                   | `kw_sprite_flip`       | `gfx_sprite_flip(i, h, v)`               |
| `SPRITE ALPHA i, a`                     | `kw_sprite_alpha`      | `gfx_sprite_alpha(i, a)`                 |
| `SPRITE FRAME i, f`                     | `kw_sprite_frame`      | `gfx_sprite_frame(i, f)`                 |
| `SPRITE ANIMATE i, spd`                 | `kw_sprite_animate`    | `gfx_sprite_animate(i, spd)`             |
| `SPRITE PRIORITY i, p`                  | `kw_sprite_priority`   | `gfx_sprite_priority(i, p)`              |
| `SPRITE BLEND i, m`                     | `kw_sprite_blend`      | `gfx_sprite_blend(i, m)`                 |
| `SPRITE REMOVE i`                       | `kw_sprite_remove`     | `gfx_sprite_remove(i)`                   |
| `SPRITE REMOVE ALL`                     | `kw_sprite_remove_all` | `gfx_sprite_remove_all()`                |
| `SPRITE FX i, t`                        | `kw_sprite_fx`         | `gfx_sprite_fx(i, t)`                    |
| `SPRITE FX PARAM i, p1, p2`             | `kw_sprite_fx_param`   | `gfx_sprite_fx_param(i, p1, p2)`         |
| `SPRITE FX COLOUR i, r, g, b, a`        | `kw_sprite_fx_colour`  | `gfx_sprite_fx_colour(i, r, g, b, a)`    |
| `SPRITE GLOW i, r, int, R, G, B`        | `kw_sprite_glow`       | `gfx_sprite_glow(i, r, int, R, G, B)`    |
| `SPRITE OUTLINE i, t, r, g, b`          | `kw_sprite_outline`    | `gfx_sprite_outline(i, t, r, g, b)`      |
| `SPRITE SHADOW i, ox, oy, r, g, b, a`   | `kw_sprite_shadow`     | `gfx_sprite_shadow(i, ox, oy, r, g, b, a)` |
| `SPRITE TINT i, f, r, g, b`             | `kw_sprite_tint`       | `gfx_sprite_tint(i, f, r, g, b)`         |
| `SPRITE FLASH i, s, r, g, b`            | `kw_sprite_flash`      | `gfx_sprite_flash(i, s, r, g, b)`        |
| `SPRITE FX OFF i`                       | `kw_sprite_fx_off`     | `gfx_sprite_fx_off(i)`                   |
| `SPRITE PAL OVERRIDE i, d`              | `kw_sprite_pal_override` | `gfx_sprite_pal_override(i, d)`        |
| `SPRITE PAL RESET i`                    | `kw_sprite_pal_reset`  | `gfx_sprite_pal_reset(i)`                |
| `SPRITE COLLIDE i, g`                   | `kw_sprite_collide`    | `gfx_sprite_collide(i, g)`               |
| `SPRITE SYNC`                           | `kw_sprite_sync`       | `gfx_sprite_sync()`                      |

### Functions (single-word tokens, expression context)

| BASIC Function           | Token                | Runtime                        |
|--------------------------|----------------------|--------------------------------|
| `SPRITEX(i)`             | `kw_spritex`         | `gfx_sprite_x(i)` → f64       |
| `SPRITEY(i)`             | `kw_spritey`         | `gfx_sprite_y(i)` → f64       |
| `SPRITEGETROT(i)`        | `kw_spritegetrot`    | `gfx_sprite_get_rot(i)` → f64 |
| `SPRITEVISIBLE(i)`       | `kw_spritevisible`   | `gfx_sprite_visible(i)` → f64 |
| `SPRITEGETFRAME(i)`      | `kw_spritegetframe`  | `gfx_sprite_get_frame(i)` → f64 |
| `SPRITEHIT(a, b)`        | `kw_spritehit`       | `gfx_sprite_hit(a, b)` → f64  |
| `SPRITECOUNT()`          | `kw_spritecount`     | `gfx_sprite_count()` → f64    |
| `SPRITEOVERLAP(ga, gb)`  | `kw_spriteoverlap`   | `gfx_sprite_overlap(ga, gb)` → f64 |