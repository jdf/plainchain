// CLAP bundles: loading, their plugin factories and descriptors, and the
// registry of the Audio Unit components registered for their plugins.
#include "ClapInternal.h"
#include "clap_host.h"

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <pthread.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {

/// A loaded bundle: its executable stays loaded, and its entry initialized,
/// for the life of the process.
struct Bundle {
    void *library = nullptr;
    const clap_plugin_entry_t *entry = nullptr;
    const clap_plugin_factory_t *factory = nullptr;
};

struct Registered {
    std::string path;
    std::string clap_id;
    std::string name;
    std::string vendor;
    uint32_t type = 0;
    uint32_t subtype = 0;
    uint32_t manufacturer = 0;
};

constexpr uint32_t kFourCcMusicDevice = 'aumu';
constexpr uint32_t kFourCcMusicEffect = 'aumf';
constexpr uint32_t kFourCcEffect = 'aufx';
constexpr uint64_t kFnvOffset = 0xcbf29ce484222325ULL;
constexpr uint64_t kFnvPrime = 0x100000001b3ULL;
/// Printable ASCII without the space: '!' (0x21) through '~' (0x7e).
constexpr uint32_t kPrintableFirst = 0x21;
constexpr uint32_t kPrintableCount = 0x7e - 0x21 + 1;

std::map<std::string, Bundle> &Bundles() {
    static auto *bundles = new std::map<std::string, Bundle>;
    return *bundles;
}

std::vector<std::unique_ptr<Registered>> &Registry() {
    static auto *registry = new std::vector<std::unique_ptr<Registered>>;
    return *registry;
}

/// Plugins created and not yet destroyed, probes included.
int g_live_plugins = 0;

/// At exit, with no plugin left, every loaded entry is deinitialized once.
void DeinitBundles() {
    if (g_live_plugins != 0) return;
    for (auto &[path, bundle] : Bundles()) bundle.entry->deinit();
}

bool IsMainThread() { return pthread_main_np() != 0; }

const Bundle *LoadBundle(const char *path) {
    auto found = Bundles().find(path);
    if (found != Bundles().end()) return &found->second;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path), std::strlen(path), true);
    if (!url) return nullptr;
    CFBundleRef cf_bundle = CFBundleCreate(nullptr, url);
    CFRelease(url);
    if (!cf_bundle) {
        NSLog(@"CLAP: %s is not a bundle", path);
        return nullptr;
    }
    CFURLRef executable = CFBundleCopyExecutableURL(cf_bundle);
    CFRelease(cf_bundle);
    if (!executable) {
        NSLog(@"CLAP: %s names no executable", path);
        return nullptr;
    }
    char binary[PATH_MAX];
    bool converted = CFURLGetFileSystemRepresentation(executable, true, reinterpret_cast<UInt8 *>(binary), sizeof binary);
    CFRelease(executable);
    if (!converted) return nullptr;
    void *library = dlopen(binary, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        NSLog(@"CLAP: loading %s: %s", binary, dlerror());
        return nullptr;
    }
    auto *entry = static_cast<const clap_plugin_entry_t *>(dlsym(library, "clap_entry"));
    if (!entry) {
        NSLog(@"CLAP: %s exports no clap_entry", binary);
        dlclose(library);
        return nullptr;
    }
    if (!clap_version_is_compatible(entry->clap_version)) {
        NSLog(@"CLAP: %s is CLAP %u.%u.%u", path, entry->clap_version.major, entry->clap_version.minor, entry->clap_version.revision);
        dlclose(library);
        return nullptr;
    }
    if (!entry->init(path)) {
        NSLog(@"CLAP: clap_entry init failed for %s", path);
        dlclose(library);
        return nullptr;
    }
    auto *factory = static_cast<const clap_plugin_factory_t *>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory || !factory->get_plugin_count || !factory->get_plugin_descriptor || !factory->create_plugin) {
        NSLog(@"CLAP: %s has no plugin factory", path);
        entry->deinit();
        dlclose(library);
        return nullptr;
    }
    static bool registered_exit = false;
    if (!registered_exit) {
        std::atexit(DeinitBundles);
        registered_exit = true;
    }
    Bundle &bundle = Bundles()[path];
    bundle = Bundle{library, entry, factory};
    return &bundle;
}

// ---- The host a scan's probe instance gets: logging and thread checks only.

void ProbeLog(const clap_host_t *, clap_log_severity severity, const char *message) {
    NSLog(@"CLAP plugin log %d: %s", severity, message);
}

bool ProbeIsMainThread(const clap_host_t *) { return IsMainThread(); }
bool ProbeIsAudioThread(const clap_host_t *) { return false; }
void ProbeRequest(const clap_host_t *) {}

const clap_host_log_t kProbeLog = {ProbeLog};
const clap_host_thread_check_t kProbeThreadCheck = {ProbeIsMainThread, ProbeIsAudioThread};

const void *ProbeExtension(const clap_host_t *, const char *id) {
    if (std::strcmp(id, CLAP_EXT_LOG) == 0) return &kProbeLog;
    if (std::strcmp(id, CLAP_EXT_THREAD_CHECK) == 0) return &kProbeThreadCheck;
    return nullptr;
}

const clap_host_t kProbeHost = {
    CLAP_VERSION_INIT, nullptr, "Plainchain", "", "", "1", ProbeExtension, ProbeRequest, ProbeRequest, ProbeRequest,
};

/// Whether the plugin takes notes: a probe instance is created, asked for
/// its note input ports, and destroyed.
bool HasNoteInput(const char *path, const char *clap_id) {
    const clap_plugin_t *plugin = pc_clap::CreatePlugin(path, clap_id, &kProbeHost);
    if (!plugin) return false;
    bool notes = false;
    if (plugin->init(plugin)) {
        auto *ports = static_cast<const clap_plugin_note_ports_t *>(plugin->get_extension(plugin, CLAP_EXT_NOTE_PORTS));
        notes = ports && ports->count(plugin, true) > 0;
    }
    pc_clap::DestroyPlugin(plugin);
    return notes;
}

