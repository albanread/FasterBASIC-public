//
//  MidiEngine.mm
//  SuperTerminal - MIDI Sequencing and Playback Engine
//
//  Created by Alban on 2024-11-17.
//  Copyright © 2024 SuperTerminal. All rights reserved.
//

#include "MidiEngine.h"
#include "CoreAudioEngine.h"
#include "SynthEngine.h"
#include <cstdlib>
#include <iostream>
#include <algorithm>
#include <sstream>

namespace SuperTerminal {

// MidiTheory constants
const std::vector<int> MidiTheory::MAJOR_TRIAD = {0, 4, 7};
const std::vector<int> MidiTheory::MINOR_TRIAD = {0, 3, 7};
const std::vector<int> MidiTheory::DIMINISHED_TRIAD = {0, 3, 6};
const std::vector<int> MidiTheory::AUGMENTED_TRIAD = {0, 4, 8};
const std::vector<int> MidiTheory::MAJOR_SEVENTH = {0, 4, 7, 11};
const std::vector<int> MidiTheory::MINOR_SEVENTH = {0, 3, 7, 10};
const std::vector<int> MidiTheory::DOMINANT_SEVENTH = {0, 4, 7, 10};

const std::vector<int> MidiTheory::MAJOR_SCALE = {0, 2, 4, 5, 7, 9, 11};
const std::vector<int> MidiTheory::MINOR_SCALE = {0, 2, 3, 5, 7, 8, 10};
const std::vector<int> MidiTheory::PENTATONIC_MAJOR = {0, 2, 4, 7, 9};
const std::vector<int> MidiTheory::PENTATONIC_MINOR = {0, 3, 5, 7, 10};
const std::vector<int> MidiTheory::BLUES_SCALE = {0, 3, 5, 6, 7, 10};
const std::vector<int> MidiTheory::CHROMATIC_SCALE = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};

// MidiTrack Implementation
MidiTrack::MidiTrack(const std::string& trackName, int ch)
    : name(trackName), channel(ch), muted(false), soloed(false), volume(1.0f), transpose(0) {
}

void MidiTrack::addNote(int note, int velocity, double startTime, double duration) {
    notes.emplace_back(channel, note, velocity, startTime, duration);
}

void MidiTrack::addControlChange(int controller, int value, double time) {
    controlChanges.emplace_back(channel, controller, value, time);
}

void MidiTrack::addProgramChange(int program, double time) {
    programChanges.emplace_back(channel, program, time);
}

void MidiTrack::clear() {
    notes.clear();
    controlChanges.clear();
    programChanges.clear();
}

void MidiTrack::transposeTrack(int semitones) {
    for (auto& note : notes) {
        note.note = std::clamp(note.note + semitones, 0, 127);
    }
    transpose += semitones;
}

void MidiTrack::scaleVelocities(float multiplier) {
    for (auto& note : notes) {
        note.velocity = std::clamp(static_cast<int>(note.velocity * multiplier), 0, 127);
    }
}

void MidiTrack::quantize(double gridSize) {
    for (auto& note : notes) {
        note.startTime = std::round(note.startTime / gridSize) * gridSize;
    }
}

std::vector<MidiNote*> MidiTrack::getNotesAtTime(double time) {
    std::vector<MidiNote*> result;
    for (auto& note : notes) {
        if (note.startTime <= time && (note.startTime + note.duration) > time) {
            result.push_back(&note);
        }
    }
    return result;
}

std::vector<MidiControlChange*> MidiTrack::getControlChangesAtTime(double time) {
    std::vector<MidiControlChange*> result;
    for (auto& cc : controlChanges) {
        if (std::abs(cc.time - time) < 0.001) { // Small tolerance for floating point
            result.push_back(&cc);
        }
    }
    return result;
}

std::vector<MidiProgramChange*> MidiTrack::getProgramChangesAtTime(double time) {
    std::vector<MidiProgramChange*> result;
    for (auto& pc : programChanges) {
        if (std::abs(pc.time - time) < 0.001) {
            result.push_back(&pc);
        }
    }
    return result;
}

// MidiSequence Implementation
MidiSequence::MidiSequence(const std::string& seqName, double bpm)
    : name(seqName), tempo(bpm), timeSignatureNum(4), timeSignatureDen(4), length(0.0) {
}

MidiSequence::~MidiSequence() {
    tracks.clear();
}

int MidiSequence::addTrack(const std::string& name, int channel) {
    auto track = std::make_unique<MidiTrack>(name, channel);
    tracks.push_back(std::move(track));
    return static_cast<int>(tracks.size() - 1);
}

void MidiSequence::removeTrack(int trackIndex) {
    if (trackIndex >= 0 && trackIndex < static_cast<int>(tracks.size())) {
        tracks.erase(tracks.begin() + trackIndex);
    }
}

MidiTrack* MidiSequence::getTrack(int trackIndex) {
    if (trackIndex >= 0 && trackIndex < static_cast<int>(tracks.size())) {
        return tracks[trackIndex].get();
    }
    return nullptr;
}

void MidiSequence::setTempo(double bpm) {
    tempo = std::max(1.0, std::min(300.0, bpm)); // Clamp to reasonable range
}

void MidiSequence::setTimeSignature(int numerator, int denominator) {
    timeSignatureNum = std::max(1, numerator);
    timeSignatureDen = std::max(1, denominator);
}

void MidiSequence::clear() {
    for (auto& track : tracks) {
        track->clear();
    }
    length = 0.0;
}

