//
//  SynthEngine.h
//  SuperTerminal Framework - Sound Synthesis Engine
//
//  Created by SuperTerminal Project
//  Copyright © 2024-2026 Alban Read, SuperTerminal. All rights reserved.
//

#pragma once

// #include "AudioSystem.h" // Not needed for V2
#include <memory>
#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <functional>
#include <cmath>
#include <array>

// Waveform types for oscillators
enum class WaveformType {
    SINE = 0,
    SQUARE = 1,
    SAWTOOTH = 2,
    TRIANGLE = 3,
    NOISE = 4,
    PULSE = 5
};

// Sound synthesis configuration
struct SynthConfig {
    uint32_t sampleRate = 44100;
    uint32_t channels = 2;          // Stereo
    uint32_t bitDepth = 16;         // 16-bit PCM
    float maxDuration = 10.0f;      // Max 10 seconds per generated sound
};

// Use WaveformType from AudioSystem.h
// WaveformType::SINE = 0, WAVE_SQUARE = 1, WAVE_SAWTOOTH = 2,
// WAVE_TRIANGLE = 3, WAVE_NOISE = 4

// Envelope ADSR (Attack, Decay, Sustain, Release)
struct EnvelopeADSR {
    float attackTime = 0.01f;       // Attack duration in seconds
    float decayTime = 0.1f;         // Decay duration in seconds
    float sustainLevel = 0.7f;      // Sustain level (0.0 to 1.0)
    float releaseTime = 0.2f;       // Release duration in seconds

    // Calculate envelope value at given time and note duration
    float getValue(float time, float noteDuration) const;
};

// Filter types and parameters
enum class FilterType {
    NONE = 0,
    LOW_PASS = 1,
    HIGH_PASS = 2,
    BAND_PASS = 3
};

struct FilterParams {
    FilterType type = FilterType::NONE;
    float cutoffFreq = 1000.0f;     // Cutoff frequency in Hz
    float resonance = 1.0f;         // Q factor (1.0 = no resonance)
    bool enabled = true;            // Filter enable/disable
    float mix = 1.0f;               // Dry/wet mix (0.0 = dry, 1.0 = wet)
};

// Advanced synthesis types
enum class SynthesisType {
    SUBTRACTIVE = 0,    // Traditional oscillator + filter
    ADDITIVE = 1,       // Sum of sine waves (harmonics)
    FM = 2,             // Frequency modulation
    GRANULAR = 3,       // Granular synthesis
    PHYSICAL = 4        // Physical modeling
};

// Additive synthesis parameters
struct AdditiveParams {
    float fundamental = 440.0f;             // Fundamental frequency
    std::array<float, 32> harmonics;        // Harmonic amplitudes (0.0-1.0)
    std::array<float, 32> harmonicPhases;   // Harmonic phase offsets
    int numHarmonics = 8;                   // Number of active harmonics

    AdditiveParams() {
        // Initialize with basic harmonic series
        harmonics.fill(0.0f);
        harmonicPhases.fill(0.0f);
        harmonics[0] = 1.0f;  // Fundamental
        harmonics[1] = 0.5f;  // Second harmonic
        harmonics[2] = 0.3f;  // Third harmonic
        harmonics[3] = 0.2f;  // Fourth harmonic
    }
};

// FM synthesis parameters
struct FMParams {
    float carrierFreq = 440.0f;     // Carrier frequency
    float modulatorFreq = 220.0f;   // Modulator frequency
    float modIndex = 2.0f;          // Modulation index
    float modulatorRatio = 1.0f;    // Modulator frequency ratio to carrier
    WaveformType carrierWave = WaveformType::SINE;
    WaveformType modulatorWave = WaveformType::SINE;
    float feedback = 0.0f;          // Feedback amount (0.0-1.0)
};

