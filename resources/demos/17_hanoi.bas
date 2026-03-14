' =========================================================================
' Towers of Hanoi Animation Demo
' An animated demonstration of the classic recursive solution to the Towers of Hanoi puzzle.
' - The goal is to move all disks from rod 1 to rod 3.
' - You can only move one disk at a time.
' - You can never place a larger disk on a smaller disk.
' - This demo precomputes the recursive solution, then animates each move.
' =========================================================================
APPNAME "Towers of Hanoi Demo"
SCREEN 640, 480, 2
SCREENTITLE "Towers of Hanoi Demo"

CONSTANT STATE_INTRO = 0
CONSTANT STATE_RUN = 1
CONSTANT STATE_DONE = 2

CONSTANT MAX_DISKS = 8
CONSTANT MAX_MOVES = 255

' game_state controls which screen/mode we are in:
' intro -> running animation -> solved screen

GLOBAL game_state AS INTEGER
GLOBAL disk_count AS INTEGER
GLOBAL total_steps AS INTEGER
GLOBAL step_count AS INTEGER
GLOBAL step_index AS INTEGER

DIM step_from(255) AS INTEGER
DIM step_to(255) AS INTEGER

' step_from(i), step_to(i) store the i-th planned move.
' Example: movefrom(10)=1 and moveto(10)=3 means
' "on move 10, move top disk from rod 1 to rod 3".

DIM rod_h(3) AS INTEGER
DIM rod_x(3) AS DOUBLE

' rod_h(r) = current stack height of rod r.
' rod_x(r) = x position for drawing rod r on screen.

GLOBAL anim_active AS INTEGER
GLOBAL anim_phase AS INTEGER
GLOBAL anim_disk AS INTEGER
GLOBAL anim_from AS INTEGER
GLOBAL anim_to AS INTEGER
GLOBAL anim_x AS DOUBLE
GLOBAL anim_y AS DOUBLE
GLOBAL anim_target_x AS DOUBLE
GLOBAL anim_target_y AS DOUBLE
GLOBAL anim_lift_y AS DOUBLE

GLOBAL frame AS INTEGER

' rod1/rod2/rod3 store disk IDs from bottom->top.
' Smaller disk ID means smaller disk (1 is smallest).

DIM rod1(MAX_DISKS) AS INTEGER
DIM rod2(MAX_DISKS) AS INTEGER
DIM rod3(MAX_DISKS) AS INTEGER

SUB InitAudio()
  ' Simple two-sound setup: pickup and drop effects.
  SOUND VOLUME 1.0
  SOUND ZAP 1, 520, 0.20
  SOUND ZAP 2, 220, 0.25
END SUB

FUNCTION RodCenterX(r AS INTEGER)
  SHARED rod_x
  RETURN rod_x(r)
END FUNCTION

FUNCTION DiskWidth(d AS INTEGER)
  ' Larger disk number => wider rectangle.
  RETURN 34 + d * 20
END FUNCTION

FUNCTION SlotY(level AS INTEGER)
  ' Bottom slot is level 1; higher levels are drawn upward.
  RETURN 430 - level * 20
END FUNCTION

FUNCTION DiskColor(d AS INTEGER)
  RETURN 2 + ((d - 1) MOD 13)
END FUNCTION

SUB PushDisk(r AS INTEGER, d AS INTEGER)
  ' Push disk d on top of rod r (stack push).
  SHARED rod_h, rod1, rod2, rod3
  rod_h(r) = rod_h(r) + 1
  IF r = 1 THEN
    rod1(rod_h(r)) = d
  ELSEIF r = 2 THEN
    rod2(rod_h(r)) = d
  ELSE
    rod3(rod_h(r)) = d
  END IF
END SUB

FUNCTION PopDisk(r AS INTEGER)
  ' Pop and return top disk from rod r (stack pop).
  SHARED rod_h, rod1, rod2, rod3
  DIM d AS INTEGER

  d = 0
  IF rod_h(r) <= 0 THEN RETURN 0

  IF r = 1 THEN
    d = rod1(rod_h(r))
    rod1(rod_h(r)) = 0
  ELSEIF r = 2 THEN
    d = rod2(rod_h(r))
    rod2(rod_h(r)) = 0
  ELSE
    d = rod3(rod_h(r))
    rod3(rod_h(r)) = 0
  END IF

  rod_h(r) = rod_h(r) - 1
  RETURN d
