// ─── Ed Graphics Integration Test ──────────────────────────────────────────
//
// Standalone Objective-C integration test that exercises the real graphics
// window lifecycle:  Metal device, MTKView, dispatch_sync to main thread,
// shared MTLBuffer allocation, buffer pointer handoff to Zig, drawing,
// SCREENTITLE, FLIP, SCREENCLOSE, and re-open.
//
// This is the code path that crashes in production (gfx_screen + 800 on a
// GCD thread) and that the pure-Zig GraphicsState unit tests cannot reach
// because they use heap-allocated byte arrays instead of real Metal buffers.
//
// Build:  zig build test-graphics
//         (Requires a display — will skip gracefully if no Metal device.)

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
// Stubs for symbols referenced by ed_graphics_bridge.m that are not
// part of the graphics subsystem itself.
// ═══════════════════════════════════════════════════════════════════════════

__attribute__((weak)) void basic_jit_stop(void) {
    fprintf(stderr, "  [STUB] basic_jit_stop called\n");
}

__attribute__((weak)) void timer_tick_frame(void) {
    // no-op — frame-based messaging timers not needed in test
}

// ═══════════════════════════════════════════════════════════════════════════
// Extern Zig functions (ed_graphics.zig / graphics_runtime.zig exports)
// ═══════════════════════════════════════════════════════════════════════════

// JIT compile + execute (defined in ed_graphics_integration_root.zig)
extern int jit_compile_and_run(const char *source, size_t len);

extern void gfx_set_pixel_buffer(int index, void *ptr, uint64_t size);
extern void gfx_set_line_palette(void *ptr, uint32_t line_count);
extern void gfx_set_global_palette(void *ptr);
extern void gfx_set_palette_effects(void *ptr);
extern void gfx_set_collision_flags(void *ptr);
extern void gfx_clear_buffer_pointers(void);
extern void gfx_mark_closed(void);
extern void gfx_reset_sync(void);
extern void gfx_signal_vsync(void);
extern void gfx_signal_gpu_wait(void);
extern void gfx_update_fence(uint32_t fence);
extern void gfx_get_resolution(uint16_t *w, uint16_t *h,
                                uint16_t *bw, uint16_t *bh,
                                uint16_t *ox, uint16_t *oy);
extern uint8_t gfx_get_front_buffer(void);
extern void gfx_get_scroll(int16_t *sx, int16_t *sy);
extern int32_t gfx_dequeue_command(uint8_t *cmd_type, uint32_t *fence,
                                    uint8_t *payload);

// Runtime functions (f64 calling convention — same as JIT calls)
extern void gfx_screen(double w, double h, double scale);
extern void gfx_screen_close(void);
extern void gfx_screen_title(const void *desc);
extern void gfx_pset(double x, double y, double c);
extern double gfx_pget(double x, double y);
extern void gfx_cls(double c);
extern void gfx_line(double x1, double y1, double x2, double y2, double c);
extern void gfx_rect(double x, double y, double w, double h, double c,
                      double filled);
extern void gfx_circle(double cx, double cy, double r, double c,
                        double filled);
extern void gfx_ellipse(double cx, double cy, double rx, double ry,
                         double c, double filled);
extern void gfx_draw_text(double x, double y, const void *desc,
                           double c, double font);
extern void gfx_flip(void);
extern void gfx_palette(double idx, double r, double g, double b);
extern void gfx_set_target(double buf);
extern void gfx_blit_solid(double sb, double sx, double sy,
                            double db, double dx, double dy,
                            double w, double h);
extern void gfx_set_scroll(double x, double y);
extern double gfx_screen_width(void);
extern double gfx_screen_height(void);
extern double gfx_screen_active(void);
extern void gfx_vsync(void);

// Window lifecycle (ed_graphics_bridge.m)
extern void gfx_create_window_sync(uint16_t w, uint16_t h, uint16_t scale);
extern void gfx_destroy_window_async(void);
extern void ed_graphics_init(void);
extern void ed_graphics_shutdown(void);

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

// ═══════════════════════════════════════════════════════════════════════════
// Real StringDescriptor runtime — linked from string_utf32.zig
// ═══════════════════════════════════════════════════════════════════════════
//
// gfx_screen_title() and gfx_draw_text() expect a pointer to a BASIC
// StringDescriptor which they pass to string_to_utf8().  We now link the
// real Zig runtime (string_utf32, samm_core, samm_pool) so the same
// string_to_utf8 / string_new_ascii that JIT-compiled BASIC code uses
// is also used by the test's own direct calls.  This eliminates the
// symbol collision that previously caused intermittent corruption.

