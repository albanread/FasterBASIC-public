//
//  VoiceController.h
//  SuperTerminal Framework - Persistent Voice Controller
//
//  SID-style voice control system for advanced audio programming
//  Provides continuous, stateful voices with waveforms, envelopes, and filters
//
//  Copyright © 2024 SuperTerminal. All rights reserved.
//

#ifndef SUPERTERMINAL_VOICE_CONTROLLER_H
#define SUPERTERMINAL_VOICE_CONTROLLER_H

#include <cstdint>
#include <vector>
#include <array>
#include <memory>
#include <mutex>
#include <atomic>
#include <string>

namespace SuperTerminal {

/// Voice waveform types (similar to SID)
enum class VoiceWaveform {
    Silence = 0,
    Sine,
    Square,
    Sawtooth,
    Triangle,
    Noise,
    Pulse,
    Physical  // Physical modeling synthesis
};

/// Physical modeling types
enum class PhysicalModelType {
    PluckedString = 0,  // Karplus-Strong string
    StruckBar = 1,      // Modal synthesis - bells, xylophones
    BlownTube = 2,      // Waveguide - flutes, winds
    Drumhead = 3,       // Modal synthesis - drums, membranes
    ShatteredGlass = 4  // Chaotic modal synthesis - glass breaking/shattering
};

/// Voice envelope state
enum class EnvelopeState {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release
};

/// Filter types
enum class VoiceFilterType {
    None = 0,
    LowPass,
    HighPass,
    BandPass
};

/// LFO waveform types
enum class LFOWaveform {
    Sine = 0,
    Triangle,
    Square,
    Sawtooth,
    SampleAndHold  // Random stepped values
};

/// Low Frequency Oscillator state
struct LFO {
    bool enabled;
    LFOWaveform waveform;
    float rate;          // Frequency in Hz
    float phase;         // Current phase (0.0 to 1.0)
    float lastValue;     // Last output value (for sample & hold)
    
    LFO()
        : enabled(false)
        , waveform(LFOWaveform::Sine)
        , rate(5.0f)
        , phase(0.0f)
        , lastValue(0.0f)
    {}
    
    /// Update phase based on delta time
    void updatePhase(float deltaTime);
    
    /// Get current LFO value (-1.0 to 1.0)
    float getValue(uint32_t& randomState);
    
    /// Reset phase to 0
    void reset() { phase = 0.0f; }
};

/// LFO routing for a voice (which LFO affects what parameter)
struct LFORouting {
    // Each value is LFO number (1-based, 0 = no routing)
    // Depth values control modulation amount
    int pitchLFO;           // LFO for pitch modulation (vibrato)
    float pitchDepthCents;  // Pitch modulation depth in cents
    
    int volumeLFO;          // LFO for volume modulation (tremolo)
    float volumeDepth;      // Volume modulation depth (0.0 to 1.0)
    
    int filterLFO;          // LFO for filter cutoff modulation
    float filterDepthHz;    // Filter modulation depth in Hz
    
    int pulseWidthLFO;      // LFO for pulse width modulation
    float pulseWidthDepth;  // Pulse width modulation depth (0.0 to 1.0)
    
    LFORouting()
        : pitchLFO(0)
        , pitchDepthCents(0.0f)
        , volumeLFO(0)
        , volumeDepth(0.0f)
        , filterLFO(0)
        , filterDepthHz(0.0f)
        , pulseWidthLFO(0)
        , pulseWidthDepth(0.0f)
    {}
};

/// ADSR envelope parameters (in milliseconds)
struct VoiceEnvelope {
    float attackMs;      // Attack time in milliseconds
    float decayMs;       // Decay time in milliseconds
    float sustainLevel;  // Sustain level (0.0 to 1.0)
    float releaseMs;     // Release time in milliseconds
    
    VoiceEnvelope()
        : attackMs(10.0f)
        , decayMs(50.0f)
        , sustainLevel(0.7f)
        , releaseMs(100.0f)
    {}
};

/// Single voice state
struct Voice {
    // Identity
    int voiceNumber;
    bool active;
    
