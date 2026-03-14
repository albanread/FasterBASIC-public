# Audio System Guide (Friendly Quickstart)

If you are not an audio expert, start here.

This guide helps you choose the right audio path in FasterBASIC quickly.

---

## The 3 Audio Tools (Simple Rule)

- Use `SOUND` for **instant game SFX** (coin, jump, shoot, hurt, explode).
- Use `MUSIC` for **structured song/loop playback** from ABC.
- Use `VS` for **live synth control** (notes, envelopes, filters, modulation in real time).

---

## Which One Should I Use?

### I need quick arcade effects

Use `SOUND`.

- Create once into slots
- Trigger many times during gameplay
- Easiest path for most games

Read: [SOUND Command: Fast Game SFX](sound-command.md)

### I need background music loops

Use `MUSIC`.

- Load ABC into a slot
- Play by slot during game states
- Best for title/theme/level loops

Read: [ABC Player for Arcade Games](ABCplayer.md)

### I need expressive synth behavior

Use `VS`.

- Persistent voices
- Real-time control-rate events
- Great for drones, alarms, modulation, dynamic effects

Read: [Introduction to VoiceScript](introduction_voicescript.md)

Then: [Advanced VoiceScript Guide](advanced_voicescript.md)

---

## Important Threading Note (Saves Confusion)

For VS, you usually **do not** need extra BASIC threads for responsiveness.

- send `VS` control-rate events from your main update loop
- audio is rendered continuously by the audio callback

Use `WORKER` threads for heavy non-audio computation, then feed results back into your normal gameplay logic.

Read: [Workers: Safe Concurrency](workers.md)

---

## What This Means in BASIC (Right Now)

Recent engine work improved internal audio plumbing for physical-model sound generation and VS render/bounce stability.

For BASIC programmers, the practical meaning is:

- your existing `SOUND`, `MUSIC`, and `VS` scripts keep working as before
- reliability of advanced audio workflows is better (especially render/bounce paths)
- there is currently **no new BASIC keyword syntax** you must learn for this internal bridge

So at the BASIC level, keep using the same command families while the engine side gets stronger underneath.

---

## Recommended Learning Path

1. [SOUND Command: Fast Game SFX](sound-command.md)
2. [ABC Player for Arcade Games](ABCplayer.md)
3. [Introduction to VoiceScript](introduction_voicescript.md)
4. [Advanced VoiceScript Guide](advanced_voicescript.md)
5. [Workers: Safe Concurrency](workers.md)

---

## Quick “Game Feel” Checklist

- Keep SFX short and clear
- Keep music loops simple and repeatable
- Use VS for dynamic moments, not every sound
- Keep master levels conservative to avoid clipping
- Prefer consistency over complexity