// Granular synthesis parameters
struct GranularParams {
    float grainSize = 0.05f;        // Grain size in seconds
    float overlap = 0.5f;           // Grain overlap (0.0-1.0)
    float pitch = 1.0f;             // Pitch multiplier
    float spread = 0.1f;            // Random pitch spread
    float density = 20.0f;          // Grains per second
    WaveformType grainWave = WaveformType::SINE;
    float randomness = 0.2f;        // Position randomness
};

// Physical modeling parameters
struct PhysicalParams {
    enum ModelType {
        PLUCKED_STRING,
        STRUCK_BAR,
        BLOWN_TUBE,
        DRUMHEAD
    } modelType = PLUCKED_STRING;

    float frequency = 440.0f;       // Base frequency
    float damping = 0.1f;           // Damping factor
    float brightness = 0.5f;        // Brightness/harmonics
    float excitation = 1.0f;        // Excitation strength
    float resonance = 0.3f;         // Body resonance
    float stringTension = 0.8f;     // String tension (for string models)
    float airPressure = 0.7f;       // Air pressure (for wind models)
};

// Real-time modulation parameters
struct ModulationParams {
    // LFO (Low Frequency Oscillator)
    struct LFO {
        WaveformType waveform = WaveformType::SINE;
        float frequency = 2.0f;     // LFO frequency in Hz
        float amplitude = 0.0f;     // Modulation depth
        float phase = 0.0f;         // Phase offset
        bool enabled = false;
    };

    LFO frequencyLFO;               // Frequency modulation
    LFO amplitudeLFO;               // Amplitude modulation
    LFO filterLFO;                  // Filter modulation

    // Envelope followers
    bool frequencyEnvelope = false;  // Apply envelope to frequency
    bool filterEnvelope = true;      // Apply envelope to filter
    float envelopeAmount = 1.0f;     // Envelope modulation depth
};

// Audio effects parameters
struct EffectsParams {
    // Reverb
    struct Reverb {
        bool enabled = false;
        float roomSize = 0.5f;      // 0.0-1.0
        float damping = 0.5f;       // 0.0-1.0
        float width = 1.0f;         // 0.0-1.0
        float wet = 0.3f;           // 0.0-1.0
        float dry = 0.7f;           // 0.0-1.0
    } reverb;

    // Distortion
    struct Distortion {
        bool enabled = false;
        float drive = 0.5f;         // 0.0-2.0
        float tone = 0.5f;          // 0.0-1.0 (low-pass after distortion)
        float level = 0.8f;         // Output level
    } distortion;

    // Chorus
    struct Chorus {
        bool enabled = false;
        float rate = 1.0f;          // LFO rate in Hz
        float depth = 0.3f;         // Modulation depth
        float delay = 0.02f;        // Base delay in seconds
        float feedback = 0.2f;      // Feedback amount
        float mix = 0.5f;           // Dry/wet mix
    } chorus;

    // Delay
    struct Delay {
        bool enabled = false;
        float delayTime = 0.25f;    // Delay time in seconds
        float feedback = 0.3f;      // Feedback amount
        float mix = 0.3f;           // Dry/wet mix
        bool syncToTempo = false;   // Sync to BPM
    } delay;
};

// Enhanced oscillator definition
struct Oscillator {
    WaveformType waveform = WaveformType::SINE;
    float frequency = 440.0f;       // Base frequency in Hz
    float amplitude = 1.0f;         // Amplitude (0.0 to 1.0)
    float phase = 0.0f;             // Phase offset
    float pulseWidth = 0.5f;        // For pulse waves (0.0 to 1.0)

    // Frequency modulation
    float fmAmount = 0.0f;          // FM depth
    float fmFreq = 0.0f;            // FM frequency

    // Amplitude modulation
    float amAmount = 0.0f;          // AM depth
    float amFreq = 0.0f;            // AM frequency

    // Real-time parameter control
    bool frequencyTracking = true;  // Follow note frequency
    float detuneAmount = 0.0f;      // Detune in cents
    float drift = 0.0f;             // Random frequency drift

