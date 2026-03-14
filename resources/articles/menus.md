# Menus in FasterBASIC

This guide shows how to add native macOS menu bars to your graphics programs using the `MENU` features.

## What You Get

- Declarative menu definitions with `MENU DEFINE ... END DEFINE`
- Clickable menu items with stable numeric IDs
- Keyboard shortcuts (like `Cmd+Q`)
- Runtime updates (`MENU CHECK`, `MENU ENABLE`, `MENU RENAME`)
- Event polling with `MENU EVENT()` so your game loop stays single-threaded

## Core Syntax

### 1) Define menus

```basic
MENU DEFINE
  MENU "Game"
    ITEM 101, "New", "Cmd+N"
    ITEM 102, "Pause", "P", CHECKED
    SEPARATOR
    ITEM 103, "Quit", "Cmd+Q"
  END MENU

  MENU "View"
    ITEM 201, "Show FPS", "", CHECKED
    ITEM 202, "Wireframe", "W", DISABLED
  END MENU
END DEFINE
```

### 2) Poll events in your loop

```basic
ev = MENU EVENT()
IF ev <> 0 THEN
    SELECT CASE ev
        CASE 101
            ' New
        CASE 102
            ' Pause
        CASE 103
            ' Quit
    END SELECT
END IF
```

`MENU EVENT()` returns the clicked `ITEM` id, or `0` when no pending event exists.

### 3) Update items at runtime

```basic
MENU CHECK 102, 1          ' check Pause
MENU ENABLE 202, 0         ' disable Wireframe
MENU RENAME 101, "Restart" ' rename New -> Restart
MENU RESET                 ' remove all user-defined menus
```

## ITEM Flags

Inside `MENU DEFINE`, each `ITEM` supports optional flags:

- `CHECKED` — starts with a checkmark
- `DISABLED` — starts disabled

You can combine shortcut + flags:

```basic
ITEM 500, "Autosave", "Cmd+S", CHECKED
ITEM 501, "Danger Action", "", DISABLED
```

## Shortcut Format

Shortcut strings use `+` separators. Examples:

- `"P"`
- `"Cmd+Q"`
- `"Cmd+Shift+P"`
- `"Ctrl+Alt+K"`
- `"F5"`

Supported modifiers:

- `CMD` or `COMMAND`
- `SHIFT`
- `ALT` or `OPTION`
- `CTRL` or `CONTROL`

## Practical Pattern

Use menu IDs as command constants and treat menus as input events.

```basic
SCREEN 640, 480, 2

MENU DEFINE
  MENU "Program"
    ITEM 101, "Toggle Pause", "P"
    ITEM 102, "Show FPS", "F", CHECKED
    SEPARATOR
    ITEM 199, "Quit", "Cmd+Q"
  END MENU
END DEFINE

paused = 0
showFps = 1
running = 1

DO WHILE running = 1
    ev = MENU EVENT()

    IF ev <> 0 THEN
        SELECT CASE ev
            CASE 101
                paused = 1 - paused
            CASE 102
                showFps = 1 - showFps
                MENU CHECK 102, showFps
            CASE 199
                running = 0
        END SELECT
    END IF

    ' render/update here
    VSYNC
LOOP

MENU RESET
SCREENCLOSE
END
```

## Notes

- Menus are intended for graphics-window programs.
- Keep item IDs unique in your program.
- Call `MENU RESET` when done (also good hygiene between scenes/tools).
- For a full runnable example, see [demos/create_menu_demo1.bas](../demos/create_menu_demo1.bas).
