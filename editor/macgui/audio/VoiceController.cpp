//
//  VoiceController.cpp
//  SuperTerminal Framework - Persistent Voice Controller
//
//  SID-style voice control system for advanced audio programming
//  Implementation of continuous voice synthesis
//
//  Copyright © 2024 SuperTerminal. All rights reserved.
//  Copyright © 2026 Alban and Friends. All rights reserved.
//

#include "VoiceController.h"
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>

namespace SuperTerminal {

// Debug logging to file
static std::ofstream g_voiceControllerLog;
static bool g_voiceLogInitialized = false;

static bool isVoiceLoggingEnabled() {
    static bool enabled = []() {
        const char* v = std::getenv("FB_VOICE_LOG");
        return v != nullptr && v[0] != '\0' && v[0] != '0';
    }();
    return enabled;
}

static void initVoiceControllerLog() {
    if (!isVoiceLoggingEnabled()) {
        g_voiceLogInitialized = true;
        return;
    }
    if (!g_voiceLogInitialized) {
        g_voiceControllerLog.open("/tmp/voicecontroller_debug.log", std::ios::out | std::ios::trunc);
        if (g_voiceControllerLog.is_open()) {
            g_voiceControllerLog << "=== VoiceController Debug Log ===" << std::endl;
        }
        g_voiceLogInitialized = true;
    }
}

static void logVoiceController(const std::string& message) {
    if (!isVoiceLoggingEnabled()) {
        return;
    }
    if (!g_voiceLogInitialized) {
        initVoiceControllerLog();
    }
    if (g_voiceControllerLog.is_open()) {
        g_voiceControllerLog << message << std::endl;
    }
}

// =============================================================================
// MARK: - Constants
// =============================================================================

static constexpr float PI = 3.14159265358979323846f;
static constexpr float TWO_PI = 2.0f * PI;

static bool writeStereoFloatToWav(const std::string& path,
                                  const std::vector<float>& interleaved,
                                  uint32_t sampleRate) {
    if (path.empty() || sampleRate == 0 || interleaved.empty() || (interleaved.size() % 2) != 0) {
        return false;
    }

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
        return false;
    }

    const uint16_t channels = 2;
    const uint16_t bitsPerSample = 16;
    const uint32_t bytesPerSample = bitsPerSample / 8;
    const uint32_t dataSize = static_cast<uint32_t>((interleaved.size() / 2) * channels * bytesPerSample);
    const uint32_t fmtChunkSize = 16;
    const uint32_t riffSize = 4 + (8 + fmtChunkSize) + (8 + dataSize);
    const uint32_t byteRate = sampleRate * channels * bytesPerSample;
    const uint16_t blockAlign = channels * bytesPerSample;

    out.write("RIFF", 4);
    out.write(reinterpret_cast<const char*>(&riffSize), sizeof(riffSize));
    out.write("WAVE", 4);
    out.write("fmt ", 4);
    out.write(reinterpret_cast<const char*>(&fmtChunkSize), sizeof(fmtChunkSize));

    const uint16_t audioFormat = 1; // PCM
    out.write(reinterpret_cast<const char*>(&audioFormat), sizeof(audioFormat));
    out.write(reinterpret_cast<const char*>(&channels), sizeof(channels));
    out.write(reinterpret_cast<const char*>(&sampleRate), sizeof(sampleRate));
    out.write(reinterpret_cast<const char*>(&byteRate), sizeof(byteRate));
    out.write(reinterpret_cast<const char*>(&blockAlign), sizeof(blockAlign));
    out.write(reinterpret_cast<const char*>(&bitsPerSample), sizeof(bitsPerSample));

    out.write("data", 4);
    out.write(reinterpret_cast<const char*>(&dataSize), sizeof(dataSize));

    for (float sample : interleaved) {
        const float clamped = std::max(-1.0f, std::min(1.0f, sample));
        const int16_t pcm = static_cast<int16_t>(clamped * 32767.0f);
        out.write(reinterpret_cast<const char*>(&pcm), sizeof(pcm));
    }

    return out.good();
}

// =============================================================================
// MARK: - LFO Implementation
// =============================================================================

void LFO::updatePhase(float deltaTime) {
    if (!enabled) return;
    
    // Update phase based on rate
    phase += rate * deltaTime;
    
    // Wrap phase to [0, 1)
    while (phase >= 1.0f) {
        phase -= 1.0f;
    }
}

float LFO::getValue(uint32_t& randomState) {
    if (!enabled) return 0.0f;
    
    switch (waveform) {
        case LFOWaveform::Sine:
            return std::sin(phase * TWO_PI);
            
        case LFOWaveform::Triangle:
            if (phase < 0.5f) {
                return 4.0f * phase - 1.0f;  // Rising edge
            } else {
                return 3.0f - 4.0f * phase;  // Falling edge
            }
            
        case LFOWaveform::Square:
            return (phase < 0.5f) ? 1.0f : -1.0f;
            
        case LFOWaveform::Sawtooth:
            return 2.0f * phase - 1.0f;
            
        case LFOWaveform::SampleAndHold: {
            // Generate new random value at phase wrap
            float newPhase = phase + 0.01f;  // Check if we wrapped
            if (newPhase >= 1.0f || phase < 0.01f) {
                // Generate new random value
                randomState = (randomState >> 1) ^ (-(randomState & 1u) & 0xB400u);
                lastValue = ((randomState & 0xFFFF) / 32768.0f) - 1.0f;
            }
            return lastValue;
        }
    }
    
    return 0.0f;
}

// =============================================================================
// MARK: - Voice Implementation
// =============================================================================