    // Oscillator sync
    bool hardSync = false;          // Hard sync to master oscillator
    float syncRatio = 1.0f;         // Sync frequency ratio
};

// Enhanced sound effect definition
struct SynthSoundEffect {
    std::string name;
    float duration = 1.0f;          // Duration in seconds
    SynthesisType synthesisType = SynthesisType::SUBTRACTIVE;

    // Traditional subtractive synthesis
    std::vector<Oscillator> oscillators;
    EnvelopeADSR envelope;
    FilterParams filter;

    // Advanced synthesis parameters
    AdditiveParams additive;
    FMParams fm;
    GranularParams granular;
    PhysicalParams physical;

    // Real-time modulation
    ModulationParams modulation;

    // Audio effects
    EffectsParams effects;

    // Legacy effect parameters (kept for compatibility)
    float pitchSweepStart = 0.0f;   // Pitch sweep (semitones)
    float pitchSweepEnd = 0.0f;
    float pitchSweepCurve = 1.0f;   // Sweep curve (1.0 = linear, >1 = exponential)

    float noiseMix = 0.0f;          // Mix in noise (0.0 to 1.0)
    float distortion = 0.0f;        // Distortion amount (0.0 to 1.0)

    // Repeat/echo (legacy - use effects.delay instead)
    float echoDelay = 0.0f;         // Echo delay in seconds
    float echoDecay = 0.0f;         // Echo decay factor
    int echoCount = 0;              // Number of echoes
};

// Predefined sound effect types
enum class SoundEffectType {
    BEEP,
    BANG,
    EXPLODE,
    ZAP,
    COIN,
    JUMP,
    POWERUP,
    HURT,
    SHOOT,
    CLICK,
    SWEEP_UP,
    SWEEP_DOWN,
    RANDOM_BEEP,
    PICKUP,
    BLIP
};

// Generated audio buffer
struct SynthAudioBuffer {
    std::vector<float> samples;     // Interleaved stereo samples
    uint32_t sampleRate;
    uint32_t channels;
    float duration;

    SynthAudioBuffer(uint32_t sr = 44100, uint32_t ch = 2)
        : sampleRate(sr), channels(ch), duration(0.0f) {}

    size_t getSampleCount() const { return samples.size(); }
    size_t getFrameCount() const { return samples.size() / channels; }
    void resize(float durationSeconds);
    void clear();
};

// WAV file export parameters
struct WAVExportParams {
    uint32_t sampleRate = 44100;
    uint16_t bitDepth = 16;         // 8, 16, 24, or 32 bit
    uint16_t channels = 2;          // Mono or stereo
    bool normalize = true;          // Normalize to prevent clipping
    float volume = 1.0f;            // Output volume multiplier
};

// Main synthesis engine
class SynthEngine {
public:
    SynthEngine();
    ~SynthEngine();

    // Initialization
    bool initialize(const SynthConfig& config = SynthConfig{});
    void shutdown();
    bool isInitialized() const { return initialized.load(); }

    // Memory-based sound generation (returns sound ID for immediate use)
    uint32_t generateBeepToMemory(float frequency, float duration);
    uint32_t generateExplodeToMemory(float size, float duration);
    uint32_t generateCoinToMemory(float pitch, float duration);
    uint32_t generateShootToMemory(float intensity, float duration);
    uint32_t generateClickToMemory(float intensity, float duration);
    uint32_t generateJumpToMemory(float power, float duration);
    uint32_t generatePowerupToMemory(float intensity, float duration);
    uint32_t generateHurtToMemory(float intensity, float duration);
    uint32_t generatePickupToMemory(float pitch, float duration);
    uint32_t generateBlipToMemory(float pitch, float duration);
    uint32_t generateZapToMemory(float frequency, float duration);

    // Advanced memory generation
    uint32_t generateBigExplosionToMemory(float size, float duration);
    uint32_t generateSmallExplosionToMemory(float intensity, float duration);
    uint32_t generateDistantExplosionToMemory(float distance, float duration);
    uint32_t generateMetalExplosionToMemory(float shrapnel, float duration);

