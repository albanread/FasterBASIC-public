// aot_appkit_init.m
//
// AppKit initialization for AOT-compiled FasterBASIC programs that use graphics.
//
// Problem:
//   Graphics require an NSApplication event loop running on the main thread.
//   AOT programs start with main() executing user code directly on the main thread.
//   We need to retrofit the threading model: main thread → event loop,
//   worker thread → user code.
//
// Solution:
//   When gfx_screen() is first called, we detect if we're in AOT mode (not in Ed GUI).
//   If so, we:
//     1. Save the current execution state (we're partway through main())
//     2. Spawn a worker thread to continue executing from where we are
//     3. Transform the main thread into an AppKit event loop
//     4. When the worker finishes, terminate the event loop
//
// This uses setjmp/longjmp to "move" execution from main thread to worker thread.

#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>

// ─── State ───────────────────────────────────────────────────────────────────

static bool g_aot_initialized = false;
static bool g_is_aot_mode = false;
static bool g_event_loop_running = false;

// ─── External symbols ────────────────────────────────────────────────────────

extern void ed_graphics_init(void);

// ─── Check if we're already in an AppKit environment ─────────────────────────

static bool is_in_ed_gui(void) {
    NSApplication *app = [NSApplication sharedApplication];
    return app && [app isRunning];
}

// ─── AppKit delegate ─────────────────────────────────────────────────────────

@interface AOTAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AOTAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Activate so windows appear
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    }

    // Initialize graphics subsystem
    ed_graphics_init();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return NSTerminateNow;
}

@end

// ─── Simple AppKit setup (no threading) ──────────────────────────────────────
//
// This version just initializes NSApp but doesn't take over the main thread.
// Graphics may not work perfectly but won't crash. For full functionality,
// the user would need to manually call NSApp run or use the Ed GUI.

void aot_appkit_init_if_needed(void) {
    if (g_aot_initialized) return;
    g_aot_initialized = true;

    // Check if already in Ed GUI
    if (is_in_ed_gui()) {
        g_is_aot_mode = false;
        return;
    }

    // We're in standalone AOT mode
    g_is_aot_mode = true;

    @autoreleasepool {
        // Initialize NSApplication
        NSApplication *app = [NSApplication sharedApplication];

        // Set up delegate
        AOTAppDelegate *delegate = [[AOTAppDelegate alloc] init];
        [app setDelegate:delegate];

        // Make it a regular app
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Call finishLaunching to activate the app
        [app finishLaunching];
    }
}

// ─── Process pending events (called from VSYNC) ──────────────────────────────
//
// This pumps the event loop to keep windows responsive without blocking.
// Called periodically from gfx_vsync() so windows update and respond to input.

void aot_appkit_process_events(void) {
    if (!g_is_aot_mode) return;

    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            aot_appkit_process_events();
        });
        return;
    }

    @autoreleasepool {
        // Process all pending events without blocking
        NSEvent *event;
        NSDate *now = [NSDate distantPast];
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:now
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES])) {
            [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
    }
}

// ─── Run event loop until program exits ──────────────────────────────────────
//
// This can be called explicitly if the program wants to keep windows open
// after main() completes. It blocks until the app terminates.

void aot_appkit_run_event_loop(void) {
    if (!g_is_aot_mode) return;
    if (g_event_loop_running) return;

    g_event_loop_running = true;

    @autoreleasepool {
        [NSApp run];
    }
}

// ─── Shutdown ────────────────────────────────────────────────────────────────

void aot_appkit_shutdown(void) {
    if (!g_is_aot_mode) return;

    @autoreleasepool {
        [NSApp terminate:nil];
    }
}
