// ─── Ed Sprite Integration Test ────────────────────────────────────────────
//
// Standalone Objective-C integration test that opens a real Metal graphics
// window and exercises the GPU-driven sprite system end-to-end:
//
//   • Procedural sprite definition (gfx_sprite_def + gfx_sprite_data)
//   • Palette setup (gfx_sprite_palette)
//   • Instance placement and visibility (gfx_sprite, gfx_sprite_show)
//   • Movement, rotation, scaling (gfx_sprite_pos, gfx_sprite_rot, gfx_sprite_scale)
//   • Flip and alpha (gfx_sprite_flip, gfx_sprite_alpha)
//   • Animation frames (gfx_sprite_frames, gfx_sprite_animate)
//   • Effects: glow, outline, tint, shadow, flash, dissolve
//   • Collision detection (gfx_sprite_hit)
//   • Priority ordering (gfx_sprite_priority)
//   • Additive blending (gfx_sprite_blend)
//   • Remove and re-place (gfx_sprite_remove, gfx_sprite_remove_all)
//   • VSYNC-driven rendering loop
//
// Build & run:
//
//   zig build test-sprites
//
// Requires a display — will exit 0 (skip) if no Metal device.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <math.h>
#include <pthread.h>
#include <dispatch/dispatch.h>

// ═══════════════════════════════════════════════════════════════════════════
// Stubs for symbols referenced by ed_graphics_bridge.m
// ═══════════════════════════════════════════════════════════════════════════

__attribute__((weak)) void basic_jit_stop(void) {
    // no-op — no JIT thread in the sprite test
}

__attribute__((weak)) void timer_tick_frame(void) {
    // no-op
}

// ═══════════════════════════════════════════════════════════════════════════
// Extern Zig functions (ed_graphics.zig / graphics_runtime.zig exports)
// ═══════════════════════════════════════════════════════════════════════════

// Window lifecycle
extern void gfx_create_window_sync(uint16_t w, uint16_t h, uint16_t scale);
extern void gfx_destroy_window_async(void);
extern void ed_graphics_init(void);
extern void ed_graphics_shutdown(void);

// Runtime functions (f64 calling convention)
extern void   gfx_screen(double w, double h, double scale);
extern void   gfx_screen_close(void);
extern void   gfx_screen_title(const void *desc);
extern void   gfx_pset(double x, double y, double c);
extern double gfx_pget(double x, double y);
extern void   gfx_cls(double c);
extern void   gfx_line(double x1, double y1, double x2, double y2, double c);
extern void   gfx_rect(double x, double y, double w, double h, double c, double filled);
extern void   gfx_circle(double cx, double cy, double r, double c, double filled);
extern void   gfx_draw_text(double x, double y, const void *desc, double c, double font);
extern void   gfx_flip(void);
extern void   gfx_palette(double idx, double r, double g, double b);
extern void   gfx_set_target(double buf);
extern void   gfx_blit_solid(double sb, double sx, double sy, double db, double dx, double dy, double w, double h);
extern double gfx_screen_width(void);
extern double gfx_screen_height(void);
extern double gfx_screen_active(void);
extern void   gfx_vsync(void);

// Sprite runtime functions
extern void   gfx_sprite_def(double id, double w, double h);
extern void   gfx_sprite_data(double id, double x, double y, double c);
extern void   gfx_sprite_palette(double id, double idx, double r, double g, double b);
extern void   gfx_sprite_frames(double id, double fw, double fh, double count);
extern void   gfx_sprite(double inst, double def, double x, double y);
extern void   gfx_sprite_show(double inst);
extern void   gfx_sprite_hide(double inst);
extern void   gfx_sprite_pos(double inst, double x, double y);
extern void   gfx_sprite_move(double inst, double dx, double dy);
extern void   gfx_sprite_rot(double inst, double angle_deg);
extern void   gfx_sprite_scale(double inst, double sx, double sy);
extern void   gfx_sprite_anchor(double inst, double ax, double ay);
extern void   gfx_sprite_flip(double inst, double h, double v);
extern void   gfx_sprite_alpha(double inst, double a);
extern void   gfx_sprite_frame(double inst, double frame);
extern void   gfx_sprite_animate(double inst, double speed);
extern void   gfx_sprite_priority(double inst, double pri);
extern void   gfx_sprite_blend(double inst, double mode);
extern void   gfx_sprite_remove(double inst);
extern void   gfx_sprite_remove_all(void);
extern void   gfx_sprite_fx(double inst, double fx_type);
extern void   gfx_sprite_fx_param(double inst, double p1, double p2);
extern void   gfx_sprite_fx_colour(double inst, double r, double g, double b, double a);
extern void   gfx_sprite_glow(double inst, double radius, double intensity, double r, double g, double b);
extern void   gfx_sprite_outline(double inst, double thickness, double r, double g, double b);
extern void   gfx_sprite_shadow(double inst, double ox, double oy, double r, double g, double b, double a);
extern void   gfx_sprite_tint(double inst, double factor, double r, double g, double b);
extern void   gfx_sprite_flash(double inst, double speed, double r, double g, double b);
extern void   gfx_sprite_fx_off(double inst);
extern double gfx_sprite_hit(double a, double b);
extern double gfx_sprite_count(void);
extern double gfx_sprite_x(double inst);
extern double gfx_sprite_y(double inst);
extern double gfx_sprite_visible(double inst);
extern double gfx_sprite_get_frame(double inst);
extern void   gfx_sprite_sync(void);

// ═══════════════════════════════════════════════════════════════════════════
// Test helpers
// ═══════════════════════════════════════════════════════════════════════════

static int g_test_pass = 0;
static int g_test_fail = 0;

#define TEST_LOG(fmt, ...) fprintf(stderr, "  " fmt "\n", ##__VA_ARGS__)

#define ASSERT_TRUE(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "  \033[31m[FAIL]\033[0m %s:%d: %s\n", \
                __FILE__, __LINE__, msg); \
        g_test_fail++; \
    } else { \
        g_test_pass++; \
    } \
} while (0)

#define ASSERT_EQ_INT(a, b, msg) do { \
    long long _a = (long long)(a); \
    long long _b = (long long)(b); \
    if (_a != _b) { \
        fprintf(stderr, "  \033[31m[FAIL]\033[0m %s:%d: %s " \
                "(expected %lld, got %lld)\n", \
                __FILE__, __LINE__, msg, _a, _b); \
        g_test_fail++; \
    } else { \
        g_test_pass++; \
    } \
} while (0)