    // Waveform
    VoiceWaveform waveform;
    VoiceWaveform waveform2;   // Second waveform for combination
    bool combineWaveforms;     // Enable waveform combination
    float pulseWidth;          // For pulse wave (0.0 to 1.0, 0.5 = square)
    
    // Frequency/pitch
    float frequency;       // In Hz
    float targetFrequency; // Target frequency for portamento
    float portamentoTime;  // Portamento time in seconds (0 = instant)
    float portamentoProgress; // Current progress (0.0 to 1.0)
    float detuneCents;     // Detune in cents (+/- 100 cents = 1 semitone)
    float phase;           // Current phase (0.0 to 1.0)
    
    // SID-style modulation
    int ringModSource;     // Voice number to ring modulate with (0 = none)
    int syncSource;        // Voice number to sync to (0 = none)
    bool testBit;          // Test bit - resets and holds oscillator
    
    // Envelope
    VoiceEnvelope envelope;
    EnvelopeState envelopeState;
    float envelopeLevel;   // Current envelope level (0.0 to 1.0)
    float releaseStartLevel; // Envelope level captured when release begins
    float envelopeTime;    // Time in current envelope state (seconds)
    
    // Gate
    bool gateOn;           // Gate state (on = playing, off = releasing)
    float autoGateTime;    // Auto-gate timer (0 = disabled, >0 = time remaining)
    
    // Volume
    float volume;          // Voice volume (0.0 to 1.0)
    
    // Stereo positioning
    float pan;             // Pan position (-1.0 = left, 0.0 = center, 1.0 = right)
    
    // Delay effect
    bool delayEnabled;     // Enable delay effect for this voice
    float delayTime;       // Delay time in seconds (0.0 to 2.0)
    float delayFeedback;   // Delay feedback amount (0.0 to 0.95)
    float delayMix;        // Wet/dry mix (0.0 = dry only, 1.0 = wet only)
    
    // Filter routing
    bool filterEnabled;    // Route through global filter
    
    // LFO routing
    LFORouting lfoRouting;
    
    // Noise state (for noise waveform)
    uint32_t noiseState;
    
    // Physical modeling parameters
    PhysicalModelType physicalModel;  // Type of physical model
    float physicalDamping;            // Damping factor (0.0 to 1.0)
    float physicalBrightness;         // Brightness/harmonics (0.0 to 1.0)
    float physicalExcitation;         // Excitation strength (0.0 to 1.0)
    float physicalResonance;          // Body resonance (0.0 to 1.0)
    float physicalTension;            // String tension (0.0 to 1.0, for string models)
    float physicalPressure;           // Air pressure (0.0 to 1.0, for tube models)
    bool physicalTriggered;           // Has physical model been triggered
    std::vector<float> physicalDelayLine;  // Delay line for physical modeling
    int physicalDelayPos;             // Write position in delay line
    float physicalLastSample;         // Last sample for filtering
    
    Voice()
        : voiceNumber(0)
        , active(false)
        , waveform(VoiceWaveform::Sine)
        , waveform2(VoiceWaveform::Silence)
        , combineWaveforms(false)
        , pulseWidth(0.5f)
        , frequency(440.0f)
        , targetFrequency(440.0f)
        , portamentoTime(0.0f)
        , portamentoProgress(1.0f)
        , detuneCents(0.0f)
        , phase(0.0f)
        , ringModSource(0)
        , syncSource(0)
        , testBit(false)
        , envelopeState(EnvelopeState::Idle)
        , envelopeLevel(0.0f)
        , releaseStartLevel(0.0f)
        , envelopeTime(0.0f)
        , gateOn(false)
        , autoGateTime(0.0f)
        , volume(1.0f)
        , pan(0.0f)
        , delayEnabled(false)
        , delayTime(0.25f)
        , delayFeedback(0.3f)
        , delayMix(0.5f)
        , filterEnabled(false)
        , noiseState(0xACE1u)
        , physicalModel(PhysicalModelType::PluckedString)
        , physicalDamping(0.1f)
        , physicalBrightness(0.5f)
        , physicalExcitation(1.0f)
        , physicalResonance(0.3f)
        , physicalTension(0.8f)
        , physicalPressure(0.7f)
        , physicalTriggered(false)
        , physicalDelayPos(0)
        , physicalLastSample(0.0f)
    {}
    