double MidiSequence::calculateLength() {
    double maxLength = 0.0;
    for (const auto& track : tracks) {
        for (const auto& note : track->notes) {
            maxLength = std::max(maxLength, note.startTime + note.duration);
        }
    }
    length = maxLength;
    return length;
}

void MidiSequence::addChord(int trackIndex, const std::vector<int>& notes, int velocity, double startTime, double duration) {
    MidiTrack* track = getTrack(trackIndex);
    if (!track) return;

    for (int note : notes) {
        track->addNote(note, velocity, startTime, duration);
    }
}

void MidiSequence::addArpeggio(int trackIndex, const std::vector<int>& notes, int velocity, double startTime, double stepDuration) {
    MidiTrack* track = getTrack(trackIndex);
    if (!track) return;

    double currentTime = startTime;
    for (int note : notes) {
        track->addNote(note, velocity, currentTime, stepDuration);
        currentTime += stepDuration;
    }
}

void MidiSequence::addDrumPattern(int trackIndex, const std::vector<int>& drums, const std::vector<bool>& pattern, double startTime, double stepDuration) {
    MidiTrack* track = getTrack(trackIndex);
    if (!track || drums.size() != pattern.size()) return;

    for (size_t i = 0; i < pattern.size(); ++i) {
        if (pattern[i]) {
            track->addNote(drums[i], 100, startTime + (i * stepDuration), stepDuration * 0.9);
        }
    }
}

// MidiEngine Implementation
MidiEngine::MidiEngine()
    : initialized(false), coreAudioEngine(nullptr)
#ifdef __APPLE__
    , samplerUnit(nullptr), auGraph(nullptr), samplerNode(0), outputNode(0), currentMusicSequence(nullptr), musicPlayerInitialized(false)
#endif
    , nextSequenceId(1)
{
    logInfo("MidiEngine: Constructor called");
}

MidiEngine::~MidiEngine() {
    shutdown();
}

bool MidiEngine::initialize(CoreAudioEngine* audioEngine) {
    logInfo("MidiEngine: Initializing...");

    if (initialized) {
        logInfo("MidiEngine: Already initialized");
        return true;
    }

    coreAudioEngine = audioEngine;
    if (!coreAudioEngine) {
        logError("MidiEngine: CoreAudioEngine is null");
        return false;
    }

    if (!initializePlatformMidi()) {
        logError("MidiEngine: Platform MIDI initialization failed");
        return false;
    }

    initialized = true;
    logInfo("MidiEngine: Initialization complete");
    logInfo("  Sample Rate: 44100 Hz");
    logInfo("  Channels: 16 MIDI channels");
    logInfo("  Polyphony: 128 voices");

    return true;
}

void MidiEngine::shutdown() {
    if (!initialized) return;

    logInfo("MidiEngine: Shutting down...");

    // Stop all playback
    allNotesOff();

    // Clear sequences
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        sequences.clear();
        sequencePlaying.clear();
        sequenceVolumes.clear();
        sequenceLooping.clear();
    }

    shutdownPlatformMidi();

    initialized = false;
    logInfo("MidiEngine: Shutdown complete");
}

bool MidiEngine::loadMidiFile(const std::string& filename, int sequenceId) {
#ifdef __APPLE__
    logInfo("MidiEngine: Loading MIDI file: " + filename);

    CFURLRef fileURL = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                                (const UInt8*)filename.c_str(),
                                                                filename.length(),
                                                                false);
    if (!fileURL) {
        logError("MidiEngine: Could not create URL for file: " + filename);
        return false;
    }

    MusicSequence musicSequence;
    OSStatus result = NewMusicSequence(&musicSequence);
    if (result != noErr) {
        logError("MidiEngine: Could not create music sequence");
        CFRelease(fileURL);
        return false;
    }

    result = MusicSequenceFileLoad(musicSequence, fileURL, kMusicSequenceFile_MIDIType, kMusicSequenceLoadSMF_ChannelsToTracks);
    CFRelease(fileURL);

    if (result != noErr) {
        logError("MidiEngine: Could not load MIDI file");
        DisposeMusicSequence(musicSequence);
        return false;
    }

    // Store the loaded sequence (simplified - would need proper management)
    // For now, dispose to avoid leaking until sequence ownership is implemented.
    DisposeMusicSequence(musicSequence);
    logInfo("MidiEngine: MIDI file loaded successfully");
    return true;
#else
    logError("MidiEngine: MIDI file loading not implemented for this platform");
    return false;
#endif
}

int MidiEngine::createSequence(const std::string& name, double tempo) {
    std::lock_guard<std::mutex> lock(sequenceMutex);

    int sequenceId = nextSequenceId++;
    sequences[sequenceId] = std::make_unique<MidiSequence>(name, tempo);
    sequencePlaying[sequenceId] = false;
    sequenceVolumes[sequenceId] = 1.0f;
    sequenceLooping[sequenceId] = false;

    logInfo("MidiEngine: Created sequence ID " + std::to_string(sequenceId) + " '" + name + "' at " + std::to_string(tempo) + " BPM");
    return sequenceId;
}

bool MidiEngine::deleteSequence(int sequenceId) {
    bool exists = false;
    bool wasPlaying = false;
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto sequenceIt = sequences.find(sequenceId);
        if (sequenceIt == sequences.end()) {
            logError("MidiEngine: Sequence ID " + std::to_string(sequenceId) + " not found");
            return false;
        }
        exists = true;
        auto playingIt = sequencePlaying.find(sequenceId);
        wasPlaying = (playingIt != sequencePlaying.end()) ? playingIt->second : false;
    }

    if (!exists) {
        return false;
    }

    if (wasPlaying) {
        stopSequence(sequenceId);
    }

    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        sequences.erase(sequenceId);
        sequencePlaying.erase(sequenceId);
        sequenceVolumes.erase(sequenceId);
        sequenceLooping.erase(sequenceId);
    }

    logInfo("MidiEngine: Deleted sequence ID " + std::to_string(sequenceId));
    return true;
}

