// ─── Ed Metal Bridge ────────────────────────────────────────────────────────
//
// Objective-C platform layer for Ed. Provides:
//   1. NSApplication + NSWindow setup
//   2. MTKView with Metal rendering pipeline
//   3. Glyph atlas generation via CoreText
//   4. Keyboard/mouse event forwarding to Zig callbacks
//   5. Clipboard access
//   6. Metal shader compilation (from embedded source)
//
// All communication with Zig is through C-callable functions defined in
// platform.zig. The ObjC side never imports Zig headers directly.
//
// This file is compiled by Zig's build system as a C/ObjC source file
// and linked into the Ed binary.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#include <mach/mach_time.h>
#include "generated_help.h"
#include "embedded_glyph_metal_source.h"
#include <string.h>
#include <stdlib.h>

// App/menu naming comes from the graphics bridge (APPNAME BASIC command)
extern NSString *ed_current_app_name(void);

// ─── Help Window Implementation ──────────────────────────────────────────────

static void layoutHelpWindow(NSWindow *helpWindow);

@interface EdHelpWindowController : NSWindowController <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation EdHelpWindowController

- (instancetype)init {
    NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
    const CGFloat default_width = 480.0;
    const CGFloat default_height = 640.0;
    NSRect windowRect = NSMakeRect(screenRect.origin.x + (screenRect.size.width - default_width) * 0.5,
                                   screenRect.origin.y + (screenRect.size.height - default_height) * 0.5,
                                   default_width,
                                   default_height);

    NSWindow *window = [[NSWindow alloc] initWithContentRect:windowRect
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"Faster Basic Help"];

    self = [super initWithWindow:window];
    if (self) {
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        [config.userContentController addScriptMessageHandler:self name:@"runSnippet"];
        [config.userContentController addScriptMessageHandler:self name:@"editSnippet"];
        _webView = [[WKWebView alloc] initWithFrame:[[window contentView] bounds] configuration:config];
        [_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [[window contentView] addSubview:_webView];
        [_webView setNavigationDelegate:self];

        // Load content from generated header
        NSData *data = [NSData dataWithBytes:HELP_HTML_DATA length:HELP_HTML_LEN];
        NSString *htmlString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [_webView loadHTMLString:htmlString baseURL:nil];
    }
    return self;
}

- (void)navigateToKeyword:(const char *)keyword {
    layoutHelpWindow(self.window);
    if (!self.window.isVisible) {
        [self showWindow:nil];
    }
    [self.window makeKeyAndOrderFront:nil];

    // Default to intro if empty
    if (!keyword || strlen(keyword) == 0) {
        [_webView evaluateJavaScript:@"show('intro');" completionHandler:nil];
        return;
    }

    NSString *kw = [NSString stringWithUTF8String:keyword];

    // Special case "intro" passed explicitly
    if ([kw isEqualToString:@"intro"]) {
        [_webView evaluateJavaScript:@"show('intro');" completionHandler:nil];
        return;
    }

    // Attempt to show keyword (try both kw_UPPER and exact match/article)
    // We'll normalize to Upper for keywords.
    // But if it's an article... articles have IDs like article_filename_md.
    // The Zig side likely passes raw tokens/words.

    NSString *upper = [kw uppercaseString];

    // We inject JS to try to find the element. If kw_UPPER exists, show it.
    // Else check if kw matches an ID directly.
    // Else show intro + alert? Or search?

    NSString *js = [NSString stringWithFormat:
        @"var id1 = 'kw_%@'; "
        @"var id2 = '%@'; "
        @"if (document.getElementById(id1)) { show(id1); } "
        @"else if (document.getElementById(id2)) { show(id2); } "
        @"else { show('intro'); search('%@'); }",
        upper, kw, kw];

    [_webView evaluateJavaScript:js completionHandler:nil];
}

// ── WKScriptMessageHandler — receives Run/Edit button clicks from help JS ──
extern void ed_run_snippet(const char *source, uint32_t len);
extern void ed_edit_snippet(const char *source, uint32_t len);

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"runSnippet"]) {
        NSString *code = message.body;
        if ([code isKindOfClass:[NSString class]] && code.length > 0) {
            const char *utf8 = [code UTF8String];
            uint32_t len = (uint32_t)strlen(utf8);
            // Must dispatch to main thread (we're already on it via WK, but
            // ensure Zig state access is safe)
            ed_run_snippet(utf8, len);
        }
    }
    if ([message.name isEqualToString:@"editSnippet"]) {
        NSString *code = message.body;
        if ([code isKindOfClass:[NSString class]] && code.length > 0) {
            const char *utf8 = [code UTF8String];
            uint32_t len = (uint32_t)strlen(utf8);
            ed_edit_snippet(utf8, len);
        }
    }
}

@end

static void layoutHelpWindow(NSWindow *helpWindow) {
    if (!helpWindow) return;

    NSWindow *editorWindow = [NSApp mainWindow];
    if (editorWindow == helpWindow) {
        editorWindow = [NSApp keyWindow];
    }
    if (editorWindow == helpWindow) {
        editorWindow = nil;
    }
    NSScreen *screen = editorWindow ? editorWindow.screen : [NSScreen mainScreen];
    if (!screen) return;

    NSRect screenFrame = screen.visibleFrame;

    const CGFloat gap = 8.0;
    const CGFloat desiredHelpWidth = 480.0;
    const CGFloat minHelpWidth = 360.0;

    if (editorWindow) {
        NSRect editorFrame = editorWindow.frame;

        if (editorFrame.origin.x < screenFrame.origin.x) {
            editorFrame.origin.x = screenFrame.origin.x;
        }
        if (editorFrame.origin.y < screenFrame.origin.y) {
            editorFrame.origin.y = screenFrame.origin.y;
        }
        if (NSMaxY(editorFrame) > NSMaxY(screenFrame)) {
            editorFrame.origin.y = NSMaxY(screenFrame) - editorFrame.size.height;
        }

        CGFloat availableRight = NSMaxX(screenFrame) - NSMaxX(editorFrame) - gap;
        if (availableRight < desiredHelpWidth) {
            CGFloat maxShiftLeft = editorFrame.origin.x - screenFrame.origin.x;
            CGFloat needed = desiredHelpWidth - availableRight;
            CGFloat shift = MIN(maxShiftLeft, needed);
            editorFrame.origin.x -= shift;
            availableRight += shift;

            if (availableRight < desiredHelpWidth) {
                CGFloat minEditorWidth = editorWindow.minSize.width;
                CGFloat reduce = desiredHelpWidth - availableRight;
                CGFloat newWidth = MAX(minEditorWidth, editorFrame.size.width - reduce);
                availableRight += (editorFrame.size.width - newWidth);
                editorFrame.size.width = newWidth;
            }
        }

        [editorWindow setFrame:editorFrame display:YES animate:YES];

        availableRight = NSMaxX(screenFrame) - NSMaxX(editorFrame) - gap;
        CGFloat helpWidth = MIN(desiredHelpWidth, availableRight);
        if (helpWidth < minHelpWidth) {
            helpWidth = MIN(minHelpWidth, availableRight);
        }
        if (helpWidth < 200.0) {
            helpWidth = MAX(200.0, availableRight);
        }

        CGFloat helpX = NSMaxX(editorFrame) + gap;
        CGFloat helpHeight = screenFrame.size.height;
        CGFloat helpY = screenFrame.origin.y;

        if (helpX + helpWidth > NSMaxX(screenFrame)) {
            helpX = NSMaxX(screenFrame) - helpWidth;
        }

        [helpWindow setFrame:NSMakeRect(helpX, helpY, helpWidth, helpHeight)
                     display:YES
                     animate:YES];
    } else {
        CGFloat helpWidth = MIN(desiredHelpWidth, screenFrame.size.width);
        CGFloat helpX = NSMaxX(screenFrame) - helpWidth;
        [helpWindow setFrame:NSMakeRect(helpX,
                                        screenFrame.origin.y,
                                        helpWidth,
                                        screenFrame.size.height)
                     display:YES
                     animate:YES];
    }
}

static EdHelpWindowController *gHelpController = nil;

@interface EdCompilerSettingsDialogController : NSObject
@property (nonatomic, strong) NSTextField *pathField;
@property (nonatomic, strong) NSTextField *optionsField;
- (void)browseCompiler:(id)sender;
@end

@implementation EdCompilerSettingsDialogController

- (void)browseCompiler:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.title = @"Choose Compiler";
    panel.message = @"Select the backend compiler executable Ed should invoke through edglue";

    NSModalResponse response = [panel runModal];
    if (response == NSModalResponseOK) {
        NSURL *url = panel.URL;
        if (url && url.path) {
            self.pathField.stringValue = url.path;
        }
    }
}

@end

void platform_show_help(const char* keyword) {
    if (!gHelpController) {
        gHelpController = [[EdHelpWindowController alloc] init];
    }

    // Must run on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [gHelpController navigateToKeyword:keyword];
    });
}

void platform_set_help_theme(int theme_id) {
    if (!gHelpController) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *js = [NSString stringWithFormat:@"setTheme(%d);", theme_id];
        [gHelpController.webView evaluateJavaScript:js completionHandler:nil];
    });
}

// Show a compiler introspection report (AST/CFG/Symbols/IR/Code) in the help
// WKWebView by calling the JavaScript showReport(title, htmlBody) function.
// title and html_body are null-terminated UTF-8 C strings; html_body is
// already-escaped HTML markup (built in callShowReport in ed_jit.zig).
void platform_show_report(const char* title, const char* html_body) {
    if (!title || !html_body) return;
    NSString *nsTitle    = [NSString stringWithUTF8String:title];
    NSString *nsHtmlBody = [NSString stringWithUTF8String:html_body];
    if (!nsTitle || !nsHtmlBody) return;
    // Use NSJSONSerialization to produce safe JSON strings (handles quotes,
    // backslashes, control characters, etc.) so we can inject them into JS.
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[nsTitle, nsHtmlBody]
                                                       options:0
                                                         error:nil];
    if (!jsonData) return;
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (!json) return;
    // json is an array literal like ["title","<pre>...</pre>"]
    NSString *js = [NSString stringWithFormat:@"(function(){var a=%@;showReport(a[0],a[1]);})();", json];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gHelpController) {
            gHelpController = [[EdHelpWindowController alloc] init];
        }
        [gHelpController showWindow:nil];
        [gHelpController.window makeKeyAndOrderFront:nil];
        [gHelpController.webView evaluateJavaScript:js completionHandler:nil];
    });
}

typedef struct __attribute__((packed)) {
    float pos_x;
    float pos_y;
    float uv_x;
    float uv_y;
    uint8_t fg[4];
    uint8_t bg[4];
    uint32_t flags;
} GlyphInstance;

typedef struct {
    float viewport_width;
    float viewport_height;
    float cell_width;
    float cell_height;
    float atlas_width;
    float atlas_height;
    float time;
    float _pad;
} EdUniforms;

typedef struct {
    const GlyphInstance *instances;
    uint32_t instance_count;
    uint32_t _pad0;
    EdUniforms uniforms;
    float clear_r;
    float clear_g;
    float clear_b;
    float clear_a;
} EdFrameData;

typedef struct {
    float atlas_width;
    float atlas_height;
    float cell_width;
    float cell_height;
    uint32_t cols;
    uint32_t rows;
    uint32_t first_codepoint;
    uint32_t glyph_count;
    float ascent;
    float descent;
    float leading;
    float _pad;
} GlyphAtlasInfo;

typedef struct {
    uint32_t codepoint;
    uint16_t keycode;
    uint32_t modifiers;
    uint8_t  is_repeat;
    uint8_t  _pad;
} KeyEvent;

typedef struct {
    float x;
    float y;
    float scroll_dx;
    float scroll_dy;
    uint8_t button;
    uint8_t click_count;
    uint8_t _pad[2];
} MouseEvent;

typedef struct {
    uint32_t event_type;
    float width;
    float height;
    float scale;
} WindowEvent;

// Callback function pointer types
typedef EdFrameData (*FrameCallbackFn)(double dt);
typedef void (*KeyCallbackFn)(const KeyEvent *);
typedef void (*KeyUpCallbackFn)(const KeyEvent *);
typedef void (*TextCallbackFn)(uint32_t codepoint);
typedef void (*MouseDownCallbackFn)(const MouseEvent *);
typedef void (*MouseUpCallbackFn)(const MouseEvent *);
typedef void (*MouseMovedCallbackFn)(float x, float y);
typedef void (*ScrollCallbackFn)(float dx, float dy);
typedef void (*WindowCallbackFn)(const WindowEvent *);

typedef struct {
    FrameCallbackFn      on_frame;
    KeyCallbackFn        on_key_down;
    KeyUpCallbackFn      on_key_up;
    TextCallbackFn       on_text_input;
    MouseDownCallbackFn  on_mouse_down;
    MouseUpCallbackFn    on_mouse_up;
    MouseMovedCallbackFn on_mouse_moved;
    ScrollCallbackFn     on_scroll;
    WindowCallbackFn     on_window_event;
} EdCallbacks;

