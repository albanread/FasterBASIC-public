//
// FBAudioManager.mm
// FasterBASIC Audio Manager — Phase 1 (SOUND) + Phase 2 (MUSIC) + Phase 3 (VS)
//
// Obj-C++ implementation wiring SynthEngine + SoundBank + AVAudioEngine
// for SOUND, MusicBank + MidiEngine for MUSIC, and
// VoiceController + AVAudioSourceNode for the VS real-time synthesiser.
//
// MIT License — Copyright (c) 2025
//

#include "FBAudioManager.h"
#include "fb_audio_shim.h"
#include "SynthEngine.h"
#include "SoundBank.h"
#include "MusicBank.h"
#include "MidiEngine.h"
#include "CoreAudioEngine.h"
#include "VoiceController.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <fstream>
#include <iomanip>
#include <chrono>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <cstdint>
#include <cstdio>

// ═══════════════════════════════════════════════════════════════════════════════
//  PIMPL Implementation
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
//  VS Recording — command types for the timeline system
// ═══════════════════════════════════════════════════════════════════════════════

enum class VSRecordCmdType {
    Waveform, Frequency, Note, NoteName, PulseWidth,
    Envelope, Gate, Volume, Pan, MasterVolume,
    FilterType, FilterCutoff, FilterResonance, FilterEnabled, FilterRoute,
    RingMod, Sync, Portamento, Detune,
    DelayEnabled, DelayTime, DelayFeedback, DelayMix,
    LFOWaveform, LFORate, LFOReset,
    LFOPitch, LFOVolume, LFOFilter, LFOPulse,
    PhysicalModel, PhysicalDamping, PhysicalBrightness, PhysicalExcitation,
    PhysicalResonance, PhysicalTension, PhysicalPressure, PhysicalTrigger,
    Reset
};

struct VSRecordCmd {
    float beat;              // Beat position
    VSRecordCmdType type;
    int   iarg1{0};          // voice / lfo number
    int   iarg2{0};          // waveform / source / filter type / model type
    float farg1{0.0f};
    float farg2{0.0f};
    float farg3{0.0f};
    float farg4{0.0f};
    bool  barg{false};
    std::string sarg;        // for notename
};

struct CompiledMusicProgram {
    uint8_t channel{1}; // 1..16
    uint8_t program{0}; // 0..127
};

struct CompiledMusicNote {
    double startBeats{0.0};
    double durationBeats{0.0};
    uint8_t midiNote{60};
    uint8_t velocity{100};
    uint8_t channel{1}; // 1..16
};

struct CompiledMusicData {
    float tempo{120.0f};
    std::vector<CompiledMusicProgram> programs;
    std::vector<CompiledMusicNote> notes;

    size_t getMemoryUsage() const {
        return sizeof(CompiledMusicData) +
               (programs.size() * sizeof(CompiledMusicProgram)) +
               (notes.size() * sizeof(CompiledMusicNote));
    }
};

static bool readU32LE(const uint8_t*& cur, const uint8_t* end, uint32_t& out) {
    if (static_cast<size_t>(end - cur) < 4) return false;
    out = static_cast<uint32_t>(cur[0]) |
          (static_cast<uint32_t>(cur[1]) << 8) |
          (static_cast<uint32_t>(cur[2]) << 16) |
          (static_cast<uint32_t>(cur[3]) << 24);
    cur += 4;
    return true;
}

static bool fbAudioDebugEnabledManager() {
    const char* v = std::getenv("FB_AUDIO_DEBUG");
    if (!v || !*v) return false;
    return std::strcmp(v, "0") != 0;
}

static AudioDeviceID fbGetDefaultOutputDeviceId() {
    AudioDeviceID deviceId = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(deviceId);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &addr,
                                                 0,
                                                 nullptr,
                                                 &size,
                                                 &deviceId);
    if (status != noErr) return kAudioObjectUnknown;
    return deviceId;
}

