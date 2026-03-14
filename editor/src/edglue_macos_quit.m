#import <Cocoa/Cocoa.h>
#include <stdbool.h>
#include <stdint.h>

bool edglue_request_mac_quit(int pid) {
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
        if (app == nil) return false;
        return [app terminate];
    }
}

bool edglue_force_mac_quit(int pid) {
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
        if (app == nil) return false;
        return [app forceTerminate];
    }
}

bool edglue_request_mac_front(int pid) {
    @autoreleasepool {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
        if (app == nil) return false;

        if (app.hidden) {
            [app unhide];
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [app activateWithOptions:(NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps)];
#pragma clang diagnostic pop
    }
}