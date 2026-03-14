# Advanced VoiceScript (VS) Guide

This is the deeper guide for programmers who already use basic `VS` note/gate workflows.

Focus:

- architectural understanding
- robust real-time usage patterns
- modulation/filter/routing strategies for game audio
- practical recording pipeline usage

For first-time users, start with [Introduction to VoiceScript](introduction_voicescript.md).

---

## 1) How VS Is Exposed to BASIC

Your BASIC commands map to a layered runtime path:

- BASIC statements (`VS ...`)
- runtime exports (`vs_*` in `audio_runtime.zig`)
- C shim forwards (`fb_vs_*` in `fb_audio_shim.mm`)
- manager forwarding (`FBAudioManager::vsSet*`)
- DSP core (`VoiceController`)

This matters because VS is **stateful**. Commands mutate persistent voice state, and audio callback continuously renders current state.

### Control-rate vs audio-rate (critical mental model)

VS runs in two time domains:

- **Control-rate (BASIC/game thread):** your `VS` commands update parameters and trigger events.
- **Audio-rate (audio callback):** the engine continuously renders PCM from the latest voice state.

So `VS NOTE`, `VS FILTER`, `VS LFO`, and `VS GATE` are instruction updates, not direct sample-generation calls. You hear the result as soon as the callback consumes that updated state.

Practical implications:

- Prefer small, regular control updates for smooth sweeps.
- Use ADSR/LFO inside the voice for fast motion instead of flooding BASIC commands.
- Retrigger intentionally: repeated note/gate events can restart envelope behavior.
- Treat BASIC-side changes as musical gestures driving a real-time synth engine.
- For most projects, avoid extra BASIC threading for VS control; your main update loop is enough.
- Use workers for expensive non-audio computation, then feed results back as `VS` control-rate events in the main update loop. See: [Workers: Safe Concurrency in FasterBASIC](workers.md).

---

## 2) Voice Architecture (Practical View)

Each voice includes:

- oscillator config (waveform/pulse/phase)
- pitch path (note/frequency, detune, portamento)
- gate + ADSR envelope state machine
- volume and pan
- optional delay send/feedback/mix
- optional global-filter routing flag
- LFO routing targets (pitch, volume, filter, pulse)
- optional physical model state

Think of each voice as a tiny synth strip.

---

## 3) Reliable Real-Time Control Patterns

### Pattern A: Event voice + release discipline

For transient events:

- dedicated voice per event family
- set patch once
- only update note/frequency at trigger time
- always issue gate off

### Pattern B: Continuous ambient voices

For hum/drones:

- gate on once
- modulate filter/LFO/depth over time
- avoid retriggering envelope unless needed

### Pattern C: Voice reservation

Reserve voice ranges by system to avoid collisions:

- gameplay SFX voices
- UI voices
- ambience voices

---

## 4) Modulation Design Patterns

### Vibrato (subtle pitch movement)

```basic
VS LFO WAVEFORM 1, lfoWave
VS LFO RATE 1, 5.0
VS LFO PITCH 1, 1, 10.0   ' depth in cents
```

Keep depth conservative for game readability.

### Tremolo (volume movement)

```basic
VS LFO WAVEFORM 2, lfoWave
VS LFO RATE 2, 6.0
VS LFO VOLUME 2, 2, 0.25
```

Useful for warning sirens and charging effects.

### Pulse-width motion

```basic
VS LFO PULSE 3, 1, 0.2
```

Great for retro textures when using pulse-like timbres.

---

## 5) Filter and Routing Strategy

Global filter is controlled by:

- `VS FILTER TYPE`
- `VS FILTER CUTOFF`
- `VS FILTER RESONANCE`
- `VS FILTER ON/OFF`

Per-voice opt-in with:

- `VS FILTER ROUTE voice, ON/OFF`

Practical trick:

- route only selected voices to filter
- leave impact/noise voices unfiltered for clarity

---

## 6) Pitch Layering Tricks

### Portamento lead

```basic
VS PORTAMENTO 1, 0.12
VS NOTE 1, 60
VS GATE 1, ON
VS NOTE 1, 67
```

### Detune thickness

Use two voices with same note, slight detune:

```basic
VS NOTE 1, 60
VS NOTE 2, 60
VS DETUNE 1, -5
VS DETUNE 2, 5
```

Pan lightly for width.

---

## 7) Physical Modeling Usage

`VS PHYSICAL ...` controls an alternate synthesis mode per voice.

Good uses in games:

- struck/impact timbres
- brittle break sounds
- resonant percussive accents

Workflow:

1. choose model (`VS PHYSICAL voice, model`)
2. set damping/brightness/excitation/etc
3. trigger (`VS PHYSICAL TRIGGER voice`)

Use sparingly at first; these sounds are expressive but easier to overdrive in dense mixes.

---

## 8) Recording Workflow (`VS RECORD`)

VS recording captures **commands + beat positions**, not raw live buffers.

Core commands:

- `VS RECORD START`
- `VS RECORD TEMPO bpm`
- `VS RECORD WAIT beats`
- perform `VS ...` commands
- `VS RECORD SAVE slot, volume` (bounce to SoundBank slot)
- `VS RECORD PLAY`
- `VS RECORD WAV "file.wav"`

Practical use:

- prototype live VS gestures
- bake them into reusable one-shot `SOUND PLAY` assets
- keep real-time VS voices free for dynamic gameplay needs

---

## 9) Performance and Mix Guidance

- Keep active voice count intentional; avoid full-volume stacks
- Use envelopes to reduce sustained clutter
- Prefer short release for action-heavy states
- Use `VS MASTER` for global headroom
- Reserve louder settings for sparse moments

---

## 10) Debugging Checklist

If no sound:

1. `VS RESET` and rebuild one minimal voice
2. confirm voice index in valid range
3. set waveform + note/frequency + volume
4. gate ON
5. if still silent, remove filter/LFO/delay/physical settings and reintroduce one by one

If sound is messy:

- reduce detune/LFO depth
- lower resonance and delay feedback
- shorten release

---

## 11) Suggested Project Structure

### `vs_init.bas`

- setup master/filter defaults
- define shared patch constants

### `vs_events.bas`

- helper subs for shoot/hit/pickup/warn

### `vs_ambient.bas`

- long-running drones and modulated beds

### `vs_record_tools.bas`

- optional dev-only routines for `VS RECORD` workflows

This keeps advanced VS manageable in larger BASIC projects.

---

## Related Docs

- [Audio System Guide (Friendly Quickstart)](audio-system-guide.md)
- [Introduction to VoiceScript](introduction_voicescript.md)
- [SOUND Command guide](sound-command.md)
- [ABC Player guide](ABCplayer.md)
- [Voice Script system design](../design/VOICE_SCRIPT_SYSTEM.md)