MidiSequence* MidiEngine::getSequence(int sequenceId) {
    std::lock_guard<std::mutex> lock(sequenceMutex);

    auto it = sequences.find(sequenceId);
    if (it != sequences.end()) {
        return it->second.get();
    }
    return nullptr;
}

bool MidiEngine::playSequence(int sequenceId, float volume, bool loop) {
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto sequenceIt = sequences.find(sequenceId);
        if (sequenceIt == sequences.end()) {
            logError("MidiEngine: Cannot play sequence ID " + std::to_string(sequenceId) + " - not found");
            return false;
        }

        sequenceVolumes[sequenceId] = std::clamp(volume, 0.0f, 1.0f);
        sequenceLooping[sequenceId] = loop;
    }

    {
        std::lock_guard<std::mutex> lock(playbackMutex);
        startSequencePlayback(sequenceId);
    }

    logInfo("MidiEngine: Started playback of sequence ID " + std::to_string(sequenceId) +
            " (volume: " + std::to_string(volume) + ", loop: " + (loop ? "yes" : "no") + ")");
    return true;
}

void MidiEngine::stopSequence(int sequenceId) {
    bool wasPlaying = false;
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto playingIt = sequencePlaying.find(sequenceId);
        if (playingIt != sequencePlaying.end() && playingIt->second) {
            playingIt->second = false;
            wasPlaying = true;
        }
    }

    if (wasPlaying) {
        std::lock_guard<std::mutex> lock(playbackMutex);
        stopSequencePlayback(sequenceId);
        logInfo("MidiEngine: Stopped sequence ID " + std::to_string(sequenceId));
    }
}

void MidiEngine::pauseSequence(int sequenceId) {
    bool isPlaying = false;
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto playingIt = sequencePlaying.find(sequenceId);
        isPlaying = (playingIt != sequencePlaying.end() && playingIt->second);
    }

    if (isPlaying) {
        std::lock_guard<std::mutex> lock(playbackMutex);
        stopSequencePlayback(sequenceId);
        // Keep sequencePlaying true so we know it was paused, not stopped
        logInfo("MidiEngine: Paused sequence ID " + std::to_string(sequenceId));
    }
}

void MidiEngine::resumeSequence(int sequenceId) {
    bool isPlaying = false;
    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto playingIt = sequencePlaying.find(sequenceId);
        isPlaying = (playingIt != sequencePlaying.end() && playingIt->second);
    }

    if (isPlaying) {
        std::lock_guard<std::mutex> lock(playbackMutex);
        startSequencePlayback(sequenceId);
        logInfo("MidiEngine: Resumed sequence ID " + std::to_string(sequenceId));
    }
}

void MidiEngine::setSequenceVolume(int sequenceId, float volume) {
    std::lock_guard<std::mutex> lock(sequenceMutex);

    auto it = sequenceVolumes.find(sequenceId);
    if (it != sequenceVolumes.end()) {
        it->second = std::clamp(volume, 0.0f, 1.0f);
        logInfo("MidiEngine: Set sequence ID " + std::to_string(sequenceId) +
                " volume to " + std::to_string(volume));
    }
}

void MidiEngine::setSequencePosition(int sequenceId, double beats) {
    // Simplified implementation - in real version would seek to position
    logInfo("MidiEngine: Set sequence ID " + std::to_string(sequenceId) +
            " position to " + std::to_string(beats) + " beats");
}

double MidiEngine::getSequencePosition(int sequenceId) {
    // Simplified implementation - in real version would return current position
    return 0.0;
}

void MidiEngine::playNote(int channel, int note, int velocity, double duration) {
    if (!initialized) return;

    // Add console debugging
    // Background thread - no console output

    // Clamp parameters
    channel = std::clamp(channel, 1, 16);
    note = std::clamp(note, 0, 127);
    velocity = std::clamp(velocity, 0, 127);

    // For now, just log the MIDI note for future implementation
    // logInfo("MidiEngine: MIDI Note ON CH" + std::to_string(channel) +
    //         " Note=" + std::to_string(note) +
    //         " (" + std::to_string(frequency) + "Hz) " +
    //         "Velocity=" + std::to_string(velocity) +
    //         " Duration=" + std::to_string(duration));

    // Track for auto-stop if duration specified
    if (duration > 0.0) {
        std::lock_guard<std::mutex> lock(activeNotesMutex);
        ActiveNote activeNote;
        activeNote.channel = channel;
        activeNote.note = note;
        activeNote.startTime = std::chrono::steady_clock::now();
        activeNote.duration = duration;
        activeNotes.push_back(activeNote);
    }

    if (midiEventCallback) {
        midiEventCallback(channel, note, velocity, true);
    }

#ifdef __APPLE__
    // Also send to MIDI sampler unit (for future proper MIDI implementation)
    if (samplerUnit) {
        UInt32 noteOnCommand = (0x90 | (channel - 1)) | (note << 8) | (velocity << 16);
        OSStatus result = MusicDeviceMIDIEvent(samplerUnit, (noteOnCommand & 0xFF),
                                              ((noteOnCommand >> 8) & 0xFF),
                                              ((noteOnCommand >> 16) & 0xFF), 0);
        if (result != noErr) {
            logError("MidiEngine: Failed to send MIDI note on event (ch=" + std::to_string(channel) +
                    " note=" + std::to_string(note) + " vel=" + std::to_string(velocity) + "): " + std::to_string(result));
        } else {
            // logInfo("MidiEngine: MIDI note ON sent successfully (ch=" + std::to_string(channel) +
            //        " note=" + std::to_string(note) + " vel=" + std::to_string(velocity) + ")");
        }
    } else {
        logError("MidiEngine: samplerUnit is null, cannot send MIDI note");
    }
#endif
}

