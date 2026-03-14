//
// CoreAudioEngine.cpp
// FasterBASIC — CoreAudioEngine stub/adapter
//
// Converted from SuperTerminal v2 CoreAudioEngine.mm to pure C++.
// Removed Obj-C dependencies (NSLog → fprintf).
//
// Provides compatibility layer for MidiEngine.
//

#include "CoreAudioEngine.h"
#include "SynthEngine.h"
#include <cstdio>

namespace SuperTerminal {

CoreAudioEngine::CoreAudioEngine()
    : m_initialized(false)
    , m_synthEngine(nullptr)
{
}

CoreAudioEngine::~CoreAudioEngine() {
    shutdown();
}

bool CoreAudioEngine::initialize() {
    if (m_initialized) {
        return true;
    }

    // Minimal initialization - most audio handled by AVAudioEngine
    m_initialized = true;

    fprintf(stderr, "CoreAudioEngine: Initialized (stub/adapter mode)\n");
    return true;
}

void CoreAudioEngine::shutdown() {
    if (!m_initialized) {
        return;
    }

    m_initialized = false;
    m_synthEngine = nullptr;
}

} // namespace SuperTerminal