static std::string fbAudioDeviceName(AudioDeviceID deviceId) {
    if (deviceId == kAudioObjectUnknown) return "unknown";
    CFStringRef nameRef = nullptr;
    AudioObjectPropertyAddress addr = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(nameRef);
    OSStatus status = AudioObjectGetPropertyData(deviceId,
                                                 &addr,
                                                 0,
                                                 nullptr,
                                                 &size,
                                                 &nameRef);
    if (status != noErr || !nameRef) return "unknown";
    char buf[256] = {0};
    if (!CFStringGetCString(nameRef, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        CFRelease(nameRef);
        return "unknown";
    }
    CFRelease(nameRef);
    return std::string(buf);
}

static bool fbForceDefaultOutputEnabled() {
    const char* v = std::getenv("FB_AUDIO_FORCE_DEFAULT_OUTPUT");
    if (!v || !*v) return false;
    return std::strcmp(v, "0") != 0;
}

static bool readF64LE(const uint8_t*& cur, const uint8_t* end, double& out) {
    if (static_cast<size_t>(end - cur) < 8) return false;
    std::memcpy(&out, cur, 8);
    cur += 8;
    return true;
}

static constexpr uint32_t kCompiledMusicMagic = 0x434D4246u; // "FBMC" little-endian bytes
static constexpr uint32_t kCompiledMusicVersion = 1u;
static constexpr uint32_t kCompiledMusicIdBase = 0x80000000u;
static constexpr size_t kSfxVoiceCount = 12;

static std::string buildCompiledMusicBlobSummary(uint32_t musicId,
                                                 const CompiledMusicData& data)
{
    bool usedChannels[17] = {false};
    for (const auto& p : data.programs) {
        if (p.channel >= 1 && p.channel <= 16) {
            usedChannels[p.channel] = true;
        }
    }

    bool hasNotes = false;
    double minStart = 0.0;
    double maxEnd = 0.0;
    for (const auto& n : data.notes) {
        if (n.channel >= 1 && n.channel <= 16) {
            usedChannels[n.channel] = true;
        }
        const double start = std::max(0.0, n.startBeats);
        const double end = std::max(start, n.startBeats + n.durationBeats);
        if (!hasNotes) {
            hasNotes = true;
            minStart = start;
            maxEnd = end;
        } else {
            minStart = std::min(minStart, start);
            maxEnd = std::max(maxEnd, end);
        }
    }

    std::string channelList;
    for (int ch = 1; ch <= 16; ++ch) {
        if (!usedChannels[ch]) continue;
        if (!channelList.empty()) channelList += ",";
        channelList += std::to_string(ch);
    }
    if (channelList.empty()) channelList = "none";

    std::ostringstream oss;
    oss << std::fixed << std::setprecision(3);
    oss << "format=FBMC"
        << ";version=" << kCompiledMusicVersion
        << ";id=" << musicId
        << ";tempo=" << data.tempo
        << ";programs=" << data.programs.size()
        << ";notes=" << data.notes.size()
        << ";channels=" << channelList
        << ";start_beats=" << (hasNotes ? minStart : 0.0)
        << ";end_beats=" << (hasNotes ? maxEnd : 0.0)
        << ";duration_beats=" << (hasNotes ? (maxEnd - minStart) : 0.0);
    return oss.str();
}

static void writeU16BE(std::ofstream& out, uint16_t v) {
    const uint8_t b[2] = {
        static_cast<uint8_t>((v >> 8) & 0xFF),
        static_cast<uint8_t>(v & 0xFF),
    };
    out.write(reinterpret_cast<const char*>(b), 2);
}

static void writeU32BE(std::ofstream& out, uint32_t v) {
    const uint8_t b[4] = {
        static_cast<uint8_t>((v >> 24) & 0xFF),
        static_cast<uint8_t>((v >> 16) & 0xFF),
        static_cast<uint8_t>((v >> 8) & 0xFF),
        static_cast<uint8_t>(v & 0xFF),
    };
    out.write(reinterpret_cast<const char*>(b), 4);
}

static void appendVarLen(std::vector<uint8_t>& out, uint32_t value) {
    uint8_t bytes[5];
    int count = 0;
    bytes[count++] = static_cast<uint8_t>(value & 0x7F);
    value >>= 7;
    while (value > 0 && count < 5) {
        bytes[count++] = static_cast<uint8_t>((value & 0x7F) | 0x80);
        value >>= 7;
    }
    for (int i = count - 1; i >= 0; --i) {
        out.push_back(bytes[i]);
    }
}

struct FBAudioManager::Impl {
    // ── Core subsystems (SOUND) ────────────────────────────────────────────
    std::unique_ptr<SynthEngine>              synthEngine;
    std::unique_ptr<SuperTerminal::SoundBank> soundBank;

    // ── Music subsystems (MUSIC) ───────────────────────────────────────────
    std::unique_ptr<SuperTerminal::MusicBank>      musicBank;
    std::unique_ptr<SuperTerminal::MidiEngine>      midiEngine;
    std::unique_ptr<SuperTerminal::CoreAudioEngine> coreAudioEngine;

    // ── Voice synthesiser (VS) ─────────────────────────────────────────────
    std::unique_ptr<SuperTerminal::VoiceController> voiceController;

    // ── AVAudioEngine graph ────────────────────────────────────────────────
    AVAudioEngine*      audioEngine;
    std::vector<AVAudioPlayerNode*> sfxNodes;
    std::atomic<uint32_t> nextSfxNode{0};
    AVAudioSourceNode*  vsSourceNode;   // real-time voice synth source
    AVAudioFormat*      audioFormat;

    // ── State ──────────────────────────────────────────────────────────────
    std::atomic<bool>  initialized{false};
    std::atomic<float> soundVolume{1.0f};
    std::atomic<float> musicVolume{1.0f};

    // ── Music playback state ───────────────────────────────────────────────
    //  0 = Stopped, 1 = Playing, 2 = Paused
    std::atomic<int>   musicState{0};
    // Per-musicId → active MidiEngine sequence id (supports simultaneous tracks)
    std::unordered_map<uint32_t, int> activeSeqByMusicId;
    // ── Compiled music bank (precompiled by compiler, no runtime ABC parse)
    std::unordered_map<uint32_t, CompiledMusicData> compiledMusicBank;
    uint32_t nextCompiledMusicId{kCompiledMusicIdBase};

    // ── VS recording state ─────────────────────────────────────────────────
    std::atomic<bool>  vsRecording{false};
    std::atomic<float> vsRecordTempoBPM{120.0f};
    std::atomic<float> vsRecordBeatCursor{0.0f};
    std::vector<VSRecordCmd> vsRecordTimeline;
    mutable std::mutex vsRecordTimelineMutex;

    // ── Playback end-time tracking (for soundIsPlaying) ────────────────────
    // Maps soundId → estimated wall-clock end time (seconds since epoch).
    // Updated by soundPlay(); cleared to 0 by soundStopOne().
    std::unordered_map<uint32_t, double> playbackEndTimes;

    // ── Metadata scratch buffers (for returning C strings) ─────────────────
    mutable std::string titleBuf;
    mutable std::string composerBuf;
    mutable std::string keyBuf;
    mutable std::string compiledBlobInfoBuf;

    // ── Thread safety ──────────────────────────────────────────────────────
    mutable std::mutex mutex;

    // ── Constructor / Destructor ───────────────────────────────────────────

    Impl()
        : audioEngine(nil)
        , vsSourceNode(nil)
        , audioFormat(nil)
    {
        synthEngine     = std::make_unique<SynthEngine>();
        soundBank       = std::make_unique<SuperTerminal::SoundBank>();
        musicBank       = std::make_unique<SuperTerminal::MusicBank>();
        midiEngine      = std::make_unique<SuperTerminal::MidiEngine>();
        coreAudioEngine = std::make_unique<SuperTerminal::CoreAudioEngine>();
        voiceController = std::make_unique<SuperTerminal::VoiceController>(8, 44100.0f);
    }

    ~Impl() {
        if (midiEngine) {
            midiEngine->shutdown();
        }
        if (coreAudioEngine) {
            coreAudioEngine->shutdown();
        }
        if (audioEngine) {
            [audioEngine stop];
            audioEngine = nil;
        }
        for (auto* node : sfxNodes) {
            (void)node;
        }
        sfxNodes.clear();
        vsSourceNode = nil;
        audioFormat  = nil;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  Constructor / Destructor
// ═══════════════════════════════════════════════════════════════════════════════

FBAudioManager::FBAudioManager()
    : m_impl(std::make_unique<Impl>())
{
}

FBAudioManager::~FBAudioManager() {
    shutdown();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

bool FBAudioManager::initialize() {
    std::lock_guard<std::mutex> lock(m_impl->mutex);

    if (m_impl->initialized) {
        return true;
    }

    @autoreleasepool {
        NSError* error = nil;

        // ── Create AVAudioEngine ───────────────────────────────────────
        m_impl->audioEngine = [[AVAudioEngine alloc] init];

        // ── Create SFX player-node pool (polyphonic) ──────────────────
        m_impl->sfxNodes.clear();
        m_impl->sfxNodes.reserve(kSfxVoiceCount);
        for (size_t i = 0; i < kSfxVoiceCount; ++i) {
            AVAudioPlayerNode* node = [[AVAudioPlayerNode alloc] init];
            [m_impl->audioEngine attachNode:node];
            m_impl->sfxNodes.push_back(node);
        }

        // ── Audio format: 44.1 kHz, stereo, non-interleaved float ─────
        m_impl->audioFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                      sampleRate:44100.0
                        channels:2
                     interleaved:NO];

        // ── Create VS source node (real-time voice synth) ──────────────
        //
        // AVAudioSourceNode provides a render-block called on the audio
        // thread.  We forward it to VoiceController::generateAudio().
        auto* vc = m_impl->voiceController.get();
        m_impl->vsSourceNode = [[AVAudioSourceNode alloc]
            initWithFormat:m_impl->audioFormat
               renderBlock:^OSStatus(BOOL * _Nonnull isSilence,
                                     const AudioTimeStamp * _Nonnull timestamp,
                                     AVAudioFrameCount frameCount,
                                     AudioBufferList * _Nonnull outputData) {
                // VoiceController writes stereo interleaved → we need
                // to deinterleave into the non-interleaved output.
                // Allocate a small stack buffer for the interleaved data.
                const int maxStack = 4096;
                float stackBuf[maxStack];
                float* interleaved = stackBuf;
                std::vector<float> heapBuf;
                size_t needed = (size_t)frameCount * 2;
                if (needed > maxStack) {
                    heapBuf.resize(needed, 0.0f);
                    interleaved = heapBuf.data();
                } else {
                    std::memset(interleaved, 0, needed * sizeof(float));
                }

                vc->generateAudio(interleaved, (int)frameCount);

                // Deinterleave into the output buffers
                float* left  = (float*)outputData->mBuffers[0].mData;
                float* right = (outputData->mNumberBuffers > 1)
                    ? (float*)outputData->mBuffers[1].mData : left;

                for (AVAudioFrameCount i = 0; i < frameCount; i++) {
                    left[i]  = interleaved[i * 2];
                    right[i] = interleaved[i * 2 + 1];
                }

                return noErr;
            }];

        // ── Connect player → mixer, vsSource → mixer → output ─────────
        @try {
            [m_impl->audioEngine attachNode:m_impl->vsSourceNode];

            for (auto* node : m_impl->sfxNodes) {
                [m_impl->audioEngine connect:node
                                          to:m_impl->audioEngine.mainMixerNode
                                      format:m_impl->audioFormat];
                node.volume = 1.0f;
            }

            [m_impl->audioEngine connect:m_impl->vsSourceNode
                                      to:m_impl->audioEngine.mainMixerNode
                                  format:m_impl->audioFormat];

            [m_impl->audioEngine connect:m_impl->audioEngine.mainMixerNode
                                      to:m_impl->audioEngine.outputNode
                                  format:nil];

            m_impl->audioEngine.mainMixerNode.outputVolume = 1.0f;

            [m_impl->audioEngine prepare];
            [m_impl->audioEngine startAndReturnError:&error];

            if (error) {
                NSLog(@"FBAudioManager: failed to start AVAudioEngine: %@", error);
                return false;
            }

            if (fbForceDefaultOutputEnabled()) {
                AudioDeviceID defaultDeviceId = fbGetDefaultOutputDeviceId();
                if (defaultDeviceId != kAudioObjectUnknown) {
                    AUAudioUnit* outAU = m_impl->audioEngine.outputNode.AUAudioUnit;
                    if (outAU) {
                        NSError* devErr = nil;
                        [outAU setDeviceID:defaultDeviceId error:&devErr];
                        if (devErr) {
                            NSLog(@"FBAudioManager: failed to force default output device (%u): %@",
                                  (unsigned)defaultDeviceId,
                                  devErr);
                        }
                    }
                }
            }

            if (fbAudioDebugEnabledManager()) {
                const AVAudioFormat* outFmt = [m_impl->audioEngine.outputNode outputFormatForBus:0];
                const double outRate = outFmt ? outFmt.sampleRate : 0.0;
                const AVAudioChannelCount outCh = outFmt ? outFmt.channelCount : 0;
                AudioDeviceID defaultDeviceId = fbGetDefaultOutputDeviceId();
                const std::string defaultName = fbAudioDeviceName(defaultDeviceId);
                AUAudioUnit* outAU = m_impl->audioEngine.outputNode.AUAudioUnit;
                AudioObjectID currentOutId = kAudioObjectUnknown;
                if (outAU) currentOutId = outAU.deviceID;
                const std::string currentName = fbAudioDeviceName(currentOutId);
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] engine route out_fmt=%.1fHz/%u ch default_dev=%u(%s) current_dev=%u(%s) force_default=%d\n",
                             outRate,
                             (unsigned)outCh,
                             (unsigned)defaultDeviceId,
                             defaultName.c_str(),
                             (unsigned)currentOutId,
                             currentName.c_str(),
                             fbForceDefaultOutputEnabled() ? 1 : 0);
            }
        }
        @catch (NSException* exception) {
            NSLog(@"FBAudioManager: exception during audio init: %@", exception.reason);
            return false;
        }

        // ── Initialise SynthEngine ─────────────────────────────────────
        SynthConfig cfg;
        cfg.sampleRate  = 44100;
        cfg.channels    = 1;       // generate mono; we fan out to stereo on play
        cfg.bitDepth    = 16;
        cfg.maxDuration = 10.0f;

        if (!m_impl->synthEngine->initialize(cfg)) {
            NSLog(@"FBAudioManager: failed to initialise SynthEngine");
            return false;
        }

        // ── Initialise Music subsystems ────────────────────────────────
        m_impl->coreAudioEngine->initialize();
        m_impl->coreAudioEngine->setSynthEngine(m_impl->synthEngine.get());

        if (!m_impl->midiEngine->initialize(m_impl->coreAudioEngine.get())) {
            NSLog(@"FBAudioManager: warning — MidiEngine init failed (music playback may not work)");
            // Non-fatal: SOUND still works; MUSIC via MIDI won't
        }

        m_impl->initialized = true;
        NSLog(@"FBAudioManager: initialised (44100 Hz, stereo, float32) — SOUND + MUSIC ready");
        return true;
    } // @autoreleasepool
}

void FBAudioManager::shutdown() {
    std::lock_guard<std::mutex> lock(m_impl->mutex);

    if (!m_impl->initialized) {
        return;
    }

    // Stop VS voices
    if (m_impl->voiceController) {
        m_impl->voiceController->resetAllVoices();
    }
    {
        std::lock_guard<std::mutex> vsLock(m_impl->vsRecordTimelineMutex);
        m_impl->vsRecording.store(false, std::memory_order_relaxed);
        m_impl->vsRecordBeatCursor.store(0.0f, std::memory_order_relaxed);
        m_impl->vsRecordTempoBPM.store(120.0f, std::memory_order_relaxed);
        m_impl->vsRecordTimeline.clear();
    }

    // Stop music playback
    if (m_impl->midiEngine && m_impl->midiEngine->isInitialized()) {
        m_impl->midiEngine->allNotesOff();
        m_impl->midiEngine->shutdown();
    }
    if (m_impl->coreAudioEngine) {
        m_impl->coreAudioEngine->shutdown();
    }
    m_impl->musicState = 0;
    m_impl->activeSeqByMusicId.clear();
    m_impl->compiledMusicBank.clear();
    m_impl->nextCompiledMusicId = kCompiledMusicIdBase;

    // Stop sound playback
    for (auto* node : m_impl->sfxNodes) {
        if (node) [node stop];
    }

    if (m_impl->audioEngine) {
        [m_impl->audioEngine stop];
    }

    m_impl->synthEngine->shutdown();
    m_impl->soundBank->freeAll();
    m_impl->musicBank->freeAll();

    m_impl->initialized = false;
    NSLog(@"FBAudioManager: shut down");
}

bool FBAudioManager::isInitialized() const {
    return m_impl->initialized;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Helper — register a SynthAudioBuffer in the SoundBank
// ═══════════════════════════════════════════════════════════════════════════════

static uint32_t registerBuffer(SuperTerminal::SoundBank* bank,
                               std::unique_ptr<SynthAudioBuffer> buf)
{
    if (!buf || buf->samples.empty()) {
        return 0;
    }
    return bank->registerSound(std::move(buf));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Predefined Game Sound Effects
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t FBAudioManager::soundCreateBeep(float frequency, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateBeep(frequency, duration));
}

uint32_t FBAudioManager::soundCreateZap(float frequency, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateZap(frequency, duration));
}

uint32_t FBAudioManager::soundCreateExplode(float size, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateExplode(size, duration));
}