    /// Generate next sample for this voice
    float generateSample(float deltaTime, float sampleRate, const std::vector<Voice>& allVoices);
    
    /// Update envelope
    void updateEnvelope(float deltaTime);
    
    /// Update portamento
    void updatePortamento(float deltaTime);
    
    /// Update auto-gate
    void updateAutoGate(float deltaTime);
};

/// Global filter state (shared across voices)
struct VoiceFilter {
    VoiceFilterType type;
    float cutoffHz;
    float resonance;
    bool enabled;
    
    // Filter state variables (biquad)
    float x1, x2;  // Input history
    float y1, y2;  // Output history
    
    // Biquad coefficients
    float b0, b1, b2, a1, a2;
    
    VoiceFilter()
        : type(VoiceFilterType::LowPass)
        , cutoffHz(2000.0f)
        , resonance(1.0f)
        , enabled(false)
        , x1(0.0f), x2(0.0f)
        , y1(0.0f), y2(0.0f)
        , b0(1.0f), b1(0.0f), b2(0.0f)
        , a1(0.0f), a2(0.0f)
    {}
    
    /// Update filter coefficients based on current parameters
    void updateCoefficients(float sampleRate);
    
    /// Process a sample through the filter
    float process(float input);
    
    /// Reset filter state
    void reset();
};

/// Voice Controller - Manages persistent voices for SID-style programming
class VoiceController {
public:
    /// Constructor
    /// @param maxVoices Maximum number of simultaneous voices
    /// @param sampleRate Audio sample rate
    VoiceController(int maxVoices = 8, float sampleRate = 48000.0f);
    
    /// Destructor
    ~VoiceController();
    
    // Disable copy
    VoiceController(const VoiceController&) = delete;
    VoiceController& operator=(const VoiceController&) = delete;
    
    // =========================================================================
    // Voice Control
    // =========================================================================
    
    /// Set voice waveform
    /// @param voiceNum Voice number (1-based)
    /// @param waveform Waveform type
    void setWaveform(int voiceNum, VoiceWaveform waveform);
    
    /// Set voice frequency
    /// @param voiceNum Voice number (1-based)
    /// @param frequencyHz Frequency in Hz
    void setFrequency(int voiceNum, float frequencyHz);
    
    /// Set voice note (by MIDI note number)
    /// @param voiceNum Voice number (1-based)
    /// @param midiNote MIDI note number (0-127, middle C = 60)
    void setNote(int voiceNum, int midiNote);
    
    /// Set voice note (by note name)
    /// @param voiceNum Voice number (1-based)
    /// @param noteName Note name (e.g., "C-4", "A#3", "Gb5")
    void setNoteName(int voiceNum, const std::string& noteName);
    
    /// Set voice envelope (ADSR)
    /// @param voiceNum Voice number (1-based)
    /// @param attackMs Attack time in milliseconds
    /// @param decayMs Decay time in milliseconds
    /// @param sustainLevel Sustain level (0.0 to 1.0)
    /// @param releaseMs Release time in milliseconds
    void setEnvelope(int voiceNum, float attackMs, float decayMs, 
                     float sustainLevel, float releaseMs);
    
    /// Set voice gate (on = start/sustain, off = release)
    /// @param voiceNum Voice number (1-based)
    /// @param gateOn Gate state
    void setGate(int voiceNum, bool gateOn);
    
    /// Set voice volume
    /// @param voiceNum Voice number (1-based)
    /// @param volume Volume level (0.0 to 1.0)
    void setVolume(int voiceNum, float volume);
    
    /// Set voice pan position
    /// @param voiceNum Voice number (1-based)
    /// @param pan Pan position (-1.0 = left, 0.0 = center, 1.0 = right)
    void setPan(int voiceNum, float pan);
    
    /// Set pulse width (for pulse waveform)
    /// @param voiceNum Voice number (1-based)
    /// @param pulseWidth Pulse width (0.0 to 1.0, 0.5 = square wave)
    void setPulseWidth(int voiceNum, float pulseWidth);
    
