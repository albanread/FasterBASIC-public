//
// SoundBank.cpp
// SuperTerminal v2
//
// Sound bank implementation - ID-based sound storage and management.
//

#include "SoundBank.h"
#include <algorithm>

namespace SuperTerminal {

// =============================================================================
// Constructor / Destructor
// =============================================================================

SoundBank::SoundBank()
    : nextId_(1)
{
}

SoundBank::~SoundBank() {
    freeAll();
}

// =============================================================================
// Sound Registration & Retrieval
// =============================================================================

uint32_t SoundBank::registerSound(std::unique_ptr<SynthAudioBuffer> buffer) {
    if (!buffer) {
        return 0; // Invalid buffer
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    // Assign ID and store
    uint32_t id = nextId_++;
    sounds_[id] = std::move(buffer);
    
    return id;
}

const SynthAudioBuffer* SoundBank::getSound(uint32_t id) const {
    if (id == 0) {
        return nullptr;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    auto it = sounds_.find(id);
    if (it != sounds_.end()) {
        return it->second.get();
    }
    
    return nullptr;
}

bool SoundBank::hasSound(uint32_t id) const {
    if (id == 0) {
        return false;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    return sounds_.find(id) != sounds_.end();
}

size_t SoundBank::getSoundCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sounds_.size();
}

// =============================================================================
// Sound Management
// =============================================================================

bool SoundBank::freeSound(uint32_t id) {
    if (id == 0) {
        return false;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    auto it = sounds_.find(id);
    if (it != sounds_.end()) {
        sounds_.erase(it);
        return true;
    }
    
    return false;
}

void SoundBank::freeAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    sounds_.clear();
}

size_t SoundBank::getMemoryUsage() const {
    std::lock_guard<std::mutex> lock(mutex_);
    
    size_t totalBytes = 0;
    for (const auto& pair : sounds_) {
        if (pair.second) {
            // Each float sample is 4 bytes
            totalBytes += pair.second->samples.size() * sizeof(float);
        }
    }
    
    return totalBytes;
}

} // namespace SuperTerminal