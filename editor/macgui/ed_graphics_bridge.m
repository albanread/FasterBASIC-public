// ─── Ed Graphics Bridge ─────────────────────────────────────────────────────
//
// Objective-C / Metal bridge for the retro graphics window. Provides:
//
//   1. GraphicsWindowController — NSWindow + MTKView creation/lifecycle
//   2. GraphicsMetalRenderer    — MTKViewDelegate: command drain, GPU passes
//   3. Shared MTLBuffer allocation (MTLStorageModeShared)
//   4. Keyboard/mouse event forwarding to Zig atomic state
//   5. Metal shader compilation and pipeline state management
//
// Communication with Zig (ed_graphics.zig) is through C-callable functions:
//   - gfx_dequeue_command()    — drain the SPSC command ring
//   - gfx_set_pixel_buffer()   — pass shared buffer pointers to Zig
//   - gfx_signal_vsync()       — signal JIT thread sync primitives
//   - gfx_set_key_state()      — forward input events
//   - etc.
//
// This file is compiled by Zig's build system as an ObjC source file
// with -fobjc-arc and linked into the Ed binary.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include "embedded_graphics_metal_source.h"

// ─── Extern Zig Functions (graphics_runtime.zig) ────────────────────────────
//
// Every `export fn` in graphics_runtime.zig must be referenced from this
// ObjC compilation unit so the linker retains them.  The JIT resolves
// these at runtime via dlsym(RTLD_DEFAULT, …).

