# WINDOW Command Guide

The `WINDOW` family lets BASIC code create native non-modal windows with Cocoa controls and poll events from the UI thread. Use it when you need buttons, text fields, checkboxes, and labels without blocking your program.

## Quick Start

```basic
WINDOW DEFINE 1, "Hello", 100, 100, 320, 200
    WINDOW BUTTON 10, "Click Me", 20, 20, 120, 28
    WINDOW LABEL 11, "Status: waiting", 20, 60, 200, 24
END WINDOW
WINDOW SHOW 1

DO
    status = WINDOW EVENT(win, ctl)
    IF status = 1 THEN
        IF ctl = 0 THEN EXIT DO               ' window closed
        IF ctl = 10 THEN
            WINDOW SET TEXT 1, 11, "Clicked!"  ' update label text
        END IF
    END IF
    SLEEP 0.05
LOOP
WINDOW SHUTDOWN
```

## Creating Windows

### WINDOW DEFINE

```basic
WINDOW DEFINE id, title$, x, y, w, h
    ' ...controls go here...
END WINDOW
```

Creates a window with a numeric `id`. Title may be any string expression. Coordinates are screen-relative (top-left origin). Nest control definitions inside the block; they automatically belong to this window.

### WINDOW SHOW / HIDE / CLOSE / SHUTDOWN

```basic
WINDOW SHOW id        ' Display the window (blocks until visible)
WINDOW HIDE id        ' Hide the window, preserving its state
WINDOW CLOSE id       ' Destroy the window and free resources
WINDOW SHUTDOWN       ' Close all windows
```

## Controls

All controls take a `control_id` (any number you choose), display text, and a position/size rectangle. Inside a `WINDOW DEFINE ... END WINDOW` block, the window ID is implied. Outside the block, prefix with the window ID.

### BUTTON
```basic
WINDOW BUTTON [win_id,] ctl_id, text$, x, y, w, h
```
A push button. Fires an event when clicked.

### TEXTFIELD
```basic
WINDOW TEXTFIELD [win_id,] ctl_id, default_text$, x, y, w, h
```
An editable text input. Fires an event when the user presses Enter/Return.

### TEXTAREA
```basic
WINDOW TEXTAREA [win_id,] ctl_id, default_text$, x, y, w, h
```
Multi-line editable text. Fires an event when its contents change. Read/write with `WINDOW TEXT$` and `WINDOW SET TEXT`.

### COMBOBOX
```basic
WINDOW COMBOBOX [win_id,] ctl_id, "Choice1|Choice2|Choice3", x, y, w, h
```
Dropdown with editable text entry. Fires an event when the selection changes. Read the selected index with `WINDOW VALUE()`; set the visible label with `WINDOW SET TEXT` if you need a custom display string.

### LABEL
```basic
WINDOW LABEL [win_id,] ctl_id, text$, x, y, w, h
```
A read-only text label. Does not fire events. Use `SET TEXT` to update it.

### CHECKBOX
```basic
WINDOW CHECKBOX [win_id,] ctl_id, text$, x, y, w, h
```
A toggle checkbox. Fires an event each time it is toggled. Read its state with `WINDOW CHECKED()`.

## Property Setters

Update controls or windows without re-specifying their geometry. This is much cleaner than re-issuing a full control definition.

### SET TEXT
```basic
WINDOW SET TEXT win_id, ctl_id, text$
WINDOW SET TEXT win_id, ctl_id, left$, middle$, right$   ' status bar segments
```
Sets the text of any control (label, textfield, button, or checkbox). Status bars support an overload with three segments (left/middle/right); segment text is write-only.

### SET ENABLED
```basic
WINDOW SET ENABLED win_id, ctl_id, flag
```
Enable (`flag = 1`) or disable (`flag = 0`) a control. Disabled controls are grayed out and do not respond to clicks.

### SET VALUE
```basic
WINDOW SET VALUE win_id, ctl_id, value
```
Sets numeric control state (slider/progress position or combo/popup selection index). Use `WINDOW VALUE()` to read it back.

### SET TITLE
```basic
WINDOW SET TITLE win_id, title$
```
Changes the window's title bar text at runtime.

## Event Polling

```basic
s = WINDOW EVENT(winOut, ctlOut)
```

- Returns `s = 0` when no event is queued; `1` when an event is delivered.
- Writes the window id and control id into `winOut` and `ctlOut`.
- A `ctlOut` of `0` means the **window was closed** by the user.
- Poll this in your main loop; the call does not block the UI.

### Typical Event Loop

```basic
running = 1
DO WHILE running
    s = WINDOW EVENT(win, ctl)
    IF s = 1 THEN
        IF ctl = 0 THEN
            running = 0                       ' window closed
        ELSEIF ctl = 10 THEN
            PRINT "Button 10 clicked"
        END IF
    END IF
    SLEEP 0.05
LOOP
```

## Reading Control Values

### TEXT$
```basic
value$ = WINDOW TEXT$(win_id, ctl_id)
```
Returns the current text content of any control — text fields, text areas, labels, buttons, or checkboxes.

### CHECKED
```basic
flag = WINDOW CHECKED(win_id, ctl_id)
```
Returns `1` if a checkbox is checked, `0` if unchecked.