// Window event types (must match platform.zig WindowEventType)
enum {
    WINDOW_EVENT_RESIZED       = 0,
    WINDOW_EVENT_MOVED         = 1,
    WINDOW_EVENT_FOCUS_GAINED  = 2,
    WINDOW_EVENT_FOCUS_LOST    = 3,
    WINDOW_EVENT_CLOSE         = 4,
    WINDOW_EVENT_DPI_CHANGED   = 5,
};

// Modifier bit positions (must match platform.zig Modifiers packed struct)
enum {
    MOD_SHIFT     = 1u << 0,
    MOD_CTRL      = 1u << 1,
    MOD_ALT       = 1u << 2,
    MOD_CMD       = 1u << 3,
    MOD_CAPS_LOCK = 1u << 4,
    MOD_FN        = 1u << 5,
};

// ─── Toolbar item identifiers ───────────────────────────────────────────────

static NSToolbarItemIdentifier const EdToolbarRunItem     = @"EdToolbarRun";
static NSToolbarItemIdentifier const EdToolbarStopItem    = @"EdToolbarStop";
static NSToolbarItemIdentifier const EdToolbarTerminalItem = @"EdToolbarTerminal";

// ─── Metal Shader Source ────────────────────────────────────────────────────
// Embedded at compile time from the .metal file. For development we load at
// runtime; the build system can switch to pre-compiled metallib later.

// Forward declaration — shader source embedded in the runtime
static NSString *g_shader_source = nil;

// ─── Globals ────────────────────────────────────────────────────────────────

static EdCallbacks     g_callbacks = {0};
static GlyphAtlasInfo  g_atlas_info = {0};
static float           g_backing_scale = 2.0f; // display scale factor (Retina = 2.0)

// Strong references to delegates — NSApp.delegate and NSWindow.delegate are
// weak properties, so without these globals ARC would deallocate them when
// the @autoreleasepool in ed_platform_init drains, before [NSApp run] fires
// applicationDidFinishLaunching:.  We use `id` here because the ObjC class
// @interfaces are defined further down in this file.
static id g_app_delegate = nil;
static id g_win_delegate = nil;
static id g_renderer     = nil;

static id<MTLDevice>              g_device = nil;
static id<MTLCommandQueue>        g_command_queue = nil;

// Persistent GPU buffer for glyph instances.  setVertexBytes has a 4 KB
// limit; our instance array can easily reach hundreds of KB, so we use a
// proper MTLBuffer that is re-created when it needs to grow.
static id<MTLBuffer>              g_instance_buffer = nil;
static size_t                     g_instance_buffer_capacity = 0;  // bytes
static id<MTLRenderPipelineState> g_glyph_pipeline = nil;
static id<MTLRenderPipelineState> g_solid_pipeline = nil;
static id<MTLTexture>             g_atlas_texture = nil;
static id<MTLSamplerState>        g_sampler = nil;

static MTKView    *g_mtk_view = nil;
static NSWindow   *g_window = nil;
static uint64_t    g_start_time = 0;
static mach_timebase_info_data_t g_timebase = {0};

// ─── Context Menu Extern Declarations (forward) ─────────────────────────────
//
// These are exported from ed_main.zig and provide the bridge between the
// ObjC context menu and the Zig editor state.

extern int      ed_context_menu_is_terminal(float px, float py);
extern uint32_t ed_context_menu_query(void);
extern uint32_t ed_context_menu_word(uint8_t *buf, uint32_t buf_len);
extern void     ed_context_menu_action(uint32_t action);
extern void     ed_context_menu_position_cursor(float x, float y);

// Context menu action IDs (must match ed_main.zig CTX_ACTION_* constants).
enum {
    kCtxGoToDefinition = 0,
    kCtxFindReferences = 1,
    kCtxSymbolOutline  = 2,
    kCtxCut            = 3,
    kCtxCopy           = 4,
    kCtxPaste          = 5,
    kCtxSelectAll      = 6,
    kCtxToggleComment  = 7,
    kCtxDuplicateLine  = 8,
    kCtxFormat         = 9,
    kCtxRename         = 10,
    // Terminal-pane actions (must match CTX_ACTION_TERM_* in ed_main.zig)
    kCtxTermClear      = 20,
    kCtxTermCopy       = 21,
    kCtxTermPaste      = 22,
};

// Menu bar action IDs (must match ed_main.zig MENU_* constants).
enum {
    kMenuNew             = 100,
    kMenuOpen            = 101,
    kMenuSave            = 102,
    kMenuSaveAs          = 103,
    kMenuExportUTF8      = 104,
    kMenuUndo            = 110,
    kMenuRedo            = 111,
    kMenuCut             = 112,
    kMenuCopy            = 113,
    kMenuPaste           = 114,
    kMenuSelectAll       = 115,
    kMenuFind            = 116,
    kMenuFindReplace     = 117,
    kMenuFindNext        = 118,
    kMenuFindPrev        = 119,
    kMenuGoToLine        = 120,
    kMenuFormat          = 130,
    kMenuToggleComment   = 131,
    kMenuDuplicateLine   = 132,
    kMenuFold            = 133,
    kMenuUnfoldAll       = 134,
    kMenuFoldAll         = 135,
    kMenuRename          = 136,
    kMenuGoToDef         = 137,
    kMenuFindRefs        = 138,
    kMenuSymbolOutline   = 139,
    kMenuMatchBracket    = 140,
    kMenuAnalyse         = 141,
    kMenuToggleTerminal  = 150,
    kMenuTermFullscreen  = 151,
    kMenuThemeNext       = 152,
    kMenuThemePrev       = 153,
    kMenuInsertFile      = 154,
    kMenuRun             = 160,
    kMenuBuild           = 161,
    kMenuStop            = 162,
    kMenuViewIR          = 163,
    kMenuViewASM         = 164,
    kMenuDisassemble     = 165,
    kMenuViewAST         = 166,
    kMenuViewCFG         = 167,
    kMenuViewSymbols     = 168,
    kMenuHelp            = 170,
    kMenuMoveLineUp      = 171,
    kMenuMoveLineDown    = 172,
};

// ─── Context Menu Action Target ─────────────────────────────────────────────

@interface EdContextMenuActions : NSObject
- (void)ctxGoToDefinition:(id)sender;
- (void)ctxFindReferences:(id)sender;
- (void)ctxSymbolOutline:(id)sender;
- (void)ctxCut:(id)sender;
- (void)ctxCopy:(id)sender;
- (void)ctxPaste:(id)sender;
- (void)ctxSelectAll:(id)sender;
- (void)ctxToggleComment:(id)sender;
- (void)ctxDuplicateLine:(id)sender;
- (void)ctxFormat:(id)sender;
- (void)ctxRename:(id)sender;
- (void)ctxHelp:(id)sender;
// Terminal pane
- (void)ctxTermClear:(id)sender;
- (void)ctxTermCopy:(id)sender;
- (void)ctxTermPaste:(id)sender;
@end

@implementation EdContextMenuActions
- (void)ctxGoToDefinition:(id)sender { (void)sender; ed_context_menu_action(kCtxGoToDefinition); }
- (void)ctxFindReferences:(id)sender { (void)sender; ed_context_menu_action(kCtxFindReferences); }
- (void)ctxSymbolOutline:(id)sender  { (void)sender; ed_context_menu_action(kCtxSymbolOutline); }
- (void)ctxCut:(id)sender            { (void)sender; ed_context_menu_action(kCtxCut); }
- (void)ctxCopy:(id)sender           { (void)sender; ed_context_menu_action(kCtxCopy); }
- (void)ctxPaste:(id)sender          { (void)sender; ed_context_menu_action(kCtxPaste); }
- (void)ctxSelectAll:(id)sender      { (void)sender; ed_context_menu_action(kCtxSelectAll); }
- (void)ctxToggleComment:(id)sender  { (void)sender; ed_context_menu_action(kCtxToggleComment); }
- (void)ctxDuplicateLine:(id)sender  { (void)sender; ed_context_menu_action(kCtxDuplicateLine); }
- (void)ctxFormat:(id)sender         { (void)sender; ed_context_menu_action(kCtxFormat); }
- (void)ctxRename:(id)sender         { (void)sender; ed_context_menu_action(kCtxRename); }
- (void)ctxTermClear:(id)sender      { (void)sender; ed_context_menu_action(kCtxTermClear); }
- (void)ctxTermCopy:(id)sender       { (void)sender; ed_context_menu_action(kCtxTermCopy); }
- (void)ctxTermPaste:(id)sender      { (void)sender; ed_context_menu_action(kCtxTermPaste); }
- (void)ctxHelp:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    NSString *word = item.representedObject;
    if (word) {
        platform_show_help([word UTF8String]);
    } else {
        platform_show_help("");
    }
}
@end

static EdContextMenuActions *g_ctx_actions = nil;

// ─── Helpers ────────────────────────────────────────────────────────────────

static double getTimeSeconds(void) {
    uint64_t elapsed = mach_absolute_time() - g_start_time;
    uint64_t nanos = elapsed * g_timebase.numer / g_timebase.denom;
    return (double)nanos / 1e9;
}

static uint32_t modifiersFromNSEvent(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags;
    uint32_t mods = 0;
    if (flags & NSEventModifierFlagShift)   mods |= MOD_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= MOD_CTRL;
    if (flags & NSEventModifierFlagOption)  mods |= MOD_ALT;
    if (flags & NSEventModifierFlagCommand) mods |= MOD_CMD;
    if (flags & NSEventModifierFlagCapsLock) mods |= MOD_CAPS_LOCK;
    if (flags & NSEventModifierFlagFunction) mods |= MOD_FN;
    return mods;
}

// ─── Glyph Atlas Builder ────────────────────────────────────────────────────