extern void gfx_screen(double w, double h, double scale);
extern void gfx_screen_close(void);
extern void gfx_screen_title(const void *desc);
extern void gfx_screen_mode(const void *desc);
extern void gfx_set_target(double buf);
extern void gfx_pset(double x, double y, double c);
extern double gfx_pget(double x, double y);
extern void gfx_line(double x1, double y1, double x2, double y2, double c);
extern void gfx_rect(double x, double y, double w, double h, double c, double filled);
extern void gfx_circle(double cx, double cy, double r, double c, double filled);
extern void gfx_ellipse(double cx, double cy, double rx, double ry, double c, double filled);
extern void gfx_triangle(double x1, double y1, double x2, double y2, double x3, double y3, double c, double filled);
extern void gfx_fill_area(double x, double y, double c);
extern void gfx_cls(double c);
extern void gfx_scroll_buffer(double dx, double dy, double fill);
extern void gfx_blit(double sb, double sx, double sy, double db, double dx, double dy, double w, double h);
extern void gfx_blit_solid(double sb, double sx, double sy, double db, double dx, double dy, double w, double h);
extern void gfx_blit_scale(double sb, double sx, double sy, double sw, double sh, double db, double dx, double dy, double dw, double dh);
extern void gfx_blit_flip(double sb, double sx, double sy, double db, double dx, double dy, double w, double h, double fm);
extern void gfx_palette(double idx, double r, double g, double b);
extern void gfx_line_palette(double line, double idx, double r, double g, double b);
extern void gfx_reset_palette(void);
extern double gfx_palette_get(double idx);
extern double gfx_line_palette_get(double line, double idx);
extern void gfx_pal_cycle(double slot, double start, double end, double speed, double dir);
extern void gfx_pal_fade(double slot, double idx, double speed, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_pulse(double slot, double idx, double speed, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_gradient(double slot, double idx, double ls, double le, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_strobe(double slot, double idx, double on, double off, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_stop(double slot);
extern void gfx_pal_stop_all(void);
extern void gfx_pal_pause(double slot);
extern void gfx_pal_resume(double slot);
extern void gfx_pal_cycle_lines(double slot, double idx, double ls, double le, double speed, double dir);
extern void gfx_pal_fade_lines(double slot, double idx, double ls, double le, double speed, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_pulse_lines(double slot, double idx, double ls, double le, double speed, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_pal_strobe_lines(double slot, double idx, double ls, double le, double on, double off, double r1, double g1, double b1, double r2, double g2, double b2);
extern void gfx_draw_text(double x, double y, const void *desc, double c, double font);
extern double gfx_text_width(const void *desc, double font);
extern double gfx_text_height(double font);
extern void gfx_flip(void);
extern void gfx_vsync(void);
extern void gfx_set_scroll(double x, double y);
extern void gfx_menu_reset(void);
extern void gfx_menu_add_menu(double menu_id, const void *title);
extern void gfx_menu_add_item(double menu_id, double item_id, const void *label, const void *shortcut, double flags);
extern void gfx_menu_add_separator(double menu_id);
extern void gfx_menu_set_checked(double item_id, double on);
extern void gfx_menu_set_enabled(double item_id, double on);
extern void gfx_menu_rename(double item_id, const void *label);
extern double gfx_menu_next(void);
extern void gfx_dialog_reset(void);
extern void gfx_dialog_begin(double dialog_id);
extern void gfx_dialog_set_title(const void *title);
extern void gfx_dialog_set_message(const void *message);
extern void gfx_dialog_add_label(const void *text);
extern void gfx_dialog_add_textfield(double control_id, const void *label, const void *default_text);
extern void gfx_dialog_add_securefield(double control_id, const void *label, const void *default_text);
extern void gfx_dialog_add_textarea(double control_id, const void *label, const void *default_text);
extern void gfx_dialog_add_numberfield(double control_id, const void *label, double default_value, double min_value, double max_value, double step);
extern void gfx_dialog_add_slider(double control_id, const void *label, double min_value, double max_value, double default_value);
extern void gfx_dialog_add_filepicker(double control_id, const void *label, const void *default_path);
extern void gfx_dialog_add_checkbox(double control_id, const void *label, double checked);
extern void gfx_dialog_add_radio(double control_id, double group_id, const void *label, double selected);
extern void gfx_dialog_add_dropdown(double control_id, const void *label, const void *options, double default_index);
extern void gfx_dialog_add_button(double control_id, const void *label, double flags);
extern void gfx_dialog_end(void);
extern double gfx_dialog_show(double dialog_id);
extern void *gfx_dialog_get_text(double control_id);
extern double gfx_dialog_get_checked(double control_id);
extern double gfx_dialog_get_selection(double control_id);
extern void gfx_dialog_set_text(double control_id, const void *value);
extern void gfx_dialog_set_number(double control_id, double value);
extern void gfx_dialog_set_checked(double control_id, double on);
extern void gfx_dialog_set_selection(double control_id, double index);
extern void gfx_commit(void);
extern void gfx_wait(void);
extern void gfx_wait_frames(double n);
extern double gfx_fence(void);
extern double gfx_fence_done(double id);
extern double gfx_collide(double ba, double ax, double ay, double bb, double bx, double by, double w, double h);
extern void gfx_collide_setup(double i, double buf, double x, double y, double w, double h);
extern void gfx_collide_src(double buf, double x, double y, double w, double h);
extern void gfx_collide_test(void);
extern double gfx_collide_result(double i, double j);
extern double gfx_inkey(void);
extern double gfx_keydown(double k);
extern double gfx_mousex(void);
extern double gfx_mousey(void);
extern double gfx_mousebutton(void);
extern double gfx_mousescroll(void);
extern double gfx_joy_count(void);
extern double gfx_joy_axis(double c, double a);
extern double gfx_joy_button(double c, double b);
extern double gfx_screen_width(void);
extern double gfx_screen_height(void);
extern double gfx_screen_active(void);
extern double gfx_front_buffer(void);
extern double gfx_buffer_width(void);
extern double gfx_buffer_height(void);
extern double gfx_image_define(double id, double width, double height, double format);
extern void gfx_image_destroy(double id);
extern double gfx_image_exists(double id);
extern double gfx_image_apply_batch_raw(double id, const void *data, double len);
extern double gfx_image_get_rgba_ptr(double id);
extern double gfx_image_get_stride(double id);
extern double gfx_image_width(double id);
extern double gfx_image_height(double id);

// Anchor table: the linker sees these references and retains all symbols.
// Sprite runtime functions
extern void gfx_sprite_load(double id, const void *desc);
extern void gfx_sprite_def(double id, double w, double h);
extern void gfx_sprite_data(double id, double x, double y, double c);
extern void gfx_sprite_palette(double id, double idx, double r, double g, double b);
extern void gfx_sprite_std_pal(double id, double pal_id);
extern void gfx_sprite_frames(double id, double fw, double fh, double count);
extern void gfx_sprite(double inst, double def, double x, double y);
extern void gfx_sprite_pos(double inst, double x, double y);
extern void gfx_sprite_move(double inst, double dx, double dy);
extern void gfx_sprite_rot(double inst, double angle_deg);
extern void gfx_sprite_scale(double inst, double sx, double sy);
extern void gfx_sprite_anchor(double inst, double ax, double ay);
extern void gfx_sprite_show(double inst);
extern void gfx_sprite_hide(double inst);
extern void gfx_sprite_flip(double inst, double h, double v);
extern void gfx_sprite_alpha(double inst, double a);
extern void gfx_sprite_frame(double inst, double frame);
extern void gfx_sprite_animate(double inst, double speed);
extern void gfx_sprite_priority(double inst, double pri);
extern void gfx_sprite_blend(double inst, double mode);
extern void gfx_sprite_remove(double inst);
extern void gfx_sprite_remove_all(void);
extern void gfx_sprite_commit(double id);
extern void gfx_sprite_begin(double id);
extern void gfx_sprite_end(void);
extern void gfx_sprite_row(double row, const void *data, double count);
extern void gfx_sprite_fx(double inst, double fx_type);
extern void gfx_sprite_fx_param(double inst, double p1, double p2);
extern void gfx_sprite_fx_colour(double inst, double r, double g, double b, double a);
extern void gfx_sprite_glow(double inst, double radius, double intensity, double r, double g, double b);
extern void gfx_sprite_outline(double inst, double thickness, double r, double g, double b);
extern void gfx_sprite_shadow(double inst, double ox, double oy, double r, double g, double b, double a);
extern void gfx_sprite_tint(double inst, double factor, double r, double g, double b);
extern void gfx_sprite_flash(double inst, double speed, double r, double g, double b);
extern void gfx_sprite_fx_off(double inst);
extern void gfx_sprite_pal_override(double inst, double def_id);
extern void gfx_sprite_pal_reset(double inst);
extern double gfx_sprite_x(double inst);
extern double gfx_sprite_y(double inst);
extern double gfx_sprite_get_rot(double inst);
extern double gfx_sprite_visible(double inst);
extern double gfx_sprite_get_frame(double inst);
extern double gfx_sprite_hit(double a, double b);
extern double gfx_sprite_count(void);
extern void gfx_sprite_collide(double inst, double group);
extern double gfx_sprite_overlap(double grp_a, double grp_b);
extern void gfx_sprite_sync(void);
extern void gfx_screensave(const void *path);

__attribute__((used))
static const void *_gfx_runtime_anchor[] = {
    (const void *)gfx_screen,        (const void *)gfx_screen_close,
    (const void *)gfx_screen_title,  (const void *)gfx_screen_mode,
    (const void *)gfx_set_target,    (const void *)gfx_pset,
    (const void *)gfx_pget,          (const void *)gfx_line,
    (const void *)gfx_rect,          (const void *)gfx_circle,
    (const void *)gfx_ellipse,       (const void *)gfx_triangle,
    (const void *)gfx_fill_area,     (const void *)gfx_cls,
    (const void *)gfx_scroll_buffer, (const void *)gfx_blit,
    (const void *)gfx_blit_solid,    (const void *)gfx_blit_scale,
    (const void *)gfx_blit_flip,     (const void *)gfx_palette,
    (const void *)gfx_line_palette,  (const void *)gfx_reset_palette,
    (const void *)gfx_palette_get,   (const void *)gfx_line_palette_get,
    (const void *)gfx_pal_cycle,     (const void *)gfx_pal_fade,
    (const void *)gfx_pal_pulse,     (const void *)gfx_pal_gradient,
    (const void *)gfx_pal_strobe,    (const void *)gfx_pal_stop,
    (const void *)gfx_pal_stop_all,   (const void *)gfx_pal_pause,
    (const void *)gfx_pal_resume,     (const void *)gfx_pal_cycle_lines,
    (const void *)gfx_pal_fade_lines, (const void *)gfx_pal_pulse_lines,
    (const void *)gfx_pal_strobe_lines, (const void *)gfx_draw_text,
    (const void *)gfx_text_width,    (const void *)gfx_text_height,
    (const void *)gfx_flip,          (const void *)gfx_vsync,
    (const void *)gfx_set_scroll,    (const void *)gfx_commit,
    (const void *)gfx_menu_reset,    (const void *)gfx_menu_add_menu,
    (const void *)gfx_menu_add_item, (const void *)gfx_menu_add_separator,
    (const void *)gfx_menu_set_checked, (const void *)gfx_menu_set_enabled,
    (const void *)gfx_menu_rename,   (const void *)gfx_menu_next,
    (const void *)gfx_dialog_reset,  (const void *)gfx_dialog_begin,
    (const void *)gfx_dialog_set_title, (const void *)gfx_dialog_set_message,
    (const void *)gfx_dialog_add_label, (const void *)gfx_dialog_add_textfield,
    (const void *)gfx_dialog_add_securefield, (const void *)gfx_dialog_add_textarea,
    (const void *)gfx_dialog_add_numberfield, (const void *)gfx_dialog_add_slider,
    (const void *)gfx_dialog_add_filepicker,
    (const void *)gfx_dialog_add_checkbox, (const void *)gfx_dialog_add_radio,
    (const void *)gfx_dialog_add_dropdown, (const void *)gfx_dialog_add_button,
    (const void *)gfx_dialog_end,    (const void *)gfx_dialog_show,
    (const void *)gfx_dialog_get_text, (const void *)gfx_dialog_get_checked,
    (const void *)gfx_dialog_get_selection,
    (const void *)gfx_dialog_set_text, (const void *)gfx_dialog_set_number,
    (const void *)gfx_dialog_set_checked, (const void *)gfx_dialog_set_selection,
    (const void *)gfx_wait,          (const void *)gfx_wait_frames,
    (const void *)gfx_fence,
    (const void *)gfx_fence_done,    (const void *)gfx_collide,
    (const void *)gfx_collide_setup, (const void *)gfx_collide_src,
    (const void *)gfx_collide_test,  (const void *)gfx_collide_result,
    (const void *)gfx_inkey,         (const void *)gfx_keydown,
    (const void *)gfx_mousex,        (const void *)gfx_mousey,
    (const void *)gfx_mousebutton,   (const void *)gfx_mousescroll,
    (const void *)gfx_joy_count,     (const void *)gfx_joy_axis,
    (const void *)gfx_joy_button,    (const void *)gfx_screen_width,
    (const void *)gfx_screen_height, (const void *)gfx_screen_active,
    (const void *)gfx_front_buffer,  (const void *)gfx_buffer_width,
    (const void *)gfx_buffer_height,
    // Sprite system
    (const void *)gfx_sprite_load,   (const void *)gfx_sprite_def,
    (const void *)gfx_sprite_data,   (const void *)gfx_sprite_palette,
    (const void *)gfx_sprite_std_pal,(const void *)gfx_sprite_frames,
    (const void *)gfx_sprite,        (const void *)gfx_sprite_pos,
    (const void *)gfx_sprite_move,   (const void *)gfx_sprite_rot,
    (const void *)gfx_sprite_scale,  (const void *)gfx_sprite_anchor,
    (const void *)gfx_sprite_show,   (const void *)gfx_sprite_hide,
    (const void *)gfx_sprite_flip,   (const void *)gfx_sprite_alpha,
    (const void *)gfx_sprite_frame,  (const void *)gfx_sprite_animate,
    (const void *)gfx_sprite_priority,(const void *)gfx_sprite_blend,
    (const void *)gfx_sprite_remove, (const void *)gfx_sprite_remove_all,
    (const void *)gfx_sprite_commit,
    (const void *)gfx_sprite_begin,  (const void *)gfx_sprite_end,
    (const void *)gfx_sprite_row,
    (const void *)gfx_sprite_fx,     (const void *)gfx_sprite_fx_param,
    (const void *)gfx_sprite_fx_colour,(const void *)gfx_sprite_glow,
    (const void *)gfx_sprite_outline,(const void *)gfx_sprite_shadow,
    (const void *)gfx_sprite_tint,   (const void *)gfx_sprite_flash,
    (const void *)gfx_sprite_fx_off, (const void *)gfx_sprite_pal_override,
    (const void *)gfx_sprite_pal_reset,
    (const void *)gfx_sprite_x,      (const void *)gfx_sprite_y,
    (const void *)gfx_sprite_get_rot,(const void *)gfx_sprite_visible,
    (const void *)gfx_sprite_get_frame,(const void *)gfx_sprite_hit,
    (const void *)gfx_sprite_count,  (const void *)gfx_sprite_collide,
    (const void *)gfx_sprite_overlap,  (const void *)gfx_sprite_sync,
    // Screen save
    (const void *)gfx_screensave,
};

// ─── Extern Zig Functions (ed_graphics.zig) ─────────────────────────────────
//
// These are defined in ed_graphics.zig as `export fn` with callconv(.c).

extern int32_t gfx_dequeue_command(uint8_t *out_type, uint32_t *out_fence, uint8_t *out_payload);
extern void gfx_set_pixel_buffer(int32_t index, void *ptr, uint64_t size);
extern void gfx_set_line_palette(void *ptr, uint32_t count);
extern void gfx_set_global_palette(void *ptr);
extern void gfx_set_palette_effects(void *ptr);
extern void gfx_set_collision_flags(void *ptr);
extern void gfx_signal_vsync(void);
extern void gfx_signal_gpu_wait(void);
extern void gfx_update_fence(uint32_t fence_id);
extern void gfx_set_key_state(uint8_t keycode, int32_t pressed);
extern void gfx_set_mouse_state(int16_t x, int16_t y, uint8_t buttons);
extern void gfx_add_mouse_scroll(int16_t delta);
extern void gfx_menu_push_event(uint16_t item_id);
extern void gfx_menu_clear_events(void);
extern void gfx_mark_closed(void);
extern void gfx_get_resolution(uint16_t *w, uint16_t *h, uint16_t *bw, uint16_t *bh, uint16_t *ox, uint16_t *oy);
extern int32_t gfx_get_collision_source(uint8_t i, uint8_t *buf, int16_t *x, int16_t *y, uint16_t *w, uint16_t *h);
extern uint8_t gfx_get_collision_count(void);
extern uint8_t gfx_get_front_buffer(void);
extern void gfx_get_scroll(int16_t *x, int16_t *y);
extern void gfx_get_par(uint16_t *num, uint16_t *den);
extern void gfx_set_controller_state(uint8_t controller, int32_t connected, const float *axes, uint32_t buttons);
extern void gfx_set_controller_disconnected(uint8_t controller);

// Sprite system
extern void gfx_set_sprite_buffers(void *atlas_entries, void *instances, void *palettes, void *uniforms);
extern void gfx_set_sprite_staging(void *ptr, uint32_t size);
extern void gfx_set_sprite_output_size(uint32_t w, uint32_t h);

// ─── Command Types (must match ed_graphics.zig GfxCommandType) ──────────────

enum {
    GFX_CMD_CREATE_WINDOW      = 0,
    GFX_CMD_DESTROY_WINDOW     = 1,
    GFX_CMD_SET_TITLE          = 2,
    GFX_CMD_SET_SCREEN_MODE    = 3,
    GFX_CMD_FLIP               = 4,
    GFX_CMD_SET_SCROLL         = 5,
    GFX_CMD_INSTALL_EFFECT     = 6,
    GFX_CMD_STOP_EFFECT        = 7,
    GFX_CMD_STOP_ALL_EFFECTS   = 8,
    GFX_CMD_PAUSE_EFFECT       = 9,
    GFX_CMD_RESUME_EFFECT      = 10,
    GFX_CMD_COLLISION_DISPATCH = 11,
    GFX_CMD_COLLISION_SINGLE   = 12,
    GFX_CMD_COMMIT_FENCE       = 13,
    GFX_CMD_WAIT_GPU           = 14,
    GFX_CMD_SPRITE_UPLOAD      = 15,
    GFX_CMD_MENU_RESET         = 16,
    GFX_CMD_MENU_DEFINE        = 17,
    GFX_CMD_MENU_ADD_ITEM      = 18,
    GFX_CMD_MENU_ADD_SEPARATOR = 19,
    GFX_CMD_MENU_SET_CHECKED   = 20,
    GFX_CMD_MENU_SET_ENABLED   = 21,
    GFX_CMD_MENU_RENAME        = 22,
    GFX_CMD_SET_APP_NAME       = 23,
};

// ─── Payload Structures (must match ed_graphics.zig) ────────────────────────

#pragma pack(push, 1)

typedef struct {
    uint16_t width;
    uint16_t height;
    uint16_t scale_hint;
    uint16_t _pad;
} CreateWindowPayload;

typedef struct {
    int16_t scroll_x;
    int16_t scroll_y;
} SetScrollPayload;

typedef struct {
    uint32_t len;
    char data[52];
} SetTitlePayload;

// PaletteEffect — 48 bytes, must match ed_graphics.zig PaletteEffect
typedef struct {
    uint32_t effect_type;
    uint32_t flags;
    uint32_t index_start;
    uint32_t index_end;
    uint32_t line_start;
    uint32_t line_end;
    float    speed;
    float    phase;
    uint8_t  colour_a[4];
    uint8_t  colour_b[4];
    int32_t  direction;
    uint32_t _pad;
} PaletteEffect;

typedef struct {
    uint8_t slot;
    uint8_t _pad[3];
    PaletteEffect effect;
} InstallEffectPayload;

typedef struct {
    uint8_t buf_a;
    uint8_t buf_b;
    uint8_t _pad[2];
    int16_t ax, ay;
    int16_t bx, by;
    uint16_t w, h;
} CollisionSinglePayload;

typedef struct {
    uint8_t menu_id;
    uint8_t title_len;
    uint8_t title[30];
} MenuDefinePayload;

typedef struct {
    uint8_t menu_id;
    uint8_t _pad0;
    uint16_t item_id;
    uint8_t label_len;
    uint8_t shortcut_len;
    uint16_t flags;
    uint8_t label[24];
    uint8_t shortcut[8];
} MenuItemPayload;

typedef struct {
    uint16_t item_id;
    uint8_t state;
    uint8_t _pad0;
} MenuStatePayload;

typedef struct {
    uint16_t item_id;
    uint8_t label_len;
    uint8_t _pad0;
    uint8_t label[30];
} MenuRenamePayload;

typedef struct {
    uint16_t atlas_x;
    uint16_t atlas_y;
    uint16_t width;
    uint16_t height;
    uint64_t pixel_ptr;  // malloc'd pixel snapshot made on JIT thread at SPRITE END
} SpriteUploadPayload;

// SpriteUniformsGPU — must match sprite.zig SpriteUniformsGPU
typedef struct {
    uint32_t num_instances;
    uint32_t atlas_width;
    uint32_t atlas_height;
    uint32_t output_width;
    uint32_t output_height;
    uint32_t frame_counter;
    uint32_t _pad[2];
} SpriteUniformsGPU;

#pragma pack(pop)

// ─── GfxUniforms (must match graphics.metal) ────────────────────────────────

typedef struct {
    uint32_t visible_width;
    uint32_t visible_height;
    uint32_t buffer_width;
    uint32_t buffer_height;
    int32_t  scroll_x;
    int32_t  scroll_y;
    uint32_t frame_counter;
    uint32_t front_buffer;
} GfxUniforms;

// ─── DisplayUniforms (must match graphics.metal) ────────────────────────────

typedef struct {
    float viewport_size[2];
    float texture_size[2];
    float par_numerator;
    float par_denominator;
    float _pad[2];
} DisplayUniforms;

// ─── CollisionParams (must match graphics.metal) ────────────────────────────

typedef struct {
    uint32_t buf_a_offset;
    uint32_t buf_b_offset;
    uint32_t buf_stride;
    int32_t  ax, ay;
    int32_t  bx, by;
    uint32_t width, height;
    uint32_t flags_index;
} CollisionParams;

// ─── Constants ──────────────────────────────────────────────────────────────

#define NUM_BUFFERS            8
#define MAX_PALETTE_EFFECTS   32
#define LINE_PAL_ENTRIES      16
#define GLOBAL_PAL_ENTRIES   240
#define MAX_COLLISION_FLAGS  2048
#define PALETTE_EFFECT_SIZE    48  // sizeof(PaletteEffect)

// Sprite system constants
#define SPRITE_ATLAS_SIZE     2048
#define SPRITE_MAX_DEFINITIONS 1024
#define SPRITE_MAX_INSTANCES   512
#define SPRITE_MAX_PALETTES   1024
#define SPRITE_ATLAS_ENTRY_SIZE  32
#define SPRITE_INSTANCE_SIZE     80
#define SPRITE_PALETTE_SIZE      64   // 16 * 4 bytes (RGBA32)
#define SPRITE_STAGING_SIZE  (256 * 256)  // max single sprite pixels

// ─── Forward Declarations ───────────────────────────────────────────────────

@class GraphicsWindowController;
@class GraphicsMetalRenderer;
@class GraphicsControllerManager;

// ─── Forward-declared helpers (defined after GraphicsWindowController) ───────
// Used by gfx_create_window_sync / gfx_destroy_window_sync.  Defined after
// GraphicsWindowController so the full class interface is visible.
static void gfx_handle_create_window(uint16_t w, uint16_t h, uint16_t scale);
static void gfx_handle_destroy_window(void);

// ─── Globals ────────────────────────────────────────────────────────────────

static GraphicsWindowController *g_gfx_window_controller = nil;
static GraphicsMetalRenderer    *g_gfx_renderer = nil;
static GraphicsControllerManager *g_gfx_controller_manager = nil;
static NSWindow                 *g_gfx_window = nil;
static MTKView                  *g_gfx_mtk_view = nil;

static id<MTLDevice>             g_gfx_device = nil;
static id<MTLCommandQueue>       g_gfx_command_queue = nil;

// Shared MTLBuffers (MTLStorageModeShared — CPU + GPU access)
static id<MTLBuffer>             g_pixel_buffers[NUM_BUFFERS];
static id<MTLBuffer>             g_line_palette_buffer = nil;
static id<MTLBuffer>             g_global_palette_buffer = nil;
static id<MTLBuffer>             g_palette_effects_buffer = nil;
static id<MTLBuffer>             g_collision_flags_buffer = nil;
static id<MTLBuffer>             g_uniforms_buffer = nil;

// Private GPU-only buffers (working palettes)
static id<MTLBuffer>             g_line_pal_work = nil;
static id<MTLBuffer>             g_global_pal_work = nil;

// Output texture (Private, GPU-only)
static id<MTLTexture>            g_output_texture = nil;

// Sprite system buffers
static id<MTLTexture>            g_sprite_atlas = nil;           // R8Uint, 2048×2048, Private
static id<MTLBuffer>             g_sprite_staging = nil;         // Shared, pixel upload staging
static id<MTLBuffer>             g_sprite_atlas_entries = nil;   // Shared, 1024 × 32 bytes
static id<MTLBuffer>             g_sprite_instances = nil;       // Shared, 512 × 80 bytes
static id<MTLBuffer>             g_sprite_palettes = nil;        // Shared, 1024 × 64 bytes
static id<MTLBuffer>             g_sprite_uniforms = nil;        // Shared, 32 bytes

// Pending sprite atlas uploads (deferred from command drain to GPU encoding phase)
#define MAX_PENDING_SPRITE_UPLOADS 64
typedef struct {
    SpriteUploadPayload payload;
    uint8_t *pixels;        // malloc'd snapshot of staging buffer at SPRITE END time
} PendingSpriteUpload;
static PendingSpriteUpload g_pending_sprite_uploads[MAX_PENDING_SPRITE_UPLOADS];
static uint32_t g_pending_sprite_upload_count = 0;

// Pipeline states
static id<MTLComputePipelineState>  g_palette_animate_pipeline = nil;
static id<MTLComputePipelineState>  g_palette_lookup_pipeline = nil;
static id<MTLComputePipelineState>  g_collision_pipeline = nil;
static id<MTLComputePipelineState>  g_sprite_render_pipeline = nil;
static id<MTLRenderPipelineState>   g_display_pipeline = nil;
static id<MTLSamplerState>          g_nearest_sampler = nil;

// State
static uint32_t g_frame_counter = 0;
static _Atomic uint32_t g_front_buffer = 0;
static _Atomic int32_t  g_scroll_x = 0;
static _Atomic int32_t  g_scroll_y = 0;
static uint32_t g_last_submitted_fence = 0;
static bool     g_pending_gpu_wait = false;
static bool     g_pending_collision = false;
static bool     g_gfx_active = false;
static NSString *g_app_name = @"Ed";

// Set to true when destroyWindow is called programmatically (e.g. during
// window recreation in createWindowWithWidth:).  Prevents windowShouldClose:
// from calling basic_jit_stop() which would send SIGALRM to the JIT thread
// that is currently blocked in dispatch_sync waiting for window creation to
// complete — killing the very program that requested the new window.
static bool     g_gfx_programmatic_close = false;

// Resolution
static uint16_t g_visible_w = 0;
static uint16_t g_visible_h = 0;
static uint16_t g_buf_w = 0;
static uint16_t g_buf_h = 0;
static uint16_t g_overscan_x = 0;
static uint16_t g_overscan_y = 0;

// Mouse button tracking
static uint8_t g_mouse_buttons = 0;

// Application/menu naming — allows the BASIC program to retitle the app
static void applyAppNameToMenus(NSString *name) {
    if (!name || name.length == 0) return;

    g_app_name = name;

    if ([[NSProcessInfo processInfo] respondsToSelector:@selector(setProcessName:)]) {
        [[NSProcessInfo processInfo] setProcessName:name];
    }

    NSMenu *mainMenu = [NSApp mainMenu];
    if (!mainMenu) return;

    NSMenuItem *appMenuItem = (mainMenu.numberOfItems > 0) ? [mainMenu itemAtIndex:0] : nil;
    NSMenu *appMenu = appMenuItem.submenu;

    if (appMenuItem) {
        [appMenuItem setTitle:name];
    }

    if (appMenu) {
        [appMenu setTitle:name];
        for (NSMenuItem *item in appMenu.itemArray) {
            SEL action = item.action;
            if (action == @selector(orderFrontStandardAboutPanel:)) {
                item.title = [NSString stringWithFormat:@"About %@", name];
            } else if (action == @selector(hide:)) {
                item.title = [NSString stringWithFormat:@"Hide %@", name];
            } else if (action == @selector(terminate:)) {
                item.title = [NSString stringWithFormat:@"Quit %@", name];
            }
        }
    }
}

NSString *ed_current_app_name(void) {
    return (g_app_name && g_app_name.length > 0) ? g_app_name : @"Ed";
}

void ed_set_application_name(NSString *name) {
    if (!name || name.length == 0) return;
    NSString *copy = [name copy];
    void (^apply)(void) = ^{
        applyAppNameToMenus(copy);
    };

    if ([NSThread isMainThread]) {
        apply();
    } else {
        dispatch_async(dispatch_get_main_queue(), apply);
    }
}

// ─── Dynamic program menu state ─────────────────────────────────────────

@interface GraphicsMenuActionTarget : NSObject
- (void)menuItemActivated:(id)sender;
@end

@implementation GraphicsMenuActionTarget
- (void)menuItemActivated:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    NSInteger tag = item.tag;
    if (tag > 0 && tag <= 65535) {
        gfx_menu_push_event((uint16_t)tag);
    }
}
@end

@interface GraphicsMenuManager : NSObject
- (void)reset;
- (void)defineMenu:(uint8_t)menuId title:(NSString *)title;
- (void)addItemToMenu:(uint8_t)menuId itemId:(uint16_t)itemId label:(NSString *)label shortcut:(NSString *)shortcut flags:(uint16_t)flags;
- (void)addSeparatorToMenu:(uint8_t)menuId;
- (void)setChecked:(uint16_t)itemId state:(BOOL)on;
- (void)setEnabled:(uint16_t)itemId state:(BOOL)on;
- (void)renameItem:(uint16_t)itemId label:(NSString *)label;
@end

@implementation GraphicsMenuManager {
    NSMutableDictionary<NSNumber *, NSMenu *> *_menusById;
    NSMutableDictionary<NSNumber *, NSMenuItem *> *_itemsById;
    NSMutableArray<NSMenuItem *> *_insertedRootItems;
    NSMenuItem *_containerItem;
    NSMenu *_containerSubmenu;
    GraphicsMenuActionTarget *_actionTarget;
}

static BOOL parseShortcutString(NSString *shortcut, NSString **outKey, NSEventModifierFlags *outMask) {
    if (!shortcut || shortcut.length == 0) {
        *outKey = @"";
        *outMask = 0;
        return YES;
    }

    NSArray<NSString *> *parts = [shortcut componentsSeparatedByString:@"+"];
    NSEventModifierFlags mask = 0;
    NSString *keyPart = nil;

    for (NSString *raw in parts) {
        NSString *part = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
        if (part.length == 0) continue;
        if ([part isEqualToString:@"CMD"] || [part isEqualToString:@"COMMAND"]) {
            mask |= NSEventModifierFlagCommand;
        } else if ([part isEqualToString:@"SHIFT"]) {
            mask |= NSEventModifierFlagShift;
        } else if ([part isEqualToString:@"ALT"] || [part isEqualToString:@"OPTION"]) {
            mask |= NSEventModifierFlagOption;
        } else if ([part isEqualToString:@"CTRL"] || [part isEqualToString:@"CONTROL"]) {
            mask |= NSEventModifierFlagControl;
        } else {
            keyPart = part;
        }
    }

    if (!keyPart || keyPart.length == 0) {
        *outKey = @"";
        *outMask = mask;
        return YES;
    }

    if (keyPart.length >= 2 && [keyPart hasPrefix:@"F"]) {
        NSInteger fn = [[keyPart substringFromIndex:1] integerValue];
        unichar fkey = 0;
        switch (fn) {
            case 1: fkey = NSF1FunctionKey; break;
            case 2: fkey = NSF2FunctionKey; break;
            case 3: fkey = NSF3FunctionKey; break;
            case 4: fkey = NSF4FunctionKey; break;
            case 5: fkey = NSF5FunctionKey; break;
            case 6: fkey = NSF6FunctionKey; break;
            case 7: fkey = NSF7FunctionKey; break;
            case 8: fkey = NSF8FunctionKey; break;
            case 9: fkey = NSF9FunctionKey; break;
            case 10: fkey = NSF10FunctionKey; break;
            case 11: fkey = NSF11FunctionKey; break;
            case 12: fkey = NSF12FunctionKey; break;
            default: fkey = 0; break;
        }
        if (fkey != 0) {
            *outKey = [NSString stringWithCharacters:&fkey length:1];
            *outMask = mask;
            return YES;
        }
    }

    *outKey = [keyPart lowercaseString];
    *outMask = mask;
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _menusById = [NSMutableDictionary dictionary];
    _itemsById = [NSMutableDictionary dictionary];
    _insertedRootItems = [NSMutableArray array];
    _actionTarget = [[GraphicsMenuActionTarget alloc] init];
    return self;
}

- (NSMenu *)rootProgramMenu {
    NSMenu *main = [NSApp mainMenu];
    if (!main) return nil;

    NSMenu *graphicsSub = nil;
    for (NSMenuItem *it in main.itemArray) {
        if ([[it.title uppercaseString] isEqualToString:@"GRAPHICS"]) {
            graphicsSub = it.submenu;
            break;
        }
    }

    if (graphicsSub) {
        if (!_containerItem || !_containerSubmenu || _containerItem.menu != graphicsSub) {
            [self reset];
            _containerItem = [[NSMenuItem alloc] initWithTitle:@"Program Menu" action:nil keyEquivalent:@""];
            _containerSubmenu = [[NSMenu alloc] initWithTitle:@"Program Menu"];
            [_containerItem setSubmenu:_containerSubmenu];
            [graphicsSub addItem:_containerItem];
            [_insertedRootItems addObject:_containerItem];
        }
        return _containerSubmenu;
    }

    return [NSApp mainMenu];
}

- (void)reset {
    for (NSMenuItem *item in _insertedRootItems) {
        NSMenu *parent = item.menu;
        if (parent) {
            [parent removeItem:item];
        }
    }
    [_insertedRootItems removeAllObjects];
    [_menusById removeAllObjects];
    [_itemsById removeAllObjects];
    _containerItem = nil;
    _containerSubmenu = nil;
    gfx_menu_clear_events();
}

- (void)defineMenu:(uint8_t)menuId title:(NSString *)title {
    NSMenu *root = [self rootProgramMenu];
    if (!root) return;

    NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:(title ?: @"Menu") action:nil keyEquivalent:@""];
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:(title ?: @"Menu")];
    [menuItem setSubmenu:submenu];
    [root addItem:menuItem];
    [_menusById setObject:submenu forKey:@(menuId)];

    if (root == [NSApp mainMenu]) {
        [_insertedRootItems addObject:menuItem];
    }
}

- (void)addItemToMenu:(uint8_t)menuId itemId:(uint16_t)itemId label:(NSString *)label shortcut:(NSString *)shortcut flags:(uint16_t)flags {
    NSMenu *menu = _menusById[@(menuId)];
    if (!menu) return;

    NSString *key = @"";
    NSEventModifierFlags mask = 0;
    parseShortcutString(shortcut ?: @"", &key, &mask);

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:(label ?: @"Item") action:@selector(menuItemActivated:) keyEquivalent:key ?: @""];
    item.target = _actionTarget;
    item.tag = itemId;
    [item setKeyEquivalentModifierMask:mask];
    item.state = (flags & 1) ? NSControlStateValueOn : NSControlStateValueOff;
    item.enabled = (flags & 2) ? NO : YES;
    [menu addItem:item];
    _itemsById[@(itemId)] = item;
}

- (void)addSeparatorToMenu:(uint8_t)menuId {
    NSMenu *menu = _menusById[@(menuId)];
    if (!menu) return;
    [menu addItem:[NSMenuItem separatorItem]];
}

- (void)setChecked:(uint16_t)itemId state:(BOOL)on {
    NSMenuItem *item = _itemsById[@(itemId)];
    if (!item) return;
    item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setEnabled:(uint16_t)itemId state:(BOOL)on {
    NSMenuItem *item = _itemsById[@(itemId)];
    if (!item) return;
    item.enabled = on;
}

- (void)renameItem:(uint16_t)itemId label:(NSString *)label {
    NSMenuItem *item = _itemsById[@(itemId)];
    if (!item) return;
    item.title = label ?: @"";
}

@end

static GraphicsMenuManager *g_menu_manager = nil;

// ─── Dynamic program dialog state ───────────────────────────────────────

@interface GraphicsDialogActionTarget : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSTextField *> *fileFields;
- (void)dialogButtonActivated:(id)sender;
- (void)browseFile:(id)sender;
@end

@implementation GraphicsDialogActionTarget
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _fileFields = [NSMutableDictionary dictionary];
    return self;
}

- (void)dialogButtonActivated:(id)sender {
    NSButton *button = (NSButton *)sender;
    NSInteger tag = button.tag;
    NSWindow *window = button.window;
    if (!window) {
        [NSApp stopModalWithCode:tag > 0 ? tag : NSModalResponseOK];
        return;
    }
    [NSApp stopModalWithCode:tag > 0 ? tag : NSModalResponseOK];
    [window orderOut:nil];
}

- (void)browseFile:(id)sender {
    NSButton *button = (NSButton *)sender;
    NSNumber *cid = @(button.tag);
    NSTextField *field = self.fileFields[cid];
    if (!field) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;

    NSModalResponse res = [panel runModal];
    if (res == NSModalResponseOK) {
        NSURL *url = panel.URL;
        if (url.path) {
            field.stringValue = url.path;
        }
    }
}
@end

@interface GraphicsDialogManager : NSObject
- (void)reset;
- (void)beginDialog:(uint16_t)dialogId;
- (void)setTitle:(NSString *)title;
- (void)setMessage:(NSString *)message;
- (void)addLabel:(NSString *)text;
- (void)addTextField:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue;
- (void)addSecureField:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue;
- (void)addTextArea:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue;
- (void)addNumberField:(uint16_t)controlId label:(NSString *)label defaultValue:(double)defaultValue minValue:(double)minValue maxValue:(double)maxValue step:(double)step;
- (void)addSlider:(uint16_t)controlId label:(NSString *)label minValue:(double)minValue maxValue:(double)maxValue defaultValue:(double)defaultValue;
- (void)addFilePicker:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue;
- (void)addCheckbox:(uint16_t)controlId label:(NSString *)label checked:(BOOL)checked;
- (void)addRadio:(uint16_t)controlId groupId:(uint16_t)groupId label:(NSString *)label selected:(BOOL)selected;
- (void)addDropdown:(uint16_t)controlId label:(NSString *)label options:(NSString *)options defaultIndex:(NSInteger)defaultIndex;
- (void)addButton:(uint16_t)controlId label:(NSString *)label flags:(uint8_t)flags;
- (void)endDialog;
- (uint16_t)showDialog:(uint16_t)dialogId;
- (NSString *)textForControl:(uint16_t)controlId;
- (BOOL)checkedForControl:(uint16_t)controlId;
- (NSInteger)selectionForControl:(uint16_t)controlId;
- (void)setTextForControl:(uint16_t)controlId value:(NSString *)value;
- (void)setNumberForControl:(uint16_t)controlId value:(double)value;
- (void)setCheckedForControl:(uint16_t)controlId state:(BOOL)on;
- (void)setSelectionForControl:(uint16_t)controlId index:(NSInteger)index;
@end

@implementation GraphicsDialogManager {
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_dialogsById;
    uint16_t _currentDialogId;

    NSMutableDictionary<NSNumber *, NSString *> *_lastTextValues;
    NSMutableDictionary<NSNumber *, NSNumber *> *_lastCheckedValues;
    NSMutableDictionary<NSNumber *, NSNumber *> *_lastSelectionValues;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _dialogsById = [NSMutableDictionary dictionary];
    _lastTextValues = [NSMutableDictionary dictionary];
    _lastCheckedValues = [NSMutableDictionary dictionary];
    _lastSelectionValues = [NSMutableDictionary dictionary];
    _currentDialogId = 0;
    return self;
}

- (void)reset {
    [_dialogsById removeAllObjects];
    [_lastTextValues removeAllObjects];
    [_lastCheckedValues removeAllObjects];
    [_lastSelectionValues removeAllObjects];
    _currentDialogId = 0;
}

- (NSMutableDictionary *)ensureCurrentDialog {
    NSNumber *key = @(_currentDialogId);
    NSMutableDictionary *dialog = _dialogsById[key];
    if (!dialog) {
        dialog = [@{
            @"title": @"Dialog",
            @"message": @"",
            @"controls": [NSMutableArray array]
        } mutableCopy];
        _dialogsById[key] = dialog;
    }
    return dialog;
}

- (void)beginDialog:(uint16_t)dialogId {
    _currentDialogId = dialogId;
    NSMutableDictionary *dialog = [@{
        @"title": @"Dialog",
        @"message": @"",
        @"controls": [NSMutableArray array]
    } mutableCopy];
    _dialogsById[@(dialogId)] = dialog;
}

- (void)setTitle:(NSString *)title {
    [self ensureCurrentDialog][@"title"] = title ?: @"Dialog";
}

- (void)setMessage:(NSString *)message {
    [self ensureCurrentDialog][@"message"] = message ?: @"";
}

- (void)addControl:(NSDictionary *)control {
    NSMutableArray *controls = [self ensureCurrentDialog][@"controls"];
    [controls addObject:control];
}

- (void)addLabel:(NSString *)text {
    [self addControl:@{ @"type": @"label", @"text": text ?: @"" }];
}

- (void)addTextField:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue {
    [self addControl:@{
        @"type": @"textfield",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"default": defaultValue ?: @""
    }];
}

- (void)addSecureField:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue {
    [self addControl:@{
        @"type": @"securefield",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"default": defaultValue ?: @""
    }];
}

- (void)addTextArea:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue {
    [self addControl:@{
        @"type": @"textarea",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"default": defaultValue ?: @""
    }];
}

- (void)addNumberField:(uint16_t)controlId label:(NSString *)label defaultValue:(double)defaultValue minValue:(double)minValue maxValue:(double)maxValue step:(double)step {
    [self addControl:@{
        @"type": @"numberfield",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"default": @(defaultValue),
        @"min": @(minValue),
        @"max": @(maxValue),
        @"step": @(step)
    }];
}

- (void)addSlider:(uint16_t)controlId label:(NSString *)label minValue:(double)minValue maxValue:(double)maxValue defaultValue:(double)defaultValue {
    [self addControl:@{
        @"type": @"slider",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"min": @(minValue),
        @"max": @(maxValue),
        @"default": @(defaultValue)
    }];
}

- (void)addFilePicker:(uint16_t)controlId label:(NSString *)label defaultValue:(NSString *)defaultValue {
    [self addControl:@{
        @"type": @"filepicker",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"default": defaultValue ?: @""
    }];
}

- (void)addCheckbox:(uint16_t)controlId label:(NSString *)label checked:(BOOL)checked {
    [self addControl:@{
        @"type": @"checkbox",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"checked": @(checked)
    }];
}

- (void)addRadio:(uint16_t)controlId groupId:(uint16_t)groupId label:(NSString *)label selected:(BOOL)selected {
    [self addControl:@{
        @"type": @"radio",
        @"id": @(controlId),
        @"group": @(groupId),
        @"label": label ?: @"",
        @"selected": @(selected)
    }];
}

- (void)addDropdown:(uint16_t)controlId label:(NSString *)label options:(NSString *)options defaultIndex:(NSInteger)defaultIndex {
    [self addControl:@{
        @"type": @"dropdown",
        @"id": @(controlId),
        @"label": label ?: @"",
        @"options": options ?: @"",
        @"defaultIndex": @(defaultIndex)
    }];
}

- (void)addButton:(uint16_t)controlId label:(NSString *)label flags:(uint8_t)flags {
    [self addControl:@{
        @"type": @"button",
        @"id": @(controlId),
        @"label": label ?: @"Button",
        @"flags": @(flags)
    }];
}

- (void)endDialog {
    // No-op currently; reserved for validation/finalization.
}

- (uint16_t)showDialog:(uint16_t)dialogId {
    NSMutableDictionary *dialog = _dialogsById[@(dialogId)];
    if (!dialog) return 0;
    const CGFloat panelWidth = 560.0;

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, panelWidth, 420)
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    panel.title = dialog[@"title"] ?: @"Dialog";
    [panel setReleasedWhenClosed:NO];

    NSView *content = panel.contentView;
    if (!content) return 0;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 10)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];

    NSMutableDictionary<NSNumber *, id> *textInputs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSButton *> *checkboxInputs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSButton *> *radioInputs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSPopUpButton *> *dropdownInputs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSSlider *> *sliderInputs = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *buttonDefs = [NSMutableArray array];
    GraphicsDialogActionTarget *actionTarget = [[GraphicsDialogActionTarget alloc] init];
    __block NSView *firstEditable = nil;

    NSString *message = dialog[@"message"] ?: @"";
    if (message.length > 0) {
        NSTextField *msg = [NSTextField wrappingLabelWithString:message];
        msg.translatesAutoresizingMaskIntoConstraints = NO;
        [msg.widthAnchor constraintEqualToConstant:panelWidth - 32].active = YES;
        [stack addArrangedSubview:msg];
    }

    NSArray *controls = dialog[@"controls"] ?: @[];
    for (NSDictionary *ctrl in controls) {
        NSString *type = ctrl[@"type"];

        if ([type isEqualToString:@"button"]) {
            [buttonDefs addObject:ctrl];
            continue;
        }

        if ([type isEqualToString:@"label"]) {
            NSTextField *label = [NSTextField wrappingLabelWithString:(ctrl[@"text"] ?: @"")];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [label.widthAnchor constraintEqualToConstant:panelWidth - 32].active = YES;
            [stack addArrangedSubview:label];
            continue;
        }

        if ([type isEqualToString:@"textfield"] || [type isEqualToString:@"securefield"] || [type isEqualToString:@"numberfield"] || [type isEqualToString:@"filepicker"]) {
            NSStackView *row = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 24)];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.spacing = 8.0;

            NSTextField *lbl = [NSTextField labelWithString:(ctrl[@"label"] ?: @"")];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            [lbl.widthAnchor constraintEqualToConstant:180.0].active = YES;
            [row addArrangedSubview:lbl];

            NSTextField *field = nil;
            if ([type isEqualToString:@"securefield"]) {
                field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
                field.stringValue = ctrl[@"default"] ?: @"";
            } else if ([type isEqualToString:@"numberfield"]) {
                field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
                field.formatter = [[NSNumberFormatter alloc] init];
                double dv = [ctrl[@"default"] doubleValue];
                field.stringValue = [NSString stringWithFormat:@"%g", dv];
            } else {
                field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
                field.stringValue = ctrl[@"default"] ?: @"";
            }
            field.translatesAutoresizingMaskIntoConstraints = NO;
            [field.widthAnchor constraintGreaterThanOrEqualToConstant:300.0].active = YES;
            [row addArrangedSubview:field];

            if ([type isEqualToString:@"filepicker"]) {
                NSButton *browse = [NSButton buttonWithTitle:@"Browse…" target:actionTarget action:@selector(browseFile:)];
                browse.tag = [ctrl[@"id"] intValue];
                [row addArrangedSubview:browse];
                actionTarget.fileFields[ctrl[@"id"] ?: @0] = field;
            }

            [stack addArrangedSubview:row];
            textInputs[ctrl[@"id"] ?: @0] = field;
            if (!firstEditable) firstEditable = field;
            continue;
        }

        if ([type isEqualToString:@"textarea"]) {
            NSTextField *lbl = [NSTextField labelWithString:(ctrl[@"label"] ?: @"")];
            [stack addArrangedSubview:lbl];

            NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 100)];
            scroll.hasVerticalScroller = YES;
            scroll.borderType = NSBezelBorder;
            scroll.translatesAutoresizingMaskIntoConstraints = NO;
            [scroll.widthAnchor constraintEqualToConstant:panelWidth - 32].active = YES;
            [scroll.heightAnchor constraintEqualToConstant:100.0].active = YES;

            NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 100)];
            textView.string = ctrl[@"default"] ?: @"";
            scroll.documentView = textView;
            [stack addArrangedSubview:scroll];

            textInputs[ctrl[@"id"] ?: @0] = textView;
            if (!firstEditable) firstEditable = textView;
            continue;
        }

        if ([type isEqualToString:@"slider"]) {
            NSStackView *row = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 24)];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.spacing = 8.0;

            NSTextField *lbl = [NSTextField labelWithString:(ctrl[@"label"] ?: @"")];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            [lbl.widthAnchor constraintEqualToConstant:180.0].active = YES;
            [row addArrangedSubview:lbl];

            NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            slider.minValue = [ctrl[@"min"] doubleValue];
            slider.maxValue = [ctrl[@"max"] doubleValue];
            slider.doubleValue = [ctrl[@"default"] doubleValue];
            slider.translatesAutoresizingMaskIntoConstraints = NO;
            [slider.widthAnchor constraintGreaterThanOrEqualToConstant:300.0].active = YES;
            [row addArrangedSubview:slider];

            [stack addArrangedSubview:row];
            sliderInputs[ctrl[@"id"] ?: @0] = slider;
            continue;
        }

        if ([type isEqualToString:@"checkbox"]) {
            NSButton *cb = [NSButton checkboxWithTitle:(ctrl[@"label"] ?: @"") target:nil action:nil];
            cb.state = [ctrl[@"checked"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            [stack addArrangedSubview:cb];
            checkboxInputs[ctrl[@"id"] ?: @0] = cb;
            continue;
        }

        if ([type isEqualToString:@"radio"]) {
            NSButton *rb = [NSButton radioButtonWithTitle:(ctrl[@"label"] ?: @"") target:nil action:nil];
            rb.state = [ctrl[@"selected"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            [stack addArrangedSubview:rb];
            radioInputs[ctrl[@"id"] ?: @0] = rb;
            continue;
        }

        if ([type isEqualToString:@"dropdown"]) {
            NSStackView *row = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 24)];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.spacing = 8.0;

            NSTextField *lbl = [NSTextField labelWithString:(ctrl[@"label"] ?: @"")];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            [lbl.widthAnchor constraintEqualToConstant:180.0].active = YES;
            [row addArrangedSubview:lbl];

            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 24) pullsDown:NO];
            NSString *options = ctrl[@"options"] ?: @"";
            NSArray<NSString *> *items = [options componentsSeparatedByString:@"|"];
            for (NSString *item in items) {
                NSString *trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length > 0) [popup addItemWithTitle:trimmed];
            }
            NSInteger defIdx = [ctrl[@"defaultIndex"] integerValue];
            if (defIdx >= 0 && defIdx < (NSInteger)popup.numberOfItems) {
                [popup selectItemAtIndex:defIdx];
            }
            popup.translatesAutoresizingMaskIntoConstraints = NO;
            [popup.widthAnchor constraintGreaterThanOrEqualToConstant:300.0].active = YES;
            [row addArrangedSubview:popup];

            [stack addArrangedSubview:row];
            dropdownInputs[ctrl[@"id"] ?: @0] = popup;
            continue;
        }
    }

    if (buttonDefs.count == 0) {
        [buttonDefs addObject:@{ @"id": @1, @"label": @"OK", @"flags": @1 }];
    }

    NSStackView *buttonRow = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth - 32, 30)];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.alignment = NSLayoutAttributeCenterY;
    buttonRow.spacing = 8.0;

    NSView *spacer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.widthAnchor constraintGreaterThanOrEqualToConstant:1.0].active = YES;
    [buttonRow addArrangedSubview:spacer];

    for (NSDictionary *btn in buttonDefs) {
        NSButton *b = [NSButton buttonWithTitle:(btn[@"label"] ?: @"OK") target:actionTarget action:@selector(dialogButtonActivated:)];
        b.tag = (NSInteger)[btn[@"id"] unsignedIntValue];
        uint8_t flags = (uint8_t)[btn[@"flags"] unsignedIntValue];
        if (flags & 1) b.keyEquivalent = @"\r";
        if (flags & 2) b.keyEquivalent = @"\e";
        [buttonRow addArrangedSubview:b];
    }

    [stack addArrangedSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16.0],
    ]];

    [content layoutSubtreeIfNeeded];
    NSRect fitting = [content fittingSize].width > 0 ? NSMakeRect(0, 0, panelWidth, [content fittingSize].height + 32.0) : NSMakeRect(0, 0, panelWidth, 360.0);
    [panel setContentSize:fitting.size];
    [panel center];

    if (firstEditable) {
        [panel setInitialFirstResponder:firstEditable];
        [panel makeFirstResponder:firstEditable];
    }

    __block id closeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:panel
                     queue:nil
                usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        [NSApp stopModalWithCode:0];
    }];

    NSModalResponse response = [NSApp runModalForWindow:panel];
    if (closeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    }
    uint16_t clicked_id = 0;
    if (response > 0 && response <= 65535) {
        clicked_id = (uint16_t)response;
    }
    [panel orderOut:nil];

    [_lastTextValues removeAllObjects];
    [_lastCheckedValues removeAllObjects];
    [_lastSelectionValues removeAllObjects];

    [textInputs enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, id view, BOOL *stop) {
        (void)stop;
        if ([view isKindOfClass:[NSTextField class]]) {
            _lastTextValues[key] = [(NSTextField *)view stringValue] ?: @"";
        } else if ([view isKindOfClass:[NSTextView class]]) {
            _lastTextValues[key] = [(NSTextView *)view string] ?: @"";
        }
    }];

    [checkboxInputs enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSButton *view, BOOL *stop) {
        (void)stop;
        _lastCheckedValues[key] = @(view.state == NSControlStateValueOn);
    }];

    [radioInputs enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSButton *view, BOOL *stop) {
        (void)stop;
        _lastCheckedValues[key] = @(view.state == NSControlStateValueOn);
    }];

    [dropdownInputs enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSPopUpButton *popup, BOOL *stop) {
        (void)stop;
        _lastSelectionValues[key] = @((NSInteger)popup.indexOfSelectedItem);
    }];

    [sliderInputs enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSSlider *slider, BOOL *stop) {
        (void)stop;
        _lastSelectionValues[key] = @((NSInteger)slider.doubleValue);
        _lastTextValues[key] = [NSString stringWithFormat:@"%g", slider.doubleValue];
    }];

    if (clicked_id != 0) return clicked_id;
    return 0;
}