    /// Enable/disable filter routing for voice
    /// @param voiceNum Voice number (1-based)
    /// @param enabled Route through filter
    void setFilterRouting(int voiceNum, bool enabled);
    
    /// Set ring modulation source
    /// @param voiceNum Voice number (1-based)
    /// @param sourceVoice Voice number to ring modulate with (0 = disable)
    void setRingMod(int voiceNum, int sourceVoice);
    
    /// Set oscillator sync source
    /// @param voiceNum Voice number (1-based)
    /// @param sourceVoice Voice number to sync to (0 = disable)
    void setSync(int voiceNum, int sourceVoice);
    
    /// Set test bit (oscillator reset/hold)
    /// @param voiceNum Voice number (1-based)
    /// @param testOn Test bit state
    void setTestBit(int voiceNum, bool testOn);
    
    /// Set waveform combination
    /// @param voiceNum Voice number (1-based)
    /// @param waveform1 First waveform
    /// @param waveform2 Second waveform (Silence to disable combination)
    void setWaveformCombination(int voiceNum, VoiceWaveform waveform1, VoiceWaveform waveform2);
    
    /// Set portamento time
    /// @param voiceNum Voice number (1-based)
    /// @param timeSeconds Glide time in seconds (0 = instant)
    void setPortamento(int voiceNum, float timeSeconds);
    
    /// Set detune
    /// @param voiceNum Voice number (1-based)
    /// @param cents Detune in cents (+/- 100 cents = 1 semitone)
    void setDetune(int voiceNum, float cents);
    
    // =========================================================================
    // Delay Effect Control
    // =========================================================================
    
    /// Enable/disable delay effect for voice
    /// @param voiceNum Voice number (1-based)
    /// @param enabled Enable delay
    void setDelayEnabled(int voiceNum, bool enabled);
    
    /// Set delay time
    /// @param voiceNum Voice number (1-based)
    /// @param timeSeconds Delay time in seconds (0.0 to 2.0)
    void setDelayTime(int voiceNum, float timeSeconds);
    
    /// Set delay feedback
    /// @param voiceNum Voice number (1-based)
    /// @param feedback Feedback amount (0.0 to 0.95)
    void setDelayFeedback(int voiceNum, float feedback);
    
    /// Set delay wet/dry mix
    /// @param voiceNum Voice number (1-based)
    /// @param mix Wet/dry mix (0.0 = dry only, 1.0 = wet only)
    void setDelayMix(int voiceNum, float mix);
    
    /// Play note with automatic gate-off after duration
    /// @param voiceNum Voice number (1-based)
    /// @param midiNote MIDI note number (0-127)
    /// @param durationSeconds Duration in seconds
    void playNote(int voiceNum, int midiNote, float durationSeconds);
    
    // =========================================================================
    // Physical Modeling Control
    // =========================================================================
    
    /// Set physical model type
    /// @param voiceNum Voice number (1-based)
    /// @param modelType Physical model type
    void setPhysicalModel(int voiceNum, PhysicalModelType modelType);
    
    /// Set physical model damping
    /// @param voiceNum Voice number (1-based)
    /// @param damping Damping factor (0.0 to 1.0)
    void setPhysicalDamping(int voiceNum, float damping);
    
    /// Set physical model brightness
    /// @param voiceNum Voice number (1-based)
    /// @param brightness Brightness/harmonics (0.0 to 1.0)
    void setPhysicalBrightness(int voiceNum, float brightness);
    
    /// Set physical model excitation strength
    /// @param voiceNum Voice number (1-based)
    /// @param excitation Excitation strength (0.0 to 1.0)
    void setPhysicalExcitation(int voiceNum, float excitation);
    
    /// Set physical model resonance
    /// @param voiceNum Voice number (1-based)
    /// @param resonance Body resonance (0.0 to 1.0)
    void setPhysicalResonance(int voiceNum, float resonance);
    
    /// Set physical model string tension (for string models)
    /// @param voiceNum Voice number (1-based)
    /// @param tension String tension (0.0 to 1.0)
    void setPhysicalTension(int voiceNum, float tension);
    
