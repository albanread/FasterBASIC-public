# Dialogs in FasterBASIC

Use `DIALOG` to build native macOS modal forms from BASIC.

These are limited, because the dialog is displayed in a different user interface thread.  BASIC can then read the results, however to change anything from BASIC the dialog is reopened.

Even so these are useful to request user input.

## Why Use Dialogs

Dialogs are useful when you want:

- structured user input (instead of console prompts)
- native controls (`TEXTFIELD`, `DROPDOWN`, `CHECKBOX`, etc.)
- a simple modal workflow: define → show → read values

## Core Workflow

1. Define a dialog with `DIALOG DEFINE <id> ... END DEFINE`
2. Show it with `choice = DIALOG SHOW(<id>)`
3. Read values with `DIALOG TEXT$`, `DIALOG CHECKED`, `DIALOG SELECTION`
4. Optionally update defaults for next show with `DIALOG SET*`
5. Cleanup with `DIALOG RESET`

## Dialog Definition

```basic
DIALOG DEFINE 1
    TITLE "Example"
    MESSAGE "Enter values and click OK."

    NUMBERFIELD 10, "Amount", 100, 0, 100000
    DROPDOWN 20, "Mode", "Fast|Balanced|Accurate", 1
    CHECKBOX 30, "Enable advanced mode", CHECKED

    BUTTON 1, "OK", DEFAULT
    BUTTON 2, "Cancel", CANCEL
END DEFINE
```

## Controls

### Static text

- `LABEL "text"`

### Text input

- `TEXTFIELD id, "Label" [, "default"]`
- `SECUREFIELD id, "Label" [, "default"]`
- `TEXTAREA id, "Label" [, "default"]`

### Numeric input

- `NUMBERFIELD id, "Label", default, min, max [, step]`
- `SLIDER id, "Label", min, max, default`

### Selection/toggle

- `CHECKBOX id, "Label" [, CHECKED]`
- `RADIO id, groupId, "Label" [, SELECTED]`
- `DROPDOWN id, "Label", "A|B|C" [, defaultIndex]`

### File path helper

- `FILEPICKER id, "Label" [, "default/path"]`

### Buttons

- `BUTTON id, "Label" [, DEFAULT | CANCEL]`

## Showing and Handling Results

```basic
choice = DIALOG SHOW(1)

IF choice = 0 OR choice = 2 THEN
    ' 0 means window closed (titlebar X)
    ' 2 means Cancel button in this example
    END
END IF
```

`DIALOG SHOW` returns:

- button id for the clicked button
- `0` when the dialog is closed via the window close button

## Reading Values

After `DIALOG SHOW`:

- `DIALOG TEXT$(id)` → string value
- `DIALOG CHECKED(id)` → `1` or `0`
- `DIALOG SELECTION(id)` → selected index (dropdown), or numeric selection value for some controls such as slider

Example:

```basic
name$ = DIALOG TEXT$(11)
useFast = DIALOG CHECKED(30)
mode = DIALOG SELECTION(20)
value = VAL(DIALOG TEXT$(10))
```

## Writing Values Back (for Next Show)

Setters let BASIC update stored control values between `SHOW` calls:

- `DIALOG SETTEXT id, text$`
- `DIALOG SETNUMBER id, number`
- `DIALOG SETCHECKED id, state`
- `DIALOG SETSELECTION id, index`

Example:

```basic
DIALOG SETNUMBER 10, 250
DIALOG SETCHECKED 30, 1
DIALOG SETSELECTION 20, 0
```

## Complete Example

```basic
PRINT "Dialog Quick Demo"

DO
    DIALOG DEFINE 7
        TITLE "Temperature Converter"
        MESSAGE "Choose conversion mode and value"

        NUMBERFIELD 10, "Temperature", 32, -500, 2000
        DROPDOWN 20, "Convert", "F -> C|C -> F", 0

        BUTTON 1, "Convert", DEFAULT
        BUTTON 2, "Quit", CANCEL
    END DEFINE

    choice = DIALOG SHOW(7)
    IF choice = 0 OR choice = 2 THEN EXIT DO

    t = VAL(DIALOG TEXT$(10))
    mode = DIALOG SELECTION(20)

    IF mode = 0 THEN
        r = (t - 32) * 5 / 9
        PRINT t; " F = "; r; " C"
    ELSE
        r = (t * 9 / 5) + 32
        PRINT t; " C = "; r; " F"
    END IF

    DIALOG SETNUMBER 10, r
LOOP

DIALOG RESET
PRINT "Done."
```

## Tips

- Keep control IDs unique per dialog.
- Treat dialog close (`choice = 0`) as cancel/quit in your control flow.
- Reuse one dialog ID and update fields with `DIALOG SET*` to keep UX smooth.
- For real examples, see:
  - [demos/dialog_temp_converter.bas](../demos/dialog_temp_converter.bas)
  - [demos/dialog_calculator_pro.bas](../demos/dialog_calculator_pro.bas)
  - [calculators/dialog_loan_payment.bas](../calculators/dialog_loan_payment.bas)