- (NSString *)textForControl:(uint16_t)controlId {
    return _lastTextValues[@(controlId)] ?: @"";
}

- (BOOL)checkedForControl:(uint16_t)controlId {
    return [_lastCheckedValues[@(controlId)] boolValue];
}

- (NSInteger)selectionForControl:(uint16_t)controlId {
    NSNumber *v = _lastSelectionValues[@(controlId)];
    return v ? v.integerValue : 0;
}

- (void)forEachControlById:(uint16_t)controlId apply:(void (^)(NSMutableDictionary *ctrl))block {
    if (!block) return;
    NSNumber *target = @(controlId);
    for (NSNumber *key in _dialogsById) {
        NSMutableDictionary *dialog = _dialogsById[key];
        NSMutableArray *controls = dialog[@"controls"];
        for (id item in controls) {
            if (![item isKindOfClass:[NSMutableDictionary class]]) continue;
            NSMutableDictionary *ctrl = (NSMutableDictionary *)item;
            NSNumber *cid = ctrl[@"id"];
            if (cid && [cid isEqualToNumber:target]) {
                block(ctrl);
            }
        }
    }
}

- (void)setTextForControl:(uint16_t)controlId value:(NSString *)value {
    NSString *val = value ?: @"";
    [self forEachControlById:controlId apply:^(NSMutableDictionary *ctrl) {
        NSString *type = ctrl[@"type"] ?: @"";
        if ([type isEqualToString:@"textfield"] || [type isEqualToString:@"securefield"] || [type isEqualToString:@"textarea"] || [type isEqualToString:@"filepicker"]) {
            ctrl[@"default"] = val;
        } else if ([type isEqualToString:@"numberfield"]) {
            ctrl[@"default"] = @([val doubleValue]);
        }
    }];
    _lastTextValues[@(controlId)] = val;
}

- (void)setNumberForControl:(uint16_t)controlId value:(double)value {
    [self forEachControlById:controlId apply:^(NSMutableDictionary *ctrl) {
        NSString *type = ctrl[@"type"] ?: @"";
        if ([type isEqualToString:@"numberfield"] || [type isEqualToString:@"slider"]) {
            ctrl[@"default"] = @(value);
        } else if ([type isEqualToString:@"textfield"] || [type isEqualToString:@"securefield"] || [type isEqualToString:@"textarea"]) {
            ctrl[@"default"] = [NSString stringWithFormat:@"%g", value];
        }
    }];
    _lastTextValues[@(controlId)] = [NSString stringWithFormat:@"%g", value];
}

- (void)setCheckedForControl:(uint16_t)controlId state:(BOOL)on {
    [self forEachControlById:controlId apply:^(NSMutableDictionary *ctrl) {
        NSString *type = ctrl[@"type"] ?: @"";
        if ([type isEqualToString:@"checkbox"]) {
            ctrl[@"checked"] = @(on);
        } else if ([type isEqualToString:@"radio"]) {
            ctrl[@"selected"] = @(on);
        }
    }];
    _lastCheckedValues[@(controlId)] = @(on);
}

- (void)setSelectionForControl:(uint16_t)controlId index:(NSInteger)index {
    [self forEachControlById:controlId apply:^(NSMutableDictionary *ctrl) {
        NSString *type = ctrl[@"type"] ?: @"";
        if ([type isEqualToString:@"dropdown"]) {
            ctrl[@"defaultIndex"] = @(index);
        } else if ([type isEqualToString:@"slider"]) {
            ctrl[@"default"] = @((double)index);
        }
    }];
    _lastSelectionValues[@(controlId)] = @(index);
}

@end

static GraphicsDialogManager *g_dialog_manager = nil;

static NSString *gfx_string_from_bytes(const uint8_t *ptr, uint32_t len) {
    if (!ptr || len == 0) return @"";
    NSString *s = [[NSString alloc] initWithBytes:ptr length:len encoding:NSUTF8StringEncoding];
    return s ?: @"";
}

void gfx_dialog_reset_bridge(void) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager reset];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_begin_bridge(uint16_t dialog_id) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager beginDialog:dialog_id];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_set_title_bridge(const uint8_t *ptr, uint32_t len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setTitle:gfx_string_from_bytes(ptr, len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_set_message_bridge(const uint8_t *ptr, uint32_t len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setMessage:gfx_string_from_bytes(ptr, len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_label_bridge(const uint8_t *ptr, uint32_t len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addLabel:gfx_string_from_bytes(ptr, len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_textfield_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, const uint8_t *default_ptr, uint32_t default_len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addTextField:control_id label:gfx_string_from_bytes(label_ptr, label_len) defaultValue:gfx_string_from_bytes(default_ptr, default_len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_securefield_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, const uint8_t *default_ptr, uint32_t default_len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addSecureField:control_id label:gfx_string_from_bytes(label_ptr, label_len) defaultValue:gfx_string_from_bytes(default_ptr, default_len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_textarea_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, const uint8_t *default_ptr, uint32_t default_len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addTextArea:control_id label:gfx_string_from_bytes(label_ptr, label_len) defaultValue:gfx_string_from_bytes(default_ptr, default_len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_numberfield_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, double default_value, double min_value, double max_value, double step) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addNumberField:control_id
                                   label:gfx_string_from_bytes(label_ptr, label_len)
                            defaultValue:default_value
                                minValue:min_value
                                maxValue:max_value
                                    step:step];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_slider_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, double min_value, double max_value, double default_value) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addSlider:control_id
                              label:gfx_string_from_bytes(label_ptr, label_len)
                           minValue:min_value
                           maxValue:max_value
                       defaultValue:default_value];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_filepicker_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, const uint8_t *default_ptr, uint32_t default_len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addFilePicker:control_id
                                  label:gfx_string_from_bytes(label_ptr, label_len)
                           defaultValue:gfx_string_from_bytes(default_ptr, default_len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_checkbox_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, uint8_t checked) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addCheckbox:control_id label:gfx_string_from_bytes(label_ptr, label_len) checked:(checked != 0)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_radio_bridge(uint16_t control_id, uint16_t group_id, const uint8_t *label_ptr, uint32_t label_len, uint8_t selected) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addRadio:control_id groupId:group_id label:gfx_string_from_bytes(label_ptr, label_len) selected:(selected != 0)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_dropdown_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, const uint8_t *options_ptr, uint32_t options_len, int32_t default_index) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addDropdown:control_id label:gfx_string_from_bytes(label_ptr, label_len) options:gfx_string_from_bytes(options_ptr, options_len) defaultIndex:default_index];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_add_button_bridge(uint16_t control_id, const uint8_t *label_ptr, uint32_t label_len, uint8_t flags) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager addButton:control_id label:gfx_string_from_bytes(label_ptr, label_len) flags:flags];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_end_bridge(void) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager endDialog];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

uint16_t gfx_dialog_show_bridge(uint16_t dialog_id) {
    __block uint16_t result = 0;
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        result = [g_dialog_manager showDialog:dialog_id];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}

const char *gfx_dialog_get_text_bridge(uint16_t control_id) {
    static char s_dialog_text_buf[4096];
    __block NSString *text = @"";
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        text = [g_dialog_manager textForControl:control_id] ?: @"";
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);

    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    size_t n = d.length;
    if (n > sizeof(s_dialog_text_buf) - 1) n = sizeof(s_dialog_text_buf) - 1;
    if (n > 0) memcpy(s_dialog_text_buf, d.bytes, n);
    s_dialog_text_buf[n] = '\0';
    return s_dialog_text_buf;
}

uint8_t gfx_dialog_get_checked_bridge(uint16_t control_id) {
    __block BOOL on = NO;
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        on = [g_dialog_manager checkedForControl:control_id];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return on ? 1 : 0;
}

int32_t gfx_dialog_get_selection_bridge(uint16_t control_id) {
    __block NSInteger idx = 0;
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        idx = [g_dialog_manager selectionForControl:control_id];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
    return (int32_t)idx;
}

void gfx_dialog_set_text_bridge(uint16_t control_id, const uint8_t *ptr, uint32_t len) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setTextForControl:control_id value:gfx_string_from_bytes(ptr, len)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_set_number_bridge(uint16_t control_id, double value) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setNumberForControl:control_id value:value];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_set_checked_bridge(uint16_t control_id, uint8_t on) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setCheckedForControl:control_id state:(on != 0)];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}

void gfx_dialog_set_selection_bridge(uint16_t control_id, int32_t index) {
    void (^work)(void) = ^{
        if (!g_dialog_manager) g_dialog_manager = [[GraphicsDialogManager alloc] init];
        [g_dialog_manager setSelectionForControl:control_id index:index];
    };
    if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);
}


// ═══════════════════════════════════════════════════════════════════════════
// GraphicsMetalRenderer — MTKViewDelegate
// ═══════════════════════════════════════════════════════════════════════════

@interface GraphicsMetalRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device view:(MTKView *)view;
- (void)allocateBuffersForWidth:(uint16_t)w height:(uint16_t)h;
- (void)releaseBuffers;
@end

@implementation GraphicsMetalRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device view:(MTKView *)view {
    self = [super init];
    if (!self) return nil;

    g_gfx_device = device;
    g_gfx_command_queue = [device newCommandQueue];

    // ── Load Metal shaders ──

    NSError *error = nil;
    NSString *shaderSource = kEmbeddedGraphicsMetalSource;

    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    if (@available(macOS 15.0, *)) {
        options.mathMode = MTLMathModeFast;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        options.fastMathEnabled = YES;
#pragma clang diagnostic pop
    }

    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource
                                                 options:options
                                                   error:&error];
    if (!library) {
        NSLog(@"[GFX] ERROR: Failed to compile graphics.metal: %@", error);
        return self;
    }

    // ── Create compute pipeline states ──

    id<MTLFunction> paletteAnimateFunc = [library newFunctionWithName:@"palette_animate"];
    id<MTLFunction> paletteLookupFunc  = [library newFunctionWithName:@"palette_lookup"];
    id<MTLFunction> collisionFunc      = [library newFunctionWithName:@"collision_check"];
    id<MTLFunction> spriteRenderFunc   = [library newFunctionWithName:@"sprite_render"];

    if (paletteAnimateFunc) {
        g_palette_animate_pipeline = [device newComputePipelineStateWithFunction:paletteAnimateFunc error:&error];
        if (!g_palette_animate_pipeline) {
            NSLog(@"[GFX] ERROR: palette_animate pipeline: %@", error);
        }
    }

    if (paletteLookupFunc) {
        g_palette_lookup_pipeline = [device newComputePipelineStateWithFunction:paletteLookupFunc error:&error];
        if (!g_palette_lookup_pipeline) {
            NSLog(@"[GFX] ERROR: palette_lookup pipeline: %@", error);
        }
    }

    if (collisionFunc) {
        g_collision_pipeline = [device newComputePipelineStateWithFunction:collisionFunc error:&error];
        if (!g_collision_pipeline) {
            NSLog(@"[GFX] ERROR: collision_check pipeline: %@", error);
        }
    }

    if (spriteRenderFunc) {
        g_sprite_render_pipeline = [device newComputePipelineStateWithFunction:spriteRenderFunc error:&error];
        if (!g_sprite_render_pipeline) {
            NSLog(@"[GFX] ERROR: sprite_render pipeline: %@", error);
        }
    }

    // ── Create render pipeline state (display quad) ──

    id<MTLFunction> vertexFunc   = [library newFunctionWithName:@"display_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"display_fragment"];

    if (vertexFunc && fragmentFunc) {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertexFunc;
        desc.fragmentFunction = fragmentFunc;
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
        // Enable alpha blending for the letterbox background
        desc.colorAttachments[0].blendingEnabled = NO;

        g_display_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!g_display_pipeline) {
            NSLog(@"[GFX] ERROR: display pipeline: %@", error);
        }
    }

    // ── Create nearest-neighbour sampler ──

    MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.minFilter = MTLSamplerMinMagFilterNearest;
    samplerDesc.magFilter = MTLSamplerMinMagFilterNearest;
    samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_nearest_sampler = [device newSamplerStateWithDescriptor:samplerDesc];

    // ── Uniforms buffer ──
    g_uniforms_buffer = [device newBufferWithLength:sizeof(GfxUniforms)
                                           options:MTLResourceStorageModeShared];

    return self;
}

- (void)allocateBuffersForWidth:(uint16_t)w height:(uint16_t)h {
    // Get resolution info from Zig (includes overscan calculation)
    gfx_get_resolution(&g_visible_w, &g_visible_h, &g_buf_w, &g_buf_h, &g_overscan_x, &g_overscan_y);

    uint64_t buf_size = (uint64_t)g_buf_w * (uint64_t)g_buf_h;
    uint64_t line_pal_size = (uint64_t)g_buf_h * LINE_PAL_ENTRIES * 4;  // 4 bytes per RGBA32
    uint64_t global_pal_size = GLOBAL_PAL_ENTRIES * 4;
    uint64_t effects_size = MAX_PALETTE_EFFECTS * PALETTE_EFFECT_SIZE;
    uint64_t collision_size = MAX_COLLISION_FLAGS * sizeof(uint32_t);

    // ── Allocate shared pixel buffers ──
    for (int i = 0; i < NUM_BUFFERS; i++) {
        g_pixel_buffers[i] = [g_gfx_device newBufferWithLength:buf_size
                                                       options:MTLResourceStorageModeShared];
        // Clear to 0 (transparent)
        memset(g_pixel_buffers[i].contents, 0, buf_size);
        // Pass pointer to Zig
        gfx_set_pixel_buffer(i, g_pixel_buffers[i].contents, buf_size);
    }

    // ── Allocate shared palette buffers ──
    g_line_palette_buffer = [g_gfx_device newBufferWithLength:line_pal_size
                                                      options:MTLResourceStorageModeShared];
    memset(g_line_palette_buffer.contents, 0, line_pal_size);
    gfx_set_line_palette(g_line_palette_buffer.contents, g_buf_h);

    g_global_palette_buffer = [g_gfx_device newBufferWithLength:global_pal_size
                                                        options:MTLResourceStorageModeShared];
    memset(g_global_palette_buffer.contents, 0, global_pal_size);
    gfx_set_global_palette(g_global_palette_buffer.contents);

    // ── Allocate shared palette effects buffer ──
    g_palette_effects_buffer = [g_gfx_device newBufferWithLength:effects_size
                                                         options:MTLResourceStorageModeShared];
    memset(g_palette_effects_buffer.contents, 0, effects_size);
    gfx_set_palette_effects(g_palette_effects_buffer.contents);

    // ── Allocate shared collision flags buffer ──
    g_collision_flags_buffer = [g_gfx_device newBufferWithLength:collision_size
                                                         options:MTLResourceStorageModeShared];
    memset(g_collision_flags_buffer.contents, 0, collision_size);
    gfx_set_collision_flags(g_collision_flags_buffer.contents);

    // ── Allocate private GPU working palette buffers ──
    g_line_pal_work = [g_gfx_device newBufferWithLength:line_pal_size
                                                options:MTLResourceStorageModePrivate];
    g_global_pal_work = [g_gfx_device newBufferWithLength:global_pal_size
                                                  options:MTLResourceStorageModePrivate];

    // ── Create output texture (Private, GPU-only) ──
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                    width:g_visible_w
                                   height:g_visible_h
                                mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    texDesc.storageMode = MTLStorageModePrivate;
    g_output_texture = [g_gfx_device newTextureWithDescriptor:texDesc];

    // ── Allocate sprite system buffers ──

    // Sprite atlas (Private — GPU only after blit upload)
    MTLTextureDescriptor *atlasDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Uint
                                    width:SPRITE_ATLAS_SIZE
                                   height:SPRITE_ATLAS_SIZE
                                mipmapped:NO];
    atlasDesc.usage = MTLTextureUsageShaderRead;
    atlasDesc.storageMode = MTLStorageModePrivate;
    g_sprite_atlas = [g_gfx_device newTextureWithDescriptor:atlasDesc];

    // Staging buffer for pixel uploads (Shared)
    g_sprite_staging = [g_gfx_device newBufferWithLength:SPRITE_STAGING_SIZE
                                                 options:MTLResourceStorageModeShared];
    memset(g_sprite_staging.contents, 0, SPRITE_STAGING_SIZE);

    // Atlas entries (Shared)
    uint64_t atlas_entries_size = SPRITE_MAX_DEFINITIONS * SPRITE_ATLAS_ENTRY_SIZE;
    g_sprite_atlas_entries = [g_gfx_device newBufferWithLength:atlas_entries_size
                                                       options:MTLResourceStorageModeShared];
    memset(g_sprite_atlas_entries.contents, 0, atlas_entries_size);

    // Instance descriptors (Shared)
    uint64_t instances_size = SPRITE_MAX_INSTANCES * SPRITE_INSTANCE_SIZE;
    g_sprite_instances = [g_gfx_device newBufferWithLength:instances_size
                                                   options:MTLResourceStorageModeShared];
    memset(g_sprite_instances.contents, 0, instances_size);

    // Palettes (Shared)
    uint64_t palettes_size = SPRITE_MAX_PALETTES * SPRITE_PALETTE_SIZE;
    g_sprite_palettes = [g_gfx_device newBufferWithLength:palettes_size
                                                  options:MTLResourceStorageModeShared];
    memset(g_sprite_palettes.contents, 0, palettes_size);

    // Sprite uniforms (Shared)
    g_sprite_uniforms = [g_gfx_device newBufferWithLength:sizeof(SpriteUniformsGPU)
                                                  options:MTLResourceStorageModeShared];
    memset(g_sprite_uniforms.contents, 0, sizeof(SpriteUniformsGPU));

    // Pass sprite buffer pointers to Zig
    gfx_set_sprite_buffers(
        g_sprite_atlas_entries.contents,
        g_sprite_instances.contents,
        g_sprite_palettes.contents,
        g_sprite_uniforms.contents
    );
    gfx_set_sprite_staging(g_sprite_staging.contents, SPRITE_STAGING_SIZE);
    gfx_set_sprite_output_size(g_visible_w, g_visible_h);

    g_frame_counter = 0;
    atomic_store(&g_front_buffer, 0);
    atomic_store(&g_scroll_x, 0);
    atomic_store(&g_scroll_y, 0);
}