float Voice::generateSample(float deltaTime, float sampleRate, const std::vector<Voice>& allVoices) {
    static int debugCount = 0;
    debugCount++;

    // Update auto-gate timer
    updateAutoGate(deltaTime);

    // Update portamento
    updatePortamento(deltaTime);

    // Test bit - reset and hold oscillator
    if (testBit) {
        phase = 0.0f;
        return 0.0f;
    }

    if (!active) {
        if (debugCount % 48000 == 0 && voiceNumber == 1) {
            char buf[128];
            snprintf(buf, sizeof(buf), "Voice %d generateSample: NOT ACTIVE (gateOn=%d)", voiceNumber, gateOn);
            logVoiceController(buf);
        }
        return 0.0f;
    }

    // Update envelope
    updateEnvelope(deltaTime);

    if (!gateOn && envelopeLevel <= 0.0f) {
        if (debugCount % 48000 == 0 && voiceNumber == 1) {
            char buf[128];
            snprintf(buf, sizeof(buf), "Voice %d generateSample: gate off and envelope=0", voiceNumber);
            logVoiceController(buf);
        }
        return 0.0f;
    }

    if (debugCount % 48000 == 0 && voiceNumber == 1) {
        char buf[256];
        snprintf(buf, sizeof(buf), "Voice %d generateSample: active=%d, gateOn=%d, envelopeLevel=%.3f, freq=%.1f, waveform=%d",
                voiceNumber, active, gateOn, envelopeLevel, frequency, static_cast<int>(waveform));
        logVoiceController(buf);
    }

    // Calculate effective frequency with detune and LFO
    float effectiveFreq = frequency;
    if (detuneCents != 0.0f) {
        effectiveFreq *= std::pow(2.0f, detuneCents / 1200.0f);
    }
    
    // Apply LFO pitch modulation (vibrato) - handled by VoiceController
    // This is applied during mixVoices to avoid voice-to-voice dependencies

    // Advance phase
    phase += effectiveFreq / sampleRate;

    // Wrap phase
    while (phase >= 1.0f) {
        phase -= 1.0f;
    }

    // Check for sync - if sync source just wrapped, reset our phase
    if (syncSource > 0 && syncSource <= static_cast<int>(allVoices.size())) {
        // Defensive check: prevent self-sync
        if (syncSource != voiceNumber) {
            const Voice& syncVoice = allVoices[syncSource - 1];
            // Sync happens when master oscillator wraps (phase goes from high to low)
            // We need to detect if the sync voice crossed zero this sample
            // This is a simplification - real implementation would need per-sample sync
            if (syncVoice.active && !syncVoice.testBit) {
            float syncOldPhase = syncVoice.phase - (syncVoice.frequency / sampleRate);
            if (syncOldPhase >= 1.0f || (syncOldPhase < 1.0f && syncVoice.phase < syncOldPhase)) {
                    phase = 0.0f;
                }
            }
        }
    }

    // Generate waveform sample
    float sample = 0.0f;

    switch (waveform) {
        case VoiceWaveform::Silence:
            sample = 0.0f;
            break;

        case VoiceWaveform::Sine:
            sample = std::sin(phase * TWO_PI);
            break;

        case VoiceWaveform::Square:
            sample = (phase < 0.5f) ? 1.0f : -1.0f;
            break;

        case VoiceWaveform::Sawtooth:
            sample = 2.0f * phase - 1.0f;
            break;

        case VoiceWaveform::Triangle:
            sample = (phase < 0.5f) ? (4.0f * phase - 1.0f) : (3.0f - 4.0f * phase);
            break;

        case VoiceWaveform::Noise:
            // Linear feedback shift register for noise
            noiseState = (noiseState >> 1) ^ (-(noiseState & 1u) & 0xB400u);
            sample = ((noiseState & 0xFFFF) / 32768.0f) - 1.0f;
            break;

        case VoiceWaveform::Pulse:
            sample = (phase < pulseWidth) ? 1.0f : -1.0f;
            break;

        case VoiceWaveform::Physical:
            // Physical modeling synthesis
            if (!physicalTriggered) {
                sample = 0.0f;
            } else {
                int delayLength = static_cast<int>(physicalDelayLine.size());
                
                switch (physicalModel) {
                    case PhysicalModelType::PluckedString: {
                        // Karplus-Strong algorithm
                        int readPos = (physicalDelayPos + 1) % delayLength;
                        float currentSample = physicalDelayLine[readPos];
                        
                        // Lowpass filter (brightness control)
                        float filterCoeff = 0.5f + (physicalBrightness * 0.49f);
                        float filtered = filterCoeff * currentSample + (1.0f - filterCoeff) * physicalLastSample;
                        physicalLastSample = filtered;
                        
                        // Apply decay and string tension
                        float decayFactor = 1.0f - (physicalDamping * 0.01f) - ((1.0f - physicalTension) * 0.005f);
                        filtered *= decayFactor;
                        
                        // Resonance boost
                        filtered *= (1.0f + physicalResonance * 0.2f);
                        
                        // Write back to delay line
                        physicalDelayLine[physicalDelayPos] = filtered;
                        physicalDelayPos = (physicalDelayPos + 1) % delayLength;
                        
                        sample = filtered * 0.5f;
                        break;
                    }
                    
                    case PhysicalModelType::StruckBar: {
                        // Modal synthesis for metallic bar
                        // Modal ratios from ideal bar physics
                        const int numModes = 6;
                        const float modeRatios[6] = {1.0f, 2.756f, 5.404f, 8.933f, 13.344f, 18.64f};
                        const float modeAmps[6] = {1.0f, 0.5f, 0.25f, 0.15f, 0.1f, 0.05f};
                        
                        // Calculate time since trigger
                        float time = static_cast<float>(physicalDelayPos) / sampleRate;
                        float baseDamping = physicalDamping * 5.0f;
                        
                        sample = 0.0f;
                        for (int mode = 0; mode < numModes; ++mode) {
                            float modeFreq = frequency * modeRatios[mode];
                            float modeDecay = baseDamping * (1.0f + mode * 0.5f);
                            float envelope = std::exp(-modeDecay * time) * physicalExcitation;
                            
                            // Brightness affects higher modes
                            float modeAmp = modeAmps[mode] * (1.0f - (mode * 0.1f * (1.0f - physicalBrightness)));
                            
                            // Resonance boost for fundamental
                            if (mode < 2) {
                                envelope *= (1.0f + physicalResonance * 0.3f);
                            }
                            
                            sample += std::sin(2.0f * TWO_PI * modeFreq * time) * modeAmp * envelope;
                        }
                        
                        physicalDelayPos++;
                        sample *= 0.3f;
                        break;
                    }
                    
                    case PhysicalModelType::BlownTube: {
                        // Waveguide with breath noise
                        int readPos = (physicalDelayPos + 1) % delayLength;
                        float currentSample = physicalDelayLine[readPos];
                        
                        // Lowpass filter
                        float filterCoeff = 0.3f + (physicalBrightness * 0.65f);
                        float filtered = filterCoeff * currentSample + (1.0f - filterCoeff) * physicalLastSample;
                        physicalLastSample = filtered;
                        
                        // Apply decay
                        float decayFactor = 1.0f - (physicalDamping * 0.005f);
                        filtered *= decayFactor;
                        
                        // Add subtle breath noise (continuous excitation)
                        float breathNoise = ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * physicalPressure * 0.005f;
                        filtered += breathNoise * physicalExcitation;
                        
                        // Resonance boost
                        filtered *= (1.0f + physicalResonance * 0.15f);
                        
                        // Write back to delay line
                        physicalDelayLine[physicalDelayPos] = filtered;
                        physicalDelayPos = (physicalDelayPos + 1) % delayLength;
                        
                        sample = filtered * 0.7f;
                        break;
                    }
                    
                    case PhysicalModelType::Drumhead: {
                        // Modal synthesis for circular membrane
                        // Modal ratios from Bessel functions (circular drumhead)
                        const int numModes = 8;
                        const float modeRatios[8] = {1.0f, 1.593f, 2.136f, 2.296f, 2.653f, 2.918f, 3.156f, 3.501f};
                        const float modeAmps[8] = {1.0f, 0.6f, 0.4f, 0.35f, 0.25f, 0.2f, 0.15f, 0.1f};
                        
                        // Calculate time since trigger
                        float time = static_cast<float>(physicalDelayPos) / sampleRate;
                        float baseDamping = 2.0f + (physicalDamping * 8.0f);
                        
                        sample = 0.0f;
                        for (int mode = 0; mode < numModes; ++mode) {
                            float modeFreq = frequency * modeRatios[mode];
                            float modeDecay = baseDamping * (1.0f + mode * 0.3f);
                            float envelope = std::exp(-modeDecay * time) * physicalExcitation;
                            
                            // Brightness affects higher modes
                            float modeAmp = modeAmps[mode] * (1.0f - (mode * 0.08f * (1.0f - physicalBrightness)));
                            
                            // Resonance boost for fundamental
                            if (mode == 0) {
                                envelope *= (1.0f + physicalResonance * 0.4f);
                            }
                            
                            // Phase modulation for attack transient
                            float phase = 2.0f * TWO_PI * modeFreq * time;
                            if (time < 0.01f) {
                                phase += std::sin(2.0f * TWO_PI * frequency * 0.5f * time) * 5.0f * (1.0f - time * 100.0f);
                            }
                            
                            sample += std::sin(phase) * modeAmp * envelope;
                        }
                        
                        // Add initial transient noise for stick attack
                        if (time < 0.005f) {
                            float noiseEnv = (1.0f - time * 200.0f);
                            sample += ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * 0.3f * noiseEnv * physicalExcitation;
                        }
                        
                        physicalDelayPos++;
                        sample *= 0.35f;
                        break;
                    }
                    
                    case PhysicalModelType::ShatteredGlass: {
                        // Chaotic modal synthesis for shattered glass
                        // Many random inharmonic modes with fast decay
                        const int numModes = 16;
                        
                        // Calculate time since trigger
                        float time = static_cast<float>(physicalDelayPos) / sampleRate;
                        float baseDamping = 8.0f + (physicalDamping * 12.0f); // Very fast decay
                        
                        sample = 0.0f;
                        
                        // Seed random with voice number for consistency
                        unsigned int seed = voiceNumber * 12345 + physicalDelayPos / 100;
                        
                        for (int mode = 0; mode < numModes; ++mode) {
                            // Random inharmonic frequency ratios (chaotic, not harmonic)
                            seed = seed * 1103515245 + 12345;
                            float randomRatio = 2.0f + ((seed % 1000) / 100.0f); // 2.0 to 12.0
                            
                            // Higher base frequency for glass
                            float modeFreq = frequency * randomRatio * (2.0f + mode * 0.3f);
                            
                            // Very fast decay, higher modes decay even faster
                            float modeDecay = baseDamping * (1.0f + mode * 0.4f);
                            float envelope = std::exp(-modeDecay * time) * physicalExcitation;
                            
                            // Brightness affects amplitude distribution
                            float modeAmp = 0.5f / (1.0f + mode * (1.0f - physicalBrightness));
                            
                            // Resonance adds slight shimmer
                            if (mode < 4) {
                                envelope *= (1.0f + physicalResonance * 0.2f);
                            }
                            
                            sample += std::sin(2.0f * TWO_PI * modeFreq * time) * modeAmp * envelope;
                        }
                        
                        // Add initial sharp transient noise for the "crack"
                        if (time < 0.003f) {
                            float noiseEnv = (1.0f - time * 333.0f); // Very fast decay
                            sample += ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * 0.6f * noiseEnv * physicalExcitation;
                        }
                        
                        // Add subtle high-frequency noise throughout for glass texture
                        if (time < 0.05f) {
                            float textureNoise = ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * 0.1f;
                            sample += textureNoise * std::exp(-20.0f * time) * physicalBrightness;
                        }
                        
                        physicalDelayPos++;
                        sample *= 0.4f;
                        break;
                    }
                }
            }
            break;
    }

    // Waveform combination
    if (combineWaveforms && waveform2 != VoiceWaveform::Silence) {
        float sample2 = 0.0f;
        switch (waveform2) {
            case VoiceWaveform::Sine:
                sample2 = std::sin(phase * TWO_PI);
                break;
            case VoiceWaveform::Square:
                sample2 = (phase < 0.5f) ? 1.0f : -1.0f;
                break;
            case VoiceWaveform::Sawtooth:
                sample2 = 2.0f * phase - 1.0f;
                break;
            case VoiceWaveform::Triangle:
                sample2 = (phase < 0.5f) ? (4.0f * phase - 1.0f) : (3.0f - 4.0f * phase);
                break;
            case VoiceWaveform::Pulse:
                sample2 = (phase < pulseWidth) ? 1.0f : -1.0f;
                break;
            default:
                sample2 = 0.0f;
                break;
        }
        // Mix waveforms (average to prevent clipping)
        sample = (sample + sample2) * 0.5f;
    }

    // Ring modulation
    if (ringModSource > 0 && ringModSource <= static_cast<int>(allVoices.size())) {
        // Defensive check: ensure we're not ring modulating with ourselves (prevent recursion)
        if (ringModSource == voiceNumber) {
            // Self ring-mod would cause issues, skip it
        } else {
            const Voice& modVoice = allVoices[ringModSource - 1];
            // Only apply ring mod if modulator voice is active
            if (modVoice.active && !modVoice.testBit) {
                // Generate modulator sample
                float modSample = 0.0f;
                switch (modVoice.waveform) {
                case VoiceWaveform::Sine:
                    modSample = std::sin(modVoice.phase * TWO_PI);
                    break;
                case VoiceWaveform::Square:
                    modSample = (modVoice.phase < 0.5f) ? 1.0f : -1.0f;
                    break;
                case VoiceWaveform::Sawtooth:
                    modSample = 2.0f * modVoice.phase - 1.0f;
                    break;
                case VoiceWaveform::Triangle:
                    modSample = (modVoice.phase < 0.5f) ? (4.0f * modVoice.phase - 1.0f) : (3.0f - 4.0f * modVoice.phase);
                    break;
                case VoiceWaveform::Pulse:
                    modSample = (modVoice.phase < modVoice.pulseWidth) ? 1.0f : -1.0f;
                    break;
                default:
                    modSample = 1.0f;
                    break;
                }
                // Ring modulation = multiplication
                sample *= modSample;
            }
        }
    }

    // Apply envelope and volume
    // Note: LFO volume modulation is applied in VoiceController::mixVoices
    sample *= envelopeLevel * volume;

    return sample;
}

