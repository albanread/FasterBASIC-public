//
// FBAudioManager.h
// FasterBASIC Audio Manager — Phase 1 (SOUND) + Phase 2 (MUSIC) + Phase 3 (VS)
//
// Stripped-down facade over SynthEngine + SoundBank + AVAudioEngine.
// Provides slot-based sound creation and playback for the BASIC runtime.
//
// This is the FasterBASIC equivalent of SuperTerminal's AudioManager,
// reduced to just the SOUND keyword family for Phase 1.
//
// MIT License — Copyright (c) 2025
//

#ifndef FB_AUDIO_MANAGER_H
#define FB_AUDIO_MANAGER_H

#include <cstdint>
#include <cstddef>
#include <memory>
#include <mutex>
#include <atomic>

// ═══════════════════════════════════════════════════════════════════════════════
//  Forward Declarations
// ═══════════════════════════════════════════════════════════════════════════════

class SynthEngine;

namespace SuperTerminal {
    class SoundBank;
    class MusicBank;
    class ABCParser;
    class MidiEngine;
    class CoreAudioEngine;
    class VoiceController;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Constants
//
//  Waveform / noise / filter / physical-model constants are defined in
//  fb_audio_shim.h as C-compatible #defines (FB_WAVE_*, FB_NOISE_*, etc.).
//  FBAudioManager methods accept plain int for these parameters.
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
//  FBAudioManager
// ═══════════════════════════════════════════════════════════════════════════════

/// FBAudioManager — Phase 1 audio facade for FasterBASIC
///
/// Manages:
///   - SynthEngine:   procedural sound generation (PCM buffers)
///   - SoundBank:     slot-based storage of generated sounds
///   - AVAudioEngine: real-time playback via Apple audio stack
///
/// Thread safety:
///   All public methods are safe to call from any thread.
///   Internally mutex-protected; AVAudioEngine callbacks are lock-free.
///
/// Lifecycle:
///   1. Construct (lightweight — no audio hardware touched)
///   2. initialize() — starts AVAudioEngine, inits SynthEngine
///   3. soundCreate* / soundPlay / soundFree — normal use
///   4. shutdown() — tears down audio hardware
///   5. Destructor calls shutdown() if needed
///
class FBAudioManager {
public:
    FBAudioManager();
    ~FBAudioManager();

    // Non-copyable, non-movable (singleton-like usage)
    FBAudioManager(const FBAudioManager&) = delete;
    FBAudioManager& operator=(const FBAudioManager&) = delete;
    FBAudioManager(FBAudioManager&&) = delete;
    FBAudioManager& operator=(FBAudioManager&&) = delete;

    // ─────────────────────────────────────────────────────────────────────
    //  Lifecycle
    // ─────────────────────────────────────────────────────────────────────

    /// Initialize audio subsystem (AVAudioEngine, SynthEngine).
    /// Returns true on success. Safe to call multiple times.
    bool initialize();

    /// Shut down audio subsystem and release resources.
    void shutdown();

    /// Check if initialized.
    bool isInitialized() const;

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Predefined Game Sound Effects
    //  Each creates a procedurally generated sound in the SoundBank.
    //  Returns an internal sound ID (0 = error).
    // ─────────────────────────────────────────────────────────────────────

    uint32_t soundCreateBeep(float frequency, float duration);
    uint32_t soundCreateZap(float frequency, float duration);
    uint32_t soundCreateExplode(float size, float duration);
    uint32_t soundCreateBigExplosion(float size, float duration);
    uint32_t soundCreateSmallExplosion(float intensity, float duration);
    uint32_t soundCreateDistantExplosion(float distance, float duration);
    uint32_t soundCreateMetalExplosion(float shrapnel, float duration);
    uint32_t soundCreateBang(float intensity, float duration);
    uint32_t soundCreateCoin(float pitch, float duration);
    uint32_t soundCreateJump(float power, float duration);
    uint32_t soundCreatePowerup(float intensity, float duration);
    uint32_t soundCreateHurt(float severity, float duration);
    uint32_t soundCreateShoot(float power, float duration);
    uint32_t soundCreateClick(float sharpness, float duration);
    uint32_t soundCreateBlip(float pitch, float duration);
    uint32_t soundCreatePickup(float brightness, float duration);
    uint32_t soundCreateSweepUp(float startFreq, float endFreq, float duration);
    uint32_t soundCreateSweepDown(float startFreq, float endFreq, float duration);
    uint32_t soundCreateRandomBeep(uint32_t seed, float duration);

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Custom Synthesis
    // ─────────────────────────────────────────────────────────────────────

