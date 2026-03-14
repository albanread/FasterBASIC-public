//
// fb_audio_shim.h
// FasterBASIC Audio C Shim
//
// Pure C linkage API that Zig and the BASIC runtime call into.
// Implemented by fb_audio_shim.mm which forwards to FBAudioManager.
//
// Phase 1: SOUND — procedural sound generation and playback
// Phase 2: MUSIC — ABC notation music via MIDI engine
// Phase 3: VS    — 8-voice real-time synthesiser (SID-style)
//
// All functions are safe to call from any thread.
// The audio system initialises lazily on first use.
//
// MIT License — Copyright (c) 2025
//

#ifndef FB_AUDIO_SHIM_H
#define FB_AUDIO_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants — Waveforms
// ═══════════════════════════════════════════════════════════════════════════════

#define FB_WAVE_SINE      0
#define FB_WAVE_SQUARE    1
#define FB_WAVE_SAWTOOTH  2
#define FB_WAVE_TRIANGLE  3
#define FB_WAVE_NOISE     4
#define FB_WAVE_PULSE     5

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants — Noise Types
// ═══════════════════════════════════════════════════════════════════════════════

#define FB_NOISE_WHITE  0
#define FB_NOISE_PINK   1
#define FB_NOISE_BROWN  2

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants — Filter Types
// ═══════════════════════════════════════════════════════════════════════════════

#define FB_FILTER_NONE      0
#define FB_FILTER_LOWPASS   1
#define FB_FILTER_HIGHPASS  2
#define FB_FILTER_BANDPASS  3

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants — Physical Model Types
// ═══════════════════════════════════════════════════════════════════════════════

#define FB_PHYS_PLUCKED  0
#define FB_PHYS_STRUCK   1
#define FB_PHYS_BLOWN    2
#define FB_PHYS_DRUM     3
#define FB_PHYS_GLASS    4

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants — LFO Waveforms (for VS LFO commands)
// ═══════════════════════════════════════════════════════════════════════════════

#define FB_LFO_SINE          0
#define FB_LFO_TRIANGLE      1
#define FB_LFO_SQUARE        2
#define FB_LFO_SAWTOOTH      3
#define FB_LFO_SAMPLE_HOLD   4

// ═══════════════════════════════════════════════════════════════════════════════
//  Lifecycle
//
//  fb_audio_init() is called automatically on first use if needed.
//  Explicit init/shutdown are provided for deterministic control.
// ═══════════════════════════════════════════════════════════════════════════════

/// Initialise the audio subsystem. Safe to call multiple times.
/// Returns true on success.
bool fb_audio_init(void);

/// Shut down the audio subsystem and release all resources.
void fb_audio_shutdown(void);

