// ─── Audio Runtime — JIT-Callable Exports ───────────────────────────────────
//
// C-callable functions with callconv(.c) that are resolved by
// dlsym(RTLD_DEFAULT, ...) at JIT link time, just like the existing
// gfx_* runtime symbols in graphics_runtime.zig.
//
// All arguments use f64 because FasterBASIC's default numeric type is
// DOUBLE, and the JIT calling convention passes everything as doubles.
// The runtime functions convert to the appropriate C types internally
// before calling the fb_* C shim functions.
//
// Thread safety: these functions are called from the JIT worker thread.
// The underlying FBAudioManager is internally mutex-locked.

const std = @import("std");

// ─── C Shim Extern Declarations ────────────────────────────────────────────
//
// These match the C-linkage functions in fb_audio_shim.h / fb_audio_shim.mm.
// We declare them here so the Zig wrappers can call them directly.

extern "c" fn fb_audio_init() bool;
extern "c" fn fb_audio_shutdown() void;
extern "c" fn fb_audio_is_initialized() bool;

// ── SOUND — Predefined SFX ─────────────────────────────────────────────────
extern "c" fn fb_sound_create_beep(frequency: f32, duration: f32) u32;
extern "c" fn fb_sound_create_zap(frequency: f32, duration: f32) u32;
extern "c" fn fb_sound_create_explode(size: f32, duration: f32) u32;
extern "c" fn fb_sound_create_big_explosion(size: f32, duration: f32) u32;
extern "c" fn fb_sound_create_small_explosion(intensity: f32, duration: f32) u32;
extern "c" fn fb_sound_create_distant_explosion(distance: f32, duration: f32) u32;
extern "c" fn fb_sound_create_metal_explosion(shrapnel: f32, duration: f32) u32;
extern "c" fn fb_sound_create_bang(intensity: f32, duration: f32) u32;
extern "c" fn fb_sound_create_coin(pitch: f32, duration: f32) u32;
extern "c" fn fb_sound_create_jump(power: f32, duration: f32) u32;
extern "c" fn fb_sound_create_powerup(intensity: f32, duration: f32) u32;
extern "c" fn fb_sound_create_hurt(severity: f32, duration: f32) u32;
extern "c" fn fb_sound_create_shoot(power: f32, duration: f32) u32;
extern "c" fn fb_sound_create_click(sharpness: f32, duration: f32) u32;
extern "c" fn fb_sound_create_blip(pitch: f32, duration: f32) u32;
extern "c" fn fb_sound_create_pickup(brightness: f32, duration: f32) u32;
extern "c" fn fb_sound_create_sweep_up(start_freq: f32, end_freq: f32, duration: f32) u32;
extern "c" fn fb_sound_create_sweep_down(start_freq: f32, end_freq: f32, duration: f32) u32;
extern "c" fn fb_sound_create_random_beep(seed: u32, duration: f32) u32;

// ── SOUND — Custom Synthesis ────────────────────────────────────────────────
extern "c" fn fb_sound_create_tone(frequency: f32, duration: f32, waveform: c_int) u32;
extern "c" fn fb_sound_create_note(midi_note: c_int, duration: f32, waveform: c_int, attack: f32, decay: f32, sustain: f32, release: f32) u32;
extern "c" fn fb_sound_create_noise(noise_type: c_int, duration: f32) u32;
extern "c" fn fb_sound_create_fm(carrier_freq: f32, mod_freq: f32, mod_index: f32, duration: f32) u32;
extern "c" fn fb_sound_create_filtered_tone(frequency: f32, duration: f32, waveform: c_int, filter_type: c_int, cutoff: f32, resonance: f32) u32;
extern "c" fn fb_sound_create_filtered_note(midi_note: c_int, duration: f32, waveform: c_int, attack: f32, decay: f32, sustain: f32, release: f32, filter_type: c_int, cutoff: f32, resonance: f32) u32;

// ── SOUND — Effects Processing ──────────────────────────────────────────────
extern "c" fn fb_sound_create_with_reverb(frequency: f32, duration: f32, waveform: c_int, room_size: f32, damping: f32, wet: f32) u32;
extern "c" fn fb_sound_create_with_delay(frequency: f32, duration: f32, waveform: c_int, delay_time: f32, feedback: f32, mix: f32) u32;
extern "c" fn fb_sound_create_with_distortion(frequency: f32, duration: f32, waveform: c_int, drive: f32, tone: f32, level: f32) u32;

