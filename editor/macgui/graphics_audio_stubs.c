// graphics_audio_stubs.c
//
// Stub implementations of graphics and audio functions for console-mode builds.
//
// When console mode is used, these stubs are linked instead of the full
// graphics/audio platform library. They either:
//   - Return immediately (no-op)
//   - Return default values (0, empty)
//   - Print a warning message (optional, can be disabled)
//
// This keeps console executables small and fast without the 6.6MB platform
// library and complex AppKit threading overhead.

#include <stdio.h>
#include <stdint.h>

// Set to 1 to print warnings when graphics/audio functions are called
#define WARN_ON_GRAPHICS_CALL 0

// ═══════════════════════════════════════════════════════════════════════════
// Graphics Window Functions
// ═══════════════════════════════════════════════════════════════════════════

void gfx_screen(double width, double height, double scale) {
#if WARN_ON_GRAPHICS_CALL
    fprintf(stderr, "Warning: SCREEN called in console mode (no graphics available)\n");
#endif
    (void)width; (void)height; (void)scale;
}

void gfx_screen_close(void) {
    // no-op
}

void gfx_screen_title(const void *desc) {
    (void)desc;
}

void gfx_screen_mode(const void *desc) {
    (void)desc;
}

double gfx_screen_width(void) {
    return 0.0;
}

double gfx_screen_height(void) {
    return 0.0;
}

double gfx_screen_active(void) {
    return 0.0; // Not active
}

void gfx_mark_closed(void) {
    // no-op in console mode (signal-safe stub)
}

// ═══════════════════════════════════════════════════════════════════════════
// Drawing Functions
// ═══════════════════════════════════════════════════════════════════════════

void gfx_pset(double x, double y, double c) {
    (void)x; (void)y; (void)c;
}

void gfx_line(double x1, double y1, double x2, double y2, double c) {
    (void)x1; (void)y1; (void)x2; (void)y2; (void)c;
}

void gfx_rect(double x, double y, double w, double h, double c, double filled) {
    (void)x; (void)y; (void)w; (void)h; (void)c; (void)filled;
}

void gfx_circle(double cx, double cy, double r, double c, double filled) {
    (void)cx; (void)cy; (void)r; (void)c; (void)filled;
}

void gfx_cls(double c) {
    (void)c;
}

double gfx_pget(double x, double y) {
    (void)x; (void)y;
    return 0.0;
}

void gfx_draw_text(double x, double y, const void *text, double color, double scale) {
    (void)x; (void)y; (void)text; (void)color; (void)scale;
}

double gfx_text_width(const void *text, double scale) {
    (void)text; (void)scale;
    return 0.0;
}

