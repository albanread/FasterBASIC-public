// ─── fbc AppKit Runner ──────────────────────────────────────────────────────
//
// Provides a main-thread NSApplication run loop so that fbc --jit programs
// can open graphics windows via the ed_graphics_bridge.m code path.
//
// Problem:
//   The graphics bridge creates NSWindow + MTKView and uses dispatch_sync
//   to the main queue.  MTKView rendering callbacks (drawInMTKView:) and
//   VSYNC signalling require a running Cocoa event loop on the main thread.
//   In fbc --jit mode, the main thread directly executes JIT code — there
//   is no event loop, so window creation hangs or rendering never fires.
//
// Solution:
//   fbc_run_with_appkit() initialises NSApplication with a proper delegate,
//   spawns a background thread to run the JIT-compiled program, and runs
//   [NSApp run] on the main thread.  The delegate handles activation after
//   launch so windows actually appear on screen.  When the worker finishes,
//   it posts [NSApp stop:] + a dummy event to unblock the run loop.
//
// Thread topology:
//
//   Main thread (caller)          Worker thread
//   ─────────────────────         ──────────────────────
//   fbc_run_with_appkit()
//     ├─ [NSApp sharedApp]
//     ├─ set delegate
//     ├─ pthread_create ──────►   (waits for app ready)
//     ├─ [NSApp run]              │
//     │   applicationDidFinish    │
//     │   Launching: ──────────►  work(context) starts
//     │   (services dispatch,     │ gfx_screen → dispatch_sync OK
//     │    MTKView callbacks,     │ gfx_flip, gfx_vsync …
//     │    input events)          │ gfx_screen_close
//     │                           └─ finished
//     │                              [NSApp stop:] + dummy event
//     ├─ [NSApp run] returns
//     ├─ pthread_join
//     └─ return
//
// Called from main.zig via:
//   extern fn fbc_run_with_appkit(work: *const fn(*anyopaque) callconv(.c) void,
//                                  context: *anyopaque) callconv(.c) void;

#import <Cocoa/Cocoa.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>

// ─── ed_graphics_bridge.m symbols we need ───────────────────────────────────

extern void ed_graphics_init(void);

// ─── Worker info ────────────────────────────────────────────────────────────

typedef struct {
    void (*work)(void *);
    void *context;
    volatile bool app_ready;  // set by delegate after finishLaunching
} FbcWorkerInfo;

// ─── NSApplication delegate ─────────────────────────────────────────────────
//
// Without a proper delegate, windows created by dispatch_sync blocks may
// never appear because the process hasn't finished launching.  Cocoa
// requires applicationDidFinishLaunching: to fire before windows become
// visible and the process can activate (appear in Dock, receive focus).

@interface FbcAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, assign) FbcWorkerInfo *workerInfo;
@property (nonatomic, assign) pthread_t workerThread;
@end

@implementation FbcAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Now the process is a proper GUI app — activate it so any
    // windows we create come to the front and receive focus.
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    }

    // Signal the worker thread that it's safe to start.
    // The worker was spinning on this flag waiting for the app to
    // finish launching so that window creation actually works.
    if (self.workerInfo) {
        self.workerInfo->app_ready = true;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;  // We manage our own lifecycle
}

@end

// ─── Minimal menu bar ───────────────────────────────────────────────────────
//
// Without a menu bar the process doesn't appear properly in the Dock and
// Cmd+Q doesn't work.  We create a minimal app menu with Quit.

static void fbc_create_minimal_menu(void) {
    NSMenu *menubar = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] init];

    // Quit item (Cmd+Q)
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    [appMenuItem setSubmenu:appMenu];

    [NSApp setMainMenu:menubar];
}

// ─── Worker thread ──────────────────────────────────────────────────────────

