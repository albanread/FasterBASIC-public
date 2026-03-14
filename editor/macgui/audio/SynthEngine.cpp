//
//  SynthEngine.mm
//  SuperTerminal v2 - Minimal Sound Synthesis Engine
//
//  Phase 1 implementation - core features only
//  Based on v1 algorithms, adapted for v2 architecture
//

#include "SynthEngine.h"
#include <cmath>
#include <algorithm>
#include <random>

namespace {
std::mutex g_synthMemoryMutex;
std::unordered_map<uint32_t, std::unique_ptr<SynthAudioBuffer>> g_synthMemoryBank;
std::atomic<uint32_t> g_nextSynthMemoryId{1};

uint32_t registerSynthMemoryBuffer(std::unique_ptr<SynthAudioBuffer> buffer) {
    if (!buffer) {
        return 0;
    }

    const uint32_t id = g_nextSynthMemoryId.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(g_synthMemoryMutex);
    g_synthMemoryBank[id] = std::move(buffer);
    return id;
}
} // namespace

std::unique_ptr<SynthAudioBuffer> synth_take_memory_buffer(uint32_t id) {
    if (id == 0) {
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(g_synthMemoryMutex);
    auto it = g_synthMemoryBank.find(id);
    if (it == g_synthMemoryBank.end()) {
        return nullptr;
    }

    auto out = std::move(it->second);
    g_synthMemoryBank.erase(it);
    return out;
}

bool synth_free_memory_buffer(uint32_t id) {
    if (id == 0) {
        return false;
    }

    std::lock_guard<std::mutex> lock(g_synthMemoryMutex);
    return g_synthMemoryBank.erase(id) > 0;
}

bool synth_has_memory_buffer(uint32_t id) {
    if (id == 0) {
        return false;
    }

    std::lock_guard<std::mutex> lock(g_synthMemoryMutex);
    return g_synthMemoryBank.find(id) != g_synthMemoryBank.end();
}

// =============================================================================
// EnvelopeADSR Implementation
// =============================================================================

float EnvelopeADSR::getValue(float time, float noteDuration) const {
    if (time < 0.0f) return 0.0f;

    float totalTime = attackTime + decayTime + releaseTime;
    float sustainTime = std::max(0.0f, noteDuration - totalTime);

    if (time <= attackTime) {
        if (attackTime <= 0.0f) return 1.0f;
        return time / attackTime;
    }

    time -= attackTime;
    if (time <= decayTime) {
        if (decayTime <= 0.0f) return sustainLevel;
        float t = time / decayTime;
        return 1.0f - t * (1.0f - sustainLevel);
    }

    time -= decayTime;
    if (time <= sustainTime) {
        return sustainLevel;
    }

    time -= sustainTime;
    if (time <= releaseTime) {
        if (releaseTime <= 0.0f) return 0.0f;
        return sustainLevel * (1.0f - time / releaseTime);
    }

    return 0.0f;
}

// =============================================================================
// SynthEngine Implementation
// =============================================================================

SynthEngine::SynthEngine()
    : config()
    , initialized(false)
    , lastGenerationTime(0.0f)
    , generatedSoundCount(0)
    , randomSeed(12345)
{
}

SynthEngine::~SynthEngine() {
    shutdown();
}

bool SynthEngine::initialize(const SynthConfig& cfg) {
    if (initialized.load()) {
        return true;
    }

    config = cfg;
    initialized = true;
    return true;
}

void SynthEngine::shutdown() {
    if (!initialized.load()) {
        return;
    }
    initialized = false;
}

// =============================================================================
// Core Synthesis Helpers
// =============================================================================

float SynthEngine::generateWaveform(WaveformType waveform, float phase, float pulseWidth) {
    switch (waveform) {
        case WaveformType::SINE:
            return std::sin(phase);

        case WaveformType::SQUARE:
            return (std::fmod(phase, 2.0f * M_PI) < M_PI) ? 1.0f : -1.0f;

        case WaveformType::SAWTOOTH:
            return 2.0f * (phase / (2.0f * M_PI) - std::floor(phase / (2.0f * M_PI) + 0.5f));

        case WaveformType::TRIANGLE: {
            float t = std::fmod(phase / (2.0f * M_PI), 1.0f);
            return 4.0f * std::abs(t - 0.5f) - 1.0f;
        }

        case WaveformType::NOISE:
            return generateNoise();

        case WaveformType::PULSE: {
            float t = std::fmod(phase, 2.0f * M_PI) / (2.0f * M_PI);
            return (t < pulseWidth) ? 1.0f : -1.0f;
        }
    }
    return 0.0f;
}

float SynthEngine::generateNoise() {
    randomSeed = randomSeed * 1103515245 + 12345;
    return (float)((randomSeed / 65536) % 32768) / 16384.0f - 1.0f;
}

float SynthEngine::random01() {
    randomSeed = randomSeed * 1103515245 + 12345;
    return (float)((randomSeed / 65536) % 32768) / 32768.0f;
}

float SynthEngine::randomRange(float min, float max) {
    return min + random01() * (max - min);
}

// =============================================================================
// Sound Generation - Main Entry Point
// =============================================================================

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateSound(const SynthSoundEffect& effect) {
    if (!initialized.load()) {
        return nullptr;
    }

    auto startTime = std::chrono::high_resolution_clock::now();

    // Create buffer
    auto buffer = std::make_unique<SynthAudioBuffer>();
    buffer->sampleRate = config.sampleRate;
    buffer->channels = config.channels;
    float clampedDuration = std::max(0.0f, std::min(effect.duration, config.maxDuration));
    if (clampedDuration <= 0.0f) {
        clampedDuration = 0.01f;
    }
    buffer->duration = clampedDuration;
    buffer->resize(clampedDuration);

    size_t frameCount = buffer->getFrameCount();
    float dt = 1.0f / buffer->sampleRate;

    // Generate samples
    for (size_t frame = 0; frame < frameCount; ++frame) {
        float time = frame * dt;
        float sample = 0.0f;

        // Generate from oscillators
        for (const auto& osc : effect.oscillators) {
            float phase = 2.0f * M_PI * osc.frequency * time + osc.phase;
            float oscSample = generateWaveform(osc.waveform, phase, osc.pulseWidth);
            sample += oscSample * osc.amplitude;
        }

        // Apply frequency sweep if configured
        if (effect.pitchSweepStart != effect.pitchSweepEnd) {
            float sweepT = time / clampedDuration;
            float freq = effect.pitchSweepStart + (effect.pitchSweepEnd - effect.pitchSweepStart) * sweepT;
            float sweepPhase = 2.0f * M_PI * freq * time;
            sample += generateWaveform(WaveformType::SINE, sweepPhase, 0.5f) * 0.5f;
        }

        // Mix in noise
        if (effect.noiseMix > 0.0f) {
            sample = sample * (1.0f - effect.noiseMix) + generateNoise() * effect.noiseMix;
        }

        // Apply envelope
        sample *= effect.envelope.getValue(time, effect.duration);

        // Apply distortion
        if (effect.distortion > 0.0f) {
            float dist = 1.0f + effect.distortion * 10.0f;
            sample = std::tanh(sample * dist) / std::tanh(dist);
        }

        // Write to buffer (stereo)
        for (uint32_t ch = 0; ch < buffer->channels; ++ch) {
            buffer->samples[frame * buffer->channels + ch] = sample * 0.5f; // Scale down
        }
    }

    // Simple echo effect
    if (effect.echoCount > 0 && effect.echoDelay > 0.0f) {
        size_t delayFrames = static_cast<size_t>(effect.echoDelay * buffer->sampleRate);
        float decay = effect.echoDecay;

        for (int echo = 0; echo < effect.echoCount; ++echo) {
            size_t echoStart = delayFrames * (echo + 1);
            float amplitude = std::pow(decay, echo + 1);

            for (size_t frame = 0; frame < frameCount && (frame + echoStart) < frameCount; ++frame) {
                for (uint32_t ch = 0; ch < buffer->channels; ++ch) {
                    size_t sourceIdx = frame * buffer->channels + ch;
                    size_t destIdx = (frame + echoStart) * buffer->channels + ch;
                    buffer->samples[destIdx] += buffer->samples[sourceIdx] * amplitude;
                }
            }
        }
    }

    // Normalize
    normalizeBuffer(*buffer);

    auto endTime = std::chrono::high_resolution_clock::now();
    lastGenerationTime = std::chrono::duration<float, std::milli>(endTime - startTime).count();
    generatedSoundCount++;

    return buffer;
}

void SynthEngine::normalizeBuffer(SynthAudioBuffer& buffer, float targetLevel) {
    if (buffer.samples.empty()) return;

    float maxSample = 0.0f;
    for (float sample : buffer.samples) {
        maxSample = std::max(maxSample, std::abs(sample));
    }

    if (maxSample > 1.0f) {
        float safeTarget = std::max(0.0f, std::min(targetLevel, 1.0f));
        float scale = safeTarget / maxSample;
        for (float& sample : buffer.samples) {
            sample *= scale;
        }
    }
}

// =============================================================================
// Predefined Sound Effects
// =============================================================================

SynthSoundEffect SynthEngine::createBeepEffect(float frequency, float duration) {
    SynthSoundEffect effect;
    effect.name = "Beep";
    effect.duration = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform = WaveformType::SINE;
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.05f;
    effect.envelope.sustainLevel = 0.7f;
    effect.envelope.releaseTime = 0.1f;

    return effect;
}

SynthSoundEffect SynthEngine::createCoinEffect(float pitch, float duration) {
    SynthSoundEffect effect;
    effect.name = "Coin";
    effect.duration = duration;

    // Two oscillators for a pleasant chime
    Oscillator osc1;
    osc1.waveform = WaveformType::SINE;
    osc1.frequency = 987.77f; // B5
    osc1.amplitude = 0.5f;
    effect.oscillators.push_back(osc1);

    Oscillator osc2;
    osc2.waveform = WaveformType::SINE;
    osc2.frequency = 1318.51f; // E6
    osc2.amplitude = 0.3f;
    effect.oscillators.push_back(osc2);

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.1f;
    effect.envelope.sustainLevel = 0.3f;
    effect.envelope.releaseTime = 0.15f;

    return effect;
}

SynthSoundEffect SynthEngine::createJumpEffect(float height, float duration) {
    SynthSoundEffect effect;
    effect.name = "Jump";
    effect.duration = duration;

    effect.pitchSweepStart = 300.0f;
    effect.pitchSweepEnd = 600.0f;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.05f;
    effect.envelope.sustainLevel = 0.5f;
    effect.envelope.releaseTime = 0.1f;

    return effect;
}

SynthSoundEffect SynthEngine::createExplodeEffect(float size, float duration) {
    SynthSoundEffect effect;
    effect.name = "Explode";
    effect.duration = duration;

    // Start with a strong low thump and a small body harmonic.
    Oscillator bass;
    bass.waveform = WaveformType::SINE;
    bass.frequency = 58.0f;
    bass.amplitude = 0.95f;
    effect.oscillators.push_back(bass);

    Oscillator body;
    body.waveform = WaveformType::TRIANGLE;
    body.frequency = 86.0f;
    body.amplitude = 0.28f;
    effect.oscillators.push_back(body);

    // Keep only a little noise texture to avoid "hiss" character.
    effect.noiseMix = std::max(0.0f, std::min(0.12f, 0.06f * size));

    effect.pitchSweepStart = 135.0f;
    effect.pitchSweepEnd = 32.0f;

    effect.envelope.attackTime = 0.0015f;
    effect.envelope.decayTime = 0.14f;
    effect.envelope.sustainLevel = 0.0f;
    effect.envelope.releaseTime = 0.10f;
    effect.distortion = 0.08f;

    return effect;
}

SynthSoundEffect SynthEngine::createShootEffect(float power, float duration) {
    SynthSoundEffect effect;
    effect.name = "Shoot";
    effect.duration = duration;

    effect.pitchSweepStart = 800.0f;
    effect.pitchSweepEnd = 200.0f;
    effect.noiseMix = 0.3f;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.05f;
    effect.envelope.sustainLevel = 0.4f;
    effect.envelope.releaseTime = 0.08f;

    return effect;
}

SynthSoundEffect SynthEngine::createPowerUpEffect(float intensity, float duration) {
    SynthSoundEffect effect;
    effect.name = "PowerUp";
    effect.duration = duration;

    effect.pitchSweepStart = 200.0f;
    effect.pitchSweepEnd = 800.0f;

    Oscillator osc;
    osc.waveform = WaveformType::SQUARE;
    osc.frequency = 400.0f;
    osc.amplitude = 0.4f;
    effect.oscillators.push_back(osc);

    effect.envelope.attackTime = 0.1f;
    effect.envelope.decayTime = 0.1f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime = 0.2f;

    return effect;
}

SynthSoundEffect SynthEngine::createClickEffect(float sharpness, float duration) {
    SynthSoundEffect effect;
    effect.name = "Click";
    effect.duration = duration;

    Oscillator osc;
    osc.waveform = WaveformType::NOISE;
    osc.amplitude = 0.3f;
    effect.oscillators.push_back(osc);

    effect.envelope.attackTime = 0.001f;
    effect.envelope.decayTime = 0.01f;
    effect.envelope.sustainLevel = 0.0f;
    effect.envelope.releaseTime = 0.03f;

    return effect;
}

// =============================================================================
// Public Sound Generation API
// =============================================================================

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateBeep(float frequency, float duration) {
    return generateSound(createBeepEffect(frequency, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateBang(float intensity, float duration) {
    SynthSoundEffect effect;
    effect.duration = duration;
    effect.noiseMix = 0.8f;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.05f;
    effect.envelope.sustainLevel = 0.0f;
    effect.envelope.releaseTime = 0.1f;

    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateExplode(float size, float duration) {
    return generateSound(createExplodeEffect(size, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateBigExplosion(float size, float duration) {
    auto effect = createExplodeEffect(size, duration);

    Oscillator sub;
    sub.waveform = WaveformType::SINE;
    sub.frequency = 36.0f;
    sub.amplitude = 0.55f;
    effect.oscillators.push_back(sub);

    effect.pitchSweepStart = 110.0f;
    effect.pitchSweepEnd = 22.0f;
    effect.noiseMix = std::max(effect.noiseMix, 0.14f);
    effect.envelope.decayTime = 0.22f;
    effect.envelope.releaseTime = 0.18f;
    effect.distortion = 0.14f;

    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateSmallExplosion(float intensity, float duration) {
    auto effect = createExplodeEffect(intensity, duration);
    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateDistantExplosion(float distance, float duration) {
    auto effect = createExplodeEffect(distance, duration);
    effect.noiseMix = 0.4f;
    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateMetalExplosion(float shrapnel, float duration) {
    auto effect = createExplodeEffect(shrapnel, duration);
    effect.noiseMix = 0.7f;
    effect.distortion = 0.3f;
    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateZap(float frequency, float duration) {
    SynthSoundEffect effect;
    effect.duration = duration;
    effect.pitchSweepStart = 1000.0f;
    effect.pitchSweepEnd = 100.0f;
    effect.noiseMix = 0.2f;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.05f;
    effect.envelope.sustainLevel = 0.3f;
    effect.envelope.releaseTime = 0.08f;

    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateCoin(float pitch, float duration) {
    return generateSound(createCoinEffect(pitch, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateJump(float power, float duration) {
    return generateSound(createJumpEffect(power, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generatePowerUp(float intensity, float duration) {
    return generateSound(createPowerUpEffect(intensity, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateHurt(float intensity, float duration) {
    SynthSoundEffect effect;
    effect.duration = duration;
    effect.pitchSweepStart = 600.0f;
    effect.pitchSweepEnd = 200.0f;
    effect.noiseMix = 0.4f;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.1f;
    effect.envelope.sustainLevel = 0.2f;
    effect.envelope.releaseTime = 0.15f;

    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateShoot(float power, float duration) {
    return generateSound(createShootEffect(power, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateClick(float intensity, float duration) {
    return generateSound(createClickEffect(intensity, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateSweepUp(float startFreq, float endFreq, float duration) {
    SynthSoundEffect effect;
    effect.duration = duration;
    effect.pitchSweepStart = startFreq;
    effect.pitchSweepEnd = endFreq;

    effect.envelope.attackTime = 0.01f;
    effect.envelope.decayTime = 0.1f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime = 0.1f;

    return generateSound(effect);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateSweepDown(float startFreq, float endFreq, float duration) {
    return generateSweepUp(startFreq, endFreq, duration);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateRandomBeep(uint32_t seed, float duration) {
    randomSeed = seed;
    float freq = randomRange(200.0f, 1000.0f);
    float baseDuration = (duration > 0.0f) ? duration : 0.2f;
    float randomDuration = randomRange(baseDuration * 0.5f, baseDuration * 1.5f);
    return generateBeep(freq, randomDuration);
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generatePickup(float pitch, float duration) {
    return generateSound(createCoinEffect(pitch, duration));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::generateBlip(float pitch, float duration) {
    return generateBeep(800.0f * pitch, duration);
}

// =============================================================================
// Utility Functions
// =============================================================================

float SynthEngine::noteToFrequency(int midiNote) {
    return 440.0f * std::pow(2.0f, (midiNote - 69) / 12.0f);
}

int SynthEngine::frequencyToNote(float frequency) {
    if (frequency <= 0.0f) return 0;
    return static_cast<int>(std::round(69.0f + 12.0f * std::log2(frequency / 440.0f)));
}

// =============================================================================
// Stub Functions - Not Implemented in Phase 1
// =============================================================================

// These functions are declared in the header but not critical for Phase 1
// They can be implemented later as needed

uint32_t SynthEngine::generateBeepToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateExplodeToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateCoinToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateShootToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateClickToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateJumpToMemory(float, float) { return 0; }
uint32_t SynthEngine::generatePowerupToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateHurtToMemory(float, float) { return 0; }
uint32_t SynthEngine::generatePickupToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateBlipToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateZapToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateBigExplosionToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateSmallExplosionToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateDistantExplosionToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateMetalExplosionToMemory(float, float) { return 0; }
uint32_t SynthEngine::generateSweepUpToMemory(float, float, float) { return 0; }
uint32_t SynthEngine::generateSweepDownToMemory(float, float, float) { return 0; }
uint32_t SynthEngine::generateOscillatorToMemory(WaveformType, float, float, float, float, float, float) { return 0; }
uint32_t SynthEngine::generateRandomBeepToMemory(uint32_t, float) { return 0; }

uint32_t SynthEngine::generatePhysicalToMemory(PhysicalParams::ModelType model, float frequency,
                                               float damping, float brightness, float duration) {
    PhysicalParams params;
    params.modelType = model;
    params.frequency = frequency;
    params.damping = damping;
    params.brightness = brightness;
    params.excitation = 1.0f;
    params.resonance = 0.3f;
    params.stringTension = 0.8f;
    params.airPressure = 0.7f;

    if (model == PhysicalParams::BLOWN_TUBE) {
        params.airPressure = damping;
        params.damping = 0.1f;
    }

    auto buffer = synthesizePhysical(params, duration, nullptr);
    if (!buffer) return 0;

    return registerSynthMemoryBuffer(std::move(buffer));
}

std::unique_ptr<SynthAudioBuffer> SynthEngine::synthesizeOscillator(const Oscillator&, float, const EnvelopeADSR*, const FilterParams*) { return nullptr; }
std::unique_ptr<SynthAudioBuffer> SynthEngine::synthesizeAdditive(const AdditiveParams&, float, const EnvelopeADSR*) { return nullptr; }
std::unique_ptr<SynthAudioBuffer> SynthEngine::synthesizeFM(const FMParams&, float, const EnvelopeADSR*) { return nullptr; }
std::unique_ptr<SynthAudioBuffer> SynthEngine::synthesizeGranular(const GranularParams&, float, const EnvelopeADSR*) { return nullptr; }
std::unique_ptr<SynthAudioBuffer> SynthEngine::synthesizePhysical(const PhysicalParams& params, float duration, const EnvelopeADSR* envelope) {
    auto buffer = std::make_unique<SynthAudioBuffer>();
    buffer->sampleRate = config.sampleRate;
    buffer->channels = config.channels;
    buffer->resize(duration);

    // Dispatch to specific physical model
    switch (params.modelType) {
        case PhysicalParams::PLUCKED_STRING:
            simulateString(*buffer, params);
            break;
        case PhysicalParams::STRUCK_BAR:
            simulateBar(*buffer, params);
            break;
        case PhysicalParams::BLOWN_TUBE:
            simulateTube(*buffer, params);
            break;
        case PhysicalParams::DRUMHEAD:
            simulateDrum(*buffer, params);
            break;
    }

    // Apply envelope if provided
    if (envelope) {
        size_t frameCount = buffer->getFrameCount();
        for (size_t frame = 0; frame < frameCount; ++frame) {
            float time = static_cast<float>(frame) / buffer->sampleRate;
            float envValue = envelope->getValue(time, duration);

            for (uint32_t ch = 0; ch < buffer->channels; ++ch) {
                size_t idx = frame * buffer->channels + ch;
                buffer->samples[idx] *= envValue;
            }
        }
    }

    return buffer;
}

// =============================================================================
// Physical Modeling Implementations
// =============================================================================

// Karplus-Strong Plucked String Algorithm
void SynthEngine::simulateString(SynthAudioBuffer& buffer, const PhysicalParams& params) {
    float freq = params.frequency;
    if (!std::isfinite(freq) || freq <= 0.0f) {
        freq = 440.0f;
    }
    float damping = params.damping;
    float brightness = params.brightness;

    // Calculate delay line length based on frequency
    int delayLength = static_cast<int>(buffer.sampleRate / freq);
    if (delayLength < 2) delayLength = 2;

    std::vector<float> delayLine(delayLength, 0.0f);
    int writePos = 0;

    // Initialize with noise burst (pluck excitation)
    for (int i = 0; i < delayLength; ++i) {
        delayLine[i] = (randomRange(-1.0f, 1.0f)) * params.excitation;
    }

    // Lowpass filter coefficient (brightness control)
    float filterCoeff = 0.5f + (brightness * 0.49f); // Range: 0.5 to 0.99
    float lastSample = 0.0f;

    // String tension affects decay rate
    float decayFactor = 1.0f - (damping * 0.01f) - ((1.0f - params.stringTension) * 0.005f);

    size_t frameCount = buffer.getFrameCount();
    for (size_t frame = 0; frame < frameCount; ++frame) {
        // Read from delay line
        int readPos = (writePos + 1) % delayLength;
        float currentSample = delayLine[readPos];

        // Simple lowpass filter (averaging)
        float filtered = filterCoeff * currentSample + (1.0f - filterCoeff) * lastSample;
        lastSample = filtered;

        // Apply decay and string tension
        filtered *= decayFactor;

        // Add slight resonance boost at fundamental
        float resonanceBoost = 1.0f + (params.resonance * 0.2f);
        filtered *= resonanceBoost;

        // Write back to delay line
        delayLine[writePos] = filtered;
        writePos = (writePos + 1) % delayLength;

        // Output to all channels
        for (uint32_t ch = 0; ch < buffer.channels; ++ch) {
            buffer.samples[frame * buffer.channels + ch] = filtered * 0.5f;
        }
    }
}

// Modal Synthesis for Struck Bar (bells, xylophones, metallic percussion)
void SynthEngine::simulateBar(SynthAudioBuffer& buffer, const PhysicalParams& params) {
    float freq = params.frequency;
    float damping = params.damping;
    float brightness = params.brightness;

    // Modal ratios for an ideal bar (from physics)
    // These give the characteristic metallic/bell-like timbre
    const int numModes = 6;
    float modeRatios[numModes] = {1.0f, 2.756f, 5.404f, 8.933f, 13.344f, 18.64f};
    float modeAmps[numModes] = {1.0f, 0.5f, 0.25f, 0.15f, 0.1f, 0.05f};

    // Brightness affects higher mode amplitudes
    for (int i = 0; i < numModes; ++i) {
        modeAmps[i] *= (1.0f - (i * 0.1f * (1.0f - brightness)));
    }

    // Damping affects decay rates (higher modes decay faster)
    float baseDamping = damping * 5.0f;

    size_t frameCount = buffer.getFrameCount();
    float sampleRate = static_cast<float>(buffer.sampleRate);

    for (size_t frame = 0; frame < frameCount; ++frame) {
        float time = static_cast<float>(frame) / sampleRate;
        float sample = 0.0f;

        // Sum all modes
        for (int mode = 0; mode < numModes; ++mode) {
            float modeFreq = freq * modeRatios[mode];
            float modeDecay = baseDamping * (1.0f + mode * 0.5f); // Higher modes decay faster
            float envelope = std::exp(-modeDecay * time) * params.excitation;

            // Add resonance to fundamental and first overtone
            if (mode < 2) {
                envelope *= (1.0f + params.resonance * 0.3f);
            }

            sample += std::sin(2.0f * M_PI * modeFreq * time) * modeAmps[mode] * envelope;
        }

        // Output to all channels
        for (uint32_t ch = 0; ch < buffer.channels; ++ch) {
            buffer.samples[frame * buffer.channels + ch] = sample * 0.3f;
        }
    }
}

// Waveguide Blown Tube (flutes, organs, wind sounds)
void SynthEngine::simulateTube(SynthAudioBuffer& buffer, const PhysicalParams& params) {
    float freq = params.frequency;
    if (!std::isfinite(freq) || freq <= 0.0f) {
        freq = 440.0f;
    }
    float damping = params.damping;
    float brightness = params.brightness;

    // Calculate delay line length (tube length)
    int delayLength = static_cast<int>(buffer.sampleRate / freq);
    if (delayLength < 2) delayLength = 2;

    std::vector<float> delayLine(delayLength, 0.0f);
    int writePos = 0;

    // Air pressure controls excitation strength and breath noise
    float breathNoise = params.airPressure * 0.1f;
    float excitationStrength = params.excitation * params.airPressure;

    // Lowpass for tube damping
    float filterCoeff = 0.3f + (brightness * 0.65f);
    float lastSample = 0.0f;

    // Decay factor
    float decayFactor = 1.0f - (damping * 0.005f);

    size_t frameCount = buffer.getFrameCount();
    float sampleRate = static_cast<float>(buffer.sampleRate);

    for (size_t frame = 0; frame < frameCount; ++frame) {
        float time = static_cast<float>(frame) / sampleRate;

        // Excitation: breath noise that decays over time
        float excitation = 0.0f;
        if (time < 0.1f) {
            // Initial attack with noise
            excitation = randomRange(-breathNoise, breathNoise) * excitationStrength;
        } else {
            // Sustained tone with subtle breath noise
            excitation = randomRange(-breathNoise, breathNoise) * excitationStrength * 0.3f;
        }

        // Read from delay line
        int readPos = (writePos + 1) % delayLength;
        float currentSample = delayLine[readPos];

        // Lowpass filter (simulates energy loss in tube)
        float filtered = filterCoeff * currentSample + (1.0f - filterCoeff) * lastSample;
        lastSample = filtered;

        // Apply decay
        filtered *= decayFactor;

        // Add excitation
        filtered += excitation;

        // Resonance boost at fundamental
        filtered *= (1.0f + params.resonance * 0.15f);

        // Write back to delay line
        delayLine[writePos] = filtered;
        writePos = (writePos + 1) % delayLength;

        // Output to all channels
        for (uint32_t ch = 0; ch < buffer.channels; ++ch) {
            buffer.samples[frame * buffer.channels + ch] = filtered * 0.4f;
        }
    }
}

// Modal Synthesis for Drumhead (2D membrane modes)
void SynthEngine::simulateDrum(SynthAudioBuffer& buffer, const PhysicalParams& params) {
    float freq = params.frequency;
    float damping = params.damping;
    float brightness = params.brightness;

    // Modal ratios for circular drumhead (from Bessel functions)
    // These create the characteristic "boing" of a drum
    const int numModes = 8;
    float modeRatios[numModes] = {1.0f, 1.593f, 2.136f, 2.296f, 2.653f, 2.918f, 3.156f, 3.501f};
    float modeAmps[numModes] = {1.0f, 0.6f, 0.4f, 0.35f, 0.25f, 0.2f, 0.15f, 0.1f};

    // Brightness affects higher mode amplitudes
    for (int i = 0; i < numModes; ++i) {
        modeAmps[i] *= (1.0f - (i * 0.08f * (1.0f - brightness)));
    }

    // Damping is higher for drums
    float baseDamping = 2.0f + (damping * 8.0f);

    size_t frameCount = buffer.getFrameCount();
    float sampleRate = static_cast<float>(buffer.sampleRate);

    for (size_t frame = 0; frame < frameCount; ++frame) {
        float time = static_cast<float>(frame) / sampleRate;
        float sample = 0.0f;

        // Sum all modes
        for (int mode = 0; mode < numModes; ++mode) {
            float modeFreq = freq * modeRatios[mode];
            float modeDecay = baseDamping * (1.0f + mode * 0.3f);
            float envelope = std::exp(-modeDecay * time) * params.excitation;

            // Add resonance to fundamental
            if (mode == 0) {
                envelope *= (1.0f + params.resonance * 0.4f);
            }

            // Phase modulation for more complex attack
            float phase = 2.0f * M_PI * modeFreq * time;
            if (time < 0.01f) {
                // Add inharmonic attack "thump"
                phase += std::sin(2.0f * M_PI * freq * 0.5f * time) * 5.0f * (1.0f - time * 100.0f);
            }

            sample += std::sin(phase) * modeAmps[mode] * envelope;
        }

        // Add initial transient noise for stick attack
        if (time < 0.005f) {
            float noiseEnv = (1.0f - time * 200.0f);
            sample += randomRange(-0.3f, 0.3f) * noiseEnv * params.excitation;
        }

        // Output to all channels
        for (uint32_t ch = 0; ch < buffer.channels; ++ch) {
            buffer.samples[frame * buffer.channels + ch] = sample * 0.35f;
        }
    }
}


bool SynthEngine::exportToWAV(const SynthAudioBuffer&, const std::string&, const WAVExportParams&) { return false; }
bool SynthEngine::exportToWAVMemory(const SynthAudioBuffer&, std::vector<uint8_t>&, const WAVExportParams&) { return false; }

// =============================================================================
// C API Stubs - Phase 2
// =============================================================================

extern "C" {
    uint32_t synth_create_physical_string(float frequency, float damping, float brightness, float duration);
    uint32_t synth_create_physical_bar(float frequency, float damping, float brightness, float duration);
    uint32_t synth_create_physical_tube(float frequency, float airPressure, float brightness, float duration);
    uint32_t synth_create_physical_drum(float frequency, float damping, float excitation, float duration);

    bool synth_initialize() { return false; }
    void synth_shutdown() {}
    bool synth_is_initialized() { return false; }

    // All other C API functions return false/0/nullptr
    bool synth_generate_beep(const char*, float, float) { return false; }
    bool synth_generate_bang(const char*, float, float) { return false; }
    bool synth_generate_explode(const char*, float, float) { return false; }
    bool synth_generate_big_explosion(const char*, float, float) { return false; }
    bool synth_generate_small_explosion(const char*, float, float) { return false; }
    bool synth_generate_distant_explosion(const char*, float, float) { return false; }
    bool synth_generate_metal_explosion(const char*, float, float) { return false; }
    bool synth_generate_zap(const char*, float, float) { return false; }
    bool synth_generate_coin(const char*, float, float) { return false; }
    bool synth_generate_jump(const char*, float, float) { return false; }
    bool synth_generate_powerup(const char*, float, float) { return false; }
    bool synth_generate_hurt(const char*, float, float) { return false; }
    bool synth_generate_shoot(const char*, float, float) { return false; }
    bool synth_generate_click(const char*, float, float) { return false; }
    bool synth_generate_sweep_up(const char*, float, float, float) { return false; }
    bool synth_generate_sweep_down(const char*, float, float, float) { return false; }
    bool synth_generate_random_beep(const char*, uint32_t, float) { return false; }
    bool synth_generate_pickup(const char*, float, float) { return false; }
    bool synth_generate_blip(const char*, float, float) { return false; }
    bool synth_generate_oscillator(const char*, int, float, float, float, float, float, float) { return false; }
    bool synth_generate_additive(const char*, float, const float*, int, float) { return false; }
    bool synth_generate_fm(const char*, float, float, float, float) { return false; }
    bool synth_generate_granular(const char*, float, float, float, float) { return false; }
    bool synth_generate_physical_string(const char* name, float frequency, float damping, float brightness, float duration) {
        (void)name;
        return synth_create_physical_string(frequency, damping, brightness, duration) != 0;
    }
    bool synth_generate_physical_bar(const char* name, float frequency, float damping, float brightness, float duration) {
        (void)name;
        return synth_create_physical_bar(frequency, damping, brightness, duration) != 0;
    }
    bool synth_generate_physical_tube(const char* name, float frequency, float airPressure, float brightness, float duration) {
        (void)name;
        return synth_create_physical_tube(frequency, airPressure, brightness, duration) != 0;
    }
    bool synth_generate_physical_drum(const char* name, float frequency, float damping, float excitation, float duration) {
        (void)name;
        return synth_create_physical_drum(frequency, damping, excitation, duration) != 0;
    }

    uint32_t synth_create_additive(float, const float*, int, float) { return 0; }
    uint32_t synth_create_fm(float, float, float, float) { return 0; }
    uint32_t synth_create_granular(float, float, float, float) { return 0; }
    uint32_t synth_create_physical_string(float frequency, float damping, float brightness, float duration) {
        SynthEngine engine;
        if (!engine.initialize()) return 0;
        return engine.generatePhysicalToMemory(PhysicalParams::PLUCKED_STRING, frequency, damping, brightness, duration);
    }
    uint32_t synth_create_physical_bar(float frequency, float damping, float brightness, float duration) {
        SynthEngine engine;
        if (!engine.initialize()) return 0;
        return engine.generatePhysicalToMemory(PhysicalParams::STRUCK_BAR, frequency, damping, brightness, duration);
    }
    uint32_t synth_create_physical_tube(float frequency, float airPressure, float brightness, float duration) {
        SynthEngine engine;
        if (!engine.initialize()) return 0;
        return engine.generatePhysicalToMemory(PhysicalParams::BLOWN_TUBE, frequency, airPressure, brightness, duration);
    }
    uint32_t synth_create_physical_drum(float frequency, float damping, float excitation, float duration) {
        SynthEngine engine;
        if (!engine.initialize()) return 0;
        return engine.generatePhysicalToMemory(PhysicalParams::DRUMHEAD, frequency, damping, excitation, duration);
    }

    bool synth_set_effect_param(uint32_t, const char*, const char*, float) { return false; }
    bool synth_add_effect(uint32_t, const char*) { return false; }
    bool synth_remove_effect(uint32_t, const char*) { return false; }

    bool synth_save_preset(const char*, const char*) { return false; }
    const char* synth_load_preset(const char*) { return nullptr; }
    bool synth_apply_preset(uint32_t, const char*) { return false; }

    bool synth_generate_sound_pack(const char*) { return false; }

    float synth_note_to_frequency(int midiNote) {
        return 440.0f * std::pow(2.0f, (midiNote - 69) / 12.0f);
    }

    int synth_frequency_to_note(float frequency) {
        return static_cast<int>(std::round(69.0f + 12.0f * std::log2(frequency / 440.0f)));
    }

    float synth_get_last_generation_time() { return 0.0f; }
    size_t synth_get_generated_count() { return 0; }
}

// =============================================================================
// SynthAudioBuffer Implementation
// =============================================================================

void SynthAudioBuffer::resize(float durationSeconds) {
    duration = durationSeconds;
    size_t frameCount = static_cast<size_t>(sampleRate * durationSeconds);
    samples.resize(frameCount * channels);
}

void SynthAudioBuffer::clear() {
    samples.clear();
    duration = 0.0f;
}