// ── SOUND — Playback & Management ──────────────────────────────────────────
extern "c" fn fb_sound_play(sound_id: u32, volume: f32, pan: f32) void;
extern "c" fn fb_sound_play_simple(sound_id: u32) void;
extern "c" fn fb_sound_stop() void;
extern "c" fn fb_sound_stop_one(sound_id: u32) void;
extern "c" fn fb_sound_is_playing(sound_id: u32) bool;
extern "c" fn fb_sound_get_duration(sound_id: u32) f32;
extern "c" fn fb_sound_free(sound_id: u32) bool;
extern "c" fn fb_sound_free_all() void;
extern "c" fn fb_sound_set_volume(volume: f32) void;
extern "c" fn fb_sound_get_volume() f32;
extern "c" fn fb_sound_exists(sound_id: u32) bool;
extern "c" fn fb_sound_get_count() usize;
extern "c" fn fb_sound_get_memory_usage() usize;
extern "c" fn fb_sound_export_wav(sound_id: u32, filename: ?[*:0]const u8, volume: f32) bool;

// ── Utility ─────────────────────────────────────────────────────────────────
extern "c" fn fb_note_to_freq(midi_note: c_int) f32;
extern "c" fn fb_freq_to_note(frequency: f32) c_int;
extern "c" fn fb_audio_stop_all() void;

// ── MUSIC — Playback ────────────────────────────────────────────────────────
extern "c" fn fb_music_play(abc_notation: ?[*:0]const u8, volume: f32) void;
extern "c" fn fb_music_play_simple(abc_notation: ?[*:0]const u8) void;
extern "c" fn fb_music_load_string(abc_notation: ?[*:0]const u8) u32;
extern "c" fn fb_music_load_compiled_blob(blob_data: ?*const anyopaque, blob_size: usize) u32;
extern "c" fn fb_music_play_id(music_id: u32, volume: f32) void;
extern "c" fn fb_music_play_id_simple(music_id: u32) void;
extern "c" fn fb_music_stop() void;
extern "c" fn fb_music_pause() void;
extern "c" fn fb_music_resume() void;
extern "c" fn fb_music_set_volume(volume: f32) void;
extern "c" fn fb_music_get_volume() f32;
extern "c" fn fb_music_free(music_id: u32) bool;
extern "c" fn fb_sound_import_synth_memory(synth_memory_id: u32) u32;
extern "c" fn fb_sound_discard_synth_memory(synth_memory_id: u32) bool;
extern "c" fn fb_music_free_all() void;
extern "c" fn fb_music_is_playing() bool;
extern "c" fn fb_music_is_playing_id(music_id: u32) bool;
extern "c" fn fb_music_get_state() c_int;
extern "c" fn fb_music_exists(music_id: u32) bool;
extern "c" fn fb_music_get_count() usize;
extern "c" fn fb_music_get_memory_usage() usize;
extern "c" fn fb_music_get_title(music_id: u32) ?[*:0]const u8;

export fn snd_import_memory(synth_memory_id: f64) callconv(.c) f64 {
    return fromU32(fb_sound_import_synth_memory(toU32(synth_memory_id)));
}

export fn snd_discard_memory(synth_memory_id: f64) callconv(.c) f64 {
    return fromBool(fb_sound_discard_synth_memory(toU32(synth_memory_id)));
}
extern "c" fn fb_music_get_composer(music_id: u32) ?[*:0]const u8;
extern "c" fn fb_music_get_key(music_id: u32) ?[*:0]const u8;
extern "c" fn fb_music_get_tempo(music_id: u32) f32;
extern "c" fn fb_music_get_compiled_blob_info(music_id: u32) ?[*:0]const u8;
extern "c" fn fb_music_render(abc_notation: ?[*:0]const u8, duration: f32, sample_rate: f32) u32;
extern "c" fn fb_music_render_simple(abc_notation: ?[*:0]const u8) u32;
extern "c" fn fb_music_render_wav(abc_notation: ?[*:0]const u8, filename: ?[*:0]const u8, duration: f32, sample_rate: f32) bool;
extern "c" fn fb_music_export_midi(music_id: u32, filename: ?[*:0]const u8) bool;
extern "c" fn string_new_utf8(cstr: ?[*:0]const u8) callconv(.c) ?*anyopaque;