extern void  *string_new_ascii(const char *s);
extern void   string_release(void *desc);
extern void   samm_init(void);

// Convenience: create a StringDescriptor from a C string literal.
// Caller must string_release() the result when done.
#define STR_DESC(cstr) string_new_ascii(cstr)

// ═══════════════════════════════════════════════════════════════════════════
// Drawing helpers — build visible content
// ═══════════════════════════════════════════════════════════════════════════

static void setup_palette(void) {
    // Background: deep blue-purple
    gfx_palette(16.0, 16.0, 12.0, 40.0);
    // Star colours
    gfx_palette(17.0, 255.0, 200.0, 60.0);
    gfx_palette(18.0, 60.0, 180.0, 255.0);
    // Player body
    gfx_palette(19.0, 255.0, 80.0, 80.0);
    // Accent green
    gfx_palette(20.0, 80.0, 255.0, 120.0);
    // White
    gfx_palette(21.0, 255.0, 255.0, 255.0);
    // Dim text
    gfx_palette(22.0, 100.0, 100.0, 140.0);
    // Bright text
    gfx_palette(23.0, 200.0, 200.0, 220.0);
    // Orange
    gfx_palette(24.0, 255.0, 160.0, 40.0);
    // Cyan trail
    gfx_palette(25.0, 40.0, 200.0, 220.0);
}

// Pre-render a starfield into buffer 4
static void render_starfield(void) {
    gfx_set_target(4.0);
    gfx_cls(16.0);

    for (int i = 0; i < 120; i++) {
        int sx = (i * 197 + 31) % 320;
        int sy = (i * 113 + 17) % 200;
        int sc = 21 + (i % 3);
        if (sc > 23) sc = 22;
        gfx_pset((double)sx, (double)sy, (double)sc);
    }

    gfx_set_target(1.0);
}

// Draw one frame of the bouncing-ball animation
static void draw_frame(int frame, double px, double py, double angle) {
    int ix = (int)px;
    int iy = (int)py;

    // Copy starfield as background
    gfx_blit_solid(4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 320.0, 200.0);

    // Trail dots
    for (int t = 1; t <= 6; t++) {
        double tx = px - cos(angle - t * 0.15) * t * 4;
        double ty = py - sin(angle - t * 0.15) * t * 4;
        if (tx > 1 && tx < 318 && ty > 1 && ty < 198) {
            gfx_pset(tx, ty, 25.0);
        }
    }

    // Diamond body
    gfx_line(ix, iy - 7, ix + 6, iy, 19.0);
    gfx_line(ix + 6, iy, ix, iy + 7, 19.0);
    gfx_line(ix, iy + 7, ix - 6, iy, 19.0);
    gfx_line(ix - 6, iy, ix, iy - 7, 19.0);

    // Centre dot
    gfx_pset(ix, iy, 21.0);

    // Orbiting accent circles
    double ox, oy;
    ox = ix + cos(angle) * 14;
    oy = iy + sin(angle) * 14;
    gfx_circle(ox, oy, 2.0, 19.0, 1.0);

    ox = ix + cos(angle + 2.094) * 14;
    oy = iy + sin(angle + 2.094) * 14;
    gfx_circle(ox, oy, 2.0, 20.0, 1.0);

    ox = ix + cos(angle + 4.189) * 14;
    oy = iy + sin(angle + 4.189) * 14;
    gfx_circle(ox, oy, 2.0, 24.0, 1.0);

    // Outer ring (ellipse)
    gfx_ellipse(ix, iy, 20.0, 12.0, 18.0, 0.0);
}

// ═══════════════════════════════════════════════════════════════════════════
// Test phases
// ═══════════════════════════════════════════════════════════════════════════

static volatile int g_phase = 0;
static volatile bool g_tests_done = false;

enum {
    PHASE_INIT = 0,
    PHASE_OPEN_WINDOW,
    PHASE_DRAW_ANIMATION,
    PHASE_TITLE_CHANGES,
    PHASE_CLOSE_WINDOW,
    PHASE_REOPEN_WINDOW,
    PHASE_DRAW_AFTER_REOPEN,
    PHASE_CLOSE_FINAL,
    PHASE_JIT_TESTS,
    PHASE_DONE,
};