static BOOL buildGlyphAtlas(const char *font_name, float font_size, float scale) {
    // Create the CoreText font at the BACKING scale for crisp Retina glyphs.
    // All atlas cell dimensions will be in backing (drawable) pixels.
    float scaled_font_size = font_size * scale;

    CFStringRef cf_font_name = CFStringCreateWithCString(NULL, font_name, kCFStringEncodingUTF8);
    CTFontRef ct_font = CTFontCreateWithName(cf_font_name, (CGFloat)scaled_font_size, NULL);
    CFRelease(cf_font_name);

    if (!ct_font) {
        NSLog(@"Ed: Failed to create font '%s', falling back to Menlo", font_name);
        ct_font = CTFontCreateWithName(CFSTR("Menlo"), (CGFloat)scaled_font_size, NULL);
        if (!ct_font) {
            NSLog(@"Ed: FATAL — cannot create any font");
            return NO;
        }
    }

    // Get font metrics
    CGFloat ascent  = CTFontGetAscent(ct_font);
    CGFloat descent = CTFontGetDescent(ct_font);
    CGFloat leading = CTFontGetLeading(ct_font);

    // For a monospaced font, get the advance width of a space character
    CGGlyph space_glyph;
    UniChar space_char = ' ';
    CTFontGetGlyphsForCharacters(ct_font, &space_char, &space_glyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(ct_font, kCTFontOrientationDefault, &space_glyph, &advance, 1);

    float cell_w = (float)ceil(advance.width);
    float cell_h = (float)ceil(ascent + descent + leading);

    // We want at least some reasonable cell size
    if (cell_w < 4.0f) cell_w = 8.0f;
    if (cell_h < 8.0f) cell_h = 16.0f;

    // Atlas layout: printable ASCII 0x20..0x7E = 95 characters
    // Grid: 16 columns × 6 rows = 96 cells (one spare)
    uint32_t first_cp = 0x20;
    uint32_t glyph_count = 95;
    uint32_t cols = 16;
    uint32_t rows = 6;

    float atlas_w = cell_w * (float)cols;
    float atlas_h = cell_h * (float)rows;

    // Ensure power-of-two friendly dimensions for the texture
    uint32_t tex_w = (uint32_t)ceil(atlas_w);
    uint32_t tex_h = (uint32_t)ceil(atlas_h);

    // Round up to next multiple of 4 for alignment
    tex_w = (tex_w + 3) & ~3u;
    tex_h = (tex_h + 3) & ~3u;

    // Create a bitmap context for rendering glyphs
    // Use 8-bit alpha-only for the atlas (we only need the alpha mask)
    size_t bpp = 4; // RGBA for CoreGraphics compatibility
    size_t stride = tex_w * bpp;
    uint8_t *bitmap_data = (uint8_t *)calloc(tex_h * stride, 1);
    if (!bitmap_data) {
        CFRelease(ct_font);
        return NO;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        bitmap_data, tex_w, tex_h, 8, stride,
        color_space,
        kCGImageAlphaPremultipliedLast
    );
    CGColorSpaceRelease(color_space);

    if (!ctx) {
        free(bitmap_data);
        CFRelease(ct_font);
        return NO;
    }

    // Flip coordinate system (CoreGraphics is bottom-up, we want top-down
    // for Metal's texture layout where row 0 is at the top).
    CGContextTranslateCTM(ctx, 0, (CGFloat)tex_h);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    // CRITICAL: CoreText renders glyphs relative to the baseline using its
    // own coordinate system.  When we flip the CGContext, glyph outlines
    // are still drawn in CoreText's native bottom-up orientation, which
    // makes them appear upside-down / mirrored.  Setting the text matrix
    // to scale(1, -1) tells CoreText to flip its glyph paths so they
    // render right-side-up in our flipped context.
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1.0, -1.0));

    // Set white foreground for glyph rendering (we'll use the alpha channel)
    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);

    // Anti-aliasing for nice glyphs
    CGContextSetShouldAntialias(ctx, YES);
    CGContextSetShouldSmoothFonts(ctx, YES);
    CGContextSetAllowsFontSmoothing(ctx, YES);

    // Render each glyph into its cell
    for (uint32_t i = 0; i < glyph_count; i++) {
        uint32_t cp = first_cp + i;
        uint32_t col = i % cols;
        uint32_t row = i / cols;

        // Cell origin (top-left in our flipped coordinate system)
        float cell_x = (float)col * cell_w;
        float cell_y = (float)row * cell_h;

        // Baseline position within the cell
        float baseline_x = cell_x;
        float baseline_y = cell_y + (float)ascent;

        // Create an attributed string for this character
        UniChar uc = (UniChar)cp;
        CFStringRef char_str = CFStringCreateWithCharacters(NULL, &uc, 1);

        CFStringRef keys[] = { kCTFontAttributeName };
        CFTypeRef values[] = { ct_font };
        CFDictionaryRef attrs = CFDictionaryCreate(
            NULL, (const void **)keys, (const void **)values, 1,
            &kCFCopyStringDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );

        CFAttributedStringRef attr_str = CFAttributedStringCreate(NULL, char_str, attrs);
        CTLineRef line = CTLineCreateWithAttributedString(attr_str);

        // Draw the glyph
        CGContextSetTextPosition(ctx, (CGFloat)baseline_x, (CGFloat)baseline_y);
        CTLineDraw(line, ctx);

        CFRelease(line);
        CFRelease(attr_str);
        CFRelease(attrs);
        CFRelease(char_str);
    }

    CGContextFlush(ctx);

    // Create Metal texture from the bitmap
    MTLTextureDescriptor *tex_desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:tex_w
        height:tex_h
        mipmapped:NO];
    tex_desc.usage = MTLTextureUsageShaderRead;
    tex_desc.storageMode = MTLStorageModeShared;

    g_atlas_texture = [g_device newTextureWithDescriptor:tex_desc];
    if (!g_atlas_texture) {
        CGContextRelease(ctx);
        free(bitmap_data);
        CFRelease(ct_font);
        return NO;
    }

    [g_atlas_texture replaceRegion:MTLRegionMake2D(0, 0, tex_w, tex_h)
                       mipmapLevel:0
                         withBytes:bitmap_data
                       bytesPerRow:stride];

    // Store atlas info
    g_atlas_info = (GlyphAtlasInfo){
        .atlas_width  = (float)tex_w,
        .atlas_height = (float)tex_h,
        .cell_width   = cell_w,
        .cell_height  = cell_h,
        .cols         = cols,
        .rows         = rows,
        .first_codepoint = first_cp,
        .glyph_count  = glyph_count,
        .ascent       = (float)ascent,
        .descent      = (float)descent,
        .leading      = (float)leading,
        ._pad         = 0,
    };

    CGContextRelease(ctx);
    free(bitmap_data);
    CFRelease(ct_font);

    NSLog(@"Ed: Glyph atlas built — %ux%u, cell %.0fx%.0f, %u glyphs, font '%s' %.0fpt (scale %.1fx, rendered at %.0fpt)",
          tex_w, tex_h, cell_w, cell_h, glyph_count, font_name, font_size, scale, scaled_font_size);

    return YES;
}

// ─── Metal Pipeline Setup ───────────────────────────────────────────────────

static BOOL buildPipelines(void) {
    NSError *error = nil;

    if (!g_shader_source) {
        g_shader_source = kEmbeddedGlyphMetalSource;
    }

    // Compile shaders from source
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_0;

    id<MTLLibrary> library = [g_device newLibraryWithSource:g_shader_source
                                                   options:opts
                                                     error:&error];
    if (!library) {
        NSLog(@"Ed: Shader compilation failed: %@", error);
        return NO;
    }

    // ── Glyph pipeline (text rendering) ─────────────────────────────────
    {
        id<MTLFunction> vertex_fn   = [library newFunctionWithName:@"glyph_vertex"];
        id<MTLFunction> fragment_fn = [library newFunctionWithName:@"glyph_fragment"];

        if (!vertex_fn || !fragment_fn) {
            NSLog(@"Ed: Cannot find glyph_vertex / glyph_fragment in shader library");
            return NO;
        }

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label = @"Ed Glyph Pipeline";
        desc.vertexFunction   = vertex_fn;
        desc.fragmentFunction = fragment_fn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        // Enable alpha blending for glyph compositing
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;

        g_glyph_pipeline = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!g_glyph_pipeline) {
            NSLog(@"Ed: Glyph pipeline creation failed: %@", error);
            return NO;
        }
    }

    // ── Solid rect pipeline (cursor, selection bg, dividers) ────────────
    {
        id<MTLFunction> vertex_fn   = [library newFunctionWithName:@"solid_vertex"];
        id<MTLFunction> fragment_fn = [library newFunctionWithName:@"solid_fragment"];

        if (!vertex_fn || !fragment_fn) {
            NSLog(@"Ed: Cannot find solid_vertex / solid_fragment in shader library");
            return NO;
        }

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label = @"Ed Solid Pipeline";
        desc.vertexFunction   = vertex_fn;
        desc.fragmentFunction = fragment_fn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;

        g_solid_pipeline = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!g_solid_pipeline) {
            NSLog(@"Ed: Solid pipeline creation failed: %@", error);
            return NO;
        }
    }

    // ── Sampler ─────────────────────────────────────────────────────────
    {
        MTLSamplerDescriptor *samp_desc = [[MTLSamplerDescriptor alloc] init];
        samp_desc.minFilter    = MTLSamplerMinMagFilterLinear;
        samp_desc.magFilter    = MTLSamplerMinMagFilterLinear;
        samp_desc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samp_desc.tAddressMode = MTLSamplerAddressModeClampToEdge;

        g_sampler = [g_device newSamplerStateWithDescriptor:samp_desc];
    }

    NSLog(@"Ed: Metal pipelines built successfully");
    return YES;
}

// ─── MTKView Delegate ───────────────────────────────────────────────────────

@interface EdMetalRenderer : NSObject <MTKViewDelegate>
@property (nonatomic) double lastFrameTime;
@property (nonatomic) uint64_t frameCount;
@end

@implementation EdMetalRenderer

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastFrameTime = getTimeSeconds();
        _frameCount = 0;
    }
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        if (!g_callbacks.on_frame) return;

        double now = getTimeSeconds();
        double dt = now - _lastFrameTime;
        _lastFrameTime = now;
        _frameCount++;

        // The viewport dimensions are sent in DRAWABLE (backing) pixels.
        // The atlas cell dimensions are also in backing pixels (built at scale).
        // So all coordinates throughout the system are in backing pixels.
        CGSize drawable_size = view.drawableSize;

        // Notify Zig of the current viewport size every frame so it stays in sync.
        if (g_callbacks.on_window_event) {
            WindowEvent ev = {
                .event_type = WINDOW_EVENT_RESIZED,
                .width  = (float)drawable_size.width,
                .height = (float)drawable_size.height,
                .scale  = g_backing_scale,
            };
            g_callbacks.on_window_event(&ev);
        }

        // Ask Zig to build the frame data
        EdFrameData frame = g_callbacks.on_frame(dt);

        // Log the first few frames for debugging
        if (_frameCount <= 3) {
            NSLog(@"Ed: Frame %llu — %u instances, viewport %.0fx%.0f, cell %.1fx%.1f, clear (%.2f,%.2f,%.2f)",
                  _frameCount, frame.instance_count,
                  frame.uniforms.viewport_width, frame.uniforms.viewport_height,
                  frame.uniforms.cell_width, frame.uniforms.cell_height,
                  frame.clear_r, frame.clear_g, frame.clear_b);
        }

        // Get the current render pass descriptor — this internally acquires
        // the next drawable from the CAMetalLayer. Do NOT call nextDrawable
        // separately or you'll get a different drawable and nothing renders.
        MTLRenderPassDescriptor *pass_desc = view.currentRenderPassDescriptor;
        if (!pass_desc) return;

        // Use the view's currentDrawable (same one backing the pass descriptor)
        id<CAMetalDrawable> drawable = view.currentDrawable;
        if (!drawable) return;

        pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass_desc.colorAttachments[0].clearColor = MTLClearColorMake(
            frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a
        );

        id<MTLCommandBuffer> cmd_buf = [g_command_queue commandBuffer];
        cmd_buf.label = @"Ed Frame";

        id<MTLRenderCommandEncoder> encoder = [cmd_buf renderCommandEncoderWithDescriptor:pass_desc];
        encoder.label = @"Ed Render";

        if (frame.instance_count > 0 && frame.instances != NULL) {
            // ── Upload instance data to a GPU buffer ────────────────────
            // setVertexBytes is limited to 4 KB of inline constant data.
            // Our instance array can be 200k × 28 B ≈ 5.6 MB, so we must
            // use a real MTLBuffer.  We keep one around and grow it when
            // the required size exceeds its capacity.
            size_t instance_size = (size_t)frame.instance_count * sizeof(GlyphInstance);

            if (!g_instance_buffer || instance_size > g_instance_buffer_capacity) {
                // Grow to at least 2× the current need (amortised allocation).
                size_t new_cap = instance_size * 2;
                if (new_cap < 64 * 1024) new_cap = 64 * 1024; // 64 KB minimum
                g_instance_buffer = [g_device newBufferWithLength:new_cap
                                                         options:MTLResourceStorageModeShared];
                g_instance_buffer_capacity = new_cap;
            }

            // Copy instance data into the buffer
            memcpy(g_instance_buffer.contents, frame.instances, instance_size);

            // ── Draw glyphs ─────────────────────────────────────────────
            [encoder setRenderPipelineState:g_glyph_pipeline];

            // Instance buffer (buffer 0) — proper MTLBuffer, not inline bytes
            [encoder setVertexBuffer:g_instance_buffer offset:0 atIndex:0];

            // Uniforms (buffer 1) — small enough for setVertexBytes (32 B)
            EdUniforms uniforms = frame.uniforms;
            uniforms.viewport_width  = (float)drawable_size.width;
            uniforms.viewport_height = (float)drawable_size.height;
            [encoder setVertexBytes:&uniforms length:sizeof(EdUniforms) atIndex:1];

            // Fragment texture and sampler
            [encoder setFragmentTexture:g_atlas_texture atIndex:0];
            [encoder setFragmentSamplerState:g_sampler atIndex:0];

            // Draw instanced quads (6 vertices per quad, one quad per instance)
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0
                        vertexCount:6
                      instanceCount:frame.instance_count];
        }

        [encoder endEncoding];
        [cmd_buf presentDrawable:drawable];
        [cmd_buf commit];
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Resize is now handled per-frame in drawInMTKView: to avoid
    // ordering issues where the first frames render before this fires.
    (void)view;
    (void)size;
}

@end

// ─── Custom NSView to capture keyboard events ───────────────────────────────

@interface EdMTKView : MTKView <NSTextInputClient>
@property (nonatomic, strong) NSMutableArray<NSEvent *> *pendingKeyEvents;
@end

@implementation EdMTKView

- (instancetype)initWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
    self = [super initWithFrame:frame device:device];
    if (self) {
        _pendingKeyEvents = [NSMutableArray array];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

// ── Keyboard Events ─────────────────────────────────────────────────────────

- (void)keyDown:(NSEvent *)event {
    // First, let the input method handle it (for IME support)
    [self.pendingKeyEvents addObject:event];
    [self interpretKeyEvents:@[event]];

    // If interpretKeyEvents didn't consume it via insertText:, handle directly
    if ([self.pendingKeyEvents containsObject:event]) {
        [self.pendingKeyEvents removeObject:event];
        [self handleKeyEvent:event isDown:YES];
    }
}

- (void)keyUp:(NSEvent *)event {
    [self handleKeyEvent:event isDown:NO];
}

- (void)flagsChanged:(NSEvent *)event {
    // Modifier-only key changes (shift, ctrl, alt, cmd)
    // We don't currently need these but could forward them
}

- (void)handleKeyEvent:(NSEvent *)event isDown:(BOOL)down {
    uint32_t mods = modifiersFromNSEvent(event);
    uint32_t codepoint = 0;

    NSString *chars = event.characters;
    if (chars.length > 0) {
        unichar uc = [chars characterAtIndex:0];
        // Filter out control characters that aren't useful
        if (uc >= 0x20 || uc == '\r' || uc == '\t' || uc == '\n' || uc == 0x1B) {
            codepoint = (uint32_t)uc;
        }
        // Handle surrogate pairs for code points > U+FFFF
        if (chars.length >= 2 && CFStringIsSurrogateHighCharacter(uc)) {
            unichar low = [chars characterAtIndex:1];
            if (CFStringIsSurrogateLowCharacter(low)) {
                codepoint = CFStringGetLongCharacterForSurrogatePair(uc, low);
            }
        }
    }

    // Convert Return to newline
    if (codepoint == '\r') codepoint = '\n';

    KeyEvent ke = {
        .codepoint  = codepoint,
        .keycode    = (uint16_t)event.keyCode,
        .modifiers  = mods,
        .is_repeat  = event.isARepeat ? 1 : 0,
        ._pad       = 0,
    };

    if (down) {
        if (g_callbacks.on_key_down) g_callbacks.on_key_down(&ke);
    } else {
        if (g_callbacks.on_key_up) g_callbacks.on_key_up(&ke);
    }
}

// ── NSTextInputClient Protocol ──────────────────────────────────────────────
// Required for proper IME / composed character input.

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *str = ([string isKindOfClass:[NSAttributedString class]])
        ? [(NSAttributedString *)string string]
        : (NSString *)string;

    // Remove the event from pending since we're handling it via IME
    if (self.pendingKeyEvents.count > 0) {
        [self.pendingKeyEvents removeLastObject];
    }

    // Send each code point as a text input callback
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar uc = [str characterAtIndex:i];
        uint32_t cp = (uint32_t)uc;

        // Handle surrogate pairs
        if (CFStringIsSurrogateHighCharacter(uc) && i + 1 < str.length) {
            unichar low = [str characterAtIndex:i + 1];
            if (CFStringIsSurrogateLowCharacter(low)) {
                cp = CFStringGetLongCharacterForSurrogatePair(uc, low);
                i++;
            }
        }

        if (cp == '\r') cp = '\n';

        if (g_callbacks.on_text_input) {
            g_callbacks.on_text_input(cp);
        }
    }
}