    // Sweep effects to memory
    uint32_t generateSweepUpToMemory(float startFreq, float endFreq, float duration);
    uint32_t generateSweepDownToMemory(float startFreq, float endFreq, float duration);

    // Custom oscillator to memory
    uint32_t generateOscillatorToMemory(WaveformType waveform, float frequency, float duration,
                                       float attack, float decay, float sustain, float release);

    // Advanced synthesis to memory
    uint32_t generateAdditiveToMemory(float fundamental, const std::vector<float>& harmonics, float duration);
    uint32_t generateFMToMemory(float carrierFreq, float modulatorFreq, float modIndex, float duration);
    uint32_t generateGranularToMemory(float baseFreq, float grainSize, float overlap, float duration);
    uint32_t generatePhysicalToMemory(PhysicalParams::ModelType model, float frequency,
                                     float damping, float brightness, float duration);

    // Random generation to memory
    uint32_t generateRandomBeepToMemory(uint32_t seed, float duration);

    // Sound effect generation
    std::unique_ptr<SynthAudioBuffer> generateSound(const SynthSoundEffect& effect);
    std::unique_ptr<SynthAudioBuffer> generatePredefinedSound(SoundEffectType type, float duration = 0.0f);

    // Predefined sound effects
    std::unique_ptr<SynthAudioBuffer> generateBeep(float frequency = 800.0f, float duration = 0.2f);
    std::unique_ptr<SynthAudioBuffer> generateBang(float intensity = 1.0f, float duration = 0.3f);
    std::unique_ptr<SynthAudioBuffer> generateExplode(float size = 1.0f, float duration = 1.0f);

    // Specialized explosion types
    std::unique_ptr<SynthAudioBuffer> generateBigExplosion(float size = 1.0f, float duration = 2.0f);
    std::unique_ptr<SynthAudioBuffer> generateSmallExplosion(float intensity = 1.0f, float duration = 0.5f);
    std::unique_ptr<SynthAudioBuffer> generateDistantExplosion(float distance = 1.0f, float duration = 1.5f);
    std::unique_ptr<SynthAudioBuffer> generateMetalExplosion(float shrapnel = 1.0f, float duration = 1.2f);
    std::unique_ptr<SynthAudioBuffer> generateZap(float frequency = 2000.0f, float duration = 0.15f);
    std::unique_ptr<SynthAudioBuffer> generateCoin(float pitch = 1.0f, float duration = 0.4f);
    std::unique_ptr<SynthAudioBuffer> generateJump(float height = 1.0f, float duration = 0.3f);
    std::unique_ptr<SynthAudioBuffer> generatePowerUp(float intensity = 1.0f, float duration = 0.8f);
    std::unique_ptr<SynthAudioBuffer> generateHurt(float severity = 1.0f, float duration = 0.4f);
    std::unique_ptr<SynthAudioBuffer> generateShoot(float power = 1.0f, float duration = 0.2f);
    std::unique_ptr<SynthAudioBuffer> generateClick(float sharpness = 1.0f, float duration = 0.05f);

    // Sweep sounds
    std::unique_ptr<SynthAudioBuffer> generateSweepUp(float startFreq = 200.0f, float endFreq = 2000.0f, float duration = 0.5f);
    std::unique_ptr<SynthAudioBuffer> generateSweepDown(float startFreq = 2000.0f, float endFreq = 200.0f, float duration = 0.5f);

    // Random/procedural sounds
    std::unique_ptr<SynthAudioBuffer> generateRandomBeep(uint32_t seed = 0, float duration = 0.3f);
    std::unique_ptr<SynthAudioBuffer> generatePickup(float brightness = 1.0f, float duration = 0.25f);
    std::unique_ptr<SynthAudioBuffer> generateBlip(float pitch = 1.0f, float duration = 0.1f);