- (void)releaseBuffers {
    // Clear Zig-side pointers first so they don't dangle while we
    // nil the underlying MTLBuffer objects.
    extern void gfx_clear_buffer_pointers(void);
    gfx_clear_buffer_pointers();

    for (int i = 0; i < NUM_BUFFERS; i++) {
        g_pixel_buffers[i] = nil;
    }
    g_line_palette_buffer = nil;
    g_global_palette_buffer = nil;
    g_palette_effects_buffer = nil;
    g_collision_flags_buffer = nil;
    g_line_pal_work = nil;
    g_global_pal_work = nil;
    g_output_texture = nil;

    // Sprite system
    g_sprite_atlas = nil;
    g_sprite_staging = nil;
    g_sprite_atlas_entries = nil;
    g_sprite_instances = nil;
    g_sprite_palettes = nil;
    g_sprite_uniforms = nil;
}

// ─── MTKViewDelegate ────────────────────────────────────────────────────────

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Handled in the render loop
}

- (void)drawInMTKView:(MTKView *)view {
    if (!g_gfx_active) return;
    if (!g_pixel_buffers[0]) return;

    // ═══════════════════════════════════════════════════════════════════
    // Phase 1: Drain Command Queue
    // ═══════════════════════════════════════════════════════════════════

    uint8_t cmd_type;
    uint32_t cmd_fence;
    uint8_t cmd_payload[56];

    while (gfx_dequeue_command(&cmd_type, &cmd_fence, cmd_payload)) {
        switch (cmd_type) {
            case GFX_CMD_FLIP: {
                // Swap front/back buffer index
                uint8_t front = gfx_get_front_buffer();
                atomic_store(&g_front_buffer, front);
                break;
            }

            case GFX_CMD_SET_SCROLL: {
                SetScrollPayload *p = (SetScrollPayload *)cmd_payload;
                atomic_store(&g_scroll_x, p->scroll_x);
                atomic_store(&g_scroll_y, p->scroll_y);
                break;
            }

            case GFX_CMD_SET_TITLE: {
                SetTitlePayload *p = (SetTitlePayload *)cmd_payload;
                if (p->len > 0 && p->len <= 52 && g_gfx_window) {
                    NSString *title = [[NSString alloc] initWithBytes:p->data
                                                              length:p->len
                                                            encoding:NSUTF8StringEncoding];
                    if (title) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [g_gfx_window setTitle:title];
                        });
                    }
                }
                break;
            }

            case GFX_CMD_SET_APP_NAME: {
                SetTitlePayload *p = (SetTitlePayload *)cmd_payload;
                if (p->len > 0 && p->len <= 52) {
                    NSString *name = [[NSString alloc] initWithBytes:p->data
                                                               length:p->len
                                                             encoding:NSUTF8StringEncoding];
                    if (name) {
                        ed_set_application_name(name);
                    }
                }
                break;
            }

            case GFX_CMD_INSTALL_EFFECT: {
                InstallEffectPayload *p = (InstallEffectPayload *)cmd_payload;
                if (p->slot < MAX_PALETTE_EFFECTS && g_palette_effects_buffer) {
                    PaletteEffect *effects = (PaletteEffect *)g_palette_effects_buffer.contents;
                    effects[p->slot] = p->effect;
                }
                break;
            }

            case GFX_CMD_STOP_EFFECT: {
                uint8_t slot = cmd_payload[0];
                if (slot < MAX_PALETTE_EFFECTS && g_palette_effects_buffer) {
                    PaletteEffect *effects = (PaletteEffect *)g_palette_effects_buffer.contents;
                    memset(&effects[slot], 0, PALETTE_EFFECT_SIZE);
                }
                break;
            }

            case GFX_CMD_STOP_ALL_EFFECTS: {
                if (g_palette_effects_buffer) {
                    memset(g_palette_effects_buffer.contents, 0,
                           MAX_PALETTE_EFFECTS * PALETTE_EFFECT_SIZE);
                }
                break;
            }

            case GFX_CMD_PAUSE_EFFECT: {
                uint8_t slot = cmd_payload[0];
                if (slot < MAX_PALETTE_EFFECTS && g_palette_effects_buffer) {
                    PaletteEffect *effects = (PaletteEffect *)g_palette_effects_buffer.contents;
                    effects[slot].flags &= ~(1u << 1);  // Clear ACTIVE bit
                }
                break;
            }

            case GFX_CMD_RESUME_EFFECT: {
                uint8_t slot = cmd_payload[0];
                if (slot < MAX_PALETTE_EFFECTS && g_palette_effects_buffer) {
                    PaletteEffect *effects = (PaletteEffect *)g_palette_effects_buffer.contents;
                    effects[slot].flags |= (1u << 1);   // Set ACTIVE bit
                }
                break;
            }

            case GFX_CMD_COLLISION_DISPATCH: {
                g_pending_collision = true;
                break;
            }

            case GFX_CMD_COLLISION_SINGLE: {
                // Handled as a 2-source batch in Zig; just flag collision
                g_pending_collision = true;
                break;
            }

            case GFX_CMD_COMMIT_FENCE: {
                g_last_submitted_fence = cmd_fence;
                break;
            }

            case GFX_CMD_WAIT_GPU: {
                g_pending_gpu_wait = true;
                break;
            }

            case GFX_CMD_SPRITE_UPLOAD: {
                // Pixel snapshot was already made on the JIT thread at SPRITE END;
                // just move the pointer into our pending list.
                if (g_pending_sprite_upload_count < MAX_PENDING_SPRITE_UPLOADS) {
                    SpriteUploadPayload *p = (SpriteUploadPayload *)cmd_payload;
                    g_pending_sprite_uploads[g_pending_sprite_upload_count].payload = *p;
                    g_pending_sprite_uploads[g_pending_sprite_upload_count].pixels =
                        (uint8_t *)(uintptr_t)p->pixel_ptr;
                    g_pending_sprite_upload_count++;
                }
                break;
            }

            case GFX_CMD_MENU_RESET: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                [g_menu_manager reset];
                break;
            }

            case GFX_CMD_MENU_DEFINE: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                MenuDefinePayload *p = (MenuDefinePayload *)cmd_payload;
                NSString *title = [[NSString alloc] initWithBytes:p->title length:p->title_len encoding:NSUTF8StringEncoding];
                [g_menu_manager defineMenu:p->menu_id title:title ?: @"Menu"];
                break;
            }

            case GFX_CMD_MENU_ADD_ITEM: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                MenuItemPayload *p = (MenuItemPayload *)cmd_payload;
                NSString *label = [[NSString alloc] initWithBytes:p->label length:p->label_len encoding:NSUTF8StringEncoding];
                NSString *shortcut = [[NSString alloc] initWithBytes:p->shortcut length:p->shortcut_len encoding:NSUTF8StringEncoding];
                [g_menu_manager addItemToMenu:p->menu_id
                                        itemId:p->item_id
                                         label:label ?: @"Item"
                                      shortcut:shortcut ?: @""
                                         flags:p->flags];
                break;
            }

            case GFX_CMD_MENU_ADD_SEPARATOR: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                uint8_t menu_id = cmd_payload[0];
                [g_menu_manager addSeparatorToMenu:menu_id];
                break;
            }

            case GFX_CMD_MENU_SET_CHECKED: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                MenuStatePayload *p = (MenuStatePayload *)cmd_payload;
                [g_menu_manager setChecked:p->item_id state:(p->state != 0)];
                break;
            }

            case GFX_CMD_MENU_SET_ENABLED: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                MenuStatePayload *p = (MenuStatePayload *)cmd_payload;
                [g_menu_manager setEnabled:p->item_id state:(p->state != 0)];
                break;
            }

            case GFX_CMD_MENU_RENAME: {
                if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                MenuRenamePayload *p = (MenuRenamePayload *)cmd_payload;
                NSString *label = [[NSString alloc] initWithBytes:p->label length:p->label_len encoding:NSUTF8StringEncoding];
                [g_menu_manager renameItem:p->item_id label:label ?: @""];
                break;
            }

            case GFX_CMD_CREATE_WINDOW:
            case GFX_CMD_DESTROY_WINDOW:
                // Window lifecycle is handled synchronously via
                // gfx_create_window_sync / gfx_destroy_window_sync
                // (dispatch_sync to main thread).  These command types
                // should no longer appear in the ring, but ignore them
                // harmlessly if they do.
                break;

            case GFX_CMD_SET_SCREEN_MODE:
                // Handled as a state change in Zig; no ObjC action needed
                break;

            default:
                break;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 2: Update Uniforms
    // ═══════════════════════════════════════════════════════════════════

    uint32_t front = atomic_load(&g_front_buffer);
    int32_t sx = atomic_load(&g_scroll_x);
    int32_t sy = atomic_load(&g_scroll_y);

    GfxUniforms *u = (GfxUniforms *)g_uniforms_buffer.contents;
    u->visible_width  = g_visible_w;
    u->visible_height = g_visible_h;
    u->buffer_width   = g_buf_w;
    u->buffer_height  = g_buf_h;
    u->scroll_x       = sx;
    u->scroll_y       = sy;
    u->frame_counter  = g_frame_counter;
    u->front_buffer   = front;

    // ═══════════════════════════════════════════════════════════════════
    // Phase 3: Encode GPU Passes
    // ═══════════════════════════════════════════════════════════════════

    id<MTLCommandBuffer> cmdBuf = [g_gfx_command_queue commandBuffer];
    if (!cmdBuf) return;

    // ── Pass 1: Palette Animation Compute ──
    if (g_palette_animate_pipeline && g_line_pal_work && g_global_pal_work) {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:g_palette_animate_pipeline];

        [enc setBuffer:g_line_pal_work         offset:0 atIndex:0];  // Private work
        [enc setBuffer:g_global_pal_work       offset:0 atIndex:1];  // Private work
        [enc setBuffer:g_line_palette_buffer   offset:0 atIndex:2];  // Shared base
        [enc setBuffer:g_global_palette_buffer offset:0 atIndex:3];  // Shared base
        [enc setBuffer:g_palette_effects_buffer offset:0 atIndex:4]; // Shared effects
        [enc setBuffer:g_uniforms_buffer       offset:0 atIndex:5];

        // Dispatch as a SINGLE threadgroup so that threadgroup_barrier in the
        // shader correctly synchronises the palette copy phase (all threads)
        // against the effect application phase (threads 0–31).  Using multiple
        // threadgroups caused a race: effects applied by threadgroup 0 were
        // overwritten when later threadgroups finished their copy.
        NSUInteger maxThreads = g_palette_animate_pipeline.maxTotalThreadsPerThreadgroup;
        if (maxThreads > 1024) maxThreads = 1024;  // Clamp to reasonable size
        if (maxThreads < 32)   maxThreads = 32;

        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(maxThreads, 1, 1)];
        [enc endEncoding];
    }

    // ── Pass 2: Palette Lookup Compute ──
    if (g_palette_lookup_pipeline && g_output_texture && front < NUM_BUFFERS && g_pixel_buffers[front]) {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:g_palette_lookup_pipeline];

        [enc setBuffer:g_pixel_buffers[front] offset:0 atIndex:0];  // Shared pixel buffer
        [enc setBuffer:g_line_pal_work        offset:0 atIndex:1];  // Private work
        [enc setBuffer:g_global_pal_work      offset:0 atIndex:2];  // Private work
        [enc setBuffer:g_uniforms_buffer      offset:0 atIndex:3];
        [enc setTexture:g_output_texture atIndex:0];

        NSUInteger tew = g_palette_lookup_pipeline.threadExecutionWidth;
        NSUInteger teh = g_palette_lookup_pipeline.maxTotalThreadsPerThreadgroup / tew;
        if (teh == 0) teh = 1;

        MTLSize threadsPerGroup = MTLSizeMake(tew, teh, 1);
        MTLSize gridSize = MTLSizeMake(g_visible_w, g_visible_h, 1);

        if (@available(macOS 10.15, *)) {
            [enc dispatchThreads:gridSize threadsPerThreadgroup:threadsPerGroup];
        } else {
            MTLSize groups = MTLSizeMake(
                (g_visible_w + tew - 1) / tew,
                (g_visible_h + teh - 1) / teh,
                1
            );
            [enc dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
        }

        [enc endEncoding];
    }

    // ── Pass 2.5a: Sprite Atlas Uploads (deferred blits) ──
    if (g_pending_sprite_upload_count > 0 && g_sprite_atlas) {
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        for (uint32_t ui = 0; ui < g_pending_sprite_upload_count; ui++) {
            PendingSpriteUpload *pu = &g_pending_sprite_uploads[ui];
            SpriteUploadPayload *p  = &pu->payload;
            if (p->width > 0 && p->height > 0 && pu->pixels) {
                uint32_t nbytes = (uint32_t)p->width * (uint32_t)p->height;
                // Create a per-upload temporary buffer so each blit reads its
                // own data.  Using the single g_sprite_staging caused a race:
                // all blit commands were enqueued before the GPU executed any,
                // so every blit read the last sprite's data.
                id<MTLBuffer> tmpBuf =
                    [g_gfx_device newBufferWithBytes:pu->pixels
                                              length:nbytes
                                             options:MTLResourceStorageModeShared];
                [blit copyFromBuffer:tmpBuf
                        sourceOffset:0
                   sourceBytesPerRow:p->width
                 sourceBytesPerImage:(uint64_t)p->width * p->height
                          sourceSize:MTLSizeMake(p->width, p->height, 1)
                           toTexture:g_sprite_atlas
                    destinationSlice:0
                    destinationLevel:0
                   destinationOrigin:MTLOriginMake(p->atlas_x, p->atlas_y, 0)];
            }
            free(pu->pixels);
            pu->pixels = NULL;
        }
        [blit endEncoding];
        g_pending_sprite_upload_count = 0;
    }

    // ── Pass 2.5b: Sprite Render Compute ──
    // Only dispatched when there are active sprite instances (zero cost otherwise).
    if (g_sprite_render_pipeline && g_sprite_atlas && g_output_texture && g_sprite_uniforms) {
        SpriteUniformsGPU *su = (SpriteUniformsGPU *)g_sprite_uniforms.contents;
        if (su->num_instances > 0) {
            id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
            [enc setComputePipelineState:g_sprite_render_pipeline];

            [enc setTexture:g_output_texture atIndex:0];    // read_write (RGBA16Float)
            [enc setTexture:g_sprite_atlas   atIndex:1];    // read (R8Uint)
            [enc setBuffer:g_sprite_atlas_entries offset:0 atIndex:0];
            [enc setBuffer:g_sprite_instances    offset:0 atIndex:1];
            [enc setBuffer:g_sprite_palettes     offset:0 atIndex:2];
            [enc setBuffer:g_sprite_uniforms     offset:0 atIndex:3];

            NSUInteger tew = g_sprite_render_pipeline.threadExecutionWidth;
            NSUInteger teh = g_sprite_render_pipeline.maxTotalThreadsPerThreadgroup / tew;
            if (teh == 0) teh = 1;

            MTLSize threadsPerGroup = MTLSizeMake(tew, teh, 1);
            MTLSize gridSize = MTLSizeMake(g_visible_w, g_visible_h, 1);

            if (@available(macOS 10.15, *)) {
                [enc dispatchThreads:gridSize threadsPerThreadgroup:threadsPerGroup];
            } else {
                MTLSize groups = MTLSizeMake(
                    (g_visible_w + tew - 1) / tew,
                    (g_visible_h + teh - 1) / teh,
                    1
                );
                [enc dispatchThreadgroups:groups threadsPerThreadgroup:threadsPerGroup];
            }

            [enc endEncoding];
        }
    }

    // ── Pass 3: Collision Detection (if requested) ──
    if (g_pending_collision && g_collision_pipeline && g_collision_flags_buffer) {
        // Clear collision flags
        uint32_t *flags = (uint32_t *)g_collision_flags_buffer.contents;
        memset(flags, 0, MAX_COLLISION_FLAGS * sizeof(uint32_t));

        uint8_t count = gfx_get_collision_count();
        uint64_t buf_size = (uint64_t)g_buf_w * (uint64_t)g_buf_h;

        // Create a contiguous buffer view for all pixel buffers
        // We encode separate dispatches for each pair
        for (uint8_t i = 0; i < count; i++) {
            for (uint8_t j = i + 1; j < count; j++) {
                // Get source info
                uint8_t buf_a_idx, buf_b_idx;
                int16_t ax, ay, bx, by;
                uint16_t aw, ah, bw, bh;

                if (!gfx_get_collision_source(i, &buf_a_idx, &ax, &ay, &aw, &ah)) continue;
                if (!gfx_get_collision_source(j, &buf_b_idx, &bx, &by, &bw, &bh)) continue;

                if (buf_a_idx >= NUM_BUFFERS || buf_b_idx >= NUM_BUFFERS) continue;

                // Compute overlap region
                int32_t overlap_left   = (ax > bx) ? ax : bx;
                int32_t overlap_top    = (ay > by) ? ay : by;
                int32_t overlap_right  = ((ax + aw) < (bx + bw)) ? (ax + aw) : (bx + bw);
                int32_t overlap_bottom = ((ay + ah) < (by + bh)) ? (ay + ah) : (by + bh);

                int32_t overlap_w = overlap_right - overlap_left;
                int32_t overlap_h = overlap_bottom - overlap_top;

                if (overlap_w <= 0 || overlap_h <= 0) continue;  // No overlap

                // Triangular matrix index
                uint32_t flags_idx = j * (j - 1) / 2 + i;

                CollisionParams params;
                params.buf_a_offset = 0;  // Offset within the buffer itself
                params.buf_b_offset = 0;
                params.buf_stride = g_buf_w;
                // Remap overlap coordinates relative to each region
                params.ax = overlap_left;
                params.ay = overlap_top;
                params.bx = overlap_left;
                params.by = overlap_top;
                params.width = (uint32_t)overlap_w;
                params.height = (uint32_t)overlap_h;
                params.flags_index = flags_idx;

                id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
                [enc setComputePipelineState:g_collision_pipeline];
                [enc setBuffer:g_pixel_buffers[buf_a_idx] offset:0 atIndex:0];
                [enc setBuffer:g_collision_flags_buffer   offset:0 atIndex:1];
                [enc setBytes:&params length:sizeof(CollisionParams) atIndex:2];

                // For collision, we need both buffers. Since the shader reads
                // from buffer(0), we'll handle this by encoding two separate
                // reads. Actually, the shader expects all_buffers as a single
                // buffer. For simplicity, we use buf_a as the "all" buffer
                // and compute offsets accordingly.
                //
                // Better approach: use the buf_a buffer directly and set buf_b
                // as a separate buffer. Let's modify the collision approach:
                // We dispatch with buf_a, and manually check buf_b pixels.
                //
                // For the MVP, we'll do a CPU-side collision check for the
                // overlapping regions since the buffers are shared memory.
                // This is fast enough for small sprite regions.

                // Actually, since both buffers are MTLStorageModeShared, we can
                // just do the collision check right here on the CPU. This avoids
                // the complexity of passing two separate buffers to the shader.

                [enc endEncoding];

                // CPU-side collision check (shared memory — zero copy)
                uint8_t *buf_a_ptr = (uint8_t *)g_pixel_buffers[buf_a_idx].contents;
                uint8_t *buf_b_ptr = (uint8_t *)g_pixel_buffers[buf_b_idx].contents;
                bool hit = false;

                for (int32_t py = 0; py < overlap_h && !hit; py++) {
                    for (int32_t px = 0; px < overlap_w && !hit; px++) {
                        int32_t a_x = overlap_left + px;
                        int32_t a_y = overlap_top + py;
                        int32_t b_x = overlap_left + px;
                        int32_t b_y = overlap_top + py;

                        if (a_x < 0 || a_x >= g_buf_w || a_y < 0 || a_y >= g_buf_h) continue;
                        if (b_x < 0 || b_x >= g_buf_w || b_y < 0 || b_y >= g_buf_h) continue;

                        uint32_t a_off = (uint32_t)a_y * g_buf_w + (uint32_t)a_x;
                        uint32_t b_off = (uint32_t)b_y * g_buf_w + (uint32_t)b_x;

                        if (buf_a_ptr[a_off] != 0 && buf_b_ptr[b_off] != 0) {
                            hit = true;
                        }
                    }
                }

                if (hit) {
                    flags[flags_idx] = 1;
                }
            }
        }

        g_pending_collision = false;
    }

    // ── Pass 4: Display Scaling Render Pass ──
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;

    if (drawable && passDesc && g_display_pipeline && g_output_texture) {
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;

        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
        [enc setRenderPipelineState:g_display_pipeline];

        // Set display uniforms
        uint16_t par_num, par_den;
        gfx_get_par(&par_num, &par_den);

        DisplayUniforms du;
        CGSize drawableSize = view.drawableSize;
        du.viewport_size[0] = (float)drawableSize.width;
        du.viewport_size[1] = (float)drawableSize.height;
        du.texture_size[0]  = (float)g_visible_w;
        du.texture_size[1]  = (float)g_visible_h;
        du.par_numerator    = (float)par_num;
        du.par_denominator  = (float)par_den;
        du._pad[0] = 0;
        du._pad[1] = 0;

        [enc setVertexBytes:&du length:sizeof(DisplayUniforms) atIndex:0];
        [enc setFragmentTexture:g_output_texture atIndex:0];
        [enc setFragmentSamplerState:g_nearest_sampler atIndex:0];

        // Draw fullscreen triangle (3 vertices, no vertex buffer)
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 4: Completion Handler + Present
    // ═══════════════════════════════════════════════════════════════════

    uint32_t submitted_fence = g_last_submitted_fence;
    bool wants_gpu_wait = g_pending_gpu_wait;
    g_pending_gpu_wait = false;

    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cb) {
        // Signal VSYNC
        gfx_signal_vsync();

        // Signal GPU wait if pending
        if (wants_gpu_wait) {
            gfx_signal_gpu_wait();
        }

        // Update completed fence
        if (submitted_fence > 0) {
            gfx_update_fence(submitted_fence);
        }
    }];

    if (drawable) {
        [cmdBuf presentDrawable:drawable];
    }
    [cmdBuf commit];

    g_frame_counter++;
}