void Voice::updateEnvelope(float deltaTime) {
    envelopeTime += deltaTime;

    switch (envelopeState) {
        case EnvelopeState::Idle:
            envelopeLevel = 0.0f;
            if (gateOn) {
                envelopeState = EnvelopeState::Attack;
                envelopeTime = 0.0f;
            }
            break;

        case EnvelopeState::Attack:
            if (envelope.attackMs <= 0.0f) {
                envelopeLevel = 1.0f;
                envelopeState = EnvelopeState::Decay;
                envelopeTime = 0.0f;
            } else {
                float attackTimeSec = envelope.attackMs / 1000.0f;
                envelopeLevel = std::min(1.0f, envelopeTime / attackTimeSec);
                if (envelopeLevel >= 1.0f) {
                    envelopeState = EnvelopeState::Decay;
                    envelopeTime = 0.0f;
                }
            }
            if (!gateOn) {
                releaseStartLevel = envelopeLevel;
                envelopeState = EnvelopeState::Release;
                envelopeTime = 0.0f;
            }
            break;

        case EnvelopeState::Decay:
            if (envelope.decayMs <= 0.0f) {
                envelopeLevel = envelope.sustainLevel;
                envelopeState = EnvelopeState::Sustain;
                envelopeTime = 0.0f;
            } else {
                float decayTimeSec = envelope.decayMs / 1000.0f;
                float decayAmount = 1.0f - envelope.sustainLevel;
                envelopeLevel = 1.0f - (decayAmount * std::min(1.0f, envelopeTime / decayTimeSec));
                if (envelopeTime >= decayTimeSec) {
                    envelopeLevel = envelope.sustainLevel;
                    envelopeState = EnvelopeState::Sustain;
                    envelopeTime = 0.0f;
                }
            }
            if (!gateOn) {
                releaseStartLevel = envelopeLevel;
                envelopeState = EnvelopeState::Release;
                envelopeTime = 0.0f;
            }
            break;

        case EnvelopeState::Sustain:
            envelopeLevel = envelope.sustainLevel;
            if (!gateOn) {
                releaseStartLevel = envelopeLevel;
                envelopeState = EnvelopeState::Release;
                envelopeTime = 0.0f;
            }
            break;

        case EnvelopeState::Release:
            if (envelope.releaseMs <= 0.0f) {
                envelopeLevel = 0.0f;
                envelopeState = EnvelopeState::Idle;
                active = false;
            } else {
                float releaseTimeSec = envelope.releaseMs / 1000.0f;
                float startLevel = releaseStartLevel;
                envelopeLevel = startLevel * (1.0f - std::min(1.0f, envelopeTime / releaseTimeSec));
                if (envelopeTime >= releaseTimeSec) {
                    envelopeLevel = 0.0f;
                    envelopeState = EnvelopeState::Idle;
                    active = false;
                }
            }
            if (gateOn) {
                envelopeState = EnvelopeState::Attack;
                envelopeTime = 0.0f;
            }
            break;
    }
}