void MidiEngine::stopNote(int channel, int note) {
    if (!initialized) return;

    // Add console debugging
    // Background thread - no console output

    channel = std::clamp(channel, 1, 16);
    note = std::clamp(note, 0, 127);

    // logInfo("MidiEngine: Stop note CH" + std::to_string(channel) + " N" + std::to_string(note));

    if (midiEventCallback) {
        midiEventCallback(channel, note, 0, false);
    }

#ifdef __APPLE__
    if (samplerUnit) {
        // Send MIDI note off
        UInt32 noteOffCommand = (0x80 | (channel - 1)) | (note << 8);
        OSStatus result = MusicDeviceMIDIEvent(samplerUnit, (noteOffCommand & 0xFF),
                                              ((noteOffCommand >> 8) & 0xFF),
                                              0, 0);
        if (result != noErr) {
            logError("MidiEngine: Failed to send MIDI note off event (ch=" + std::to_string(channel) +
                    " note=" + std::to_string(note) + "): " + std::to_string(result));
        } else {
            // logInfo("MidiEngine: MIDI note OFF sent successfully (ch=" + std::to_string(channel) +
            //        " note=" + std::to_string(note) + ")");
        }
    } else {
        logError("MidiEngine: samplerUnit is null, cannot send MIDI note off");
    }
#endif

    // Remove from active notes
    std::lock_guard<std::mutex> lock(activeNotesMutex);
    activeNotes.erase(std::remove_if(activeNotes.begin(), activeNotes.end(),
        [channel, note](const ActiveNote& n) {
            return n.channel == channel && n.note == note;
        }), activeNotes.end());
}

void MidiEngine::sendControlChange(int channel, int controller, int value) {
    if (!initialized) return;

    // Add console debugging
    // Background thread - no console output

    channel = std::clamp(channel, 1, 16);
    controller = std::clamp(controller, 0, 127);
    value = std::clamp(value, 0, 127);

#ifdef __APPLE__
    if (samplerUnit) {
        UInt32 ccCommand = (0xB0 | (channel - 1)) | (controller << 8) | (value << 16);
        MusicDeviceMIDIEvent(samplerUnit, (ccCommand & 0xFF),
                           ((ccCommand >> 8) & 0xFF),
                           ((ccCommand >> 16) & 0xFF), 0);
    }
#endif

#ifdef FB_MIDI_CC_DEBUG
    logInfo("MidiEngine: CC CH" + std::to_string(channel) + " #" + std::to_string(controller) +
            " = " + std::to_string(value));
#endif
}

void MidiEngine::sendProgramChange(int channel, int program) {
    if (!initialized) return;

    // Add console debugging
    // Background thread - no console output

    channel = std::clamp(channel, 1, 16);
    program = std::clamp(program, 0, 127);

#ifdef __APPLE__
    if (samplerUnit) {
        UInt32 pcCommand = (0xC0 | (channel - 1)) | (program << 8);
        MusicDeviceMIDIEvent(samplerUnit, (pcCommand & 0xFF),
                           ((pcCommand >> 8) & 0xFF), 0, 0);
    }
#endif

    logInfo("MidiEngine: Program Change CH" + std::to_string(channel) + " = " + std::to_string(program));
}

void MidiEngine::allNotesOff(int channel) {
    if (!initialized) return;

    if (channel == -1) {
        // All channels
        for (int ch = 1; ch <= 16; ++ch) {
            sendControlChange(ch, 123, 0); // All Notes Off
        }
        std::lock_guard<std::mutex> lock(activeNotesMutex);
        activeNotes.clear();
    } else {
        channel = std::clamp(channel, 1, 16);
        sendControlChange(channel, 123, 0);

        // Remove active notes for this channel
        std::lock_guard<std::mutex> lock(activeNotesMutex);
        activeNotes.erase(std::remove_if(activeNotes.begin(), activeNotes.end(),
            [channel](const ActiveNote& n) {
                return n.channel == channel;
            }), activeNotes.end());
    }

    logInfo("MidiEngine: All Notes Off" + (channel == -1 ? " (all channels)" : " CH" + std::to_string(channel)));
}

void MidiEngine::setMasterVolume(float volume) {
    masterVolume = std::clamp(volume, 0.0f, 1.0f);

    // Send volume CC to all channels
    int volumeCC = static_cast<int>(masterVolume * 127);
    for (int ch = 1; ch <= 16; ++ch) {
        sendControlChange(ch, 7, volumeCC); // Main Volume
    }

    logInfo("MidiEngine: Master volume set to " + std::to_string(masterVolume));
}

void MidiEngine::setMasterTempo(float tempoMultiplier) {
    masterTempoMultiplier = std::clamp(tempoMultiplier, 0.1f, 4.0f);
    logInfo("MidiEngine: Master tempo multiplier set to " + std::to_string(masterTempoMultiplier));
}