    /// Set physical model air pressure (for tube models)
    /// @param voiceNum Voice number (1-based)
    /// @param pressure Air pressure (0.0 to 1.0)
    void setPhysicalPressure(int voiceNum, float pressure);
    
    /// Trigger physical model excitation
    /// @param voiceNum Voice number (1-based)
    void triggerPhysical(int voiceNum);
    
    // =========================================================================
    // Global Filter Control
    // =========================================================================
    
    /// Set global filter type
    /// @param type Filter type
    void setFilterType(VoiceFilterType type);
    
    /// Set global filter cutoff frequency
    /// @param cutoffHz Cutoff frequency in Hz
    void setFilterCutoff(float cutoffHz);
    
    /// Set global filter resonance
    /// @param resonance Resonance (1.0 = none, higher = more resonant)
    void setFilterResonance(float resonance);
    
    /// Enable/disable global filter
    /// @param enabled Filter enabled
    void setFilterEnabled(bool enabled);
    
    // =========================================================================
    // Global Control
    // =========================================================================
    
    /// Set master volume
    /// @param volume Master volume (0.0 to 1.0)
    void setMasterVolume(float volume);
    
    /// Get master volume
    /// @return Master volume (0.0 to 1.0)
    float getMasterVolume() const { return m_masterVolume; }
    
    // =========================================================================
    // LFO Control
    // =========================================================================
    
    /// Set LFO waveform
    /// @param lfoNum LFO number (1-based, 1-4)
    /// @param waveform LFO waveform type
    void setLFOWaveform(int lfoNum, LFOWaveform waveform);
    
    /// Set LFO rate (frequency)
    /// @param lfoNum LFO number (1-based, 1-4)
    /// @param rateHz Rate in Hz
    void setLFORate(int lfoNum, float rateHz);
    
    /// Reset LFO phase to 0
    /// @param lfoNum LFO number (1-based, 1-4)
    void resetLFO(int lfoNum);
    
    /// Route LFO to voice pitch (vibrato)
    /// @param voiceNum Voice number (1-based)
    /// @param lfoNum LFO number (1-based, 0 = disable)
    /// @param depthCents Modulation depth in cents
    void setLFOToPitch(int voiceNum, int lfoNum, float depthCents);
    
    /// Route LFO to voice volume (tremolo)
    /// @param voiceNum Voice number (1-based)
    /// @param lfoNum LFO number (1-based, 0 = disable)
    /// @param depth Modulation depth (0.0 to 1.0)
    void setLFOToVolume(int voiceNum, int lfoNum, float depth);
    
    /// Route LFO to filter cutoff
    /// @param voiceNum Voice number (1-based)
    /// @param lfoNum LFO number (1-based, 0 = disable)
    /// @param depthHz Modulation depth in Hz
    void setLFOToFilter(int voiceNum, int lfoNum, float depthHz);
    
    /// Route LFO to pulse width
    /// @param voiceNum Voice number (1-based)
    /// @param lfoNum LFO number (1-based, 0 = disable)
    /// @param depth Modulation depth (0.0 to 1.0)
    void setLFOToPulseWidth(int voiceNum, int lfoNum, float depth);
    
    /// Reset all voices (gate off, clear state)
    void resetAllVoices();
    
    /// Get number of active voices
    /// @return Number of voices with gate on
    int getActiveVoiceCount() const;
    
    /// Set render mode (direct to WAV file or live playback)
    /// @param enable Enable render-to-file mode
    /// @param outputPath WAV file path for rendering (ignored if enable=false)
    void setRenderMode(bool enable, const std::string& outputPath);
    
    // =========================================================================
    // Audio Generation
    // =========================================================================
    
    /// Generate audio samples (called by audio system)
    /// @param outBuffer Output buffer (stereo interleaved)
    /// @param frameCount Number of stereo frames to generate
    void generateAudio(float* outBuffer, int frameCount);
    
    /// Set sample rate (called when audio system changes rate)
    /// @param sampleRate New sample rate
    void setSampleRate(float sampleRate);
    