void Voice::updatePortamento(float deltaTime) {
    if (portamentoTime <= 0.0f || portamentoProgress >= 1.0f) {
        return;
    }

    // Update progress
    portamentoProgress += deltaTime / portamentoTime;
    if (portamentoProgress >= 1.0f) {
        portamentoProgress = 1.0f;
        frequency = targetFrequency;
    } else {
        // Exponential glide (sounds more musical)
        float startFreq = frequency;
        float ratio = targetFrequency / startFreq;
        frequency = startFreq * std::pow(ratio, portamentoProgress);
    }
}

void Voice::updateAutoGate(float deltaTime) {
    if (autoGateTime > 0.0f) {
        autoGateTime -= deltaTime;
        if (autoGateTime <= 0.0f) {
            gateOn = false;
            autoGateTime = 0.0f;
        }
    }
}

// =============================================================================
// MARK: - VoiceFilter Implementation
// =============================================================================

void VoiceFilter::updateCoefficients(float sampleRate) {
    if (!enabled) {
        return;
    }

    float omega = TWO_PI * cutoffHz / sampleRate;
    float sn = std::sin(omega);
    float cs = std::cos(omega);
    float alpha = sn / (2.0f * resonance);

    switch (type) {
        case VoiceFilterType::LowPass:
            b0 = (1.0f - cs) / 2.0f;
            b1 = 1.0f - cs;
            b2 = (1.0f - cs) / 2.0f;
            a1 = -2.0f * cs;
            a2 = 1.0f - alpha;
            break;

        case VoiceFilterType::HighPass:
            b0 = (1.0f + cs) / 2.0f;
            b1 = -(1.0f + cs);
            b2 = (1.0f + cs) / 2.0f;
            a1 = -2.0f * cs;
            a2 = 1.0f - alpha;
            break;

        case VoiceFilterType::BandPass:
            b0 = alpha;
            b1 = 0.0f;
            b2 = -alpha;
            a1 = -2.0f * cs;
            a2 = 1.0f - alpha;
            break;

        case VoiceFilterType::None:
        default:
            b0 = 1.0f;
            b1 = 0.0f;
            b2 = 0.0f;
            a1 = 0.0f;
            a2 = 0.0f;
            break;
    }

    // Normalize
    float a0 = 1.0f + alpha;
    b0 /= a0;
    b1 /= a0;
    b2 /= a0;
    a1 /= a0;
    a2 /= a0;
}

float VoiceFilter::process(float input) {
    if (!enabled) {
        return input;
    }

    // Biquad filter (Direct Form II)
    float output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;

    // Update history
    x2 = x1;
    x1 = input;
    y2 = y1;
    y1 = output;

    return output;
}

void VoiceFilter::reset() {
    x1 = x2 = y1 = y2 = 0.0f;
}

// =============================================================================
// MARK: - VoiceController Implementation
// =============================================================================

VoiceController::VoiceController(int maxVoices, float sampleRate)
    : m_maxVoices(maxVoices)
    , m_sampleRate(sampleRate)
    , m_lfoRandomState(0xACE1u)
    , m_masterVolume(1.0f)
    , m_renderMode(false)
{
    initVoiceControllerLog();
    char buf[128];
    snprintf(buf, sizeof(buf), "VoiceController created: %d voices, %.0f Hz sample rate", maxVoices, sampleRate);
    logVoiceController(buf);

    m_voices.resize(maxVoices);
    for (int i = 0; i < maxVoices; i++) {
        m_voices[i].voiceNumber = i + 1; // 1-based numbering
        m_voices[i].active = false;
    }
    m_filter.updateCoefficients(sampleRate);
    
    // Initialize delay buffers
    initializeDelayBuffers();
}

