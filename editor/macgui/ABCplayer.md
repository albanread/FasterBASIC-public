# ABC Player for Arcade Games (FasterBASIC)

This guide is about **how ABC works in this codebase**, not the full ABC standard.

If you want game-ready music quickly, this is the path to use.

---

## What This Covers

- How `MUSIC LOAD` and `MUSIC PLAY` actually flow through FasterBASIC
- Which ABC features are reliably supported by our parser/compiler path
- How to structure tracks for arcade gameplay (title loops, level beds, stingers)
- Practical patterns that avoid parser/runtime surprises

## What This Does *Not* Cover

- The full ABC 2.x spec
- Advanced engraving features intended for notation publishing
- DAW-style composition workflows

## See Also

- [Audio System Guide (Friendly Quickstart)](audio-system-guide.md) — choose SOUND vs MUSIC vs VS quickly.
- [SOUND Command: Fast Game SFX](sound-command.md) — predefined game effects and slot-based SFX workflow.
- [Introduction to VoiceScript](introduction_voicescript.md) — beginner-friendly real-time synth basics.
- [Advanced VoiceScript Guide](advanced_voicescript.md) — deeper modulation, routing, and recording workflows.
- [Workers: Safe Concurrency](workers.md) — safe background compute for game logic; keep audio control in the main loop.

---

## The Real Pipeline in This Project

For arcade games, the intended flow is:

1. Write ABC as a string literal.
2. `MUSIC LOAD slot, "..."`
3. `MUSIC PLAY slot[, volume]`

Under the hood:

- The compiler validates ABC literals during semantic checks.
- `MUSIC LOAD` with a compile-time literal is compiled into an internal FBMC blob.
- Runtime loads that blob with `mus_load_compiled`.
- `MUSIC PLAY slot` resolves slot -> musicId -> MidiEngine sequence playback.

### Important Runtime Behavior

`MUSIC PLAY "..."` (inline string playback) is currently not the practical path in the manager implementation. Use **slot-based** playback (`MUSIC LOAD` then `MUSIC PLAY slot`) for reliable behavior.

---

## Supported Header Fields (Practical Subset)

These are the fields you should treat as core:

- `X:` tune number (required by basic validation path)
- `T:` title
- `C:` composer
- `M:` meter (`4/4`, `3/4`, `C`, `C|`)
- `L:` default note length
- `Q:` tempo (supports `Q:120` and `Q:1/4=120` style)
- `K:` key signature (required by basic validation path)
- `V:` voice definitions/switches

Also supported:

- `%%MIDI program <0..127>`
- `%%MIDI channel <1..16>`
- `%%MIDI transpose <-127..127>`
- `%%MIDI velocity <0..127>` / `%%MIDI volume <0..127>`
- `%%MIDI drum on` / `%%MIDI percussion`

---

## Supported Body Features (Arcade-Relevant)

You can safely build game cues with:

- Notes with accidentals and octave marks
- Rests (`z`)
- Bar lines and repeat expansion
- Multi-voice writing (`V:1`, `V:2`, `V:3`)
- Chords in brackets (`[CEG]`)
- Guitar chord symbols (`"C"`, `"G7"`) as harmonic events
- Tuplet specifiers like `(3...`
- Ties (`-`)
- Broken rhythm markers (`>` and `<`)

The parser is intentionally forgiving in places (unknown directives are often ignored). For game work, prefer clean, minimal notation over clever notation tricks.

---

## Arcade Composition Strategy

Think in **game states**, not songs.

### 1) Title Loop (8–16 bars)

Goal: recognizable identity, low fatigue.

- Keep melody sparse.
- Use 2–3 voices max.
- Leave space with rests every bar.

### 2) Gameplay Bed (16–32 bars)

Goal: motion without distraction.

- Stable bass ostinato in one voice.
- Mid voice for rhythm pulse.
- Lead voice with short motifs, not full melody.

### 3) Stingers (1–2 bars)

Goal: immediate feedback.

- Victory: rising interval + bright program.
- Failure: descending minor motion + short decay.

Load these into separate slots so gameplay code can trigger them independently.

---

## Recommended Voice Layout for Games

Use a fixed channel/voice mental model:

- `V:1` Lead / hooks
- `V:2` Harmony / pads / arps
- `V:3` Bass / pulse
- (Optional) percussion voice with `%%MIDI drum on`

Example voice setup:

```abc
X:1
T:Level 1 Loop
M:4/4
L:1/8
Q:1/4=148
K:Cm
%%score V1 V2 V3
V:1 name="Lead" program=81
V:2 name="Chords" program=62
V:3 name="Bass" program=38
```

---

## FasterBASIC Usage Pattern (Recommended)

```basic
' Load once (startup or level load)
MUSIC LOAD 1, """X:1
T:Level Loop
M:4/4
L:1/8
Q:1/4=148
K:C
V:1 name=\"Lead\" program=81
V:2 name=\"Bass\" program=38
[V:1] c2 e2 g2 e2 | c2 e2 g2 e2 |
[V:2] C,2 z2 C,2 z2 | C,2 z2 C,2 z2 |
"""

' Play when entering state
MUSIC PLAY 1, 0.9

' Stop / swap on state change
MUSIC STOP
```

Tip: Keep music text literal and static where possible. That gives you compile-time validation and compiled-blob loading.

---

## Debug and Validation Tips

### Compiler-side checks

`MUSIC LOAD` with literal ABC is validated during compile/semantic pass. Invalid literals fail early.

### Trace compiled stream

Use:

- CLI flag: `--trace-abc`
- Env: `ED_TRACE_ABC=1`

This helps verify emitted tempo/program/note counts and channel mapping.

### Runtime sanity checks

- Verify slot exists before play (`MUSIC LOAD` succeeded).
- Keep game music volume in a sane range (typically 0.0–1.0).
- Prefer short loops while iterating, then extend.

---

## Practical Limitations to Design Around

1. Inline string playback (`MUSIC PLAY "..."`) is not the main runtime path right now.
   - Use slot-based load/play.

2. The strongest path is compile-time literals.
   - Dynamic/generated ABC strings are harder to validate and debug.

3. This parser path is optimized for **playback features**, not full score notation semantics.
   - If a notation trick is unclear, simplify it.

---

## Arcade-First Checklist

Before shipping a track:

- [ ] Uses `MUSIC LOAD slot, "..."` (literal)
- [ ] Has `X:` and `K:`
- [ ] Has explicit `Q:` and `L:`
- [ ] Voices separated by role (lead/harmony/bass)
- [ ] Loop length fits gameplay state
- [ ] No dense melodic material during high-action moments
- [ ] Verified with `--trace-abc` at least once

---

## Final Advice

Treat ABC in FasterBASIC like a **deterministic gameplay music script**.

Small, clear, repeatable structures beat complex notation. For arcade games, consistency and timing clarity matter more than musical sophistication.