    /// Get sample rate
    /// @return Current sample rate
    float getSampleRate() const { return m_sampleRate; }
    
private:
    /// Get voice by number (1-based), returns nullptr if invalid
    Voice* getVoice(int voiceNum);
    
    /// Convert MIDI note to frequency
    static float midiNoteToFrequency(int midiNote);
    
    /// Convert note name to MIDI note number
    static int noteNameToMidiNote(const std::string& noteName);
    
    /// Generate waveform sample
    static float generateWaveformSample(VoiceWaveform waveform, float phase, 
                                       float pulseWidth, uint32_t& noiseState);
    
    /// Combine two waveform samples
    static float combineWaveformSamples(float sample1, float sample2);
    
    /// Mix all voices and process filter
    float mixVoices(float deltaTime);
    
    /// Get voice phase (for sync/ring mod)
    float getVoicePhase(int voiceNum) const;
    
    /// Get voice output (for ring mod)
    float getVoiceOutput(int voiceNum) const;
    
    // Voice array
    std::vector<Voice> m_voices;
    int m_maxVoices;
    
    // Global filter
    VoiceFilter m_filter;
    
    // Audio parameters
    float m_sampleRate;
    
    // Delay buffers (per voice)
    struct DelayBuffer {
        std::vector<float> bufferL;    // Left channel delay buffer
        std::vector<float> bufferR;    // Right channel delay buffer
        int writePos;                   // Current write position
        int maxSize;                    // Maximum buffer size in samples
        
        DelayBuffer() : writePos(0), maxSize(0) {}
        
        void resize(int sampleRate, float maxDelayTime) {
            maxSize = static_cast<int>(sampleRate * maxDelayTime);
            bufferL.resize(maxSize, 0.0f);
            bufferR.resize(maxSize, 0.0f);
            writePos = 0;
        }
        
        void clear() {
            std::fill(bufferL.begin(), bufferL.end(), 0.0f);
            std::fill(bufferR.begin(), bufferR.end(), 0.0f);
            writePos = 0;
        }
        
        void write(float left, float right) {
            if (maxSize > 0) {
                bufferL[writePos] = left;
                bufferR[writePos] = right;
                writePos = (writePos + 1) % maxSize;
            }
        }
        
        void read(float delaySamples, float& left, float& right) const {
            if (maxSize == 0 || delaySamples <= 0) {
                left = right = 0.0f;
                return;
            }
            
            // Calculate read position with interpolation
            int delayInt = static_cast<int>(delaySamples);
            float delayFrac = delaySamples - delayInt;
            
            int readPos = writePos - delayInt;
            if (readPos < 0) readPos += maxSize;
            
            int readPos2 = readPos - 1;
            if (readPos2 < 0) readPos2 += maxSize;
            
            // Linear interpolation
            left = bufferL[readPos] * (1.0f - delayFrac) + bufferL[readPos2] * delayFrac;
            right = bufferR[readPos] * (1.0f - delayFrac) + bufferR[readPos2] * delayFrac;
        }
    };
    
    std::vector<DelayBuffer> m_delayBuffers;
    
    // LFO array (4 global LFOs)
    static constexpr int MAX_LFOS = 4;
    std::array<LFO, MAX_LFOS> m_lfos;
    uint32_t m_lfoRandomState;  // Random state for sample & hold LFOs
    
    // Master volume
    float m_masterVolume;
    
    // Render mode (WAV file output vs live playback)
    bool m_renderMode;
    std::string m_renderOutputPath;
    std::vector<float> m_renderBuffer;  // Accumulated audio for rendering
    
    // Thread safety
    mutable std::mutex m_mutex;
    
    // LFO helpers
    LFO* getLFO(int lfoNum);
    float getLFOValue(int lfoNum);
    void updateLFOs(float deltaTime);
    
    // Delay helpers
    void initializeDelayBuffers();
    void processVoiceDelay(Voice& voice, DelayBuffer& delayBuffer, float& outLeft, float& outRight);
};

} // namespace SuperTerminal

#endif // SUPERTERMINAL_VOICE_CONTROLLER_H