/// Check whether the audio subsystem is initialised.
bool fb_audio_is_initialized(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Predefined Game Sound Effects
//
//  Each function creates a procedurally generated sound in the sound bank
//  and returns a sound ID (uint32_t).  ID 0 means error.
//
//  The BASIC slot mapping (1–256) is handled by the BASIC runtime layer
//  above this shim.  This shim deals only in raw sound IDs.
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_sound_create_beep(float frequency, float duration);
uint32_t fb_sound_create_zap(float frequency, float duration);
uint32_t fb_sound_create_explode(float size, float duration);
uint32_t fb_sound_create_big_explosion(float size, float duration);
uint32_t fb_sound_create_small_explosion(float intensity, float duration);
uint32_t fb_sound_create_distant_explosion(float distance, float duration);
uint32_t fb_sound_create_metal_explosion(float shrapnel, float duration);
uint32_t fb_sound_create_bang(float intensity, float duration);
uint32_t fb_sound_create_coin(float pitch, float duration);
uint32_t fb_sound_create_jump(float power, float duration);
uint32_t fb_sound_create_powerup(float intensity, float duration);
uint32_t fb_sound_create_hurt(float severity, float duration);
uint32_t fb_sound_create_shoot(float power, float duration);
uint32_t fb_sound_create_click(float sharpness, float duration);
uint32_t fb_sound_create_blip(float pitch, float duration);
uint32_t fb_sound_create_pickup(float brightness, float duration);
uint32_t fb_sound_create_sweep_up(float start_freq, float end_freq, float duration);
uint32_t fb_sound_create_sweep_down(float start_freq, float end_freq, float duration);
uint32_t fb_sound_create_random_beep(uint32_t seed, float duration);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Custom Synthesis
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a tone with the given waveform, frequency, and duration.
/// waveform: one of FB_WAVE_* constants.
uint32_t fb_sound_create_tone(float frequency, float duration, int waveform);

/// Create a musical note with MIDI note number and ADSR envelope.
/// waveform: one of FB_WAVE_* constants.
/// attack/decay/sustain/release: envelope parameters (seconds / level).
uint32_t fb_sound_create_note(int midi_note, float duration, int waveform,
                              float attack, float decay,
                              float sustain, float release);

/// Create a noise sound.
/// noise_type: one of FB_NOISE_* constants.
uint32_t fb_sound_create_noise(int noise_type, float duration);

/// Create an FM synthesis sound.
/// carrier_freq: carrier frequency in Hz.
/// mod_freq:     modulator frequency in Hz.
/// mod_index:    modulation depth.
uint32_t fb_sound_create_fm(float carrier_freq, float mod_freq,
                            float mod_index, float duration);

/// Create a filtered tone.
/// filter_type: one of FB_FILTER_* constants.
/// cutoff:      filter cutoff frequency in Hz.
/// resonance:   filter resonance (Q).
uint32_t fb_sound_create_filtered_tone(float frequency, float duration,
                                       int waveform, int filter_type,
                                       float cutoff, float resonance);

/// Create a filtered note with ADSR envelope.
uint32_t fb_sound_create_filtered_note(int midi_note, float duration,
                                       int waveform,
                                       float attack, float decay,
                                       float sustain, float release,
                                       int filter_type,
                                       float cutoff, float resonance);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Effects Processing (baked into the generated buffer)
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a tone with reverb baked in.
uint32_t fb_sound_create_with_reverb(float frequency, float duration,
                                     int waveform,
                                     float room_size, float damping, float wet);

/// Create a tone with delay/echo baked in.
uint32_t fb_sound_create_with_delay(float frequency, float duration,
                                    int waveform,
                                    float delay_time, float feedback, float mix);

/// Create a tone with distortion baked in.
uint32_t fb_sound_create_with_distortion(float frequency, float duration,
                                         int waveform,
                                         float drive, float tone, float level);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Playback
// ═══════════════════════════════════════════════════════════════════════════════

/// Play a sound by its bank ID.
/// volume: 0.0 (silent) to 1.0 (full).
/// pan:    -1.0 (left) to 1.0 (right), 0.0 = centre.
void fb_sound_play(uint32_t sound_id, float volume, float pan);

/// Convenience: play at full volume, centred.
void fb_sound_play_simple(uint32_t sound_id);

/// Stop all currently playing sounds.
void fb_sound_stop(void);

/// Stop one specific sound slot (logical stop, does not cancel mid-buffer hardware playback).
void fb_sound_stop_one(uint32_t sound_id);

/// Check whether a sound slot is currently playing.
/// Uses a time-based estimate from the most recent fb_sound_play() call.
bool fb_sound_is_playing(uint32_t sound_id);

/// Return the PCM buffer duration of a slot in seconds (0.0 if unknown).
float fb_sound_get_duration(uint32_t sound_id);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

/// Free a single sound by its bank ID.
/// Returns true if the sound existed and was freed.
bool fb_sound_free(uint32_t sound_id);

/// Free all sounds in the bank.
void fb_sound_free_all(void);

/// Export a stored sound slot to WAV.
bool fb_sound_export_wav(uint32_t sound_id, const char* filename, float volume);

/// Import a temporary SynthEngine memory-buffer ID into SoundBank.
/// Returns a playable sound_id (0 on failure).
uint32_t fb_sound_import_synth_memory(uint32_t synth_memory_id);

/// Discard a temporary SynthEngine memory-buffer ID without importing.
bool fb_sound_discard_synth_memory(uint32_t synth_memory_id);

/// Set the master sound volume (0.0–1.0).
void fb_sound_set_volume(float volume);

/// Get the current master sound volume.
float fb_sound_get_volume(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Queries
// ═══════════════════════════════════════════════════════════════════════════════

/// Check whether a sound exists in the bank.
bool fb_sound_exists(uint32_t sound_id);

/// Get the number of sounds currently in the bank.
size_t fb_sound_get_count(void);

/// Get the approximate memory usage of all stored sounds (bytes).
size_t fb_sound_get_memory_usage(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  Utility
// ═══════════════════════════════════════════════════════════════════════════════

/// Convert a MIDI note number to frequency in Hz.
/// Example: midi note 69 → 440.0 Hz (A4).
float fb_note_to_freq(int midi_note);

/// Convert a frequency in Hz to the nearest MIDI note number.
/// Example: 440.0 Hz → 69 (A4).
int fb_freq_to_note(float frequency);

/// Stop all audio output (sounds, music, and in future: voices).
void fb_audio_stop_all(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Inline Playback (ABC notation)
//
//  Play ABC notation strings directly through the MIDI engine.
//  Uses Apple's built-in DLS synthesiser for instrument sounds.
// ═══════════════════════════════════════════════════════════════════════════════

/// Play ABC notation string directly.
/// @param abc_notation  ABC notation text (e.g. "X:1\nT:Scale\nM:4/4\nK:C\nCDEF|GABc|")
/// @param volume        0.0 (silent) to 1.0 (full)
void fb_music_play(const char* abc_notation, float volume);

/// Convenience: play ABC notation at full volume.
void fb_music_play_simple(const char* abc_notation);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank (Load and Play by Slot)
//
//  Load ABC notation into the music bank for later playback.
//  Returns a music ID (uint32_t).  ID 0 means error.
//  The BASIC slot mapping (1–64) is handled by the BASIC runtime layer
//  above this shim.  This shim deals only in raw music IDs.
// ═══════════════════════════════════════════════════════════════════════════════

/// Load ABC notation from a string into the music bank.
/// @param abc_notation  ABC notation text
/// @return Unique music ID (0 = error)
uint32_t fb_music_load_string(const char* abc_notation);

/// Load compiler-precompiled music blob data into the music bank.
/// @param blob_data  Pointer to precompiled blob bytes
/// @param blob_size  Blob size in bytes
/// @return Unique music ID (0 = error)
uint32_t fb_music_load_compiled_blob(const void* blob_data, size_t blob_size);

/// Play a music piece from the bank by its ID.
/// @param music_id  ID returned from fb_music_load_string
/// @param volume    0.0 (silent) to 1.0 (full)
void fb_music_play_id(uint32_t music_id, float volume);

/// Convenience: play music by ID at full volume.
void fb_music_play_id_simple(uint32_t music_id);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Playback Control
// ═══════════════════════════════════════════════════════════════════════════════

/// Stop music playback.
void fb_music_stop(void);

/// Pause music playback.
void fb_music_pause(void);

/// Resume music playback from pause.
void fb_music_resume(void);

/// Set the music volume (0.0–1.0).
void fb_music_set_volume(float volume);

/// Get the current music volume.
float fb_music_get_volume(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

/// Free a single music piece by its bank ID.
/// Returns true if the music existed and was freed.
bool fb_music_free(uint32_t music_id);

/// Free all music in the bank.
void fb_music_free_all(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Queries
// ═══════════════════════════════════════════════════════════════════════════════

/// Check whether music is currently playing.
bool fb_music_is_playing(void);
bool fb_music_is_playing_id(uint32_t music_id);

/// Get the music playback state: 0=Stopped, 1=Playing, 2=Paused.
int fb_music_get_state(void);

/// Check whether a music piece exists in the bank.
bool fb_music_exists(uint32_t music_id);

/// Get the number of music pieces currently in the bank.
size_t fb_music_get_count(void);

/// Get the approximate memory usage of all stored music (bytes).
size_t fb_music_get_memory_usage(void);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Metadata
//
//  Return pointers to internal string buffers.  The returned pointer is
//  valid until the next call to the same metadata function.
// ═══════════════════════════════════════════════════════════════════════════════

/// Get the title of a music piece (from ABC T: header).
const char* fb_music_get_title(uint32_t music_id);

/// Get the composer of a music piece (from ABC C: header).
const char* fb_music_get_composer(uint32_t music_id);

/// Get the key signature of a music piece (from ABC K: header).
const char* fb_music_get_key(uint32_t music_id);

/// Get the tempo (BPM) of a music piece (from ABC Q: header).
float fb_music_get_tempo(uint32_t music_id);

/// Get compiled-blob introspection info for a music piece.
/// Returns a semicolon-separated summary string for compiled entries.
const char* fb_music_get_compiled_blob_info(uint32_t music_id);

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Rendering (offline ABC → sound bank)
//
//  Render ABC notation to a PCM sound buffer, registered in the SoundBank.
//  The returned ID is a *sound* ID usable with fb_sound_play().
// ═══════════════════════════════════════════════════════════════════════════════

/// Render ABC notation to a sound bank slot.
/// @param abc_notation  ABC notation text
/// @param duration      Maximum render duration in seconds (0 = auto from tune)
/// @param sample_rate   Sample rate in Hz (0 = default 44100)
/// @return Sound ID (for use with fb_sound_play), or 0 on error.
uint32_t fb_music_render(const char* abc_notation, float duration, float sample_rate);

/// Convenience: render with default duration and sample rate.
uint32_t fb_music_render_simple(const char* abc_notation);

/// Render ABC notation directly to WAV output (if available).
bool fb_music_render_wav(const char* abc_notation, const char* filename,
                         float duration, float sample_rate);

/// Export compiled music slot/id to Standard MIDI file.
bool fb_music_export_midi(uint32_t music_id, const char* filename);

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Voice Synthesiser (8-Voice Real-Time Control)
//
//  An 8-voice polyphonic synthesiser inspired by the SID chip with modern
//  capabilities: stereo pan, per-voice delay, 4 routable LFOs, physical
//  modeling, and offline recording/rendering.
//
//  Voices are numbered 1–8.  LFOs are numbered 1–4.
//  All parameters take effect immediately on the real-time audio thread.
// ═══════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Oscillator
// ─────────────────────────────────────────────────────────────────────────────

/// Set voice waveform.
/// @param voice  Voice number (1–8)
/// @param waveform  One of FB_WAVE_* constants (0=Sine … 5=Pulse),
///                  or 7 for physical modeling mode.
void fb_vs_waveform(int voice, int waveform);

/// Set voice frequency in Hz.
void fb_vs_frequency(int voice, float hz);

/// Set voice note by MIDI note number (0–127, middle C = 60).
void fb_vs_note(int voice, int midi_note);

/// Set voice note by name (e.g. "C-4", "A#3", "Gb5").
void fb_vs_notename(int voice, const char* name);

/// Set pulse width (for pulse waveform, 0.0–1.0, 0.5 = square).
void fb_vs_pulse(int voice, float width);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Envelope (ADSR)
// ─────────────────────────────────────────────────────────────────────────────

/// Set ADSR envelope for a voice.
/// @param attack_ms   Attack time in milliseconds
/// @param decay_ms    Decay time in milliseconds
/// @param sustain     Sustain level 0.0–1.0
/// @param release_ms  Release time in milliseconds
void fb_vs_envelope(int voice, float attack_ms, float decay_ms,
                    float sustain, float release_ms);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Gate Control
// ─────────────────────────────────────────────────────────────────────────────

/// Set voice gate.  gate_on=true triggers attack; false triggers release.
void fb_vs_gate(int voice, bool gate_on);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Volume & Pan
// ─────────────────────────────────────────────────────────────────────────────

/// Set per-voice volume (0.0–1.0).
void fb_vs_volume(int voice, float level);

/// Set per-voice stereo pan (-1.0 left … 0.0 centre … 1.0 right).
void fb_vs_pan(int voice, float position);

/// Set master voice volume (0.0–1.0).
void fb_vs_master(float level);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Filter (Global)
// ─────────────────────────────────────────────────────────────────────────────

/// Set global filter type (one of FB_FILTER_* constants).
void fb_vs_filter_type(int filter_type);

/// Set global filter cutoff frequency in Hz.
void fb_vs_filter_cutoff(float hz);

/// Set global filter resonance (1.0 = none, higher = more).
void fb_vs_filter_resonance(float q);

/// Enable or disable the global filter.
void fb_vs_filter_enabled(bool on);

/// Route a voice through (true) or bypass (false) the global filter.
void fb_vs_filter_route(int voice, bool on);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Modulation (SID-Style)
// ─────────────────────────────────────────────────────────────────────────────

/// Set ring modulation source voice (0 = off).
void fb_vs_ring(int voice, int source_voice);

/// Set hard sync source voice (0 = off).
void fb_vs_sync(int voice, int source_voice);

/// Set portamento (pitch glide) time in seconds (0 = instant).
void fb_vs_portamento(int voice, float seconds);

/// Set detuning in cents (±100 cents = 1 semitone).
void fb_vs_detune(int voice, float cents);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Per-Voice Delay
// ─────────────────────────────────────────────────────────────────────────────

/// Enable or disable the delay effect for a voice.
void fb_vs_delay_enabled(int voice, bool on);

/// Set delay time in seconds (0.0–2.0).
void fb_vs_delay_time(int voice, float seconds);

/// Set delay feedback amount (0.0–0.95).
void fb_vs_delay_feedback(int voice, float amount);

/// Set delay wet/dry mix (0.0 = dry, 1.0 = wet).
void fb_vs_delay_mix(int voice, float mix);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — LFO (4 Global Low-Frequency Oscillators)
// ─────────────────────────────────────────────────────────────────────────────

/// Set LFO waveform (one of FB_LFO_* constants).
/// @param lfo  LFO number (1–4)
void fb_vs_lfo_waveform(int lfo, int waveform);

/// Set LFO rate in Hz.
void fb_vs_lfo_rate(int lfo, float hz);

/// Reset LFO phase to 0.
void fb_vs_lfo_reset(int lfo);

/// Route LFO to voice pitch (vibrato).
/// @param depth_cents  Modulation depth in cents
void fb_vs_lfo_pitch(int voice, int lfo, float depth_cents);

/// Route LFO to voice volume (tremolo).
/// @param depth  Modulation depth 0.0–1.0
void fb_vs_lfo_volume(int voice, int lfo, float depth);

/// Route LFO to filter cutoff (auto-wah).
/// @param depth_hz  Modulation depth in Hz
void fb_vs_lfo_filter(int voice, int lfo, float depth_hz);

/// Route LFO to pulse width (auto-PWM).
/// @param depth  Modulation depth 0.0–1.0
void fb_vs_lfo_pulse(int voice, int lfo, float depth);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Physical Modeling
// ─────────────────────────────────────────────────────────────────────────────

/// Set physical model type (one of FB_PHYS_* constants).
void fb_vs_physical_model(int voice, int model_type);

/// Set physical model damping (0.0–1.0).
void fb_vs_physical_damping(int voice, float val);

/// Set physical model brightness (0.0–1.0).
void fb_vs_physical_brightness(int voice, float val);

/// Set physical model excitation strength (0.0–1.0).
void fb_vs_physical_excitation(int voice, float val);

/// Set physical model body resonance (0.0–1.0).
void fb_vs_physical_resonance(int voice, float val);

/// Set physical model string tension (0.0–1.0, for string models).
void fb_vs_physical_tension(int voice, float val);

/// Set physical model air pressure (0.0–1.0, for wind models).
void fb_vs_physical_pressure(int voice, float val);

/// Trigger physical model excitation.
void fb_vs_physical_trigger(int voice);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Global Control
// ─────────────────────────────────────────────────────────────────────────────

/// Reset all voices (gates off, clear state).
void fb_vs_reset(void);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Queries
// ─────────────────────────────────────────────────────────────────────────────

/// Get the number of voices with gate ON.
int fb_vs_active_count(void);

/// Get the current master voice volume.
float fb_vs_get_master(void);

/// Check whether any voice is currently active.
bool fb_vs_is_playing(void);

// ─────────────────────────────────────────────────────────────────────────────
//  VS — Recording & Rendering (Timeline System)
//
//  The recording system captures VS commands with beat timestamps.
//  On save/play, it replays the timeline offline through VoiceController
//  and produces a PCM buffer in the SoundBank.
// ─────────────────────────────────────────────────────────────────────────────

/// Start recording — subsequent VS commands are captured with beat positions.
void fb_vs_record_start(void);

/// Set recording tempo in BPM (default 120).
void fb_vs_record_tempo(float bpm);

/// Advance the recording beat cursor by N beats.
void fb_vs_record_wait(float beats);

/// End recording and render to a SoundBank slot.
/// @param volume  Render volume 0.0–1.0
/// @return Sound ID (for use with fb_sound_play), or 0 on error.
uint32_t fb_vs_record_save(float volume);

/// End recording, render, and play immediately.
/// @param volume  Playback volume 0.0–1.0
void fb_vs_record_play(float volume);

/// End recording and render to a WAV file.
/// @param filename  Output WAV file path
void fb_vs_record_wav(const char* filename);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // FB_AUDIO_SHIM_H