    /// Simple tone: waveform + frequency + duration
    uint32_t soundCreateTone(float frequency, float duration, int waveform);

    /// Musical note with ADSR envelope
    uint32_t soundCreateNote(int midiNote, float duration, int waveform,
                             float attack, float decay,
                             float sustain, float release);

    /// Noise generator
    uint32_t soundCreateNoise(int noiseType, float duration);

    /// FM synthesis
    uint32_t soundCreateFM(float carrierFreq, float modFreq,
                           float modIndex, float duration);

    /// Filtered tone
    uint32_t soundCreateFilteredTone(float frequency, float duration,
                                     int waveform, int filterType,
                                     float cutoff, float resonance);

    /// Filtered note with ADSR
    uint32_t soundCreateFilteredNote(int midiNote, float duration,
                                     int waveform,
                                     float attack, float decay,
                                     float sustain, float release,
                                     int filterType,
                                     float cutoff, float resonance);

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Effects Processing (create with effect baked in)
    // ─────────────────────────────────────────────────────────────────────

    uint32_t soundCreateWithReverb(float frequency, float duration,
                                   int waveform,
                                   float roomSize, float damping, float wet);

    uint32_t soundCreateWithDelay(float frequency, float duration,
                                  int waveform,
                                  float delayTime, float feedback, float mix);

    uint32_t soundCreateWithDistortion(float frequency, float duration,
                                       int waveform,
                                       float drive, float tone, float level);

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Playback
    // ─────────────────────────────────────────────────────────────────────

    /// Play a sound by its bank ID.
    /// @param soundId  ID returned from any soundCreate* method
    /// @param volume   0.0 (silent) to 1.0 (full), default 1.0
    /// @param pan      -1.0 (left) to 1.0 (right), default 0.0 (centre)
    void soundPlay(uint32_t soundId, float volume = 1.0f, float pan = 0.0f);

    /// Stop all currently playing sounds.
    void soundStop();

    /// Stop one specific sound slot (logical stop — marks it not-playing).
    void soundStopOne(uint32_t soundId);

    /// Is this sound slot currently playing?
    /// Uses a time-based estimate from the most recent soundPlay call.
    bool soundIsPlaying(uint32_t soundId) const;

    /// Return the PCM buffer duration of a slot in seconds (0.0 if unknown).
    float soundGetDuration(uint32_t soundId) const;

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Bank Management
    // ─────────────────────────────────────────────────────────────────────

    /// Free a single sound slot.
    bool soundFree(uint32_t soundId);

    /// Free all sound slots.
    void soundFreeAll();

    /// Export a stored sound slot to a WAV file.
    /// @param soundId   SoundBank ID
    /// @param filename  Output WAV path
    /// @param volume    Linear gain applied on export (0.0-1.0+)
    bool soundExportWav(uint32_t soundId, const char* filename, float volume = 1.0f);

    /// Import a temporary SynthEngine memory-buffer ID into SoundBank.
    /// Returns a SoundBank sound ID (0 on failure).
    uint32_t soundImportSynthMemory(uint32_t synthMemoryId);

    /// Discard a temporary SynthEngine memory-buffer ID without importing.
    bool soundDiscardSynthMemory(uint32_t synthMemoryId);

    /// Set master sound volume (0.0–1.0).
    void setSoundVolume(float volume);

    /// Get master sound volume.
    float getSoundVolume() const;

    // ─────────────────────────────────────────────────────────────────────
    //  SOUND — Queries
    // ─────────────────────────────────────────────────────────────────────

    /// Does a sound exist in the bank?
    bool soundExists(uint32_t soundId) const;

    /// Number of occupied sound slots.
    size_t soundGetCount() const;

    /// Approximate memory usage of all stored sounds (bytes).
    size_t soundGetMemoryUsage() const;

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Inline Playback (ABC notation)
    // ─────────────────────────────────────────────────────────────────────

    /// Play ABC notation string directly.
    /// @param abcNotation  ABC notation text (e.g. "X:1\nT:Scale\nM:4/4\nK:C\nCDEF|GABc|")
    /// @param volume       0.0 (silent) to 1.0 (full), default 1.0
    void musicPlay(const char* abcNotation, float volume = 1.0f);

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Bank (Load and Play by Slot)
    // ─────────────────────────────────────────────────────────────────────

