//
// MusicBank.cpp
// SuperTerminal v2
//
// Music bank implementation - ID-based music storage and management.
//

#include "MusicBank.h"
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cctype>
#include <cstdlib>

namespace SuperTerminal {

// =============================================================================
// MusicData Implementation
// =============================================================================

void MusicData::parseMetadata() {
    // Parse ABC notation headers
    // Basic parser for X:, T:, C:, K:, M:, Q: fields
    
    std::istringstream iss(abcNotation);
    std::string line;
    
    while (std::getline(iss, line)) {
        // Trim whitespace
        line.erase(0, line.find_first_not_of(" \t\r\n"));
        line.erase(line.find_last_not_of(" \t\r\n") + 1);
        
        if (line.empty()) continue;
        
        // Parse header fields
        if (line.size() >= 2 && line[1] == ':') {
            char field = line[0];
            std::string value = line.substr(2);
            
            // Trim value
            value.erase(0, value.find_first_not_of(" \t"));
            value.erase(value.find_last_not_of(" \t") + 1);
            
            switch (field) {
                case 'X': // Reference number
                    referenceNumber = std::atoi(value.c_str());
                    break;
                    
                case 'T': // Title
                    title = value;
                    break;
                    
                case 'C': // Composer
                    composer = value;
                    break;
                    
                case 'K': // Key signature
                    key = value;
                    break;
                    
                case 'M': // Meter/time signature
                    meter = value;
                    break;
                    
                case 'Q': // Tempo
                {
                    // Parse tempo (e.g., "1/4=120" or just "120")
                    size_t eqPos = value.find('=');
                    if (eqPos != std::string::npos && eqPos + 1 < value.size()) {
                        float t = static_cast<float>(std::atof(value.substr(eqPos + 1).c_str()));
                        tempo = (t > 0.0f) ? t : 120.0f;
                    } else {
                        float t = static_cast<float>(std::atof(value.c_str()));
                        tempo = (t > 0.0f) ? t : 120.0f;
                    }
                    break;
                }
                    
                default:
                    // Ignore other fields
                    break;
            }
        }
        
        // Stop parsing at first note line (after K: field, which should be last header)
        if (!key.empty() && line.size() > 0 && line[1] != ':') {
            break;
        }
    }
}

// =============================================================================
// Constructor / Destructor
// =============================================================================

MusicBank::MusicBank()
    : nextId_(1)
{
}

MusicBank::~MusicBank() {
    freeAll();
}

// =============================================================================
// Music Loading & Registration
// =============================================================================

uint32_t MusicBank::loadFromString(const std::string& abcNotation) {
    if (abcNotation.empty()) {
        return 0; // Empty notation
    }
    
    // Validate basic ABC structure
    if (!validateABC(abcNotation)) {
        return 0; // Invalid ABC notation
    }
    
    // Create music data
    auto data = std::make_unique<MusicData>(abcNotation);
    
    // Register and return ID
    return registerMusic(std::move(data));
}

uint32_t MusicBank::loadFromFile(const std::string& filename) {
    if (filename.empty()) {
        return 0; // Empty filename
    }
    
    // Open file
    std::ifstream file(filename);
    if (!file.is_open()) {
        return 0; // Could not open file
    }
    
    // Read entire file into string
    std::stringstream buffer;
    buffer << file.rdbuf();
    std::string abcNotation = buffer.str();
    
    file.close();
    
    // Load from the string
    return loadFromString(abcNotation);
}

uint32_t MusicBank::registerMusic(std::unique_ptr<MusicData> data) {
    if (!data) {
        return 0; // Invalid data
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    // Assign ID and store
    uint32_t id = nextId_++;
    music_[id] = std::move(data);
    
    return id;
}

// =============================================================================
// Music Retrieval
// =============================================================================

const MusicData* MusicBank::getMusic(uint32_t id) const {
    if (id == 0) {
        return nullptr;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    auto it = music_.find(id);
    if (it != music_.end()) {
        return it->second.get();
    }
    
    return nullptr;
}

std::string MusicBank::getABCNotation(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->abcNotation;
    }
    return "";
}

bool MusicBank::hasMusic(uint32_t id) const {
    if (id == 0) {
        return false;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    return music_.find(id) != music_.end();
}

size_t MusicBank::getMusicCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return music_.size();
}

// =============================================================================
// Metadata Queries
// =============================================================================

std::string MusicBank::getTitle(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->title;
    }
    return "";
}

std::string MusicBank::getComposer(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->composer;
    }
    return "";
}

std::string MusicBank::getKey(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->key;
    }
    return "";
}

std::string MusicBank::getMeter(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->meter;
    }
    return "";
}

float MusicBank::getTempo(uint32_t id) const {
    const MusicData* data = getMusic(id);
    if (data) {
        return data->tempo;
    }
    return 0.0f;
}

// =============================================================================
// Music Management
// =============================================================================

bool MusicBank::freeMusic(uint32_t id) {
    if (id == 0) {
        return false;
    }
    
    std::lock_guard<std::mutex> lock(mutex_);
    
    auto it = music_.find(id);
    if (it != music_.end()) {
        music_.erase(it);
        return true;
    }
    
    return false;
}

void MusicBank::freeAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    music_.clear();
}

size_t MusicBank::getMemoryUsage() const {
    std::lock_guard<std::mutex> lock(mutex_);
    
    size_t totalBytes = 0;
    for (const auto& pair : music_) {
        if (pair.second) {
            totalBytes += pair.second->getMemoryUsage();
        }
    }
    
    return totalBytes;
}

std::vector<uint32_t> MusicBank::getAllMusicIds() const {
    std::lock_guard<std::mutex> lock(mutex_);
    
    std::vector<uint32_t> ids;
    ids.reserve(music_.size());
    
    for (const auto& pair : music_) {
        ids.push_back(pair.first);
    }
    
    return ids;
}

// =============================================================================
// Private Helper Methods
// =============================================================================

bool MusicBank::validateABC(const std::string& abc) const {
    if (abc.empty()) {
        return false;
    }
    
    // Basic validation: check for required X: and K: fields
    bool hasX = false;
    bool hasK = false;
    
    std::istringstream iss(abc);
    std::string line;
    
    while (std::getline(iss, line)) {
        // Trim whitespace
        line.erase(0, line.find_first_not_of(" \t\r\n"));
        line.erase(line.find_last_not_of(" \t\r\n") + 1);
        
        if (line.empty()) continue;
        
        // Check for X: field
        if (line.size() >= 2 && line[0] == 'X' && line[1] == ':') {
            hasX = true;
        }
        
        // Check for K: field
        if (line.size() >= 2 && line[0] == 'K' && line[1] == ':') {
            hasK = true;
            break; // K: should be the last header field
        }
    }
    
    // ABC notation requires at minimum X: and K: fields
    return hasX && hasK;
}

} // namespace SuperTerminal