static void *fbc_worker_thread(void *arg) {
    @autoreleasepool {
        FbcWorkerInfo *info = (FbcWorkerInfo *)arg;

        // Wait until the app has finished launching.
        // Without this, window creation may silently fail or the window
        // may be created but never displayed because Cocoa hasn't set
        // up the WindowServer connection yet.
        while (!info->app_ready) {
            usleep(1000);  // 1ms spin — finishLaunching is fast
        }

        // Small extra delay to let the run loop fully settle.
        // This ensures the first dispatch_sync from gfx_create_window_sync
        // is serviced promptly.
        usleep(5000);

        // Run the JIT-compiled program
        info->work(info->context);

        // Work is done — tell the main thread to stop the run loop.
        // We must both call [NSApp stop:] AND post a dummy event,
        // because -[NSApp run] only checks the stop flag when
        // processing an event.
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp stop:nil];

            // Post a dummy event to kick the run loop out of its
            // blocking nextEventMatchingMask: call.
            NSEvent *dummyEvent = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                     location:NSMakePoint(0, 0)
                                                modifierFlags:0
                                                    timestamp:0
                                                 windowNumber:0
                                                      context:nil
                                                      subtype:0
                                                        data1:0
                                                        data2:0];
            [NSApp postEvent:dummyEvent atStart:YES];
        });
    }
    return NULL;
}

// ─── Public C interface ─────────────────────────────────────────────────────

/// Run a function on a background thread while servicing the AppKit
/// event loop on the main thread.  Blocks until `work` returns.
///
/// @param work     Function to execute on the worker thread.
/// @param context  Opaque pointer passed to `work`.
void fbc_run_with_appkit(void (*work)(void *), void *context) {
    @autoreleasepool {
        // ── Initialise NSApplication ────────────────────────────────
        //
        // This is idempotent — safe to call even if already initialised.
        // NSApplicationActivationPolicyRegular gives us a proper GUI
        // process: Dock icon, menu bar, ability to receive focus and
        // display windows.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // ── Create a minimal menu bar ───────────────────────────────
        fbc_create_minimal_menu();

        // ── Set up the delegate ─────────────────────────────────────
        //
        // The delegate's applicationDidFinishLaunching: is the signal
        // that it's safe to create windows.  The worker thread waits
        // for this before calling into the JIT code.
        FbcWorkerInfo info = {
            .work = work,
            .context = context,
            .app_ready = false,
        };

        FbcAppDelegate *delegate = [[FbcAppDelegate alloc] init];
        delegate.workerInfo = &info;
        [NSApp setDelegate:delegate];

        // ── Start the graphics command polling timer ────────────────
        //
        // ed_graphics_init() installs a repeating timer on the main
        // run loop that drains the command ring for commands that
        // arrive before a window exists (once the MTKView is live,
        // drawInMTKView: takes over).  It also starts game controller
        // observation.
        ed_graphics_init();

        // ── Spawn worker thread ─────────────────────────────────────
        //
        // The worker starts immediately but spins on info.app_ready
        // until applicationDidFinishLaunching: fires.
        pthread_t thread;
        int rc = pthread_create(&thread, NULL, fbc_worker_thread, &info);
        if (rc != 0) {
            fprintf(stderr, "[fbc] WARNING: pthread_create failed (%d), "
                            "running without AppKit event loop\n", rc);
            work(context);
            return;
        }

        // ── Run the event loop ──────────────────────────────────────
        //
        // This blocks until [NSApp stop:] is called by the worker
        // thread's completion handler.  While blocked here, the main
        // thread services:
        //   • dispatch_sync blocks from gfx_create_window_sync
        //   • MTKView drawInMTKView: render callbacks
        //   • NSWindow keyboard/mouse events
        //   • Timer callbacks (command polling, game controllers)
        //
        // [NSApp run] internally calls [NSApp finishLaunching] which
        // triggers applicationDidFinishLaunching: on the delegate,
        // which sets info.app_ready = true and activates the app.
        [NSApp run];

        // ── Clean up ────────────────────────────────────────────────
        pthread_join(thread, NULL);

        // Clear delegate to avoid dangling pointer (info is stack-local)
        [NSApp setDelegate:nil];
    }
}