    /// Load ABC notation from a string into the music bank.
    /// Returns an internal music ID (0 = error).
    uint32_t musicLoadString(const char* abcNotation);

    /// Load precompiled music blob data into the music bank.
    /// Blob format is owned by the compiler/runtime boundary.
    /// Returns an internal music ID (0 = error).
    uint32_t musicLoadCompiledBlob(const void* blobData, size_t blobSize);

    /// Play a music piece from the bank by its ID.
    /// @param musicId  ID returned from musicLoadString
    /// @param volume   0.0 (silent) to 1.0 (full), default 1.0
    void musicPlayId(uint32_t musicId, float volume = 1.0f);

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Playback Control
    // ─────────────────────────────────────────────────────────────────────

    /// Stop music playback.
    void musicStop();

    /// Pause music playback.
    void musicPause();

    /// Resume music playback from pause.
    void musicResume();

    /// Set music volume (0.0–1.0).
    void setMusicVolume(float volume);

    /// Get music volume.
    float getMusicVolume() const;

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Bank Management
    // ─────────────────────────────────────────────────────────────────────

    /// Free a single music slot.
    bool musicFree(uint32_t musicId);

    /// Free all music slots.
    void musicFreeAll();

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Queries
    // ─────────────────────────────────────────────────────────────────────

    /// Is music currently playing?
    bool isMusicPlaying() const;
    bool isMusicPlayingId(uint32_t musicId) const;

    /// Music state: 0=Stopped, 1=Playing, 2=Paused.
    int getMusicState() const;

    /// Does a music slot exist?
    bool musicExists(uint32_t musicId) const;

    /// Number of occupied music slots.
    size_t musicGetCount() const;

    /// Approximate memory usage of all stored music (bytes).
    size_t musicGetMemoryUsage() const;

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Metadata
    // ─────────────────────────────────────────────────────────────────────

    /// Get the title of a music piece (from ABC T: header).
    const char* musicGetTitle(uint32_t musicId) const;

    /// Get the composer of a music piece (from ABC C: header).
    const char* musicGetComposer(uint32_t musicId) const;

    /// Get the key signature of a music piece (from ABC K: header).
    const char* musicGetKey(uint32_t musicId) const;

    /// Get the tempo (BPM) of a music piece (from ABC Q: header).
    float musicGetTempo(uint32_t musicId) const;

    /// Get compiled blob introspection info for a music piece.
    /// For compiler-compiled music IDs, returns a semicolon-separated summary.
    /// For non-compiled bank entries, returns a minimal format marker.
    const char* musicGetCompiledBlobInfo(uint32_t musicId) const;

    // ─────────────────────────────────────────────────────────────────────
    //  MUSIC — Rendering (offline ABC → sound bank)
    // ─────────────────────────────────────────────────────────────────────

    /// Render ABC notation to a PCM sound buffer and register it in the
    /// SoundBank. Returns a sound ID suitable for SOUND PLAY.
    /// @param abcNotation  ABC notation text
    /// @param duration     Maximum render duration in seconds (0 = auto)
    /// @param sampleRate   Sample rate (0 = default 44100)
    uint32_t musicRenderToSoundBank(const char* abcNotation,
                                     float duration = 0.0f,
                                     float sampleRate = 0.0f);

    /// Render ABC notation to WAV output (if available in current backend).
    bool musicRenderWav(const char* abcNotation,
                        const char* filename,
                        float duration = 0.0f,
                        float sampleRate = 0.0f);

    /// Export compiled music (slot/id) to Standard MIDI File (.mid).
    /// Currently supported for compiler-compiled music IDs.
    bool musicExportMidi(uint32_t musicId, const char* filename);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Oscillator
    // ─────────────────────────────────────────────────────────────────────

    void vsSetWaveform(int voiceNum, int waveform);
    void vsSetFrequency(int voiceNum, float hz);
    void vsSetNote(int voiceNum, int midiNote);
    void vsSetNoteName(int voiceNum, const char* name);
    void vsSetPulseWidth(int voiceNum, float width);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Envelope (ADSR)
    // ─────────────────────────────────────────────────────────────────────

    void vsSetEnvelope(int voiceNum, float attackMs, float decayMs,
                       float sustainLevel, float releaseMs);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Gate Control
    // ─────────────────────────────────────────────────────────────────────