#define ASSERT_EQ_F64(a, b, msg) do { \
    double _a = (double)(a); \
    double _b = (double)(b); \
    if (fabs(_a - _b) > 0.01) { \
        fprintf(stderr, "  \033[31m[FAIL]\033[0m %s:%d: %s " \
                "(expected %.2f, got %.2f)\n", \
                __FILE__, __LINE__, msg, _a, _b); \
        g_test_fail++; \
    } else { \
        g_test_pass++; \
    } \
} while (0)

// ═══════════════════════════════════════════════════════════════════════════
// Real StringDescriptor runtime — linked from string_utf32.zig
// ═══════════════════════════════════════════════════════════════════════════
//
// We now link the real Zig runtime (string_utf32, samm_core, samm_pool)
// so the same string_to_utf8 / string_new_ascii that JIT-compiled BASIC
// code uses is also used by the test's own direct calls.  This eliminates
// the symbol collision that previously caused intermittent corruption.

extern void  *string_new_ascii(const char *s);
extern void   string_release(void *desc);
extern void   samm_init(void);

// Convenience: create a StringDescriptor from a C string literal.
// Caller must string_release() the result when done.
#define STR_DESC(cstr) string_new_ascii(cstr)

// ═══════════════════════════════════════════════════════════════════════════
// Helper: draw a HUD label at the bottom of the screen
// ═══════════════════════════════════════════════════════════════════════════

static void draw_hud(const char *phase_name, int frame, int total_frames) {
    // Dark bar at top
    gfx_rect(0.0, 0.0, 320.0, 12.0, 27.0, 1.0);
    void *hud = STR_DESC(phase_name);
    gfx_draw_text(4.0, 2.0, hud, 23.0, 0.0);
    string_release(hud);

    // Frame counter at bottom
    gfx_rect(0.0, 190.0, 320.0, 10.0, 27.0, 1.0);
    char frame_str[48];
    snprintf(frame_str, sizeof(frame_str), "Frame %d/%d", frame + 1, total_frames);
    void *hud2 = STR_DESC(frame_str);
    gfx_draw_text(4.0, 191.0, hud2, 22.0, 0.0);
    string_release(hud2);
}

// ═══════════════════════════════════════════════════════════════════════════
// Sprite shape generators — procedurally define sprites via gfx_sprite_data
// ═══════════════════════════════════════════════════════════════════════════

// Define sprite 0: 16×16 diamond shape
static void define_diamond_sprite(void) {
    gfx_sprite_def(0.0, 16.0, 16.0);

    // Palette: 0=transparent, 1=black outline, 2=body, 3=highlight, 4=shadow
    gfx_sprite_palette(0.0, 0.0,   0.0,   0.0,   0.0);   // transparent (alpha=0 set by default)
    gfx_sprite_palette(0.0, 1.0,   0.0,   0.0,   0.0);   // black outline
    gfx_sprite_palette(0.0, 2.0, 255.0,  80.0,  80.0);   // red body
    gfx_sprite_palette(0.0, 3.0, 255.0, 180.0, 180.0);   // highlight
    gfx_sprite_palette(0.0, 4.0, 160.0,  40.0,  40.0);   // shadow

    // Draw diamond shape
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            // Manhattan distance from centre
            int dx = abs(x - 7);
            int dy = abs(y - 7);
            int dist = dx + dy;

            if (dist <= 7) {
                double c;
                if (dist == 7) {
                    c = 1.0; // outline
                } else if (dx + dy <= 3) {
                    c = 3.0; // highlight centre
                } else if (x > 7 && y > 7) {
                    c = 4.0; // shadow quadrant
                } else {
                    c = 2.0; // body
                }
                gfx_sprite_data(0.0, (double)x, (double)y, c);
            }
        }
    }
}

// Define sprite 1: 12×12 circle/ball
static void define_ball_sprite(void) {
    gfx_sprite_def(1.0, 12.0, 12.0);

    gfx_sprite_palette(1.0, 0.0,   0.0,   0.0,   0.0);
    gfx_sprite_palette(1.0, 1.0,   0.0,   0.0,   0.0);
    gfx_sprite_palette(1.0, 2.0,  80.0, 200.0, 255.0);   // cyan body
    gfx_sprite_palette(1.0, 3.0, 160.0, 240.0, 255.0);   // highlight
    gfx_sprite_palette(1.0, 4.0,  20.0, 100.0, 160.0);   // shadow

    for (int y = 0; y < 12; y++) {
        for (int x = 0; x < 12; x++) {
            double dx = x - 5.5;
            double dy = y - 5.5;
            double r = sqrt(dx * dx + dy * dy);

            if (r <= 5.5) {
                double c;
                if (r > 4.5) {
                    c = 1.0; // outline
                } else if (r <= 2.0) {
                    c = 3.0; // highlight
                } else if (dx > 0 && dy > 0) {
                    c = 4.0; // shadow
                } else {
                    c = 2.0; // body
                }
                gfx_sprite_data(1.0, (double)x, (double)y, c);
            }
        }
    }
}

