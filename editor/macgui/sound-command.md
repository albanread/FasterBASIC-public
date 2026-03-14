# SOUND Command: Fast Game SFX in FasterBASIC

This guide documents the `SOUND` command as implemented in this project, with practical hints for **simple arcade/game effects**.

It focuses on:

- slot-based sound creation
- predefined SFX commands
- quick usage patterns for jump, shoot, hit, pickup, and explosions

## See Also

- [Audio System Guide (Friendly Quickstart)](audio-system-guide.md) — choose SOUND vs MUSIC vs VS quickly.
- [ABC Player for Arcade Games](ABCplayer.md) — music composition/playback flow for `MUSIC LOAD` and `MUSIC PLAY`.
- [Introduction to VoiceScript](introduction_voicescript.md) — getting started with live synth voices in BASIC.
- [Advanced VoiceScript Guide](advanced_voicescript.md) — deeper VS architecture and advanced control patterns.
- [Workers: Safe Concurrency](workers.md) — use workers for heavy CPU tasks, not for audio callback timing.

---

## Mental Model

`SOUND` is a two-step workflow:

1. **Create** a sound into a slot.
2. **Play** that slot whenever needed.

```basic
SOUND COIN 1, 1.1, 0.12
SOUND PLAY 1, 1.0, 0.0
```

Why this is useful for games:

- create once, trigger many times
- easy per-event mapping (`slot 1 = coin`, `slot 2 = jump`, etc.)
- predictable CPU use during gameplay

---

## Core Syntax (Arcade Subset)

### Create predefined SFX

```basic
SOUND BEEP slot, frequency, duration
SOUND ZAP slot, frequency, duration
SOUND EXPLODE slot, size, duration
SOUND BIGEXPLODE slot, size, duration
SOUND SMALLEXPLODE slot, intensity, duration
SOUND DISTANTEXPLODE slot, distance, duration
SOUND METALEXPLODE slot, shrapnel, duration
SOUND BANG slot, intensity, duration
SOUND COIN slot, pitch, duration
SOUND JUMP slot, power, duration
SOUND POWERUP slot, intensity, duration
SOUND HURT slot, severity, duration
SOUND SHOOT slot, power, duration
SOUND CLICK slot, sharpness, duration
SOUND BLIP slot, pitch, duration
SOUND PICKUP slot, brightness, duration
SOUND SWEEPUP slot, startFreq, endFreq, duration
SOUND SWEEPDOWN slot, startFreq, endFreq, duration
SOUND RANDOMBEEP slot, seed, duration
```

### Play and control

```basic
SOUND PLAY slot [, volume [, pan]]
SOUND STOP
SOUND FREE slot
SOUND FREE ALL
SOUND VOLUME level
```

---

## Slot Strategy for Small Games

Use a stable slot map so your code stays readable:

```basic
' Suggested slot map
' 1 = coin/pickup
' 2 = jump
' 3 = shoot
' 4 = hurt
' 5 = explosion
' 6 = UI click
```

Initialize at startup/level-load:

```basic
SOUND COIN 1, 1.1, 0.10
SOUND JUMP 2, 0.9, 0.14
SOUND SHOOT 3, 1.0, 0.08
SOUND HURT 4, 0.8, 0.16
SOUND EXPLODE 5, 1.0, 0.35
SOUND CLICK 6, 0.8, 0.05
```

Trigger from gameplay events:

```basic
IF gotCoin THEN SOUND PLAY 1, 0.9
IF jumpPressed THEN SOUND PLAY 2, 0.9
IF firePressed THEN SOUND PLAY 3, 0.8
IF tookDamage THEN SOUND PLAY 4, 1.0
IF enemyDead THEN SOUND PLAY 5, 0.9
```

---

## Preset Cheat Sheet (Game-Oriented)

These are practical sonic roles, not strict rules.

### UI / Feedback

- `SOUND CLICK`: menus, confirm, cursor move
- `SOUND BLIP`: radar ticks, tiny HUD updates
- `SOUND BEEP`: generic short notifications

### Player Actions

- `SOUND JUMP`: platformer jump and bounce
- `SOUND SHOOT`: bullets, lasers, throw action
- `SOUND POWERUP`: ability unlock, mode-up

### Rewards

- `SOUND COIN`: pickups, score, bonus chain
- `SOUND PICKUP`: softer/warmer collectible cue

### Combat / Impact

- `SOUND HURT`: player or enemy damage
- `SOUND BANG`: punch, impact, collisions
- `SOUND ZAP`: sci-fi hit, electric damage

### Destruction

- `SOUND SMALLEXPLODE`: small enemies/projectiles
- `SOUND EXPLODE`: standard enemy/object
- `SOUND BIGEXPLODE`: boss or major object
- `SOUND DISTANTEXPLODE`: background ambience depth
- `SOUND METALEXPLODE`: robotic/armored destruction

### Motion / Transitions

- `SOUND SWEEPUP`: charge-up, spawn-in, level-up
- `SOUND SWEEPDOWN`: warning-down, fail, despawn
- `SOUND RANDOMBEEP`: retro computer chatter, variation

---

## Parameter Tuning Hints

### Duration

- Most gameplay SFX: `0.05` to `0.25`
- Larger events: `0.30` to `0.80`

Shorter sounds feel more responsive in action gameplay.

### Loudness / mix

- Use `SOUND PLAY slot, volume` per event
- Keep master with `SOUND VOLUME level` (for global balancing)
- Typical per-event range: `0.6` to `1.0`

### Stereo placement

Use pan for spatial feedback:

- `-1.0` left
- `0.0` center
- `1.0` right

Example:

```basic
' Enemy on left side of screen
SOUND PLAY 3, 0.8, -0.5
```

---

## Minimal Arcade Pack (Copy/Paste)

```basic
' --- Init once ---
SOUND COIN 1, 1.1, 0.10
SOUND JUMP 2, 0.9, 0.14
SOUND SHOOT 3, 1.0, 0.08
SOUND HURT 4, 0.8, 0.16
SOUND EXPLODE 5, 1.0, 0.35
SOUND CLICK 6, 0.8, 0.05
SOUND VOLUME 0.9

' --- During game loop ---
' SOUND PLAY 1   ' coin
' SOUND PLAY 2   ' jump
' SOUND PLAY 3   ' shoot
' SOUND PLAY 4   ' hurt
' SOUND PLAY 5   ' explode
' SOUND PLAY 6   ' ui click
```

---

## Practical Notes

- `SOUND STOP` stops currently playing sounds globally.
- `SOUND FREE slot` releases one slot when you no longer need it.
- `SOUND FREE ALL` is useful on scene unload.
- If many effects stack too loudly, lower `SOUND VOLUME` and use shorter durations.

### Engine note (BASIC-facing)

- Internal audio plumbing now has a cleaner path for adopting generated buffers into playable `SOUND` slots.
- At the BASIC level this does **not** add new `SOUND` syntax yet.
- Keep using normal slot workflow: create (`SOUND ...`) → trigger (`SOUND PLAY`) → free (`SOUND FREE`).

---

## Suggested Workflow

1. Start with 4–6 core slots (coin, jump, shoot, hurt, explode, click).
2. Tune durations first (responsiveness), then loudness.
3. Add variation only where repetition is obvious (`RANDOMBEEP`, alternate slots).
4. Keep effects short and clear; game feel improves when SFX do not mask each other.

That’s enough to ship clean retro/arcade audio feedback without building a full audio system by hand.