- (void)doCommandBySelector:(SEL)selector {
    // Handle action selectors from interpretKeyEvents
    // (moveUp:, moveDown:, deleteBackward:, etc.)
    // We handle these through our keyDown: handler instead
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange {
    // For IME composition — show composition inline
    // TODO: implement IME composition display
}

- (void)unmarkText {
    // End IME composition
}

- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)markedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText {
    return NO;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                               actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // Return the window position for IME popups
    NSRect frame = self.window.frame;
    return NSMakeRect(frame.origin.x + 100, frame.origin.y + frame.size.height - 100, 0, 0);
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

// ── Mouse Events ────────────────────────────────────────────────────────────

- (void)mouseDown:(NSEvent *)event {
    if (!g_callbacks.on_mouse_down) return;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    // Flip Y coordinate (NSView is bottom-up, we want top-down)
    loc.y = self.bounds.size.height - loc.y;
    // Convert from points to backing (drawable) pixels to match our coordinate system
    loc.x *= g_backing_scale;
    loc.y *= g_backing_scale;
    MouseEvent me = {
        .x = (float)loc.x,
        .y = (float)loc.y,
        .scroll_dx = 0,
        .scroll_dy = 0,
        .button = 0,
        .click_count = (uint8_t)event.clickCount,
    };
    g_callbacks.on_mouse_down(&me);
}

- (void)mouseUp:(NSEvent *)event {
    if (!g_callbacks.on_mouse_up) return;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    loc.y = self.bounds.size.height - loc.y;
    loc.x *= g_backing_scale;
    loc.y *= g_backing_scale;
    MouseEvent me = {
        .x = (float)loc.x,
        .y = (float)loc.y,
        .scroll_dx = 0,
        .scroll_dy = 0,
        .button = 0,
        .click_count = (uint8_t)event.clickCount,
    };
    g_callbacks.on_mouse_up(&me);
}

- (void)rightMouseDown:(NSEvent *)event {
    // ── Context Menu ────────────────────────────────────────────────────
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    loc.y = self.bounds.size.height - loc.y;
    float px = (float)(loc.x * g_backing_scale);
    float py = (float)(loc.y * g_backing_scale);

    // ── Terminal pane menu ──────────────────────────────────────────────
    if (ed_context_menu_is_terminal(px, py)) {
        uint32_t flags    = ed_context_menu_query();
        BOOL hasTermSel   = (flags & 8) != 0;   // CTX_HAS_TERM_SELECTION
        BOOL hasClip      = (flags & 4) != 0;   // CTX_HAS_CLIPBOARD

        NSMenu *termMenu = [[NSMenu alloc] initWithTitle:@"Terminal"];

        NSMenuItem *clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear Terminal"
                                                          action:@selector(ctxTermClear:)
                                                   keyEquivalent:@""];
        [clearItem setTarget:g_ctx_actions];
        [termMenu addItem:clearItem];

        [termMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *tCutItem = [[NSMenuItem alloc] initWithTitle:@"Cut"
                                                         action:@selector(ctxTermCopy:)
                                                  keyEquivalent:@""];
        [tCutItem setTarget:g_ctx_actions];
        [tCutItem setEnabled:hasTermSel];
        [termMenu addItem:tCutItem];

        NSMenuItem *tCopyItem = [[NSMenuItem alloc] initWithTitle:@"Copy"
                                                          action:@selector(ctxTermCopy:)
                                                   keyEquivalent:@""];
        [tCopyItem setTarget:g_ctx_actions];
        [tCopyItem setEnabled:hasTermSel];
        [termMenu addItem:tCopyItem];

        NSMenuItem *tPasteItem = [[NSMenuItem alloc] initWithTitle:@"Paste"
                                                           action:@selector(ctxTermPaste:)
                                                    keyEquivalent:@""];
        [tPasteItem setTarget:g_ctx_actions];
        [tPasteItem setEnabled:hasClip];
        [termMenu addItem:tPasteItem];

        [NSMenu popUpContextMenu:termMenu withEvent:event forView:self];
        return;
    }

    // ── Editor pane menu ────────────────────────────────────────────────
    // Position the editor cursor at the click location so that
    // Go-to-Definition and word-under-cursor resolve at the right spot.
    ed_context_menu_position_cursor(px, py);

    // Query the editor for what's available at this position.
    uint32_t flags = ed_context_menu_query();
    BOOL hasSel   = (flags & 1) != 0;   // CTX_HAS_SELECTION
    BOOL hasSym   = (flags & 2) != 0;   // CTX_HAS_SYMBOL
    BOOL hasClip  = (flags & 4) != 0;   // CTX_HAS_CLIPBOARD

    // Get the word under cursor for the "Go to <name>" label.
    char wordBuf[128];
    uint32_t wordLen = ed_context_menu_word((uint8_t *)wordBuf, sizeof(wordBuf));

    // ── Build NSMenu ────────────────────────────────────────────────────
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Context"];

    // Go to Definition
    NSString *gotoTitle;
    NSString *wordStr = nil;
    if (wordLen > 0) {
        wordStr = [[NSString alloc] initWithBytes:wordBuf
                                                  length:wordLen
                                                encoding:NSUTF8StringEncoding];
        gotoTitle = [NSString stringWithFormat:@"Go to Definition — %@", wordStr];
    } else {
        gotoTitle = @"Go to Definition";
    }
    NSMenuItem *gotoItem = [[NSMenuItem alloc] initWithTitle:gotoTitle
                                                     action:@selector(ctxGoToDefinition:)
                                              keyEquivalent:@""];
    [gotoItem setTarget:g_ctx_actions];
    [gotoItem setEnabled:hasSym];
    [menu addItem:gotoItem];

    // Help
    NSString *helpTitle = (wordStr)
        ? [NSString stringWithFormat:@"Help — %@", wordStr]
        : @"Help";
    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:helpTitle
                                                      action:@selector(ctxHelp:)
                                               keyEquivalent:@""];
    [helpItem setTarget:g_ctx_actions];
    if (wordStr) [helpItem setRepresentedObject:wordStr];
    [menu addItem:helpItem];

    // Find References (search for all occurrences)
    NSString *findRefTitle = (wordLen > 0)
        ? [NSString stringWithFormat:@"Find References — %@",
           [[NSString alloc] initWithBytes:wordBuf length:wordLen encoding:NSUTF8StringEncoding]]
        : @"Find References";
    NSMenuItem *findRefItem = [[NSMenuItem alloc] initWithTitle:findRefTitle
                                                        action:@selector(ctxFindReferences:)
                                                 keyEquivalent:@""];
    [findRefItem setTarget:g_ctx_actions];
    [findRefItem setEnabled:(wordLen > 0)];
    [menu addItem:findRefItem];

    // Rename Symbol
    NSString *renameTitle = (wordLen > 0)
        ? [NSString stringWithFormat:@"Rename Symbol — %@",
           [[NSString alloc] initWithBytes:wordBuf length:wordLen encoding:NSUTF8StringEncoding]]
        : @"Rename Symbol";
    NSMenuItem *renameItem = [[NSMenuItem alloc] initWithTitle:renameTitle
                                                       action:@selector(ctxRename:)
                                                keyEquivalent:@""];
    [renameItem setTarget:g_ctx_actions];
    [renameItem setEnabled:(wordLen > 0 && hasSym)];
    [menu addItem:renameItem];

    // Symbol Outline
    NSMenuItem *outlineItem = [[NSMenuItem alloc] initWithTitle:@"Symbol Outline…"
                                                        action:@selector(ctxSymbolOutline:)
                                                 keyEquivalent:@""];
    [outlineItem setTarget:g_ctx_actions];
    [menu addItem:outlineItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Cut / Copy / Paste
    NSMenuItem *cutItem = [[NSMenuItem alloc] initWithTitle:@"Cut"
                                                    action:@selector(ctxCut:)
                                             keyEquivalent:@""];
    [cutItem setTarget:g_ctx_actions];
    [cutItem setEnabled:hasSel];
    [menu addItem:cutItem];

    NSMenuItem *copyItem = [[NSMenuItem alloc] initWithTitle:@"Copy"
                                                     action:@selector(ctxCopy:)
                                              keyEquivalent:@""];
    [copyItem setTarget:g_ctx_actions];
    [copyItem setEnabled:hasSel];
    [menu addItem:copyItem];

    NSMenuItem *pasteItem = [[NSMenuItem alloc] initWithTitle:@"Paste"
                                                      action:@selector(ctxPaste:)
                                               keyEquivalent:@""];
    [pasteItem setTarget:g_ctx_actions];
    [pasteItem setEnabled:hasClip];
    [menu addItem:pasteItem];

    NSMenuItem *selectAllItem = [[NSMenuItem alloc] initWithTitle:@"Select All"
                                                          action:@selector(ctxSelectAll:)
                                                   keyEquivalent:@""];
    [selectAllItem setTarget:g_ctx_actions];
    [menu addItem:selectAllItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Toggle Comment / Duplicate Line / Format
    NSMenuItem *commentItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Comment"
                                                        action:@selector(ctxToggleComment:)
                                                 keyEquivalent:@""];
    [commentItem setTarget:g_ctx_actions];
    [menu addItem:commentItem];

    NSMenuItem *dupItem = [[NSMenuItem alloc] initWithTitle:@"Duplicate Line"
                                                    action:@selector(ctxDuplicateLine:)
                                             keyEquivalent:@""];
    [dupItem setTarget:g_ctx_actions];
    [menu addItem:dupItem];

    NSMenuItem *fmtItem = [[NSMenuItem alloc] initWithTitle:@"Format Source"
                                                    action:@selector(ctxFormat:)
                                             keyEquivalent:@""];
    [fmtItem setTarget:g_ctx_actions];
    [menu addItem:fmtItem];

    // Show the menu at the click location (in window coordinates).
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)rightMouseUp:(NSEvent *)event {
    // Context menu is handled entirely in rightMouseDown:.
    (void)event;
}

- (void)mouseMoved:(NSEvent *)event {
    if (!g_callbacks.on_mouse_moved) return;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    loc.y = self.bounds.size.height - loc.y;
    loc.x *= g_backing_scale;
    loc.y *= g_backing_scale;
    g_callbacks.on_mouse_moved((float)loc.x, (float)loc.y);
}

- (void)mouseDragged:(NSEvent *)event {
    // Forward drag as a mouse-down with click_count=1 so Zig extends the selection.
    // The Zig side will see repeated mouse-down events during the drag and should
    // treat them as selection-extension (anchor stays, cursor moves).
    if (!g_callbacks.on_mouse_down) return;
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    loc.y = self.bounds.size.height - loc.y;
    loc.x *= g_backing_scale;
    loc.y *= g_backing_scale;
    MouseEvent me = {
        .x = (float)loc.x,
        .y = (float)loc.y,
        .scroll_dx = 0,
        .scroll_dy = 0,
        .button = 0,
        .click_count = 0,  // 0 = drag continuation (not a new click)
    };
    g_callbacks.on_mouse_down(&me);
}

- (void)scrollWheel:(NSEvent *)event {
    if (!g_callbacks.on_scroll) return;
    float dx = (float)event.scrollingDeltaX;
    float dy = (float)event.scrollingDeltaY;
    // If using pixel-precise scrolling (trackpad), scale to backing pixels
    if (event.hasPreciseScrollingDeltas) {
        g_callbacks.on_scroll(dx * g_backing_scale, dy * g_backing_scale);
    } else {
        // Mouse wheel: multiply by cell height (already in backing pixels) for smooth feel
        g_callbacks.on_scroll(dx * g_atlas_info.cell_width, dy * g_atlas_info.cell_height * 3.0f);
    }
}

@end

// ─── Save-before-close helpers ─────────────────────────────────────────────
// These Zig exports are called by both EdWindowDelegate (close button) and
// EdAppDelegate (Cmd+Q) to implement the "save before closing?" prompt.
extern int  ed_is_modified(void);
extern int  ed_save_to_existing_path(void);
extern int  ed_save_as_path(const char *path);

// Set to YES by -windowShouldClose after the user answers the save alert, so
// -applicationShouldTerminate (triggered via windowWillClose → [NSApp terminate:])
// does not show a second prompt for the same close gesture.
static BOOL gCloseAlreadyHandled = NO;

// ─── Window Delegate ────────────────────────────────────────────────────────

@interface EdWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation EdWindowDelegate

- (void)windowDidResize:(NSNotification *)notification {
    // The MTKView delegate handles resize via drawableSizeWillChange
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (g_callbacks.on_window_event) {
        WindowEvent ev = { .event_type = WINDOW_EVENT_FOCUS_GAINED };
        g_callbacks.on_window_event(&ev);
    }
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (g_callbacks.on_window_event) {
        WindowEvent ev = { .event_type = WINDOW_EVENT_FOCUS_LOST };
        g_callbacks.on_window_event(&ev);
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (ed_is_modified()) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Save changes before closing?"];
        [alert setInformativeText:@"Your unsaved changes will be lost if you close without saving."];
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Don\u2019t Save"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert setAlertStyle:NSAlertStyleWarning];
        NSModalResponse res = [alert runModal];
        if (res == NSAlertThirdButtonReturn) {
            // Cancel — keep window open
            return NO;
        }
        if (res == NSAlertFirstButtonReturn) {
            // Save
            int saved = ed_save_to_existing_path();
            if (saved == 0) {
                // Untitled file — ask where to save it
                NSSavePanel *panel = [NSSavePanel savePanel];
                [panel setNameFieldStringValue:@"untitled.bas"];
                if ([panel runModal] == NSModalResponseOK) {
                    ed_save_as_path([[panel URL] fileSystemRepresentation]);
                } else {
                    return NO; // user cancelled the save-as => don't close
                }
            }
        }
        // Save or Don't Save: mark so applicationShouldTerminate skips re-prompt
        gCloseAlreadyHandled = YES;
    }
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
}

@end

// ─── Toolbar Delegate ───────────────────────────────────────────────────────
//
// Provides a minimal, tasteful toolbar with monochrome SF Symbol icons.
// Unified compact style — sits in the title bar, takes no extra space.
// No text labels, no colours.  Just quiet, professional icons.

// Forward-declare sendSyntheticKey (defined below with the menu actions)
static void sendSyntheticKey(uint16_t keycode, uint32_t mods);

@interface EdToolbarDelegate : NSObject <NSToolbarDelegate>
@end

@implementation EdToolbarDelegate

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];

    if ([identifier isEqualToString:EdToolbarRunItem]) {
        item.label   = @"Run";
        item.toolTip = @"Run Program (F5)";
        item.target  = self;
        item.action  = @selector(toolbarRun:);
        item.bordered = YES;

        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:@"play"
                                  accessibilityDescription:@"Run"];
        } else {
            item.image = [NSImage imageNamed:NSImageNameGoRightTemplate];
        }
    }
    else if ([identifier isEqualToString:EdToolbarStopItem]) {
        item.label   = @"Stop";
        item.toolTip = @"Stop Program";
        item.target  = self;
        item.action  = @selector(toolbarStop:);
        item.bordered = YES;

        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:@"stop"
                                  accessibilityDescription:@"Stop"];
        } else {
            item.image = [NSImage imageNamed:NSImageNameStopProgressFreestandingTemplate];
        }
    }
    else if ([identifier isEqualToString:EdToolbarTerminalItem]) {
        item.label   = @"Terminal";
        item.toolTip = @"Toggle Terminal (⌘J)";
        item.target  = self;
        item.action  = @selector(toolbarTerminal:);
        item.bordered = YES;

        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:@"terminal"
                                  accessibilityDescription:@"Terminal"];
        } else {
            item.image = [NSImage imageNamed:NSImageNameActionTemplate];
        }
    }

    return item;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        EdToolbarRunItem,
        EdToolbarStopItem,
        NSToolbarFlexibleSpaceItemIdentifier,
        EdToolbarTerminalItem,
    ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[
        EdToolbarRunItem,
        EdToolbarStopItem,
        EdToolbarTerminalItem,
        NSToolbarFlexibleSpaceItemIdentifier,
        NSToolbarSpaceItemIdentifier,
    ];
}

