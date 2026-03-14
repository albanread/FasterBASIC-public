//
//  MidiEngine.h
//  SuperTerminal - MIDI Sequencing and Playback Engine
//
//  Created by Alban on 2024-11-17.
//  Copyright © 2024 SuperTerminal. All rights reserved.
//

#pragma once

#include <string>
#include <vector>
#include <memory>
#include <functional>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <chrono>
#include <thread>

#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreMIDI/CoreMIDI.h>
#include <AVFoundation/AVFoundation.h>
#include <CoreFoundation/CoreFoundation.h>
#endif

class SynthEngine;

namespace SuperTerminal {

// Forward declarations
class CoreAudioEngine;

// MIDI Event types for tracker-style programming
struct MidiNote {
    int channel;
    int note;          // MIDI note number (0-127)
    int velocity;      // Velocity (0-127)
    double startTime;  // Start time in beats
    double duration;   // Duration in beats
    bool isActive;     // Currently playing

    MidiNote(int ch = 1, int n = 60, int vel = 100, double start = 0.0, double dur = 1.0)
        : channel(ch), note(n), velocity(vel), startTime(start), duration(dur), isActive(false) {}
};

struct MidiControlChange {
    int channel;
    int controller;    // CC number (0-127)
    int value;         // CC value (0-127)
    double time;       // Time in beats

    MidiControlChange(int ch = 1, int cc = 0, int val = 0, double t = 0.0)
        : channel(ch), controller(cc), value(val), time(t) {}
};

struct MidiProgramChange {
    int channel;
    int program;       // Instrument number (0-127)
    double time;       // Time in beats

    MidiProgramChange(int ch = 1, int prog = 0, double t = 0.0)
        : channel(ch), program(prog), time(t) {}
};

// MIDI Track for tracker-style composition
class MidiTrack {
public:
    std::string name;
    int channel;
    std::vector<MidiNote> notes;
    std::vector<MidiControlChange> controlChanges;
    std::vector<MidiProgramChange> programChanges;
    bool muted;
    bool soloed;
    float volume;      // Track volume multiplier (0.0-1.0)
    int transpose;     // Transpose amount in semitones

    MidiTrack(const std::string& trackName = "Track", int ch = 1);

    // Add events to track
    void addNote(int note, int velocity, double startTime, double duration);
    void addControlChange(int controller, int value, double time);
    void addProgramChange(int program, double time = 0.0);

    // Track manipulation
    void clear();
    void transposeTrack(int semitones);
    void scaleVelocities(float multiplier);
    void quantize(double gridSize); // Quantize to beat grid

    // Get events at specific time
    std::vector<MidiNote*> getNotesAtTime(double time);
    std::vector<MidiControlChange*> getControlChangesAtTime(double time);
    std::vector<MidiProgramChange*> getProgramChangesAtTime(double time);
};

// MIDI Sequence for complete compositions
class MidiSequence {
public:
    std::string name;
    double tempo;           // BPM
    int timeSignatureNum;   // Time signature numerator
    int timeSignatureDen;   // Time signature denominator
    double length;          // Total length in beats
    std::vector<std::unique_ptr<MidiTrack>> tracks;

    MidiSequence(const std::string& seqName = "Sequence", double bpm = 120.0);
    ~MidiSequence();

    // Track management
    int addTrack(const std::string& name, int channel = 1);
    void removeTrack(int trackIndex);
    MidiTrack* getTrack(int trackIndex);
    int getTrackCount() const { return static_cast<int>(tracks.size()); }

    // Sequence manipulation
    void setTempo(double bpm);
    void setTimeSignature(int numerator, int denominator);
    void clear();
    double calculateLength(); // Calculate total sequence length

    // Pattern-based composition helpers
    void addChord(int trackIndex, const std::vector<int>& notes, int velocity, double startTime, double duration);
    void addArpeggio(int trackIndex, const std::vector<int>& notes, int velocity, double startTime, double stepDuration);
    void addDrumPattern(int trackIndex, const std::vector<int>& drums, const std::vector<bool>& pattern, double startTime, double stepDuration);
};

// MIDI Engine - Main class for MIDI functionality
class MidiEngine {
public:
    MidiEngine();
    ~MidiEngine();

    // Initialization
    bool initialize(CoreAudioEngine* audioEngine);
    void shutdown();
    bool isInitialized() const { return initialized; }

    // File-based MIDI playback
    bool loadMidiFile(const std::string& filename, int sequenceId);
    bool playMidiFile(int sequenceId, float volume = 1.0, bool loop = false);
    void stopMidiFile(int sequenceId);
    void pauseMidiFile(int sequenceId);
    void resumeMidiFile(int sequenceId);
    void setMidiFileVolume(int sequenceId, float volume);

    // Programmatic MIDI sequences
    int createSequence(const std::string& name = "Sequence", double tempo = 120.0);
    bool deleteSequence(int sequenceId);
    MidiSequence* getSequence(int sequenceId);

    // Sequence playback control
    bool playSequence(int sequenceId, float volume = 1.0, bool loop = false);
    void stopSequence(int sequenceId);
    void pauseSequence(int sequenceId);
    void resumeSequence(int sequenceId);
    void setSequenceVolume(int sequenceId, float volume);
    void setSequencePosition(int sequenceId, double beats);
    double getSequencePosition(int sequenceId);

    // Real-time MIDI events
    void playNote(int channel, int note, int velocity, double duration = 0.0);
    void stopNote(int channel, int note);
    void sendControlChange(int channel, int controller, int value);
    void sendProgramChange(int channel, int program);
    void allNotesOff(int channel = -1); // -1 for all channels

    // Global controls
    void setMasterVolume(float volume);
    float getMasterVolume() const { return masterVolume; }
    void setMasterTempo(float tempoMultiplier); // Global tempo scaling