uint32_t FBAudioManager::soundCreateBigExplosion(float size, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateBigExplosion(size, duration));
}

uint32_t FBAudioManager::soundCreateSmallExplosion(float intensity, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSmallExplosion(intensity, duration));
}

uint32_t FBAudioManager::soundCreateDistantExplosion(float distance, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateDistantExplosion(distance, duration));
}

uint32_t FBAudioManager::soundCreateMetalExplosion(float shrapnel, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateMetalExplosion(shrapnel, duration));
}

uint32_t FBAudioManager::soundCreateBang(float intensity, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateBang(intensity, duration));
}

uint32_t FBAudioManager::soundCreateCoin(float pitch, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateCoin(pitch, duration));
}

uint32_t FBAudioManager::soundCreateJump(float power, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateJump(power, duration));
}

uint32_t FBAudioManager::soundCreatePowerup(float intensity, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generatePowerUp(intensity, duration));
}

uint32_t FBAudioManager::soundCreateHurt(float severity, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateHurt(severity, duration));
}

uint32_t FBAudioManager::soundCreateShoot(float power, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateShoot(power, duration));
}

uint32_t FBAudioManager::soundCreateClick(float sharpness, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateClick(sharpness, duration));
}

uint32_t FBAudioManager::soundCreateBlip(float pitch, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateBlip(pitch, duration));
}

uint32_t FBAudioManager::soundCreatePickup(float brightness, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generatePickup(brightness, duration));
}

uint32_t FBAudioManager::soundCreateSweepUp(float startFreq, float endFreq, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSweepUp(startFreq, endFreq, duration));
}

uint32_t FBAudioManager::soundCreateSweepDown(float startFreq, float endFreq, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSweepDown(startFreq, endFreq, duration));
}

uint32_t FBAudioManager::soundCreateRandomBeep(uint32_t seed, float duration) {
    if (!m_impl->initialized) return 0;
    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateRandomBeep(seed, duration));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Custom Synthesis
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t FBAudioManager::soundCreateTone(float frequency, float duration, int waveform) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name      = "Tone";
    effect.duration  = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.envelope.attackTime    = 0.01f;
    effect.envelope.decayTime     = 0.05f;
    effect.envelope.sustainLevel  = 0.8f;
    effect.envelope.releaseTime   = 0.05f;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateNote(int midiNote, float duration, int waveform,
                                          float attack, float decay,
                                          float sustain, float release) {
    if (!m_impl->initialized) return 0;

    float frequency = noteToFrequency(midiNote);

    SynthSoundEffect effect;
    effect.name      = "Note";
    effect.duration  = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.envelope.attackTime   = attack;
    effect.envelope.decayTime    = decay;
    effect.envelope.sustainLevel = sustain;
    effect.envelope.releaseTime  = release;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateNoise(int noiseType, float duration) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name      = "Noise";
    effect.duration  = duration;
    effect.noiseMix  = 1.0f;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    // Noise type affects filtering:
    //   WHITE = raw noise
    //   PINK  = apply crude lowpass (via lower sustain + longer decay)
    //   BROWN = heavier lowpass
    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.05f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime  = 0.05f;

    if (noiseType == FB_NOISE_PINK) {
        // Pink-ish: reduce high-frequency content via mild distortion curve
        effect.distortion = 0.1f;
    } else if (noiseType == FB_NOISE_BROWN) {
        effect.distortion = 0.25f;
    }

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateFM(float carrierFreq, float modFreq,
                                        float modIndex, float duration) {
    if (!m_impl->initialized) return 0;

    // Build an FM sound using the SynthSoundEffect struct.
    // We approximate FM by using two oscillators with phase modulation
    // baked into the generation via pitchSweep and oscillator mixing.
    SynthSoundEffect effect;
    effect.name      = "FM";
    effect.duration  = duration;
    effect.synthesisType = SynthesisType::FM;

    // Carrier oscillator
    Oscillator carrier;
    carrier.waveform  = WaveformType::SINE;
    carrier.frequency = carrierFreq;
    carrier.amplitude = 0.5f;
    carrier.fmAmount  = modIndex;
    carrier.fmFreq    = modFreq;
    effect.oscillators.push_back(carrier);

    effect.fm.carrierFreq   = carrierFreq;
    effect.fm.modulatorFreq = modFreq;
    effect.fm.modIndex      = modIndex;

    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.1f;
    effect.envelope.sustainLevel = 0.7f;
    effect.envelope.releaseTime  = 0.1f;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateFilteredTone(float frequency, float duration,
                                                  int waveform, int filterType,
                                                  float cutoff, float resonance) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name      = "FilteredTone";
    effect.duration  = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.filter.type      = static_cast<FilterType>(filterType);
    effect.filter.cutoffFreq = cutoff;
    effect.filter.resonance  = resonance;
    effect.filter.enabled    = true;
    effect.filter.mix        = 1.0f;

    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.05f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime  = 0.05f;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateFilteredNote(int midiNote, float duration,
                                                  int waveform,
                                                  float attack, float decay,
                                                  float sustain, float release,
                                                  int filterType,
                                                  float cutoff, float resonance) {
    if (!m_impl->initialized) return 0;

    float frequency = noteToFrequency(midiNote);

    SynthSoundEffect effect;
    effect.name      = "FilteredNote";
    effect.duration  = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.filter.type       = static_cast<FilterType>(filterType);
    effect.filter.cutoffFreq = cutoff;
    effect.filter.resonance  = resonance;
    effect.filter.enabled    = true;
    effect.filter.mix        = 1.0f;

    effect.envelope.attackTime   = attack;
    effect.envelope.decayTime    = decay;
    effect.envelope.sustainLevel = sustain;
    effect.envelope.releaseTime  = release;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Effects Processing
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t FBAudioManager::soundCreateWithReverb(float frequency, float duration,
                                                int waveform,
                                                float roomSize, float damping,
                                                float wet) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name     = "ReverbTone";
    effect.duration = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    effect.effects.reverb.enabled  = true;
    effect.effects.reverb.roomSize = roomSize;
    effect.effects.reverb.damping  = damping;
    effect.effects.reverb.wet      = wet;
    effect.effects.reverb.dry      = 1.0f - wet;
    effect.effects.reverb.width    = 1.0f;

    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.05f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime  = 0.1f;

    // Extend duration to accommodate reverb tail
    effect.duration = duration + roomSize * 0.5f;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateWithDelay(float frequency, float duration,
                                               int waveform,
                                               float delayTime, float feedback,
                                               float mix) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name     = "DelayTone";
    effect.duration = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = 0.5f;
    effect.oscillators.push_back(osc);

    // Map delay parameters onto the echo system in SynthSoundEffect
    effect.echoDelay = delayTime;
    effect.echoDecay = feedback;
    effect.echoCount = static_cast<int>(3.0f / (1.0f - std::min(feedback, 0.95f)));
    if (effect.echoCount < 1) effect.echoCount = 1;
    if (effect.echoCount > 20) effect.echoCount = 20;

    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.05f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime  = 0.05f;

    // Extend buffer to hold echo tail
    float tailDuration = delayTime * effect.echoCount;
    effect.duration = duration + tailDuration;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

uint32_t FBAudioManager::soundCreateWithDistortion(float frequency, float duration,
                                                    int waveform,
                                                    float drive, float tone,
                                                    float level) {
    if (!m_impl->initialized) return 0;

    SynthSoundEffect effect;
    effect.name     = "DistortTone";
    effect.duration = duration;
    effect.synthesisType = SynthesisType::SUBTRACTIVE;

    Oscillator osc;
    osc.waveform  = static_cast<WaveformType>(waveform);
    osc.frequency = frequency;
    osc.amplitude = level;
    effect.oscillators.push_back(osc);

    effect.distortion = drive;

    effect.envelope.attackTime   = 0.01f;
    effect.envelope.decayTime    = 0.05f;
    effect.envelope.sustainLevel = 0.8f;
    effect.envelope.releaseTime  = 0.05f;

    return registerBuffer(m_impl->soundBank.get(),
                          m_impl->synthEngine->generateSound(effect));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Playback
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::soundPlay(uint32_t soundId, float volume, float pan) {
    if (!m_impl->initialized) {
        if (fbAudioDebugEnabledManager()) {
            std::fprintf(stderr, "[FB_AUDIO_DEBUG] soundPlay rejected: manager not initialized\n");
        }
        return;
    }

    if (soundId == 0) {
        if (fbAudioDebugEnabledManager()) {
            std::fprintf(stderr, "[FB_AUDIO_DEBUG] soundPlay rejected: soundId=0\n");
        }
        return;
    }

    // Retrieve PCM buffer from SoundBank
    const SynthAudioBuffer* buffer = m_impl->soundBank->getSound(soundId);
    if (!buffer || buffer->samples.empty()) {
        NSLog(@"FBAudioManager: sound ID %u not found", soundId);
        if (fbAudioDebugEnabledManager()) {
            const bool exists = m_impl->soundBank ? m_impl->soundBank->hasSound(soundId) : false;
            const size_t count = m_impl->soundBank ? m_impl->soundBank->getSoundCount() : 0;
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] soundPlay missing buffer id=%u exists=%d count=%zu\n",
                         soundId,
                         exists ? 1 : 0,
                         count);
        }
        return;
    }

    @autoreleasepool {
        float samplePeak = 0.0f;
        float sampleRms = 0.0f;
        if (fbAudioDebugEnabledManager() && !buffer->samples.empty()) {
            double sumSq = 0.0;
            for (float s : buffer->samples) {
                const float a = std::fabs(s);
                if (a > samplePeak) samplePeak = a;
                sumSq += (double)s * (double)s;
            }
            sampleRms = (float)std::sqrt(sumSq / (double)buffer->samples.size());
        }

        // Convert SynthAudioBuffer → AVAudioPCMBuffer (stereo, non-interleaved)
        AVAudioFrameCount frameCount = (AVAudioFrameCount)buffer->getFrameCount();
        AVAudioPCMBuffer* pcmBuffer =
            [[AVAudioPCMBuffer alloc] initWithPCMFormat:m_impl->audioFormat
                                          frameCapacity:frameCount];
        pcmBuffer.frameLength = frameCount;

        float* leftChannel  = pcmBuffer.floatChannelData[0];
        float* rightChannel = pcmBuffer.floatChannelData[1];

        // Apply master volume and per-play volume
        float finalVolume = volume * m_impl->soundVolume.load();

        // Constant-power pan law (equal-power)
        //   pan: -1.0 = full left, 0.0 = centre, 1.0 = full right
        float leftGain  = 1.0f;
        float rightGain = 1.0f;

        if (pan < 0.0f) {
            rightGain = 1.0f + pan;   // pan is negative → reduces right
        } else if (pan > 0.0f) {
            leftGain = 1.0f - pan;
        }

        leftGain  *= finalVolume;
        rightGain *= finalVolume;

        // Copy samples — SynthEngine generates mono (channels == 1) or stereo
        size_t sampleIndex = 0;
        for (AVAudioFrameCount i = 0; i < frameCount; i++) {
            if (buffer->channels == 1) {
                // Mono → stereo with pan
                float sample = buffer->samples[sampleIndex++];
                leftChannel[i]  = sample * leftGain;
                rightChannel[i] = sample * rightGain;
            } else {
                // Stereo with pan
                leftChannel[i]  = buffer->samples[sampleIndex++] * leftGain;
                rightChannel[i] = buffer->samples[sampleIndex++] * rightGain;
            }
        }

        // Choose a voice from the SFX pool; this avoids serial queueing on one node.
        AVAudioPlayerNode* playerNode = nil;
        uint32_t voiceIndex = 0;
        if (!m_impl->sfxNodes.empty()) {
            voiceIndex = m_impl->nextSfxNode.fetch_add(1, std::memory_order_relaxed);
            voiceIndex %= (uint32_t)m_impl->sfxNodes.size();
            playerNode = m_impl->sfxNodes[voiceIndex];
        }

        if (!playerNode) {
            if (fbAudioDebugEnabledManager()) {
                std::fprintf(stderr, "[FB_AUDIO_DEBUG] soundPlay rejected: no SFX player nodes\n");
            }
            return;
        }

        // Ensure the chosen player node is running
        if (![playerNode isPlaying]) {
            [playerNode play];
        }

        // Schedule the buffer for immediate playback (non-blocking, fire-and-forget)
        [playerNode scheduleBuffer:pcmBuffer
                                    atTime:nil
                                   options:0
                         completionHandler:nil];

        if (fbAudioDebugEnabledManager()) {
            const int engineRunning = (m_impl->audioEngine && m_impl->audioEngine.isRunning) ? 1 : 0;
            const int nodePlaying = (playerNode && [playerNode isPlaying]) ? 1 : 0;
            const float nodeVol = playerNode ? playerNode.volume : -1.0f;
            const float mixerVol = m_impl->audioEngine ? m_impl->audioEngine.mainMixerNode.outputVolume : -1.0f;
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] soundPlay scheduled id=%u voice=%u/%zu frames=%u sr=%u ch=%u reqVol=%.3f master=%.3f final=%.3f pan=%.3f peak=%.4f rms=%.4f engine=%d node=%d nodeVol=%.3f mixVol=%.3f\n",
                         soundId,
                         (unsigned)voiceIndex,
                         m_impl->sfxNodes.size(),
                         (unsigned)frameCount,
                         (unsigned)buffer->sampleRate,
                         (unsigned)buffer->channels,
                         volume,
                         m_impl->soundVolume.load(),
                         finalVolume,
                         pan,
                         samplePeak,
                         sampleRms,
                         engineRunning,
                         nodePlaying,
                         nodeVol,
                         mixerVol);
        }

        // Record estimated end time so soundIsPlaying() can query it.
        if (buffer->sampleRate > 0) {
            using clock = std::chrono::steady_clock;
            using dsec  = std::chrono::duration<double>;
            double now = std::chrono::duration_cast<dsec>(clock::now().time_since_epoch()).count();
            double dur = (double)buffer->getFrameCount() / (double)buffer->sampleRate;
            std::lock_guard<std::mutex> lk(m_impl->mutex);
            m_impl->playbackEndTimes[soundId] = now + dur;
        }
    }
}