VoiceController::~VoiceController() {
    resetAllVoices();
}

// =============================================================================
// MARK: - Voice Control
// =============================================================================

Voice* VoiceController::getVoice(int voiceNum) {
    if (voiceNum < 1 || voiceNum > m_maxVoices) {
        return nullptr;
    }
    return &m_voices[voiceNum - 1];
}

void VoiceController::setWaveform(int voiceNum, VoiceWaveform waveform) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->waveform = waveform;
        char buf[64];
        snprintf(buf, sizeof(buf), "setWaveform: voice=%d, waveform=%d", voiceNum, static_cast<int>(waveform));
        logVoiceController(buf);
    }
}

void VoiceController::setFrequency(int voiceNum, float frequencyHz) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->frequency = std::max(0.0f, std::min(20000.0f, frequencyHz));
    }
}

void VoiceController::setNote(int voiceNum, int midiNote) {
    char buf[128];
    snprintf(buf, sizeof(buf), "setNote: voice=%d, midiNote=%d", voiceNum, midiNote);
    logVoiceController(buf);
    float frequency = midiNoteToFrequency(midiNote);
    setFrequency(voiceNum, frequency);
}

void VoiceController::setNoteName(int voiceNum, const std::string& noteName) {
    int midiNote = noteNameToMidiNote(noteName);
    if (midiNote >= 0) {
        setNote(voiceNum, midiNote);
    }
}

void VoiceController::setEnvelope(int voiceNum, float attackMs, float decayMs,
                                  float sustainLevel, float releaseMs) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->envelope.attackMs = std::max(0.0f, attackMs);
        voice->envelope.decayMs = std::max(0.0f, decayMs);
        voice->envelope.sustainLevel = std::max(0.0f, std::min(1.0f, sustainLevel));
        voice->envelope.releaseMs = std::max(0.0f, releaseMs);
    }
}

void VoiceController::setGate(int voiceNum, bool gateOn) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->gateOn = gateOn;
        if (gateOn) {
            voice->active = true;
            if (voice->envelopeState == EnvelopeState::Idle) {
                voice->envelopeState = EnvelopeState::Attack;
                voice->envelopeTime = 0.0f;
            }
        }
        char buf[128];
        snprintf(buf, sizeof(buf), "setGate: voice=%d, gateOn=%d, active=%d, envelopeState=%d, freq=%.1f",
                voiceNum, gateOn, voice->active, static_cast<int>(voice->envelopeState), voice->frequency);
        logVoiceController(buf);
    }
}

void VoiceController::setVolume(int voiceNum, float volume) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->volume = std::max(0.0f, std::min(1.0f, volume));
    }
}

void VoiceController::setPan(int voiceNum, float pan) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->pan = std::max(-1.0f, std::min(1.0f, pan));
    }
}

void VoiceController::setDetune(int voiceNum, float cents) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->detuneCents = std::max(-1200.0f, std::min(1200.0f, cents));
    }
}

// =============================================================================
// MARK: - Delay Effect Control
// =============================================================================

void VoiceController::setDelayEnabled(int voiceNum, bool enabled) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->delayEnabled = enabled;
        if (!enabled && voiceNum > 0 && voiceNum <= static_cast<int>(m_delayBuffers.size())) {
            m_delayBuffers[voiceNum - 1].clear();
        }
    }
}

void VoiceController::setDelayTime(int voiceNum, float timeSeconds) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->delayTime = std::max(0.0f, std::min(2.0f, timeSeconds));
    }
}

void VoiceController::setDelayFeedback(int voiceNum, float feedback) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->delayFeedback = std::max(0.0f, std::min(0.95f, feedback));
    }
}

void VoiceController::setDelayMix(int voiceNum, float mix) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->delayMix = std::max(0.0f, std::min(1.0f, mix));
    }
}

// =============================================================================
// MARK: - Physical Modeling Control
// =============================================================================

void VoiceController::setPhysicalModel(int voiceNum, PhysicalModelType modelType) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalModel = modelType;
        voice->physicalTriggered = false;
        voice->physicalDelayLine.clear();
        voice->physicalDelayPos = 0;
        voice->physicalLastSample = 0.0f;
    }
}

void VoiceController::setPhysicalDamping(int voiceNum, float damping) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalDamping = std::max(0.0f, std::min(1.0f, damping));
    }
}

void VoiceController::setPhysicalBrightness(int voiceNum, float brightness) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalBrightness = std::max(0.0f, std::min(1.0f, brightness));
    }
}

void VoiceController::setPhysicalExcitation(int voiceNum, float excitation) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalExcitation = std::max(0.0f, std::min(1.0f, excitation));
    }
}

void VoiceController::setPhysicalResonance(int voiceNum, float resonance) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalResonance = std::max(0.0f, std::min(1.0f, resonance));
    }
}

void VoiceController::setPhysicalTension(int voiceNum, float tension) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalTension = std::max(0.0f, std::min(1.0f, tension));
    }
}

void VoiceController::setPhysicalPressure(int voiceNum, float pressure) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->physicalPressure = std::max(0.0f, std::min(1.0f, pressure));
    }
}

void VoiceController::triggerPhysical(int voiceNum) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        char buf[256];
        snprintf(buf, sizeof(buf), "triggerPhysical: voice=%d, freq=%.1f, model=%d, active=%d", 
                 voiceNum, voice->frequency, static_cast<int>(voice->physicalModel), voice->active);
        logVoiceController(buf);
        
        voice->active = true;           // Mark voice as active so it generates sound
        voice->physicalTriggered = true;
        voice->gateOn = true;
        
        // Initialize delay line based on frequency
        float safeFreq = voice->frequency;
        if (!std::isfinite(safeFreq) || safeFreq <= 0.0f) {
            safeFreq = 440.0f;
            voice->frequency = safeFreq;
        }
        int delayLength = static_cast<int>(m_sampleRate / safeFreq);
        if (delayLength < 2) delayLength = 2;
        
        voice->physicalDelayLine.resize(delayLength);
        voice->physicalDelayPos = 0;
        voice->physicalLastSample = 0.0f;
        
        // Initialize with excitation based on model type
        switch (voice->physicalModel) {
            case PhysicalModelType::PluckedString:
            case PhysicalModelType::Drumhead:
                // Noise burst excitation
                for (int i = 0; i < delayLength; ++i) {
                    voice->physicalDelayLine[i] = ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * voice->physicalExcitation;
                }
                break;
                
            case PhysicalModelType::StruckBar:
                // Impulse excitation
                for (int i = 0; i < delayLength; ++i) {
                    voice->physicalDelayLine[i] = 0.0f;
                }
                voice->physicalDelayLine[0] = voice->physicalExcitation;
                break;
                
            case PhysicalModelType::BlownTube:
                // Small noise for wind
                for (int i = 0; i < delayLength; ++i) {
                    voice->physicalDelayLine[i] = ((rand() / (float)RAND_MAX) * 2.0f - 1.0f) * voice->physicalExcitation * 0.1f;
                }
                break;
                
            case PhysicalModelType::ShatteredGlass:
                // Not used - glass uses pure modal synthesis, no delay line needed
                voice->physicalDelayLine.clear();
                break;
        }
    }
}