// ── VS — Voice Synthesiser ──────────────────────────────────────────────────
extern "c" fn fb_vs_waveform(voice: c_int, waveform: c_int) void;
extern "c" fn fb_vs_frequency(voice: c_int, hz: f32) void;
extern "c" fn fb_vs_note(voice: c_int, midi_note: c_int) void;
extern "c" fn fb_vs_notename(voice: c_int, name: ?[*:0]const u8) void;
extern "c" fn fb_vs_pulse(voice: c_int, width: f32) void;
extern "c" fn fb_vs_envelope(voice: c_int, attack_ms: f32, decay_ms: f32, sustain: f32, release_ms: f32) void;
extern "c" fn fb_vs_gate(voice: c_int, gate_on: bool) void;
extern "c" fn fb_vs_volume(voice: c_int, level: f32) void;
extern "c" fn fb_vs_pan(voice: c_int, position: f32) void;
extern "c" fn fb_vs_master(level: f32) void;
extern "c" fn fb_vs_filter_type(filter_type: c_int) void;
extern "c" fn fb_vs_filter_cutoff(hz: f32) void;
extern "c" fn fb_vs_filter_resonance(q: f32) void;
extern "c" fn fb_vs_filter_enabled(on: bool) void;
extern "c" fn fb_vs_filter_route(voice: c_int, on: bool) void;
extern "c" fn fb_vs_ring(voice: c_int, source_voice: c_int) void;
extern "c" fn fb_vs_sync(voice: c_int, source_voice: c_int) void;
extern "c" fn fb_vs_portamento(voice: c_int, seconds: f32) void;
extern "c" fn fb_vs_detune(voice: c_int, cents: f32) void;
extern "c" fn fb_vs_delay_enabled(voice: c_int, on: bool) void;
extern "c" fn fb_vs_delay_time(voice: c_int, seconds: f32) void;
extern "c" fn fb_vs_delay_feedback(voice: c_int, amount: f32) void;
extern "c" fn fb_vs_delay_mix(voice: c_int, mix: f32) void;
extern "c" fn fb_vs_lfo_waveform(lfo: c_int, waveform: c_int) void;
extern "c" fn fb_vs_lfo_rate(lfo: c_int, hz: f32) void;
extern "c" fn fb_vs_lfo_reset(lfo: c_int) void;
extern "c" fn fb_vs_lfo_pitch(voice: c_int, lfo: c_int, depth_cents: f32) void;
extern "c" fn fb_vs_lfo_volume(voice: c_int, lfo: c_int, depth: f32) void;
extern "c" fn fb_vs_lfo_filter(voice: c_int, lfo: c_int, depth_hz: f32) void;
extern "c" fn fb_vs_lfo_pulse(voice: c_int, lfo: c_int, depth: f32) void;
extern "c" fn fb_vs_physical_model(voice: c_int, model_type: c_int) void;
extern "c" fn fb_vs_physical_damping(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_brightness(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_excitation(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_resonance(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_tension(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_pressure(voice: c_int, val: f32) void;
extern "c" fn fb_vs_physical_trigger(voice: c_int) void;
extern "c" fn fb_vs_reset() void;
extern "c" fn fb_vs_active_count() c_int;
extern "c" fn fb_vs_get_master() f32;
extern "c" fn fb_vs_is_playing() bool;
extern "c" fn fb_vs_record_start() void;
extern "c" fn fb_vs_record_tempo(bpm: f32) void;
extern "c" fn fb_vs_record_wait(beats: f32) void;
extern "c" fn fb_vs_record_save(volume: f32) u32;
extern "c" fn fb_vs_record_play(volume: f32) void;
extern "c" fn fb_vs_record_wav(filename: ?[*:0]const u8) void;

// ─── Helpers ────────────────────────────────────────────────────────────────

inline fn toF32(v: f64) f32 {
    return @floatCast(v);
}

inline fn toI32(v: f64) c_int {
    return @intFromFloat(v);
}

inline fn toU32(v: f64) u32 {
    const i: i64 = @intFromFloat(v);
    if (i < 0) return 0;
    if (i > 0xFFFFFFFF) return 0xFFFFFFFF;
    return @intCast(i);
}

inline fn toBool(v: f64) bool {
    return v != 0.0;
}

inline fn fromU32(v: u32) f64 {
    return @floatFromInt(v);
}

inline fn fromI32(v: c_int) f64 {
    return @floatFromInt(v);
}

inline fn fromF32(v: f32) f64 {
    return @floatCast(v);
}

inline fn fromBool(v: bool) f64 {
    return if (v) 1.0 else 0.0;
}

inline fn fromUsize(v: usize) f64 {
    return @floatFromInt(v);
}

/// Convert a BASIC StringDescriptor* to a null-terminated C string.
/// BASIC string descriptors have layout: { ptr: [*]const u8, len: usize }
/// We extract the pointer and length, copy into a stack buffer, and
/// null-terminate it. Returns null on failure.
///
/// This matches the pattern used in graphics_runtime.zig for string args.
const StringDesc = extern struct {
    ptr: [*]const u8,
    len: usize,
};

fn getStringSlice(desc: ?*const anyopaque) []const u8 {
    const sd = @as(?*const StringDesc, @ptrCast(@alignCast(desc))) orelse return &.{};
    if (sd.len == 0) return &.{};
    return sd.ptr[0..sd.len];
}

/// Thread-local buffer for null-terminating strings passed to C.
/// We use a reasonably large buffer to handle ABC notation and filenames.
threadlocal var str_buf: [8192]u8 = undefined;

fn toCString(desc: ?*const anyopaque) ?[*:0]const u8 {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return null;
    const copy_len = @min(slice.len, str_buf.len - 1);
    @memcpy(str_buf[0..copy_len], slice[0..copy_len]);
    str_buf[copy_len] = 0;
    return @ptrCast(&str_buf);
}

/// Second thread-local buffer for functions needing two string args.
threadlocal var str_buf2: [4096]u8 = undefined;

fn toCString2(desc: ?*const anyopaque) ?[*:0]const u8 {
    const slice = getStringSlice(desc);
    if (slice.len == 0) return null;
    const copy_len = @min(slice.len, str_buf2.len - 1);
    @memcpy(str_buf2[0..copy_len], slice[0..copy_len]);
    str_buf2[copy_len] = 0;
    return @ptrCast(&str_buf2);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Predefined SFX (return sound ID as f64)
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_beep(freq: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_beep(toF32(freq), toF32(dur)));
}

export fn snd_zap(freq: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_zap(toF32(freq), toF32(dur)));
}

export fn snd_explode(size: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_explode(toF32(size), toF32(dur)));
}

export fn snd_big_explosion(size: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_big_explosion(toF32(size), toF32(dur)));
}

export fn snd_small_explosion(intensity: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_small_explosion(toF32(intensity), toF32(dur)));
}

export fn snd_distant_explosion(distance: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_distant_explosion(toF32(distance), toF32(dur)));
}

