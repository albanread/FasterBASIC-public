//
// fb_audio_shim.mm
// FasterBASIC Audio C Shim — Implementation
//
// Pure C linkage functions that delegate to a lazily-initialised
// FBAudioManager singleton. This is the boundary between the
// Zig/BASIC runtime and the C++/Obj-C++ audio subsystem.
//
// All functions auto-initialise the audio system on first call.
// All functions are thread-safe (FBAudioManager is internally locked).
//
// MIT License — Copyright (c) 2025
//

#include "fb_audio_shim.h"
#include "FBAudioManager.h"

#include <mutex>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ═══════════════════════════════════════════════════════════════════════════════
//  Singleton Access
// ═══════════════════════════════════════════════════════════════════════════════

static FBAudioManager* s_manager = nullptr;
static std::once_flag  s_onceFlag;

/// Return the singleton FBAudioManager, creating it on first call.
/// Does NOT call initialize() — that is done by ensureInit().
static FBAudioManager& getManager() {
    std::call_once(s_onceFlag, [] {
        s_manager = new FBAudioManager();
    });
    return *s_manager;
}

/// Ensure the audio subsystem is initialised.
/// Called at the top of every public function that needs audio hardware.
/// Returns true if the system is ready.
static bool ensureInit() {
    FBAudioManager& mgr = getManager();
    if (mgr.isInitialized()) {
        return true;
    }
    return mgr.initialize();
}

static bool fbAudioDebugEnabled() {
    const char* v = std::getenv("FB_AUDIO_DEBUG");
    if (!v || !*v) return false;
    return std::strcmp(v, "0") != 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

extern "C" {

bool fb_audio_init(void) {
    return ensureInit();
}

void fb_audio_shutdown(void) {
    FBAudioManager& mgr = getManager();
    mgr.shutdown();
}

bool fb_audio_is_initialized(void) {
    FBAudioManager& mgr = getManager();
    return mgr.isInitialized();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Predefined Game Sound Effects
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_sound_create_beep(float frequency, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateBeep(frequency, duration);
}

uint32_t fb_sound_create_zap(float frequency, float duration) {
    if (!ensureInit()) return 0;
    uint32_t id = getManager().soundCreateZap(frequency, duration);
    if (fbAudioDebugEnabled()) {
        std::fprintf(stderr, "[FB_AUDIO_DEBUG] create zap freq=%.3f dur=%.3f -> id=%u\n", frequency, duration, id);
    }
    return id;
}

uint32_t fb_sound_create_explode(float size, float duration) {
    if (!ensureInit()) return 0;
    uint32_t id = getManager().soundCreateExplode(size, duration);
    if (fbAudioDebugEnabled()) {
        std::fprintf(stderr, "[FB_AUDIO_DEBUG] create explode size=%.3f dur=%.3f -> id=%u\n", size, duration, id);
    }
    return id;
}

uint32_t fb_sound_create_big_explosion(float size, float duration) {
    if (!ensureInit()) return 0;
    uint32_t id = getManager().soundCreateBigExplosion(size, duration);
    if (fbAudioDebugEnabled()) {
        std::fprintf(stderr, "[FB_AUDIO_DEBUG] create bigexplode size=%.3f dur=%.3f -> id=%u\n", size, duration, id);
    }
    return id;
}

uint32_t fb_sound_create_small_explosion(float intensity, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateSmallExplosion(intensity, duration);
}

uint32_t fb_sound_create_distant_explosion(float distance, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateDistantExplosion(distance, duration);
}

uint32_t fb_sound_create_metal_explosion(float shrapnel, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateMetalExplosion(shrapnel, duration);
}

uint32_t fb_sound_create_bang(float intensity, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateBang(intensity, duration);
}

uint32_t fb_sound_create_coin(float pitch, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateCoin(pitch, duration);
}

uint32_t fb_sound_create_jump(float power, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateJump(power, duration);
}

uint32_t fb_sound_create_powerup(float intensity, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreatePowerup(intensity, duration);
}

uint32_t fb_sound_create_hurt(float severity, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateHurt(severity, duration);
}

uint32_t fb_sound_create_shoot(float power, float duration) {
    if (!ensureInit()) return 0;
    uint32_t id = getManager().soundCreateShoot(power, duration);
    if (fbAudioDebugEnabled()) {
        std::fprintf(stderr, "[FB_AUDIO_DEBUG] create shoot power=%.3f dur=%.3f -> id=%u\n", power, duration, id);
    }
    return id;
}

uint32_t fb_sound_create_click(float sharpness, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateClick(sharpness, duration);
}

uint32_t fb_sound_create_blip(float pitch, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateBlip(pitch, duration);
}

uint32_t fb_sound_create_pickup(float brightness, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreatePickup(brightness, duration);
}

uint32_t fb_sound_create_sweep_up(float start_freq, float end_freq, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateSweepUp(start_freq, end_freq, duration);
}

uint32_t fb_sound_create_sweep_down(float start_freq, float end_freq, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateSweepDown(start_freq, end_freq, duration);
}

uint32_t fb_sound_create_random_beep(uint32_t seed, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateRandomBeep(seed, duration);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Custom Synthesis
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_sound_create_tone(float frequency, float duration, int waveform) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateTone(frequency, duration, waveform);
}

uint32_t fb_sound_create_note(int midi_note, float duration, int waveform,
                              float attack, float decay,
                              float sustain, float release) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateNote(midi_note, duration, waveform,
                                        attack, decay, sustain, release);
}

uint32_t fb_sound_create_noise(int noise_type, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateNoise(noise_type, duration);
}

uint32_t fb_sound_create_fm(float carrier_freq, float mod_freq,
                            float mod_index, float duration) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateFM(carrier_freq, mod_freq, mod_index, duration);
}

uint32_t fb_sound_create_filtered_tone(float frequency, float duration,
                                       int waveform, int filter_type,
                                       float cutoff, float resonance) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateFilteredTone(frequency, duration, waveform,
                                                filter_type, cutoff, resonance);
}

