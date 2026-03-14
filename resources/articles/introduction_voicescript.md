# Introduction to VoiceScript (VS) in FasterBASIC

VoiceScript (`VS`) is the **live synthesizer** in FasterBASIC.

If `SOUND` is for pre-made one-shot effects, `VS` is for sounds you **shape in real time**: notes, envelopes, modulation, and expressive motion while the game is running.

This guide is for BASIC programmers who want a practical on-ramp.

---

## When to Use VS vs SOUND vs MUSIC

Need a quick chooser first? See [Audio System Guide (Friendly Quickstart)](audio-system-guide.md).

Use `VS` when you need:

- continuous tones (engine hum, alarm, drone)
- parameter changes over time (filter sweeps, vibrato, detune)
- playable synth voices (live note/gate control)

Use `SOUND` when you need:

- quick one-shot effects in slots (`coin`, `shoot`, `hurt`)

Use `MUSIC` when you need:

- structured score playback via ABC/slots

---

## Core Mental Model

A VS voice is a persistent synth channel.

### The Most Important Concept (easy to miss)

`VS` commands do **not** directly output audio sample-by-sample from your BASIC line.

Instead, your BASIC code rapidly sends **control instructions** (set note, set filter, gate on/off). The audio system then reads that state later on the audio callback and renders the actual sound in real time.

Think of it like this:

- BASIC thread = writes synth settings/events
- Audio thread = reads current synth state and produces samples continuously

In normal use, this means you usually **do not need to create BASIC threads** just to make VS feel instant.

So yes: you are programming the instrument state now, and hearing the result as the audio engine renders it moments later.

Typical flow:

1. Pick a voice (1..8)
2. Set waveform + pitch + envelope + volume
3. Open gate (`VS GATE voice, ON`) to sound
4. Close gate (`VS GATE voice, OFF`) to release

Minimal pattern:

```basic
VS RESET
VS WAVEFORM 1, waveformType
VS NOTE 1, 60
VS ENVELOPE 1, 10, 80, 0.7, 150
VS VOLUME 1, 0.6
VS GATE 1, ON
SLEEP 0.5
VS GATE 1, OFF
```

In gameplay code this feels immediate, but architecturally it is control-rate commands driving audio-rate rendering.

---

## The 8 Commands to Learn First

Start with only these:

- `VS RESET`
- `VS WAVEFORM voice, waveformType`
- `VS NOTE voice, midiNote` (or `VS FREQUENCY`)
- `VS ENVELOPE voice, attack, decay, sustain, release`
- `VS VOLUME voice, level`
- `VS PAN voice, position`
- `VS GATE voice, ON/OFF`
- `VS MASTER level`

That is enough to build most beginner game sounds.

---

## A Beginner Patch Recipe

### Laser shot

```basic
VS WAVEFORM 1, waveformType
VS NOTE 1, 84
VS ENVELOPE 1, 1, 30, 0.0, 40
VS VOLUME 1, 0.5
VS GATE 1, ON
SLEEP 0.05
VS GATE 1, OFF
```

### Pickup chime

```basic
VS WAVEFORM 2, waveformType
VS NOTE 2, 72
VS ENVELOPE 2, 5, 80, 0.2, 120
VS VOLUME 2, 0.5
VS GATE 2, ON
SLEEP 0.12
VS NOTE 2, 79
SLEEP 0.12
VS GATE 2, OFF
```

### Warning tone

```basic
VS WAVEFORM 3, waveformType
VS NOTE 3, 48
VS ENVELOPE 3, 5, 30, 0.8, 50
VS VOLUME 3, 0.4
VS GATE 3, ON
SLEEP 0.15
VS GATE 3, OFF
```

---

## Game-Friendly Voice Allocation

Keep voices assigned by role:

- voice 1: player action sounds
- voice 2: pickup/UI tones
- voice 3: warnings/alarms
- voice 4: ambient drone
- voices 5–8: spare/special events

This keeps your update logic simple and avoids accidental voice conflicts.

---

## Common Beginner Mistakes

1. Forgetting to open gate
   - You set note/frequency, but no sound until `VS GATE ..., ON`.

2. Forgetting to close gate
   - Voice stays active and stacks unexpectedly.

3. Using too many voices at full volume
   - Start lower (`0.3`–`0.7`) and set `VS MASTER` conservatively.

4. Ignoring envelope
   - Raw gate on/off clicks are harsh; always set ADSR.

5. Assuming you need extra threading for responsiveness
   - Usually false. Send `VS` control-rate events from your main update loop; the audio callback already runs independently.
   - Use `WORKER` threads for heavy non-audio jobs (pathfinding, generation, simulation), not for making VS itself "more real-time". See: [Workers: Safe Concurrency in FasterBASIC](workers.md).

---

## A Safe Starter Template

```basic
' Run once
VS RESET
VS MASTER 0.8

' Before each sound event
' - choose dedicated voice
' - configure only what changed
' - gate on/off quickly
```

If you follow this, VS becomes predictable and easy to control.

---

## Where to Go Next

Once comfortable, learn:

- `VS PORTAMENTO` + `VS DETUNE` (pitch motion/thickness)
- `VS FILTER ...` + `VS FILTER ROUTE` (tone shaping)
- `VS LFO ...` (movement over time)
- `VS RECORD ...` (capture command performance)
- `WORKER`/`SPAWN`/`AWAIT` for safe background CPU work: [Workers: Safe Concurrency in FasterBASIC](workers.md)

Continue with: [Advanced VoiceScript Guide](advanced_voicescript.md)

Also useful: [Audio System Guide (Friendly Quickstart)](audio-system-guide.md)