    void vsSetGate(int voiceNum, bool gateOn);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Volume & Pan
    // ─────────────────────────────────────────────────────────────────────

    void vsSetVolume(int voiceNum, float level);
    void vsSetPan(int voiceNum, float position);
    void vsSetMasterVolume(float level);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Filter (Global)
    // ─────────────────────────────────────────────────────────────────────

    void vsSetFilterType(int filterType);
    void vsSetFilterCutoff(float hz);
    void vsSetFilterResonance(float q);
    void vsSetFilterEnabled(bool enabled);
    void vsSetFilterRouting(int voiceNum, bool enabled);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Modulation (SID-Style)
    // ─────────────────────────────────────────────────────────────────────

    void vsSetRingMod(int voiceNum, int sourceVoice);
    void vsSetSync(int voiceNum, int sourceVoice);
    void vsSetPortamento(int voiceNum, float timeSeconds);
    void vsSetDetune(int voiceNum, float cents);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Per-Voice Delay
    // ─────────────────────────────────────────────────────────────────────

    void vsSetDelayEnabled(int voiceNum, bool enabled);
    void vsSetDelayTime(int voiceNum, float timeSeconds);
    void vsSetDelayFeedback(int voiceNum, float feedback);
    void vsSetDelayMix(int voiceNum, float mix);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — LFO (4 Global Low-Frequency Oscillators)
    // ─────────────────────────────────────────────────────────────────────

    void vsSetLFOWaveform(int lfoNum, int waveform);
    void vsSetLFORate(int lfoNum, float rateHz);
    void vsResetLFO(int lfoNum);
    void vsSetLFOToPitch(int voiceNum, int lfoNum, float depthCents);
    void vsSetLFOToVolume(int voiceNum, int lfoNum, float depth);
    void vsSetLFOToFilter(int voiceNum, int lfoNum, float depthHz);
    void vsSetLFOToPulseWidth(int voiceNum, int lfoNum, float depth);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Physical Modeling
    // ─────────────────────────────────────────────────────────────────────

    void vsSetPhysicalModel(int voiceNum, int modelType);
    void vsSetPhysicalDamping(int voiceNum, float damping);
    void vsSetPhysicalBrightness(int voiceNum, float brightness);
    void vsSetPhysicalExcitation(int voiceNum, float excitation);
    void vsSetPhysicalResonance(int voiceNum, float resonance);
    void vsSetPhysicalTension(int voiceNum, float tension);
    void vsSetPhysicalPressure(int voiceNum, float pressure);
    void vsTriggerPhysical(int voiceNum);

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Global Control
    // ─────────────────────────────────────────────────────────────────────

    void vsReset();

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Queries
    // ─────────────────────────────────────────────────────────────────────

    int vsGetActiveCount() const;
    float vsGetMasterVolume() const;
    bool vsIsPlaying() const;

    // ─────────────────────────────────────────────────────────────────────
    //  VS — Recording & Rendering (Timeline System)
    //
    //  Captures VS commands with beat timestamps, then renders offline
    //  through VoiceController to produce a PCM buffer.
    // ─────────────────────────────────────────────────────────────────────

    /// Start recording — subsequent VS commands are captured.
    void vsRecordStart();

    /// Set recording tempo in BPM (default 120).
    void vsRecordTempo(float bpm);

    /// Advance the recording beat cursor by N beats.
    void vsRecordWait(float beats);

    /// End recording and render to a SoundBank slot.
    /// Returns a sound ID suitable for SOUND PLAY.
    uint32_t vsRecordSave(float volume);

    /// End recording, render, and play immediately.
    void vsRecordPlay(float volume);

    /// End recording and render to a WAV file.
    void vsRecordWav(const char* filename);

    // ─────────────────────────────────────────────────────────────────────
    //  Utility
    // ─────────────────────────────────────────────────────────────────────

    /// Convert MIDI note number to frequency (Hz).
    static float noteToFrequency(int midiNote);

    /// Convert frequency (Hz) to nearest MIDI note number.
    static int frequencyToNote(float frequency);

    /// Stop all audio (sounds, music, future voices).
    void stopAll();

private:
    // ─────────────────────────────────────────────────────────────────────
    //  Implementation (PIMPL — hides Obj-C and C++ internals)
    // ─────────────────────────────────────────────────────────────────────
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

#endif // FB_AUDIO_MANAGER_H