### VALUE
```basic
val = WINDOW VALUE(win_id, ctl_id)
```
Returns numeric control state. For combo/popup this is the selected index; for sliders/progress bars it is the current position.

## Complete Example: Loan Calculator

```basic
DIM principal AS DOUBLE = 300000
DIM apr AS DOUBLE = 6.5

WINDOW DEFINE 1, "Loan Calculator", 100, 100, 420, 380
    WINDOW LABEL 100, "Principal ($):", 20, 20, 120, 24
    WINDOW TEXTFIELD 10, STR$(principal), 150, 20, 220, 24

    WINDOW LABEL 101, "APR (%):", 20, 60, 120, 24
    WINDOW TEXTFIELD 11, STR$(apr), 150, 60, 220, 24

    WINDOW CHECKBOX 20, "Show total interest", 20, 140, 200, 24

    WINDOW BUTTON 1, "Calculate", 20, 180, 170, 28
    WINDOW BUTTON 2, "Reset", 200, 180, 170, 28

    WINDOW LABEL 200, "Payment:", 20, 230, 120, 24
    WINDOW LABEL 210, "-", 150, 230, 220, 24
    WINDOW LABEL 212, "-", 150, 270, 220, 24
END WINDOW

WINDOW SHOW 1

running = 1
DO WHILE running
    status = WINDOW EVENT(win, ctl)
    IF status = 1 AND win = 1 THEN
        IF ctl = 0 THEN
            running = 0
        ELSEIF ctl = 1 THEN
            ' Read inputs from text fields
            principal = VAL(WINDOW TEXT$(1, 10))
            apr = VAL(WINDOW TEXT$(1, 11))
            r = (apr / 100) / 12
            payment = principal * r / (1 - (1 + r)^(-360))

            WINDOW SET TEXT 1, 210, "$" + STR$(payment)
            WINDOW SET TITLE 1, "Loan: $" + STR$(payment) + "/mo"

            IF WINDOW CHECKED(1, 20) THEN
                WINDOW SET TEXT 1, 212, "$" + STR$(payment * 360 - principal)
            ELSE
                WINDOW SET TEXT 1, 212, "(check box to show)"
            END IF
        ELSEIF ctl = 2 THEN
            WINDOW SET TEXT 1, 10, "300000"
            WINDOW SET TEXT 1, 11, "6.5"
            WINDOW SET TEXT 1, 210, "-"
            WINDOW SET TEXT 1, 212, "-"
            WINDOW SET TITLE 1, "Loan Calculator"
        END IF
    END IF
    SLEEP 0.05
LOOP
WINDOW SHUTDOWN
```

## Command Reference

| Command | Description |
|---|---|
| `WINDOW DEFINE id, title$, x, y, w, h` | Create a window |
| `WINDOW BUTTON [win,] ctl, text$, x, y, w, h` | Add a push button |
| `WINDOW TEXTFIELD [win,] ctl, text$, x, y, w, h` | Add an editable text field |
| `WINDOW TEXTAREA [win,] ctl, text$, x, y, w, h` | Add a multi-line text area |
| `WINDOW COMBOBOX [win,] ctl, opts$, x, y, w, h` | Add a dropdown combo box (selection via VALUE) |
| `WINDOW LABEL [win,] ctl, text$, x, y, w, h` | Add a read-only label |
| `WINDOW CHECKBOX [win,] ctl, text$, x, y, w, h` | Add a checkbox |
| `WINDOW SHOW id` | Show a window |
| `WINDOW HIDE id` | Hide a window |
| `WINDOW CLOSE id` | Close and destroy a window |
| `WINDOW SHUTDOWN` | Close all windows |
| `WINDOW SET TEXT win, ctl, text$` | Set control text |
| `WINDOW SET VALUE win, ctl, value` | Set numeric control value or selection |
| `WINDOW SET ENABLED win, ctl, 0/1` | Enable or disable a control |
| `WINDOW SET TITLE win, title$` | Change window title |
| `WINDOW EVENT(win, ctl)` | Poll for events (returns 0 or 1) |
| `WINDOW TEXT$(win, ctl)` | Read control text |
| `WINDOW VALUE(win, ctl)` | Read control numeric value / selection index |
| `WINDOW CHECKED(win, ctl)` | Read checkbox state (0 or 1) |

## Notes

- **Non-modal**: your BASIC loop keeps running; no dialog-style blocking.
- **Graphics mode**: programs using `WINDOW` are automatically marked to link the graphics runtime.
- **Thread-safe**: all UI mutations dispatch to the main thread; event polling is lock-guarded.
- **In-place updates**: re-issuing a control with the same `ctl_id` updates text and frame in place (avoids flicker). Use `SET TEXT` when you only need to change text.
- **Text fields** fire events on Enter/Return. Use a "Submit" button alongside for explicit actions.

## Troubleshooting

- **No window appears**: ensure you called `WINDOW SHOW id` after `WINDOW DEFINE`.
- **No events**: poll regularly and keep the process responsive (avoid long blocking loops without `SLEEP`).
- **Duplicate IDs**: using the same `ctl_id` in one window updates the existing control in place.
- **Checkbox reads 0**: `WINDOW CHECKED()` only reads `NSButton` switch-type controls; labels and text fields always return 0.