void VoiceController::initializeDelayBuffers() {
    m_delayBuffers.resize(m_maxVoices);
    for (auto& buffer : m_delayBuffers) {
        buffer.resize(static_cast<int>(m_sampleRate), 2.0f); // 2 second max delay
    }
}

void VoiceController::processVoiceDelay(Voice& voice, DelayBuffer& delayBuffer, float& outLeft, float& outRight) {
    if (!voice.delayEnabled || voice.delayTime <= 0.0f) {
        return;
    }
    
    // Calculate delay in samples
    float delaySamples = voice.delayTime * m_sampleRate;
    
    // Read delayed signal
    float delayLeft, delayRight;
    delayBuffer.read(delaySamples, delayLeft, delayRight);
    
    // Apply feedback and write to delay buffer
    float feedbackLeft = outLeft + delayLeft * voice.delayFeedback;
    float feedbackRight = outRight + delayRight * voice.delayFeedback;
    delayBuffer.write(feedbackLeft, feedbackRight);
    
    // Mix wet and dry signals
    outLeft = outLeft * (1.0f - voice.delayMix) + delayLeft * voice.delayMix;
    outRight = outRight * (1.0f - voice.delayMix) + delayRight * voice.delayMix;
}

void VoiceController::setPulseWidth(int voiceNum, float pulseWidth) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->pulseWidth = std::max(0.01f, std::min(0.99f, pulseWidth));
    }
}

void VoiceController::setFilterRouting(int voiceNum, bool enabled) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->filterEnabled = enabled;
    }
}

void VoiceController::setRingMod(int voiceNum, int sourceVoice) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->ringModSource = sourceVoice;
    }
}

void VoiceController::setSync(int voiceNum, int sourceVoice) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->syncSource = sourceVoice;
    }
}

void VoiceController::setTestBit(int voiceNum, bool testOn) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->testBit = testOn;
        if (testOn) {
            voice->phase = 0.0f;
        }
    }
}

void VoiceController::setWaveformCombination(int voiceNum, VoiceWaveform waveform1, VoiceWaveform waveform2) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->waveform = waveform1;
        voice->waveform2 = waveform2;
        voice->combineWaveforms = (waveform2 != VoiceWaveform::Silence);
    }
}

void VoiceController::setPortamento(int voiceNum, float timeSeconds) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->portamentoTime = timeSeconds;
    }
}



void VoiceController::playNote(int voiceNum, int midiNote, float durationSeconds) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        // Set target frequency for portamento
        float targetFreq = midiNoteToFrequency(midiNote);

        if (voice->portamentoTime > 0.0f) {
            // Portamento enabled - set target and reset progress
            voice->targetFrequency = targetFreq;
            voice->portamentoProgress = 0.0f;
        } else {
            // No portamento - instant change
            voice->frequency = targetFreq;
            voice->targetFrequency = targetFreq;
        }

        // Set gate on
        voice->active = true;
        voice->gateOn = true;

        // Set auto-gate timer
        voice->autoGateTime = durationSeconds;
    }
}

// =============================================================================
// MARK: - Filter Control
// =============================================================================

void VoiceController::setFilterType(VoiceFilterType type) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_filter.type = type;
    m_filter.updateCoefficients(m_sampleRate);
}

void VoiceController::setFilterCutoff(float cutoffHz) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_filter.cutoffHz = std::max(20.0f, std::min(20000.0f, cutoffHz));
    m_filter.updateCoefficients(m_sampleRate);
}

void VoiceController::setFilterResonance(float resonance) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_filter.resonance = std::max(0.1f, std::min(20.0f, resonance));
    m_filter.updateCoefficients(m_sampleRate);
}

void VoiceController::setFilterEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_filter.enabled = enabled;
}

// =============================================================================
// MARK: - Global Control
// =============================================================================

void VoiceController::setMasterVolume(float volume) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_masterVolume = std::max(0.0f, std::min(1.0f, volume));
}

void VoiceController::resetAllVoices() {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto& voice : m_voices) {
        voice.gateOn = false;
        voice.active = false;
        voice.phase = 0.0f;
        voice.envelopeState = EnvelopeState::Idle;
        voice.envelopeLevel = 0.0f;
        voice.releaseStartLevel = 0.0f;
        voice.envelopeTime = 0.0f;
    }
    m_filter.reset();
}

int VoiceController::getActiveVoiceCount() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    int count = 0;
    for (const auto& voice : m_voices) {
        if (voice.active) {
            count++;
        }
    }
    return count;
}

void VoiceController::setRenderMode(bool enable, const std::string& outputPath) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    // If disabling render mode, save accumulated buffer to file
    if (!enable && m_renderMode && !m_renderOutputPath.empty()) {
        const bool wrote = writeStereoFloatToWav(m_renderOutputPath, m_renderBuffer, static_cast<uint32_t>(m_sampleRate));
        char buf[256];
        snprintf(buf, sizeof(buf), "VoiceController: %s %zu samples to %s",
                 wrote ? "Wrote" : "Failed to write",
                 m_renderBuffer.size(),
                 m_renderOutputPath.c_str());
        logVoiceController(buf);
        m_renderBuffer.clear();
    }
    
    m_renderMode = enable;
    m_renderOutputPath = outputPath;
    
    if (enable) {
        m_renderBuffer.clear();
        m_renderBuffer.reserve(m_sampleRate * 60); // Reserve 60 seconds
        char buf[256];
        snprintf(buf, sizeof(buf), "VoiceController: Render mode enabled, output: %s", 
                 outputPath.c_str());
        logVoiceController(buf);
    } else {
        logVoiceController("VoiceController: Render mode disabled, back to live playback");
    }
}

// =============================================================================
// MARK: - LFO Control
// =============================================================================