void FBAudioManager::soundStop() {
    if (!m_impl->initialized) return;

    for (auto* node : m_impl->sfxNodes) {
        if (node) [node stop];
    }
    std::lock_guard<std::mutex> lk(m_impl->mutex);
    m_impl->playbackEndTimes.clear();
}

void FBAudioManager::soundStopOne(uint32_t soundId) {
    // We cannot cancel a single scheduled AVAudioPlayerNode buffer once enqueued,
    // so this is a logical stop: mark the slot as no longer playing so that
    // soundIsPlaying() returns false and BASIC code can re-trigger cleanly.
    std::lock_guard<std::mutex> lk(m_impl->mutex);
    m_impl->playbackEndTimes[soundId] = 0.0;
}

bool FBAudioManager::soundIsPlaying(uint32_t soundId) const {
    using clock = std::chrono::steady_clock;
    using dsec  = std::chrono::duration<double>;
    double now = std::chrono::duration_cast<dsec>(clock::now().time_since_epoch()).count();
    std::lock_guard<std::mutex> lk(m_impl->mutex);
    auto it = m_impl->playbackEndTimes.find(soundId);
    if (it == m_impl->playbackEndTimes.end()) return false;
    return now < it->second;
}

float FBAudioManager::soundGetDuration(uint32_t soundId) const {
    if (!m_impl->soundBank) return 0.0f;
    const SynthAudioBuffer* buffer = m_impl->soundBank->getSound(soundId);
    if (!buffer || buffer->sampleRate == 0) return 0.0f;
    return (float)buffer->getFrameCount() / (float)buffer->sampleRate;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

bool FBAudioManager::soundFree(uint32_t soundId) {
    if (!m_impl->soundBank) return false;
    return m_impl->soundBank->freeSound(soundId);
}

void FBAudioManager::soundFreeAll() {
    if (m_impl->soundBank) {
        m_impl->soundBank->freeAll();
    }
}

bool FBAudioManager::soundExportWav(uint32_t soundId, const char* filename, float volume) {
    if (!m_impl->soundBank || !filename || filename[0] == '\0') {
        return false;
    }

    const SynthAudioBuffer* buffer = m_impl->soundBank->getSound(soundId);
    if (!buffer || buffer->samples.empty() || buffer->channels == 0 || buffer->sampleRate == 0) {
        return false;
    }

    std::ofstream out(filename, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
        return false;
    }

    const uint16_t channels = static_cast<uint16_t>(buffer->channels);
    const uint16_t bitsPerSample = 16;
    const uint32_t bytesPerSample = bitsPerSample / 8;
    const uint32_t frameCount = static_cast<uint32_t>(buffer->getFrameCount());
    const uint32_t dataSize = frameCount * channels * bytesPerSample;
    const uint32_t riffSize = 36 + dataSize;
    const uint32_t byteRate = buffer->sampleRate * channels * bytesPerSample;
    const uint16_t blockAlign = static_cast<uint16_t>(channels * bytesPerSample);

    out.write("RIFF", 4);
    out.write(reinterpret_cast<const char*>(&riffSize), 4);
    out.write("WAVE", 4);

    out.write("fmt ", 4);
    uint32_t fmtSize = 16;
    out.write(reinterpret_cast<const char*>(&fmtSize), 4);
    uint16_t audioFormat = 1;
    out.write(reinterpret_cast<const char*>(&audioFormat), 2);
    out.write(reinterpret_cast<const char*>(&channels), 2);
    out.write(reinterpret_cast<const char*>(&buffer->sampleRate), 4);
    out.write(reinterpret_cast<const char*>(&byteRate), 4);
    out.write(reinterpret_cast<const char*>(&blockAlign), 2);
    out.write(reinterpret_cast<const char*>(&bitsPerSample), 2);

    out.write("data", 4);
    out.write(reinterpret_cast<const char*>(&dataSize), 4);

    const float gain = std::max(0.0f, volume);
    for (float s : buffer->samples) {
        const float clamped = std::clamp(s * gain, -1.0f, 1.0f);
        const int16_t sample16 = static_cast<int16_t>(clamped * 32767.0f);
        out.write(reinterpret_cast<const char*>(&sample16), 2);
    }

    return out.good();
}

uint32_t FBAudioManager::soundImportSynthMemory(uint32_t synthMemoryId) {
    if (!m_impl->soundBank) {
        return 0;
    }

    auto buffer = synth_take_memory_buffer(synthMemoryId);
    if (!buffer) {
        return 0;
    }

    return m_impl->soundBank->registerSound(std::move(buffer));
}

bool FBAudioManager::soundDiscardSynthMemory(uint32_t synthMemoryId) {
    return synth_free_memory_buffer(synthMemoryId);
}

void FBAudioManager::setSoundVolume(float volume) {
    m_impl->soundVolume = std::clamp(volume, 0.0f, 1.0f);
}

float FBAudioManager::getSoundVolume() const {
    return m_impl->soundVolume;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Queries
// ═══════════════════════════════════════════════════════════════════════════════

bool FBAudioManager::soundExists(uint32_t soundId) const {
    if (!m_impl->soundBank) return false;
    return m_impl->soundBank->hasSound(soundId);
}

size_t FBAudioManager::soundGetCount() const {
    if (!m_impl->soundBank) return 0;
    return m_impl->soundBank->getSoundCount();
}

size_t FBAudioManager::soundGetMemoryUsage() const {
    if (!m_impl->soundBank) return 0;
    return m_impl->soundBank->getMemoryUsage();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Utility
// ═══════════════════════════════════════════════════════════════════════════════

float FBAudioManager::noteToFrequency(int midiNote) {
    return 440.0f * std::pow(2.0f, (midiNote - 69) / 12.0f);
}

int FBAudioManager::frequencyToNote(float frequency) {
    if (frequency <= 0.0f) return 0;
    return static_cast<int>(std::round(69.0f + 12.0f * std::log2(frequency / 440.0f)));
}

void FBAudioManager::stopAll() {
    soundStop();
    musicStop();
    vsReset();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Helper: optionally record a command if recording is active
// ═══════════════════════════════════════════════════════════════════════════════

static void vsRecordPush(std::atomic<bool>& recording,
                         std::atomic<float>& beatCursor,
                         std::vector<VSRecordCmd>& timeline,
                         std::mutex& timelineMutex,
                         VSRecordCmd cmd) {
    if (!recording.load(std::memory_order_relaxed)) {
        return;
    }

    cmd.beat = beatCursor.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(timelineMutex);
    timeline.push_back(std::move(cmd));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Oscillator
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetWaveform(int voiceNum, int waveform) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setWaveform(voiceNum,
        static_cast<SuperTerminal::VoiceWaveform>(waveform));
    VSRecordCmd c; c.type = VSRecordCmdType::Waveform;
    c.iarg1 = voiceNum; c.iarg2 = waveform;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetFrequency(int voiceNum, float hz) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFrequency(voiceNum, hz);
    VSRecordCmd c; c.type = VSRecordCmdType::Frequency;
    c.iarg1 = voiceNum; c.farg1 = hz;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetNote(int voiceNum, int midiNote) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setNote(voiceNum, midiNote);
    VSRecordCmd c; c.type = VSRecordCmdType::Note;
    c.iarg1 = voiceNum; c.iarg2 = midiNote;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetNoteName(int voiceNum, const char* name) {
    if (!m_impl->initialized || !name) return;
    m_impl->voiceController->setNoteName(voiceNum, name);
    VSRecordCmd c; c.type = VSRecordCmdType::NoteName;
    c.iarg1 = voiceNum; c.sarg = name;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPulseWidth(int voiceNum, float width) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPulseWidth(voiceNum, width);
    VSRecordCmd c; c.type = VSRecordCmdType::PulseWidth;
    c.iarg1 = voiceNum; c.farg1 = width;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Envelope
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetEnvelope(int voiceNum, float attackMs, float decayMs,
                                    float sustainLevel, float releaseMs) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setEnvelope(voiceNum, attackMs, decayMs,
                                          sustainLevel, releaseMs);
    VSRecordCmd c; c.type = VSRecordCmdType::Envelope;
    c.iarg1 = voiceNum; c.farg1 = attackMs; c.farg2 = decayMs;
    c.farg3 = sustainLevel; c.farg4 = releaseMs;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Gate
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetGate(int voiceNum, bool gateOn) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setGate(voiceNum, gateOn);
    VSRecordCmd c; c.type = VSRecordCmdType::Gate;
    c.iarg1 = voiceNum; c.barg = gateOn;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Volume & Pan
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetVolume(int voiceNum, float level) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setVolume(voiceNum, level);
    VSRecordCmd c; c.type = VSRecordCmdType::Volume;
    c.iarg1 = voiceNum; c.farg1 = level;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPan(int voiceNum, float position) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPan(voiceNum, position);
    VSRecordCmd c; c.type = VSRecordCmdType::Pan;
    c.iarg1 = voiceNum; c.farg1 = position;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetMasterVolume(float level) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setMasterVolume(level);
    VSRecordCmd c; c.type = VSRecordCmdType::MasterVolume; c.farg1 = level;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Filter
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetFilterType(int filterType) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFilterType(
        static_cast<SuperTerminal::VoiceFilterType>(filterType));
    VSRecordCmd c; c.type = VSRecordCmdType::FilterType; c.iarg1 = filterType;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetFilterCutoff(float hz) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFilterCutoff(hz);
    VSRecordCmd c; c.type = VSRecordCmdType::FilterCutoff; c.farg1 = hz;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetFilterResonance(float q) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFilterResonance(q);
    VSRecordCmd c; c.type = VSRecordCmdType::FilterResonance; c.farg1 = q;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetFilterEnabled(bool enabled) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFilterEnabled(enabled);
    VSRecordCmd c; c.type = VSRecordCmdType::FilterEnabled; c.barg = enabled;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetFilterRouting(int voiceNum, bool enabled) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setFilterRouting(voiceNum, enabled);
    VSRecordCmd c; c.type = VSRecordCmdType::FilterRoute;
    c.iarg1 = voiceNum; c.barg = enabled;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Modulation
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetRingMod(int voiceNum, int sourceVoice) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setRingMod(voiceNum, sourceVoice);
    VSRecordCmd c; c.type = VSRecordCmdType::RingMod;
    c.iarg1 = voiceNum; c.iarg2 = sourceVoice;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetSync(int voiceNum, int sourceVoice) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setSync(voiceNum, sourceVoice);
    VSRecordCmd c; c.type = VSRecordCmdType::Sync;
    c.iarg1 = voiceNum; c.iarg2 = sourceVoice;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPortamento(int voiceNum, float timeSeconds) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPortamento(voiceNum, timeSeconds);
    VSRecordCmd c; c.type = VSRecordCmdType::Portamento;
    c.iarg1 = voiceNum; c.farg1 = timeSeconds;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetDetune(int voiceNum, float cents) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setDetune(voiceNum, cents);
    VSRecordCmd c; c.type = VSRecordCmdType::Detune;
    c.iarg1 = voiceNum; c.farg1 = cents;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Per-Voice Delay
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetDelayEnabled(int voiceNum, bool enabled) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setDelayEnabled(voiceNum, enabled);
    VSRecordCmd c; c.type = VSRecordCmdType::DelayEnabled;
    c.iarg1 = voiceNum; c.barg = enabled;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetDelayTime(int voiceNum, float timeSeconds) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setDelayTime(voiceNum, timeSeconds);
    VSRecordCmd c; c.type = VSRecordCmdType::DelayTime;
    c.iarg1 = voiceNum; c.farg1 = timeSeconds;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetDelayFeedback(int voiceNum, float feedback) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setDelayFeedback(voiceNum, feedback);
    VSRecordCmd c; c.type = VSRecordCmdType::DelayFeedback;
    c.iarg1 = voiceNum; c.farg1 = feedback;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetDelayMix(int voiceNum, float mix) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setDelayMix(voiceNum, mix);
    VSRecordCmd c; c.type = VSRecordCmdType::DelayMix;
    c.iarg1 = voiceNum; c.farg1 = mix;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — LFO
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetLFOWaveform(int lfoNum, int waveform) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFOWaveform(lfoNum,
        static_cast<SuperTerminal::LFOWaveform>(waveform));
    VSRecordCmd c; c.type = VSRecordCmdType::LFOWaveform;
    c.iarg1 = lfoNum; c.iarg2 = waveform;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetLFORate(int lfoNum, float rateHz) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFORate(lfoNum, rateHz);
    VSRecordCmd c; c.type = VSRecordCmdType::LFORate;
    c.iarg1 = lfoNum; c.farg1 = rateHz;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsResetLFO(int lfoNum) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->resetLFO(lfoNum);
    VSRecordCmd c; c.type = VSRecordCmdType::LFOReset; c.iarg1 = lfoNum;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetLFOToPitch(int voiceNum, int lfoNum, float depthCents) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFOToPitch(voiceNum, lfoNum, depthCents);
    VSRecordCmd c; c.type = VSRecordCmdType::LFOPitch;
    c.iarg1 = voiceNum; c.iarg2 = lfoNum; c.farg1 = depthCents;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetLFOToVolume(int voiceNum, int lfoNum, float depth) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFOToVolume(voiceNum, lfoNum, depth);
    VSRecordCmd c; c.type = VSRecordCmdType::LFOVolume;
    c.iarg1 = voiceNum; c.iarg2 = lfoNum; c.farg1 = depth;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetLFOToFilter(int voiceNum, int lfoNum, float depthHz) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFOToFilter(voiceNum, lfoNum, depthHz);
    VSRecordCmd c; c.type = VSRecordCmdType::LFOFilter;
    c.iarg1 = voiceNum; c.iarg2 = lfoNum; c.farg1 = depthHz;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetLFOToPulseWidth(int voiceNum, int lfoNum, float depth) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setLFOToPulseWidth(voiceNum, lfoNum, depth);
    VSRecordCmd c; c.type = VSRecordCmdType::LFOPulse;
    c.iarg1 = voiceNum; c.iarg2 = lfoNum; c.farg1 = depth;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Physical Modeling
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsSetPhysicalModel(int voiceNum, int modelType) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalModel(voiceNum,
        static_cast<SuperTerminal::PhysicalModelType>(modelType));
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalModel;
    c.iarg1 = voiceNum; c.iarg2 = modelType;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalDamping(int voiceNum, float damping) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalDamping(voiceNum, damping);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalDamping;
    c.iarg1 = voiceNum; c.farg1 = damping;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalBrightness(int voiceNum, float brightness) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalBrightness(voiceNum, brightness);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalBrightness;
    c.iarg1 = voiceNum; c.farg1 = brightness;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalExcitation(int voiceNum, float excitation) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalExcitation(voiceNum, excitation);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalExcitation;
    c.iarg1 = voiceNum; c.farg1 = excitation;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalResonance(int voiceNum, float resonance) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalResonance(voiceNum, resonance);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalResonance;
    c.iarg1 = voiceNum; c.farg1 = resonance;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalTension(int voiceNum, float tension) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalTension(voiceNum, tension);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalTension;
    c.iarg1 = voiceNum; c.farg1 = tension;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsSetPhysicalPressure(int voiceNum, float pressure) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->setPhysicalPressure(voiceNum, pressure);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalPressure;
    c.iarg1 = voiceNum; c.farg1 = pressure;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

void FBAudioManager::vsTriggerPhysical(int voiceNum) {
    if (!m_impl->initialized) return;
    m_impl->voiceController->triggerPhysical(voiceNum);
    VSRecordCmd c; c.type = VSRecordCmdType::PhysicalTrigger;
    c.iarg1 = voiceNum;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Global Control
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsReset() {
    if (!m_impl->initialized) return;
    m_impl->voiceController->resetAllVoices();
    VSRecordCmd c; c.type = VSRecordCmdType::Reset;
    vsRecordPush(m_impl->vsRecording, m_impl->vsRecordBeatCursor, m_impl->vsRecordTimeline, m_impl->vsRecordTimelineMutex, c);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Queries
// ═══════════════════════════════════════════════════════════════════════════════

int FBAudioManager::vsGetActiveCount() const {
    if (!m_impl->initialized) return 0;
    return m_impl->voiceController->getActiveVoiceCount();
}

float FBAudioManager::vsGetMasterVolume() const {
    if (!m_impl->initialized) return 0.0f;
    return m_impl->voiceController->getMasterVolume();
}

bool FBAudioManager::vsIsPlaying() const {
    if (!m_impl->initialized) return false;
    return m_impl->voiceController->getActiveVoiceCount() > 0;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Recording & Rendering helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Replay one recorded command onto a VoiceController instance.
static void vsReplayCmd(SuperTerminal::VoiceController& vc, const VSRecordCmd& c) {
    using T = VSRecordCmdType;
    switch (c.type) {
        case T::Waveform:
            vc.setWaveform(c.iarg1, static_cast<SuperTerminal::VoiceWaveform>(c.iarg2)); break;
        case T::Frequency:
            vc.setFrequency(c.iarg1, c.farg1); break;
        case T::Note:
            vc.setNote(c.iarg1, c.iarg2); break;
        case T::NoteName:
            vc.setNoteName(c.iarg1, c.sarg); break;
        case T::PulseWidth:
            vc.setPulseWidth(c.iarg1, c.farg1); break;
        case T::Envelope:
            vc.setEnvelope(c.iarg1, c.farg1, c.farg2, c.farg3, c.farg4); break;
        case T::Gate:
            vc.setGate(c.iarg1, c.barg); break;
        case T::Volume:
            vc.setVolume(c.iarg1, c.farg1); break;
        case T::Pan:
            vc.setPan(c.iarg1, c.farg1); break;
        case T::MasterVolume:
            vc.setMasterVolume(c.farg1); break;
        case T::FilterType:
            vc.setFilterType(static_cast<SuperTerminal::VoiceFilterType>(c.iarg1)); break;
        case T::FilterCutoff:
            vc.setFilterCutoff(c.farg1); break;
        case T::FilterResonance:
            vc.setFilterResonance(c.farg1); break;
        case T::FilterEnabled:
            vc.setFilterEnabled(c.barg); break;
        case T::FilterRoute:
            vc.setFilterRouting(c.iarg1, c.barg); break;
        case T::RingMod:
            vc.setRingMod(c.iarg1, c.iarg2); break;
        case T::Sync:
            vc.setSync(c.iarg1, c.iarg2); break;
        case T::Portamento:
            vc.setPortamento(c.iarg1, c.farg1); break;
        case T::Detune:
            vc.setDetune(c.iarg1, c.farg1); break;
        case T::DelayEnabled:
            vc.setDelayEnabled(c.iarg1, c.barg); break;
        case T::DelayTime:
            vc.setDelayTime(c.iarg1, c.farg1); break;
        case T::DelayFeedback:
            vc.setDelayFeedback(c.iarg1, c.farg1); break;
        case T::DelayMix:
            vc.setDelayMix(c.iarg1, c.farg1); break;
        case T::LFOWaveform:
            vc.setLFOWaveform(c.iarg1, static_cast<SuperTerminal::LFOWaveform>(c.iarg2)); break;
        case T::LFORate:
            vc.setLFORate(c.iarg1, c.farg1); break;
        case T::LFOReset:
            vc.resetLFO(c.iarg1); break;
        case T::LFOPitch:
            vc.setLFOToPitch(c.iarg1, c.iarg2, c.farg1); break;
        case T::LFOVolume:
            vc.setLFOToVolume(c.iarg1, c.iarg2, c.farg1); break;
        case T::LFOFilter:
            vc.setLFOToFilter(c.iarg1, c.iarg2, c.farg1); break;
        case T::LFOPulse:
            vc.setLFOToPulseWidth(c.iarg1, c.iarg2, c.farg1); break;
        case T::PhysicalModel:
            vc.setPhysicalModel(c.iarg1, static_cast<SuperTerminal::PhysicalModelType>(c.iarg2)); break;
        case T::PhysicalDamping:
            vc.setPhysicalDamping(c.iarg1, c.farg1); break;
        case T::PhysicalBrightness:
            vc.setPhysicalBrightness(c.iarg1, c.farg1); break;
        case T::PhysicalExcitation:
            vc.setPhysicalExcitation(c.iarg1, c.farg1); break;
        case T::PhysicalResonance:
            vc.setPhysicalResonance(c.iarg1, c.farg1); break;
        case T::PhysicalTension:
            vc.setPhysicalTension(c.iarg1, c.farg1); break;
        case T::PhysicalPressure:
            vc.setPhysicalPressure(c.iarg1, c.farg1); break;
        case T::PhysicalTrigger:
            vc.triggerPhysical(c.iarg1); break;
        case T::Reset:
            vc.resetAllVoices(); break;
    }
}

/// Offline-render the recorded timeline into a mono PCM buffer.
/// Returns a SynthAudioBuffer, or nullptr on failure.
static std::unique_ptr<SynthAudioBuffer> vsRenderTimeline(
    const std::vector<VSRecordCmd>& timeline,
    float tempoBPM, float sampleRate, float masterVolume)
{
    if (timeline.empty()) return nullptr;

    // Find the last beat position to compute total duration
    float lastBeat = 0.0f;
    for (const auto& c : timeline) {
        if (c.beat > lastBeat) lastBeat = c.beat;
    }
    // Add a tail of 2 beats for release / reverb
    float totalBeats = lastBeat + 2.0f;
    float beatsPerSecond = tempoBPM / 60.0f;
    float totalSeconds = totalBeats / beatsPerSecond;
    size_t totalFrames = static_cast<size_t>(totalSeconds * sampleRate);
    if (totalFrames == 0) return nullptr;

    // Create an offline VoiceController
    SuperTerminal::VoiceController vc(8, sampleRate);
    vc.setMasterVolume(masterVolume);

    // Sort timeline by beat
    auto sorted = timeline;
    std::sort(sorted.begin(), sorted.end(),
              [](const VSRecordCmd& a, const VSRecordCmd& b) {
                  return a.beat < b.beat;
              });

    // Render in small chunks, dispatching commands at the right beat
    const int chunkFrames = 256;
    float stereoChunk[chunkFrames * 2];

    auto buf = std::make_unique<SynthAudioBuffer>(
        static_cast<uint32_t>(sampleRate), 1);
    buf->samples.resize(totalFrames, 0.0f);

    size_t cmdIdx = 0;
    size_t outPos = 0;

    for (size_t frame = 0; frame < totalFrames; frame += chunkFrames) {
        float currentBeat = (static_cast<float>(frame) / sampleRate) * beatsPerSecond;

        // Dispatch all commands whose beat <= currentBeat
        while (cmdIdx < sorted.size() && sorted[cmdIdx].beat <= currentBeat) {
            vsReplayCmd(vc, sorted[cmdIdx]);
            cmdIdx++;
        }

        int framesToRender = std::min((int)(totalFrames - frame), chunkFrames);
        std::memset(stereoChunk, 0, sizeof(float) * framesToRender * 2);
        vc.generateAudio(stereoChunk, framesToRender);

        // Down-mix stereo to mono
        for (int i = 0; i < framesToRender && outPos < totalFrames; i++, outPos++) {
            buf->samples[outPos] = (stereoChunk[i * 2] + stereoChunk[i * 2 + 1]) * 0.5f;
        }
    }

    buf->duration = totalSeconds;
    return buf;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Recording API
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::vsRecordStart() {
    if (!m_impl->initialized) return;
    std::lock_guard<std::mutex> lock(m_impl->vsRecordTimelineMutex);
    m_impl->vsRecording.store(true, std::memory_order_relaxed);
    m_impl->vsRecordBeatCursor.store(0.0f, std::memory_order_relaxed);
    m_impl->vsRecordTempoBPM.store(120.0f, std::memory_order_relaxed);
    m_impl->vsRecordTimeline.clear();
}

void FBAudioManager::vsRecordTempo(float bpm) {
    if (!m_impl->initialized) return;
    m_impl->vsRecordTempoBPM.store((bpm > 0.0f) ? bpm : 120.0f, std::memory_order_relaxed);
}

void FBAudioManager::vsRecordWait(float beats) {
    if (!m_impl->initialized) return;
    if (beats > 0.0f) {
        float cur = m_impl->vsRecordBeatCursor.load(std::memory_order_relaxed);
        m_impl->vsRecordBeatCursor.store(cur + beats, std::memory_order_relaxed);
    }
}

uint32_t FBAudioManager::vsRecordSave(float volume) {
    if (!m_impl->initialized) return 0;
    std::vector<VSRecordCmd> timelineCopy;
    float tempo = 120.0f;
    {
        std::lock_guard<std::mutex> lock(m_impl->vsRecordTimelineMutex);
        m_impl->vsRecording.store(false, std::memory_order_relaxed);
        timelineCopy = m_impl->vsRecordTimeline;
        m_impl->vsRecordTimeline.clear();
        tempo = m_impl->vsRecordTempoBPM.load(std::memory_order_relaxed);
    }

    auto buf = vsRenderTimeline(timelineCopy, tempo, 44100.0f, volume);

    if (!buf || buf->samples.empty()) return 0;
    return m_impl->soundBank->registerSound(std::move(buf));
}

void FBAudioManager::vsRecordPlay(float volume) {
    if (!m_impl->initialized) return;
    uint32_t id = vsRecordSave(volume);
    if (id != 0) {
        soundPlay(id, 1.0f, 0.0f);
    }
}

void FBAudioManager::vsRecordWav(const char* filename) {
    if (!m_impl->initialized || !filename) return;
    std::vector<VSRecordCmd> timelineCopy;
    float tempo = 120.0f;
    {
        std::lock_guard<std::mutex> lock(m_impl->vsRecordTimelineMutex);
        m_impl->vsRecording.store(false, std::memory_order_relaxed);
        timelineCopy = m_impl->vsRecordTimeline;
        m_impl->vsRecordTimeline.clear();
        tempo = m_impl->vsRecordTempoBPM.load(std::memory_order_relaxed);
    }

    auto buf = vsRenderTimeline(timelineCopy, tempo, 44100.0f, 1.0f);

    if (!buf || buf->samples.empty()) return;

    // Write a minimal 16-bit mono WAV
    std::ofstream out(filename, std::ios::binary);
    if (!out.is_open()) return;

    uint32_t sampleRate = 44100;
    uint16_t bitsPerSample = 16;
    uint16_t numChannels = 1;
    uint32_t numSamples = static_cast<uint32_t>(buf->samples.size());
    uint32_t dataSize = numSamples * (bitsPerSample / 8) * numChannels;
    uint32_t fileSize = 36 + dataSize;

    // RIFF header
    out.write("RIFF", 4);
    out.write(reinterpret_cast<const char*>(&fileSize), 4);
    out.write("WAVE", 4);

    // fmt chunk
    out.write("fmt ", 4);
    uint32_t fmtSize = 16;
    out.write(reinterpret_cast<const char*>(&fmtSize), 4);
    uint16_t audioFormat = 1; // PCM
    out.write(reinterpret_cast<const char*>(&audioFormat), 2);
    out.write(reinterpret_cast<const char*>(&numChannels), 2);
    out.write(reinterpret_cast<const char*>(&sampleRate), 4);
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    out.write(reinterpret_cast<const char*>(&byteRate), 4);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);
    out.write(reinterpret_cast<const char*>(&blockAlign), 2);
    out.write(reinterpret_cast<const char*>(&bitsPerSample), 2);

    // data chunk
    out.write("data", 4);
    out.write(reinterpret_cast<const char*>(&dataSize), 4);

    for (size_t i = 0; i < buf->samples.size(); i++) {
        float s = std::clamp(buf->samples[i], -1.0f, 1.0f);
        int16_t sample16 = static_cast<int16_t>(s * 32767.0f);
        out.write(reinterpret_cast<const char*>(&sample16), 2);
    }

    out.close();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Inline Playback
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::musicPlay(const char* abcNotation, float volume) {
    (void)abcNotation;
    (void)volume;
    NSLog(@"FBAudioManager: musicPlay inline ABC is unsupported; compile ABC into a blob before playback");
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank (Load and Play by Slot)
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t FBAudioManager::musicLoadString(const char* abcNotation) {
    if (!m_impl->initialized || !abcNotation) return 0;
    return m_impl->musicBank->loadFromString(abcNotation);
}

uint32_t FBAudioManager::musicLoadCompiledBlob(const void* blobData, size_t blobSize) {
    const bool trace_blob = fbAudioDebugEnabledManager() || (std::getenv("ED_TRACE_ABC") != nullptr);

    if (!m_impl->initialized || !blobData || blobSize == 0) {
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob rejected init=%d blob=%p size=%zu\n",
                         m_impl->initialized.load() ? 1 : 0,
                         blobData,
                         blobSize);
        }
        return 0;
    }

    const auto* cur = static_cast<const uint8_t*>(blobData);
    const auto* end = cur + blobSize;

    uint32_t magic = 0;
    uint32_t version = 0;
    uint32_t programCount = 0;
    uint32_t noteCount = 0;
    double tempo = 0.0;

    if (!readU32LE(cur, end, magic) ||
        !readU32LE(cur, end, version) ||
        !readF64LE(cur, end, tempo) ||
        !readU32LE(cur, end, programCount) ||
        !readU32LE(cur, end, noteCount)) {
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob header decode failed size=%zu\n",
                         blobSize);
        }
        return 0;
    }

    if (trace_blob) {
        std::fprintf(stderr,
                     "[FB_AUDIO_DEBUG] musicLoadCompiledBlob header size=%zu magic=0x%08x version=%u tempo=%.3f programs=%u notes=%u\n",
                     blobSize,
                     magic,
                     version,
                     tempo,
                     programCount,
                     noteCount);
    }

    if (magic != kCompiledMusicMagic || version != kCompiledMusicVersion) {
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob invalid header expected_magic=0x%08x got_magic=0x%08x expected_version=%u got_version=%u\n",
                         kCompiledMusicMagic,
                         magic,
                         kCompiledMusicVersion,
                         version);
        }
        return 0;
    }

    CompiledMusicData compiled;
    compiled.tempo = (tempo > 0.0) ? static_cast<float>(tempo) : 120.0f;
    compiled.programs.reserve(programCount);
    compiled.notes.reserve(noteCount);

    for (uint32_t i = 0; i < programCount; ++i) {
        if (static_cast<size_t>(end - cur) < 4) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob truncated program[%u] remaining=%zu\n",
                             i,
                             static_cast<size_t>(end - cur));
            }
            return 0;
        }
        const uint8_t channel = cur[0];
        const uint8_t program = cur[1];
        cur += 4; // skip reserved bytes

        if (channel < 1 || channel > 16) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob invalid program channel index=%u channel=%u\n",
                             i,
                             channel);
            }
            return 0;
        }

        CompiledMusicProgram p;
        p.channel = channel;
        p.program = static_cast<uint8_t>(std::min<int>(program, 127));
        compiled.programs.push_back(p);

        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob program[%u] channel=%u program=%u\n",
                         i,
                         p.channel,
                         p.program);
        }
    }

    for (uint32_t i = 0; i < noteCount; ++i) {
        double startBeats = 0.0;
        double durationBeats = 0.0;
        if (!readF64LE(cur, end, startBeats) || !readF64LE(cur, end, durationBeats)) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob truncated note timing[%u] remaining=%zu\n",
                             i,
                             static_cast<size_t>(end - cur));
            }
            return 0;
        }
        if (static_cast<size_t>(end - cur) < 4) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob truncated note payload[%u] remaining=%zu\n",
                             i,
                             static_cast<size_t>(end - cur));
            }
            return 0;
        }

        const uint8_t midiNote = cur[0];
        const uint8_t velocity = cur[1];
        const uint8_t channel = cur[2];
        cur += 4;

        if (channel < 1 || channel > 16) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob invalid note channel index=%u channel=%u\n",
                             i,
                             channel);
            }
            return 0;
        }
        if (midiNote > 127) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicLoadCompiledBlob invalid midi note index=%u midi=%u\n",
                             i,
                             midiNote);
            }
            return 0;
        }

        CompiledMusicNote n;
        n.startBeats = std::max(0.0, startBeats);
        n.durationBeats = std::max(0.0, durationBeats);
        n.midiNote = midiNote;
        n.velocity = velocity;
        n.channel = channel;
        compiled.notes.push_back(n);

        if (trace_blob && i < 16) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob note[%u] start=%.6f dur=%.6f midi=%u vel=%u ch=%u\n",
                         i,
                         n.startBeats,
                         n.durationBeats,
                         n.midiNote,
                         n.velocity,
                         n.channel);
        }
    }

    if (cur != end) {
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicLoadCompiledBlob trailing bytes=%zu\n",
                         static_cast<size_t>(end - cur));
        }
        return 0;
    }

    const uint32_t id = m_impl->nextCompiledMusicId++;
    m_impl->compiledMusicBank[id] = std::move(compiled);
    if (trace_blob) {
        const auto& data = m_impl->compiledMusicBank[id];
        std::fprintf(stderr,
                     "[FB_AUDIO_DEBUG] musicLoadCompiledBlob stored id=%u tempo=%.3f programs=%zu notes=%zu\n",
                     id,
                     data.tempo,
                     data.programs.size(),
                     data.notes.size());
    }
    if (std::getenv("ED_TRACE_ABC") != nullptr) {
        m_impl->compiledBlobInfoBuf = buildCompiledMusicBlobSummary(id, m_impl->compiledMusicBank[id]);
        NSLog(@"FBAudioManager: musicLoadCompiledBlob %s", m_impl->compiledBlobInfoBuf.c_str());
    }
    return id;
}

