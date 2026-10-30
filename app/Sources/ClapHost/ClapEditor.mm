// ClapEditorViewController: a CLAP plugin's embedded Cocoa GUI as the view of
// a view controller, in `clap.gui`'s order for an embedded GUI: create,
// can_resize, get_size, set_parent, show; hide and destroy when done. The
// cocoa window API measures in logical points and leaves scaling to the
// system, so the host never calls set_scale. Everything here runs on the
// main thread.
#include "ClapInternal.h"

#include <pthread.h>

#include <algorithm>
#include <cmath>

namespace {

/// The view's size when the plugin reports none.
constexpr CGFloat kFallbackWidth = 400;
constexpr CGFloat kFallbackHeight = 300;
/// The smallest content a resizable editor's window shrinks to.
constexpr CGFloat kMinimumSide = 1;

bool IsMainThread() { return pthread_main_np() != 0; }

uint32_t Points(CGFloat length) { return static_cast<uint32_t>(std::lround(std::max<CGFloat>(length, 0))); }

}  // namespace

@interface ClapEditorViewController ()
- (void)viewMovedToWindow:(NSWindow *)window;
@end

/// The parent the plugin's own view is embedded in. Flipped, so the plugin's
/// view sits at the top left when the window is larger than the GUI; it tells
/// the controller each time it joins or leaves a window.
@interface ClapEditorView : NSView
@property(nonatomic, weak) ClapEditorViewController *controller;
@end

@implementation ClapEditorView

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.controller viewMovedToWindow:self.window];
}

@end

@implementation ClapEditorViewController {
    ClapAudioUnit *_unit;
    const clap_plugin_t *_plugin;
    const clap_plugin_gui_t *_gui;
    BOOL _shown;
    BOOL _resizable;
    /// Set while the controller itself sizes the view, which the plugin already knows of.
    BOOL _sizing;
    /// The GUI's size as the plugin last reported, asked for, or took it.
    NSSize _size;
    __weak NSWindow *_observedWindow;
}

- (instancetype)initWithUnit:(ClapAudioUnit *)unit plugin:(const clap_plugin_t *)plugin gui:(const clap_plugin_gui_t *)gui {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _unit = unit;
    _plugin = plugin;
    _gui = gui;
    _size = NSMakeSize(kFallbackWidth, kFallbackHeight);
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (!_attached) return;
    const clap_plugin_t *plugin = _plugin;
    const clap_plugin_gui_t *gui = _gui;
    BOOL shown = _shown;
    if (IsMainThread()) {
        if (shown) gui->hide(plugin);
        gui->destroy(plugin);
        return;
    }
    // The block holds the unit, so the plugin is still there when its GUI is destroyed.
    ClapAudioUnit *unit = _unit;
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)unit;
        if (shown) gui->hide(plugin);
        gui->destroy(plugin);
    });
}

// ---- The view and the GUI in it

- (void)loadView {
    ClapEditorView *view = [[ClapEditorView alloc] initWithFrame:NSZeroRect];
    view.controller = self;
    self.view = view;
    [self attach];
    [self showGui];
}

/// The GUI created and embedded in the view, sized as the plugin reports.
- (void)attach {
    if (_attached) return;
    if (!_gui->create(_plugin, CLAP_WINDOW_API_COCOA, false)) {
        NSLog(@"CLAP: the plugin could not create its Cocoa GUI");
        return;
    }
    _resizable = _gui->can_resize(_plugin);
    uint32_t width = 0;
    uint32_t height = 0;
    if (_gui->get_size(_plugin, &width, &height) && width > 0 && height > 0) _size = NSMakeSize(width, height);
    [self sizeViewTo:_size];
    clap_window_t window{};
    window.api = CLAP_WINDOW_API_COCOA;
    window.cocoa = (__bridge void *)self.view;
    if (!_gui->set_parent(_plugin, &window)) {
        NSLog(@"CLAP: the plugin could not embed its GUI in the editor's view");
        _gui->destroy(_plugin);
        return;
    }
    _attached = YES;
    NSWindow *parent = self.view.window;
    if (parent) [self fitWindow:parent];
}

- (void)detach {
    if (!_attached) return;
    [self hideGui];
    _gui->destroy(_plugin);
    _attached = NO;
}

- (void)showGui {
    if (!_attached || _shown) return;
    _gui->show(_plugin);
    _shown = YES;
}

- (void)hideGui {
    if (!_attached || !_shown) return;
    _gui->hide(_plugin);
    _shown = NO;
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self attach];
    [self showGui];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self hideGui];
}