// ═══════════════════════════════════════════════════════════════════════════
// Worker thread — simulates the JIT execution thread
// ═══════════════════════════════════════════════════════════════════════════

static void *test_worker_thread(void *arg) {
    @autoreleasepool {

        // Initialise SAMM memory pools — required before any
        // string_new_ascii / string_release calls.
        samm_init();

        // ────────────────────────────────────────────────────────────
        // Phase 1: Open window
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 1: SCREEN 320, 200");
        g_phase = PHASE_OPEN_WINDOW;

        gfx_screen(320.0, 200.0, 0.0);

        ASSERT_TRUE(gfx_screen_active() == 1.0,
                     "screen should be active after SCREEN");
        ASSERT_EQ_INT(320, (int)gfx_screen_width(),  "width = 320");
        ASSERT_EQ_INT(200, (int)gfx_screen_height(), "height = 200");

        // Verify buffer pointers by writing + reading a pixel
        gfx_pset(0.0, 0.0, 1.0);
        double p = gfx_pget(0.0, 0.0);
        ASSERT_EQ_INT(1, (int)p, "pget returns what pset wrote");

        // Set up palette and starfield
        setup_palette();
        render_starfield();

        // Bring the window to front
        dispatch_sync(dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
        });

        TEST_LOG("  Window opened, buffers valid, palette set.");

        // ────────────────────────────────────────────────────────────
        // Phase 2: Animated drawing — 120 frames (~2 seconds at 60fps)
        // ────────────────────────────────────────────────────────────
        g_phase = PHASE_DRAW_ANIMATION;

        void *title_anim = STR_DESC("Integration Test - Animation");
        gfx_screen_title(title_anim);
        string_release(title_anim);

        double px = 160.0, py = 100.0;
        double vx = 2.4, vy = 1.6;
        double angle = 0.0;

        TEST_LOG("▸ Phase 2: Bouncing diamond — 120 frames");

        for (int frame = 0; frame < 120; frame++) {
            // Update position
            px += vx;
            py += vy;
            if (px < 20)  { px = 20;  vx = -vx; }
            if (px > 300) { px = 300; vx = -vx; }
            if (py < 20)  { py = 20;  vy = -vy; }
            if (py > 180) { py = 180; vy = -vy; }
            angle += 0.06;

            // Draw
            draw_frame(frame, px, py, angle);

            // HUD text
            void *hud1 = STR_DESC("Graphics Integration Test");
            gfx_draw_text(4.0, 4.0, hud1, 23.0, 0.0);
            string_release(hud1);

            char frame_str[32];
            snprintf(frame_str, sizeof(frame_str), "Frame %d/120", frame + 1);
            void *hud2 = STR_DESC(frame_str);
            gfx_draw_text(4.0, 190.0, hud2, 22.0, 0.0);
            string_release(hud2);

            gfx_flip();
            usleep(16600); // ~60 fps
        }

        // Verify drawing integrity
        gfx_cls(0.0);
        gfx_pset(50.0, 50.0, 42.0);
        p = gfx_pget(50.0, 50.0);
        ASSERT_EQ_INT(42, (int)p, "pget after 120 frames");

        TEST_LOG("  120 frames drawn.");

        // ────────────────────────────────────────────────────────────
        // Phase 3: SCREENTITLE changes — visible in the title bar
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 3: SCREENTITLE variations");
        g_phase = PHASE_TITLE_CHANGES;

        const char *titles[] = {
            "Title 1 - ASCII",
            "Title 2 - Em Dash",
            "Title 3: ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrst",
            "Title 4: Final title before close",
        };

        for (int i = 0; i < 4; i++) {
            void *td = STR_DESC(titles[i]);
            gfx_screen_title(td);
            string_release(td);

            // Draw a frame with the title number so it's visible
            gfx_cls(16.0);
            gfx_rect(80.0, 60.0, 160.0, 80.0, 18.0, 1.0);

            char label[64];
            snprintf(label, sizeof(label), "SCREENTITLE #%d", i + 1);
            void *lb = STR_DESC(label);
            gfx_draw_text(100.0, 90.0, lb, 21.0, 0.0);
            string_release(lb);

            gfx_flip();

            // Hold each title for 0.5s so it's readable
            for (int f = 0; f < 30; f++) {
                usleep(16600);
            }
        }

        // Also test a very long title (should truncate, not crash)
        void *title_long = STR_DESC(
            "This is a very long title string that exceeds the "
            "52-byte maximum and should be safely truncated");
        gfx_screen_title(title_long);
        string_release(title_long);
        usleep(100000);

        TEST_LOG("  5 title changes completed.");

        // ────────────────────────────────────────────────────────────
        // Phase 4: SCREENCLOSE
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 4: SCREENCLOSE");
        g_phase = PHASE_CLOSE_WINDOW;

        // Show "closing..." for a moment
        gfx_cls(16.0);
        void *closing = STR_DESC("Closing window...");
        gfx_draw_text(100.0, 90.0, closing, 19.0, 0.0);
        string_release(closing);
        gfx_flip();
        usleep(500000); // 0.5s visible

        gfx_screen_close();
        usleep(200000); // let async close finish

        // Drawing after close — must not crash (null guards)
        gfx_pset(10.0, 10.0, 5.0);
        gfx_cls(0.0);
        gfx_line(0.0, 0.0, 10.0, 10.0, 1.0);
        gfx_circle(50.0, 50.0, 5.0, 1.0, 0.0);
        gfx_rect(0.0, 0.0, 10.0, 10.0, 1.0, 1.0);

        TEST_LOG("  Window closed. Drawing after close is safe.");

        // Pause so the user sees the window is gone
        usleep(500000);

        // ────────────────────────────────────────────────────────────
        // Phase 5: Re-open window (fresh Metal buffers)
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 5: Re-open — SCREEN 320, 200");
        g_phase = PHASE_REOPEN_WINDOW;

        gfx_screen(320.0, 200.0, 0.0);

        ASSERT_TRUE(gfx_screen_active() == 1.0,
                     "active after re-open");
        ASSERT_EQ_INT(320, (int)gfx_screen_width(),
                       "width 320 after re-open");

        // Fresh buffers — old data must be gone
        gfx_pset(100.0, 100.0, 99.0);
        p = gfx_pget(100.0, 100.0);
        ASSERT_EQ_INT(99, (int)p, "pget after re-open");

        setup_palette();
        render_starfield();

        // Bring to front again
        dispatch_sync(dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
        });

        void *reopen_title = STR_DESC("Re-opened Window");
        gfx_screen_title(reopen_title);
        string_release(reopen_title);

        TEST_LOG("  Window re-opened, buffers valid.");

        // ────────────────────────────────────────────────────────────
        // Phase 6: Draw after re-open — 90 frames (~1.5 seconds)
        //          Different animation to prove buffers are fresh
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 6: Expanding circles — 90 frames");
        g_phase = PHASE_DRAW_AFTER_REOPEN;

        for (int frame = 0; frame < 90; frame++) {
            // Copy starfield
            gfx_blit_solid(4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 320.0, 200.0);

            // Expanding concentric circles
            for (int ring = 0; ring < 6; ring++) {
                double r = fmod(frame * 0.8 + ring * 12, 80.0);
                int colour = 17 + (ring % 4);
                gfx_circle(160.0, 100.0, r, (double)colour, 0.0);
            }

            // Spinning line
            double lx = 160 + cos(frame * 0.08) * 60;
            double ly = 100 + sin(frame * 0.08) * 60;
            gfx_line(160.0, 100.0, lx, ly, 21.0);

            // Centre dot
            gfx_circle(160.0, 100.0, 3.0, 24.0, 1.0);

            void *hud3 = STR_DESC("After re-open");
            gfx_draw_text(4.0, 4.0, hud3, 23.0, 0.0);
            string_release(hud3);

            // SETSCROLL test — subtle oscillation
            double sx = sin(frame * 0.1) * 3;
            double sy = cos(frame * 0.1) * 2;
            gfx_set_scroll(sx, sy);

            gfx_flip();
            usleep(16600);
        }

        // Reset scroll
        gfx_set_scroll(0.0, 0.0);

        // Verify pixel integrity
        gfx_set_target(1.0);
        gfx_cls(0.0);
        gfx_pset(75.0, 75.0, 33.0);
        p = gfx_pget(75.0, 75.0);
        ASSERT_EQ_INT(33, (int)p, "pget after re-open draw");

        TEST_LOG("  90 frames drawn after re-open.");

        // ────────────────────────────────────────────────────────────
        // Phase 7: Close window before JIT tests
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 7: SCREENCLOSE before JIT tests");
        g_phase = PHASE_CLOSE_FINAL;

        gfx_cls(16.0);
        void *preparing = STR_DESC("Preparing JIT tests...");
        gfx_draw_text(88.0, 90.0, preparing, 23.0, 0.0);
        string_release(preparing);
        gfx_flip();
        usleep(500000);

        gfx_screen_close();
        usleep(200000);

        TEST_LOG("  Window closed.");

        // ────────────────────────────────────────────────────────────
        // Phase 8: JIT — compile and execute real BASIC programs
        //
        // This is the critical test: BASIC source → lex → parse →
        // semantic → codegen → QBE IR → ARM64 → JIT link (resolves
        // gfx_* via dlsym/jump table) → execute on THIS thread.
        //
        // The executed code calls gfx_screen() which dispatch_sync's
        // to the main thread — the exact crash path from the report.
        // ────────────────────────────────────────────────────────────
        TEST_LOG("▸ Phase 8: JIT — compile and execute BASIC programs");

        // ── JIT Test 1: Open window, draw, set title, close ─────────
        {
            TEST_LOG("  JIT test 1: SCREEN + draw + SCREENTITLE + SCREENCLOSE");
            const char *src =
                "SCREEN 320, 200\n"
                "SCREENTITLE \"JIT Test 1 \\xe2\\x80\\x94 Window\"\n"
                "PALETTE 16, 16, 12, 40\n"
                "PALETTE 17, 255, 200, 60\n"
                "PALETTE 21, 255, 255, 255\n"
                "GCLS 16\n"
                "GLINE 0, 0, 319, 199, 17\n"
                "GLINE 319, 0, 0, 199, 17\n"
                "CIRCLE 160, 100, 40, 21, 1\n"
                "PSET 160, 100, 17\n"
                "DRAWTEXT 100, 4, \"JIT compiled!\", 21, 0\n"
                "FLIP\n"
                "SLEEP 800\n"
                "SCREENCLOSE\n"
                "END\n";
            int rc = jit_compile_and_run(src, strlen(src));
            ASSERT_EQ_INT(0, rc, "JIT test 1 should succeed");
            usleep(200000);
        }

        // ── JIT Test 2: Open, draw animation loop, close ────────────
        {
            TEST_LOG("  JIT test 2: animated loop (30 frames)");
            const char *src =
                "SCREEN 320, 200\n"
                "SCREENTITLE \"JIT Test 2 — Animation\"\n"
                "PALETTE 16, 10, 10, 30\n"
                "PALETTE 17, 255, 200, 60\n"
                "PALETTE 18, 60, 180, 255\n"
                "PALETTE 19, 255, 80, 80\n"
                "PALETTE 21, 255, 255, 255\n"
                "DIM px AS DOUBLE, py AS DOUBLE\n"
                "DIM vx AS DOUBLE, vy AS DOUBLE\n"
                "DIM frame AS INTEGER\n"
                "px = 160.0\n"
                "py = 100.0\n"
                "vx = 3.0\n"
                "vy = 2.0\n"
                "FOR frame = 1 TO 30\n"
                "  px = px + vx\n"
                "  py = py + vy\n"
                "  IF px < 20 OR px > 300 THEN vx = -vx\n"
                "  IF py < 20 OR py > 180 THEN vy = -vy\n"
                "  GCLS 16\n"
                "  CIRCLE INT(px), INT(py), 8, 19, 1\n"
                "  PSET INT(px), INT(py), 21\n"
                "  GLINE 0, 0, INT(px), INT(py), 18\n"
                "  DRAWTEXT 4, 4, \"JIT Animation\", 21, 0\n"
                "  FLIP\n"
                "  SLEEP 33\n"
                "NEXT frame\n"
                "SCREENCLOSE\n"
                "END\n";
            int rc = jit_compile_and_run(src, strlen(src));
            ASSERT_EQ_INT(0, rc, "JIT test 2 should succeed");
            usleep(200000);
        }

        // ── JIT Test 3: Close + re-open (lifecycle test) ────────────
        {
            TEST_LOG("  JIT test 3: open, close, re-open");
            const char *src =
                "SCREEN 320, 200\n"
                "SCREENTITLE \"JIT Test 3a — First open\"\n"
                "GCLS 16\n"
                "DRAWTEXT 80, 90, \"First window\", 21, 0\n"
                "FLIP\n"
                "SLEEP 500\n"
                "SCREENCLOSE\n"
                "SLEEP 300\n"
                "SCREEN 320, 200\n"
                "SCREENTITLE \"JIT Test 3b — Re-opened!\"\n"
                "PALETTE 20, 80, 255, 120\n"
                "GCLS 16\n"
                "DRAWTEXT 80, 90, \"Re-opened!\", 20, 0\n"
                "CIRCLE 160, 100, 30, 20, 0\n"
                "FLIP\n"
                "SLEEP 800\n"
                "SCREENCLOSE\n"
                "END\n";
            int rc = jit_compile_and_run(src, strlen(src));
            ASSERT_EQ_INT(0, rc, "JIT test 3 should succeed");
            usleep(200000);
        }

        // ── JIT Test 4: SETTARGET + BLITSOLID ───────────────────────
        {
            TEST_LOG("  JIT test 4: SETTARGET + BLITSOLID");
            const char *src =
                "SCREEN 320, 200\n"
                "SCREENTITLE \"JIT Test 4 — Blit\"\n"
                "PALETTE 16, 10, 10, 30\n"
                "PALETTE 17, 255, 200, 60\n"
                "PALETTE 21, 255, 255, 255\n"
                "' Draw starfield into buffer 4\n"
                "SETTARGET 4\n"
                "GCLS 16\n"
                "DIM i AS INTEGER\n"
                "FOR i = 0 TO 50\n"
                "  PSET (i * 197 + 31) MOD 320, (i * 113 + 17) MOD 200, 21\n"
                "NEXT i\n"
                "' Copy to display buffer and add overlay\n"
                "SETTARGET 0\n"
                "BLITSOLID 4, 0, 0, 0, 0, 0, 320, 200\n"
                "CIRCLE 160, 100, 20, 17, 1\n"
                "DRAWTEXT 100, 4, \"BLIT test\", 21, 0\n"
                "FLIP\n"
                "SLEEP 800\n"
                "SCREENCLOSE\n"
                "END\n";
            int rc = jit_compile_and_run(src, strlen(src));
            ASSERT_EQ_INT(0, rc, "JIT test 4 should succeed");
            usleep(200000);
        }

        TEST_LOG("  JIT tests complete.");

        // ────────────────────────────────────────────────────────────
        // Done
        // ────────────────────────────────────────────────────────────
        g_phase = PHASE_DONE;
        g_tests_done = true;

        // Tell the main thread to quit the run loop
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            // Post a dummy event to unblock the run loop
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
    sleep(60); // 60-second timeout (test takes ~8 seconds)
    if (!g_tests_done) {
        fprintf(stderr, "\n\033[31m[TIMEOUT]\033[0m Tests did not complete "
                        "within 60 seconds (stuck in phase %d)\n", g_phase);
        fflush(stderr);
        _exit(2);
    }
    return NULL;
}