    // Utility functions
    static int noteNameToNumber(const std::string& noteName); // "C4" -> 60
    static std::string noteNumberToName(int noteNumber);       // 60 -> "C4"
    static double beatsToSeconds(double beats, double tempo);
    static double secondsToBeats(double seconds, double tempo);

    // Tracker-style pattern helpers
    std::vector<int> parseChord(const std::string& chordName, int rootNote); // "Cmaj" -> [0,4,7]
    std::vector<int> parseScale(const std::string& scaleName, int rootNote); // "major" -> [0,2,4,5,7,9,11]

    // Status and debugging
    int getActiveNoteCount() const;
    int getLoadedSequenceCount() const;
    std::vector<int> getActiveSequences() const;

    // Callback for custom MIDI processing
    using MidiEventCallback = std::function<void(int channel, int note, int velocity, bool noteOn)>;
    void setMidiEventCallback(MidiEventCallback callback) { midiEventCallback = callback; }

    // Wait for playback completion
    void waitForPlaybackComplete();

private:
    // MIDI timing helpers
    void startSchedulingThread();
    void stopSchedulingThread();
    void schedulingThreadLoop();
    double beatsToMilliseconds(double beats) const;
    // Internal state
    std::atomic<bool> initialized{false};
    CoreAudioEngine* coreAudioEngine;

    // MIDI timing and scheduling
    std::atomic<double> currentTempo{120.0};
    std::chrono::steady_clock::time_point lastTickTime;
    std::mutex schedulingMutex;
    std::condition_variable schedulingCondition;
    std::vector<std::pair<std::chrono::steady_clock::time_point, std::function<void()>>> scheduledEvents;
    std::thread schedulingThread;
    std::atomic<bool> schedulingActive{false};

    // Platform-specific MIDI components
#ifdef __APPLE__
    AudioUnit samplerUnit;
    AUGraph auGraph;
    AUNode samplerNode;
    AUNode outputNode;
    MusicSequence currentMusicSequence;

    bool musicPlayerInitialized;
#endif

    // Sequence management
    std::unordered_map<int, std::unique_ptr<MidiSequence>> sequences;
    std::unordered_map<int, bool> sequencePlaying;
    std::unordered_map<int, float> sequenceVolumes;
    std::unordered_map<int, bool> sequenceLooping;
    int nextSequenceId;

    // Playback state
    std::atomic<float> masterVolume{1.0f};
    std::atomic<float> masterTempoMultiplier{1.0f};

    // Threading
    mutable std::mutex sequenceMutex;
    mutable std::mutex playbackMutex;

    // Real-time note tracking
    struct ActiveNote {
        int channel;
        int note;
        std::chrono::steady_clock::time_point startTime;
        double duration; // 0.0 for infinite
    };
    std::vector<ActiveNote> activeNotes;
    mutable std::mutex activeNotesMutex;

    // Callbacks
    MidiEventCallback midiEventCallback;

    // Internal methods
    bool initializePlatformMidi();
    void shutdownPlatformMidi();
    bool setupSamplerUnit();
    void cleanupSamplerUnit();

    // Sequence conversion
#ifdef __APPLE__
    bool convertSequenceToMusicSequence(MidiSequence* sequence, MusicSequence& musicSequence);
    void addTrackToMusicSequence(MidiTrack* track, MusicSequence& musicSequence);
#endif

    // Playback management
    void updateActiveNotes();
    void startSequencePlayback(int sequenceId);
    void stopSequencePlayback(int sequenceId);

    // Helper methods
    ::SynthEngine* getSynthEngineFromAudio();

    // Utility
    void logError(const std::string& message);
    void logInfo(const std::string& message);
};

// Chord and scale definitions for tracker-style composition
class MidiTheory {
public:
    // Common chord intervals (semitones from root)
    static const std::vector<int> MAJOR_TRIAD;      // [0, 4, 7]
    static const std::vector<int> MINOR_TRIAD;      // [0, 3, 7]
    static const std::vector<int> DIMINISHED_TRIAD; // [0, 3, 6]
    static const std::vector<int> AUGMENTED_TRIAD;  // [0, 4, 8]
    static const std::vector<int> MAJOR_SEVENTH;    // [0, 4, 7, 11]
    static const std::vector<int> MINOR_SEVENTH;    // [0, 3, 7, 10]
    static const std::vector<int> DOMINANT_SEVENTH; // [0, 4, 7, 10]

    // Common scales
    static const std::vector<int> MAJOR_SCALE;      // [0, 2, 4, 5, 7, 9, 11]
    static const std::vector<int> MINOR_SCALE;      // [0, 2, 3, 5, 7, 8, 10]
    static const std::vector<int> PENTATONIC_MAJOR; // [0, 2, 4, 7, 9]
    static const std::vector<int> PENTATONIC_MINOR; // [0, 3, 5, 7, 10]
    static const std::vector<int> BLUES_SCALE;      // [0, 3, 5, 6, 7, 10]
    static const std::vector<int> CHROMATIC_SCALE;  // [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

    // General MIDI drum mapping (channel 10)
    static const int GM_KICK_DRUM = 36;
    static const int GM_SNARE_DRUM = 38;
    static const int GM_CLOSED_HIHAT = 42;
    static const int GM_OPEN_HIHAT = 46;
    static const int GM_CRASH_CYMBAL = 49;
    static const int GM_RIDE_CYMBAL = 51;

    // Utility functions
    static std::vector<int> getChordIntervals(const std::string& chordType);
    static std::vector<int> getScaleIntervals(const std::string& scaleType);
    static std::vector<int> transposeNotes(const std::vector<int>& notes, int semitones);
};

} // namespace SuperTerminal