/// The view at `size`: through its window's content size when the view is
/// that window's content, directly otherwise.
- (void)sizeViewTo:(NSSize)size {
    _sizing = YES;
    self.preferredContentSize = size;
    NSWindow *window = self.isViewLoaded ? self.view.window : nil;
    if (window && window.contentView == self.view) {
        [self limitWindow:window];
        [window setContentSize:size];
    } else {
        [self.view setFrameSize:size];
    }
    _sizing = NO;
}

// ---- The window

- (void)viewMovedToWindow:(NSWindow *)window {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    _observedWindow = window;
    if (!window) return;
    [center addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:window];
    [center addObserver:self selector:@selector(windowDidEndLiveResize:) name:NSWindowDidEndLiveResizeNotification object:window];
    [self fitWindow:window];
}

/// The window's limits from the plugin, and its content at the GUI's size.
- (void)fitWindow:(NSWindow *)window {
    if (window.contentView != self.view) return;
    [self limitWindow:window];
    NSSize content = [window contentRectForFrameRect:window.frame].size;
    if (!NSEqualSizes(content, _size)) [self sizeViewTo:_size];
}

/// A GUI that cannot resize fixes the window's content size at its own; a
/// resizable one lets the window resize along the axes its hints allow,
/// keeping the aspect ratio they ask for.
- (void)limitWindow:(NSWindow *)window {
    if (window.contentView != self.view) return;
    NSSize minimum = _size;
    NSSize maximum = _size;
    window.contentResizeIncrements = NSMakeSize(1, 1);
    if (_attached && _resizable) {
        clap_gui_resize_hints_t hints{true, true, false, 0, 0};
        if (_gui->get_resize_hints && !_gui->get_resize_hints(_plugin, &hints)) hints = {true, true, false, 0, 0};
        if (hints.can_resize_horizontally) {
            minimum.width = kMinimumSide;
            maximum.width = CGFLOAT_MAX;
        }
        if (hints.can_resize_vertically) {
            minimum.height = kMinimumSide;
            maximum.height = CGFLOAT_MAX;
        }
        bool both = hints.can_resize_horizontally && hints.can_resize_vertically;
        if (both && hints.preserve_aspect_ratio && hints.aspect_ratio_width > 0 && hints.aspect_ratio_height > 0) {
            window.contentAspectRatio = NSMakeSize(hints.aspect_ratio_width, hints.aspect_ratio_height);
        }
    }
    window.contentMinSize = minimum;
    window.contentMaxSize = maximum;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self detach];
}

/// A size the plugin adjusted away from the one the user dragged to is
/// taken once the drag ends.
- (void)windowDidEndLiveResize:(NSNotification *)notification {
    NSWindow *window = _observedWindow;
    if (window && _attached) [self fitWindow:window];
}

/// A user's resize reaches a resizable GUI as the nearest size it accepts.
- (void)viewDidLayout {
    [super viewDidLayout];
    if (!_attached || !_resizable || _sizing) return;
    NSSize bounds = self.view.bounds.size;
    uint32_t width = Points(bounds.width);
    uint32_t height = Points(bounds.height);
    if (width == Points(_size.width) && height == Points(_size.height)) return;
    if (_gui->adjust_size) _gui->adjust_size(_plugin, &width, &height);
    if (_gui->set_size(_plugin, width, height)) _size = NSMakeSize(width, height);
    bool fits = Points(_size.width) == Points(bounds.width) && Points(_size.height) == Points(bounds.height);
    if (fits || self.view.inLiveResize) return;
    __weak ClapEditorViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ClapEditorViewController *editor = weakSelf;
        NSWindow *window = editor ? editor->_observedWindow : nil;
        if (window) [editor fitWindow:window];
    });
}

// ---- What the plugin asks of the host

- (BOOL)resizeTo:(NSSize)size {
    if (!_attached || size.width <= 0 || size.height <= 0) return NO;
    _size = size;
    [self sizeViewTo:size];
    return YES;
}

- (void)resizeHintsChanged {
    NSWindow *window = self.isViewLoaded ? self.view.window : nil;
    if (window) [self limitWindow:window];
}

- (BOOL)showWindow {
    NSWindow *window = self.isViewLoaded ? self.view.window : nil;
    if (!window) return NO;
    [window makeKeyAndOrderFront:nil];
    return YES;
}

- (BOOL)hideWindow {
    NSWindow *window = self.isViewLoaded ? self.view.window : nil;
    if (!window) return NO;
    [window orderOut:nil];
    return YES;
}

- (void)closeWindowDestroyed:(BOOL)destroyed {
    if (destroyed && _attached) {
        // The plugin's side is gone; destroy acknowledges it.
        _gui->destroy(_plugin);
        _attached = NO;
        _shown = NO;
    }
    NSWindow *window = self.isViewLoaded ? self.view.window : nil;
    [window close];
}

@end