// ═══════════════════════════════════════════════════════════════════════════
// Entry point — set up NSApplication, launch worker thread, run loop
// ═══════════════════════════════════════════════════════════════════════════

int gfx_test_main(int argc, const char *argv[]) {
    @autoreleasepool {
        fprintf(stderr, "\n\033[1m"
            "══════════════════════════════════════════════════\n"
            "  Ed Graphics Integration Test\n"
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
        device = nil; // The bridge creates its own

        // ── Initialise the graphics subsystem ───────────────────────
        ed_graphics_init();

        // ── Start watchdog ──────────────────────────────────────────
        pthread_t watchdog;
        pthread_create(&watchdog, NULL, watchdog_thread, NULL);
        pthread_detach(watchdog);

        // ── Start test worker thread ────────────────────────────────
        pthread_t worker;
        pthread_create(&worker, NULL, test_worker_thread, NULL);

        // ── Run the main event loop ─────────────────────────────────
        //    dispatch_sync from gfx_create_window_sync, the MTKView
        //    render callbacks, and NSWindow display all happen here.
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
            fprintf(stderr, "\033[31mINTEGRATION TEST FAILED\033[0m\n\n");
            return 1;
        }

        fprintf(stderr, "\033[32mINTEGRATION TEST PASSED\033[0m\n\n");
        return 0;
    }
}