@end


// ═══════════════════════════════════════════════════════════════════════════
// GraphicsWindowController — NSWindowDelegate + Event Handling
// ═══════════════════════════════════════════════════════════════════════════

@interface GraphicsWindowController : NSObject <NSWindowDelegate>
- (void)createWindowWithWidth:(uint16_t)w height:(uint16_t)h scaleHint:(uint16_t)scale;
- (void)destroyWindow;
@end

@interface GraphicsContentView : MTKView
@end

@implementation GraphicsContentView

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

// ─── Keyboard Events ────────────────────────────────────────────────────

- (void)keyDown:(NSEvent *)event {
    gfx_set_key_state((uint8_t)event.keyCode, 1);
}

- (void)keyUp:(NSEvent *)event {
    gfx_set_key_state((uint8_t)event.keyCode, 0);
}

- (void)flagsChanged:(NSEvent *)event {
    // Track modifier keys
    NSEventModifierFlags flags = event.modifierFlags;
    gfx_set_key_state(56, (flags & NSEventModifierFlagShift) ? 1 : 0);    // Shift
    gfx_set_key_state(59, (flags & NSEventModifierFlagControl) ? 1 : 0);  // Ctrl
    gfx_set_key_state(58, (flags & NSEventModifierFlagOption) ? 1 : 0);   // Alt/Option
    gfx_set_key_state(55, (flags & NSEventModifierFlagCommand) ? 1 : 0);  // Cmd
}

// ─── Mouse Events ───────────────────────────────────────────────────────

- (void)updateMousePosition:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

    // Convert from view coordinates to logical pixel coordinates
    CGSize viewSize = self.bounds.size;
    if (viewSize.width <= 0 || viewSize.height <= 0) return;

    // Account for PAR correction and scaling
    uint16_t par_num, par_den;
    gfx_get_par(&par_num, &par_den);
    float par = (float)par_num / fmaxf((float)par_den, 1.0f);

    float display_w = (float)g_visible_w;
    float display_h = (float)g_visible_h * par;

    float scale_x = (float)viewSize.width / display_w;
    float scale_y = (float)viewSize.height / display_h;
    float scale = fminf(scale_x, scale_y);

    float rendered_w = display_w * scale;
    float rendered_h = display_h * scale;

    float offset_x = ((float)viewSize.width - rendered_w) * 0.5f;
    float offset_y = ((float)viewSize.height - rendered_h) * 0.5f;

    // Map view coordinates to logical pixels
    float lx = (loc.x - offset_x) / scale;
    float ly = ((float)viewSize.height - loc.y - offset_y) / scale / par;

    int16_t mx = (int16_t)lx;
    int16_t my = (int16_t)ly;

    // Clamp to visible area
    if (mx < 0) mx = 0;
    if (my < 0) my = 0;
    if (mx >= g_visible_w) mx = g_visible_w - 1;
    if (my >= g_visible_h) my = g_visible_h - 1;

    gfx_set_mouse_state(mx, my, g_mouse_buttons);
}

- (void)mouseDown:(NSEvent *)event {
    g_mouse_buttons |= 1;  // Left
    [self updateMousePosition:event];
}

- (void)mouseUp:(NSEvent *)event {
    g_mouse_buttons &= ~1;
    [self updateMousePosition:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    g_mouse_buttons |= 2;  // Right
    [self updateMousePosition:event];
}

- (void)rightMouseUp:(NSEvent *)event {
    g_mouse_buttons &= ~2;
    [self updateMousePosition:event];
}

- (void)otherMouseDown:(NSEvent *)event {
    g_mouse_buttons |= 4;  // Middle
    [self updateMousePosition:event];
}

- (void)otherMouseUp:(NSEvent *)event {
    g_mouse_buttons &= ~4;
    [self updateMousePosition:event];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateMousePosition:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self updateMousePosition:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self updateMousePosition:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self updateMousePosition:event];
}

- (void)scrollWheel:(NSEvent *)event {
    float dy = (float)event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) {
        dy *= 10.0f;  // Line-based scrolling
    }
    gfx_add_mouse_scroll((int16_t)dy);
}

@end


@implementation GraphicsWindowController

- (void)createWindowWithWidth:(uint16_t)w height:(uint16_t)h scaleHint:(uint16_t)scale {
    if (g_gfx_window) {
        // Window already exists — close it first so we create a fresh one.
        // Use programmatic close so windowShouldClose: doesn't kill the
        // JIT thread that is waiting for this window to be created.
        [self destroyWindowProgrammatic:YES];
    }

    // Get Metal device
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSLog(@"[GFX] ERROR: No Metal device available");
        return;
    }

    // Calculate window size
    uint16_t par_num, par_den;
    gfx_get_par(&par_num, &par_den);
    float par = (float)par_num / fmaxf((float)par_den, 1.0f);

    float display_w = (float)w;
    float display_h = (float)h * par;

    // Determine integer scale factor
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenFrame = screen.visibleFrame;
    float max_scale_x = (float)screenFrame.size.width / display_w;
    float max_scale_y = (float)screenFrame.size.height / display_h;
    float max_scale = fminf(max_scale_x, max_scale_y) * 0.85f;  // Leave some margin

    float win_scale;
    if (scale > 0) {
        win_scale = (float)scale;
    } else {
        win_scale = floorf(max_scale);
        if (win_scale < 1.0f) win_scale = 1.0f;
    }

    float win_w = display_w * win_scale;
    float win_h = display_h * win_scale;

    // Create window
    NSRect contentRect = NSMakeRect(0, 0, win_w, win_h);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable |
                                  NSWindowStyleMaskResizable;

    g_gfx_window = [[NSWindow alloc] initWithContentRect:contentRect
                                               styleMask:styleMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    if (!g_gfx_window) {
        NSLog(@"[GFX] ERROR: Failed to create window (request %hu x %hu, scale %hu)", w, h, scale);
        return;
    }

    [g_gfx_window setTitle:@"FasterBASIC Graphics"];
    [g_gfx_window setMinSize:NSMakeSize(display_w, display_h)];
    [g_gfx_window setDelegate:self];
    [g_gfx_window setAcceptsMouseMovedEvents:YES];
    [g_gfx_window setReleasedWhenClosed:NO];  // ARC manages lifecycle

    // Create MTKView
    GraphicsContentView *mtkView = [[GraphicsContentView alloc] initWithFrame:contentRect device:device];
    mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    mtkView.preferredFramesPerSecond = 60;
    mtkView.enableSetNeedsDisplay = NO;  // Continuous rendering
    mtkView.paused = NO;

    g_gfx_mtk_view = mtkView;
    g_gfx_window.contentView = mtkView;

    // Create renderer
    g_gfx_renderer = [[GraphicsMetalRenderer alloc] initWithDevice:device view:mtkView];
    if (!g_gfx_renderer) {
        NSLog(@"[GFX] ERROR: Failed to create renderer (request %hu x %hu, scale %hu)", w, h, scale);
        [g_gfx_window close];
        g_gfx_window = nil;
        return;
    }
    mtkView.delegate = g_gfx_renderer;

    // Allocate shared buffers
    [g_gfx_renderer allocateBuffersForWidth:w height:h];

    // Initialize default palettes (Zig side)
    // This is done after buffer pointers are set in Zig
    g_gfx_active = true;

    // Center and show window
    [g_gfx_window center];
    [g_gfx_window makeKeyAndOrderFront:nil];
    [g_gfx_window orderFrontRegardless];

    // Re-activate the application so the window is visible even when
    // running from a CLI process (fbc --jit) that wasn't launched from
    // the Dock or Finder.  Without this the window may be created but
    // hidden behind other apps.
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    }

    // Make the MTKView first responder for keyboard events
    [g_gfx_window makeFirstResponder:mtkView];
}

- (void)destroyWindow {
    [self destroyWindowProgrammatic:NO];
}

- (void)destroyWindowProgrammatic:(BOOL)programmatic {
    g_gfx_active = false;

    // Closing the window triggers windowShouldClose: → windowWillClose:
    // which handles releasing buffers, nilling pointers, etc.
    // When called programmatically (during window recreation), we set a
    // flag so windowShouldClose: does NOT call basic_jit_stop() — the
    // JIT thread is alive and waiting for the new window to be created.
    if (g_gfx_window) {
        if (programmatic) {
            g_gfx_programmatic_close = true;
        }
        [g_gfx_window close];
        g_gfx_programmatic_close = false;
        // g_gfx_window is set to nil inside windowWillClose:
    }
}

// ─── NSWindowDelegate ───────────────────────────────────────────────────

- (BOOL)windowShouldClose:(NSWindow *)sender {
    g_gfx_active = false;
    gfx_mark_closed();

    // Stop the running JIT program — if a BASIC program opened this
    // window, closing it should terminate the program (like Cmd+.).
    // BUT: if the close is programmatic (window recreation), the JIT
    // thread is alive and blocked in dispatch_sync waiting for the new
    // window — do NOT kill it.
    if (!g_gfx_programmatic_close) {
        extern void basic_jit_stop(void);
        basic_jit_stop();
    }

    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    // The window is being closed (close button, programmatic close, or
    // forced stop).  Clean up all references so createWindowWithWidth:
    // will create a fresh window next time instead of trying to
    // reconfigure a dead one.
    if (g_gfx_renderer) {
        [g_gfx_renderer releaseBuffers];
        g_gfx_renderer = nil;
    }

    if (g_gfx_mtk_view) {
        g_gfx_mtk_view.paused = YES;
        g_gfx_mtk_view.delegate = nil;
        g_gfx_mtk_view = nil;
    }

    g_gfx_window = nil;
    g_gfx_command_queue = nil;
    g_gfx_device = nil;

    if (g_menu_manager) {
        [g_menu_manager reset];
    } else {
        gfx_menu_clear_events();
    }

    if (g_dialog_manager) {
        [g_dialog_manager reset];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    // Graphics window gained focus
}

- (void)windowDidResignKey:(NSNotification *)notification {
    // Graphics window lost focus — clear all key states
    for (int i = 0; i < 256; i++) {
        gfx_set_key_state((uint8_t)i, 0);
    }
    g_mouse_buttons = 0;
}

@end


// ═══════════════════════════════════════════════════════════════════════════
// GraphicsControllerManager — Game Controller Discovery + Polling
// ═══════════════════════════════════════════════════════════════════════════
//
// Uses the GameController framework to discover and poll game controllers.
// Supports up to 4 controllers. Axes and buttons are forwarded to Zig's
// ControllerState via gfx_set_controller_state().
//
// Axis mapping (index → meaning):
//   0 = Left stick X    (-1..1)
//   1 = Left stick Y    (-1..1)
//   2 = Right stick X   (-1..1)
//   3 = Right stick Y   (-1..1)
//   4 = Left trigger    (0..1)
//   5 = Right trigger   (0..1)
//
// Button mapping (bit → button):
//   0  = A / Cross           8  = Left shoulder
//   1  = B / Circle          9  = Right shoulder
//   2  = X / Square         10  = Left trigger (digital)
//   3  = Y / Triangle       11  = Right trigger (digital)
//   4  = D-pad Up           12  = Left stick click
//   5  = D-pad Down         13  = Right stick click
//   6  = D-pad Left         14  = Home / Guide
//   7  = D-pad Right        15  = Options / Menu

#define MAX_CONTROLLERS 4

@interface GraphicsControllerManager : NSObject
- (void)startObserving;
- (void)stopObserving;
- (void)pollControllers;
@end

@implementation GraphicsControllerManager {
    NSTimer *_pollTimer;
    id _connectObserver;
    id _disconnectObserver;
}

- (void)startObserving {
    // Observe controller connect/disconnect notifications
    _connectObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidConnectNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [self updateControllerList];
    }];

    _disconnectObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:GCControllerDidDisconnectNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [self updateControllerList];
    }];

    // Start discovery
    if (@available(macOS 11.0, *)) {
        [GCController startWirelessControllerDiscoveryWithCompletionHandler:^{
            // Discovery complete
        }];
    }

    // Initial scan
    [self updateControllerList];

    // Poll controller state at 60 Hz
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                repeats:YES
                                                  block:^(NSTimer *timer) {
        [self pollControllers];
    }];
}

- (void)stopObserving {
    if (_pollTimer) {
        [_pollTimer invalidate];
        _pollTimer = nil;
    }

    if (_connectObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_connectObserver];
        _connectObserver = nil;
    }
    if (_disconnectObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_disconnectObserver];
        _disconnectObserver = nil;
    }

    if (@available(macOS 11.0, *)) {
        [GCController stopWirelessControllerDiscovery];
    }

    // Mark all controllers disconnected
    for (uint8_t i = 0; i < MAX_CONTROLLERS; i++) {
        gfx_set_controller_disconnected(i);
    }
}

- (void)updateControllerList {
    NSArray<GCController *> *controllers = [GCController controllers];

    // Mark all as disconnected first, then re-populate
    for (uint8_t i = 0; i < MAX_CONTROLLERS; i++) {
        gfx_set_controller_disconnected(i);
    }

    uint8_t slot = 0;
    for (GCController *ctrl in controllers) {
        if (slot >= MAX_CONTROLLERS) break;
        // We'll pick up their state in pollControllers
        (void)ctrl;
        slot++;
    }
}

- (void)pollControllers {
    if (!g_gfx_active) return;

    NSArray<GCController *> *controllers = [GCController controllers];
    uint8_t slot = 0;

    for (GCController *ctrl in controllers) {
        if (slot >= MAX_CONTROLLERS) break;

        float axes[6] = {0, 0, 0, 0, 0, 0};
        uint32_t buttons = 0;

        GCExtendedGamepad *gp = ctrl.extendedGamepad;
        if (gp) {
            // ── Axes ──
            axes[0] = gp.leftThumbstick.xAxis.value;
            axes[1] = gp.leftThumbstick.yAxis.value;
            axes[2] = gp.rightThumbstick.xAxis.value;
            axes[3] = gp.rightThumbstick.yAxis.value;
            axes[4] = gp.leftTrigger.value;
            axes[5] = gp.rightTrigger.value;

            // ── Buttons ──
            if (gp.buttonA.pressed)        buttons |= (1u << 0);
            if (gp.buttonB.pressed)        buttons |= (1u << 1);
            if (gp.buttonX.pressed)        buttons |= (1u << 2);
            if (gp.buttonY.pressed)        buttons |= (1u << 3);
            if (gp.dpad.up.pressed)        buttons |= (1u << 4);
            if (gp.dpad.down.pressed)      buttons |= (1u << 5);
            if (gp.dpad.left.pressed)      buttons |= (1u << 6);
            if (gp.dpad.right.pressed)     buttons |= (1u << 7);
            if (gp.leftShoulder.pressed)   buttons |= (1u << 8);
            if (gp.rightShoulder.pressed)  buttons |= (1u << 9);
            if (gp.leftTrigger.pressed)    buttons |= (1u << 10);
            if (gp.rightTrigger.pressed)   buttons |= (1u << 11);

            if (@available(macOS 10.14.1, *)) {
                if (gp.leftThumbstickButton && gp.leftThumbstickButton.pressed)
                    buttons |= (1u << 12);
                if (gp.rightThumbstickButton && gp.rightThumbstickButton.pressed)
                    buttons |= (1u << 13);
            }

            if (@available(macOS 11.0, *)) {
                if (gp.buttonHome && gp.buttonHome.pressed)
                    buttons |= (1u << 14);
            }

            if (@available(macOS 10.15, *)) {
                if (gp.buttonMenu.pressed)
                    buttons |= (1u << 15);
            }

            gfx_set_controller_state(slot, 1, axes, buttons);
        } else {
            // Try micro gamepad (Siri Remote, etc.)
            GCMicroGamepad *micro = ctrl.microGamepad;
            if (micro) {
                axes[0] = micro.dpad.xAxis.value;
                axes[1] = micro.dpad.yAxis.value;

                if (micro.buttonA.pressed) buttons |= (1u << 0);
                if (micro.buttonX.pressed) buttons |= (1u << 2);

                gfx_set_controller_state(slot, 1, axes, buttons);
            } else {
                gfx_set_controller_disconnected(slot);
            }
        }

        slot++;
    }

    // Mark remaining slots as disconnected
    while (slot < MAX_CONTROLLERS) {
        gfx_set_controller_disconnected(slot);
        slot++;
    }
}

@end


// ═══════════════════════════════════════════════════════════════════════════
// Main Thread Command Processing
// ═══════════════════════════════════════════════════════════════════════════
//
// This function is called periodically from the main run loop to process
// commands that require main-thread execution (window creation/destruction).
// The MTKView's drawInMTKView: handles the per-frame commands.

static void gfx_process_main_thread_commands(void) {
    uint8_t cmd_type;
    uint32_t cmd_fence;
    uint8_t cmd_payload[56];

    // Peek at commands — only process window lifecycle commands here.
    // Other commands are processed in drawInMTKView:.
    // Since we're using a SPSC queue, we need to be careful not to
    // consume commands meant for the renderer.
    //
    // Solution: The renderer's drawInMTKView drains all commands.
    // Window lifecycle commands that arrive before the window exists
    // are handled here via a timer.

    // This is handled by the timer below.
}

// ═══════════════════════════════════════════════════════════════════════════
// Startup Timer — Process Window Creation Commands
// ═══════════════════════════════════════════════════════════════════════════
//
// Before the graphics window exists, there's no MTKView to drain commands.
// We use a repeating timer on the main thread to check for CREATE_WINDOW
// commands and process them.

static NSTimer *g_gfx_startup_timer = nil;

static void gfx_start_command_polling(void) {
    if (g_gfx_startup_timer) return;

    g_gfx_startup_timer = [NSTimer scheduledTimerWithTimeInterval:1.0/120.0
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        // If the window is active and rendering, the MTKView drains commands
        if (g_gfx_active && g_gfx_mtk_view && !g_gfx_mtk_view.paused) {
            return;
        }

        // Drain commands from the ring.  When there is no graphics SCREEN,
        // most drawing commands have nowhere to go and are discarded.
        // However, MENU commands must still be processed — they operate on
        // the application menu bar which exists independently of any SCREEN.
        uint8_t cmd_type;
        uint32_t cmd_fence;
        uint8_t cmd_payload[56];

        while (gfx_dequeue_command(&cmd_type, &cmd_fence, cmd_payload)) {
            switch (cmd_type) {
                case GFX_CMD_MENU_RESET: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    [g_menu_manager reset];
                    break;
                }
                case GFX_CMD_MENU_DEFINE: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    MenuDefinePayload *p = (MenuDefinePayload *)cmd_payload;
                    NSString *title = [[NSString alloc] initWithBytes:p->title length:p->title_len encoding:NSUTF8StringEncoding];
                    [g_menu_manager defineMenu:p->menu_id title:title ?: @"Menu"];
                    break;
                }
                case GFX_CMD_MENU_ADD_ITEM: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    MenuItemPayload *p = (MenuItemPayload *)cmd_payload;
                    NSString *label = [[NSString alloc] initWithBytes:p->label length:p->label_len encoding:NSUTF8StringEncoding];
                    NSString *shortcut = [[NSString alloc] initWithBytes:p->shortcut length:p->shortcut_len encoding:NSUTF8StringEncoding];
                    [g_menu_manager addItemToMenu:p->menu_id
                                           itemId:p->item_id
                                            label:label ?: @"Item"
                                         shortcut:shortcut ?: @""
                                            flags:p->flags];
                    break;
                }
                case GFX_CMD_MENU_ADD_SEPARATOR: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    uint8_t menu_id = cmd_payload[0];
                    [g_menu_manager addSeparatorToMenu:menu_id];
                    break;
                }
                case GFX_CMD_MENU_SET_CHECKED: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    MenuStatePayload *p = (MenuStatePayload *)cmd_payload;
                    [g_menu_manager setChecked:p->item_id state:(p->state != 0)];
                    break;
                }
                case GFX_CMD_MENU_SET_ENABLED: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    MenuStatePayload *p = (MenuStatePayload *)cmd_payload;
                    [g_menu_manager setEnabled:p->item_id state:(p->state != 0)];
                    break;
                }
                case GFX_CMD_MENU_RENAME: {
                    if (!g_menu_manager) g_menu_manager = [[GraphicsMenuManager alloc] init];
                    MenuRenamePayload *p = (MenuRenamePayload *)cmd_payload;
                    NSString *label = [[NSString alloc] initWithBytes:p->label length:p->label_len encoding:NSUTF8StringEncoding];
                    [g_menu_manager renameItem:p->item_id label:label ?: @""];
                    break;
                }
                default:
                    // Discard drawing/effect commands — no SCREEN to render to.
                    break;
            }
        }
    }];
}

// ═══════════════════════════════════════════════════════════════════════════
// Static helpers — create/destroy window via GraphicsWindowController
// ═══════════════════════════════════════════════════════════════════════════
// Called from both the render loop (drawInMTKView:) and the polling timer.
// Defined here because GraphicsWindowController must be fully declared first.

static void gfx_handle_create_window(uint16_t w, uint16_t h, uint16_t scale) {
    if (!g_gfx_window_controller) {
        g_gfx_window_controller = [[GraphicsWindowController alloc] init];
    }
    [g_gfx_window_controller createWindowWithWidth:w height:h scaleHint:scale];
}

