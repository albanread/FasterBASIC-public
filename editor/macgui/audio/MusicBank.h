//
// MusicBank.h
// SuperTerminal v2
//
// Music bank for storing and managing ABC notation music by ID.
// Provides ID-based music loading, storage, and metadata management.
//

#ifndef SUPERTERMINAL_MUSIC_BANK_H
#define SUPERTERMINAL_MUSIC_BANK_H

#include <cstdint>
#include <string>
#include <memory>
#include <unordered_map>
#include <mutex>
#include <vector>

namespace SuperTerminal {

/// Music data structure - stores ABC notation and parsed metadata
struct MusicData {
    std::string abcNotation;     // Full ABC notation string
    std::string title;            // Parsed title (T: field)
    std::string composer;         // Parsed composer (C: field)
    std::string key;              // Parsed key signature (K: field)
    std::string meter;            // Parsed meter (M: field)
    int referenceNumber;          // X: field
    float tempo;                  // Q: field (beats per minute)
    
    /// Constructor
    MusicData() : referenceNumber(0), tempo(120.0f) {}
    
    /// Constructor with ABC notation
    explicit MusicData(const std::string& abc) 
        : abcNotation(abc), referenceNumber(0), tempo(120.0f) {
        parseMetadata();
    }
    
    /// Parse metadata from ABC notation
    void parseMetadata();
    
    /// Get approximate memory usage
    size_t getMemoryUsage() const {
        return abcNotation.size() + title.size() + composer.size() + 
               key.size() + meter.size() + sizeof(referenceNumber) + sizeof(tempo);
    }
};

/// MusicBank: ID-based music storage and management
///
/// Responsibilities:
/// - Store ABC notation music strings and assign unique IDs
/// - Parse and cache metadata from ABC notation
/// - Provide thread-safe access to stored music
/// - Manage music lifecycle (creation, retrieval, deletion)
///
/// Usage:
/// - Load music from file or string to get an ID
/// - Play music by referencing its ID
/// - Query metadata (title, composer, etc.)
/// - Free music when no longer needed to reclaim memory
class MusicBank {
public:
    /// Constructor
    MusicBank();
    
    /// Destructor
    ~MusicBank();
    
    // Disable copy, allow move
    MusicBank(const MusicBank&) = delete;
    MusicBank& operator=(const MusicBank&) = delete;
    MusicBank(MusicBank&&) noexcept = delete;
    MusicBank& operator=(MusicBank&&) noexcept = delete;
    
    // =========================================================================
    // Music Loading & Registration
    // =========================================================================
    
    /// Load music from ABC notation string
    /// @param abcNotation ABC notation string
    /// @return Unique music ID (0 = invalid/error)
    uint32_t loadFromString(const std::string& abcNotation);
    
    /// Load music from ABC file
    /// @param filename Path to ABC file
    /// @return Unique music ID (0 = invalid/error)
    uint32_t loadFromFile(const std::string& filename);
    
    /// Register pre-loaded music data
    /// @param data Music data (ownership transferred)
    /// @return Unique music ID (0 = invalid/error)
    uint32_t registerMusic(std::unique_ptr<MusicData> data);
    
    // =========================================================================
    // Music Retrieval
    // =========================================================================
    
    /// Get music data by ID (read-only access)
    /// @param id Music ID
    /// @return Pointer to music data, or nullptr if not found
    const MusicData* getMusic(uint32_t id) const;
    
    /// Get ABC notation string by ID
    /// @param id Music ID
    /// @return ABC notation string (empty if not found)
    std::string getABCNotation(uint32_t id) const;
    
    /// Check if music exists
    /// @param id Music ID
    /// @return true if music exists
    bool hasMusic(uint32_t id) const;
    
    /// Get the number of stored music pieces
    /// @return Number of music pieces in the bank
    size_t getMusicCount() const;
    
    // =========================================================================
    // Metadata Queries
    // =========================================================================
    
    /// Get music title
    /// @param id Music ID
    /// @return Title string (empty if not found)
    std::string getTitle(uint32_t id) const;
    
    /// Get music composer
    /// @param id Music ID
    /// @return Composer string (empty if not found)
    std::string getComposer(uint32_t id) const;
    
    /// Get music key signature
    /// @param id Music ID
    /// @return Key string (empty if not found)
    std::string getKey(uint32_t id) const;
    
    /// Get music meter/time signature
    /// @param id Music ID
    /// @return Meter string (empty if not found)
    std::string getMeter(uint32_t id) const;
    
    /// Get music tempo
    /// @param id Music ID
    /// @return Tempo in BPM (0.0 if not found)
    float getTempo(uint32_t id) const;
    
    // =========================================================================
    // Music Management
    // =========================================================================
    
    /// Free a music piece by ID
    /// @param id Music ID to free
    /// @return true if music was found and freed
    bool freeMusic(uint32_t id);
    
    /// Free all music
    void freeAll();
    
    /// Get total memory usage of all stored music (approximate)
    /// @return Memory usage in bytes
    size_t getMemoryUsage() const;
    
    /// Get all music IDs currently in the bank
    /// @return Vector of music IDs
    std::vector<uint32_t> getAllMusicIds() const;
    
private:
    /// Music storage
    std::unordered_map<uint32_t, std::unique_ptr<MusicData>> music_;
    
    /// Next available ID
    uint32_t nextId_;
    
    /// Thread safety
    mutable std::mutex mutex_;
    
    /// Validate ABC notation (basic check for required fields)
    /// @param abc ABC notation string
    /// @return true if valid
    bool validateABC(const std::string& abc) const;
};

} // namespace SuperTerminal

#endif // SUPERTERMINAL_MUSIC_BANK_H