void FBAudioManager::musicPlayId(uint32_t musicId, float volume) {
    if (!m_impl->initialized) return;
    const bool trace_blob = fbAudioDebugEnabledManager() || (std::getenv("ED_TRACE_ABC") != nullptr);

    if (auto it = m_impl->compiledMusicBank.find(musicId);
        it != m_impl->compiledMusicBank.end()) {

        auto& midi = m_impl->midiEngine;
        if (!midi || !midi->isInitialized()) {
            NSLog(@"FBAudioManager: musicPlayId(compiled) — MidiEngine not initialised");
            return;
        }

        // Stop only the sequence previously associated with this musicId
        auto prevIt = m_impl->activeSeqByMusicId.find(musicId);
        if (prevIt != m_impl->activeSeqByMusicId.end()) {
            midi->stopSequence(prevIt->second);
            midi->deleteSequence(prevIt->second);
            m_impl->activeSeqByMusicId.erase(prevIt);
        }

        const auto& data = it->second;
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicPlayId(compiled) id=%u tempo=%.3f programs=%zu notes=%zu reqVol=%.3f masterVol=%.3f\n",
                         musicId,
                         data.tempo,
                         data.programs.size(),
                         data.notes.size(),
                         volume,
                         m_impl->musicVolume.load());
        }
        const int seqId = midi->createSequence("Compiled", static_cast<double>(data.tempo));
        auto* sequence = midi->getSequence(seqId);
        if (!sequence) {
            if (trace_blob) {
                std::fprintf(stderr,
                             "[FB_AUDIO_DEBUG] musicPlayId(compiled) failed to get sequence id=%d for musicId=%u\n",
                             seqId,
                             musicId);
            }
            return;
        }

        std::unordered_map<int, int> channelToTrack;

        auto ensureTrack = [&](int channel) -> SuperTerminal::MidiTrack* {
            auto trackIt = channelToTrack.find(channel);
            if (trackIt == channelToTrack.end()) {
                const std::string trackName = "CH" + std::to_string(channel);
                const int trackIdx = sequence->addTrack(trackName, channel);
                channelToTrack[channel] = trackIdx;
                return sequence->getTrack(trackIdx);
            }
            return sequence->getTrack(trackIt->second);
        };

        for (const auto& program : data.programs) {
            auto* track = ensureTrack(static_cast<int>(program.channel));
            if (track) {
                track->addProgramChange(static_cast<int>(program.program), 0.0);
                if (trace_blob) {
                    std::fprintf(stderr,
                                 "[FB_AUDIO_DEBUG] musicPlayId(compiled) program channel=%u program=%u\n",
                                 program.channel,
                                 program.program);
                }
            }
        }

        for (const auto& note : data.notes) {
            if (note.durationBeats <= 0.0) continue;
            auto* track = ensureTrack(static_cast<int>(note.channel));
            if (!track) continue;
            track->addNote(
                static_cast<int>(note.midiNote),
                static_cast<int>(note.velocity),
                note.startBeats,
                note.durationBeats
            );
        }

        const double seqLen = sequence->calculateLength();
        if (trace_blob) {
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicPlayId(compiled) sequence id=%d trackCount=%d lengthBeats=%.6f\n",
                         seqId,
                         sequence->getTrackCount(),
                         seqLen);
        }
        midi->setMasterVolume(volume * m_impl->musicVolume.load());
        const bool play_ok = midi->playSequence(seqId, volume);

        if (trace_blob) {
            const auto active = midi->getActiveSequences();
            std::fprintf(stderr,
                         "[FB_AUDIO_DEBUG] musicPlayId(compiled) playSequence=%d activeSequences=%zu\n",
                         play_ok ? 1 : 0,
                         active.size());
        }

        if (!play_ok) {
            midi->deleteSequence(seqId);
            return;
        }

        m_impl->activeSeqByMusicId[musicId] = seqId;
        m_impl->musicState = 1;
        return;
    }

    const auto* data = m_impl->musicBank->getMusic(musicId);
    if (data) {
        NSLog(@"FBAudioManager: musicPlayId — runtime ABC playback is unsupported for music ID %u", musicId);
        return;
    }

    NSLog(@"FBAudioManager: musicPlayId — music ID %u not found", musicId);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Playback Control