END FUNCTION

SUB RecordStep(from_rod AS INTEGER, to_rod AS INTEGER)
  ' Append one move to the move list.
  SHARED step_count, step_from, step_to
  step_count = step_count + 1
  step_from(step_count) = from_rod
  step_to(step_count) = to_rod
END SUB

SUB BuildSteps(n AS INTEGER, from_rod AS INTEGER, aux_rod AS INTEGER, to_rod AS INTEGER)
  ' Classic recursive Hanoi solver:
  ' 1) Move n-1 from source to helper
  ' 2) Move largest remaining disk source -> target
  ' 3) Move n-1 from helper to target
  IF n <= 0 THEN EXIT SUB
  CALL BuildSteps(n - 1, from_rod, to_rod, aux_rod)
  CALL RecordStep(from_rod, to_rod)
  CALL BuildSteps(n - 1, aux_rod, from_rod, to_rod)
END SUB

SUB SetupPuzzle(n AS INTEGER)
  ' Reset rods and precompute full move list for n disks.
  SHARED rod_h, rod1, rod2, rod3
  SHARED disk_count, total_steps, step_count, step_index
  DIM i AS INTEGER

  disk_count = n

  rod1() = 0
  rod2() = 0
  rod3() = 0
  rod_h() = 0

  FOR i = disk_count TO 1 STEP -1
    CALL PushDisk(1, i)
  NEXT i

  total_steps = 1
  ' total_steps = 2^n - 1
  FOR i = 1 TO disk_count
    total_steps = total_steps * 2
  NEXT i
  total_steps = total_steps - 1

  step_count = 0
  step_index = 0
  CALL BuildSteps(disk_count, 1, 2, 3)
END SUB

SUB DrawDiskBySpec(cx AS DOUBLE, y AS DOUBLE, disk AS INTEGER)
  DIM w AS DOUBLE
  DIM c AS INTEGER
  w = DiskWidth(disk)
  c = DiskColor(disk)

  RECT cx - (w / 2), y, w, 16, c, 1
  RECT cx - (w / 2), y, w, 16, 1, 0
END SUB

SUB DrawRodStack(r AS INTEGER)
  ' Draw every disk currently stacked on a rod.
  SHARED rod_h, rod1, rod2, rod3
  DIM i AS INTEGER
  DIM d AS INTEGER
  DIM cx AS DOUBLE

  cx = RodCenterX(r)

  FOR i = 1 TO rod_h(r)
    IF r = 1 THEN
      d = rod1(i)
    ELSEIF r = 2 THEN
      d = rod2(i)
    ELSE
      d = rod3(i)
    END IF
    CALL DrawDiskBySpec(cx, SlotY(i), d)
  NEXT i
END SUB

SUB DrawScene()
  ' Render one full frame: UI, rods, disks, and status text.
  SHARED anim_active, anim_disk, anim_x, anim_y
  SHARED game_state, step_index, total_steps, disk_count
  DIM i AS INTEGER

  GCLS 0

  ' Header
  RECT 0, 0, 640, 42, 1, 1
  DRAWTEXT 10, 12, "TOWERS OF HANOI (ANIMATION)", 15, 1
  DRAWTEXT 345, 12, "DISKS: " & STR$(disk_count), 15, 1
  DRAWTEXT 480, 12, "MOVE: " & STR$(step_index) & "/" & STR$(total_steps), 15, 1

  ' Base and rods
  RECT 70, 438, 500, 10, 6, 1
  FOR i = 1 TO 3
    RECT RodCenterX(i) - 5, 170, 10, 268, 8, 1
    DRAWTEXT RodCenterX(i) - 4, 448, STR$(i), 15, 0
  NEXT i

  ' Draw disks on rods
  CALL DrawRodStack(1)
  CALL DrawRodStack(2)
  CALL DrawRodStack(3)

  ' Draw moving disk on top
  IF anim_active = 1 THEN
    CALL DrawDiskBySpec(anim_x, anim_y, anim_disk)
  END IF

  IF game_state = STATE_INTRO THEN
    DRAWTEXT 170, 86, "Automatic recursive solution demo", 11, 0
    DRAWTEXT 170, 110, "Press any key to start (ESC quits)", 14, 0
  ELSEIF game_state = STATE_DONE THEN
    DRAWTEXT 215, 86, "Solved! Press any key to run again", 10, 0
  END IF