// ── Toolbar actions ─────────────────────────────────────────────────────────

- (void)toolbarRun:(id)sender {
    // F5 — Run
    sendSyntheticKey(0x60, 0);
}

- (void)toolbarStop:(id)sender {
    // Cmd+. — Stop running program
    sendSyntheticKey(0x2F, 1u << 3);  // VK.PERIOD + MOD_CMD
}

- (void)toolbarTerminal:(id)sender {
    // Cmd+J — Toggle terminal
    sendSyntheticKey(0x26, 1u << 3);  // MOD_CMD
}

@end

static EdToolbarDelegate *g_toolbar_delegate = nil;



// ─── Menu Action Target ─────────────────────────────────────────────────────
//
// Routes menu item actions to the Zig editor by synthesising KeyEvent structs
// and calling g_callbacks.on_key_down.  This keeps all command logic in Zig —
// the menus are just another way to trigger the same key combos.

// Virtual key codes (must match platform.zig VK)
enum {
    kEdVK_A = 0x00, kEdVK_S = 0x01, kEdVK_D = 0x02, kEdVK_F = 0x03,
    kEdVK_H = 0x04, kEdVK_G = 0x05, kEdVK_Z = 0x06, kEdVK_X = 0x07,
    kEdVK_C = 0x08, kEdVK_V = 0x09, kEdVK_B = 0x0B, kEdVK_Q = 0x0C,
    kEdVK_W = 0x0D, kEdVK_E = 0x0E, kEdVK_R = 0x0F, kEdVK_Y = 0x10,
    kEdVK_T = 0x11, kEdVK_O = 0x1F, kEdVK_U = 0x20, kEdVK_I = 0x22,
    kEdVK_P = 0x23, kEdVK_L = 0x25, kEdVK_J = 0x26, kEdVK_K = 0x28,
    kEdVK_N = 0x2D, kEdVK_M = 0x2E, kEdVK_Slash = 0x2C,
    kEdVK_LeftBracket = 0x21, kEdVK_RightBracket = 0x1E,
    kEdVK_Period = 0x2F,
    kEdVK_F1 = 0x7A, kEdVK_F2 = 0x78, kEdVK_F5 = 0x60,
    kEdVK_F6 = 0x61, kEdVK_F7 = 0x62, kEdVK_F8 = 0x64,
    kEdVK_F9 = 0x65, kEdVK_F10 = 0x6D, kEdVK_F11 = 0x67,
    kEdVK_F12 = 0x6F,
    kEdVK_UpArrow = 0x7E, kEdVK_DownArrow = 0x7D,
};

static void sendSyntheticKey(uint16_t keycode, uint32_t mods) {
    if (!g_callbacks.on_key_down) return;
    KeyEvent ke = {
        .codepoint  = 0,
        .keycode    = keycode,
        .modifiers  = mods,
        .is_repeat  = 0,
        ._pad       = 0,
    };
    g_callbacks.on_key_down(&ke);
}

// ─── Extern Graphics Runtime Functions (from graphics_runtime.zig) ──────────
//
// Used by the Graphics menu to directly open/clear/close the graphics window
// for interactive testing without compiling a BASIC program.

extern void gfx_screen(double width, double height, double scale);
extern void gfx_screen_close(void);
extern void gfx_cls(double colour);
extern void gfx_flip(void);
extern double gfx_screen_active(void);

@interface EdMenuActions : NSObject
// File
- (void)menuNew:(id)sender;
- (void)menuOpen:(id)sender;
- (void)menuInsertFile:(id)sender;
- (void)menuSave:(id)sender;
- (void)menuSaveAs:(id)sender;
- (void)menuExportUTF8:(id)sender;
- (void)menuClose:(id)sender;
// Edit
- (void)menuUndo:(id)sender;
- (void)menuRedo:(id)sender;
- (void)menuCut:(id)sender;
- (void)menuCopy:(id)sender;
- (void)menuPaste:(id)sender;
- (void)menuSelectAll:(id)sender;
- (void)menuDuplicateLine:(id)sender;
- (void)menuToggleComment:(id)sender;
- (void)menuMoveLineUp:(id)sender;
- (void)menuMoveLineDown:(id)sender;
// Code
- (void)menuFormat:(id)sender;
- (void)menuFold:(id)sender;
- (void)menuUnfoldAll:(id)sender;
- (void)menuFoldAll:(id)sender;
- (void)menuRename:(id)sender;
- (void)menuGoToDefinition:(id)sender;
- (void)menuFindReferences:(id)sender;
- (void)menuSymbolOutline:(id)sender;
- (void)menuAnalyse:(id)sender;
// Find
- (void)menuFind:(id)sender;
- (void)menuFindReplace:(id)sender;
- (void)menuFindNext:(id)sender;
- (void)menuFindPrev:(id)sender;
- (void)menuGoToLine:(id)sender;
- (void)menuJumpToBracket:(id)sender;
- (void)menuToggleCaseSensitivity:(id)sender;
// View
- (void)menuToggleTerminal:(id)sender;
- (void)menuTerminalFullscreen:(id)sender;
- (void)menuNextTheme:(id)sender;
- (void)menuPrevTheme:(id)sender;
// Program
- (void)menuRun:(id)sender;
- (void)menuBuild:(id)sender;
- (void)menuViewIR:(id)sender;
- (void)menuViewAssembly:(id)sender;
- (void)menuDisassemble:(id)sender;
- (void)menuViewAST:(id)sender;
- (void)menuViewCFG:(id)sender;
- (void)menuViewSymbols:(id)sender;
- (void)menuStop:(id)sender;
// LLVM Optimization Level (applies to Run and Build)
- (void)menuOptO0:(id)sender;
- (void)menuOptO1:(id)sender;
- (void)menuOptO2:(id)sender;
- (void)menuOptO3:(id)sender;
- (void)menuToggleFastMathTrig:(id)sender;
// Graphics
- (void)menuGfxOpen:(id)sender;
- (void)menuGfxClear:(id)sender;
- (void)menuGfxClose:(id)sender;
// Help
- (void)menuKeyboardShortcuts:(id)sender;
// App / Settings
- (void)menuCompilerSettings:(id)sender;
@end

@implementation EdMenuActions

- (void)menuNew:(id)sender              { sendSyntheticKey(kEdVK_N,  MOD_CMD); }
- (void)menuOpen:(id)sender             { sendSyntheticKey(kEdVK_O,  MOD_CMD); }
- (void)menuInsertFile:(id)sender       { sendSyntheticKey(kEdVK_P,  MOD_CMD | MOD_SHIFT); }
- (void)menuSave:(id)sender             { sendSyntheticKey(kEdVK_S,  MOD_CMD); }
- (void)menuSaveAs:(id)sender           { sendSyntheticKey(kEdVK_S,  MOD_CMD | MOD_SHIFT); }
- (void)menuExportUTF8:(id)sender       { sendSyntheticKey(kEdVK_E,  MOD_CMD | MOD_SHIFT); }
- (void)menuClose:(id)sender            { [g_window performClose:sender]; }

- (void)menuUndo:(id)sender             { sendSyntheticKey(kEdVK_Z,  MOD_CMD); }
- (void)menuRedo:(id)sender             { sendSyntheticKey(kEdVK_Z,  MOD_CMD | MOD_SHIFT); }
- (void)menuCut:(id)sender              { sendSyntheticKey(kEdVK_X,  MOD_CMD); }
- (void)menuCopy:(id)sender             { sendSyntheticKey(kEdVK_C,  MOD_CMD); }
- (void)menuPaste:(id)sender            { sendSyntheticKey(kEdVK_V,  MOD_CMD); }
- (void)menuSelectAll:(id)sender        { sendSyntheticKey(kEdVK_A,  MOD_CMD); }
- (void)menuDuplicateLine:(id)sender    { sendSyntheticKey(kEdVK_D,  MOD_CMD); }
- (void)menuToggleComment:(id)sender    { sendSyntheticKey(kEdVK_Slash, MOD_CMD); }
- (void)menuMoveLineUp:(id)sender       { sendSyntheticKey(kEdVK_UpArrow,   MOD_ALT); }
- (void)menuMoveLineDown:(id)sender     { sendSyntheticKey(kEdVK_DownArrow, MOD_ALT); }

