// The C face of ClapHost: CLAP bundles are scanned, each plugin in them is
// registered as an in-process Audio Unit (a ClapAudioUnit), and the registry
// maps each registered component description back to its bundle and CLAP id.
// Everything here runs on the main thread.
#ifndef PC_CLAP_HOST_H
#define PC_CLAP_HOST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Registers every plugin of every .clap bundle in `directory` and the folders under it; returns how many
   plugins the bundles hold. A plugin registered before stays as it is, so a repeated scan registers only what is new. */
int pc_clap_scan(const char *directory);
/* Registers the plugins of the bundle at `path`; returns how many it holds, or -1 when it cannot be loaded.
   A plugin registered before stays as it is. */
int pc_clap_register_bundle(const char *path);

/* One registered plugin. The strings live as long as the process. */
typedef struct pc_clap_plugin {
    const char *path;      /* the bundle, as it was registered */
    const char *clap_id;
    const char *name;
    const char *vendor;
    uint32_t type;         /* 'aumu', 'aumf', or 'aufx' */
    uint32_t subtype;
    uint32_t manufacturer;
} pc_clap_plugin;

/* Before the process exits, after every plugin instance (every ClapAudioUnit, probes included) is destroyed:
   deinitializes each loaded bundle's entry and forgets the bundle, whose executable stays loaded; a later
   registration or instance initializes it again. While a plugin is alive it does nothing and returns false.
   Nothing deinitializes the entries at exit on its own, when a bundle's static storage may already be gone. */
bool pc_clap_shutdown(void);

int pc_clap_count(void);
bool pc_clap_plugin_at(int index, pc_clap_plugin *out);
/* The registered plugin with this component description. */
bool pc_clap_lookup(uint32_t type, uint32_t subtype, uint32_t manufacturer, pc_clap_plugin *out);

/* What a bridged unit reports about itself. `unit` is the AUAudioUnit
   (unretained); a unit that is not a ClapAudioUnit makes these return false. */
typedef struct pc_clap_unit_info {
    bool created_on_main_thread;
    int note_dialect;                  /* 0: no note input, 1: CLAP note events, 2: MIDI */
    bool active;                       /* activated, between allocating and deallocating render resources */
    uint32_t input_channels;           /* the first input port's, 0 without one */
    uint32_t output_channels;          /* the first output port's */
    uint32_t latency_frames;
    /* Counted as the events pass, from the unit's creation. */
    uint64_t process_calls;
    uint64_t midi_render_events;       /* AURenderEventMIDI events read from the render event list */
    uint64_t note_events;              /* CLAP note on and off events sent to the plugin */
    uint64_t midi_events;              /* CLAP MIDI events sent to the plugin */
    uint64_t parameter_render_events;  /* AURenderEventParameter and ramp events read from the render event list */
    uint64_t host_parameter_events;    /* values set through the parameter tree, sent to the plugin */
    uint64_t plugin_parameter_events;  /* parameter values the plugin reported */
    uint64_t dropped_events;           /* events a full list or queue had no room for */
} pc_clap_unit_info;

bool pc_clap_unit_read_info(void *unit, pc_clap_unit_info *out);
/* The parameter's value as the plugin reports it through clap.params get_value. */
bool pc_clap_unit_param_value(void *unit, uint32_t param_id, double *value);
/* As if the plugin's own editor had moved a parameter: the value reaches the
   plugin at the next block, and the plugin's report of it waits in the queue
   the render block fills with the values the plugin reports. */
bool pc_clap_unit_post_plugin_param(void *unit, uint32_t param_id, double value);

#ifdef __cplusplus
}
#endif

#endif
