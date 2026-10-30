// What ClapLoader.mm, ClapAudioUnit.mm, and ClapEditor.mm share; Swift never sees it.
#ifndef PC_CLAP_INTERNAL_H
#define PC_CLAP_INTERNAL_H

#include <clap/clap.h>

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>

/// One CLAP plugin instance presented as an in-process Audio Unit.
@interface ClapAudioUnit : AUAudioUnit
@end

/// The plugin's own Cocoa GUI (`clap.gui`, embedded), in a view the
/// controller owns. The view is the parent the plugin draws into, sized as
/// the plugin asks. The GUI is created when the view loads and destroyed
/// when the view's window closes or the controller goes away; the plugin
/// outlives it. Main thread only.
@interface ClapEditorViewController : NSViewController

/// Holds `unit` strongly, so the plugin outlives the editor.
- (instancetype)initWithUnit:(ClapAudioUnit *)unit plugin:(const clap_plugin_t *)plugin gui:(const clap_plugin_gui_t *)gui;

/// Whether the plugin's GUI is created and embedded in the view.
@property(nonatomic, readonly) BOOL attached;

/// `clap_host_gui.request_resize`: the view and its window's content take the size.
- (BOOL)resizeTo:(NSSize)size;
/// `clap_host_gui.resize_hints_changed`: the window's limits follow the plugin's hints again.
- (void)resizeHintsChanged;
/// `clap_host_gui.request_show` and `request_hide`: the window is ordered front or out.
- (BOOL)showWindow;
- (BOOL)hideWindow;
/// `clap_host_gui.closed`: the window closes, destroying the GUI first when
/// the plugin says its side is gone.
- (void)closeWindowDestroyed:(BOOL)destroyed;

@end

namespace pc_clap {

/// Main thread: creates the plugin `clap_id` of the bundle at `path` with
/// `host`, loading the bundle when it is not loaded yet; nullptr when the
/// bundle or the plugin is gone.
const clap_plugin_t *CreatePlugin(const char *path, const char *clap_id, const clap_host_t *host);

/// Main thread: destroys a plugin `CreatePlugin` made.
void DestroyPlugin(const clap_plugin_t *plugin);

}  // namespace pc_clap

#endif