- (void)menuFold:(id)sender             { sendSyntheticKey(kEdVK_LeftBracket,  MOD_CMD | MOD_SHIFT); }
- (void)menuUnfoldAll:(id)sender        { sendSyntheticKey(kEdVK_RightBracket, MOD_CMD | MOD_SHIFT); }
- (void)menuFoldAll:(id)sender          { ed_context_menu_action(135); } // MENU_FOLD_ALL
- (void)menuRename:(id)sender           { sendSyntheticKey(kEdVK_R,  MOD_CMD); }
- (void)menuGoToDefinition:(id)sender   { sendSyntheticKey(kEdVK_F12, 0); }
- (void)menuFindReferences:(id)sender   { ed_context_menu_action(kCtxFindReferences); }
- (void)menuSymbolOutline:(id)sender    { sendSyntheticKey(kEdVK_O,  MOD_CMD | MOD_SHIFT); }

- (void)menuFind:(id)sender             { sendSyntheticKey(kEdVK_F,  MOD_CMD); }
- (void)menuFindReplace:(id)sender      { sendSyntheticKey(kEdVK_H,  MOD_CMD); }
- (void)menuFindNext:(id)sender         { sendSyntheticKey(kEdVK_G,  MOD_CMD); }
- (void)menuFindPrev:(id)sender         { sendSyntheticKey(kEdVK_G,  MOD_CMD | MOD_SHIFT); }
- (void)menuGoToLine:(id)sender         { sendSyntheticKey(kEdVK_L,  MOD_CMD); }
- (void)menuJumpToBracket:(id)sender    { sendSyntheticKey(kEdVK_M,  MOD_CMD); }
- (void)menuToggleCaseSensitivity:(id)sender { sendSyntheticKey(kEdVK_F2, 0); }

- (void)menuToggleTerminal:(id)sender    { sendSyntheticKey(kEdVK_J,  MOD_CMD); }
- (void)menuTerminalFullscreen:(id)sender { sendSyntheticKey(kEdVK_J,  MOD_CMD | MOD_SHIFT); }
- (void)menuNextTheme:(id)sender         { sendSyntheticKey(kEdVK_RightBracket, MOD_CMD); }
- (void)menuPrevTheme:(id)sender         { sendSyntheticKey(kEdVK_LeftBracket,  MOD_CMD); }

- (void)menuFormat:(id)sender           { sendSyntheticKey(kEdVK_I, MOD_CMD | MOD_SHIFT); } // Cmd+Shift+I
- (void)menuAnalyse:(id)sender          { sendSyntheticKey(kEdVK_A, MOD_CMD | MOD_SHIFT); } // Cmd+Shift+A

- (void)menuRun:(id)sender              { sendSyntheticKey(kEdVK_F5, 0); }
- (void)menuBuild:(id)sender            { sendSyntheticKey(kEdVK_B, MOD_CMD); } // Cmd+B
- (void)menuViewIR:(id)sender           { sendSyntheticKey(kEdVK_F7, 0); } // F7
- (void)menuViewAssembly:(id)sender     { sendSyntheticKey(kEdVK_F8, 0); } // F8
- (void)menuDisassemble:(id)sender      { sendSyntheticKey(kEdVK_F6, 0); } // F6
- (void)menuViewAST:(id)sender          { sendSyntheticKey(kEdVK_F9,  0); } // F9
- (void)menuViewCFG:(id)sender          { sendSyntheticKey(kEdVK_F10, 0); } // F10
- (void)menuViewSymbols:(id)sender      { sendSyntheticKey(kEdVK_F11, 0); } // F11
- (void)menuStop:(id)sender             { sendSyntheticKey(kEdVK_Period, MOD_CMD); } // Cmd+.

// Optimization Level
- (void)menuOptO0:(id)sender {
    extern void ed_set_jit_opt_level(uint8_t level);
    ed_set_jit_opt_level(0);
}

- (void)menuOptO1:(id)sender {
    extern void ed_set_jit_opt_level(uint8_t level);
    ed_set_jit_opt_level(1);
}

- (void)menuOptO2:(id)sender {
    extern void ed_set_jit_opt_level(uint8_t level);
    ed_set_jit_opt_level(2);
}

- (void)menuOptO3:(id)sender {
    extern void ed_set_jit_opt_level(uint8_t level);
    ed_set_jit_opt_level(3);
}

- (void)menuToggleFastMathTrig:(id)sender {
    (void)sender;
    extern uint8_t ed_get_jit_fast_math_trig(void);
    extern void ed_set_jit_fast_math_trig(uint8_t enabled);
    const uint8_t current = ed_get_jit_fast_math_trig();
    ed_set_jit_fast_math_trig(current ? 0 : 1);
}

// Graphics — gfx_screen / gfx_screen_close handle main-thread dispatch
// internally via dispatch_sync, so they can be called directly.
- (void)menuGfxOpen:(id)sender {
    if (gfx_screen_active() > 0.0) return;  // already open
    gfx_screen(320.0, 200.0, 0.0);
}

- (void)menuGfxClear:(id)sender {
    if (gfx_screen_active() <= 0.0) return;  // no window
    gfx_cls(0.0);
    gfx_flip();
}

- (void)menuGfxClose:(id)sender {
    if (gfx_screen_active() <= 0.0) return;  // no window
    gfx_screen_close();
}

- (void)menuKeyboardShortcuts:(id)sender { sendSyntheticKey(kEdVK_F1, 0); }
- (void)menuCompilerSettings:(id)sender  { (void)sender; ed_context_menu_action(155); }

