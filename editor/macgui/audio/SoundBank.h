//
// SoundBank.h
// SuperTerminal v2
//
// Sound bank for storing and managing synthesized audio buffers by ID.
// Provides ID-based sound creation, storage, and playback management.
//

#ifndef SUPERTERMINAL_SOUND_BANK_H
#define SUPERTERMINAL_SOUND_BANK_H

#include "SynthEngine.h"
#include <cstdint>
#include <memory>
#include <unordered_map>
#include <mutex>

namespace SuperTerminal {

/// SoundBank: ID-based sound storage and management
///
/// Responsibilities:
/// - Store synthesized audio buffers and assign unique IDs
/// - Provide thread-safe access to stored sounds
/// - Manage sound lifecycle (creation, retrieval, deletion)
///
/// Usage:
/// - Create sounds using SynthEngine, then register them to get an ID
/// - Play sounds by referencing their ID
/// - Free sounds when no longer needed to reclaim memory
class SoundBank {
public:
    /// Constructor
    SoundBank();
    
    /// Destructor
    ~SoundBank();
    
    // Disable copy, allow move
    SoundBank(const SoundBank&) = delete;
    SoundBank& operator=(const SoundBank&) = delete;
    SoundBank(SoundBank&&) noexcept = delete;
    SoundBank& operator=(SoundBank&&) noexcept = delete;
    
    // =========================================================================
    // Sound Registration & Retrieval
    // =========================================================================
    
    /// Register a sound buffer and return its unique ID
    /// @param buffer Audio buffer to store (ownership transferred)
    /// @return Unique sound ID (0 = invalid/error)
    uint32_t registerSound(std::unique_ptr<SynthAudioBuffer> buffer);
    
    /// Get a sound buffer by ID (read-only access)
    /// @param id Sound ID
    /// @return Pointer to audio buffer, or nullptr if not found
    const SynthAudioBuffer* getSound(uint32_t id) const;
    
    /// Check if a sound exists
    /// @param id Sound ID
    /// @return true if sound exists
    bool hasSound(uint32_t id) const;
    
    /// Get the number of stored sounds
    /// @return Number of sounds in the bank
    size_t getSoundCount() const;
    
    // =========================================================================
    // Sound Management
    // =========================================================================
    
    /// Free a sound by ID
    /// @param id Sound ID to free
    /// @return true if sound was found and freed
    bool freeSound(uint32_t id);
    
    /// Free all sounds
    void freeAll();
    
    /// Get total memory usage of all stored sounds (approximate)
    /// @return Memory usage in bytes
    size_t getMemoryUsage() const;
    
private:
    /// Sound storage
    std::unordered_map<uint32_t, std::unique_ptr<SynthAudioBuffer>> sounds_;
    
    /// Next available ID
    uint32_t nextId_;
    
    /// Thread safety
    mutable std::mutex mutex_;
};

} // namespace SuperTerminal

#endif // SUPERTERMINAL_SOUND_BANK_H