    // Custom oscillator synthesis
    std::unique_ptr<SynthAudioBuffer> synthesizeOscillator(const Oscillator& osc, float duration,
                                                     const EnvelopeADSR* envelope = nullptr,
                                                     const FilterParams* filter = nullptr);

    // Advanced synthesis methods
    std::unique_ptr<SynthAudioBuffer> synthesizeAdditive(const AdditiveParams& params, float duration,
                                                        const EnvelopeADSR* envelope = nullptr);
    std::unique_ptr<SynthAudioBuffer> synthesizeFM(const FMParams& params, float duration,
                                                   const EnvelopeADSR* envelope = nullptr);
    std::unique_ptr<SynthAudioBuffer> synthesizeGranular(const GranularParams& params, float duration,
                                                        const EnvelopeADSR* envelope = nullptr);
    std::unique_ptr<SynthAudioBuffer> synthesizePhysical(const PhysicalParams& params, float duration,
                                                        const EnvelopeADSR* envelope = nullptr);

    // WAV file export
    bool exportToWAV(const SynthAudioBuffer& buffer, const std::string& filename,
                     const WAVExportParams& params = WAVExportParams{});

    // Export to WAV format in memory (returns WAV file as byte vector)
    bool exportToWAVMemory(const SynthAudioBuffer& buffer, std::vector<uint8_t>& outWAVData,
                           const WAVExportParams& params = WAVExportParams{});

    // Utility functions
    static float noteToFrequency(int midiNote);           // Convert MIDI note to frequency
    static int frequencyToNote(float frequency);          // Convert frequency to MIDI note
    static float semitonesToRatio(float semitones);       // Convert semitones to frequency ratio
    static float dbToLinear(float db);                    // Convert dB to linear amplitude
    static float linearToDb(float linear);                // Convert linear amplitude to dB

    // Configuration
    SynthConfig getConfig() const { return config; }
    void setConfig(const SynthConfig& newConfig);

    // Performance monitoring
    float getLastGenerationTime() const { return lastGenerationTime; }
    size_t getGeneratedSoundCount() const { return generatedSoundCount.load(); }

private:
    // Configuration
    SynthConfig config;
    std::atomic<bool> initialized{false};

    // Performance tracking
    std::atomic<float> lastGenerationTime{0.0f};
    std::atomic<size_t> generatedSoundCount{0};

    // Thread safety
    mutable std::mutex synthMutex;

    // Internal synthesis functions
    float generateWaveform(WaveformType type, float phase, float pulseWidth = 0.5f);
    float generateNoise();
    void applySynthesis(SynthAudioBuffer& buffer, const SynthSoundEffect& effect);

    // Advanced synthesis engines
    void synthesizeAdditiveSamples(SynthAudioBuffer& buffer, const AdditiveParams& params,
                                  const EnvelopeADSR* envelope = nullptr);
    void synthesizeFMSamples(SynthAudioBuffer& buffer, const FMParams& params,
                            const EnvelopeADSR* envelope = nullptr);
    void synthesizeGranularSamples(SynthAudioBuffer& buffer, const GranularParams& params,
                                  const EnvelopeADSR* envelope = nullptr);
    void synthesizePhysicalSamples(SynthAudioBuffer& buffer, const PhysicalParams& params,
                                  const EnvelopeADSR* envelope = nullptr);

    // Main synthesis algorithm implementations
    void synthesizeAdditive(SynthAudioBuffer& buffer, const SynthSoundEffect& effect);
    void synthesizeFM(SynthAudioBuffer& buffer, const SynthSoundEffect& effect);
    void synthesizeGranular(SynthAudioBuffer& buffer, const SynthSoundEffect& effect);
    void synthesizePhysical(SynthAudioBuffer& buffer, const SynthSoundEffect& effect);