static void gfx_handle_destroy_window(void) {
    if (g_gfx_window_controller) {
        [g_gfx_window_controller destroyWindow];
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Window lifecycle — called from Zig (JIT thread or GCD thread)
// ═══════════════════════════════════════════════════════════════════════════

/// Synchronous window creation.  Blocks the caller until the main thread
/// has finished creating the window and allocating buffers.
void gfx_create_window_sync(uint16_t w, uint16_t h, uint16_t scale) {
    void (^work)(void) = ^{
        gfx_handle_create_window(w, h, scale);
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

/// Asynchronous window destruction.  Returns immediately; the window is
/// closed on the main thread shortly after.  SCREENCLOSE doesn't need to
/// wait — the program is about to exit anyway, and blocking with
/// dispatch_sync here can deadlock.
void gfx_destroy_window_async(void) {
    if ([NSThread isMainThread]) {
        gfx_handle_destroy_window();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            gfx_handle_destroy_window();
        });
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Public C Interface — Called from ed_main.zig to start the graphics system
// ═══════════════════════════════════════════════════════════════════════════

/// Initialize the graphics subsystem. Called once at app startup.
/// Sets up the command polling timer on the main thread.
void ed_graphics_init(void) {
    // Must be called on the main thread
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ed_graphics_init();
        });
        return;
    }

    gfx_start_command_polling();

    // Start game controller observation
    if (!g_gfx_controller_manager) {
        g_gfx_controller_manager = [[GraphicsControllerManager alloc] init];
    }
    [g_gfx_controller_manager startObserving];
}

// ─── Screen Save — PNG Export ────────────────────────────────────────────────

/// Convert a float16 (half) component stored as uint16 to a uint8 [0,255].
static uint8_t f16_to_u8(uint16_t h) {
    uint32_t sign = (uint32_t)(h >> 15) << 31;
    uint32_t exp  = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x3FF;
    uint32_t bits;
    if (exp == 0) {
        bits = sign | (mant << 13);                       // ±zero / denorm
    } else if (exp == 31) {
        bits = sign | 0x7F800000u | (mant << 13);         // Inf / NaN
    } else {
        bits = sign | ((exp + 112u) << 23) | (mant << 13);
    }
    float f;
    memcpy(&f, &bits, sizeof f);
    if (f <= 0.0f) return 0;
    if (f >= 1.0f) return 255;
    return (uint8_t)(f * 255.0f + 0.5f);
}

/// Called from the JIT thread; dispatches synchronously to the main thread
/// to blit g_output_texture (Private, RGBA16Float) into a Shared buffer,
/// converts to RGBA8, then writes a PNG.
void gfx_screensave_png(const char *path) {
    @autoreleasepool {
        void (^work)(void) = ^{
            @autoreleasepool {
                if (!g_output_texture || !g_gfx_device || !g_gfx_command_queue) {
                    NSLog(@"SCREENSAVE: graphics not initialised");
                    return;
                }
                NSUInteger tw  = g_output_texture.width;
                NSUInteger th  = g_output_texture.height;
                NSUInteger bpr = tw * 8;   // RGBA16Float = 8 bytes per pixel

                // Allocate a CPU-readable buffer to receive the texture data.
                id<MTLBuffer> capBuf =
                    [g_gfx_device newBufferWithLength:bpr * th
                                             options:MTLResourceStorageModeShared];
                if (!capBuf) {
                    NSLog(@"SCREENSAVE: failed to allocate capture buffer (%lux%lu)",
                          (unsigned long)tw, (unsigned long)th);
                    return;
                }

                // Blit Private texture → Shared buffer.
                id<MTLCommandBuffer>      cmd  = [g_gfx_command_queue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
                [blit copyFromTexture:g_output_texture
                          sourceSlice:0
                          sourceLevel:0
                         sourceOrigin:MTLOriginMake(0, 0, 0)
                           sourceSize:MTLSizeMake(tw, th, 1)
                             toBuffer:capBuf
                    destinationOffset:0
               destinationBytesPerRow:bpr
             destinationBytesPerImage:bpr * th];
                [blit endEncoding];
                [cmd commit];
                [cmd waitUntilCompleted];

                // Convert RGBA16Float → RGBA8, composited against black
                // (transparent pixels become black, matching what the Metal view shows).
                const uint16_t *src = (const uint16_t *)capBuf.contents;
                NSUInteger npixels  = tw * th;
                NSMutableData *rgba8 = [NSMutableData dataWithLength:npixels * 4];
                uint8_t *dst = (uint8_t *)rgba8.mutableBytes;
                for (NSUInteger i = 0; i < npixels; i++) {
                    uint8_t r = f16_to_u8(src[i * 4 + 0]);
                    uint8_t g = f16_to_u8(src[i * 4 + 1]);
                    uint8_t b = f16_to_u8(src[i * 4 + 2]);
                    uint8_t a = f16_to_u8(src[i * 4 + 3]);
                    // Pre-multiply against black background → fully opaque output.
                    dst[i * 4 + 0] = (uint8_t)((r * a + 127) / 255);
                    dst[i * 4 + 1] = (uint8_t)((g * a + 127) / 255);
                    dst[i * 4 + 2] = (uint8_t)((b * a + 127) / 255);
                    dst[i * 4 + 3] = 255;
                }

                // Encode and write PNG.
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL
                    pixelsWide:(NSInteger)tw
                    pixelsHigh:(NSInteger)th
                    bitsPerSample:8 samplesPerPixel:4
                    hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace
                    bytesPerRow:(NSInteger)(tw * 4)
                    bitsPerPixel:32];
                if (!rep) { NSLog(@"SCREENSAVE: bitmap alloc failed"); return; }
                memcpy([rep bitmapData], dst, npixels * 4);
                NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                                   properties:@{}];
                if (!pngData) { NSLog(@"SCREENSAVE: PNG encode failed"); return; }

                NSString *nsPath = [NSString stringWithUTF8String:path];
                if ([pngData writeToFile:nsPath atomically:YES]) {
                    NSLog(@"SCREENSAVE: saved %lux%lu → %@",
                          (unsigned long)tw, (unsigned long)th, nsPath);
                } else {
                    NSLog(@"SCREENSAVE: failed to write '%@'", nsPath);
                }
            }
        };

        if ([NSThread isMainThread]) {
            work();
        } else {
            dispatch_sync(dispatch_get_main_queue(), work);
        }
    }
}

/// Save an RGBA8 image buffer to PNG.
/// Returns 1 on success, 0 on failure.
uint8_t gfx_image_write_png_bridge(const uint8_t *path_ptr,
                                   uint32_t path_len,
                                   const uint8_t *rgba_ptr,
                                   uint32_t width,
                                   uint32_t height,
                                   uint32_t stride) {
    @autoreleasepool {
        if (!path_ptr || path_len == 0 || !rgba_ptr || width == 0 || height == 0) return 0;
        if (stride < width * 4) return 0;

        NSString *nsPath = [[NSString alloc] initWithBytes:path_ptr length:path_len encoding:NSUTF8StringEncoding];
        if (!nsPath || nsPath.length == 0) return 0;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)width
            pixelsHigh:(NSInteger)height
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:(NSInteger)(width * 4)
            bitsPerPixel:32];
        if (!rep) return 0;

        uint8_t *dst = [rep bitmapData];
        if (!dst) return 0;

        const size_t rowBytes = (size_t)width * 4;
        for (uint32_t y = 0; y < height; y++) {
            const uint8_t *srcRow = rgba_ptr + (size_t)y * (size_t)stride;
            uint8_t *dstRow = dst + (size_t)y * rowBytes;
            memcpy(dstRow, srcRow, rowBytes);
        }

        NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!pngData) return 0;

        return [pngData writeToFile:nsPath atomically:YES] ? 1 : 0;
    }
}

/// Load a PNG file from disk and return a malloc'd RGBA8 buffer.
/// Caller is responsible for calling free() on the returned pointer.
/// Returns NULL on failure. Sets *out_w and *out_h to image dimensions.
uint8_t *gfx_image_read_png_bridge(const uint8_t *path_ptr,
                                   uint32_t path_len,
                                   uint32_t *out_w,
                                   uint32_t *out_h) {
    @autoreleasepool {
        if (!path_ptr || path_len == 0 || !out_w || !out_h) return NULL;
        *out_w = 0;
        *out_h = 0;

        NSString *nsPath = [[NSString alloc] initWithBytes:path_ptr
                                                   length:path_len
                                                 encoding:NSUTF8StringEncoding];
        if (!nsPath || nsPath.length == 0) return NULL;

        NSImage *nsImage = [[NSImage alloc] initWithContentsOfFile:nsPath];
        if (!nsImage) return NULL;

        // Pick the best bitmap representation.
        NSBitmapImageRep *rep = nil;
        for (NSImageRep *r in [nsImage representations]) {
            if ([r isKindOfClass:[NSBitmapImageRep class]]) {
                rep = (NSBitmapImageRep *)r;
                break;
            }
        }
        if (!rep) {
            // Rasterise the image into an RGBA bitmap.
            NSSize sz = [nsImage size];
            if (sz.width <= 0 || sz.height <= 0) return NULL;
            rep = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL
                pixelsWide:(NSInteger)sz.width
                pixelsHigh:(NSInteger)sz.height
                bitsPerSample:8
                samplesPerPixel:4
                hasAlpha:YES
                isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                bytesPerRow:(NSInteger)(sz.width * 4)
                bitsPerPixel:32];
            if (!rep) return NULL;
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:
                [NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
            [nsImage drawInRect:NSMakeRect(0, 0, sz.width, sz.height)];
            [NSGraphicsContext restoreGraphicsState];
        }

        uint32_t w = (uint32_t)[rep pixelsWide];
        uint32_t h = (uint32_t)[rep pixelsHigh];
        if (w == 0 || h == 0) return NULL;

        // Convert to packed RGBA8, flipping vertical if needed.
        size_t byte_count = (size_t)w * (size_t)h * 4;
        uint8_t *buf = (uint8_t *)malloc(byte_count);
        if (!buf) return NULL;

        NSBitmapImageRep *rgbaRep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)w
            pixelsHigh:(NSInteger)h
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:(NSInteger)(w * 4)
            bitsPerPixel:32];
        if (!rgbaRep) { free(buf); return NULL; }

        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:
            [NSGraphicsContext graphicsContextWithBitmapImageRep:rgbaRep]];
        NSImage *tmp = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
        [tmp addRepresentation:rep];
        [tmp drawInRect:NSMakeRect(0, 0, w, h)];
        [NSGraphicsContext restoreGraphicsState];

        uint8_t *src = [rgbaRep bitmapData];
        if (!src) { free(buf); return NULL; }
        memcpy(buf, src, byte_count);

        *out_w = w;
        *out_h = h;
        return buf;
    }
}

/// Shutdown the graphics subsystem. Called at app exit.
@class GraphicsWindowManager;
static void gfx_window_manager_close_all(void);
void ed_graphics_shutdown(void) {
    if (g_gfx_startup_timer) {
        [g_gfx_startup_timer invalidate];
        g_gfx_startup_timer = nil;
    }

    if (g_gfx_controller_manager) {
        [g_gfx_controller_manager stopObserving];
        g_gfx_controller_manager = nil;
    }

    if (g_gfx_window_controller) {
        [g_gfx_window_controller destroyWindow];
        g_gfx_window_controller = nil;
    }

    if (g_menu_manager) {
        [g_menu_manager reset];
        g_menu_manager = nil;
    } else {
        gfx_menu_clear_events();
    }

    if (g_dialog_manager) {
        [g_dialog_manager reset];
        g_dialog_manager = nil;
    }

    // Close any auxiliary windows created through the window bridge.
    gfx_window_manager_close_all();
}

/// Check if the graphics window is currently active.
int ed_graphics_is_active(void) {
    return g_gfx_active ? 1 : 0;
}

// ─── Window System Exports ──────────────────────────────────────────────────
extern void gfx_window_define(double id, const void* title, double x, double y, double w, double h);
extern void gfx_window_control(double win_id, double kind, double ctl_id, const void* text, double x, double y, double w, double h);
extern void gfx_window_show(double id);
extern void gfx_window_hide(double id);
extern void gfx_window_close(double id);
extern void gfx_window_shutdown(void);
extern double gfx_window_poll(double* win_ptr, double* ctl_ptr);

// ─── Window Manager Implementation ──────────────────────────────────────────

@interface GraphicsWindow : NSWindow
@property (nonatomic, assign) uint16_t windowId;
@property (nonatomic, strong) NSMutableArray* controls; // To keep references
@end

@implementation GraphicsWindow
@end

// NSProgressIndicator inherits a read-only `tag` from NSView; subclass to make it writable.
@interface FBProgressIndicator : NSProgressIndicator
@property (nonatomic, assign) NSInteger tag;
@end
@implementation FBProgressIndicator
@synthesize tag = _tag;
@end

// NSStackView also exposes a read-only tag; provide a writable subclass for toolbars.
@interface FBToolbarStack : NSStackView
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, strong) CALayer* separator;
@end
@implementation FBToolbarStack
@synthesize tag = _tag;
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

        _separator = [CALayer layer];
        _separator.backgroundColor = [NSColor separatorColor].CGColor;
        [self.layer addSublayer:_separator];
    }
    return self;
}

- (void)layout {
    [super layout];
    const CGFloat line_h = 1.0;
    _separator.frame = CGRectMake(0, 0, self.bounds.size.width, line_h);
}
@end

// Status bar with three segments (left/middle/right), write-only via setSegments.
@interface FBStatusBar : NSView
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, strong) NSTextField* left;
@property (nonatomic, strong) NSTextField* middle;
@property (nonatomic, strong) NSTextField* right;
@property (nonatomic, strong) CALayer* separator;
- (void)setSegmentsLeft:(NSString*)l mid:(NSString*)m right:(NSString*)r;
@end

@implementation FBStatusBar
@synthesize tag = _tag;
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

        _separator = [CALayer layer];
        _separator.backgroundColor = [NSColor separatorColor].CGColor;
        [self.layer addSublayer:_separator];

        CGFloat h = frame.size.height > 0 ? frame.size.height : 20.0;
        CGFloat w = frame.size.width;
        CGFloat third = w / 3.0;
        _left = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, third, h)];
        _middle = [[NSTextField alloc] initWithFrame:NSMakeRect(third, 0, third, h)];
        _right = [[NSTextField alloc] initWithFrame:NSMakeRect(third * 2.0, 0, w - third * 2.0, h)];
        for (NSTextField* tf in @[_left, _middle, _right]) {
            tf.editable = NO;
            tf.bezeled = NO;
            tf.drawsBackground = NO;
            tf.backgroundColor = [NSColor clearColor];
            tf.font = [NSFont systemFontOfSize:12.0];
            tf.autoresizingMask = NSViewWidthSizable;
            [self addSubview:tf];
        }
        [self setSegmentsLeft:@"" mid:@"" right:@""];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    // Separator is drawn via CALayer; nothing else to paint here.
}

- (void)layout {
    [super layout];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat third = w / 3.0;
    self.left.frame = NSMakeRect(0, 0, third, h);
    self.middle.frame = NSMakeRect(third, 0, third, h);
    self.right.frame = NSMakeRect(third * 2.0, 0, w - third * 2.0, h);
    self.separator.frame = CGRectMake(0, h - 1.0, w, 1.0);
}

- (void)setSegmentsLeft:(NSString*)l mid:(NSString*)m right:(NSString*)r {
    self.left.stringValue = l ?: @"";
    self.middle.stringValue = m ?: @"";
    self.right.stringValue = r ?: @"";
}
@end

@interface FBTextAreaScrollView : NSScrollView
@property (nonatomic, assign) NSInteger tag;
@end
@implementation FBTextAreaScrollView
@synthesize tag = _tag;
@end

@interface GraphicsControl : NSControl // Or NSView container
@property (nonatomic, assign) uint16_t controlId;
@end

@implementation GraphicsControl
@end

static inline uintptr_t FBPtrFromDouble(double v) {
    uint64_t bits = 0;
    memcpy(&bits, &v, sizeof(double));
    return (uintptr_t)bits;
}

static NSColor* FBColorFromDouble(double v) {
    if (v >= 0.0 && v <= 1.0) {
        return [NSColor colorWithWhite:(CGFloat)v alpha:1.0];
    }
    uint32_t raw = (uint32_t)llround(v);
    uint8_t a = (raw > 0xFFFFFF) ? (uint8_t)((raw >> 24) & 0xFF) : 0xFF;
    uint8_t r = (uint8_t)((raw >> 16) & 0xFF);
    uint8_t g = (uint8_t)((raw >> 8) & 0xFF);
    uint8_t b = (uint8_t)(raw & 0xFF);
    return [NSColor colorWithRed:(CGFloat)r / 255.0
                           green:(CGFloat)g / 255.0
                            blue:(CGFloat)b / 255.0
                           alpha:(CGFloat)a / 255.0];
}

@interface CanvasCommand : NSObject {
    double _args[7];
}
@property (nonatomic, assign) uint8_t op;
@property (nonatomic, copy) NSString* text;
@property (nonatomic, strong) NSArray<NSValue*>* points;
- (void)setArg:(NSUInteger)idx value:(double)v;
- (double)argAt:(NSUInteger)idx;
@end

@implementation CanvasCommand
- (instancetype)init {
    self = [super init];
    if (self) {
        memset(_args, 0, sizeof(_args));
    }
    return self;
}

- (void)setArg:(NSUInteger)idx value:(double)v {
    if (idx < 7) _args[idx] = v;
}

- (double)argAt:(NSUInteger)idx {
    if (idx < 7) return _args[idx];
    return 0.0;
}
@end

static uint16_t g_canvas_backing_seed = 60000;
static BOOL g_canvas_base_post_aa = YES;
static CIContext *g_canvas_ci_context = nil;

static CIContext *fb_canvas_ci_context(void) {
    if (!g_canvas_ci_context) {
        g_canvas_ci_context = [CIContext contextWithOptions:@{}];
    }
    return g_canvas_ci_context;
}

static uint16_t fb_canvas_allocate_backing_id(void) {
    for (int i = 0; i < 4096; i += 1) {
        if (g_canvas_backing_seed < 50000) g_canvas_backing_seed = 60000;
        uint16_t candidate = g_canvas_backing_seed--;
        if (gfx_image_exists((double)candidate) == 0.0) return candidate;
    }
    return 0;
}

@interface FBCanvasView : NSView
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic) CGSize logicalSize;
@property (nonatomic) CGSize virtualSize;
@property (nonatomic, assign) uint16_t backingImageId;
@property (nonatomic, assign) uint32_t backingWidth;
@property (nonatomic, assign) uint32_t backingHeight;
- (void)syncBackingImageSize;
- (void)applyCanvasBatch:(const uint8_t*)data len:(uint32_t)len;
- (void)applyCanvasOp:(uint8_t)op args:(const double*)args count:(uint32_t)count text:(NSString*)text;
@end

@implementation FBCanvasView
@synthesize tag = _tag;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _logicalSize = frame.size;
        _virtualSize = frame.size;
        _backingImageId = 0;
        _backingWidth = 0;
        _backingHeight = 0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        [self syncBackingImageSize];
    }
    return self;
}

- (void)dealloc {
    if (_backingImageId != 0) {
        gfx_image_destroy((double)_backingImageId);
        _backingImageId = 0;
    }
    _backingWidth = 0;
    _backingHeight = 0;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setVirtualSize:(CGSize)virtualSize {
    _virtualSize = virtualSize;
    [self setFrameSize:virtualSize];
}

- (void)syncBackingImageSize {
    CGSize logical = self.logicalSize;
    if (logical.width <= 0.0 || logical.height <= 0.0) logical = self.bounds.size;
    uint32_t w = (uint32_t)MAX(1.0, round(logical.width));
    uint32_t h = (uint32_t)MAX(1.0, round(logical.height));

    if (self.backingImageId == 0) {
        self.backingImageId = fb_canvas_allocate_backing_id();
    }
    if (self.backingImageId == 0) return;

    if (self.backingWidth == w && self.backingHeight == h && gfx_image_exists((double)self.backingImageId) != 0.0) {
        return;
    }

    (void)gfx_image_define((double)self.backingImageId, (double)w, (double)h, 1.0);
    self.backingWidth = w;
    self.backingHeight = h;
}

- (void)applyCanvasBatch:(const uint8_t*)data len:(uint32_t)len {
    if (!data || len < 4) return;
    [self syncBackingImageSize];
    if (self.backingImageId == 0) return;
    (void)gfx_image_apply_batch_raw((double)self.backingImageId, data, (double)len);
    [self setNeedsDisplay:YES];
}

- (void)applyCanvasOp:(uint8_t)op args:(const double*)args count:(uint32_t)count text:(NSString*)text {
    NSMutableData *batch = [NSMutableData data];
    if (!batch) return;

    if ((op == 10 || op == 11) && count >= 2 && args != NULL) {
        uintptr_t ptr = FBPtrFromDouble(args[0]);
        uint32_t pointCount = (uint32_t)MAX(0.0, args[1]);
        if (ptr == 0 || pointCount == 0 || pointCount > 4096) return;

        uint8_t header[4] = {op, 0, 0, 0};
        uint32_t coordCount = pointCount * 2;
        if (coordCount > 254) coordCount = 254;
        header[1] = (uint8_t)coordCount;
        [batch appendBytes:header length:4];

        const double *coords = (const double *)ptr;
        [batch appendBytes:coords length:(NSUInteger)coordCount * sizeof(double)];
        [self applyCanvasBatch:batch.bytes len:(uint32_t)batch.length];
        return;
    }

    uint8_t cmdCount = (uint8_t)MIN(count, 7);
    const char *textBytes = NULL;
    uint16_t textLen = 0;
    if (op == 3 && text.length > 0) {
        NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8.length > 0) {
            textBytes = (const char *)utf8.bytes;
            textLen = (uint16_t)MIN((NSUInteger)UINT16_MAX, utf8.length);
        }
    }

    uint8_t header[4] = { op, cmdCount, (uint8_t)(textLen & 0xFF), (uint8_t)((textLen >> 8) & 0xFF) };
    [batch appendBytes:header length:4];

    if (cmdCount > 0) {
        double local[7] = {0};
        if (args != NULL) memcpy(local, args, (NSUInteger)cmdCount * sizeof(double));
        [batch appendBytes:local length:(NSUInteger)cmdCount * sizeof(double)];
    }
    if (textLen > 0 && textBytes != NULL) {
        [batch appendBytes:textBytes length:textLen];
    }

    [self applyCanvasBatch:batch.bytes len:(uint32_t)batch.length];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    [[NSColor whiteColor] setFill];
    NSRectFill(self.bounds);

    if (self.backingImageId == 0) return;

    const double ptr_val = gfx_image_get_rgba_ptr((double)self.backingImageId);
    if (ptr_val == 0.0) return;
    const size_t width = (size_t)MAX(0.0, gfx_image_width((double)self.backingImageId));
    const size_t height = (size_t)MAX(0.0, gfx_image_height((double)self.backingImageId));
    const size_t stride = (size_t)MAX(0.0, gfx_image_get_stride((double)self.backingImageId));
    if (width == 0 || height == 0 || stride < width * 4) return;

    const uint8_t *pixels = (const uint8_t *)(uintptr_t)llround(ptr_val);
    if (!pixels) return;

    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return;

    const size_t byteCount = stride * height;
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, byteCount, NULL);
    if (!provider) {
        CGColorSpaceRelease(cs);
        return;
    }

    CGBitmapInfo bitmapInfo = (CGBitmapInfo)(kCGImageAlphaLast | kCGBitmapByteOrderDefault);
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, cs, bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!image) return;

    CGImageRef drawImage = image;
    CGImageRef processedImage = NULL;

    if (g_canvas_base_post_aa) {
        @autoreleasepool {
            CIImage *input = [CIImage imageWithCGImage:image options:nil];
            if (input) {
                CIFilter *nr = [CIFilter filterWithName:@"CINoiseReduction"];
                if (nr) {
                    [nr setValue:input forKey:kCIInputImageKey];
                    [nr setValue:@0.02 forKey:@"inputNoiseLevel"];
                    [nr setValue:@0.35 forKey:@"inputSharpness"];
                    CIImage *out = nr.outputImage;
                    if (out) {
                        CIContext *ciCtx = fb_canvas_ci_context();
                        if (ciCtx) {
                            processedImage = [ciCtx createCGImage:out fromRect:input.extent];
                            if (processedImage) drawImage = processedImage;
                        }
                    }
                }
            }
        }
    }

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0.0, self.bounds.size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height), drawImage);
    CGContextRestoreGState(ctx);

    if (processedImage) CGImageRelease(processedImage);
    CGImageRelease(image);
}
@end

// NSScrollView with writable tag support for canvas controls.
@interface FBCanvasScrollView : NSScrollView
@property (nonatomic, assign) NSInteger tag;
@end
@implementation FBCanvasScrollView
@synthesize tag = _tag;
@end

@interface GraphicsWindowManager : NSObject <NSTextViewDelegate, NSComboBoxDelegate> {
    struct { uint16_t win; uint16_t ctl; uint8_t type; uint16_t row; uint16_t col; double value; } _eventQueue[64];
    int _eventHead;
    int _eventTail;
    // Last matrix-cell-edit event data (set on poll when type==2)
    uint16_t _lastMatrixRow;
    uint16_t _lastMatrixCol;
    double   _lastMatrixVal;
}
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, id>* windows; // id usually, but let's keep it specific if I defined GraphicsWindow
@property (nonatomic, strong) NSLock* lock;
- (uint8_t)pollEvent:(uint16_t*)winOut control:(uint16_t*)ctlOut;
- (uint8_t)hasWindows;
- (void)enqueueMatrixEvent:(uint16_t)winId control:(uint16_t)ctlId row:(uint16_t)row col:(uint16_t)col value:(double)value;
- (uint16_t)lastMatrixRow;
- (uint16_t)lastMatrixCol;
- (double)lastMatrixVal;
- (NSString*)textForControl:(uint16_t)windowId controlId:(uint16_t)controlId;
- (void)canvasOpForWindow:(uint16_t)windowId controlId:(uint16_t)controlId op:(uint8_t)op args:(const double*)args count:(uint32_t)count text:(NSString*)text;
- (void)canvasSetVirtualSize:(uint16_t)windowId controlId:(uint16_t)controlId w:(double)w h:(double)h;
- (void)canvasSetViewport:(uint16_t)windowId controlId:(uint16_t)controlId x:(double)x y:(double)y;
- (void)canvasSetResolution:(uint16_t)windowId controlId:(uint16_t)controlId w:(double)w h:(double)h;
- (void)canvasDispatch:(uint16_t)windowId controlId:(uint16_t)controlId data:(const uint8_t*)data len:(uint32_t)len;
- (void)closeAll;
- (void)shutdown;
@end