bool HasFeature(const clap_plugin_descriptor_t *descriptor, const char *feature) {
    if (!descriptor->features) return false;
    for (const char *const *f = descriptor->features; *f; f++) {
        if (std::strcmp(*f, feature) == 0) return true;
    }
    return false;
}

uint64_t Fnv1a(const char *text) {
    uint64_t hash = kFnvOffset;
    for (const char *p = text; *p; p++) {
        hash ^= static_cast<uint8_t>(*p);
        hash *= kFnvPrime;
    }
    return hash;
}

/// Each byte of `bits` becomes one of the 94 printable characters other than
/// the space, so Plainchain's four-character text form of the code (FourCC)
/// stays readable in session files.
uint32_t Printable(uint32_t bits) {
    uint32_t code = 0;
    for (int shift = 24; shift >= 0; shift -= 8) {
        code |= (kPrintableFirst + ((bits >> shift) & 0xff) % kPrintableCount) << shift;
    }
    return code;
}

/// The Audio Unit version for a CLAP version string such as "1.4.4":
/// major << 16 | minor << 8 | bug fix.
UInt32 AudioUnitVersion(const char *version) {
    unsigned major = 0, minor = 0, fix = 0;
    if (version) std::sscanf(version, "%u.%u.%u", &major, &minor, &fix);
    return (std::min(major, 0xffffu) << 16) | (std::min(minor, 0xffu) << 8) | std::min(fix, 0xffu);
}

bool IsRegistered(uint32_t type, uint32_t subtype, uint32_t manufacturer) {
    for (auto &r : Registry()) {
        if (r->type == type && r->subtype == subtype && r->manufacturer == manufacturer) return true;
    }
    return false;
}

std::string Text(const char *text) { return text ? text : ""; }

void Fill(const Registered &r, pc_clap_plugin *out) {
    *out = pc_clap_plugin{r.path.c_str(), r.clap_id.c_str(), r.name.c_str(), r.vendor.c_str(), r.type, r.subtype, r.manufacturer};
}

}  // namespace

namespace pc_clap {

const clap_plugin_t *CreatePlugin(const char *path, const char *clap_id, const clap_host_t *host) {
    const Bundle *bundle = LoadBundle(path);
    if (!bundle) return nullptr;
    const clap_plugin_t *plugin = bundle->factory->create_plugin(bundle->factory, host, clap_id);
    if (plugin) g_live_plugins++;
    return plugin;
}

void DestroyPlugin(const clap_plugin_t *plugin) {
    plugin->destroy(plugin);
    g_live_plugins--;
}

}  // namespace pc_clap

extern "C" {

int pc_clap_register_bundle(const char *path) {
    const Bundle *bundle = LoadBundle(path);
    if (!bundle) return -1;
    uint32_t count = bundle->factory->get_plugin_count(bundle->factory);
    for (uint32_t i = 0; i < count; i++) {
        const clap_plugin_descriptor_t *d = bundle->factory->get_plugin_descriptor(bundle->factory, i);
        if (!d || !d->id) continue;
        // Subtype and manufacturer are the two halves of the id's 64-bit FNV-1a hash.
        uint64_t hash = Fnv1a(d->id);
        uint32_t subtype = Printable(static_cast<uint32_t>(hash >> 32));
        uint32_t manufacturer = Printable(static_cast<uint32_t>(hash));
        bool known = false;
        for (uint32_t type : {kFourCcMusicDevice, kFourCcMusicEffect, kFourCcEffect}) {
            known = known || IsRegistered(type, subtype, manufacturer);
        }
        if (known) continue;
        uint32_t type = kFourCcEffect;
        if (HasFeature(d, CLAP_PLUGIN_FEATURE_INSTRUMENT)) {
            type = kFourCcMusicDevice;
        } else if (HasNoteInput(path, d->id)) {
            type = kFourCcMusicEffect;
        }
        auto r = std::make_unique<Registered>();
        *r = Registered{path, d->id, Text(d->name), Text(d->vendor), type, subtype, manufacturer};
        AudioComponentDescription description = {type, subtype, manufacturer, 0, 0};
        NSString *name = r->vendor.empty() ? @(r->name.c_str())
                                           : [NSString stringWithFormat:@"%s: %s", r->vendor.c_str(), r->name.c_str()];
        [AUAudioUnit registerSubclass:[ClapAudioUnit class] asComponentDescription:description name:name version:AudioUnitVersion(d->version)];
        Registry().push_back(std::move(r));
    }
    return static_cast<int>(count);
}

int pc_clap_scan(const char *directory) {
    NSString *dir = @(directory);
    NSArray<NSString *> *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    int total = 0;
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"clap"]) continue;
        int count = pc_clap_register_bundle([dir stringByAppendingPathComponent:name].fileSystemRepresentation);
        if (count > 0) total += count;
    }
    return total;
}

int pc_clap_count(void) { return static_cast<int>(Registry().size()); }

bool pc_clap_plugin_at(int index, pc_clap_plugin *out) {
    if (index < 0 || index >= pc_clap_count()) return false;
    Fill(*Registry()[index], out);
    return true;
}

bool pc_clap_lookup(uint32_t type, uint32_t subtype, uint32_t manufacturer, pc_clap_plugin *out) {
    for (auto &r : Registry()) {
        if (r->type == type && r->subtype == subtype && r->manufacturer == manufacturer) {
            Fill(*r, out);
            return true;
        }
    }
    return false;
}

}  // extern "C"