export fn snd_metal_explosion(shrapnel: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_metal_explosion(toF32(shrapnel), toF32(dur)));
}

export fn snd_bang(intensity: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_bang(toF32(intensity), toF32(dur)));
}

export fn snd_coin(pitch: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_coin(toF32(pitch), toF32(dur)));
}

export fn snd_jump(power: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_jump(toF32(power), toF32(dur)));
}

export fn snd_powerup(intensity: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_powerup(toF32(intensity), toF32(dur)));
}

export fn snd_hurt(severity: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_hurt(toF32(severity), toF32(dur)));
}

export fn snd_shoot(power: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_shoot(toF32(power), toF32(dur)));
}

export fn snd_click(sharpness: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_click(toF32(sharpness), toF32(dur)));
}

export fn snd_blip(pitch: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_blip(toF32(pitch), toF32(dur)));
}

export fn snd_pickup(brightness: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_pickup(toF32(brightness), toF32(dur)));
}

export fn snd_sweep_up(start_freq: f64, end_freq: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_sweep_up(toF32(start_freq), toF32(end_freq), toF32(dur)));
}

export fn snd_sweep_down(start_freq: f64, end_freq: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_sweep_down(toF32(start_freq), toF32(end_freq), toF32(dur)));
}

export fn snd_random_beep(seed: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_random_beep(toU32(seed), toF32(dur)));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Custom Synthesis (return sound ID as f64)
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_tone(freq: f64, dur: f64, wave: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_tone(toF32(freq), toF32(dur), toI32(wave)));
}

export fn snd_note(midi: f64, dur: f64, wave: f64, a: f64, d: f64, s: f64, r: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_note(toI32(midi), toF32(dur), toI32(wave), toF32(a), toF32(d), toF32(s), toF32(r)));
}

export fn snd_noise(noise_type: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_noise(toI32(noise_type), toF32(dur)));
}

export fn snd_fm(carrier: f64, modulator: f64, index: f64, dur: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_fm(toF32(carrier), toF32(modulator), toF32(index), toF32(dur)));
}

export fn snd_filtered_tone(freq: f64, dur: f64, wave: f64, ftype: f64, cutoff: f64, reso: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_filtered_tone(toF32(freq), toF32(dur), toI32(wave), toI32(ftype), toF32(cutoff), toF32(reso)));
}

export fn snd_filtered_note(midi: f64, dur: f64, wave: f64, a: f64, d: f64, s: f64, r: f64, ftype: f64, cutoff: f64, reso: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_filtered_note(toI32(midi), toF32(dur), toI32(wave), toF32(a), toF32(d), toF32(s), toF32(r), toI32(ftype), toF32(cutoff), toF32(reso)));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Effects Processing (return sound ID as f64)
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_reverb(freq: f64, dur: f64, wave: f64, room: f64, damp: f64, wet: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_with_reverb(toF32(freq), toF32(dur), toI32(wave), toF32(room), toF32(damp), toF32(wet)));
}

export fn snd_delay(freq: f64, dur: f64, wave: f64, time: f64, feedback: f64, mix: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_with_delay(toF32(freq), toF32(dur), toI32(wave), toF32(time), toF32(feedback), toF32(mix)));
}