@implementation GraphicsWindowManager

+ (instancetype)sharedManager {
    static GraphicsWindowManager* manager = nil;
    @synchronized(self) {
        if (manager == nil) {
            manager = [[GraphicsWindowManager alloc] init];
        }
    }
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _eventHead = 0;
        _eventTail = 0;
    }
    return self;
}

- (void)enqueueEvent:(uint16_t)winId control:(uint16_t)ctlId {
    [_lock lock];
    // Deduplicate type-1 events for the same (win, ctl) pair
    for (int i = _eventHead; i != _eventTail; i = (i + 1) % 64) {
        if (_eventQueue[i].type == 1 && _eventQueue[i].win == winId && _eventQueue[i].ctl == ctlId) {
            [_lock unlock];
            return;
        }
    }
    int next = (_eventTail + 1) % 64;
    if (next != _eventHead) {
        _eventQueue[_eventTail].win   = winId;
        _eventQueue[_eventTail].ctl   = ctlId;
        _eventQueue[_eventTail].type  = 1;
        _eventQueue[_eventTail].row   = 0;
        _eventQueue[_eventTail].col   = 0;
        _eventQueue[_eventTail].value = 0;
        _eventTail = next;
    }
    [_lock unlock];
}

- (void)enqueueMatrixEvent:(uint16_t)winId control:(uint16_t)ctlId row:(uint16_t)row col:(uint16_t)col value:(double)value {
    [_lock lock];
    int next = (_eventTail + 1) % 64;
    if (next != _eventHead) {
        _eventQueue[_eventTail].win   = winId;
        _eventQueue[_eventTail].ctl   = ctlId;
        _eventQueue[_eventTail].type  = 2;
        _eventQueue[_eventTail].row   = row;
        _eventQueue[_eventTail].col   = col;
        _eventQueue[_eventTail].value = value;
        _eventTail = next;
    }
    [_lock unlock];
}

- (uint16_t)lastMatrixRow { return _lastMatrixRow; }
- (uint16_t)lastMatrixCol { return _lastMatrixCol; }
- (double)lastMatrixVal   { return _lastMatrixVal; }

- (NSView*)controlInWindow:(GraphicsWindow*)win controlId:(uint16_t)controlId {
    NSInteger tag = ((NSInteger)win.windowId << 16) | controlId;
    for (NSView* ctl in win.controls) {
        if (ctl.tag == tag) return ctl;
    }
    return nil;
}

- (FBCanvasView*)canvasForWindow:(GraphicsWindow*)win controlId:(uint16_t)controlId {
    NSView* ctl = [self controlInWindow:win controlId:controlId];
    if ([ctl isKindOfClass:[FBCanvasScrollView class]]) {
        NSView* doc = ((NSScrollView*)ctl).documentView;
        if ([doc isKindOfClass:[FBCanvasView class]]) return (FBCanvasView*)doc;
    } else if ([ctl isKindOfClass:[FBCanvasView class]]) {
        return (FBCanvasView*)ctl;
    }
    return nil;
}

- (uint8_t)pollEvent:(uint16_t*)winOut control:(uint16_t*)ctlOut {
    [_lock lock];
    if (_eventHead == _eventTail) {
        [_lock unlock];
        return 0;
    }
    *winOut = _eventQueue[_eventHead].win;
    *ctlOut = _eventQueue[_eventHead].ctl;
    uint8_t type = _eventQueue[_eventHead].type;
    if (type == 2) {
        _lastMatrixRow = _eventQueue[_eventHead].row;
        _lastMatrixCol = _eventQueue[_eventHead].col;
        _lastMatrixVal = _eventQueue[_eventHead].value;
    }
    _eventHead = (_eventHead + 1) % 64;
    [_lock unlock];
    return type;
}

- (uint8_t)hasWindows {
    __block uint8_t has = 0;
    void (^work)(void) = ^{
        has = self.windows.count > 0 ? 1 : 0;
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return has;
}

- (void)defineWindow:(uint16_t)windowId title:(NSString*)title x:(uint16_t)x y:(uint16_t)y w:(uint16_t)w h:(uint16_t)h {
    void (^work)(void) = ^{
    //    NSLog(@"[GFX] defineWindow id=%u title=%@ x=%u y=%u w=%u h=%u", windowId, title, x, y, w, h);
        if (self.windows[@(windowId)]) {
            [self.windows[@(windowId)] close];
            [self.windows removeObjectForKey:@(windowId)];
        }
        
        NSRect frame = NSMakeRect(x, [NSScreen mainScreen].frame.size.height - y - h, w, h);
        GraphicsWindow* win = [[GraphicsWindow alloc] initWithContentRect:frame
                                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                                 backing:NSBackingStoreBuffered
                                                                   defer:NO];
        win.releasedWhenClosed = NO;  // ARC manages lifetime; prevent double-free
        win.windowId = windowId;
        win.title = title;
        win.controls = [NSMutableArray array];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:win];

        self.windows[@(windowId)] = win;
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

- (void)windowWillClose:(NSNotification*)note {
    GraphicsWindow* win = note.object;
    if ([win isKindOfClass:[GraphicsWindow class]]) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:win];
        [self enqueueEvent:win.windowId control:0];
        [self.windows removeObjectForKey:@(win.windowId)];
    }
}

- (void)controlAction:(NSControl*)sender {
//    NSLog(@"[GFX] controlAction: class=%@ tag=%ld", [sender class], (long)sender.tag);
    if ([sender isKindOfClass:[NSControl class]]) {
        NSInteger tag = sender.tag;
        uint16_t winId = (uint16_t)(tag >> 16);
        uint16_t ctlId = (uint16_t)(tag & 0xFFFF);
//        NSLog(@"[GFX] controlAction: decoded winId=%u ctlId=%u", winId, ctlId);
        if (winId > 0) {
            [self enqueueEvent:winId control:ctlId];
        }
    }
}

// NSTextViewDelegate — fires on every keystroke in a TEXTAREA
- (void)textDidChange:(NSNotification*)notification {
    NSTextView* tv = (NSTextView*)notification.object;
    FBTextAreaScrollView* scrollView = (FBTextAreaScrollView*)tv.enclosingScrollView;
    NSInteger tag = scrollView.tag;
    uint16_t winId = (uint16_t)(tag >> 16);
    uint16_t ctlId = (uint16_t)(tag & 0xFFFF);
    if (winId > 0) [self enqueueEvent:winId control:ctlId];
}

// NSComboBoxDelegate — fires when user selects from the COMBOBOX dropdown
- (void)comboBoxSelectionDidChange:(NSNotification*)notification {
    NSComboBox* combo = (NSComboBox*)notification.object;
    NSInteger tag = combo.tag;
    uint16_t winId = (uint16_t)(tag >> 16);
    uint16_t ctlId = (uint16_t)(tag & 0xFFFF);
    if (winId > 0) [self enqueueEvent:winId control:ctlId];
}

- (NSString*)textForControl:(uint16_t)windowId controlId:(uint16_t)controlId {
    __block NSString* result = @"";
    void (^work)(void) = ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) {
            NSView* ctl = [self controlInWindow:win controlId:controlId];
            if ([ctl isKindOfClass:[FBTextAreaScrollView class]]) {
                NSTextView* tv = (NSTextView*)((NSScrollView*)ctl).documentView;
                if ([tv isKindOfClass:[NSTextView class]]) result = tv.string;
            } else if ([ctl isKindOfClass:[NSTextField class]]) {
                result = ((NSTextField*)ctl).stringValue;
            } else if ([ctl isKindOfClass:[NSPopUpButton class]]) {
                result = ((NSPopUpButton*)ctl).titleOfSelectedItem ?: @"";
            } else if ([ctl isKindOfClass:[NSButton class]]) {
                result = ((NSButton*)ctl).title;
            }
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

- (void)addControlTo:(uint16_t)windowId kind:(uint8_t)kind controlId:(uint16_t)controlId text:(NSString*)text x:(uint16_t)x y:(uint16_t)y w:(uint16_t)w h:(uint16_t)h {
    void (^work)(void) = ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        
        NSView* contentView = win.contentView;
        NSRect frame = NSMakeRect(x, h > 0 ? (win.contentView.frame.size.height - y - h) : (win.contentView.frame.size.height - y - 24), w, h > 0 ? h : 24);

        // Auto-dock status bars to the bottom and span the full content width.
        if (kind == 11) {
            frame.origin.y = 0;
            frame.origin.x = 0;
            frame.size.height = h > 0 ? h : 24;
            frame.size.width = contentView.frame.size.width;
        }

        // Auto-dock toolbars to the top and span the full content width.
        if (kind == 10) {
            frame.origin.x = 0;
            frame.size.height = h > 0 ? h : 28;
            frame.size.width = contentView.frame.size.width;
            frame.origin.y = contentView.frame.size.height - frame.size.height;
        }

        NSView* existing = [self controlInWindow:win controlId:controlId];
        if (existing) {
            // Check whether the existing control's class matches the requested kind.
            BOOL typeMatch = NO;
            if (kind == 0 && [existing isKindOfClass:[NSButton class]] && !([existing isKindOfClass:[NSPopUpButton class]])) typeMatch = YES;
            else if (kind == 1 && [existing isKindOfClass:[NSTextField class]] && ((NSTextField*)existing).isEditable && ![existing isKindOfClass:[NSSecureTextField class]] && ![existing isKindOfClass:[NSComboBox class]]) typeMatch = YES;
            else if (kind == 2 && [existing isKindOfClass:[NSTextField class]] && !((NSTextField*)existing).isEditable) typeMatch = YES;
            else if (kind == 3 && [existing isKindOfClass:[NSButton class]] && !([existing isKindOfClass:[NSPopUpButton class]])) typeMatch = YES; // checkbox
            else if (kind == 4 && [existing isKindOfClass:[NSPopUpButton class]]) typeMatch = YES;
            else if (kind == 5 && [existing isKindOfClass:[NSSecureTextField class]]) typeMatch = YES;
            else if (kind == 8 && [existing isKindOfClass:[FBTextAreaScrollView class]]) typeMatch = YES;
            else if (kind == 9 && [existing isKindOfClass:[NSComboBox class]]) typeMatch = YES;
            else if (kind == 10 && [existing isKindOfClass:[FBToolbarStack class]]) typeMatch = YES;
            else if (kind == 11 && [existing isKindOfClass:[FBStatusBar class]]) typeMatch = YES;
            else if (kind == 12 && ([existing isKindOfClass:[FBCanvasScrollView class]] || [existing isKindOfClass:[FBCanvasView class]])) typeMatch = YES;

            if (typeMatch) {
                // Same type – update in place if anything changed.
                NSString* newText = text ? text : @"";
                BOOL sameFrame = NSEqualRects(existing.frame, frame);
                BOOL sameText = YES;
                if ([existing isKindOfClass:[FBTextAreaScrollView class]]) {
                    NSTextView* tv = (NSTextView*)((NSScrollView*)existing).documentView;
                    sameText = [tv isKindOfClass:[NSTextView class]] ? [tv.string isEqualToString:newText] : YES;
                } else if ([existing isKindOfClass:[NSButton class]]) {
                    sameText = [((NSButton*)existing).title isEqualToString:newText];
                } else if ([existing isKindOfClass:[NSTextField class]]) {
                    sameText = [((NSTextField*)existing).stringValue isEqualToString:newText];
                }

                if (sameFrame && sameText) return; // skip redundant update

//                NSLog(@"[GFX] updateControl win=%u ctl=%u kind=%u x=%u y=%u w=%u h=%u", windowId, controlId, kind, x, y, w, h);
                existing.frame = frame;
                if (kind == 0 && [existing isKindOfClass:[NSButton class]]) {
                    ((NSButton*)existing).title = newText;
                } else if (kind == 3 && [existing isKindOfClass:[NSButton class]]) {
                    ((NSButton*)existing).title = newText;
                } else if (kind == 4 && [existing isKindOfClass:[NSPopUpButton class]]) {
                    // Rebuild popup items from pipe-separated text
                    NSPopUpButton* popup = (NSPopUpButton*)existing;
                    [popup removeAllItems];
                    NSArray<NSString*>* items = [newText componentsSeparatedByString:@"|"];
                    for (NSString* item in items) {
                        [popup addItemWithTitle:[item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
                    }
                } else if (kind == 5 && [existing isKindOfClass:[NSSecureTextField class]]) {
                    ((NSSecureTextField*)existing).placeholderString = newText;
                } else if ((kind == 1 || kind == 2) && [existing isKindOfClass:[NSTextField class]]) {
                    NSTextField* tf = (NSTextField*)existing;
                    tf.stringValue = newText;
                    if (kind == 2) {
                        tf.editable = NO;
                        tf.bezeled = NO;
                        tf.drawsBackground = NO;
                    }
                } else if (kind == 8 && [existing isKindOfClass:[FBTextAreaScrollView class]]) {
                    NSTextView* tv = (NSTextView*)((NSScrollView*)existing).documentView;
                    if ([tv isKindOfClass:[NSTextView class]]) tv.string = newText;
                } else if (kind == 9 && [existing isKindOfClass:[NSComboBox class]]) {
                    NSComboBox* combo = (NSComboBox*)existing;
                    [combo removeAllItems];
                    NSArray<NSString*>* items = [newText componentsSeparatedByString:@"|"];
                    for (NSString* item in items) {
                        NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (trimmed.length > 0) [combo addItemWithObjectValue:trimmed];
                    }
                } else if (kind == 10 && [existing isKindOfClass:[FBToolbarStack class]]) {
                    FBToolbarStack* stack = (FBToolbarStack*)existing;
                    for (NSView* v in [stack.arrangedSubviews copy]) [stack removeArrangedSubview:v], [v removeFromSuperview];
                    NSArray<NSString*>* items = [newText componentsSeparatedByString:@"|"];
                    NSInteger idx = 0;
                    for (NSString* item in items) {
                        NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (trimmed.length == 0) continue;
                        NSButton* btn = [NSButton buttonWithTitle:trimmed target:self action:@selector(controlAction:)];
                        btn.bezelStyle = NSBezelStyleTexturedRounded;
                        btn.tag = ((NSInteger)windowId << 16) | (controlId + idx);
                        [stack addArrangedSubview:btn];
                        idx += 1;
                    }
                    stack.spacing = 6.0;
                } else if (kind == 11 && [existing isKindOfClass:[FBStatusBar class]]) {
                    FBStatusBar* bar = (FBStatusBar*)existing;
                    NSArray<NSString*>* parts = [newText componentsSeparatedByString:@"|"];
                    NSString* l = parts.count > 0 ? parts[0] : @"";
                    NSString* m = parts.count > 1 ? parts[1] : @"";
                    NSString* r = parts.count > 2 ? parts[2] : @"";
                    [bar setSegmentsLeft:l mid:m right:r];
                } else if (kind == 12 && [existing isKindOfClass:[FBCanvasScrollView class]]) {
                    existing.frame = frame;
                    NSView* doc = ((NSScrollView*)existing).documentView;
                    if ([doc isKindOfClass:[FBCanvasView class]]) {
                        doc.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
                        [doc setNeedsDisplay:YES];
                    }
                }
                [existing setNeedsDisplay:YES];
                return;
            }

            // Type mismatch – remove the old control so we can recreate it below.
//            NSLog(@"[GFX] replaceControl (type change) win=%u ctl=%u newKind=%u", windowId, controlId, kind);
            [existing removeFromSuperview];
            [win.controls removeObject:existing];
        }

        // Suppress implicit animation only for initial control creation.
        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setAllowsImplicitAnimation:NO];
        
        NSControl* ctl = nil;
        if (kind == 0) { // Button
//            NSLog(@"[GFX] addControl BUTTON win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSButton* btn = [[NSButton alloc] initWithFrame:frame];
            btn.title = text;
            btn.bezelStyle = NSBezelStyleRounded;
            btn.target = self;
            btn.action = @selector(controlAction:);
            ctl = btn;
        } else if (kind == 1) { // TextField
//            NSLog(@"[GFX] addControl TEXTFIELD win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSTextField* txt = [[NSTextField alloc] initWithFrame:frame];
            txt.stringValue = text ? text : @"";
            txt.editable = YES;
            txt.bezeled = YES;
            txt.target = self;
            txt.action = @selector(controlAction:);
            ctl = txt;
        } else if (kind == 2) { // Label
//            NSLog(@"[GFX] addControl LABEL win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSTextField* lbl = [[NSTextField alloc] initWithFrame:frame];
            lbl.stringValue = text ? text : @"";
            lbl.editable = NO;
            lbl.bezeled = NO;
            lbl.drawsBackground = NO;
            ctl = lbl;
        } else if (kind == 3) { // Checkbox
//            NSLog(@"[GFX] addControl CHECKBOX win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSButton* chk = [[NSButton alloc] initWithFrame:frame];
            [chk setButtonType:NSButtonTypeSwitch];
            chk.title = text ? text : @"";
            chk.state = NSControlStateValueOff;
            chk.target = self;
            chk.action = @selector(controlAction:);
            ctl = chk;
        } else if (kind == 4) { // Popup (NSPopUpButton)
//            NSLog(@"[GFX] addControl POPUP win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
            // text is pipe-separated list of items: "Item1|Item2|Item3"
            NSString* itemsStr = text ? text : @"";
            NSArray<NSString*>* items = [itemsStr componentsSeparatedByString:@"|"];
            for (NSString* item in items) {
                NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 0) [popup addItemWithTitle:trimmed];
            }
            popup.target = self;
            popup.action = @selector(controlAction:);
            ctl = popup;
        } else if (kind == 5) { // SecureTextField (NSSecureTextField)
//            NSLog(@"[GFX] addControl SECUREFIELD win=%u ctl=%u x=%u y=%u w=%u h=%u", windowId, controlId, x, y, w, h);
            NSSecureTextField* sec = [[NSSecureTextField alloc] initWithFrame:frame];
            sec.placeholderString = text ? text : @"";
            sec.stringValue = @"";
            sec.editable = YES;
            sec.bezeled = YES;
            sec.target = self;
            sec.action = @selector(controlAction:);
            ctl = sec;
        } else if (kind == 8) { // TEXTAREA (FBTextAreaScrollView + NSTextView)
            FBTextAreaScrollView* scrollView = [[FBTextAreaScrollView alloc] initWithFrame:frame];
            scrollView.hasVerticalScroller = YES;
            scrollView.hasHorizontalScroller = NO;
            scrollView.autohidesScrollers = YES;
            scrollView.borderType = NSBezelBorder;
            NSRect tvBounds = scrollView.contentView.bounds;
            NSTextView* textView = [[NSTextView alloc] initWithFrame:tvBounds];
            textView.minSize = NSMakeSize(0.0, 0.0);
            textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
            textView.verticallyResizable = YES;
            textView.horizontallyResizable = NO;
            textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            textView.textContainer.widthTracksTextView = YES;
            textView.editable = YES;
            textView.selectable = YES;
            textView.richText = NO;
            textView.delegate = self;
            textView.string = text ? text : @"";
            scrollView.tag = ((NSInteger)windowId << 16) | controlId;
            scrollView.documentView = textView;
            [contentView addSubview:scrollView];
            [win.controls addObject:scrollView];
            // ctl stays nil; scrollView added directly above
        } else if (kind == 9) { // COMBOBOX (NSComboBox)
            NSComboBox* combo = [[NSComboBox alloc] initWithFrame:frame];
            combo.usesDataSource = NO;
            combo.completes = NO;
            combo.editable = YES;
            NSString* itemsStr = text ? text : @"";
            NSArray<NSString*>* comboItems = [itemsStr componentsSeparatedByString:@"|"];
            for (NSString* item in comboItems) {
                NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 0) [combo addItemWithObjectValue:trimmed];
            }
            combo.target = self;
            combo.action = @selector(controlAction:);
            combo.delegate = self;
            ctl = combo;
        } else if (kind == 10) { // TOOLBAR (stack of buttons)
            FBToolbarStack* stack = [[FBToolbarStack alloc] initWithFrame:frame];
            stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            stack.alignment = NSLayoutAttributeCenterY;
            stack.spacing = 6.0;
            stack.tag = ((NSInteger)windowId << 16) | controlId;
            stack.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
            NSArray<NSString*>* items = [text componentsSeparatedByString:@"|"];
            NSInteger idx = 0;
            for (NSString* item in items) {
                NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length == 0) continue;
                NSButton* btn = [NSButton buttonWithTitle:trimmed target:self action:@selector(controlAction:)];
                btn.bezelStyle = NSBezelStyleTexturedRounded;
                btn.tag = ((NSInteger)windowId << 16) | (controlId + idx);
                [stack addArrangedSubview:btn];
                idx += 1;
            }
            [contentView addSubview:stack];
            [win.controls addObject:stack];
        } else if (kind == 11) { // STATUSBAR (FBStatusBar with 3 segments)
            FBStatusBar* bar = [[FBStatusBar alloc] initWithFrame:frame];
            bar.tag = ((NSInteger)windowId << 16) | controlId;
            bar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
            NSArray<NSString*>* parts = [text componentsSeparatedByString:@"|"];
            NSString* l = parts.count > 0 ? parts[0] : @"";
            NSString* m = parts.count > 1 ? parts[1] : @"";
            NSString* r = parts.count > 2 ? parts[2] : @"";
            [bar setSegmentsLeft:l mid:m right:r];
            [contentView addSubview:bar];
            [win.controls addObject:bar];
        } else if (kind == 12) { // CANVAS
            FBCanvasView* canvas = [[FBCanvasView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
            canvas.tag = ((NSInteger)windowId << 16) | controlId;
            FBCanvasScrollView* scroll = [[FBCanvasScrollView alloc] initWithFrame:frame];
            scroll.borderType = NSNoBorder;
            scroll.hasVerticalScroller = YES;
            scroll.hasHorizontalScroller = YES;
            scroll.autohidesScrollers = YES;
            scroll.drawsBackground = YES;
            scroll.backgroundColor = [NSColor controlBackgroundColor];
            scroll.documentView = canvas;
            scroll.tag = ((NSInteger)windowId << 16) | controlId;
            scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [contentView addSubview:scroll];
            [win.controls addObject:scroll];
        }
        
        if (ctl) {
            ctl.tag = (windowId << 16) | controlId;
            [contentView addSubview:ctl];
            [win.controls addObject:ctl];
        }

        [NSAnimationContext endGrouping];
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

- (void)setTextForWindowControl:(uint16_t)windowId controlId:(uint16_t)controlId text:(NSString*)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        NSView* ctl = [self controlInWindow:win controlId:controlId];
        if (!ctl) return;
        if ([ctl isKindOfClass:[FBTextAreaScrollView class]]) {
            NSTextView* tv = (NSTextView*)((FBTextAreaScrollView*)ctl).documentView;
            if ([tv isKindOfClass:[NSTextView class]]) tv.string = text ? text : @"";
        } else if ([ctl isKindOfClass:[NSSecureTextField class]]) {
            ((NSSecureTextField*)ctl).stringValue = text ? text : @"";
        } else if ([ctl isKindOfClass:[NSTextField class]]) {
            ((NSTextField*)ctl).stringValue = text ? text : @"";
        } else if ([ctl isKindOfClass:[NSPopUpButton class]]) {
            [((NSPopUpButton*)ctl) selectItemWithTitle:text ?: @""];
        } else if ([ctl isKindOfClass:[NSButton class]]) {
            ((NSButton*)ctl).title = text ? text : @"";
        } else if ([ctl isKindOfClass:[FBToolbarStack class]]) {
            FBToolbarStack* stack = (FBToolbarStack*)ctl;
            for (NSView* v in [stack.arrangedSubviews copy]) {
                [stack removeArrangedSubview:v];
                [v removeFromSuperview];
            }
            NSArray<NSString*>* items = [text componentsSeparatedByString:@"|"];
            NSInteger idx = 0;
            for (NSString* item in items) {
                NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length == 0) continue;
                NSButton* btn = [NSButton buttonWithTitle:trimmed target:self action:@selector(controlAction:)];
                btn.bezelStyle = NSBezelStyleTexturedRounded;
                btn.tag = ((NSInteger)windowId << 16) | (controlId + idx);
                [stack addArrangedSubview:btn];
                idx += 1;
            }
        } else if ([ctl isKindOfClass:[FBStatusBar class]]) {
            FBStatusBar* bar = (FBStatusBar*)ctl;
            NSArray<NSString*>* parts = [text componentsSeparatedByString:@"|"];
            NSString* l = parts.count > 0 ? parts[0] : @"";
            NSString* m = parts.count > 1 ? parts[1] : @"";
            NSString* r = parts.count > 2 ? parts[2] : @"";
            [bar setSegmentsLeft:l mid:m right:r];
        }
        [ctl setNeedsDisplay:YES];
    });
}