// ═══════════════════════════════════════════════════════════════════════════════

void FBAudioManager::musicStop() {
    if (!m_impl->initialized) return;

    auto& midi = m_impl->midiEngine;
    if (midi && midi->isInitialized()) {
        for (auto& [musicId, seqId] : m_impl->activeSeqByMusicId) {
            (void)musicId;
            midi->stopSequence(seqId);
            midi->deleteSequence(seqId);
        }
        m_impl->activeSeqByMusicId.clear();
        midi->allNotesOff();
    }
    m_impl->musicState = 0; // Stopped
}

void FBAudioManager::musicPause() {
    if (!m_impl->initialized) return;

    auto& midi = m_impl->midiEngine;
    if (midi && midi->isInitialized()) {
        for (auto& [musicId, seqId] : m_impl->activeSeqByMusicId) {
            (void)musicId;
            midi->pauseSequence(seqId);
        }
    }

    if (!m_impl->activeSeqByMusicId.empty()) {
        m_impl->musicState = 2; // Paused
    }
}

void FBAudioManager::musicResume() {
    if (!m_impl->initialized) return;

    auto& midi = m_impl->midiEngine;
    if (midi && midi->isInitialized()) {
        for (auto& [musicId, seqId] : m_impl->activeSeqByMusicId) {
            (void)musicId;
            midi->resumeSequence(seqId);
        }
    }

    if (!m_impl->activeSeqByMusicId.empty()) {
        m_impl->musicState = 1; // Playing
    }
}