    // Modulation processing
    void applyModulation(SynthAudioBuffer& buffer, const ModulationParams& modulation);
    // Audio processing
    void applyFilter(SynthAudioBuffer& buffer, const FilterParams& filter);
    void applyDistortion(SynthAudioBuffer& buffer, float amount);
    void applyEcho(SynthAudioBuffer& buffer, float delay, float decay, int count);
    void normalizeBuffer(SynthAudioBuffer& buffer, float targetLevel = 0.9f);

    // Advanced audio effects
    void applyEffects(SynthAudioBuffer& buffer, const EffectsParams& effects);
    void applyReverb(SynthAudioBuffer& buffer, const EffectsParams::Reverb& reverb);
    void applyAdvancedDistortion(SynthAudioBuffer& buffer, const EffectsParams::Distortion& distortion);
    void applyChorus(SynthAudioBuffer& buffer, const EffectsParams::Chorus& chorus);
    void applyDelay(SynthAudioBuffer& buffer, const EffectsParams::Delay& delay);

    // Physical modeling internals
    void simulateString(SynthAudioBuffer& buffer, const PhysicalParams& params);
    void simulateBar(SynthAudioBuffer& buffer, const PhysicalParams& params);
    void simulateTube(SynthAudioBuffer& buffer, const PhysicalParams& params);
    void simulateDrum(SynthAudioBuffer& buffer, const PhysicalParams& params);

    // WAV file writing
    struct WAVHeader {
        char riffId[4];
        uint32_t riffSize;
        char waveId[4];
        char fmtId[4];
        uint32_t fmtSize;
        uint16_t format;
        uint16_t channels;
        uint32_t sampleRate;
        uint32_t byteRate;
        uint16_t blockAlign;
        uint16_t bitsPerSample;
        char dataId[4];
        uint32_t dataSize;
    };

    bool writeWAVHeader(FILE* file, const WAVExportParams& params, uint32_t dataSize);
    bool writeWAVData(FILE* file, const SynthAudioBuffer& buffer, const WAVExportParams& params);
    void convertFloatToInt16(const std::vector<float>& input, std::vector<int16_t>& output, float volume = 1.0f);
    void convertFloatToInt32(const std::vector<float>& input, std::vector<int32_t>& output, float volume = 1.0f);

    // Random number generation
    uint32_t randomSeed = 12345;
    float random01();  // Generate random float between 0.0 and 1.0
    float randomRange(float min, float max);

    // Predefined sound effect templates
    // Sound effect creators
    SynthSoundEffect createBeepEffect(float frequency, float duration);
    SynthSoundEffect createBangEffect(float intensity, float duration);
    SynthSoundEffect createExplodeEffect(float size, float duration);
    SynthSoundEffect createBigExplosionEffect(float size, float duration);
    SynthSoundEffect createSmallExplosionEffect(float intensity, float duration);
    SynthSoundEffect createDistantExplosionEffect(float distance, float duration);
    SynthSoundEffect createMetalExplosionEffect(float shrapnel, float duration);
    SynthSoundEffect createZapEffect(float frequency, float duration);
    SynthSoundEffect createCoinEffect(float pitch, float duration);
    SynthSoundEffect createJumpEffect(float height, float duration);
    SynthSoundEffect createPowerUpEffect(float intensity, float duration);
    SynthSoundEffect createHurtEffect(float severity, float duration);
    SynthSoundEffect createShootEffect(float power, float duration);
    SynthSoundEffect createClickEffect(float sharpness, float duration);
    SynthSoundEffect createSweepEffect(float startFreq, float endFreq, float duration, float intensity);
};

// Shared memory-buffer registry helpers for synth_create_* IDs.
// These are used by higher layers to adopt generated buffers into SoundBank.
std::unique_ptr<SynthAudioBuffer> synth_take_memory_buffer(uint32_t id);
bool synth_free_memory_buffer(uint32_t id);
bool synth_has_memory_buffer(uint32_t id);