// Validate menu items to dynamically update checkmarks for optimization levels
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = [menuItem action];

    // Handle optimization level checkmarks
    extern uint8_t ed_get_jit_opt_level(void);
    uint8_t current_opt = ed_get_jit_opt_level();

    if (action == @selector(menuOptO0:)) {
        [menuItem setState:(current_opt == 0) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(menuOptO1:)) {
        [menuItem setState:(current_opt == 1) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(menuOptO2:)) {
        [menuItem setState:(current_opt == 2) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
    if (action == @selector(menuOptO3:)) {
        [menuItem setState:(current_opt == 3) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }

    if (action == @selector(menuToggleFastMathTrig:)) {
        extern uint8_t ed_get_jit_fast_math_trig(void);
        const uint8_t enabled = ed_get_jit_fast_math_trig();
        [menuItem setState:enabled ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }

    // Default: enable all other menu items
    return YES;
}

@end

// Keep the menu actions target alive
static EdMenuActions *g_menu_actions = nil;

// ─── Menu Builder ───────────────────────────────────────────────────────────
//
// Builds the full macOS menu bar.  Key equivalents are left EMPTY on items
// whose shortcuts we handle in the Zig keyDown: path — this avoids the menu
// system swallowing the event before our view sees it.  Instead, the shortcut
// text is shown via a right-aligned annotation string in the title.
//
// Exception: Cmd+Q (Quit) uses a real key equivalent so macOS can terminate
// the app even if our view doesn't have focus.

// Helper: create a menu item with a real key equivalent so macOS shows the
// shortcut in the menu.  The menu system will intercept the keystroke and
// call the action method, which in turn calls sendSyntheticKey → on_key_down,
// so all command logic stays in Zig.
//
// `key` is the keyEquivalent character (lowercase letter, or special char).
// `mask` is the modifier mask (defaults to Cmd if 0 is passed — use
//  NSEventModifierFlagCommand explicitly when combining with other mods).
static NSMenuItem *menuItem(NSString *title, SEL action, NSString *key, NSEventModifierFlags mask) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:action
                                          keyEquivalent:key];
    if (mask != 0) {
        [item setKeyEquivalentModifierMask:mask];
    }
    item.target = g_menu_actions;
    return item;
}

// Helper for function-key menu items.  Function keys use special Unicode
// code points defined by AppKit (NSF1FunctionKey etc.) and require the
// function-key modifier flag to be absent from the displayed modifier mask.
static NSMenuItem *menuItemFKey(NSString *title, SEL action, unichar fkey) {
    NSString *key = [NSString stringWithCharacters:&fkey length:1];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                 action:action
                                          keyEquivalent:key];
    // Function keys: no visible modifier — macOS renders "F5" automatically
    [item setKeyEquivalentModifierMask:0];
    item.target = g_menu_actions;
    return item;
}

static void buildMenuBar(void) {
    g_menu_actions = [[EdMenuActions alloc] init];
    g_ctx_actions  = [[EdContextMenuActions alloc] init];

    NSString *appName = ed_current_app_name();
    if (!appName || appName.length == 0) {
        appName = @"Ed";
    }

    NSMenu *menuBar = [[NSMenu alloc] init];

    // ── Ed (Application) Menu ───────────────────────────────────────────
    {
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [appMenuItem setTitle:appName];
        [menuBar addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];

        NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"About %@", appName]
                                                      action:@selector(orderFrontStandardAboutPanel:)
                                               keyEquivalent:@""];

        [appMenu addItem:about];
        [appMenu addItem:menuItem(@"Compiler Settings...", @selector(menuCompilerSettings:), @",", NSEventModifierFlagCommand)];
        [appMenu addItem:[NSMenuItem separatorItem]];

        // Services submenu (standard macOS)
        NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
        NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:@"Services"
                                                             action:nil
                                                      keyEquivalent:@""];
        [servicesItem setSubmenu:servicesMenu];
        [appMenu addItem:servicesItem];
        [NSApp setServicesMenu:servicesMenu];

        [appMenu addItem:[NSMenuItem separatorItem]];

        // Note: Cmd+H is intentionally NOT assigned here because we use it
        // for Find & Replace.  Users can still hide via this menu item.
        NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                                                     action:@selector(hide:)
                                              keyEquivalent:@""];
        [appMenu addItem:hide];

        NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:@"Hide Others"
                                                           action:@selector(hideOtherApplications:)
                                                    keyEquivalent:@"h"];
        [hideOthers setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
        [appMenu addItem:hideOthers];

        NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:@"Show All"
                                                        action:@selector(unhideAllApplications:)
                                                 keyEquivalent:@""];
        [appMenu addItem:showAll];

        [appMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                                     action:@selector(terminate:)
                                              keyEquivalent:@"q"];
        [appMenu addItem:quit];

        [appMenuItem setSubmenu:appMenu];
    }

    // ── File Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:fileMenuItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

        [fileMenu addItem:menuItem(@"New",          @selector(menuNew:),        @"n", NSEventModifierFlagCommand)];
        [fileMenu addItem:menuItem(@"Open…",         @selector(menuOpen:),       @"o", NSEventModifierFlagCommand)];
        [fileMenu addItem:menuItem(@"Insert File…",  @selector(menuInsertFile:), @"p",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItem:menuItem(@"Save",     @selector(menuSave:), @"s", NSEventModifierFlagCommand)];
        [fileMenu addItem:menuItem(@"Save As…", @selector(menuSaveAs:), @"s",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItem:menuItem(@"Export to UTF-8\u2026", @selector(menuExportUTF8:), @"e",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItem:menuItem(@"Close Window", @selector(menuClose:), @"w", NSEventModifierFlagCommand)];

        [fileMenuItem setSubmenu:fileMenu];
    }

    // ── Edit Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:editMenuItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

        [editMenu addItem:menuItem(@"Undo",           @selector(menuUndo:), @"z", NSEventModifierFlagCommand)];
        [editMenu addItem:menuItem(@"Redo",           @selector(menuRedo:), @"z",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItem:menuItem(@"Cut",            @selector(menuCut:),  @"x", NSEventModifierFlagCommand)];
        [editMenu addItem:menuItem(@"Copy",           @selector(menuCopy:), @"c", NSEventModifierFlagCommand)];
        [editMenu addItem:menuItem(@"Paste",          @selector(menuPaste:),@"v", NSEventModifierFlagCommand)];
        [editMenu addItem:menuItem(@"Select All",     @selector(menuSelectAll:), @"a", NSEventModifierFlagCommand)];

        [editMenuItem setSubmenu:editMenu];
    }

    // ── Code Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *codeMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:codeMenuItem];
        NSMenu *codeMenu = [[NSMenu alloc] initWithTitle:@"Code"];

        [codeMenu addItem:menuItem(@"Format Source", @selector(menuFormat:), @"i",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [codeMenu addItem:menuItem(@"Toggle Comment", @selector(menuToggleComment:), @"/", NSEventModifierFlagCommand)];
        [codeMenu addItem:menuItem(@"Duplicate Line", @selector(menuDuplicateLine:), @"d", NSEventModifierFlagCommand)];
        [codeMenu addItem:[NSMenuItem separatorItem]];
        [codeMenu addItem:menuItem(@"Move Line Up", @selector(menuMoveLineUp:), @"",
                                   NSEventModifierFlagOption)];
        {
            // Alt+Up — set Unicode arrow for key equivalent
            NSMenuItem *up = [codeMenu.itemArray lastObject];
            unichar upArrow = NSUpArrowFunctionKey;
            [up setKeyEquivalent:[NSString stringWithCharacters:&upArrow length:1]];
            [up setKeyEquivalentModifierMask:NSEventModifierFlagOption];
        }
        [codeMenu addItem:menuItem(@"Move Line Down", @selector(menuMoveLineDown:), @"",
                                   NSEventModifierFlagOption)];
        {
            NSMenuItem *dn = [codeMenu.itemArray lastObject];
            unichar dnArrow = NSDownArrowFunctionKey;
            [dn setKeyEquivalent:[NSString stringWithCharacters:&dnArrow length:1]];
            [dn setKeyEquivalentModifierMask:NSEventModifierFlagOption];
        }
        [codeMenu addItem:[NSMenuItem separatorItem]];
        [codeMenu addItem:menuItem(@"Fold", @selector(menuFold:), @"[",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [codeMenu addItem:menuItem(@"Unfold All", @selector(menuUnfoldAll:), @"]",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [codeMenu addItem:menuItem(@"Fold All", @selector(menuFoldAll:), @"", 0)];
        [codeMenu addItem:[NSMenuItem separatorItem]];
        [codeMenu addItem:menuItem(@"Rename Symbol", @selector(menuRename:), @"r", NSEventModifierFlagCommand)];
        [codeMenu addItem:menuItemFKey(@"Go to Definition", @selector(menuGoToDefinition:), NSF12FunctionKey)];
        [codeMenu addItem:menuItem(@"Find References", @selector(menuFindReferences:), @"", 0)];
        [codeMenu addItem:menuItem(@"Symbol Outline\u2026", @selector(menuSymbolOutline:), @"o",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [codeMenu addItem:menuItem(@"Jump to Matching Bracket", @selector(menuJumpToBracket:), @"m",
                                   NSEventModifierFlagCommand)];
        [codeMenu addItem:[NSMenuItem separatorItem]];
        [codeMenu addItem:menuItem(@"Analyse\u2026", @selector(menuAnalyse:), @"a",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];

        [codeMenuItem setSubmenu:codeMenu];
    }

    // ── Find Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *findMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:findMenuItem];
        NSMenu *findMenu = [[NSMenu alloc] initWithTitle:@"Find"];

        [findMenu addItem:menuItem(@"Find…",            @selector(menuFind:),        @"f", NSEventModifierFlagCommand)];
        [findMenu addItem:menuItem(@"Find & Replace…",  @selector(menuFindReplace:), @"h", NSEventModifierFlagCommand)];
        [findMenu addItem:[NSMenuItem separatorItem]];
        [findMenu addItem:menuItem(@"Find Next",        @selector(menuFindNext:),    @"g", NSEventModifierFlagCommand)];
        [findMenu addItem:menuItem(@"Find Previous",    @selector(menuFindPrev:),    @"g",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [findMenu addItem:[NSMenuItem separatorItem]];
        [findMenu addItem:menuItem(@"Go to Line…",      @selector(menuGoToLine:),    @"l", NSEventModifierFlagCommand)];
        [findMenu addItem:[NSMenuItem separatorItem]];
        [findMenu addItem:menuItemFKey(@"Toggle Case Sensitivity", @selector(menuToggleCaseSensitivity:),
                                       NSF2FunctionKey)];

        [findMenuItem setSubmenu:findMenu];
    }

    // ── View Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:viewMenuItem];
        NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];

        [viewMenu addItem:menuItem(@"Toggle Terminal", @selector(menuToggleTerminal:), @"j", NSEventModifierFlagCommand)];
        [viewMenu addItem:menuItem(@"Terminal Fullscreen", @selector(menuTerminalFullscreen:), @"j",
                                   NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [viewMenu addItem:[NSMenuItem separatorItem]];
        [viewMenu addItem:menuItem(@"Next Theme",      @selector(menuNextTheme:),     @"]", NSEventModifierFlagCommand)];
        [viewMenu addItem:menuItem(@"Previous Theme",  @selector(menuPrevTheme:),     @"[", NSEventModifierFlagCommand)];

        // Standard macOS fullscreen (provided by the system)
        [viewMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *fullscreen = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen"
                                                           action:@selector(toggleFullScreen:)
                                                    keyEquivalent:@"f"];
        [fullscreen setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagControl];
        [viewMenu addItem:fullscreen];

        [viewMenuItem setSubmenu:viewMenu];
    }

    // ── Program Menu ────────────────────────────────────────────────────
    {
        NSMenuItem *progMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:progMenuItem];
        NSMenu *progMenu = [[NSMenu alloc] initWithTitle:@"Program"];

        [progMenu addItem:menuItemFKey(@"Run", @selector(menuRun:), NSF5FunctionKey)];
        [progMenu addItem:menuItem(@"Build Executable\u2026", @selector(menuBuild:), @"b", NSEventModifierFlagCommand)];
        [progMenu addItem:[NSMenuItem separatorItem]];
        [progMenu addItem:menuItemFKey(@"View AST", @selector(menuViewAST:), NSF9FunctionKey)];
        [progMenu addItem:menuItemFKey(@"View CFG", @selector(menuViewCFG:), NSF10FunctionKey)];
        [progMenu addItem:menuItemFKey(@"View Symbols", @selector(menuViewSymbols:), NSF11FunctionKey)];
        [progMenu addItem:[NSMenuItem separatorItem]];
        [progMenu addItem:menuItemFKey(@"View LLVM IR", @selector(menuViewIR:), NSF7FunctionKey)];
        [progMenu addItem:menuItemFKey(@"View Code", @selector(menuViewAssembly:), NSF8FunctionKey)];
        [progMenu addItem:menuItemFKey(@"Disassemble", @selector(menuDisassemble:), NSF6FunctionKey)];
        [progMenu addItem:[NSMenuItem separatorItem]];
        [progMenu addItem:menuItem(@"Stop", @selector(menuStop:), @".", NSEventModifierFlagCommand)];

        // Optimization Level submenu
        [progMenu addItem:[NSMenuItem separatorItem]];
        NSMenu *optMenu = [[NSMenu alloc] initWithTitle:@"Optimization Level"];
        NSMenuItem *optMenuItem = [[NSMenuItem alloc] initWithTitle:@"Optimization Level"
                                                             action:nil
                                                      keyEquivalent:@""];

        extern uint8_t ed_get_jit_opt_level(void);
        uint8_t current_opt = ed_get_jit_opt_level();

        NSMenuItem *opt0 = [[NSMenuItem alloc] initWithTitle:@"O0 — No Optimization"
                                                      action:@selector(menuOptO0:)
                                               keyEquivalent:@""];
        opt0.target = g_menu_actions;
        if (current_opt == 0) [opt0 setState:NSControlStateValueOn];
        [optMenu addItem:opt0];

        NSMenuItem *opt1 = [[NSMenuItem alloc] initWithTitle:@"O1 — Balanced (Default)"
                                                      action:@selector(menuOptO1:)
                                               keyEquivalent:@""];
        opt1.target = g_menu_actions;
        if (current_opt == 1) [opt1 setState:NSControlStateValueOn];
        [optMenu addItem:opt1];

        NSMenuItem *opt2 = [[NSMenuItem alloc] initWithTitle:@"O2 — Aggressive"
                                                      action:@selector(menuOptO2:)
                                               keyEquivalent:@""];
        opt2.target = g_menu_actions;
        if (current_opt == 2) [opt2 setState:NSControlStateValueOn];
        [optMenu addItem:opt2];

        NSMenuItem *opt3 = [[NSMenuItem alloc] initWithTitle:@"O3 — Maximum"
                                                      action:@selector(menuOptO3:)
                                               keyEquivalent:@""];
        opt3.target = g_menu_actions;
        if (current_opt == 3) [opt3 setState:NSControlStateValueOn];
        [optMenu addItem:opt3];

        [optMenuItem setSubmenu:optMenu];
        [progMenu addItem:optMenuItem];

        [progMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *fastTrig = [[NSMenuItem alloc] initWithTitle:@"Fast Trig (Approximate SIN/COS/TAN)"
                                                          action:@selector(menuToggleFastMathTrig:)
                                                   keyEquivalent:@""];
        fastTrig.target = g_menu_actions;
        [progMenu addItem:fastTrig];

        [progMenuItem setSubmenu:progMenu];
    }

    // ── Window Menu ─────────────────────────────────────────────────────
    {
        NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:windowMenuItem];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

        // Note: Cmd+M is intentionally NOT assigned here because we use it
        // for Jump to Matching Bracket.  Users can still minimize via this menu item.
        NSMenuItem *minimize = [[NSMenuItem alloc] initWithTitle:@"Minimize"
                                                         action:@selector(performMiniaturize:)
                                                  keyEquivalent:@""];
        [windowMenu addItem:minimize];

        NSMenuItem *zoom = [[NSMenuItem alloc] initWithTitle:@"Zoom"
                                                     action:@selector(performZoom:)
                                              keyEquivalent:@""];
        [windowMenu addItem:zoom];

        [windowMenu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *bringAll = [[NSMenuItem alloc] initWithTitle:@"Bring All to Front"
                                                         action:@selector(arrangeInFront:)
                                                  keyEquivalent:@""];
        [windowMenu addItem:bringAll];

        [windowMenuItem setSubmenu:windowMenu];
        [NSApp setWindowsMenu:windowMenu];
    }

    // ── Help Menu ───────────────────────────────────────────────────────
    {
        NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:helpMenuItem];
        NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

        [helpMenu addItem:menuItemFKey(@"Keyboard Shortcuts", @selector(menuKeyboardShortcuts:), NSF1FunctionKey)];

        [helpMenuItem setSubmenu:helpMenu];
        [NSApp setHelpMenu:helpMenu];
    }

    [NSApp setMainMenu:menuBar];
}

// ─── App Delegate ───────────────────────────────────────────────────────────

@interface EdAppDelegate : NSObject <NSApplicationDelegate>
@end

// ─── Graphics subsystem (ed_graphics_bridge.m) ──────────────────────────────
extern void ed_graphics_init(void);
extern void ed_graphics_shutdown(void);

@implementation EdAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Make the window key and front
    [g_window makeKeyAndOrderFront:nil];
    [g_window makeFirstResponder:g_mtk_view];
    [NSApp activateIgnoringOtherApps:YES];

    // Start the graphics subsystem command polling timer.
    // This must happen on the main thread after the run loop is active.
    ed_graphics_init();
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // gCloseAlreadyHandled is set by windowShouldClose when the user already
    // answered a save-changes alert (close button path).  We then skip the
    // second prompt that would otherwise fire via windowWillClose →
    // [NSApp terminate:nil] → applicationShouldTerminate.
    if (gCloseAlreadyHandled || !ed_is_modified()) {
        return NSTerminateNow;
    }
    // Cmd+Q while there are unsaved changes — ask the user.
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Save changes before quitting?"];
    [alert setInformativeText:@"Your unsaved changes will be lost if you quit without saving."];
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Don\u2019t Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setAlertStyle:NSAlertStyleWarning];
    NSModalResponse res = [alert runModal];
    if (res == NSAlertThirdButtonReturn) {
        return NSTerminateCancel;
    }
    if (res == NSAlertFirstButtonReturn) {
        int saved = ed_save_to_existing_path();
        if (saved == 0) {
            NSSavePanel *panel = [NSSavePanel savePanel];
            [panel setNameFieldStringValue:@"untitled.bas"];
            if ([panel runModal] == NSModalResponseOK) {
                ed_save_as_path([[panel URL] fileSystemRepresentation]);
            } else {
                return NSTerminateCancel;
            }
        }
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    ed_graphics_shutdown();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

// ─── C API (called from Zig) ────────────────────────────────────────────────

int ed_platform_init(
    int width,
    int height,
    const char *title,
    const char *font_name,
    float font_size,
    const EdCallbacks *callbacks
) {
    @autoreleasepool {
        // Store callbacks
        memcpy(&g_callbacks, callbacks, sizeof(EdCallbacks));

        // Init timing
        mach_timebase_info(&g_timebase);
        g_start_time = mach_absolute_time();

        // Create the Metal device
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            NSLog(@"Ed: FATAL — no Metal device available");
            return -1;
        }

        g_command_queue = [g_device newCommandQueue];
        if (!g_command_queue) {
            NSLog(@"Ed: FATAL — cannot create command queue");
            return -1;
        }

        // Create NSApplication early so we can query screen properties
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Determine the backing scale factor BEFORE building the atlas.
        // We need this to render glyphs at native Retina resolution.
        g_backing_scale = 1.0f;
        NSScreen *main_screen = [NSScreen mainScreen];
        if (main_screen) {
            g_backing_scale = (float)main_screen.backingScaleFactor;
        }
        NSLog(@"Ed: Display backing scale factor = %.1f", g_backing_scale);

        // Build glyph atlas at the backing scale for crisp Retina glyphs
        if (!buildGlyphAtlas(font_name, font_size, g_backing_scale)) {
            NSLog(@"Ed: FATAL — cannot build glyph atlas");
            return -1;
        }

        // Build Metal pipelines
        if (!buildPipelines()) {
            NSLog(@"Ed: FATAL — cannot build Metal pipelines");
            return -1;
        }

        g_app_delegate = [[EdAppDelegate alloc] init];
        [NSApp setDelegate:g_app_delegate];

        // Build the full macOS menu bar
        buildMenuBar();

        // Create the window
        CGFloat initial_width = (CGFloat)width;
        if (g_atlas_info.cell_width > 0.0f && g_backing_scale > 0.0f) {
            // Aim for a default width that fits 120 columns at the current font size.
            CGFloat cell_width_points = (CGFloat)(g_atlas_info.cell_width / g_backing_scale);
            CGFloat desired_width = ceil(cell_width_points * 120.0);
            if (desired_width > 0.0) {
                initial_width = desired_width;
            }
        }
        if (main_screen) {
            CGFloat max_width = main_screen.visibleFrame.size.width * 0.9;
            if (initial_width > max_width) {
                initial_width = max_width;
            }
        }
        NSRect content_rect = NSMakeRect(0, 0, initial_width, height);
        NSWindowStyleMask style =
            NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable |
            NSWindowStyleMaskResizable |
            NSWindowStyleMaskMiniaturizable;

        g_window = [[NSWindow alloc]
            initWithContentRect:content_rect
                      styleMask:style
                        backing:NSBackingStoreBuffered
                          defer:NO];

        NSString *ns_title = [NSString stringWithUTF8String:title];
        [g_window setTitle:ns_title];
        [g_window center];
        [g_window setMinSize:NSMakeSize(640, 480)];
        [g_window setAcceptsMouseMovedEvents:YES];

        // Set a dark appearance
        g_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

        g_win_delegate = [[EdWindowDelegate alloc] init];
        [g_window setDelegate:g_win_delegate];

        // ── Toolbar ─────────────────────────────────────────────────────
        // Minimal, monochrome SF Symbol icons in the title bar.
        // Unified compact style — no extra vertical space consumed.
        {
            g_toolbar_delegate = [[EdToolbarDelegate alloc] init];

            NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"EdMainToolbar"];
            toolbar.delegate = g_toolbar_delegate;
            toolbar.displayMode = NSToolbarDisplayModeIconOnly;
            toolbar.allowsUserCustomization = NO;
            toolbar.showsBaselineSeparator = NO;

            g_window.toolbar = toolbar;

            // Unified compact style: toolbar lives inside the title bar
            if (@available(macOS 11.0, *)) {
                g_window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
            }
        }

        // Create the MTKView
        NSRect view_rect = [g_window contentLayoutRect];
        g_mtk_view = [[EdMTKView alloc] initWithFrame:view_rect device:g_device];
        g_mtk_view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        g_mtk_view.preferredFramesPerSecond = 120;
        g_mtk_view.enableSetNeedsDisplay = NO; // continuous redraw
        g_mtk_view.paused = NO;
        g_mtk_view.clearColor = MTLClearColorMake(0.0, 0.0, 0.67, 1.0); // QuickBASIC blue

        // Set up the render delegate (stored in static global for ARC retention)
        g_renderer = [[EdMetalRenderer alloc] init];
        g_mtk_view.delegate = g_renderer;

        // Attach view to window
        [g_window setContentView:g_mtk_view];

        // Show the window immediately — don't rely solely on
        // applicationDidFinishLaunching: which only fires once [NSApp run]
        // enters the run loop.  Ordering it front now ensures it appears
        // even if the delegate callback timing is surprising.
        [g_window makeKeyAndOrderFront:nil];

        NSLog(@"Ed: Platform initialized — %dx%d, scale %.1f",
              width, height, (float)g_window.backingScaleFactor);

        return 0;
    }
}

void ed_platform_run(void) {
    @autoreleasepool {
        // Activate the application so it comes to the foreground.
        // On macOS 14+ activateIgnoringOtherApps: is deprecated but
        // still functional; [NSApp activate] is the modern replacement
        // but is unavailable on older SDKs.  Belt-and-suspenders: do both.
        [NSApp activateIgnoringOtherApps:YES];
        [g_window makeKeyAndOrderFront:nil];
        [g_window makeFirstResponder:g_mtk_view];
        [NSApp run];
    }
}

void ed_platform_request_redraw(void) {
    [g_mtk_view setNeedsDisplay:YES];
}

void ed_platform_set_title(const char *title) {
    @autoreleasepool {
        [g_window setTitle:[NSString stringWithUTF8String:title]];
    }
}

GlyphAtlasInfo ed_platform_get_atlas_info(void) {
    return g_atlas_info;
}

float ed_platform_get_width(void) {
    if (!g_mtk_view) return 2880.0f;  // 1440 * 2 for retina
    CGSize size = g_mtk_view.drawableSize;
    float w = (float)size.width;
    if (w <= 0) w = 2880.0f;
    return w;
}

float ed_platform_get_height(void) {
    if (!g_mtk_view) return 1800.0f;  // 900 * 2 for retina
    CGSize size = g_mtk_view.drawableSize;
    float h = (float)size.height;
    if (h <= 0) h = 1800.0f;
    return h;
}

float ed_platform_get_scale(void) {
    if (!g_window) return 2.0f;
    return (float)g_window.backingScaleFactor;
}

void ed_platform_clipboard_set(const char *text) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
    }
}

const char * ed_platform_clipboard_get(void) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if (!str || str.length == 0) return NULL;
        // Return a strdup'd copy that the caller must free
        return strdup([str UTF8String]);
    }
}

void ed_platform_clipboard_free(const char *text) {
    if (text) free((void *)text);
}

// ─── File Dialogs ───────────────────────────────────────────────────────────

const char * ed_platform_open_file_dialog(void) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.title = @"Open File";
        panel.message = @"Choose a FasterBASIC source file to open";

        // Use the modern UTType API (macOS 11+) with a fallback for older systems.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (@available(macOS 11.0, *)) {
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"bas"],
                [UTType typeWithFilenameExtension:@"baz"],
                [UTType typeWithFilenameExtension:@"bi"],
                [UTType typeWithFilenameExtension:@"txt"],
                [UTType typeWithFilenameExtension:@"zig"],
                [UTType typeWithFilenameExtension:@"c"],
                [UTType typeWithFilenameExtension:@"h"],
                [UTType typeWithFilenameExtension:@"md"],
            ];
            panel.allowsOtherFileTypes = YES;
        } else {
            panel.allowedFileTypes = @[@"bas", @"baz", @"bi", @"txt", @"zig", @"c", @"h", @"md"];
            panel.allowsOtherFileTypes = YES;
        }