void FBAudioManager::setMusicVolume(float volume) {
    m_impl->musicVolume = std::clamp(volume, 0.0f, 1.0f);
    if (m_impl->midiEngine && m_impl->midiEngine->isInitialized()) {
        m_impl->midiEngine->setMasterVolume(m_impl->musicVolume.load());
    }
}

float FBAudioManager::getMusicVolume() const {
    return m_impl->musicVolume;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

bool FBAudioManager::musicFree(uint32_t musicId) {
    if (auto it = m_impl->compiledMusicBank.find(musicId);
        it != m_impl->compiledMusicBank.end()) {
        m_impl->compiledMusicBank.erase(it);
        return true;
    }
    if (!m_impl->musicBank) return false;
    return m_impl->musicBank->freeMusic(musicId);
}

void FBAudioManager::musicFreeAll() {
    m_impl->compiledMusicBank.clear();
    if (m_impl->musicBank) {
        m_impl->musicBank->freeAll();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Queries
// ═══════════════════════════════════════════════════════════════════════════════

bool FBAudioManager::isMusicPlaying() const {
    bool anyPlaying = false;

    if (m_impl->midiEngine && m_impl->midiEngine->isInitialized()) {
        const auto active = m_impl->midiEngine->getActiveSequences();
        const std::unordered_set<int> activeSet(active.begin(), active.end());

        for (auto it = m_impl->activeSeqByMusicId.begin(); it != m_impl->activeSeqByMusicId.end(); ) {
            if (activeSet.count(it->second)) {
                anyPlaying = true;
                ++it;
            } else {
                it = m_impl->activeSeqByMusicId.erase(it);
            }
        }
    }

    if (!anyPlaying) m_impl->musicState.store(0);
    return anyPlaying;
}

bool FBAudioManager::isMusicPlayingId(uint32_t musicId) const {
    auto it = m_impl->activeSeqByMusicId.find(musicId);
    if (it == m_impl->activeSeqByMusicId.end()) return false;

    if (!m_impl->midiEngine || !m_impl->midiEngine->isInitialized()) return false;
    const auto active = m_impl->midiEngine->getActiveSequences();
    for (int id : active) {
        if (id == it->second) return true;
    }
    // Sequence finished naturally — clean up
    m_impl->activeSeqByMusicId.erase(it);
    return false;
}

int FBAudioManager::getMusicState() const {
    return m_impl->musicState.load();
}

bool FBAudioManager::musicExists(uint32_t musicId) const {
    if (m_impl->compiledMusicBank.find(musicId) != m_impl->compiledMusicBank.end()) {
        return true;
    }
    if (!m_impl->musicBank) return false;
    return m_impl->musicBank->hasMusic(musicId);
}

size_t FBAudioManager::musicGetCount() const {
    size_t count = m_impl->compiledMusicBank.size();
    if (m_impl->musicBank) {
        count += m_impl->musicBank->getMusicCount();
    }
    return count;
}

size_t FBAudioManager::musicGetMemoryUsage() const {
    size_t bytes = 0;
    for (const auto& it : m_impl->compiledMusicBank) {
        bytes += it.second.getMemoryUsage();
    }
    if (m_impl->musicBank) {
        bytes += m_impl->musicBank->getMemoryUsage();
    }
    return bytes;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Metadata
// ═══════════════════════════════════════════════════════════════════════════════

const char* FBAudioManager::musicGetTitle(uint32_t musicId) const {
    if (!m_impl->musicBank) return "";
    m_impl->titleBuf = m_impl->musicBank->getTitle(musicId);
    return m_impl->titleBuf.c_str();
}

const char* FBAudioManager::musicGetComposer(uint32_t musicId) const {
    if (!m_impl->musicBank) return "";
    m_impl->composerBuf = m_impl->musicBank->getComposer(musicId);
    return m_impl->composerBuf.c_str();
}

const char* FBAudioManager::musicGetKey(uint32_t musicId) const {
    if (!m_impl->musicBank) return "";
    m_impl->keyBuf = m_impl->musicBank->getKey(musicId);
    return m_impl->keyBuf.c_str();
}

float FBAudioManager::musicGetTempo(uint32_t musicId) const {
    if (auto it = m_impl->compiledMusicBank.find(musicId);
        it != m_impl->compiledMusicBank.end()) {
        return it->second.tempo;
    }
    if (!m_impl->musicBank) return 0.0f;
    return m_impl->musicBank->getTempo(musicId);
}

const char* FBAudioManager::musicGetCompiledBlobInfo(uint32_t musicId) const {
    if (auto it = m_impl->compiledMusicBank.find(musicId);
        it != m_impl->compiledMusicBank.end()) {
        m_impl->compiledBlobInfoBuf = buildCompiledMusicBlobSummary(musicId, it->second);
        return m_impl->compiledBlobInfoBuf.c_str();
    }

    if (m_impl->musicBank && m_impl->musicBank->hasMusic(musicId)) {
        m_impl->compiledBlobInfoBuf = "format=ABC;id=" + std::to_string(musicId) + ";compiled=0";
        return m_impl->compiledBlobInfoBuf.c_str();
    }

    m_impl->compiledBlobInfoBuf.clear();
    return "";
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Rendering (offline ABC → SoundBank)
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t FBAudioManager::musicRenderToSoundBank(const char* abcNotation,
                                                  float duration,
                                                  float sampleRate) {
    (void)abcNotation; (void)duration; (void)sampleRate;
    NSLog(@"FBAudioManager: musicRenderToSoundBank — inline ABC rendering not available");
    return 0;
}

bool FBAudioManager::musicRenderWav(const char* abcNotation,
                                    const char* filename,
                                    float duration,
                                    float sampleRate) {
    const uint32_t soundId = musicRenderToSoundBank(abcNotation, duration, sampleRate);
    if (soundId == 0) {
        return false;
    }
    return soundExportWav(soundId, filename, 1.0f);
}

bool FBAudioManager::musicExportMidi(uint32_t musicId, const char* filename) {
    if (!filename || filename[0] == '\0') {
        return false;
    }

    auto it = m_impl->compiledMusicBank.find(musicId);
    if (it == m_impl->compiledMusicBank.end()) {
        if (m_impl->musicBank && m_impl->musicBank->hasMusic(musicId)) {
            NSLog(@"FBAudioManager: musicExportMidi — runtime ABC export is unsupported for music ID %u", musicId);
            return false;
        }

        NSLog(@"FBAudioManager: musicExportMidi — music ID %u not found", musicId);
        return false;
    }

    const auto& data = it->second;
    constexpr uint16_t ppq = 480;

    struct MidiEvent {
        uint32_t tick;
        uint8_t priority;
        std::vector<uint8_t> bytes;
    };

    std::vector<MidiEvent> events;
    events.reserve(data.programs.size() + data.notes.size() * 2 + 1);

    for (const auto& program : data.programs) {
        const uint8_t ch = static_cast<uint8_t>(std::clamp<int>(program.channel, 1, 16) - 1);
        const uint8_t prg = static_cast<uint8_t>(std::clamp<int>(program.program, 0, 127));
        events.push_back(MidiEvent{0, 0, std::vector<uint8_t>{ static_cast<uint8_t>(0xC0 | ch), prg }});
    }

    for (const auto& note : data.notes) {
        if (note.durationBeats <= 0.0) continue;
        const uint8_t ch = static_cast<uint8_t>(std::clamp<int>(note.channel, 1, 16) - 1);
        const uint8_t midi = static_cast<uint8_t>(std::clamp<int>(note.midiNote, 0, 127));
        const uint8_t vel = static_cast<uint8_t>(std::clamp<int>(note.velocity, 0, 127));

        const uint32_t startTick = static_cast<uint32_t>(std::llround(std::max(0.0, note.startBeats) * ppq));
        const uint32_t endTick = static_cast<uint32_t>(std::llround(std::max(0.0, note.startBeats + note.durationBeats) * ppq));

        events.push_back(MidiEvent{startTick, 2, std::vector<uint8_t>{ static_cast<uint8_t>(0x90 | ch), midi, vel }});
        events.push_back(MidiEvent{std::max(startTick, endTick), 1, std::vector<uint8_t>{ static_cast<uint8_t>(0x80 | ch), midi, 0 }});
    }

    std::sort(events.begin(), events.end(), [](const MidiEvent& a, const MidiEvent& b) {
        if (a.tick != b.tick) return a.tick < b.tick;
        return a.priority < b.priority;
    });

    std::vector<uint8_t> track;
    track.reserve(events.size() * 6 + 32);

    // Tempo meta event at tick 0.
    const double bpm = std::max(1.0, static_cast<double>(data.tempo));
    const uint32_t usPerQuarter = static_cast<uint32_t>(std::llround(60000000.0 / bpm));
    appendVarLen(track, 0);
    track.push_back(0xFF);
    track.push_back(0x51);
    track.push_back(0x03);
    track.push_back(static_cast<uint8_t>((usPerQuarter >> 16) & 0xFF));
    track.push_back(static_cast<uint8_t>((usPerQuarter >> 8) & 0xFF));
    track.push_back(static_cast<uint8_t>(usPerQuarter & 0xFF));

    uint32_t prevTick = 0;
    for (const auto& ev : events) {
        appendVarLen(track, ev.tick - prevTick);
        prevTick = ev.tick;
        track.insert(track.end(), ev.bytes.begin(), ev.bytes.end());
    }

    appendVarLen(track, 0);
    track.push_back(0xFF);
    track.push_back(0x2F);
    track.push_back(0x00);

    std::ofstream out(filename, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
        return false;
    }

    out.write("MThd", 4);
    writeU32BE(out, 6);
    writeU16BE(out, 0);   // format 0
    writeU16BE(out, 1);   // one track
    writeU16BE(out, ppq); // division

    out.write("MTrk", 4);
    writeU32BE(out, static_cast<uint32_t>(track.size()));
    out.write(reinterpret_cast<const char*>(track.data()), static_cast<std::streamsize>(track.size()));

    return out.good();
}