// C interface for Lua bindings
extern "C" {
    // System functions
    bool synth_initialize();
    void synth_shutdown();
    bool synth_is_initialized();

    // Predefined sound generation
    bool synth_generate_beep(const char* filename, float frequency, float duration);
    bool synth_generate_bang(const char* filename, float intensity, float duration);
    bool synth_generate_explode(const char* filename, float size, float duration);
    bool synth_generate_big_explosion(const char* filename, float size, float duration);
    bool synth_generate_small_explosion(const char* filename, float intensity, float duration);
    bool synth_generate_distant_explosion(const char* filename, float distance, float duration);
    bool synth_generate_metal_explosion(const char* filename, float shrapnel, float duration);
    bool synth_generate_zap(const char* filename, float frequency, float duration);
    bool synth_generate_coin(const char* filename, float pitch, float duration);
    bool synth_generate_jump(const char* filename, float height, float duration);
    bool synth_generate_powerup(const char* filename, float intensity, float duration);
    bool synth_generate_hurt(const char* filename, float severity, float duration);
    bool synth_generate_shoot(const char* filename, float power, float duration);
    bool synth_generate_click(const char* filename, float sharpness, float duration);

    // Sweep sounds
    bool synth_generate_sweep_up(const char* filename, float startFreq, float endFreq, float duration);
    bool synth_generate_sweep_down(const char* filename, float startFreq, float endFreq, float duration);

    // Random/procedural sounds
    bool synth_generate_random_beep(const char* filename, uint32_t seed, float duration);
    bool synth_generate_pickup(const char* filename, float brightness, float duration);
    bool synth_generate_blip(const char* filename, float pitch, float duration);

    // Custom oscillator
    bool synth_generate_oscillator(const char* filename, int waveform, float frequency,
                                  float duration, float attack, float decay,
                                  float sustain, float release);

    // Advanced synthesis methods
    bool synth_generate_additive(const char* filename, float fundamental,
                                const float* harmonics, int numHarmonics, float duration);
    bool synth_generate_fm(const char* filename, float carrierFreq, float modulatorFreq,
                          float modIndex, float duration);
    bool synth_generate_granular(const char* filename, float baseFreq, float grainSize,
                                float overlap, float duration);
    bool synth_generate_physical_string(const char* filename, float frequency, float damping,
                                       float brightness, float duration);
    bool synth_generate_physical_bar(const char* filename, float frequency, float damping,
                                    float brightness, float duration);
    bool synth_generate_physical_tube(const char* filename, float frequency, float airPressure,
                                     float brightness, float duration);
    bool synth_generate_physical_drum(const char* filename, float frequency, float damping,
                                     float excitation, float duration);

    // Memory-based advanced synthesis
    uint32_t synth_create_additive(float fundamental, const float* harmonics, int numHarmonics, float duration);
    uint32_t synth_create_fm(float carrierFreq, float modulatorFreq, float modIndex, float duration);
    uint32_t synth_create_granular(float baseFreq, float grainSize, float overlap, float duration);
    uint32_t synth_create_physical_string(float frequency, float damping, float brightness, float duration);
    uint32_t synth_create_physical_bar(float frequency, float damping, float brightness, float duration);
    uint32_t synth_create_physical_tube(float frequency, float airPressure, float brightness, float duration);
    uint32_t synth_create_physical_drum(float frequency, float damping, float excitation, float duration);

    // Real-time parameter control
    bool synth_set_effect_param(uint32_t soundId, const char* effectType, const char* paramName, float value);
    bool synth_add_effect(uint32_t soundId, const char* effectType);
    bool synth_remove_effect(uint32_t soundId, const char* effectType);

    // Preset management
    bool synth_save_preset(const char* presetName, const char* presetData);
    const char* synth_load_preset(const char* presetName);
    bool synth_apply_preset(uint32_t soundId, const char* presetName);

    // Batch generation
    bool synth_generate_sound_pack(const char* directory);  // Generate a pack of common game sounds

    // Utility
    float synth_note_to_frequency(int midiNote);
    int synth_frequency_to_note(float frequency);

    // Performance info
    float synth_get_last_generation_time();
    size_t synth_get_generated_count();
}
