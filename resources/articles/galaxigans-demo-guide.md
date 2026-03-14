# Building a Galaxigans Clone in FasterBASIC: A Beginner's Guide

If you've ever wanted to build yourself a classic arcade shooter like Galaxigans, you might not know where to start.
Relax with FasterBASIC, you can build a pixel perfect game using simple, readable code. 

In this article, we'll break down how the FasterBASIC Galaxigans demo works, exploring how to define sprites, handle game logic, and use some basic math to bring the alien swarm to life.

## 1. Defining the Art: The Power of `SPRITE ROW`

Before we can shoot aliens, we need to draw them. FasterBASIC uses a powerful, built-in GPU-accelerated sprite engine.
These are a form of hardware sprites, using the hardware in your computer.
 Instead of loading external image files, we can define our pixel art directly in the code using `SPRITE ROW`.

Here is how we define the player's ship:

```vb
SPRITE DEF 0, 16, 16
SPRITE PALETTE 0, 1, 255, 255, 255   ' white hull
SPRITE PALETTE 0, 2, 220,  20,  20   ' red wings
SPRITE PALETTE 0, 3,  20,  60, 220   ' blue body

SPRITE BEGIN 0
GCLS 0
SPRITE ROW 0, "0000000110000000"
SPRITE ROW 1, "0000001111000000"
' ... more rows ...
SPRITE END
```

**How it works:**
1. `SPRITE DEF 0, 16, 16` tells the engine we are creating Sprite #0, and it will be 16x16 pixels in size.
2. `SPRITE PALETTE` assigns RGB colors to specific numbers (1 = white, 2 = red, etc.). Number 0 is always transparent.
3. `SPRITE ROW` lets us draw the sprite row by row using a string of numbers. 

Each number corresponds to the palette color we just defined. It's literally painting by numbers, we have 16 colour sprites, so the numbers are 0 to F and the editor will even colour them.

We are also able to draw into a sprite.


## 2. The Game Loop: The Heartbeat of the Game

Every game needs a heartbeat—a loop that runs continuously, updating positions and drawing the screen. In FasterBASIC, our game loop looks like this:

```vb
DO
    GCLS 0 ' Clear the screen to black

    ' Update game logic
    CALL UpdateStars()
    CALL UpdatePlayer(frame)
    CALL UpdateEnemies(frame)
    CALL UpdateBullets()
    
    FLIP   ' Swap the hidden drawing buffer to the screen
    VSYNC  ' Wait for the monitor to refresh (locks game to 60 FPS)
    frame = frame + 1
LOOP UNTIL quit_game = 1
```

By using `FLIP` and `VSYNC`, we ensure the game runs smoothly without flickering or tearing. All our drawing happens invisibly in the background, and `FLIP` pushes the finished frame to the monitor all at once.

## 3. State Machines: Keeping Things Organized

A game isn't just shooting; it has menus, game over screens, and victory celebrations. To manage this, we use a **State Machine**. We define constants for our different states:

```vb
CONSTANT STATE_INTRO = 0
CONSTANT STATE_PLAYING = 1
CONSTANT STATE_GAMEOVER = 2
CONSTANT STATE_WIN = 3

DIM game_state AS INTEGER
game_state = STATE_INTRO
```

Inside our main loop, we use `IF / ELSEIF` blocks to check the `game_state`. 
- If it's `STATE_INTRO`, we flash "PLAYER 1 READY" and wait for a keypress.
- If it's `STATE_PLAYING`, we run the normal game logic.
- If the player loses all their ships, we switch to `STATE_GAMEOVER`.

This keeps our code clean. Instead of a tangled mess of `GOTO` statements, the game smoothly transitions from one logical state to the next.

## 4. The Math of Movement: Sine Waves and Trigonometry

The most exciting part of Galaxigans is how the enemies move. They don't just fly in straight lines; they swoop, dive, and dance. To achieve this, we use a bit of high school trigonometry: **Sine and Cosine**.

### The Alien Dive
When an alien breaks formation to attack the player, we want it to swoop down in a smooth arc. We do this by combining a linear movement (straight down) with a sinusoidal movement (waving left and right).

```vb
' t goes from 0.0 to 1.0 as the alien dives
dx_dive = SIN(t * 2.5) * 180.0
dy_dive = t * 450.0

ex = ex + dx_dive
ey = ey + dy_dive
```
- `dy_dive` pushes the alien straight down the screen.
- `dx_dive` uses `SIN()` to push the alien left and right. Because a sine wave curves smoothly, the resulting flight path is a beautiful, sweeping arc.

### The Victory Dance
If the aliens defeat the player, they perform a spiral celebration dance. We use Sine and Cosine together to calculate points on a circle:

```vb
angle = frame * 0.04 + i * 0.2
radius = 120.0 + SIN(frame * 0.02 + i * 0.1) * 100.0

ex = cx + COS(angle) * radius
ey = cy + SIN(angle) * radius
```
By constantly increasing the `angle`, `COS` and `SIN` give us the X and Y coordinates to make the aliens orbit a center point (`cx`, `cy`). By also pulsing the `radius` with another sine wave, the circle expands and contracts, creating a mesmerizing spiral effect.

## 5. Collision Detection: Did We Hit Them?

What good is a shooter if you can't shoot? FasterBASIC makes collision detection incredibly easy with the built-in `SPRITEHIT()` function.

```vb
IF SPRITEHIT(bullet_sprite_id, enemy_sprite_id) THEN
    ' Boom! We hit them!
    enemy_alive(j) = 0
    bullet_active(i) = 0
    SPRITE HIDE j
    SPRITE HIDE bullet_sprite_id
END IF
```
Instead of writing complex math to check if two rectangles overlap, `SPRITEHIT()` handles the math for you behind the scenes. It calculates the Axis-Aligned Bounding Box (AABB) of both sprites—even taking into account their scale and rotation—and checks if they overlap. While it's not pixel-perfect (it checks the rectangular bounds, not individual pixels), it is lightning fast and reasonable for arcade games.


## Colour limits

Creating pixel art with photorealistic images is not friendly.

So we have 16 colour sprites, only 14 can be changed, 0 is see through, and 1 is always black. 
However, each sprite has its own 14 colours, and you can show 512 of those at once. So that could add up to 7,168 colours from sprites...


## Conclusion

Building a game like Galaxigans might seem daunting, but by breaking it down into smaller pieces—defining art, managing state, applying simple math for movement, and checking collisions—it becomes highly approachable. 

FasterBASIC provides all the tools you need to focus on the fun part: designing the game. So grab your keyboard, switch off the internet, tweak the sine waves, draw some new aliens, and make the arcade classic your own!