double gfx_text_height(double scale) {
    (void)scale;
    return 0.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Display Control
// ═══════════════════════════════════════════════════════════════════════════

void gfx_vsync(void) {
    // no-op
}

void gfx_flip(void) {
    // no-op
}

void gfx_set_scroll(double sx, double sy) {
    (void)sx; (void)sy;
}

// ═══════════════════════════════════════════════════════════════════════════
// Palette Functions
// ═══════════════════════════════════════════════════════════════════════════

void gfx_palette(double index, double r, double g, double b) {
    (void)index; (void)r; (void)g; (void)b;
}

void gfx_palette_reset(void) {
    // no-op
}

// ═══════════════════════════════════════════════════════════════════════════
// Sprite Functions
// ═══════════════════════════════════════════════════════════════════════════

void gfx_sprite_def(double id, double w, double h) {
    (void)id; (void)w; (void)h;
}

void gfx_sprite_data(double id, double x, double y, double c) {
    (void)id; (void)x; (void)y; (void)c;
}

void gfx_sprite_palette(double id, double idx, double r, double g, double b) {
    (void)id; (void)idx; (void)r; (void)g; (void)b;
}

void gfx_sprite_load(double id, const void *filename) {
    (void)id; (void)filename;
}

void gfx_sprite(double id, double x, double y, double frame) {
    (void)id; (void)x; (void)y; (void)frame;
}

void gfx_sprite_pos(double id, double x, double y) {
    (void)id; (void)x; (void)y;
}

void gfx_sprite_move(double id, double dx, double dy) {
    (void)id; (void)dx; (void)dy;
}

void gfx_sprite_rot(double id, double angle) {
    (void)id; (void)angle;
}

void gfx_sprite_scale(double id, double sx, double sy) {
    (void)id; (void)sx; (void)sy;
}

void gfx_sprite_show(double id) {
    (void)id;
}

void gfx_sprite_hide(double id) {
    (void)id;
}

void gfx_sprite_frame(double id, double frame) {
    (void)id; (void)frame;
}

void gfx_sprite_animate(double id, double speed) {
    (void)id; (void)speed;
}

void gfx_sprite_remove(double id) {
    (void)id;
}

void gfx_sprite_remove_all(void) {
    // no-op
}

// ═══════════════════════════════════════════════════════════════════════════
// Input Functions
// ═══════════════════════════════════════════════════════════════════════════

double gfx_inkey(void) {
    return 0.0; // No key pressed
}

double gfx_keydown(double keycode) {
    (void)keycode;
    return 0.0; // Not pressed
}

double gfx_mousex(void) {
    return 0.0;
}

double gfx_mousey(void) {
    return 0.0;
}

double gfx_mousebutton(double button) {
    (void)button;
    return 0.0; // Not pressed
}

double gfx_mousescroll(void) {
    return 0.0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Audio Functions - Simple Sounds
// ═══════════════════════════════════════════════════════════════════════════

void snd_play(double frequency, double duration, double volume) {
#if WARN_ON_GRAPHICS_CALL
    static int warned = 0;
    if (!warned) {
        fprintf(stderr, "Warning: SOUND called in console mode (no audio available)\n");
        warned = 1;
    }
#endif
    (void)frequency; (void)duration; (void)volume;
}

void snd_play_simple(double frequency) {
    (void)frequency;
}

// ═══════════════════════════════════════════════════════════════════════════
// Audio Functions - Music
// ═══════════════════════════════════════════════════════════════════════════

void mus_play(const void *abc_string, double volume) {
    (void)abc_string; (void)volume;
}

void mus_play_simple(const void *abc_string) {
    (void)abc_string;
}

void mus_play_id(double track_id, double volume) {
    (void)track_id; (void)volume;
}

void mus_play_id_simple(double track_id) {
    (void)track_id;
}

// ═══════════════════════════════════════════════════════════════════════════
// Audio Functions - Voice Synthesis (stubs for all vs_* functions)
// ═══════════════════════════════════════════════════════════════════════════

void vs_play(double voice, double note, double duration, double volume) {
    (void)voice; (void)note; (void)duration; (void)volume;
}

void vs_volume(double voice, double volume) {
    (void)voice; (void)volume;
}

void vs_waveform(double voice, double waveform) {
    (void)voice; (void)waveform;
}

void vs_adsr(double voice, double attack, double decay, double sustain, double release) {
    (void)voice; (void)attack; (void)decay; (void)sustain; (void)release;
}

void vs_detune(double voice, double cents) {
    (void)voice; (void)cents;
}

void vs_duty(double voice, double duty_cycle) {
    (void)voice; (void)duty_cycle;
}

void vs_noise(double voice, double freq_mode) {
    (void)voice; (void)freq_mode;
}

void vs_ring(double voice, double modulator) {
    (void)voice; (void)modulator;
}

void vs_sync_voice(double voice, double master) {
    (void)voice; (void)master;
}

void vs_filter(double voice, double cutoff, double resonance, double filter_type) {
    (void)voice; (void)cutoff; (void)resonance; (void)filter_type;
}

void vs_pulse(double voice, double note, double duration) {
    (void)voice; (void)note; (void)duration;
}

void vs_reset(double voice) {
    (void)voice;
}

void vs_rec_start(void) {
    // no-op
}

void vs_rec_tempo(double bpm) {
    (void)bpm;
}

void vs_rec_wait(double beats) {
    (void)beats;
}

void vs_rec_save(const void *filename) {
    (void)filename;
}

void vs_rec_play(void) {
    // no-op
}

void vs_rec_wav(const void *filename) {
    (void)filename;
}

// ═══════════════════════════════════════════════════════════════════════════
// Terminal Graphics Aliases
// ═══════════════════════════════════════════════════════════════════════════

void basic_pset(double x, double y, double c) {
    (void)x; (void)y; (void)c;
}

void basic_line_draw(double x1, double y1, double x2, double y2, double c) {
    (void)x1; (void)y1; (void)x2; (void)y2; (void)c;
}

void basic_circle(double cx, double cy, double r, double c, double filled) {
    (void)cx; (void)cy; (void)r; (void)c; (void)filled;
}

void basic_rect(double x, double y, double w, double h, double c, double filled) {
    (void)x; (void)y; (void)w; (void)h; (void)c; (void)filled;
}

// ═══════════════════════════════════════════════════════════════════════════
// Runtime Symbol Forcing (stub for AOT console mode)
// ═══════════════════════════════════════════════════════════════════════════

// In JIT mode, force_runtime_symbols.c ensures symbols aren't stripped.
// In AOT console mode, we don't need this (no dlsym), so provide a no-op stub.
void basic_force_runtime_symbols(void) {
    // no-op in console mode (AOT has direct linkage)
}