- (void)setEnabledForControl:(uint16_t)windowId controlId:(uint16_t)controlId enabled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        NSView* ctl = [self controlInWindow:win controlId:controlId];
        if (ctl && [ctl respondsToSelector:@selector(setEnabled:)]) {
            [(NSControl*)ctl setEnabled:enabled];
            [ctl setNeedsDisplay:YES];
        }
    });
}

- (void)setTitleForWindow:(uint16_t)windowId title:(NSString*)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) {
            win.title = title ? title : @"";
        }
    });
}

- (uint8_t)checkedForControl:(uint16_t)windowId controlId:(uint16_t)controlId {
    __block uint8_t result = 0;
    void (^work)(void) = ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) {
            NSView* ctl = [self controlInWindow:win controlId:controlId];
            if ([ctl isKindOfClass:[NSButton class]]) {
                result = ((NSButton*)ctl).state == NSControlStateValueOn ? 1 : 0;
            }
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

- (void)addRangedControlTo:(uint16_t)windowId kind:(uint8_t)kind controlId:(uint16_t)controlId min:(double)minVal max:(double)maxVal x:(uint16_t)x y:(uint16_t)y w:(uint16_t)w h:(uint16_t)h {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;

        NSView* contentView = win.contentView;
        NSRect frame = NSMakeRect(x, h > 0 ? (contentView.frame.size.height - y - h) : (contentView.frame.size.height - y - 24), w, h > 0 ? h : 24);

        // Remove existing control with same ID if present
        NSView* existing = [self controlInWindow:win controlId:controlId];
        if (existing) {
            [existing removeFromSuperview];
            [win.controls removeObject:existing];
        }

        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setAllowsImplicitAnimation:NO];

        if (kind == 6) { // Slider
//            NSLog(@"[GFX] addControl SLIDER win=%u ctl=%u min=%g max=%g x=%u y=%u w=%u h=%u", windowId, controlId, minVal, maxVal, x, y, w, h);
            NSSlider* slider = [[NSSlider alloc] initWithFrame:frame];
            slider.minValue = minVal;
            slider.maxValue = maxVal;
            slider.doubleValue = minVal;
            slider.continuous = YES;
            slider.target = self;
            slider.action = @selector(controlAction:);
            slider.tag = ((NSInteger)windowId << 16) | controlId;
            [contentView addSubview:slider];
            [win.controls addObject:slider];
        } else if (kind == 7) { // Progress Indicator
//            NSLog(@"[GFX] addControl PROGRESS win=%u ctl=%u min=%g max=%g x=%u y=%u w=%u h=%u", windowId, controlId, minVal, maxVal, x, y, w, h);
            FBProgressIndicator* bar = [[FBProgressIndicator alloc] initWithFrame:frame];
            bar.style = NSProgressIndicatorStyleBar;
            bar.indeterminate = NO;
            bar.minValue = minVal;
            bar.maxValue = maxVal;
            bar.doubleValue = minVal;
            bar.tag = ((NSInteger)windowId << 16) | controlId;
            [contentView addSubview:bar];
            [win.controls addObject:bar];
        }

        [NSAnimationContext endGrouping];
    });
}

- (double)valueForControl:(uint16_t)windowId controlId:(uint16_t)controlId {
    __block double result = 0.0;
    void (^work)(void) = ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        NSInteger tag = ((NSInteger)windowId << 16) | controlId;
        for (NSView* view in win.controls) {
            if (view.tag == tag) {
                if ([view isKindOfClass:[NSSlider class]]) {
                    result = ((NSSlider*)view).doubleValue;
                } else if ([view isKindOfClass:[FBProgressIndicator class]]) {
                    result = ((FBProgressIndicator*)view).doubleValue;
                } else if ([view isKindOfClass:[NSPopUpButton class]]) {
                    result = (double)((NSPopUpButton*)view).indexOfSelectedItem;
                } else if ([view isKindOfClass:[NSComboBox class]]) {
                    result = (double)((NSComboBox*)view).indexOfSelectedItem;
                }
                break;
            }
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

- (void)canvasOpForWindow:(uint16_t)windowId controlId:(uint16_t)controlId op:(uint8_t)op args:(const double*)args count:(uint32_t)count text:(NSString*)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        FBCanvasView* canvas = [self canvasForWindow:win controlId:controlId];
        if (!canvas) return;

        double local[7] = {0};
        if (args) {
            uint32_t n = count < 7 ? count : 7;
            memcpy(local, args, n * sizeof(double));
        }
        [canvas applyCanvasOp:op args:local count:count text:text ?: @""];
    });
}

- (void)canvasSetVirtualSize:(uint16_t)windowId controlId:(uint16_t)controlId w:(double)w h:(double)h {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        FBCanvasView* canvas = [self canvasForWindow:win controlId:controlId];
        if (!canvas) return;
        CGSize size = CGSizeMake(w > 0.0 ? w : canvas.bounds.size.width, h > 0.0 ? h : canvas.bounds.size.height);
        canvas.virtualSize = size;
        NSScrollView* scroll = (NSScrollView*)canvas.enclosingScrollView;
        if ([scroll isKindOfClass:[NSScrollView class]]) {
            canvas.frame = NSMakeRect(0, 0, size.width, size.height);
            [scroll.documentView setFrame:canvas.frame];
            [scroll reflectScrolledClipView:scroll.contentView];
        }
    });
}

- (void)canvasSetViewport:(uint16_t)windowId controlId:(uint16_t)controlId x:(double)x y:(double)y {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        FBCanvasView* canvas = [self canvasForWindow:win controlId:controlId];
        if (!canvas) return;
        NSScrollView* scroll = (NSScrollView*)canvas.enclosingScrollView;
        if (![scroll isKindOfClass:[NSScrollView class]]) return;
        NSClipView* clip = scroll.contentView;
        [clip scrollToPoint:NSMakePoint(x, y)];
        [scroll reflectScrolledClipView:clip];
    });
}

- (void)canvasSetResolution:(uint16_t)windowId controlId:(uint16_t)controlId w:(double)w h:(double)h {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        FBCanvasView* canvas = [self canvasForWindow:win controlId:controlId];
        if (!canvas) return;
        CGSize logical = CGSizeMake(w > 0.0 ? w : canvas.bounds.size.width, h > 0.0 ? h : canvas.bounds.size.height);
        canvas.logicalSize = logical;
        [canvas syncBackingImageSize];
        [canvas setNeedsDisplay:YES];
    });
}

- (void)canvasDispatch:(uint16_t)windowId controlId:(uint16_t)controlId data:(const uint8_t*)data len:(uint32_t)len {
    if (data == NULL || len < 4) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    if (!payload || payload.length < 4) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        FBCanvasView* canvas = [self canvasForWindow:win controlId:controlId];
        if (!canvas) return;
        [canvas applyCanvasBatch:(const uint8_t*)payload.bytes len:(uint32_t)payload.length];
    });
}

- (void)setValueForControl:(uint16_t)windowId controlId:(uint16_t)controlId value:(double)value {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (!win) return;
        NSInteger tag = ((NSInteger)windowId << 16) | controlId;
//        NSLog(@"[GFX] setValueForControl win=%u ctl=%u val=%g tag=%ld controls=%lu", windowId, controlId, value, (long)tag, (unsigned long)win.controls.count);
        for (NSView* view in win.controls) {
            if (view.tag == tag) {
                // NSLog(@"[GFX] Found control class=%@", [view class]);
                if ([view isKindOfClass:[NSSlider class]]) {
                    ((NSSlider*)view).doubleValue = value;
                } else if ([view isKindOfClass:[FBProgressIndicator class]]) {
                    FBProgressIndicator* bar = (FBProgressIndicator*)view;
//                    if (bar.hidden) NSLog(@"[GFX] PROGRESS HIDDEN!");
//                    if (bar.indeterminate) NSLog(@"[GFX] PROGRESS INDETERMINATE!");
                    [bar setDoubleValue:value];
                    [bar setNeedsDisplay:YES];
                    // Also try display to force update immediately if running loop is stalling
                    [bar display]; 
                } else if ([view isKindOfClass:[NSPopUpButton class]]) {
                    [((NSPopUpButton*)view) selectItemAtIndex:(NSInteger)value];
                } else if ([view isKindOfClass:[NSComboBox class]]) {
                    [((NSComboBox*)view) selectItemAtIndex:(NSInteger)value];
                }
                [view setNeedsDisplay:YES];
                break;
            }
        }
    });
}

- (void)showWindow:(uint16_t)windowId {
    // Use dispatch_sync so the JIT thread blocks until the window is
    // actually on screen.  Because the main queue is serial, this also
    // drains all preceding async blocks (defineWindow, addControlTo)
    // before makeKeyAndOrderFront: runs.
    void (^work)(void) = ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) [win makeKeyAndOrderFront:nil];
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

- (void)hideWindow:(uint16_t)windowId {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) [win orderOut:nil];
    });
}

- (void)closeWindow:(uint16_t)windowId {
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindow* win = self.windows[@(windowId)];
        if (win) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:win];
            [win close];
            [self.windows removeObjectForKey:@(windowId)];
        }
    });
}

- (void)closeAll {
    void (^work)(void) = ^{
        for (NSNumber* key in [self.windows allKeys]) {
            GraphicsWindow* win = self.windows[key];
            if (win) {
                [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:win];
                [win close];
            }
        }
        [self.windows removeAllObjects];
        _eventHead = 0;
        _eventTail = 0;
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
}

- (void)shutdown {
    [self closeAll];
}

@end

static void gfx_window_manager_close_all(void) {
    [[GraphicsWindowManager sharedManager] closeAll];
}

// ─── Bridge Functions ───────────────────────────────────────────────────────

void gfx_window_define_bridge(uint16_t id, const char* title, uint32_t title_len, uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    NSString* titleStr = title ? [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding] : @"";
    [[GraphicsWindowManager sharedManager] defineWindow:id title:titleStr x:x y:y w:w h:h];
}

void gfx_window_control_bridge(uint16_t win_id, uint8_t kind, uint16_t ctl_id, const char* text, uint32_t text_len, uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    NSString* textStr = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    [[GraphicsWindowManager sharedManager] addControlTo:win_id kind:kind controlId:ctl_id text:textStr x:x y:y w:w h:h];
}

void gfx_window_show_bridge(uint16_t id) {
    [[GraphicsWindowManager sharedManager] showWindow:id];
}

void gfx_window_hide_bridge(uint16_t id) {
    [[GraphicsWindowManager sharedManager] hideWindow:id];
}

void gfx_window_close_bridge(uint16_t id) {
    if (id == 0) {
        [[GraphicsWindowManager sharedManager] closeAll];
    } else {
        [[GraphicsWindowManager sharedManager] closeWindow:id];
    }
}

void gfx_window_shutdown_bridge(void) {
    [[GraphicsWindowManager sharedManager] shutdown];
}

uint8_t gfx_window_poll_bridge(uint16_t* win_out, uint16_t* ctl_out) {
    return [[GraphicsWindowManager sharedManager] pollEvent:win_out control:ctl_out];
}

uint8_t gfx_window_has_windows_bridge(void) {
    return [[GraphicsWindowManager sharedManager] hasWindows];
}

const char* gfx_window_get_text_bridge(uint16_t win_id, uint16_t ctl_id) {
    static char s_window_text_buf[4096];
    NSString* text = [[GraphicsWindowManager sharedManager] textForControl:win_id controlId:ctl_id];
    if (!text) text = @"";
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    size_t n = d.length;
    if (n > sizeof(s_window_text_buf) - 1) n = sizeof(s_window_text_buf) - 1;
    if (n > 0) memcpy(s_window_text_buf, d.bytes, n);
    s_window_text_buf[n] = '\0';
    return s_window_text_buf;
}

void gfx_window_set_text_bridge(uint16_t win_id, uint16_t ctl_id, const char* text, uint32_t text_len) {
    NSString* textStr = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    [[GraphicsWindowManager sharedManager] setTextForWindowControl:win_id controlId:ctl_id text:textStr];
}

void gfx_window_set_enabled_bridge(uint16_t win_id, uint16_t ctl_id, uint8_t enabled) {
    [[GraphicsWindowManager sharedManager] setEnabledForControl:win_id controlId:ctl_id enabled:(enabled != 0)];
}

void gfx_window_set_title_bridge(uint16_t win_id, const char* title, uint32_t title_len) {
    NSString* titleStr = title ? [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding] : @"";
    [[GraphicsWindowManager sharedManager] setTitleForWindow:win_id title:titleStr];
}

uint8_t gfx_window_get_checked_bridge(uint16_t win_id, uint16_t ctl_id) {
    return [[GraphicsWindowManager sharedManager] checkedForControl:win_id controlId:ctl_id];
}

void gfx_window_ranged_control_bridge(uint16_t win_id, uint8_t kind, uint16_t ctl_id, double min, double max, uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    [[GraphicsWindowManager sharedManager] addRangedControlTo:win_id kind:kind controlId:ctl_id min:min max:max x:x y:y w:w h:h];
}

double gfx_window_get_value_bridge(uint16_t win_id, uint16_t ctl_id) {
    return [[GraphicsWindowManager sharedManager] valueForControl:win_id controlId:ctl_id];
}

void gfx_window_set_value_bridge(uint16_t win_id, uint16_t ctl_id, double value) {
    [[GraphicsWindowManager sharedManager] setValueForControl:win_id controlId:ctl_id value:value];
}

void gfx_window_canvas_dispatch_bridge(uint16_t win_id, uint16_t ctl_id, const uint8_t* data_ptr, uint32_t data_len) {
    [[GraphicsWindowManager sharedManager] canvasDispatch:win_id controlId:ctl_id data:data_ptr len:data_len];
}

void gfx_window_canvas_set_virtualsize_bridge(uint16_t win_id, uint16_t ctl_id, double virtual_w, double virtual_h) {
    [[GraphicsWindowManager sharedManager] canvasSetVirtualSize:win_id controlId:ctl_id w:virtual_w h:virtual_h];
}

void gfx_window_canvas_set_viewport_bridge(uint16_t win_id, uint16_t ctl_id, double x, double y) {
    [[GraphicsWindowManager sharedManager] canvasSetViewport:win_id controlId:ctl_id x:x y:y];
}

void gfx_window_canvas_set_resolution_bridge(uint16_t win_id, uint16_t ctl_id, double logical_w, double logical_h) {
    [[GraphicsWindowManager sharedManager] canvasSetResolution:win_id controlId:ctl_id w:logical_w h:logical_h];
}

void gfx_window_canvas_op_bridge(uint16_t win_id, uint16_t ctl_id, uint8_t op, const double* args, uint32_t count, const char* text_ptr, uint32_t text_len) {
    NSString* text = nil;
    if (text_ptr && text_len > 0) {
        text = [[NSString alloc] initWithBytes:text_ptr length:text_len encoding:NSUTF8StringEncoding];
    }
    [[GraphicsWindowManager sharedManager] canvasOpForWindow:win_id controlId:ctl_id op:op args:args count:count text:text];
}

// ─── Matrix Control (NSTableView) ─────────────────────────────────────────────

/// Data source / delegate for FBMatrixScrollView.
/// Stores a flattened row-major snapshot of the 2D double array.
@interface FBMatrixDataSource : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, assign) NSInteger rowCount;
@property (nonatomic, assign) NSInteger colCount;
/// Snapshot copy used for display (owned by this object).
@property (nonatomic, strong) NSMutableArray<NSNumber*>* snapshotData;
/// Window and control IDs for firing matrix-edit events back to the BASIC event loop.
@property (nonatomic, assign) uint16_t winId;
@property (nonatomic, assign) uint16_t ctlId;
@end

@implementation FBMatrixDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv {
    (void)tv;
    return self.rowCount;
}
- (nullable id)tableView:(NSTableView*)tv objectValueForTableColumn:(nullable NSTableColumn*)col row:(NSInteger)row {
    (void)tv;
    NSInteger c = [col.identifier integerValue];
    if (c < 0) {
        // Row-number column: display 1-based index
        return [NSString stringWithFormat:@"%ld", (long)(row + 1)];
    }
    NSInteger idx = row * self.colCount + c;
    if (idx < 0 || idx >= (NSInteger)self.snapshotData.count) return @"0";
    double val = [self.snapshotData[(NSUInteger)idx] doubleValue];
    // Show as integer when the value is a whole number, otherwise %.6g
    if (val == (double)(long long)val && fabs(val) < 1e15) {
        return [NSString stringWithFormat:@"%lld", (long long)val];
    }
    return [NSString stringWithFormat:@"%.6g", val];
}
- (void)tableView:(NSTableView*)tv setObjectValue:(nullable id)obj forTableColumn:(nullable NSTableColumn*)col row:(NSInteger)row {
    (void)tv;
    NSInteger c = [col.identifier integerValue];
    if (c < 0) return; // row-number column is read-only
    NSInteger idx = row * self.colCount + c;
    if (idx < 0 || idx >= (NSInteger)self.snapshotData.count) return;
    double val = [obj doubleValue];
    // Update snapshot for immediate visual feedback (UI thread only, safe)
    self.snapshotData[(NSUInteger)idx] = @(val);
    // Fire a matrix-cell-edit event so BASIC can write the value into its own array
    [[GraphicsWindowManager sharedManager]
        enqueueMatrixEvent:self.winId
                   control:self.ctlId
                       row:(uint16_t)(row + 1)   // 1-based
                       col:(uint16_t)(c + 1)     // 1-based
                     value:val];
}
@end

/// NSScrollView containing an editable NSTableView for matrix display.
@interface FBMatrixScrollView : NSScrollView
@property (nonatomic, assign) NSInteger tag;
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) FBMatrixDataSource* matrixDataSource;
@end

@implementation FBMatrixScrollView
@synthesize tag = _tag;
+ (instancetype)matrixViewWithRows:(NSInteger)rows cols:(NSInteger)cols snapshot:(const double*)snapshot winId:(uint16_t)winId ctlId:(uint16_t)ctlId frame:(NSRect)frame {
    FBMatrixScrollView* scroll = [[FBMatrixScrollView alloc] initWithFrame:frame];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTableView* table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    // Keep matrix columns at the widths we specify instead of stretching to fill,
    // while still letting the user resize them manually if desired.
    table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    table.allowsColumnResizing = YES;
    table.rowSizeStyle = NSTableViewRowSizeStyleSmall;
    table.intercellSpacing = NSMakeSize(4, 2);
    table.allowsMultipleSelection = NO;
    // Darker headers for row/column labels so they stand apart from the grid cells.
    NSTableHeaderView* header = table.headerView;
    if (header) {
        header.wantsLayer = YES;
        header.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0].CGColor;
        header.layer.borderColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
        header.layer.borderWidth = 1.0;
        header.layer.cornerRadius = 0.0;
    }

    // Build the data source with a snapshot for display and a live pointer for write-back
    FBMatrixDataSource* ds = [[FBMatrixDataSource alloc] init];
    ds.rowCount = rows;
    ds.colCount = cols;
    NSMutableArray* flat = [NSMutableArray arrayWithCapacity:(NSUInteger)(rows * cols)];
    if (snapshot) {
        for (NSInteger i = 0; i < rows * cols; i++) {
            [flat addObject:@(snapshot[i])];
        }
    }
    ds.snapshotData = flat;
    ds.winId = winId;
    ds.ctlId = ctlId;

    // Row-number column (identifier @"-1")
    NSTableColumn* rowNumCol = [[NSTableColumn alloc] initWithIdentifier:@"-1"];
    rowNumCol.title = @"#";
    rowNumCol.width = 36.0;
    rowNumCol.minWidth = 20.0;
    rowNumCol.maxWidth = 60.0;
    rowNumCol.editable = NO;
    rowNumCol.resizingMask = NSTableColumnUserResizingMask;
    rowNumCol.headerCell.textColor = [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
    [table addTableColumn:rowNumCol];

    // Data columns
    CGFloat colW = MAX(60.0, (frame.size.width - 44.0) / MAX(1, (CGFloat)cols));
    for (NSInteger c = 0; c < cols; c++) {
        NSString* ident = [@(c) stringValue];
        NSString* title = [NSString stringWithFormat:@"[%@]", [@(c + 1) stringValue]];
        NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:ident];
        col.title = title;
        col.width = colW;
        col.minWidth = 40.0;
        col.editable = YES;
        col.resizingMask = NSTableColumnUserResizingMask;
        col.headerCell.textColor = [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
        [table addTableColumn:col];
    }

    table.dataSource = ds;
    table.delegate = ds;
    [table reloadData];

    scroll.documentView = table;
    scroll.tableView = table;
    scroll.matrixDataSource = ds;
    return scroll;
}
@end

void gfx_window_matrix_control_bridge(uint16_t win_id, uint16_t ctl_id, int32_t rows, int32_t cols, double* data, uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    // Snapshot the data on the calling thread before dispatch_async might run.
    NSInteger nRows = (NSInteger)MAX(0, rows);
    NSInteger nCols = (NSInteger)MAX(0, cols);
    NSInteger count = nRows * nCols;
    double* snapshot = NULL;
    if (count > 0 && data) {
        snapshot = (double*)malloc((size_t)(count * sizeof(double)));
        if (snapshot) memcpy(snapshot, data, (size_t)(count * sizeof(double)));
    }

    uint16_t ww = w, hh = h, xx = x, yy = y;
    dispatch_async(dispatch_get_main_queue(), ^{
        GraphicsWindowManager* mgr = [GraphicsWindowManager sharedManager];
        GraphicsWindow* win = mgr.windows[@(win_id)];
        if (!win) { free(snapshot); return; }

        NSView* contentView = win.contentView;
        CGFloat winH = contentView.frame.size.height;
        NSRect frame = NSMakeRect(xx, hh > 0 ? (winH - yy - hh) : (winH - yy - 120), ww > 0 ? ww : 300, hh > 0 ? hh : 120);

        // Remove existing control if present
        NSView* existing = [mgr controlInWindow:win controlId:ctl_id];
        if (existing) {
            [existing removeFromSuperview];
            [win.controls removeObject:existing];
        }

        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setAllowsImplicitAnimation:NO];

        FBMatrixScrollView* scroll = [FBMatrixScrollView matrixViewWithRows:nRows cols:nCols snapshot:snapshot winId:win_id ctlId:ctl_id frame:frame];
        scroll.tag = ((NSInteger)win_id << 16) | ctl_id;
        [contentView addSubview:scroll];
        [win.controls addObject:scroll];

        [NSAnimationContext endGrouping];
        free(snapshot);
    });
}

double gfx_window_matrix_last_row_bridge(void) {
    return (double)[[GraphicsWindowManager sharedManager] lastMatrixRow];
}
double gfx_window_matrix_last_col_bridge(void) {
    return (double)[[GraphicsWindowManager sharedManager] lastMatrixCol];
}
double gfx_window_matrix_last_val_bridge(void) {
    return [[GraphicsWindowManager sharedManager] lastMatrixVal];
}

// Ensure exports are referenced
void dummy_ref_window_exports(void) {
    (void)gfx_window_define;
    (void)gfx_window_control;
    (void)gfx_window_show;
    (void)gfx_window_hide;
    (void)gfx_window_close;
    (void)gfx_window_shutdown;
    (void)gfx_window_poll;
}