export fn snd_distortion(freq: f64, dur: f64, wave: f64, drive: f64, tone_val: f64, level: f64) callconv(.c) f64 {
    return fromU32(fb_sound_create_with_distortion(toF32(freq), toF32(dur), toI32(wave), toF32(drive), toF32(tone_val), toF32(level)));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Playback & Management (statements)
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_play(id: f64, vol: f64, pan: f64) callconv(.c) void {
    fb_sound_play(toU32(id), toF32(vol), toF32(pan));
}

export fn snd_play_simple(id: f64) callconv(.c) void {
    fb_sound_play_simple(toU32(id));
}

export fn snd_stop() callconv(.c) void {
    fb_sound_stop();
}

export fn snd_stop_one(id: f64) callconv(.c) void {
    fb_sound_stop_one(toU32(id));
}

export fn snd_is_playing(id: f64) callconv(.c) f64 {
    return fromBool(fb_sound_is_playing(toU32(id)));
}

export fn snd_get_duration(id: f64) callconv(.c) f64 {
    return fromF32(fb_sound_get_duration(toU32(id)));
}

export fn snd_free(id: f64) callconv(.c) f64 {
    return fromBool(fb_sound_free(toU32(id)));
}

export fn snd_free_all() callconv(.c) void {
    fb_sound_free_all();
}

export fn snd_set_volume(vol: f64) callconv(.c) void {
    fb_sound_set_volume(toF32(vol));
}

export fn snd_get_volume() callconv(.c) f64 {
    return fromF32(fb_sound_get_volume());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOUND — Queries (return values as f64)
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_exists(id: f64) callconv(.c) f64 {
    return fromBool(fb_sound_exists(toU32(id)));
}

export fn snd_count() callconv(.c) f64 {
    return fromUsize(fb_sound_get_count());
}

export fn snd_mem() callconv(.c) f64 {
    return fromUsize(fb_sound_get_memory_usage());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Utility
// ═══════════════════════════════════════════════════════════════════════════════

export fn snd_note_to_freq(midi: f64) callconv(.c) f64 {
    return fromF32(fb_note_to_freq(toI32(midi)));
}

export fn snd_freq_to_note(freq: f64) callconv(.c) f64 {
    return fromI32(fb_freq_to_note(toF32(freq)));
}

export fn snd_stop_all() callconv(.c) void {
    fb_audio_stop_all();
}

export fn snd_init() callconv(.c) f64 {
    return fromBool(fb_audio_init());
}

export fn snd_shutdown() callconv(.c) void {
    fb_audio_shutdown();
}

export fn snd_is_init() callconv(.c) f64 {
    return fromBool(fb_audio_is_initialized());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Inline Playback (statements with string args)
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_play(abc_desc: ?*const anyopaque, vol: f64) callconv(.c) void {
    const cstr = toCString(abc_desc);
    if (cstr == null) return;
    fb_music_play(cstr, toF32(vol));
}

export fn mus_play_simple(abc_desc: ?*const anyopaque) callconv(.c) void {
    const cstr = toCString(abc_desc);
    if (cstr == null) return;
    fb_music_play_simple(cstr);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank (Load and Play by Slot)
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_load(abc_desc: ?*const anyopaque) callconv(.c) f64 {
    const cstr = toCString(abc_desc);
    if (cstr == null) return 0.0;
    return fromU32(fb_music_load_string(cstr));
}

export fn mus_load_compiled(blob_ptr: ?*const anyopaque, blob_size: f64) callconv(.c) f64 {
    if (blob_ptr == null) return 0.0;
    const sz_i64: i64 = @intFromFloat(blob_size);
    if (sz_i64 <= 0) return 0.0;
    const sz: usize = @intCast(sz_i64);
    return fromU32(fb_music_load_compiled_blob(blob_ptr, sz));
}

export fn mus_play_id(id: f64, vol: f64) callconv(.c) void {
    fb_music_play_id(toU32(id), toF32(vol));
}

export fn mus_play_id_simple(id: f64) callconv(.c) void {
    fb_music_play_id_simple(toU32(id));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Playback Control (statements)
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_stop() callconv(.c) void {
    fb_music_stop();
}

export fn mus_pause() callconv(.c) void {
    fb_music_pause();
}

export fn mus_resume() callconv(.c) void {
    fb_music_resume();
}

export fn mus_set_volume(vol: f64) callconv(.c) void {
    fb_music_set_volume(toF32(vol));
}

export fn mus_get_volume() callconv(.c) f64 {
    return fromF32(fb_music_get_volume());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Bank Management
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_free(id: f64) callconv(.c) f64 {
    return fromBool(fb_music_free(toU32(id)));
}

export fn mus_free_all() callconv(.c) void {
    fb_music_free_all();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Queries
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_is_playing() callconv(.c) f64 {
    return fromBool(fb_music_is_playing());
}

export fn mus_is_playing_id(id: f64) callconv(.c) f64 {
    return fromBool(fb_music_is_playing_id(toU32(id)));
}

export fn mus_state() callconv(.c) f64 {
    return fromI32(fb_music_get_state());
}

export fn mus_exists(id: f64) callconv(.c) f64 {
    return fromBool(fb_music_exists(toU32(id)));
}

export fn mus_count() callconv(.c) f64 {
    return fromUsize(fb_music_get_count());
}

export fn mus_mem() callconv(.c) f64 {
    return fromUsize(fb_music_get_memory_usage());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Metadata (return string descriptors or numeric values)
//
//  These return the C string pointer directly; the codegen should use
//  ret_type "l" (pointer) for the string variants.
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_get_title(id: f64) callconv(.c) ?*anyopaque {
    return string_new_utf8(fb_music_get_title(toU32(id)));
}

export fn mus_get_composer(id: f64) callconv(.c) ?*anyopaque {
    return string_new_utf8(fb_music_get_composer(toU32(id)));
}

export fn mus_get_key(id: f64) callconv(.c) ?*anyopaque {
    return string_new_utf8(fb_music_get_key(toU32(id)));
}

export fn mus_get_tempo(id: f64) callconv(.c) f64 {
    return fromF32(fb_music_get_tempo(toU32(id)));
}

export fn mus_get_compiled_blob_info(id: f64) callconv(.c) ?*anyopaque {
    return string_new_utf8(fb_music_get_compiled_blob_info(toU32(id)));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MUSIC — Rendering (offline ABC → SoundBank ID)
// ═══════════════════════════════════════════════════════════════════════════════

export fn mus_render(abc_desc: ?*const anyopaque, dur: f64, sr: f64) callconv(.c) f64 {
    const cstr = toCString(abc_desc);
    if (cstr == null) return 0.0;
    return fromU32(fb_music_render(cstr, toF32(dur), toF32(sr)));
}

export fn mus_render_simple(abc_desc: ?*const anyopaque) callconv(.c) f64 {
    const cstr = toCString(abc_desc);
    if (cstr == null) return 0.0;
    return fromU32(fb_music_render_simple(cstr));
}

export fn snd_export_wav(id: f64, filename_desc: ?*const anyopaque, vol: f64) callconv(.c) f64 {
    const cstr = toCString(filename_desc);
    if (cstr == null) return 0.0;
    return fromBool(fb_sound_export_wav(toU32(id), cstr, toF32(vol)));
}

export fn mus_render_wav(abc_desc: ?*const anyopaque, filename_desc: ?*const anyopaque, dur: f64, sr: f64) callconv(.c) f64 {
    const abc_cstr = toCString(abc_desc);
    if (abc_cstr == null) return 0.0;
    const file_cstr = toCString(filename_desc);
    if (file_cstr == null) return 0.0;
    return fromBool(fb_music_render_wav(abc_cstr, file_cstr, toF32(dur), toF32(sr)));
}

export fn mus_export_midi(id: f64, filename_desc: ?*const anyopaque) callconv(.c) f64 {
    const cstr = toCString(filename_desc);
    if (cstr == null) return 0.0;
    return fromBool(fb_music_export_midi(toU32(id), cstr));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Oscillator (statements: voice, value)
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_waveform(voice: f64, wave: f64) callconv(.c) void {
    fb_vs_waveform(toI32(voice), toI32(wave));
}

export fn vs_frequency(voice: f64, hz: f64) callconv(.c) void {
    fb_vs_frequency(toI32(voice), toF32(hz));
}

export fn vs_set_note(voice: f64, midi: f64) callconv(.c) void {
    fb_vs_note(toI32(voice), toI32(midi));
}

export fn vs_notename(voice: f64, name_desc: ?*const anyopaque) callconv(.c) void {
    const cstr = toCString(name_desc);
    if (cstr == null) return;
    fb_vs_notename(toI32(voice), cstr);
}

export fn vs_pulse(voice: f64, width: f64) callconv(.c) void {
    fb_vs_pulse(toI32(voice), toF32(width));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Envelope
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_envelope(voice: f64, a: f64, d: f64, s: f64, r: f64) callconv(.c) void {
    fb_vs_envelope(toI32(voice), toF32(a), toF32(d), toF32(s), toF32(r));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Gate
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_gate(voice: f64, on: f64) callconv(.c) void {
    fb_vs_gate(toI32(voice), toBool(on));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Volume & Pan
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_volume(voice: f64, level: f64) callconv(.c) void {
    fb_vs_volume(toI32(voice), toF32(level));
}

export fn vs_pan(voice: f64, pos: f64) callconv(.c) void {
    fb_vs_pan(toI32(voice), toF32(pos));
}

export fn vs_master(level: f64) callconv(.c) void {
    fb_vs_master(toF32(level));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Filter
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_filter_type(ftype: f64) callconv(.c) void {
    fb_vs_filter_type(toI32(ftype));
}

export fn vs_filter_cutoff(hz: f64) callconv(.c) void {
    fb_vs_filter_cutoff(toF32(hz));
}

export fn vs_filter_resonance(q: f64) callconv(.c) void {
    fb_vs_filter_resonance(toF32(q));
}

export fn vs_filter_enabled(on: f64) callconv(.c) void {
    fb_vs_filter_enabled(toBool(on));
}

export fn vs_filter_route(voice: f64, on: f64) callconv(.c) void {
    fb_vs_filter_route(toI32(voice), toBool(on));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Modulation
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_ring(voice: f64, source: f64) callconv(.c) void {
    fb_vs_ring(toI32(voice), toI32(source));
}

export fn vs_sync_voice(voice: f64, source: f64) callconv(.c) void {
    fb_vs_sync(toI32(voice), toI32(source));
}

export fn vs_portamento(voice: f64, secs: f64) callconv(.c) void {
    fb_vs_portamento(toI32(voice), toF32(secs));
}

export fn vs_detune(voice: f64, cents: f64) callconv(.c) void {
    fb_vs_detune(toI32(voice), toF32(cents));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Per-Voice Delay
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_delay_on(voice: f64, on: f64) callconv(.c) void {
    fb_vs_delay_enabled(toI32(voice), toBool(on));
}

export fn vs_delay_time(voice: f64, secs: f64) callconv(.c) void {
    fb_vs_delay_time(toI32(voice), toF32(secs));
}

export fn vs_delay_feedback(voice: f64, fb: f64) callconv(.c) void {
    fb_vs_delay_feedback(toI32(voice), toF32(fb));
}

export fn vs_delay_mix(voice: f64, mix: f64) callconv(.c) void {
    fb_vs_delay_mix(toI32(voice), toF32(mix));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — LFO
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_lfo_waveform(lfo: f64, wave: f64) callconv(.c) void {
    fb_vs_lfo_waveform(toI32(lfo), toI32(wave));
}

export fn vs_lfo_rate(lfo: f64, hz: f64) callconv(.c) void {
    fb_vs_lfo_rate(toI32(lfo), toF32(hz));
}

export fn vs_lfo_reset(lfo: f64) callconv(.c) void {
    fb_vs_lfo_reset(toI32(lfo));
}

export fn vs_lfo_pitch(voice: f64, lfo: f64, depth: f64) callconv(.c) void {
    fb_vs_lfo_pitch(toI32(voice), toI32(lfo), toF32(depth));
}

export fn vs_lfo_volume(voice: f64, lfo: f64, depth: f64) callconv(.c) void {
    fb_vs_lfo_volume(toI32(voice), toI32(lfo), toF32(depth));
}

export fn vs_lfo_filter(voice: f64, lfo: f64, depth: f64) callconv(.c) void {
    fb_vs_lfo_filter(toI32(voice), toI32(lfo), toF32(depth));
}

export fn vs_lfo_pulse(voice: f64, lfo: f64, depth: f64) callconv(.c) void {
    fb_vs_lfo_pulse(toI32(voice), toI32(lfo), toF32(depth));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Physical Modeling
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_phys_model(voice: f64, model: f64) callconv(.c) void {
    fb_vs_physical_model(toI32(voice), toI32(model));
}

export fn vs_phys_damping(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_damping(toI32(voice), toF32(val));
}

export fn vs_phys_brightness(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_brightness(toI32(voice), toF32(val));
}

export fn vs_phys_excitation(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_excitation(toI32(voice), toF32(val));
}

export fn vs_phys_resonance(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_resonance(toI32(voice), toF32(val));
}

export fn vs_phys_tension(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_tension(toI32(voice), toF32(val));
}

export fn vs_phys_pressure(voice: f64, val: f64) callconv(.c) void {
    fb_vs_physical_pressure(toI32(voice), toF32(val));
}

export fn vs_phys_trigger(voice: f64) callconv(.c) void {
    fb_vs_physical_trigger(toI32(voice));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Global Control
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_reset() callconv(.c) void {
    fb_vs_reset();
}

export fn vs_stop() callconv(.c) void {
    fb_vs_reset();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Queries
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_active_count() callconv(.c) f64 {
    return fromI32(fb_vs_active_count());
}

export fn vs_get_master() callconv(.c) f64 {
    return fromF32(fb_vs_get_master());
}

export fn vs_is_playing() callconv(.c) f64 {
    return fromBool(fb_vs_is_playing());
}

// ═══════════════════════════════════════════════════════════════════════════════
//  VS — Recording & Rendering
// ═══════════════════════════════════════════════════════════════════════════════

export fn vs_rec_start() callconv(.c) void {
    fb_vs_record_start();
}

export fn vs_rec_tempo(bpm: f64) callconv(.c) void {
    fb_vs_record_tempo(toF32(bpm));
}

export fn vs_rec_wait(beats: f64) callconv(.c) void {
    fb_vs_record_wait(toF32(beats));
}

export fn vs_rec_save(vol: f64) callconv(.c) f64 {
    return fromU32(fb_vs_record_save(toF32(vol)));
}

export fn vs_rec_play(vol: f64) callconv(.c) void {
    fb_vs_record_play(toF32(vol));
}

export fn vs_rec_wav(filename_desc: ?*const anyopaque) callconv(.c) void {
    const cstr = toCString(filename_desc);
    if (cstr == null) return;
    fb_vs_record_wav(cstr);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Anti-Dead-Strip — Force the linker to retain all exported symbols
// ═══════════════════════════════════════════════════════════════════════════════
//
// The Zig linker dead-strips `export fn` symbols that aren't referenced from
// C/ObjC code, even with rdynamic = true.  The JIT linker resolves these at
// runtime via dlsym(RTLD_DEFAULT, …), so they MUST survive linking.
//
// Taking the address of each function in a `comptime` block that is
// reachable from the root source file prevents the linker from removing them.

comptime {
    const refs = .{
        // SOUND — predefined SFX
        &snd_beep,
        &snd_zap,
        &snd_explode,
        &snd_big_explosion,
        &snd_small_explosion,
        &snd_distant_explosion,
        &snd_metal_explosion,
        &snd_bang,
        &snd_coin,
        &snd_jump,
        &snd_powerup,
        &snd_hurt,
        &snd_shoot,
        &snd_click,
        &snd_blip,
        &snd_pickup,
        &snd_sweep_up,
        &snd_sweep_down,
        &snd_random_beep,
        // SOUND — custom synthesis
        &snd_tone,
        &snd_note,
        &snd_noise,
        &snd_fm,
        &snd_filtered_tone,
        &snd_filtered_note,
        // SOUND — effects
        &snd_reverb,
        &snd_delay,
        &snd_distortion,
        // SOUND — playback & management
        &snd_play,
        &snd_play_simple,
        &snd_stop,
        &snd_stop_one,
        &snd_is_playing,
        &snd_get_duration,
        &snd_free,
        &snd_free_all,
        &snd_set_volume,
        &snd_get_volume,
        // SOUND — queries
        &snd_exists,
        &snd_count,
        &snd_mem,
        // Utility
        &snd_note_to_freq,
        &snd_freq_to_note,
        &snd_stop_all,
        &snd_init,
        &snd_shutdown,
        &snd_is_init,
        // MUSIC — playback
        &mus_play,
        &mus_play_simple,
        &mus_load,
        &mus_load_compiled,
        &mus_play_id,
        &mus_play_id_simple,
        &mus_stop,
        &mus_pause,
        &mus_resume,
        &mus_set_volume,
        &mus_get_volume,
        // MUSIC — bank management
        &mus_free,
        &mus_free_all,
        // MUSIC — queries
        &mus_is_playing,
        &mus_is_playing_id,
        &mus_state,
        &mus_exists,
        &mus_count,
        &mus_mem,
        // MUSIC — metadata
        &mus_get_title,
        &mus_get_composer,
        &mus_get_key,
        &mus_get_tempo,
        &mus_get_compiled_blob_info,
        // MUSIC — rendering
        &mus_render,
        &mus_render_simple,
        &snd_export_wav,
        &mus_render_wav,
        &mus_export_midi,
        // VS — oscillator
        &vs_waveform,
        &vs_frequency,
        &vs_set_note,
        &vs_notename,
        &vs_pulse,
        // VS — envelope & gate
        &vs_envelope,
        &vs_gate,
        // VS — volume & pan
        &vs_volume,
        &vs_pan,
        &vs_master,
        // VS — filter
        &vs_filter_type,
        &vs_filter_cutoff,
        &vs_filter_resonance,
        &vs_filter_enabled,
        &vs_filter_route,
        // VS — modulation
        &vs_ring,
        &vs_sync_voice,
        &vs_portamento,
        &vs_detune,
        // VS — per-voice delay
        &vs_delay_on,
        &vs_delay_time,
        &vs_delay_feedback,
        &vs_delay_mix,
        // VS — LFO
        &vs_lfo_waveform,
        &vs_lfo_rate,
        &vs_lfo_reset,
        &vs_lfo_pitch,
        &vs_lfo_volume,
        &vs_lfo_filter,
        &vs_lfo_pulse,
        // VS — physical modeling
        &vs_phys_model,
        &vs_phys_damping,
        &vs_phys_brightness,
        &vs_phys_excitation,
        &vs_phys_resonance,
        &vs_phys_tension,
        &vs_phys_pressure,
        &vs_phys_trigger,
        // VS — global control
        &vs_reset,
        // VS — queries
        &vs_active_count,
        &vs_get_master,
        &vs_is_playing,
        // VS — recording
        &vs_rec_start,
        &vs_rec_tempo,
        &vs_rec_wait,
        &vs_rec_save,
        &vs_rec_play,
        &vs_rec_wav,
    };
    _ = refs;
}