#pragma clang diagnostic pop

        NSModalResponse response = [panel runModal];
        if (response == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url && url.path) {
                return strdup([url.path UTF8String]);
            }
        }
        return NULL;
    }
}

const char * ed_platform_save_file_dialog(const char *suggested_name) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"Save File";
        panel.message = @"Choose a location to save your file";
        panel.canCreateDirectories = YES;
        panel.showsTagField = NO;

        if (suggested_name) {
            NSString *suggested = [NSString stringWithUTF8String:suggested_name];
            NSString *name = [suggested lastPathComponent];
            NSString *dir = [suggested stringByDeletingLastPathComponent];

            if (dir.length > 0 && ![dir isEqualToString:@"."] && ![dir isEqualToString:name]) {
                if (![dir isAbsolutePath]) {
                    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
                    dir = [cwd stringByAppendingPathComponent:dir];
                }
                panel.directoryURL = [NSURL fileURLWithPath:dir isDirectory:YES];
            }

            panel.nameFieldStringValue = name;
        } else {
            panel.nameFieldStringValue = @"untitled.bas";
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (@available(macOS 11.0, *)) {
            panel.allowedContentTypes = @[
                [UTType typeWithFilenameExtension:@"bas"],
                [UTType typeWithFilenameExtension:@"baz"],
                [UTType typeWithFilenameExtension:@"bi"],
                [UTType typeWithFilenameExtension:@"txt"],
                [UTType typeWithFilenameExtension:@"zig"],
                [UTType typeWithFilenameExtension:@"c"],
                [UTType typeWithFilenameExtension:@"h"],
                [UTType typeWithFilenameExtension:@"md"],
            ];
            panel.allowsOtherFileTypes = YES;
        } else {
            panel.allowedFileTypes = @[@"bas", @"baz", @"bi", @"txt", @"zig", @"c", @"h", @"md"];
            panel.allowsOtherFileTypes = YES;
        }
#pragma clang diagnostic pop

        NSModalResponse response = [panel runModal];
        if (response == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url && url.path) {
                return strdup([url.path UTF8String]);
            }
        }
        return NULL;
    }
}

const char * ed_platform_save_build_dialog(const char *suggested_name) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = @"Build Executable";
        panel.message = @"Choose where to save the built executable";
        panel.canCreateDirectories = YES;
        panel.showsTagField = NO;

        if (suggested_name) {
            NSString *suggested = [NSString stringWithUTF8String:suggested_name];
            NSString *name = [suggested lastPathComponent];
            NSString *dir = [suggested stringByDeletingLastPathComponent];

            if (dir.length > 0 && ![dir isEqualToString:@"."] && ![dir isEqualToString:name]) {
                if (![dir isAbsolutePath]) {
                    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
                    dir = [cwd stringByAppendingPathComponent:dir];
                }
                panel.directoryURL = [NSURL fileURLWithPath:dir isDirectory:YES];
            }

            panel.nameFieldStringValue = name;
        } else {
            panel.nameFieldStringValue = @"program";
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (@available(macOS 11.0, *)) {
            panel.allowedContentTypes = @[];
            panel.allowsOtherFileTypes = YES;
        } else {
            panel.allowedFileTypes = nil;
            panel.allowsOtherFileTypes = YES;
        }
#pragma clang diagnostic pop

        NSModalResponse response = [panel runModal];
        if (response == NSModalResponseOK) {
            NSURL *url = panel.URL;
            if (url && url.path) {
                return strdup([url.path UTF8String]);
            }
        }
        return NULL;
    }
}

void ed_platform_free_path(const char *path) {
    if (path) free((void *)path);
}

// ─── Cursor Style ───────────────────────────────────────────────────────────

void ed_platform_set_cursor(uint8_t style) {
    switch (style) {
        case 1:  // vertical resize
            [[NSCursor resizeUpDownCursor] set];
            break;
        default: // arrow
            [[NSCursor arrowCursor] set];
            break;
    }
}

// ─── Confirm Dialog ─────────────────────────────────────────────────────────

int ed_platform_confirm_save_dialog(const char *filename) {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Save Changes?";

        NSString *info;
        if (filename) {
            info = [NSString stringWithFormat:@"Do you want to save changes to \"%s\"?",
                    filename];
        } else {
            info = @"Do you want to save changes to the untitled file?";
        }
        alert.informativeText = info;
        alert.alertStyle = NSAlertStyleWarning;

        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Don't Save"];
        [alert addButtonWithTitle:@"Cancel"];

        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn)  return 1;  // Save
        if (response == NSAlertSecondButtonReturn)  return 0;  // Don't Save
        return -1;  // Cancel
    }
}

int ed_platform_compiler_settings_dialog(
    const char *current_path,
    const char *current_options,
    const char **out_path,
    const char **out_options
) {
    @autoreleasepool {
        if (out_path) *out_path = NULL;
        if (out_options) *out_options = NULL;

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Compiler Settings";
        alert.informativeText = @"Choose the compiler executable and any extra arguments Ed should pass through edglue.";
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Use Defaults"];
        [alert addButtonWithTitle:@"Cancel"];

        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 470, 126)];
        EdCompilerSettingsDialogController *controller = [[EdCompilerSettingsDialogController alloc] init];

        NSTextField *pathLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 98, 470, 20)];
        pathLabel.editable = NO;
        pathLabel.bezeled = NO;
        pathLabel.drawsBackground = NO;
        pathLabel.selectable = NO;
        pathLabel.stringValue = @"Compiler executable";

        NSTextField *pathField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 70, 370, 24)];
        pathField.placeholderString = @"/path/to/compiler";
        if (current_path && strlen(current_path) != 0) {
            pathField.stringValue = [NSString stringWithUTF8String:current_path];
        }
        controller.pathField = pathField;

        NSButton *browseButton = [[NSButton alloc] initWithFrame:NSMakeRect(382, 69, 88, 26)];
        browseButton.title = @"Browse...";
        browseButton.bezelStyle = NSBezelStyleRounded;
        browseButton.target = controller;
        browseButton.action = @selector(browseCompiler:);

        NSTextField *optionsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 42, 470, 20)];
        optionsLabel.editable = NO;
        optionsLabel.bezeled = NO;
        optionsLabel.drawsBackground = NO;
        optionsLabel.selectable = NO;
        optionsLabel.stringValue = @"Extra compiler arguments";

        NSTextField *optionsField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 14, 470, 24)];
        optionsField.placeholderString = @"For example: --target x86_64-macos --release";
        if (current_options && strlen(current_options) != 0) {
            optionsField.stringValue = [NSString stringWithUTF8String:current_options];
        }
        controller.optionsField = optionsField;

        [accessory addSubview:pathLabel];
        [accessory addSubview:pathField];
        [accessory addSubview:browseButton];
        [accessory addSubview:optionsLabel];
        [accessory addSubview:optionsField];
        alert.accessoryView = accessory;

        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            NSString *path = [pathField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *options = [optionsField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (path.length == 0) {
                return 2;
            }
            if (out_path) {
                *out_path = strdup(path.UTF8String);
            }
            if (out_options) {
                *out_options = strdup(options.UTF8String);
            }
            return 1;
        }
        if (response == NSAlertSecondButtonReturn) {
            return 2;
        }
        return 0;
    }
}
