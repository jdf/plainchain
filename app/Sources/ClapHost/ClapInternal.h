// What ClapLoader.mm and ClapAudioUnit.mm share; Swift never sees it.
#ifndef PC_CLAP_INTERNAL_H
#define PC_CLAP_INTERNAL_H

#include <clap/clap.h>

#import <AudioToolbox/AudioToolbox.h>

/// One CLAP plugin instance presented as an in-process Audio Unit.
@interface ClapAudioUnit : AUAudioUnit
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