END SUB

SUB StartStep(from_rod AS INTEGER, to_rod AS INTEGER)
  ' Start animating one planned step.
  ' We remove disk from source rod immediately, then animate through 3 phases:
  ' lift up -> move sideways -> drop down.
  SHARED anim_active, anim_phase, anim_disk, anim_from, anim_to
  SHARED anim_x, anim_y, anim_target_x, anim_target_y, anim_lift_y
  SHARED rod_h

  anim_from = from_rod
  anim_to = to_rod
  anim_disk = PopDisk(from_rod)
  IF anim_disk <= 0 THEN EXIT SUB

  anim_x = RodCenterX(from_rod)
  anim_y = SlotY(rod_h(from_rod) + 1)
  anim_target_x = RodCenterX(to_rod)
  anim_target_y = SlotY(rod_h(to_rod) + 1)
  anim_lift_y = 120

  anim_phase = 0
  anim_active = 1
  SOUND PLAY 1, 0.6
END SUB

SUB UpdateAnimation()
  ' Advance current animation by one frame.
  SHARED anim_active, anim_phase, anim_disk, anim_to
  SHARED anim_x, anim_y, anim_target_x, anim_target_y, anim_lift_y
  DIM vx AS DOUBLE
  DIM vy AS DOUBLE

  IF anim_active = 0 THEN EXIT SUB

  vx = 4.2
  vy = 4.0

  IF anim_phase = 0 THEN
    ' Phase 0: lift disk to a safe travel height.
    anim_y = anim_y - vy
    IF anim_y <= anim_lift_y THEN
      anim_y = anim_lift_y
      anim_phase = 1
    END IF

  ELSEIF anim_phase = 1 THEN
    ' Phase 1: move horizontally toward destination rod.
    IF anim_x < anim_target_x THEN
      anim_x = anim_x + vx
      IF anim_x >= anim_target_x THEN anim_x = anim_target_x
    ELSE
      anim_x = anim_x - vx
      IF anim_x <= anim_target_x THEN anim_x = anim_target_x
    END IF

    IF anim_x = anim_target_x THEN
      anim_phase = 2
    END IF

  ELSE
    ' Phase 2: lower disk onto destination stack and finish move.
    anim_y = anim_y + vy
    IF anim_y >= anim_target_y THEN
      anim_y = anim_target_y
      CALL PushDisk(anim_to, anim_disk)
      anim_active = 0
      SOUND PLAY 2, 0.6
    END IF
  END IF
END SUB

' -------------------------------------------------------------------------
' Boot
' -------------------------------------------------------------------------
CALL InitAudio()
rod_x(1) = 160
rod_x(2) = 320
rod_x(3) = 480

CALL SetupPuzzle(6)
game_state = STATE_INTRO
frame = 0

DIM quit_game AS INTEGER
DIM key_pressed AS INTEGER
quit_game = 0

DO
  ' Main game loop (runs every frame).
  ' ESC exits; otherwise we update state machine + draw + vsync.
  IF GKEYDOWN(53) THEN
    quit_game = 1
    EXIT DO
  END IF

  IF game_state = STATE_INTRO THEN
    ' Wait for any key to start animation.
    key_pressed = GINKEY()
    IF key_pressed > 0 AND key_pressed <> 53 THEN
      game_state = STATE_RUN
    END IF

  ELSEIF game_state = STATE_RUN THEN
    ' If no step is animating, begin next planned step.
    IF anim_active = 0 THEN
      IF step_index < step_count THEN
        step_index = step_index + 1
        CALL StartStep(step_from(step_index), step_to(step_index))
      ELSE
        game_state = STATE_DONE
      END IF
    END IF
    CALL UpdateAnimation()

  ELSEIF game_state = STATE_DONE THEN
    ' Restart puzzle on key press.
    key_pressed = GINKEY()
    IF key_pressed > 0 AND key_pressed <> 53 THEN
      CALL SetupPuzzle(6)
      game_state = STATE_RUN
    END IF
  END IF

  CALL DrawScene()
  FLIP
  VSYNC

  frame = frame + 1
LOOP UNTIL quit_game = 1

SCREENSAVE "/tmp/hanoi_demo.png"
PRINT "HANOI DEMO COMPLETE: /tmp/hanoi_demo.png"