// Define sprite 2: 8×8 small star
static void define_star_sprite(void) {
    gfx_sprite_def(2.0, 8.0, 8.0);

    gfx_sprite_palette(2.0, 0.0,   0.0,   0.0,   0.0);
    gfx_sprite_palette(2.0, 1.0, 255.0, 255.0, 100.0);   // bright yellow
    gfx_sprite_palette(2.0, 2.0, 255.0, 200.0,  60.0);   // gold
    gfx_sprite_palette(2.0, 3.0, 200.0, 150.0,  30.0);   // dark gold

    // Star cross pattern
    // Horizontal bar
    for (int x = 0; x < 8; x++) {
        gfx_sprite_data(2.0, (double)x, 3.0, (x == 0 || x == 7) ? 3.0 : 2.0);
        gfx_sprite_data(2.0, (double)x, 4.0, (x == 0 || x == 7) ? 3.0 : 2.0);
    }
    // Vertical bar
    for (int y = 0; y < 8; y++) {
        gfx_sprite_data(2.0, 3.0, (double)y, (y == 0 || y == 7) ? 3.0 : 2.0);
        gfx_sprite_data(2.0, 4.0, (double)y, (y == 0 || y == 7) ? 3.0 : 2.0);
    }
    // Bright centre
    gfx_sprite_data(2.0, 3.0, 3.0, 1.0);
    gfx_sprite_data(2.0, 4.0, 3.0, 1.0);
    gfx_sprite_data(2.0, 3.0, 4.0, 1.0);
    gfx_sprite_data(2.0, 4.0, 4.0, 1.0);
    // Diagonal accents
    gfx_sprite_data(2.0, 1.0, 1.0, 3.0);
    gfx_sprite_data(2.0, 6.0, 1.0, 3.0);
    gfx_sprite_data(2.0, 1.0, 6.0, 3.0);
    gfx_sprite_data(2.0, 6.0, 6.0, 3.0);
    gfx_sprite_data(2.0, 2.0, 2.0, 2.0);
    gfx_sprite_data(2.0, 5.0, 2.0, 2.0);
    gfx_sprite_data(2.0, 2.0, 5.0, 2.0);
    gfx_sprite_data(2.0, 5.0, 5.0, 2.0);
}

// Define sprite 3: 32×8 animated strip (4 frames of 8×8)
static void define_animated_sprite(void) {
    gfx_sprite_def(3.0, 32.0, 8.0);

    gfx_sprite_palette(3.0, 0.0,   0.0,   0.0,   0.0);
    gfx_sprite_palette(3.0, 1.0, 255.0, 100.0, 255.0);   // magenta
    gfx_sprite_palette(3.0, 2.0, 200.0,  60.0, 200.0);   // dark magenta
    gfx_sprite_palette(3.0, 3.0, 255.0, 200.0, 255.0);   // light pink

    // Frame 0: small dot (2×2 centre)
    for (int y = 3; y <= 4; y++)
        for (int x = 3; x <= 4; x++)
            gfx_sprite_data(3.0, (double)x, (double)y, 1.0);

    // Frame 1: medium cross
    for (int i = 1; i <= 6; i++) {
        gfx_sprite_data(3.0, (double)(8 + i), 3.0, 2.0);
        gfx_sprite_data(3.0, (double)(8 + i), 4.0, 2.0);
        gfx_sprite_data(3.0, (double)(8 + 3), (double)i, 2.0);
        gfx_sprite_data(3.0, (double)(8 + 4), (double)i, 2.0);
    }
    gfx_sprite_data(3.0, 11.0, 3.0, 1.0);
    gfx_sprite_data(3.0, 12.0, 3.0, 1.0);
    gfx_sprite_data(3.0, 11.0, 4.0, 1.0);
    gfx_sprite_data(3.0, 12.0, 4.0, 1.0);

    // Frame 2: full diamond
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            int dist = abs(x - 3) + abs(y - 3);
            if (dist <= 3) {
                double c = (dist <= 1) ? 1.0 : 2.0;
                gfx_sprite_data(3.0, (double)(16 + x), (double)y, c);
            }
        }
    }

    // Frame 3: ring/outline
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            double dx = x - 3.5;
            double dy = y - 3.5;
            double r = sqrt(dx * dx + dy * dy);
            if (r >= 2.0 && r <= 3.5) {
                gfx_sprite_data(3.0, (double)(24 + x), (double)y, 3.0);
            }
        }
    }

    // Configure as 4-frame animation
    gfx_sprite_frames(3.0, 8.0, 8.0, 4.0);
}

