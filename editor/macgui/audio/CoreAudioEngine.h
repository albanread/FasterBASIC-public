//
// CoreAudioEngine.h
// SuperTerminal v2
//
// Stub/adapter for CoreAudio functionality
// Provides compatibility layer for MidiEngine
//

#ifndef SUPERTERMINAL_COREAUDIO_ENGINE_H
#define SUPERTERMINAL_COREAUDIO_ENGINE_H

#include <memory>

// Forward declaration (SynthEngine is in global namespace)
class SynthEngine;

namespace SuperTerminal {

/// CoreAudioEngine - Adapter for audio system
///
/// This is a lightweight adapter that provides compatibility
/// between the MidiEngine and the audio playback system.
/// In v2, most audio functionality is handled by AVAudioEngine
/// via AudioManager, so this is primarily a stub for compatibility.
class CoreAudioEngine {
public:
    CoreAudioEngine();
    ~CoreAudioEngine();
    
    /// Initialize the audio engine
    bool initialize();
    
    /// Shutdown the audio engine
    void shutdown();
    
    /// Check if initialized
    bool isInitialized() const { return m_initialized; }
    
    /// Get synth engine (if available)
    ::SynthEngine* getSynthEngine() const { return m_synthEngine; }
    
    /// Set synth engine
    void setSynthEngine(::SynthEngine* synth) { m_synthEngine = synth; }
    
private:
    bool m_initialized;
    ::SynthEngine* m_synthEngine; // Not owned
};

} // namespace SuperTerminal

#endif // SUPERTERMINAL_COREAUDIO_ENGINE_H