void VoiceController::setLFOWaveform(int lfoNum, LFOWaveform waveform) {
    std::lock_guard<std::mutex> lock(m_mutex);
    LFO* lfo = getLFO(lfoNum);
    if (lfo) {
        lfo->waveform = waveform;
        lfo->enabled = true;
    }
}

void VoiceController::setLFORate(int lfoNum, float rateHz) {
    std::lock_guard<std::mutex> lock(m_mutex);
    LFO* lfo = getLFO(lfoNum);
    if (lfo) {
        lfo->rate = std::max(0.01f, std::min(100.0f, rateHz));
        lfo->enabled = true;
    }
}

void VoiceController::resetLFO(int lfoNum) {
    std::lock_guard<std::mutex> lock(m_mutex);
    LFO* lfo = getLFO(lfoNum);
    if (lfo) {
        lfo->reset();
    }
}

void VoiceController::setLFOToPitch(int voiceNum, int lfoNum, float depthCents) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->lfoRouting.pitchLFO = lfoNum;
        voice->lfoRouting.pitchDepthCents = depthCents;
    }
}

void VoiceController::setLFOToVolume(int voiceNum, int lfoNum, float depth) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->lfoRouting.volumeLFO = lfoNum;
        voice->lfoRouting.volumeDepth = std::max(0.0f, std::min(1.0f, depth));
    }
}

void VoiceController::setLFOToFilter(int voiceNum, int lfoNum, float depthHz) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->lfoRouting.filterLFO = lfoNum;
        voice->lfoRouting.filterDepthHz = depthHz;
    }
}

void VoiceController::setLFOToPulseWidth(int voiceNum, int lfoNum, float depth) {
    std::lock_guard<std::mutex> lock(m_mutex);
    Voice* voice = getVoice(voiceNum);
    if (voice) {
        voice->lfoRouting.pulseWidthLFO = lfoNum;
        voice->lfoRouting.pulseWidthDepth = std::max(0.0f, std::min(1.0f, depth));
    }
}

// =============================================================================
// MARK: - Audio Generation
// =============================================================================

void VoiceController::generateAudio(float* outBuffer, int frameCount) {
    // Defensive check: NULL buffer
    if (outBuffer == nullptr) {
        logVoiceController("ERROR: generateAudio called with NULL buffer!");
        return;
    }
    
    // Defensive check: invalid frame count
    if (frameCount <= 0 || frameCount > 8192) {
        char buf[128];
        snprintf(buf, sizeof(buf), "ERROR: generateAudio called with invalid frameCount=%d", frameCount);
        logVoiceController(buf);
        return;
    }
    
    std::lock_guard<std::mutex> lock(m_mutex);

    static int audioCallCount = 0;
    audioCallCount++;

    // Log every 120 calls (~2 seconds at 60fps audio callback)
    if (audioCallCount % 120 == 0) {
        int activeVoices = 0;
        for (const auto& voice : m_voices) {
            if (voice.active) activeVoices++;
        }
        char buf[128];
        snprintf(buf, sizeof(buf), "generateAudio call #%d: frameCount=%d, activeVoices=%d, masterVol=%.2f",
                audioCallCount, frameCount, activeVoices, m_masterVolume);
        logVoiceController(buf);
    }

    float deltaTime = 1.0f / m_sampleRate;

    for (int frame = 0; frame < frameCount; frame++) {
        // Update LFOs once per sample
        updateLFOs(deltaTime);
        
        // Initialize stereo mix
        float mixedLeft = 0.0f;
        float mixedRight = 0.0f;
        
        // Process each voice individually with pan and delay
        for (size_t i = 0; i < m_voices.size(); i++) {
            auto& voice = m_voices[i];
            if (!voice.active) continue;
            
            // Defensive check: prevent potential recursion issues
            if (i >= m_voices.size()) {
                logVoiceController("ERROR: Voice index out of bounds during generation!");
                continue;
            }
            
            // Generate voice sample (mono)
            float voiceSample = voice.generateSample(deltaTime, m_sampleRate, m_voices);
            
            // Defensive check: NaN or infinity
            if (std::isnan(voiceSample) || std::isinf(voiceSample)) {
                voiceSample = 0.0f;
            }
            
            // Apply volume
            voiceSample *= voice.volume;
            
            // Apply LFO volume modulation (tremolo)
            if (voice.lfoRouting.volumeLFO > 0) {
                float lfoValue = getLFOValue(voice.lfoRouting.volumeLFO);
                float volumeMod = 1.0f + (lfoValue * voice.lfoRouting.volumeDepth);
                voiceSample *= std::max(0.0f, volumeMod);
            }

            // Apply routed filter while still mono to avoid L/R filter-state crosstalk.
            if (voice.filterEnabled) {
                voiceSample = m_filter.process(voiceSample);
            }
            
            // Apply pan (convert mono to stereo)
            float panLeft, panRight;
            if (voice.pan < 0.0f) {
                // Pan left
                panLeft = 1.0f;
                panRight = 1.0f + voice.pan; // pan=-1 -> right=0, pan=0 -> right=1
            } else {
                // Pan right
                panLeft = 1.0f - voice.pan; // pan=1 -> left=0, pan=0 -> left=1
                panRight = 1.0f;
            }
            
            float outLeft = voiceSample * panLeft;
            float outRight = voiceSample * panRight;
            
            // Apply delay effect if enabled
            if (voice.delayEnabled && i < m_delayBuffers.size()) {
                processVoiceDelay(voice, m_delayBuffers[i], outLeft, outRight);
            }
            
            // Add to stereo mix
            mixedLeft += outLeft;
            mixedRight += outRight;
        }

        // Apply master volume
        mixedLeft *= m_masterVolume;
        mixedRight *= m_masterVolume;

        // Clamp to prevent clipping
        mixedLeft = std::max(-1.0f, std::min(1.0f, mixedLeft));
        mixedRight = std::max(-1.0f, std::min(1.0f, mixedRight));

        // Write stereo output
        outBuffer[frame * 2 + 0] = mixedLeft;
        outBuffer[frame * 2 + 1] = mixedRight;

        if (m_renderMode) {
            m_renderBuffer.push_back(mixedLeft);
            m_renderBuffer.push_back(mixedRight);
        }
    }
}