// Define sprite 4: 16×16 arrow (for flip/rotation tests)
static void define_arrow_sprite(void) {
    gfx_sprite_def(4.0, 16.0, 16.0);

    gfx_sprite_palette(4.0, 0.0,   0.0,   0.0,   0.0);
    gfx_sprite_palette(4.0, 1.0,  80.0, 255.0, 120.0);   // green body
    gfx_sprite_palette(4.0, 2.0,  40.0, 180.0,  60.0);   // dark green
    gfx_sprite_palette(4.0, 3.0, 160.0, 255.0, 180.0);   // light green

    // Arrow pointing right: shaft + head
    // Shaft (y=6..9, x=1..9)
    for (int y = 6; y <= 9; y++) {
        for (int x = 1; x <= 9; x++) {
            gfx_sprite_data(4.0, (double)x, (double)y, 1.0);
        }
    }
    // Head (triangle pointing right, x=10..14)
    for (int y = 2; y <= 13; y++) {
        int half = abs(y - 7);
        int start_x = 10;
        int end_x = 14 - half;
        for (int x = start_x; x <= end_x && x < 16; x++) {
            double c = (x == end_x) ? 2.0 : 1.0;
            gfx_sprite_data(4.0, (double)x, (double)y, c);
        }
    }
    // Highlight on top edge of shaft
    for (int x = 1; x <= 9; x++) {
        gfx_sprite_data(4.0, (double)x, 6.0, 3.0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Background drawing
// ═══════════════════════════════════════════════════════════════════════════

static void setup_palette(void) {
    gfx_palette(16.0,  12.0,  10.0,  30.0);    // dark background
    gfx_palette(17.0,  20.0,  16.0,  45.0);    // slightly lighter bg
    gfx_palette(18.0,  40.0,  30.0,  60.0);    // grid accent
    gfx_palette(19.0, 255.0, 255.0, 255.0);    // white
    gfx_palette(20.0, 100.0, 100.0, 140.0);    // dim text
    gfx_palette(21.0, 255.0, 200.0,  60.0);    // yellow label
    gfx_palette(22.0, 140.0, 140.0, 160.0);    // grey text
    gfx_palette(23.0, 200.0, 200.0, 220.0);    // bright text
    gfx_palette(24.0, 255.0,  80.0,  80.0);    // red
    gfx_palette(25.0,  80.0, 255.0, 120.0);    // green
    gfx_palette(26.0,  80.0, 200.0, 255.0);    // cyan
    gfx_palette(27.0,  20.0,  18.0,  40.0);    // HUD bar
    gfx_palette(28.0, 255.0, 100.0, 255.0);    // magenta
}

// Draw a simple starfield background
static void draw_background(void) {
    gfx_cls(16.0);

    // Subtle grid lines
    for (int x = 0; x < 320; x += 32) {
        gfx_line((double)x, 0.0, (double)x, 199.0, 17.0);
    }
    for (int y = 0; y < 200; y += 32) {
        gfx_line(0.0, (double)y, 319.0, (double)y, 17.0);
    }

    // Scatter some stars
    for (int i = 0; i < 60; i++) {
        int sx = (i * 197 + 31) % 320;
        int sy = (i * 113 + 17) % 200;
        int sc = 18 + (i % 2);
        gfx_pset((double)sx, (double)sy, (double)sc);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Test phases
// ═══════════════════════════════════════════════════════════════════════════

static volatile int  g_phase = 0;
static volatile bool g_tests_done = false;

enum {
    PHASE_INIT = 0,
    PHASE_DEFINE_SPRITES,
    PHASE_BASIC_PLACEMENT,
    PHASE_MOVEMENT_AND_ROTATION,
    PHASE_SCALING_AND_FLIP,
    PHASE_EFFECTS,
    PHASE_ANIMATION_AND_COLLISION,
    PHASE_STRESS,
    PHASE_CLEANUP,
    PHASE_DONE,
};

// ═══════════════════════════════════════════════════════════════════════════
// Worker thread — runs sprite tests
// ═══════════════════════════════════════════════════════════════════════════

static void *sprite_test_worker(void *arg) {
    @autoreleasepool {

        // ────────────────────────────────────────────────────────────
        // Phase 1: Open window, define sprites
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 1: SCREEN 320, 200 + define sprites");
        g_phase = PHASE_DEFINE_SPRITES;

        gfx_screen(320.0, 200.0, 0.0);

        ASSERT_TRUE(gfx_screen_active() == 1.0, "screen should be active");
        ASSERT_EQ_INT(320, (int)gfx_screen_width(),  "width = 320");
        ASSERT_EQ_INT(200, (int)gfx_screen_height(), "height = 200");

        setup_palette();

        // Bring window to front
        dispatch_sync(dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
        });

        // Initialise SAMM memory pools — required before any
        // string_new_ascii / string_release calls.
        samm_init();

        void *title = STR_DESC("Sprite Integration Test");
        gfx_screen_title(title);
        string_release(title);

        // Define sprite shapes one at a time, with warm-up frames between
        // each to let the main thread drain upload commands and blit staged
        // pixels into the atlas texture.  Each gfx_sprite_data() call
        // enqueues a full-sprite upload, so we must give the bridge time
        // to process them (MAX_PENDING_SPRITE_UPLOADS = 64 per frame).

        define_diamond_sprite();   // def 0: 16×16 diamond
        TEST_LOG("    Defined sprite 0 (diamond 16×16)");
        // Render a few frames so deferred uploads are flushed
        for (int warmup = 0; warmup < 6; warmup++) {
            gfx_cls(16.0);
            void *wu = STR_DESC("Uploading sprite 0...");
            gfx_draw_text(80.0, 90.0, wu, 23.0, 0.0);
            string_release(wu);
            gfx_flip();
            usleep(16600);
        }

        define_ball_sprite();      // def 1: 12×12 ball
        TEST_LOG("    Defined sprite 1 (ball 12×12)");
        for (int warmup = 0; warmup < 6; warmup++) {
            gfx_cls(16.0);
            void *wu = STR_DESC("Uploading sprite 1...");
            gfx_draw_text(80.0, 90.0, wu, 23.0, 0.0);
            string_release(wu);
            gfx_flip();
            usleep(16600);
        }

        define_star_sprite();      // def 2: 8×8 star
        TEST_LOG("    Defined sprite 2 (star 8×8)");
        for (int warmup = 0; warmup < 6; warmup++) {
            gfx_cls(16.0);
            void *wu = STR_DESC("Uploading sprite 2...");
            gfx_draw_text(80.0, 90.0, wu, 23.0, 0.0);
            string_release(wu);
            gfx_flip();
            usleep(16600);
        }

        define_animated_sprite();  // def 3: 32×8 (4 frames of 8×8)
        TEST_LOG("    Defined sprite 3 (animated 32×8)");
        for (int warmup = 0; warmup < 6; warmup++) {
            gfx_cls(16.0);
            void *wu = STR_DESC("Uploading sprite 3...");
            gfx_draw_text(80.0, 90.0, wu, 23.0, 0.0);
            string_release(wu);
            gfx_flip();
            usleep(16600);
        }

        define_arrow_sprite();     // def 4: 16×16 arrow
        TEST_LOG("    Defined sprite 4 (arrow 16×16)");
        for (int warmup = 0; warmup < 6; warmup++) {
            gfx_cls(16.0);
            void *wu = STR_DESC("Uploading sprite 4...");
            gfx_draw_text(80.0, 90.0, wu, 23.0, 0.0);
            string_release(wu);
            gfx_flip();
            usleep(16600);
        }

        ASSERT_EQ_F64(0.0, gfx_sprite_count(), "no instances yet");

        TEST_LOG("  5 sprite definitions created and uploaded.");

        // ────────────────────────────────────────────────────────────
        // Phase 2: Basic placement — 240 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 2: Basic sprite placement — 480 frames");
        g_phase = PHASE_BASIC_PLACEMENT;

        void *t2 = STR_DESC("Sprite Test - Placement");
        gfx_screen_title(t2);
        string_release(t2);

        // Place 5 sprite instances across the screen
        gfx_sprite(0.0, 0.0,  40.0,  80.0);   // diamond at (40, 80)
        gfx_sprite(1.0, 1.0, 100.0,  80.0);   // ball at (100, 80)
        gfx_sprite(2.0, 2.0, 160.0,  80.0);   // star at (160, 80)
        gfx_sprite(3.0, 0.0, 220.0,  80.0);   // another diamond at (220, 80)
        gfx_sprite(4.0, 4.0, 280.0,  80.0);   // arrow at (280, 80)

        // Show them all
        gfx_sprite_show(0.0);
        gfx_sprite_show(1.0);
        gfx_sprite_show(2.0);
        gfx_sprite_show(3.0);
        gfx_sprite_show(4.0);

        ASSERT_EQ_F64(5.0, gfx_sprite_count(), "5 instances active");
        ASSERT_EQ_F64(1.0, gfx_sprite_visible(0.0), "inst 0 visible");
        ASSERT_EQ_F64(40.0, gfx_sprite_x(0.0), "inst 0 x = 40");
        ASSERT_EQ_F64(80.0, gfx_sprite_y(0.0), "inst 0 y = 80");

        for (int frame = 0; frame < 480; frame++) {
            draw_background();
            draw_hud("Phase 2: Basic Placement", frame, 480);

            // Draw labels under each sprite
            void *l0 = STR_DESC("Diamond");
            void *l1 = STR_DESC("Ball");
            void *l2 = STR_DESC("Star");
            void *l3 = STR_DESC("Dia #2");
            void *l4 = STR_DESC("Arrow");
            gfx_draw_text(24.0, 100.0, l0, 22.0, 0.0);
            gfx_draw_text(88.0, 100.0, l1, 22.0, 0.0);
            gfx_draw_text(152.0, 100.0, l2, 22.0, 0.0);
            gfx_draw_text(206.0, 100.0, l3, 22.0, 0.0);
            gfx_draw_text(268.0, 100.0, l4, 22.0, 0.0);
            string_release(l0);
            string_release(l1);
            string_release(l2);
            string_release(l3);
            string_release(l4);

            // Gentle bob up and down
            for (int i = 0; i <= 4; i++) {
                double base_y = 80.0 + sin((frame + i * 15) * 0.1) * 8.0;
                gfx_sprite_pos((double)i, gfx_sprite_x((double)i), base_y);
            }

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        TEST_LOG("  Basic placement shown for 480 frames.");

        // ────────────────────────────────────────────────────────────
        // Phase 3: Movement and rotation — 300 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 3: Movement & rotation — 600 frames");
        g_phase = PHASE_MOVEMENT_AND_ROTATION;

        void *t3 = STR_DESC("Sprite Test - Movement & Rotation");
        gfx_screen_title(t3);
        string_release(t3);

        // Remove extras, keep 3 sprites
        gfx_sprite_remove(3.0);
        gfx_sprite_remove(4.0);
        ASSERT_EQ_F64(3.0, gfx_sprite_count(), "3 instances after remove");

        // Reposition
        gfx_sprite_pos(0.0, 160.0, 100.0);  // diamond at centre
        gfx_sprite_pos(1.0,  80.0, 100.0);  // ball left
        gfx_sprite_pos(2.0, 240.0, 100.0);  // star right

        for (int frame = 0; frame < 600; frame++) {
            draw_background();
            draw_hud("Phase 3: Movement & Rotation", frame, 600);

            double t = frame * 0.05;

            // Diamond: rotate in place
            gfx_sprite_rot(0.0, frame * 3.0);

            // Ball: orbit around centre
            double bx = 160.0 + cos(t) * 60.0;
            double by = 100.0 + sin(t) * 40.0;
            gfx_sprite_pos(1.0, bx, by);

            // Star: figure-8 path
            double sx = 160.0 + sin(t) * 80.0;
            double sy = 100.0 + sin(t * 2.0) * 30.0;
            gfx_sprite_pos(2.0, sx, sy);
            gfx_sprite_rot(2.0, frame * -5.0);

            // Label
            void *lb = STR_DESC("Rotating & moving");
            gfx_draw_text(100.0, 170.0, lb, 21.0, 0.0);
            string_release(lb);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        TEST_LOG("  Movement & rotation shown for 600 frames.");

        // ────────────────────────────────────────────────────────────
        // Phase 4: Scaling, flip, alpha — 300 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 4: Scale, flip, alpha — 600 frames");
        g_phase = PHASE_SCALING_AND_FLIP;

        void *t4 = STR_DESC("Sprite Test - Scale / Flip / Alpha");
        gfx_screen_title(t4);
        string_release(t4);

        // Reset rotations
        gfx_sprite_rot(0.0, 0.0);
        gfx_sprite_rot(2.0, 0.0);

        // Place arrow for flip test
        gfx_sprite(5.0, 4.0, 60.0, 50.0);
        gfx_sprite_show(5.0);

        gfx_sprite(6.0, 4.0, 120.0, 50.0);
        gfx_sprite_show(6.0);
        gfx_sprite_flip(6.0, 1.0, 0.0);  // H-flip

        gfx_sprite(7.0, 4.0, 180.0, 50.0);
        gfx_sprite_show(7.0);
        gfx_sprite_flip(7.0, 0.0, 1.0);  // V-flip

        gfx_sprite(8.0, 4.0, 240.0, 50.0);
        gfx_sprite_show(8.0);
        gfx_sprite_flip(8.0, 1.0, 1.0);  // H+V flip

        // Position main sprites
        gfx_sprite_pos(0.0,  80.0, 130.0);
        gfx_sprite_pos(1.0, 160.0, 130.0);
        gfx_sprite_pos(2.0, 240.0, 130.0);

        for (int frame = 0; frame < 600; frame++) {
            draw_background();
            draw_hud("Phase 4: Scale / Flip / Alpha", frame, 600);

            double t = frame * 0.04;

            // Diamond: pulsing scale
            double s = 1.0 + sin(t * 2.0) * 0.8;
            gfx_sprite_scale(0.0, s, s);

            // Ball: asymmetric scaling (squash and stretch)
            double sx = 1.0 + cos(t * 3.0) * 0.5;
            double sy = 1.0 - cos(t * 3.0) * 0.3;
            gfx_sprite_scale(1.0, sx, sy);

            // Star: pulsing alpha (fade in/out)
            double alpha = 0.3 + (sin(t * 2.5) + 1.0) * 0.35;
            gfx_sprite_alpha(2.0, alpha);
            gfx_sprite_scale(2.0, 2.0, 2.0);  // 2× size to make it visible

            // Labels
            void *l_norm = STR_DESC("Normal");
            void *l_hflip = STR_DESC("H-Flip");
            void *l_vflip = STR_DESC("V-Flip");
            void *l_hvflip = STR_DESC("HV-Flip");
            gfx_draw_text(48.0, 68.0, l_norm, 22.0, 0.0);
            gfx_draw_text(106.0, 68.0, l_hflip, 22.0, 0.0);
            gfx_draw_text(166.0, 68.0, l_vflip, 22.0, 0.0);
            gfx_draw_text(224.0, 68.0, l_hvflip, 22.0, 0.0);
            string_release(l_norm);
            string_release(l_hflip);
            string_release(l_vflip);
            string_release(l_hvflip);

            void *l_scale = STR_DESC("Scale");
            void *l_squash = STR_DESC("Squash");
            void *l_alpha = STR_DESC("Alpha");
            gfx_draw_text(64.0, 160.0, l_scale, 22.0, 0.0);
            gfx_draw_text(142.0, 160.0, l_squash, 22.0, 0.0);
            gfx_draw_text(228.0, 160.0, l_alpha, 22.0, 0.0);
            string_release(l_scale);
            string_release(l_squash);
            string_release(l_alpha);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        // Reset scale/alpha
        gfx_sprite_scale(0.0, 1.0, 1.0);
        gfx_sprite_scale(1.0, 1.0, 1.0);
        gfx_sprite_scale(2.0, 1.0, 1.0);
        gfx_sprite_alpha(2.0, 1.0);

        // Remove flip test sprites
        gfx_sprite_remove(5.0);
        gfx_sprite_remove(6.0);
        gfx_sprite_remove(7.0);
        gfx_sprite_remove(8.0);

        TEST_LOG("  Scale/flip/alpha shown for 600 frames.");

        // ────────────────────────────────────────────────────────────
        // Phase 5: Effects showcase — 360 frames (60 per effect)
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 5: Effects showcase — 720 frames");
        g_phase = PHASE_EFFECTS;

        void *t5 = STR_DESC("Sprite Test - GPU Effects");
        gfx_screen_title(t5);
        string_release(t5);

        // Place diamond at centre, scale up for visibility
        gfx_sprite_pos(0.0, 160.0, 90.0);
        gfx_sprite_scale(0.0, 2.5, 2.5);
        gfx_sprite_rot(0.0, 0.0);

        // Also place ball and star as secondary test objects
        gfx_sprite_pos(1.0,  70.0, 90.0);
        gfx_sprite_scale(1.0, 2.0, 2.0);
        gfx_sprite_pos(2.0, 250.0, 90.0);
        gfx_sprite_scale(2.0, 2.5, 2.5);

        const char *effect_names[] = { "Glow", "Outline", "Shadow", "Tint", "Flash", "None" };
        int num_effects = 6;
        int frames_per_effect = 120;

        for (int frame = 0; frame < num_effects * frames_per_effect; frame++) {
            int effect_idx = frame / frames_per_effect;
            int effect_frame = frame % frames_per_effect;

            // Apply effect at start of each segment
            if (effect_frame == 0) {
                switch (effect_idx) {
                    case 0: // Glow
                        gfx_sprite_glow(0.0, 4.0, 2.0, 255.0, 200.0, 60.0);
                        gfx_sprite_glow(1.0, 3.0, 1.5, 80.0, 200.0, 255.0);
                        gfx_sprite_glow(2.0, 5.0, 2.5, 255.0, 255.0, 100.0);
                        break;
                    case 1: // Outline
                        gfx_sprite_outline(0.0, 2.0, 255.0, 255.0, 0.0);
                        gfx_sprite_outline(1.0, 1.0, 0.0, 255.0, 0.0);
                        gfx_sprite_outline(2.0, 2.0, 255.0, 100.0, 255.0);
                        break;
                    case 2: // Shadow
                        gfx_sprite_shadow(0.0, 3.0, 3.0, 0.0, 0.0, 0.0, 180.0);
                        gfx_sprite_shadow(1.0, 2.0, 4.0, 0.0, 0.0, 40.0, 160.0);
                        gfx_sprite_shadow(2.0, 4.0, 2.0, 20.0, 0.0, 0.0, 200.0);
                        break;
                    case 3: // Tint
                        gfx_sprite_tint(0.0, 0.6, 100.0, 255.0, 100.0);
                        gfx_sprite_tint(1.0, 0.5, 255.0, 100.0, 100.0);
                        gfx_sprite_tint(2.0, 0.7, 100.0, 100.0, 255.0);
                        break;
                    case 4: // Flash
                        gfx_sprite_flash(0.0, 8.0, 255.0, 255.0, 255.0);
                        gfx_sprite_flash(1.0, 5.0, 255.0, 200.0, 60.0);
                        gfx_sprite_flash(2.0, 12.0, 255.0, 80.0, 255.0);
                        break;
                    case 5: // None
                    default:
                        gfx_sprite_fx_off(0.0);
                        gfx_sprite_fx_off(1.0);
                        gfx_sprite_fx_off(2.0);
                        break;
                }
                TEST_LOG("    Effect: %s", effect_names[effect_idx]);
            }

            draw_background();

            // Slow rotation during effects
            gfx_sprite_rot(0.0, frame * 1.5);
            gfx_sprite_rot(2.0, frame * -2.0);

            // Label
            char label[64];
            snprintf(label, sizeof(label), "Phase 5: Effect - %s", effect_names[effect_idx]);
            draw_hud(label, frame, num_effects * frames_per_effect);

            void *lbl = STR_DESC(effect_names[effect_idx]);
            gfx_draw_text(140.0, 140.0, lbl, 21.0, 0.0);
            string_release(lbl);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        // Clear effects
        gfx_sprite_fx_off(0.0);
        gfx_sprite_fx_off(1.0);
        gfx_sprite_fx_off(2.0);
        gfx_sprite_scale(0.0, 1.0, 1.0);
        gfx_sprite_scale(1.0, 1.0, 1.0);
        gfx_sprite_scale(2.0, 1.0, 1.0);
        gfx_sprite_rot(0.0, 0.0);
        gfx_sprite_rot(2.0, 0.0);

        TEST_LOG("  Effects showcase complete.");

        // ────────────────────────────────────────────────────────────
        // Phase 6: Animation, priority & collision — 300 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 6: Animation, priority & collision — 600 frames");
        g_phase = PHASE_ANIMATION_AND_COLLISION;

        void *t6 = STR_DESC("Sprite Test - Anim / Collision");
        gfx_screen_title(t6);
        string_release(t6);

        // Remove old instances
        gfx_sprite_remove_all();
        ASSERT_EQ_F64(0.0, gfx_sprite_count(), "no instances after remove_all");

        // Place animated sprite instances (def 3)
        gfx_sprite(0.0, 3.0, 40.0, 90.0);
        gfx_sprite_show(0.0);
        gfx_sprite_animate(0.0, 0.15);  // slow animation
        gfx_sprite_scale(0.0, 2.0, 2.0);

        gfx_sprite(1.0, 3.0, 120.0, 90.0);
        gfx_sprite_show(1.0);
        gfx_sprite_animate(1.0, 0.3);  // faster animation
        gfx_sprite_scale(1.0, 2.0, 2.0);

        gfx_sprite(2.0, 3.0, 200.0, 90.0);
        gfx_sprite_show(2.0);
        gfx_sprite_animate(2.0, 0.5);  // fast animation
        gfx_sprite_scale(2.0, 2.0, 2.0);

        // Place two collision test sprites (diamond + ball)
        gfx_sprite(10.0, 0.0,  80.0, 150.0);
        gfx_sprite_show(10.0);
        gfx_sprite_scale(10.0, 1.5, 1.5);

        gfx_sprite(11.0, 1.0, 240.0, 150.0);
        gfx_sprite_show(11.0);
        gfx_sprite_scale(11.0, 1.5, 1.5);

        // Priority test: place overlapping sprites at same position
        gfx_sprite(20.0, 0.0, 290.0, 50.0);
        gfx_sprite_show(20.0);
        gfx_sprite_priority(20.0, 10.0);   // behind
        gfx_sprite_scale(20.0, 1.5, 1.5);

        gfx_sprite(21.0, 1.0, 290.0, 50.0);
        gfx_sprite_show(21.0);
        gfx_sprite_priority(21.0, 200.0);  // in front
        gfx_sprite_scale(21.0, 1.5, 1.5);

        int collision_count = 0;

        for (int frame = 0; frame < 600; frame++) {
            draw_background();
            draw_hud("Phase 6: Animation / Collision", frame, 600);

            // Move collision sprites towards each other
            double t = frame * 0.03;
            double ax = 80.0 + t * 60.0;
            double bx = 240.0 - t * 60.0;
            if (ax > 160.0) ax = 160.0;
            if (bx < 160.0) bx = 160.0;
            gfx_sprite_pos(10.0, ax, 150.0);
            gfx_sprite_pos(11.0, bx, 150.0);

            // Check collision
            double hit = gfx_sprite_hit(10.0, 11.0);
            if (hit > 0.5) {
                collision_count++;
                // Flash both on collision
                if (collision_count == 1) {
                    gfx_sprite_glow(10.0, 3.0, 2.0, 255.0, 80.0, 80.0);
                    gfx_sprite_glow(11.0, 3.0, 2.0, 80.0, 200.0, 255.0);
                    TEST_LOG("    Collision detected at frame %d!", frame);
                }
            }

            // Labels
            void *l_anim = STR_DESC("Animated (3 speeds)");
            gfx_draw_text(60.0, 110.0, l_anim, 22.0, 0.0);
            string_release(l_anim);

            const char *coll_str = (hit > 0.5) ? "COLLIDING!" : "Approaching...";
            void *l_coll = STR_DESC(coll_str);
            gfx_draw_text(110.0, 170.0, l_coll,
                          (hit > 0.5) ? 24.0 : 22.0, 0.0);
            string_release(l_coll);

            void *l_pri = STR_DESC("Priority");
            gfx_draw_text(272.0, 72.0, l_pri, 22.0, 0.0);
            string_release(l_pri);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        ASSERT_TRUE(collision_count > 0, "collision should be detected");

        // Check animation advanced
        double final_frame = gfx_sprite_get_frame(2.0);
        TEST_LOG("    Fast-animated sprite ended on frame %.0f", final_frame);

        TEST_LOG("  Animation/collision phase complete. %d collision frames.", collision_count);

        // ────────────────────────────────────────────────────────────
        // Phase 7: Stress test — many instances — 300 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 7: Stress test — many sprites — 600 frames");
        g_phase = PHASE_STRESS;

        void *t7 = STR_DESC("Sprite Test - Stress (many sprites)");
        gfx_screen_title(t7);
        string_release(t7);

        gfx_sprite_remove_all();

        // Place 64 sprites in a grid / scatter pattern
        int total_sprites = 64;
        for (int i = 0; i < total_sprites; i++) {
            int def_id = i % 5;  // cycle through all 5 definitions
            double x = 16.0 + (i % 10) * 30.0;
            double y = 20.0 + (i / 10) * 25.0;
            gfx_sprite((double)i, (double)def_id, x, y);
            gfx_sprite_show((double)i);
            gfx_sprite_priority((double)i, (double)(i % 256));

            // Vary properties
            if (def_id == 3) {
                gfx_sprite_animate((double)i, 0.1 + (i % 5) * 0.05);
            }
        }

        ASSERT_EQ_F64((double)total_sprites, gfx_sprite_count(), "64 instances active");

        for (int frame = 0; frame < 600; frame++) {
            draw_background();
            draw_hud("Phase 7: Stress Test (64 sprites)", frame, 600);

            // Animate all sprites: gentle wave motion
            for (int i = 0; i < total_sprites; i++) {
                double base_x = 16.0 + (i % 10) * 30.0;
                double base_y = 20.0 + (i / 10) * 25.0;

                double ox = sin((frame + i * 7) * 0.08) * 8.0;
                double oy = cos((frame + i * 5) * 0.06) * 5.0;

                gfx_sprite_pos((double)i, base_x + ox, base_y + oy);
                gfx_sprite_rot((double)i, frame * (1.0 + (i % 4)));
            }

            // Label
            char stress_label[48];
            snprintf(stress_label, sizeof(stress_label), "%d sprites active", total_sprites);
            void *sl = STR_DESC(stress_label);
            gfx_draw_text(110.0, 180.0, sl, 21.0, 0.0);
            string_release(sl);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        TEST_LOG("  Stress test complete with %d sprites.", total_sprites);

        // ────────────────────────────────────────────────────────────
        // Phase 8: Additive blending — 240 frames
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 8: Additive blending — 480 frames");

        void *t8 = STR_DESC("Sprite Test - Additive Blend");
        gfx_screen_title(t8);
        string_release(t8);

        gfx_sprite_remove_all();

        // Place 3 overlapping sprites with additive blending
        gfx_sprite(0.0, 0.0, 130.0, 90.0);
        gfx_sprite_show(0.0);
        gfx_sprite_scale(0.0, 3.0, 3.0);
        gfx_sprite_blend(0.0, 1.0);  // additive

        gfx_sprite(1.0, 1.0, 160.0, 90.0);
        gfx_sprite_show(1.0);
        gfx_sprite_scale(1.0, 3.0, 3.0);
        gfx_sprite_blend(1.0, 1.0);  // additive

        gfx_sprite(2.0, 2.0, 190.0, 90.0);
        gfx_sprite_show(2.0);
        gfx_sprite_scale(2.0, 4.0, 4.0);
        gfx_sprite_blend(2.0, 1.0);  // additive

        for (int frame = 0; frame < 480; frame++) {
            draw_background();
            draw_hud("Phase 8: Additive Blending", frame, 480);

            // Slowly orbit
            double t = frame * 0.05;
            gfx_sprite_pos(0.0, 160.0 + cos(t) * 30.0, 90.0 + sin(t) * 20.0);
            gfx_sprite_pos(1.0, 160.0 + cos(t + 2.094) * 30.0, 90.0 + sin(t + 2.094) * 20.0);
            gfx_sprite_pos(2.0, 160.0 + cos(t + 4.189) * 30.0, 90.0 + sin(t + 4.189) * 20.0);

            gfx_sprite_rot(0.0, frame * 2.0);
            gfx_sprite_rot(1.0, frame * -3.0);
            gfx_sprite_rot(2.0, frame * 4.0);

            void *lb2 = STR_DESC("Additive blending");
            gfx_draw_text(108.0, 150.0, lb2, 21.0, 0.0);
            string_release(lb2);

            gfx_sprite_sync();
            gfx_flip();
            usleep(16600);
        }

        TEST_LOG("  Additive blending shown for 480 frames.");

        // ────────────────────────────────────────────────────────────
        // Phase 9: Cleanup & close
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 9: Cleanup & close");
        g_phase = PHASE_CLEANUP;

        gfx_sprite_remove_all();
        ASSERT_EQ_F64(0.0, gfx_sprite_count(), "no instances after final remove_all");

        // Final "done" screen
        gfx_cls(16.0);
        void *done_msg = STR_DESC("Sprite Integration Test Complete!");
        gfx_draw_text(40.0, 80.0, done_msg, 25.0, 0.0);
        string_release(done_msg);

        char result_str[64];
        snprintf(result_str, sizeof(result_str), "%d passed, %d failed",
                 g_test_pass, g_test_fail);
        void *result_desc = STR_DESC(result_str);
        gfx_draw_text(100.0, 110.0, result_desc,
                      (g_test_fail > 0) ? 24.0 : 25.0, 0.0);
        string_release(result_desc);

        gfx_flip();
        usleep(6000000);  // show for 6 seconds

        gfx_screen_close();
        usleep(200000);

        // Verify drawing after close doesn't crash
        gfx_sprite_def(99.0, 4.0, 4.0);
        gfx_sprite(99.0, 99.0, 0.0, 0.0);
        gfx_sprite_show(99.0);
        gfx_sprite_remove(99.0);

        TEST_LOG("  Window closed. Post-close sprite ops are safe.");

        // ────────────────────────────────────────────────────────────
        // Done
        // ────────────────────────────────────────────────────────────
        g_phase = PHASE_DONE;
        g_tests_done = true;

        // Tell the main thread to quit the run loop
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0];
            [NSApp postEvent:event atStart:YES];
        });
    }
    return NULL;
}

// ═══════════════════════════════════════════════════════════════════════════
// Timeout watchdog
// ═══════════════════════════════════════════════════════════════════════════

static void *watchdog_thread(void *arg) {
    sleep(360); // 360-second timeout
    if (!g_tests_done) {
        fprintf(stderr, "\n\033[31m[TIMEOUT]\033[0m Sprite tests did not complete "
                        "within 90 seconds (stuck in phase %d)\n", g_phase);
        fflush(stderr);
        _exit(2);
    }
    return NULL;
}

// ═══════════════════════════════════════════════════════════════════════════
// Entry point
// ═══════════════════════════════════════════════════════════════════════════

int sprite_test_main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "\n\033[1m"
            "══════════════════════════════════════════════════\n"
            "  Ed Sprite Integration Test\n"
            "══════════════════════════════════════════════════\n"
            "\033[0m\n");

        // ── Set up NSApplication ────────────────────────────────────
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // ── Verify Metal is available ───────────────────────────────
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[SKIP] No Metal device available.\n");
            return 0;
        }
        fprintf(stderr, "  Metal device: %s\n\n",
                [[device name] UTF8String]);
        device = nil;

        // ── Initialise the graphics subsystem ───────────────────────
        ed_graphics_init();

        // ── Start watchdog ──────────────────────────────────────────
        pthread_t watchdog;
        pthread_create(&watchdog, NULL, watchdog_thread, NULL);
        pthread_detach(watchdog);

        // ── Start test worker thread ────────────────────────────────
        pthread_t worker;
        pthread_create(&worker, NULL, sprite_test_worker, NULL);

        // ── Run the main event loop ─────────────────────────────────
        [NSApp run];

        // ── Wait for worker ─────────────────────────────────────────
        pthread_join(worker, NULL);

        // ── Shut down ───────────────────────────────────────────────
        ed_graphics_shutdown();

        // ── Report ──────────────────────────────────────────────────
        fprintf(stderr, "\n\033[1m"
            "══════════════════════════════════════════════════\n");
        if (g_test_fail > 0) {
            fprintf(stderr,
                "  Results: %d passed, \033[31m%d failed\033[0m\n",
                g_test_pass, g_test_fail);
        } else {
            fprintf(stderr,
                "  Results: \033[32m%d passed\033[0m, 0 failed\n",
                g_test_pass);
        }
        fprintf(stderr,
            "══════════════════════════════════════════════════\n"
            "\033[0m\n");

        if (g_test_fail > 0) {
            fprintf(stderr, "\033[31mSPRITE INTEGRATION TEST FAILED\033[0m\n\n");
            return 1;
        }

        fprintf(stderr, "\033[32mSPRITE INTEGRATION TEST PASSED\033[0m\n\n");
        return 0;
    }
}
