# Images and Canvas Guide


Images and Canvas are designed for use as Window commands.

Ed-BASIC provides powerful image manipulation capabilities integrated with the dialog and windowing system. 

This guide covers defining a viewport (canvas), rendering vector shapes, utilizing offscreen image buffers, image composition with blend modes, and applying post-processing effects.

These function are suitable for applications, for example to draw a chart or diagram, for games please refer to the graphics window.

---

## 1. Defining a Canvas

Before you can draw anything in a window, you must define a graphical window and place a **Canvas control** inside it. A canvas defines a rectangular region specifically dedicated to receiving drawing commands.

```basic
WINDOW DEFINE 1, "Vector Graphics Demo", 100, 100, 600, 400
    WINDOW CANVAS 10, 10, 10, 580, 380
END WINDOW

WINDOW SHOW 1
```

In this example, `1` is the Window ID and `10` is the Control ID for the new canvas. It sits at `x=10`, `y=10` relative to the window, and is `580x380` pixels in size.

## 2. Drawing Shapes and Paths

To issue drawing commands, you open a context block using `WINDOW CANVAS BEGIN` with the target `win_id` and `ctl_id`. Every operation within the block is grouped into a display list and executed when the block encounters `WINDOW CANVAS END`.

```basic
WINDOW CANVAS BEGIN 1, 10
    ' Set background color (RGBA) and fill the canvas
    PAPER 24, 28, 38, 255
    CLEAR

    ' Draw a red circle outline
    COLOR 255, 60, 60, 255
    LINEWIDTH 2
    CIRCLE 150, 100, 60, 0      ' The last argument: 0=outline, 1=fill

    ' Draw a solid yellow rectangle
    COLOR 255, 200, 40, 255
    RECT 300, 50, 180, 100, 1

    ' Render some text 
    COLOR 200, 230, 255, 255
    TEXT 20, 200, "Drawing shapes is easy!"
WINDOW CANVAS END
```

### Supported Primitives
*   `CLEAR` - Fills the entire canvas with the currently active `PAPER` color.
*   `PAPER r, g, b, a` - Sets the background clear color.
*   `COLOR r, g, b, a` - Sets the active brush color for strokes and fills. Note that `a` represents alpha (opacity) from `0` (transparent) to `255` (opaque).
*   `LINEWIDTH w` - Sets the thickness of lines and shape outlines.
*   `LINE x1, y1, x2, y2` - Draws a single line segment.
*   `RECT x, y, width, height, fill` - Draws a rectangle.
*   `CIRCLE x, y, radius, fill` - Draws a circle.
*   `ELLIPSE x, y, rX, rY, fill` - Draws an ellipse.
*   `TRIANGLE x1, y1, x2, y2, x3, y3, fill` - Draws a triangle.
*   `TEXT x, y, "String"` - Renders a line of text.

### Path Commands
For complex, irregular shapes you can use the `PATH` rendering subsystem:

```basic
WINDOW CANVAS BEGIN 1, 10
    COLOR 0, 150, 200, 255

    PATH MOVE 50, 50
    PATH LINE 150, 50
    PATH BEZIER 150, 150, 50, 150
    PATH CLOSE
    
    PATH FILL             ' Fills the enclosed path
    ' or PATH STROKE      ' Outlines the path
WINDOW CANVAS END
```

---

## 3. Offscreen Images

You can create in-memory, offscreen images to compile graphics or load external assets. These act as hidden canvases that you can draw upon precisely like a visible window canvas.

To create an offscreen memory image:

```basic
' IMAGE CREATE img_id, width, height
WINDOW IMAGE CREATE 1, 320, 240
```

To draw onto this image, substitute `CANVAS` with `IMAGE`:

```basic
WINDOW IMAGE BEGIN 1
    ' Ensure a fully transparent background to overlay on other shapes later!
    PAPER 0, 0, 0, 0
    CLEAR
    
    COLOR 40, 200, 40, 255
    CIRCLE 160, 120, 80, 1
WINDOW IMAGE END
```

When you are finished using an image and no longer need it, free its memory:
```basic
WINDOW IMAGE DESTROY 1
```

---

## 4. Placing Images & Blending

Offscreen images aren't very useful unless you can display them! You can composite an image onto a normal window canvas (or overlay it onto another image) using the `PLACE IMAGE` command.

The `PLACE IMAGE` command utilizes a very flexible syntax. The `AT`, `SRC` (source crop), and `BLEND` keywords can be chained in **any sequence**, allowing for highly readable rendering code:

```basic
WINDOW CANVAS BEGIN 1, 10
    ' Simple placement - stretch image #1 to fit the 100x100 box
    PLACE IMAGE 1 AT 50, 50, 100, 100
    
    ' Place image with ADDITIVE blending (great for glowing lights/fire/magic)
    PLACE IMAGE 2 AT 200, 50, 150, 150 BLEND ADD
    
    ' Crop a source portion of the image and scale it up, with XOR blending
    PLACE IMAGE 3 AT 400, 50, 200, 200 SRC 10, 10, 50, 50 BLEND XOR
WINDOW CANVAS END
```
*(Note: Using `IMAGE 1 AT ...` without the word `PLACE` is also completely valid shorthand.)*

**Destination (`AT x, y, width, height`)**
Determines where the image is drawn on the destination canvas and what size it will be scaled to.

**Source Crop (`SRC x, y, width, height`)**
Plucks only a rectangular subset from the source image buffer. Excellent for pulling single frames out from a sprite atlas. (Although hardware sprites supported by the graphics window are a better bet for games.)

**Blend Modes (`BLEND mode`)**
Controls how the image's pixels merge with whatever was painted underneath them.
*   `NORMAL` - Standard alpha transparency (default if omitted)
*   `ADD` - Additive blending; colors get strictly brighter.
*   `MULT` - Multiplicative blending; darkens colors beneath.
*   `SCREEN` - Screen blending; softens bright overlays.
*   `SUB` - Subtractive blending; inverts and subtracts color values.
*   `XOR` - Exclusive-OR bitwise blending; achieves classic retro inversion effects.

---

## 5. Built-in Image Filters and Saving

Ed-BASIC provides powerful post-processing capabilities allowing you to manipulate offscreen images before placing or saving them.

Apply an effect using `IMAGE EFFECT img_id, "effect_name" [, params...]`:

```basic
' Blur the image (radius X, radius Y)
IMAGE EFFECT 1, "BLUR", 2.0, 2.0

' Posterize down to 4 color bands
IMAGE EFFECT 1, "POSTERIZE", 4

' Apply FXAA anti-aliasing to smooth out jagged lines
IMAGE EFFECT 1, "FXAA"

' Adjust Edge detection, Vignettes, Gamma correction, Grayscale etc.
IMAGE EFFECT 1, "GRAYSCALE"
```

Once your image is perfectly adjusted, generate a physical file:

```basic
IMAGE SAVE 1, "my_masterpiece.png"
```

If you wish to empty an image buffer rapidly without redefining a whole block, use:
```basic
IMAGE CLEAR 1
```