// Utility Functions
int MidiEngine::noteNameToNumber(const std::string& noteName) {
    static const std::unordered_map<char, int> noteMap = {
        {'C', 0}, {'D', 2}, {'E', 4}, {'F', 5}, {'G', 7}, {'A', 9}, {'B', 11}
    };

    if (noteName.empty()) return 60; // Default to C4

    size_t pos = 0;
    char noteLetter = noteName[pos];
    if (noteLetter < 'A' || noteLetter > 'G') return 60;
    pos++;

    auto it = noteMap.find(noteLetter);
    if (it == noteMap.end()) return 60;
    int semitone = it->second;

    // Check for accidental
    int accidental = 0;
    if (pos < noteName.size()) {
        if (noteName[pos] == '#') { accidental = 1; pos++; }
        else if (noteName[pos] == 'b') { accidental = -1; pos++; }
    }

    // Parse octave number
    int octave = 4; // default
    if (pos < noteName.size() && noteName[pos] >= '0' && noteName[pos] <= '9') {
        octave = 0;
        while (pos < noteName.size() && noteName[pos] >= '0' && noteName[pos] <= '9') {
            octave = octave * 10 + (noteName[pos] - '0');
            pos++;
        }
    }

    int noteNumber = semitone + (octave + 1) * 12 + accidental;
    return std::clamp(noteNumber, 0, 127);
}

std::string MidiEngine::noteNumberToName(int noteNumber) {
    static const std::vector<std::string> noteNames = {
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
    };

    noteNumber = std::clamp(noteNumber, 0, 127);
    int octave = (noteNumber / 12) - 1;
    int note = noteNumber % 12;

    return noteNames[note] + std::to_string(octave);
}

double MidiEngine::beatsToSeconds(double beats, double tempo) {
    return beats * (60.0 / tempo);
}

double MidiEngine::secondsToBeats(double seconds, double tempo) {
    return seconds * (tempo / 60.0);
}

std::vector<int> MidiEngine::parseChord(const std::string& chordName, int rootNote) {
    // Simple chord parsing - extend as needed
    std::vector<int> intervals;

    if (chordName.find("maj") != std::string::npos || chordName.find("M") != std::string::npos) {
        intervals = MidiTheory::MAJOR_TRIAD;
    } else if (chordName.find("min") != std::string::npos || chordName.find("m") != std::string::npos) {
        intervals = MidiTheory::MINOR_TRIAD;
    } else if (chordName.find("dim") != std::string::npos) {
        intervals = MidiTheory::DIMINISHED_TRIAD;
    } else if (chordName.find("aug") != std::string::npos) {
        intervals = MidiTheory::AUGMENTED_TRIAD;
    } else {
        intervals = MidiTheory::MAJOR_TRIAD; // Default
    }

    // Check for 7th
    if (chordName.find("7") != std::string::npos) {
        if (chordName.find("maj7") != std::string::npos) {
            intervals = MidiTheory::MAJOR_SEVENTH;
        } else if (chordName.find("min7") != std::string::npos) {
            intervals = MidiTheory::MINOR_SEVENTH;
        } else {
            intervals = MidiTheory::DOMINANT_SEVENTH;
        }
    }

    // Transpose to root note
    std::vector<int> chord;
    for (int interval : intervals) {
        chord.push_back(rootNote + interval);
    }

    return chord;
}

std::vector<int> MidiEngine::parseScale(const std::string& scaleName, int rootNote) {
    std::vector<int> intervals;

    if (scaleName.find("major") != std::string::npos) {
        intervals = MidiTheory::MAJOR_SCALE;
    } else if (scaleName.find("minor") != std::string::npos) {
        intervals = MidiTheory::MINOR_SCALE;
    } else if (scaleName.find("pentatonic_major") != std::string::npos) {
        intervals = MidiTheory::PENTATONIC_MAJOR;
    } else if (scaleName.find("pentatonic_minor") != std::string::npos) {
        intervals = MidiTheory::PENTATONIC_MINOR;
    } else if (scaleName.find("blues") != std::string::npos) {
        intervals = MidiTheory::BLUES_SCALE;
    } else if (scaleName.find("chromatic") != std::string::npos) {
        intervals = MidiTheory::CHROMATIC_SCALE;
    } else {
        intervals = MidiTheory::MAJOR_SCALE; // Default
    }

    // Transpose to root note
    std::vector<int> scale;
    for (int interval : intervals) {
        scale.push_back(rootNote + interval);
    }

    return scale;
}

int MidiEngine::getActiveNoteCount() const {
    std::lock_guard<std::mutex> lock(activeNotesMutex);
    return static_cast<int>(activeNotes.size());
}

int MidiEngine::getLoadedSequenceCount() const {
    std::lock_guard<std::mutex> lock(sequenceMutex);
    return static_cast<int>(sequences.size());
}

std::vector<int> MidiEngine::getActiveSequences() const {
    std::vector<int> active;
    std::lock_guard<std::mutex> lock(sequenceMutex);

    for (const auto& pair : sequencePlaying) {
        if (pair.second) {
            active.push_back(pair.first);
        }
    }

    return active;
}

// Platform-specific implementations
#ifdef __APPLE__
bool MidiEngine::initializePlatformMidi() {
    logInfo("MidiEngine: Initializing macOS Audio Toolbox...");

    if (!setupSamplerUnit()) {
        logError("MidiEngine: Failed to setup sampler unit");
        return false;
    }

    // Initialize Music Player
    // Music player functionality moved to separate MusicPlayer class
    OSStatus result = noErr;
    if (result != noErr) {
        logError("MidiEngine: Could not create music player");
        return false;
    }

    musicPlayerInitialized = true;
    logInfo("MidiEngine: macOS Audio Toolbox initialized successfully");
    return true;
}