uint32_t fb_sound_create_filtered_note(int midi_note, float duration,
                                       int waveform,
                                       float attack, float decay,
                                       float sustain, float release,
                                       int filter_type,
                                       float cutoff, float resonance) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateFilteredNote(midi_note, duration, waveform,
                                                attack, decay, sustain, release,
                                                filter_type, cutoff, resonance);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Effects Processing
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_sound_create_with_reverb(float frequency, float duration,
                                     int waveform,
                                     float room_size, float damping, float wet) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateWithReverb(frequency, duration, waveform,
                                              room_size, damping, wet);
}

uint32_t fb_sound_create_with_delay(float frequency, float duration,
                                    int waveform,
                                    float delay_time, float feedback, float mix) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateWithDelay(frequency, duration, waveform,
                                             delay_time, feedback, mix);
}

uint32_t fb_sound_create_with_distortion(float frequency, float duration,
                                         int waveform,
                                         float drive, float tone, float level) {
    if (!ensureInit()) return 0;
    return getManager().soundCreateWithDistortion(frequency, duration, waveform,
                                                   drive, tone, level);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Playback
// ═══════════════════════════════════════════════════════════════════════════════

void fb_sound_play(uint32_t sound_id, float volume, float pan) {
    if (!ensureInit()) return;
    if (fbAudioDebugEnabled()) {
        FBAudioManager& mgr = getManager();
        bool exists = mgr.soundExists(sound_id);
        float dur = mgr.soundGetDuration(sound_id);
        std::fprintf(stderr,
                     "[FB_AUDIO_DEBUG] play id=%u vol=%.3f pan=%.3f exists=%d dur=%.3f count=%zu\n",
                     sound_id,
                     volume,
                     pan,
                     exists ? 1 : 0,
                     dur,
                     mgr.soundGetCount());
    }
    getManager().soundPlay(sound_id, volume, pan);
}

void fb_sound_play_simple(uint32_t sound_id) {
    if (!ensureInit()) return;
    getManager().soundPlay(sound_id, 1.0f, 0.0f);
}

void fb_sound_stop(void) {
    if (!ensureInit()) return;
    getManager().soundStop();
}

void fb_sound_stop_one(uint32_t sound_id) {
    if (!ensureInit()) return;
    getManager().soundStopOne(sound_id);
}

bool fb_sound_is_playing(uint32_t sound_id) {
    if (!ensureInit()) return false;
    return getManager().soundIsPlaying(sound_id);
}

float fb_sound_get_duration(uint32_t sound_id) {
    if (!ensureInit()) return 0.0f;
    return getManager().soundGetDuration(sound_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

bool fb_sound_free(uint32_t sound_id) {
    if (!ensureInit()) return false;
    return getManager().soundFree(sound_id);
}

void fb_sound_free_all(void) {
    if (!ensureInit()) return;
    getManager().soundFreeAll();
}

bool fb_sound_export_wav(uint32_t sound_id, const char* filename, float volume) {
    if (!ensureInit()) return false;
    return getManager().soundExportWav(sound_id, filename, volume);
}

uint32_t fb_sound_import_synth_memory(uint32_t synth_memory_id) {
    if (!ensureInit()) return 0;
    return getManager().soundImportSynthMemory(synth_memory_id);
}

bool fb_sound_discard_synth_memory(uint32_t synth_memory_id) {
    if (!ensureInit()) return false;
    return getManager().soundDiscardSynthMemory(synth_memory_id);
}

void fb_sound_set_volume(float volume) {
    if (!ensureInit()) return;
    if (fbAudioDebugEnabled()) {
        std::fprintf(stderr, "[FB_AUDIO_DEBUG] set sound volume=%.3f\n", volume);
    }
    getManager().setSoundVolume(volume);
}

float fb_sound_get_volume(void) {
    if (!ensureInit()) return 1.0f;
    return getManager().getSoundVolume();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Queries
// ═══════════════════════════════════════════════════════════════════════════════

bool fb_sound_exists(uint32_t sound_id) {
    if (!ensureInit()) return false;
    return getManager().soundExists(sound_id);
}

size_t fb_sound_get_count(void) {
    if (!ensureInit()) return 0;
    return getManager().soundGetCount();
}

size_t fb_sound_get_memory_usage(void) {
    if (!ensureInit()) return 0;
    return getManager().soundGetMemoryUsage();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Utility
// ═══════════════════════════════════════════════════════════════════════════════

float fb_note_to_freq(int midi_note) {
    return FBAudioManager::noteToFrequency(midi_note);
}

int fb_freq_to_note(float frequency) {
    return FBAudioManager::frequencyToNote(frequency);
}

void fb_audio_stop_all(void) {
    if (!ensureInit()) return;
    getManager().stopAll();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Inline Playback
// ═══════════════════════════════════════════════════════════════════════════════

void fb_music_play(const char* abc_notation, float volume) {
    if (!ensureInit()) return;
    getManager().musicPlay(abc_notation, volume);
}

void fb_music_play_simple(const char* abc_notation) {
    if (!ensureInit()) return;
    getManager().musicPlay(abc_notation, 1.0f);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank (Load and Play by Slot)
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_music_load_string(const char* abc_notation) {
    if (!ensureInit()) return 0;
    return getManager().musicLoadString(abc_notation);
}

uint32_t fb_music_load_compiled_blob(const void* blob_data, size_t blob_size) {
    if (!ensureInit()) return 0;
    return getManager().musicLoadCompiledBlob(blob_data, blob_size);
}

void fb_music_play_id(uint32_t music_id, float volume) {
    if (!ensureInit()) return;
    getManager().musicPlayId(music_id, volume);
}

void fb_music_play_id_simple(uint32_t music_id) {
    if (!ensureInit()) return;
    getManager().musicPlayId(music_id, 1.0f);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Playback Control
// ═══════════════════════════════════════════════════════════════════════════════

void fb_music_stop(void) {
    if (!ensureInit()) return;
    getManager().musicStop();
}

void fb_music_pause(void) {
    if (!ensureInit()) return;
    getManager().musicPause();
}

void fb_music_resume(void) {
    if (!ensureInit()) return;
    getManager().musicResume();
}

void fb_music_set_volume(float volume) {
    if (!ensureInit()) return;
    getManager().setMusicVolume(volume);
}

float fb_music_get_volume(void) {
    if (!ensureInit()) return 1.0f;
    return getManager().getMusicVolume();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

bool fb_music_free(uint32_t music_id) {
    if (!ensureInit()) return false;
    return getManager().musicFree(music_id);
}

void fb_music_free_all(void) {
    if (!ensureInit()) return;
    getManager().musicFreeAll();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Queries
// ═══════════════════════════════════════════════════════════════════════════════

bool fb_music_is_playing(void) {
    if (!ensureInit()) return false;
    return getManager().isMusicPlaying();
}

bool fb_music_is_playing_id(uint32_t music_id) {
    if (!ensureInit()) return false;
    return getManager().isMusicPlayingId(music_id);
}

int fb_music_get_state(void) {
    if (!ensureInit()) return 0;
    return getManager().getMusicState();
}

bool fb_music_exists(uint32_t music_id) {
    if (!ensureInit()) return false;
    return getManager().musicExists(music_id);
}

size_t fb_music_get_count(void) {
    if (!ensureInit()) return 0;
    return getManager().musicGetCount();
}

size_t fb_music_get_memory_usage(void) {
    if (!ensureInit()) return 0;
    return getManager().musicGetMemoryUsage();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Metadata
// ═══════════════════════════════════════════════════════════════════════════════

const char* fb_music_get_title(uint32_t music_id) {
    if (!ensureInit()) return "";
    return getManager().musicGetTitle(music_id);
}

const char* fb_music_get_composer(uint32_t music_id) {
    if (!ensureInit()) return "";
    return getManager().musicGetComposer(music_id);
}

const char* fb_music_get_key(uint32_t music_id) {
    if (!ensureInit()) return "";
    return getManager().musicGetKey(music_id);
}

float fb_music_get_tempo(uint32_t music_id) {
    if (!ensureInit()) return 0.0f;
    return getManager().musicGetTempo(music_id);
}

const char* fb_music_get_compiled_blob_info(uint32_t music_id) {
    if (!ensureInit()) return "";
    return getManager().musicGetCompiledBlobInfo(music_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Rendering
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t fb_music_render(const char* abc_notation, float duration, float sample_rate) {
    if (!ensureInit()) return 0;
    return getManager().musicRenderToSoundBank(abc_notation, duration, sample_rate);
}

uint32_t fb_music_render_simple(const char* abc_notation) {
    if (!ensureInit()) return 0;
    return getManager().musicRenderToSoundBank(abc_notation, 0.0f, 0.0f);
}

bool fb_music_render_wav(const char* abc_notation, const char* filename,
                         float duration, float sample_rate) {
    if (!ensureInit()) return false;
    return getManager().musicRenderWav(abc_notation, filename, duration, sample_rate);
}

bool fb_music_export_midi(uint32_t music_id, const char* filename) {
    if (!ensureInit()) return false;
    return getManager().musicExportMidi(music_id, filename);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Oscillator
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_waveform(int voice, int waveform) {
    if (!ensureInit()) return;
    getManager().vsSetWaveform(voice, waveform);
}

void fb_vs_frequency(int voice, float hz) {
    if (!ensureInit()) return;
    getManager().vsSetFrequency(voice, hz);
}

void fb_vs_note(int voice, int midi_note) {
    if (!ensureInit()) return;
    getManager().vsSetNote(voice, midi_note);
}

void fb_vs_notename(int voice, const char* name) {
    if (!ensureInit()) return;
    getManager().vsSetNoteName(voice, name);
}

void fb_vs_pulse(int voice, float width) {
    if (!ensureInit()) return;
    getManager().vsSetPulseWidth(voice, width);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Envelope
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_envelope(int voice, float attack_ms, float decay_ms,
                    float sustain, float release_ms) {
    if (!ensureInit()) return;
    getManager().vsSetEnvelope(voice, attack_ms, decay_ms, sustain, release_ms);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Gate
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_gate(int voice, bool gate_on) {
    if (!ensureInit()) return;
    getManager().vsSetGate(voice, gate_on);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Volume & Pan
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_volume(int voice, float level) {
    if (!ensureInit()) return;
    getManager().vsSetVolume(voice, level);
}

void fb_vs_pan(int voice, float position) {
    if (!ensureInit()) return;
    getManager().vsSetPan(voice, position);
}

void fb_vs_master(float level) {
    if (!ensureInit()) return;
    getManager().vsSetMasterVolume(level);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Filter
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_filter_type(int filter_type) {
    if (!ensureInit()) return;
    getManager().vsSetFilterType(filter_type);
}

void fb_vs_filter_cutoff(float hz) {
    if (!ensureInit()) return;
    getManager().vsSetFilterCutoff(hz);
}

void fb_vs_filter_resonance(float q) {
    if (!ensureInit()) return;
    getManager().vsSetFilterResonance(q);
}

void fb_vs_filter_enabled(bool on) {
    if (!ensureInit()) return;
    getManager().vsSetFilterEnabled(on);
}

void fb_vs_filter_route(int voice, bool on) {
    if (!ensureInit()) return;
    getManager().vsSetFilterRouting(voice, on);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Modulation
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_ring(int voice, int source_voice) {
    if (!ensureInit()) return;
    getManager().vsSetRingMod(voice, source_voice);
}

void fb_vs_sync(int voice, int source_voice) {
    if (!ensureInit()) return;
    getManager().vsSetSync(voice, source_voice);
}

void fb_vs_portamento(int voice, float seconds) {
    if (!ensureInit()) return;
    getManager().vsSetPortamento(voice, seconds);
}

void fb_vs_detune(int voice, float cents) {
    if (!ensureInit()) return;
    getManager().vsSetDetune(voice, cents);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Per-Voice Delay
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_delay_enabled(int voice, bool on) {
    if (!ensureInit()) return;
    getManager().vsSetDelayEnabled(voice, on);
}

void fb_vs_delay_time(int voice, float seconds) {
    if (!ensureInit()) return;
    getManager().vsSetDelayTime(voice, seconds);
}

void fb_vs_delay_feedback(int voice, float amount) {
    if (!ensureInit()) return;
    getManager().vsSetDelayFeedback(voice, amount);
}

void fb_vs_delay_mix(int voice, float mix) {
    if (!ensureInit()) return;
    getManager().vsSetDelayMix(voice, mix);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — LFO
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_lfo_waveform(int lfo, int waveform) {
    if (!ensureInit()) return;
    getManager().vsSetLFOWaveform(lfo, waveform);
}

void fb_vs_lfo_rate(int lfo, float hz) {
    if (!ensureInit()) return;
    getManager().vsSetLFORate(lfo, hz);
}

void fb_vs_lfo_reset(int lfo) {
    if (!ensureInit()) return;
    getManager().vsResetLFO(lfo);
}

void fb_vs_lfo_pitch(int voice, int lfo, float depth_cents) {
    if (!ensureInit()) return;
    getManager().vsSetLFOToPitch(voice, lfo, depth_cents);
}

void fb_vs_lfo_volume(int voice, int lfo, float depth) {
    if (!ensureInit()) return;
    getManager().vsSetLFOToVolume(voice, lfo, depth);
}

void fb_vs_lfo_filter(int voice, int lfo, float depth_hz) {
    if (!ensureInit()) return;
    getManager().vsSetLFOToFilter(voice, lfo, depth_hz);
}

void fb_vs_lfo_pulse(int voice, int lfo, float depth) {
    if (!ensureInit()) return;
    getManager().vsSetLFOToPulseWidth(voice, lfo, depth);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Physical Modeling
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_physical_model(int voice, int model_type) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalModel(voice, model_type);
}

void fb_vs_physical_damping(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalDamping(voice, val);
}

void fb_vs_physical_brightness(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalBrightness(voice, val);
}

void fb_vs_physical_excitation(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalExcitation(voice, val);
}

void fb_vs_physical_resonance(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalResonance(voice, val);
}

void fb_vs_physical_tension(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalTension(voice, val);
}

void fb_vs_physical_pressure(int voice, float val) {
    if (!ensureInit()) return;
    getManager().vsSetPhysicalPressure(voice, val);
}

void fb_vs_physical_trigger(int voice) {
    if (!ensureInit()) return;
    getManager().vsTriggerPhysical(voice);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Global Control
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_reset(void) {
    if (!ensureInit()) return;
    getManager().vsReset();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Queries
// ═══════════════════════════════════════════════════════════════════════════════

int fb_vs_active_count(void) {
    if (!ensureInit()) return 0;
    return getManager().vsGetActiveCount();
}

float fb_vs_get_master(void) {
    if (!ensureInit()) return 0.0f;
    return getManager().vsGetMasterVolume();
}

bool fb_vs_is_playing(void) {
    if (!ensureInit()) return false;
    return getManager().vsIsPlaying();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Recording & Rendering
// ═══════════════════════════════════════════════════════════════════════════════

void fb_vs_record_start(void) {
    if (!ensureInit()) return;
    getManager().vsRecordStart();
}

void fb_vs_record_tempo(float bpm) {
    if (!ensureInit()) return;
    getManager().vsRecordTempo(bpm);
}

void fb_vs_record_wait(float beats) {
    if (!ensureInit()) return;
    getManager().vsRecordWait(beats);
}

uint32_t fb_vs_record_save(float volume) {
    if (!ensureInit()) return 0;
    return getManager().vsRecordSave(volume);
}

void fb_vs_record_play(float volume) {
    if (!ensureInit()) return;
    getManager().vsRecordPlay(volume);
}

void fb_vs_record_wav(const char* filename) {
    if (!ensureInit()) return;
    getManager().vsRecordWav(filename);
}

} // extern "C"