float VoiceController::mixVoices(float deltaTime) {
    float unfilteredSum = 0.0f;
    float filteredSum = 0.0f;
    int activeCount = 0;
    int nonZeroSamples = 0;

    // Generate and sum all voice samples
    for (auto& voice : m_voices) {
        if (!voice.active) {
            continue;
        }
        
        // Store original values for LFO modulation
        float originalFreq = voice.frequency;
        float originalPW = voice.pulseWidth;
        
        // Apply LFO pitch modulation (temporarily)
        if (voice.lfoRouting.pitchLFO > 0) {
            float lfoValue = getLFOValue(voice.lfoRouting.pitchLFO);
            float cents = lfoValue * voice.lfoRouting.pitchDepthCents;
            voice.frequency *= std::pow(2.0f, cents / 1200.0f);
        }
        
        // Apply LFO pulse width modulation (temporarily)
        if (voice.lfoRouting.pulseWidthLFO > 0 && 
            (voice.waveform == VoiceWaveform::Pulse || voice.waveform2 == VoiceWaveform::Pulse)) {
            float lfoValue = getLFOValue(voice.lfoRouting.pulseWidthLFO);
            float basePW = 0.5f;
            float modulation = lfoValue * voice.lfoRouting.pulseWidthDepth * 0.4f;
            voice.pulseWidth = std::max(0.05f, std::min(0.95f, basePW + modulation));
        }
        
        // Generate sample with LFO-modulated parameters
        float sample = voice.generateSample(deltaTime, m_sampleRate, m_voices);
        
        // Restore original values
        voice.frequency = originalFreq;
        voice.pulseWidth = originalPW;
        
        // Apply LFO volume modulation (tremolo)
        if (voice.lfoRouting.volumeLFO > 0 && sample != 0.0f) {
            float lfoValue = getLFOValue(voice.lfoRouting.volumeLFO);
            // Map LFO [-1, 1] to volume modulation [1-depth, 1+depth]
            float volumeMod = 1.0f + (lfoValue * voice.lfoRouting.volumeDepth);
            volumeMod = std::max(0.0f, volumeMod);
            sample *= volumeMod;
        }

        if (sample != 0.0f) {
            nonZeroSamples++;
            if (voice.filterEnabled) {
                filteredSum += sample;
            } else {
                unfilteredSum += sample;
            }

            if (voice.active) {
                activeCount++;
            }
        }
    }

    static int mixCallCount = 0;
    mixCallCount++;
    if (mixCallCount % 48000 == 0) { // Log once per second at 48kHz
        char buf[128];
        snprintf(buf, sizeof(buf), "mixVoices: activeCount=%d, nonZeroSamples=%d, unfilt=%.3f, filt=%.3f",
                activeCount, nonZeroSamples, unfilteredSum, filteredSum);
        logVoiceController(buf);
    }

    // Apply LFO filter modulation to global filter
    float originalCutoff = m_filter.cutoffHz;
    bool filterModulated = false;
    for (const auto& voice : m_voices) {
        if (voice.active && voice.filterEnabled && voice.lfoRouting.filterLFO > 0) {
            float lfoValue = getLFOValue(voice.lfoRouting.filterLFO);
            float cutoffMod = lfoValue * voice.lfoRouting.filterDepthHz;
            m_filter.cutoffHz = std::max(20.0f, std::min(20000.0f, originalCutoff + cutoffMod));
            m_filter.updateCoefficients(m_sampleRate);
            filterModulated = true;
            break;  // Only use first voice's filter LFO routing
        }
    }
    
    // Process filtered voices through filter
    if (m_filter.enabled && filteredSum != 0.0f) {
        filteredSum = m_filter.process(filteredSum);
    }
    
    // Restore original filter cutoff if modulated
    if (filterModulated) {
        m_filter.cutoffHz = originalCutoff;
        m_filter.updateCoefficients(m_sampleRate);
    }

    // Mix filtered and unfiltered
    float mixed = unfilteredSum + filteredSum;

    // Simple auto-gain to prevent clipping with multiple voices
    if (activeCount > 1) {
        mixed /= std::sqrt(static_cast<float>(activeCount));
    }

    return mixed;
}

void VoiceController::setSampleRate(float sampleRate) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_sampleRate = sampleRate;
    m_filter.updateCoefficients(sampleRate);
}



// =============================================================================
// MARK: - Helper Functions
// =============================================================================

float VoiceController::midiNoteToFrequency(int midiNote) {
    // MIDI note 69 = A4 = 440 Hz
    // Frequency = 440 * 2^((midiNote - 69) / 12)
    return 440.0f * std::pow(2.0f, (midiNote - 69) / 12.0f);
}

int VoiceController::noteNameToMidiNote(const std::string& noteName) {
    if (noteName.empty()) {
        return -1;
    }

    // Parse note name (e.g., "C-4", "A#3", "Gb5")
    int noteIndex = -1;
    int accidental = 0; // 0 = natural, 1 = sharp, -1 = flat
    int octave = 4;     // Default to octave 4

    // Parse note letter
    char noteLetter = std::toupper(noteName[0]);
    switch (noteLetter) {
        case 'C': noteIndex = 0; break;
        case 'D': noteIndex = 2; break;
        case 'E': noteIndex = 4; break;
        case 'F': noteIndex = 5; break;
        case 'G': noteIndex = 7; break;
        case 'A': noteIndex = 9; break;
        case 'B': noteIndex = 11; break;
        default: return -1;
    }

    // Parse accidental and octave
    size_t pos = 1;
    if (pos < noteName.length()) {
        if (noteName[pos] == '#' || noteName[pos] == 's') {
            accidental = 1;
            pos++;
        } else if (noteName[pos] == 'b' || noteName[pos] == 'f') {
            accidental = -1;
            pos++;
        }
    }

    // Parse octave (look for digit or '-' followed by digit)
    if (pos < noteName.length()) {
        if (noteName[pos] == '-' && pos + 1 < noteName.length()) {
            octave = noteName[pos + 1] - '0';
        } else if (std::isdigit(noteName[pos])) {
            octave = noteName[pos] - '0';
        }
    }

    // Calculate MIDI note: note + accidental + (octave + 1) * 12
    // Middle C (C-4) = MIDI note 60
    int midiNote = noteIndex + accidental + (octave + 1) * 12;

    return std::max(0, std::min(127, midiNote));
}

LFO* VoiceController::getLFO(int lfoNum) {
    if (lfoNum < 1 || lfoNum > MAX_LFOS) {
        return nullptr;
    }
    return &m_lfos[lfoNum - 1];
}

float VoiceController::getLFOValue(int lfoNum) {
    LFO* lfo = getLFO(lfoNum);
    if (!lfo || !lfo->enabled) {
        return 0.0f;
    }
    return lfo->getValue(m_lfoRandomState);
}

void VoiceController::updateLFOs(float deltaTime) {
    for (auto& lfo : m_lfos) {
        lfo.updatePhase(deltaTime);
    }
}

} // namespace SuperTerminal