void MidiEngine::shutdownPlatformMidi() {
    cleanupSamplerUnit();

    if (musicPlayerInitialized) {
        // Music player cleanup moved to separate MusicPlayer class
        musicPlayerInitialized = false;
    }

    if (currentMusicSequence) {
        DisposeMusicSequence(currentMusicSequence);
        currentMusicSequence = nullptr;
    }
}

bool MidiEngine::setupSamplerUnit() {
    logInfo("MidiEngine: Setting up DLS sampler unit...");

    // Create Audio Unit description for DLS Sampler
    AudioComponentDescription samplerDesc = {0};
    samplerDesc.componentType = kAudioUnitType_MusicDevice;
    samplerDesc.componentSubType = kAudioUnitSubType_DLSSynth;
    samplerDesc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent samplerComponent = AudioComponentFindNext(nullptr, &samplerDesc);
    if (!samplerComponent) {
        logError("MidiEngine: Could not find DLS sampler component");
        return false;
    }

    OSStatus result = AudioComponentInstanceNew(samplerComponent, &samplerUnit);
    if (result != noErr) {
        logError("MidiEngine: Could not create sampler unit instance");
        return false;
    }

    // Initialize the unit
    result = AudioUnitInitialize(samplerUnit);
    if (result != noErr) {
        logError("MidiEngine: Could not initialize sampler unit");
        AudioComponentInstanceDispose(samplerUnit);
        samplerUnit = nullptr;
        return false;
    }

    // Connect the Audio Unit to system audio output
    logInfo("MidiEngine: Connecting sampler to audio output...");

    // Create an AUGraph to connect the sampler to the output
    OSStatus result2 = NewAUGraph(&auGraph);
    if (result2 != noErr) {
        logError("MidiEngine: Could not create AUGraph");
        AudioUnitUninitialize(samplerUnit);
        AudioComponentInstanceDispose(samplerUnit);
        samplerUnit = nullptr;
        return false;
    }

    // Add the sampler node to the graph
    AudioComponentDescription samplerDesc2 = {0};
    samplerDesc2.componentType = kAudioUnitType_MusicDevice;
    samplerDesc2.componentSubType = kAudioUnitSubType_DLSSynth;
    samplerDesc2.componentManufacturer = kAudioUnitManufacturer_Apple;

    result2 = AUGraphAddNode(auGraph, &samplerDesc2, &samplerNode);
    if (result2 != noErr) {
        logError("MidiEngine: Could not add sampler node to graph");
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Add the output node to the graph
    AudioComponentDescription outputDesc = {0};
    outputDesc.componentType = kAudioUnitType_Output;
    outputDesc.componentSubType = kAudioUnitSubType_DefaultOutput;
    outputDesc.componentManufacturer = kAudioUnitManufacturer_Apple;

    result2 = AUGraphAddNode(auGraph, &outputDesc, &outputNode);
    if (result2 != noErr) {
        logError("MidiEngine: Could not add output node to graph");
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Open the graph
    result2 = AUGraphOpen(auGraph);
    if (result2 != noErr) {
        logError("MidiEngine: Could not open AUGraph");
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Get the Audio Unit from the node
    result2 = AUGraphNodeInfo(auGraph, samplerNode, nullptr, &samplerUnit);
    if (result2 != noErr) {
        logError("MidiEngine: Could not get sampler unit from node");
        AUGraphClose(auGraph);
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Connect the sampler output to the output unit input
    result2 = AUGraphConnectNodeInput(auGraph, samplerNode, 0, outputNode, 0);
    if (result2 != noErr) {
        logError("MidiEngine: Could not connect sampler to output");
        AUGraphClose(auGraph);
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Initialize the graph
    result2 = AUGraphInitialize(auGraph);
    if (result2 != noErr) {
        logError("MidiEngine: Could not initialize AUGraph");
        AUGraphClose(auGraph);
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    // Start the graph
    result2 = AUGraphStart(auGraph);
    if (result2 != noErr) {
        logError("MidiEngine: Could not start AUGraph");
        AUGraphUninitialize(auGraph);
        AUGraphClose(auGraph);
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        return false;
    }

    logInfo("MidiEngine: MIDI sampler connected to audio output successfully");

    // Check if the Audio Unit graph is actually running
    Boolean isRunning = false;
    OSStatus runningStatus = AUGraphIsRunning(auGraph, &isRunning);
    if (runningStatus == noErr) {
        logInfo("MidiEngine: AUGraph running status: " + std::to_string(isRunning));
    } else {
        logError("MidiEngine: Could not check AUGraph running status: " + std::to_string(runningStatus));
    }

    // Verify Audio Unit is initialized
    OSStatus unitStatus = AudioUnitInitialize(samplerUnit);
    if (unitStatus == noErr) {
        logInfo("MidiEngine: Audio Unit re-initialization successful");
    } else {
        logError("MidiEngine: Audio Unit re-initialization failed: " + std::to_string(unitStatus));
    }

    // Load the default General MIDI sound bank
    logInfo("MidiEngine: Loading default General MIDI sound bank...");

    // Try to load Apple's default GM sound bank - use the DLS synth's built-in sounds first
    // The DLS synth should have built-in General MIDI sounds without needing external files

    // Configure DLS synth properties for General MIDI

    // Disable internal reverb — keeps retro/arcade music clean and dry.
    // Reverb causes an audible hiss tail on the very first MIDI note.
    UInt32 usesInternalReverb = 0;
    OSStatus reverbResult = AudioUnitSetProperty(samplerUnit,
                                               kMusicDeviceProperty_UsesInternalReverb,
                                               kAudioUnitScope_Global,
                                               0,
                                               &usesInternalReverb,
                                               sizeof(usesInternalReverb));

    if (reverbResult == noErr) {
        logInfo("MidiEngine: Disabled internal reverb for DLS synth");
    } else {
        logInfo("MidiEngine: Could not set reverb property: " + std::to_string(reverbResult));
    }

    // Set stream format for the Audio Unit output
    AudioStreamBasicDescription outputFormat = {0};
    outputFormat.mSampleRate = 44100.0;
    outputFormat.mFormatID = kAudioFormatLinearPCM;
    outputFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    outputFormat.mFramesPerPacket = 1;
    outputFormat.mChannelsPerFrame = 2;
    outputFormat.mBitsPerChannel = 32;
    outputFormat.mBytesPerFrame = sizeof(float);
    outputFormat.mBytesPerPacket = outputFormat.mBytesPerFrame * outputFormat.mFramesPerPacket;

    OSStatus formatResult = AudioUnitSetProperty(samplerUnit,
                                               kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Output,
                                               0,
                                               &outputFormat,
                                               sizeof(outputFormat));

    if (formatResult == noErr) {
        logInfo("MidiEngine: Set audio stream format successfully");
    } else {
        logError("MidiEngine: Could not set audio stream format: " + std::to_string(formatResult));
    }

    // Set maximum frames per slice
    UInt32 maxFrames = 512;
    OSStatus framesResult = AudioUnitSetProperty(samplerUnit,
                                               kAudioUnitProperty_MaximumFramesPerSlice,
                                               kAudioUnitScope_Global,
                                               0,
                                               &maxFrames,
                                               sizeof(maxFrames));

    if (framesResult == noErr) {
        logInfo("MidiEngine: Set maximum frames per slice to " + std::to_string(maxFrames));
    } else {
        logInfo("MidiEngine: Could not set maximum frames per slice: " + std::to_string(framesResult));
    }

    // Try to load external sound bank as fallback
    CFURLRef soundBankURL = nullptr;
    CFStringRef soundBankPath = CFSTR("/System/Library/Components/DLSMusicDevice.component/Contents/Resources/gs_instruments.dls");
    soundBankURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, soundBankPath, kCFURLPOSIXPathStyle, false);

    if (soundBankURL) {
        OSStatus bankResult = AudioUnitSetProperty(samplerUnit,
                                        kMusicDeviceProperty_SoundBankURL,
                                        kAudioUnitScope_Global,
                                        0,
                                        &soundBankURL,
                                        sizeof(soundBankURL));

        if (bankResult == noErr) {
            logInfo("MidiEngine: External sound bank loaded successfully");
        } else {
            logInfo("MidiEngine: Could not load external sound bank (error " + std::to_string(bankResult) + "), using built-in sounds");
        }

        CFRelease(soundBankURL);
    } else {
        logInfo("MidiEngine: No external sound bank found, using built-in DLS sounds");
    }

    // No startup test note — it caused an audible hiss/reverb tail at game launch.
    logInfo("MidiEngine: DLS sampler unit setup complete");
    return true;
}

void MidiEngine::cleanupSamplerUnit() {
    if (auGraph) {
        AUGraphStop(auGraph);
        AUGraphUninitialize(auGraph);
        AUGraphClose(auGraph);
        DisposeAUGraph(auGraph);
        auGraph = nullptr;
        samplerUnit = nullptr;
    } else if (samplerUnit) {
        AudioUnitUninitialize(samplerUnit);
        AudioComponentInstanceDispose(samplerUnit);
        samplerUnit = nullptr;
    }
}
#endif

// Helper to get synthesis engine from the audio system
::SynthEngine* MidiEngine::getSynthEngineFromAudio() {
    if (!coreAudioEngine) {
        return nullptr;
    }
    return coreAudioEngine->getSynthEngine();
}

// Internal helper methods
void MidiEngine::startSequencePlayback(int sequenceId) {
    logInfo("MidiEngine: Starting sequence playback (ID " + std::to_string(sequenceId) + ")");

    struct Event {
        double time;
        int channel;
        int note;
        int velocity;
        bool on;
    };

    struct PlaybackTrackData {
        int channel;
        bool muted;
        std::vector<MidiProgramChange> programChanges;
        std::vector<MidiNote> notes;
    };

    std::vector<PlaybackTrackData> tracks;
    double sequenceTempo = 120.0;

    {
        std::lock_guard<std::mutex> lock(sequenceMutex);
        auto sequenceIt = sequences.find(sequenceId);
        if (sequenceIt == sequences.end() || !sequenceIt->second) {
            return;
        }

        sequenceTempo = sequenceIt->second->tempo;
        tracks.reserve(sequenceIt->second->tracks.size());
        for (const auto& track : sequenceIt->second->tracks) {
            PlaybackTrackData data;
            data.channel = track->channel;
            data.muted = track->muted;
            data.programChanges = track->programChanges;
            data.notes = track->notes;
            tracks.push_back(std::move(data));
        }

        sequencePlaying[sequenceId] = true;
    }

    // Start a playback thread for this sequence
    std::thread playbackThread([this, sequenceId, sequenceTempo, tracks = std::move(tracks)]() {
        double beatDuration = 60.0 / sequenceTempo; // seconds per beat
        auto startTime = std::chrono::steady_clock::now();
        const bool traceNotes = std::getenv("ED_TRACE_MIDI_NOTES") != nullptr;

        // Collect channels used and send program changes + pedal-off upfront
        std::vector<int> usedChannels;
        for (const auto& track : tracks) {
            if (track.muted) continue;
            usedChannels.push_back(track.channel);
            for (const auto& pc : track.programChanges) {
                // Only handle time==0 for now; this keeps things simple for ABC one-shot tunes
                if (std::abs(pc.time) < 1e-6) {
                    sendProgramChange(pc.channel, pc.program);
                }
            }
        }
        // Ensure sustain pedal is off on all used channels
        for (int ch : usedChannels) {
            sendControlChange(ch, 64, 0);  // sustain off
            sendControlChange(ch, 123, 0); // all notes off
        }

        // Collect on/off events with absolute timing
        std::vector<Event> events;
        for (const auto& track : tracks) {
            if (track.muted) continue;

            for (const auto& note : track.notes) {
                const double onTime = note.startTime * beatDuration;
                const double offTime = (note.startTime + note.duration) * beatDuration;

                events.push_back(Event{onTime, note.channel, note.note, note.velocity, true});
                events.push_back(Event{offTime, note.channel, note.note, 0, false});
            }
        }

        std::sort(events.begin(), events.end(), [](const Event& a, const Event& b) {
            if (a.time == b.time) {
                // Process offs before ons at the same timestamp
                return (a.on ? 1 : 0) < (b.on ? 1 : 0);
            }
            return a.time < b.time;
        });

        if (traceNotes) {
            logInfo("MidiEngine: scheduling " + std::to_string(events.size()) + " events for sequence " + std::to_string(sequenceId));
            for (const auto& ev : events) {
                std::ostringstream oss;
                oss << (ev.on ? "ON" : "OFF")
                    << " ch=" << ev.channel
                    << " note=" << ev.note
                    << " vel=" << ev.velocity
                    << " t_s=" << ev.time;
                logInfo(oss.str());
            }
        }

        // Dispatch events in order
        for (const auto& ev : events) {
            bool keepPlaying = false;
            {
                std::lock_guard<std::mutex> lock(sequenceMutex);
                auto playingIt = sequencePlaying.find(sequenceId);
                keepPlaying = (playingIt != sequencePlaying.end() && playingIt->second);
            }
            if (!keepPlaying) break;

            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - startTime).count();
            double waitTime = ev.time - elapsed;
            if (waitTime > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(waitTime * 1000)));
            }

            if (ev.on) {
                playNote(ev.channel, ev.note, ev.velocity, 0.0);
            } else {
                stopNote(ev.channel, ev.note);
            }
        }

        // Sequence finished
        allNotesOff();
        {
            std::lock_guard<std::mutex> lock(sequenceMutex);
            auto playingIt = sequencePlaying.find(sequenceId);
            if (playingIt != sequencePlaying.end()) {
                playingIt->second = false;
            }
        }
        logInfo("MidiEngine: Sequence playback complete (ID " + std::to_string(sequenceId) + ")");
    });

    playbackThread.detach(); // Let it run independently
}

void MidiEngine::stopSequencePlayback(int sequenceId) {
    logInfo("MidiEngine: Stopping sequence playback (ID " + std::to_string(sequenceId) + ")");
    allNotesOff();
}

void MidiEngine::updateActiveNotes() {
    auto now = std::chrono::steady_clock::now();
    std::vector<std::pair<int, int>> expiredNotes;

    {
        std::lock_guard<std::mutex> lock(activeNotesMutex);
        for (const auto& note : activeNotes) {
            if (note.duration > 0.0) {
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - note.startTime).count() / 1000.0;
                if (elapsed >= note.duration) {
                    expiredNotes.emplace_back(note.channel, note.note);
                }
            }
        }
    }

    for (const auto& noteKey : expiredNotes) {
        stopNote(noteKey.first, noteKey.second);
    }
}

void MidiEngine::logError(const std::string& message) {
    std::cout << "ERROR: " << message << std::endl;
}

void MidiEngine::waitForPlaybackComplete() {
    // Wait for all active notes to finish
    while (true) {
        bool done = false;
        {
            std::lock_guard<std::mutex> lock(activeNotesMutex);
            done = activeNotes.empty();
        }

        if (done) {
            break;
        }

        updateActiveNotes();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

void MidiEngine::logInfo(const std::string& message) {
    std::cout << message << std::endl;
}

// MidiTheory utility implementations
std::vector<int> MidiTheory::getChordIntervals(const std::string& chordType) {
    if (chordType == "major" || chordType == "maj") return MAJOR_TRIAD;
    if (chordType == "minor" || chordType == "min") return MINOR_TRIAD;
    if (chordType == "diminished" || chordType == "dim") return DIMINISHED_TRIAD;
    if (chordType == "augmented" || chordType == "aug") return AUGMENTED_TRIAD;
    if (chordType == "major7" || chordType == "maj7") return MAJOR_SEVENTH;
    if (chordType == "minor7" || chordType == "min7") return MINOR_SEVENTH;
    if (chordType == "dominant7" || chordType == "dom7") return DOMINANT_SEVENTH;
    return MAJOR_TRIAD; // Default
}

std::vector<int> MidiTheory::getScaleIntervals(const std::string& scaleType) {
    if (scaleType == "major") return MAJOR_SCALE;
    if (scaleType == "minor") return MINOR_SCALE;
    if (scaleType == "pentatonic_major") return PENTATONIC_MAJOR;
    if (scaleType == "pentatonic_minor") return PENTATONIC_MINOR;
    if (scaleType == "blues") return BLUES_SCALE;
    if (scaleType == "chromatic") return CHROMATIC_SCALE;
    return MAJOR_SCALE; // Default
}

std::vector<int> MidiTheory::transposeNotes(const std::vector<int>& notes, int semitones) {
    std::vector<int> transposed;
    for (int note : notes) {
        transposed.push_back(std::clamp(note + semitones, 0, 127));
    }
    return transposed;
}

} // namespace SuperTerminal
