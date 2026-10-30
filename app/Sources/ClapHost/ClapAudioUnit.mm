// ClapAudioUnit: one CLAP plugin instance as an in-process Audio Unit. The
// plugin is created, activated, deactivated, and destroyed on the main
// thread; `process` runs on whatever thread renders the unit. The render
// block reaches the plugin through a plain C++ `Core`, never through the
// Objective-C object, and allocates nothing.
#include "ClapInternal.h"
#include "clap_host.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <set>
#include <vector>

namespace {

/// Input events one render block can carry; the rest of a host queue waits a block.
constexpr uint32_t kMaxEvents = 1024;
/// Parameter changes each queue holds between drains.
constexpr uint32_t kQueueCapacity = 1024;
constexpr double kDefaultSampleRate = 48000;
/// How often the main thread drains the plugin's parameter reports and answers its callback requests.
constexpr uint64_t kDrainIntervalNs = 20 * NSEC_PER_MSEC;
constexpr uint64_t kDrainLeewayNs = 5 * NSEC_PER_MSEC;
/// The capacity of a parameter's display text.
constexpr uint32_t kTextCapacity = 256;
/// A stepped enumeration with at most this many values gets value strings (a menu in a generic view).
constexpr double kMaxValueStrings = 128;
constexpr double kMidiVelocityMax = 127;
constexpr uint8_t kMidiNoteOff = 0x80;
constexpr uint8_t kMidiNoteOn = 0x90;
constexpr uint8_t kMidiKindMask = 0xf0;
constexpr uint8_t kMidiChannelMask = 0x0f;
constexpr uint32_t kMidiMessageBytes = 3;
/// The key `fullState` keeps the plugin's own `clap.state` bytes under.
NSString *const kStateKey = @"clap-state";

enum Dialect { kNoNotes = 0, kClapNotes = 1, kMidiNotes = 2 };

struct ParamChange {
    clap_id id;
    double value;
};

/// Bounded lock-free queue (Vyukov's): any number of producers and
/// consumers, a push into a full queue fails, nothing allocates after
/// construction. `N` is a power of two.
template <typename T, uint32_t N>
class Queue {
  public:
    Queue() {
        for (uint32_t i = 0; i < N; i++) cells_[i].sequence.store(i, std::memory_order_relaxed);
    }

    bool Push(const T &value) {
        uint32_t pos = enqueue_.load(std::memory_order_relaxed);
        for (;;) {
            Cell &cell = cells_[pos & (N - 1)];
            int32_t diff = static_cast<int32_t>(cell.sequence.load(std::memory_order_acquire) - pos);
            if (diff == 0) {
                if (enqueue_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) {
                    cell.value = value;
                    cell.sequence.store(pos + 1, std::memory_order_release);
                    return true;
                }
            } else if (diff < 0) {
                return false;
            } else {
                pos = enqueue_.load(std::memory_order_relaxed);
            }
        }
    }

    bool Pop(T &value) {
        uint32_t pos = dequeue_.load(std::memory_order_relaxed);
        for (;;) {
            Cell &cell = cells_[pos & (N - 1)];
            int32_t diff = static_cast<int32_t>(cell.sequence.load(std::memory_order_acquire) - (pos + 1));
            if (diff == 0) {
                if (dequeue_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) {
                    value = cell.value;
                    cell.sequence.store(pos + N, std::memory_order_release);
                    return true;
                }
            } else if (diff < 0) {
                return false;
            } else {
                pos = dequeue_.load(std::memory_order_relaxed);
            }
        }
    }

  private:
    static_assert((N & (N - 1)) == 0, "the capacity is a power of two");
    struct Cell {
        std::atomic<uint32_t> sequence;
        T value;
    };
    Cell cells_[N];
    alignas(64) std::atomic<uint32_t> enqueue_{0};
    alignas(64) std::atomic<uint32_t> dequeue_{0};
};

union InputEvent {
    clap_event_header_t header;
    clap_event_note_t note;
    clap_event_midi_t midi;
    clap_event_param_value_t param;
};

/// A `clap_input_events` over a fixed array; `list.ctx` points back here.
struct EventList {
    InputEvent *events = nullptr;
    uint32_t count = 0;
    uint32_t capacity = 0;
    clap_input_events_t list{};
};

uint32_t EventListSize(const clap_input_events_t *list) { return static_cast<const EventList *>(list->ctx)->count; }

const clap_event_header_t *EventListGet(const clap_input_events_t *list, uint32_t index) {
    auto *events = static_cast<const EventList *>(list->ctx);
    return index < events->count ? &events->events[index].header : nullptr;
}

void InitEventList(EventList &list, InputEvent *storage, uint32_t capacity) {
    list.events = storage;
    list.count = 0;
    list.capacity = capacity;
    list.list = clap_input_events_t{&list, EventListSize, EventListGet};
}

/// Everything the plugin and the render block share. The fields above the
/// atomics are set on the main thread while the unit is not rendering and
/// only read while it is.
struct Core {
    const clap_plugin_t *plugin = nullptr;
    clap_host_t host{};
    const clap_plugin_params_t *params = nullptr;
    const clap_plugin_audio_ports_t *audio_ports = nullptr;
    const clap_plugin_configurable_audio_ports_t *configurable_ports = nullptr;
    const clap_plugin_note_ports_t *note_ports = nullptr;
    const clap_plugin_state_t *state = nullptr;
    const clap_plugin_latency_t *latency = nullptr;
    Dialect dialect = kNoNotes;
    /// Whether the note port also takes raw MIDI (controllers, pitch bend) beside CLAP notes.
    bool takes_midi = false;
    bool created_on_main = false;

    /// Channel counts per port.
    std::vector<uint32_t> inputs;
    std::vector<uint32_t> outputs;

    // Render resources, sized when render resources are allocated.
    double sample_rate = kDefaultSampleRate;
    uint32_t max_frames = 0;
    std::vector<float> samples;
    /// Each channel's own buffer, inputs then outputs, then one channel of silence.
    std::vector<float *> homes;
    std::vector<float *> input_channels;
    std::vector<float *> output_channels;
    std::vector<clap_audio_buffer_t> input_buffers;
    std::vector<clap_audio_buffer_t> output_buffers;
    float *silence = nullptr;
    /// Input bus 0's buffers, handed to the pull block.
    AudioBufferList *pull_list = nullptr;
    InputEvent event_storage[kMaxEvents];
    EventList events;
    clap_output_events_t out_events{};

    // Render thread only, and the main thread once rendering has stopped.
    int64_t steady_time = 0;
    bool processing = false;
    bool process_refused = false;

    // Main thread only.
    bool activating = false;
    uint32_t latency_frames = 0;
    __weak ClapAudioUnit *owner = nil;

    std::atomic<bool> active{false};
    std::atomic<bool> bypass{false};
    /// The thread inside a render call, for `clap.thread-check`.
    std::atomic<pthread_t> audio_thread{nullptr};
    std::atomic<bool> callback_requested{false};

    /// Values the host set through the parameter tree, sent at frame 0 of the next block.
    Queue<ParamChange, kQueueCapacity> to_plugin;
    /// Values the plugin reported, set on the parameter tree on the main thread.
    Queue<ParamChange, kQueueCapacity> from_plugin;

    std::atomic<uint64_t> process_calls{0};
    std::atomic<uint64_t> midi_render_events{0};
    std::atomic<uint64_t> note_events{0};
    std::atomic<uint64_t> midi_events{0};
    std::atomic<uint64_t> parameter_render_events{0};
    std::atomic<uint64_t> host_parameter_events{0};
    std::atomic<uint64_t> plugin_parameter_events{0};
    std::atomic<uint64_t> dropped_events{0};
};

constexpr auto kRelaxed = std::memory_order_relaxed;

bool IsMainThread() { return pthread_main_np() != 0; }

bool IsAudioThread(Core *c) {
    pthread_t thread = c->audio_thread.load(std::memory_order_acquire);
    return thread && pthread_equal(thread, pthread_self());
}

Core *CoreOf(const clap_host_t *host) { return static_cast<Core *>(host->host_data); }

template <typename T>
const T *Extension(const clap_plugin_t *plugin, const char *id) {
    return static_cast<const T *>(plugin->get_extension(plugin, id));
}

NSString *TextOf(const char *chars, size_t capacity) {
    return [[NSString alloc] initWithBytes:chars length:strnlen(chars, capacity) encoding:NSUTF8StringEncoding] ?: @"";
}

void Count(std::atomic<uint64_t> &counter) { counter.fetch_add(1, kRelaxed); }

// ---- Events

void AddParam(Core *c, EventList &list, uint32_t time, clap_id id, double value) {
    if (list.count == list.capacity) {
        Count(c->dropped_events);
        return;
    }
    clap_event_param_value_t &e = list.events[list.count++].param;
    e.header = {sizeof(clap_event_param_value_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0};
    e.param_id = id;
    e.cookie = nullptr;
    e.note_id = -1;
    e.port_index = -1;
    e.channel = -1;
    e.key = -1;
    e.value = value;
}

/// One MIDI 1 message: note on and off become CLAP note events when the
/// plugin takes them, everything else (and notes for a MIDI-only port) a
/// CLAP MIDI event when the plugin takes MIDI.
void AddMidi(Core *c, EventList &list, uint32_t time, const uint8_t *data, uint16_t length) {
    if (length == 0 || c->dialect == kNoNotes) return;
    if (list.count == list.capacity) {
        Count(c->dropped_events);
        return;
    }
    uint8_t kind = data[0] & kMidiKindMask;
    bool note = (kind == kMidiNoteOn || kind == kMidiNoteOff) && length >= kMidiMessageBytes;
    if (note && c->dialect == kClapNotes) {
        bool on = kind == kMidiNoteOn && data[2] > 0;
        clap_event_note_t &e = list.events[list.count++].note;
        e.header = {sizeof(clap_event_note_t), time, CLAP_CORE_EVENT_SPACE_ID,
                    static_cast<uint16_t>(on ? CLAP_EVENT_NOTE_ON : CLAP_EVENT_NOTE_OFF), CLAP_EVENT_IS_LIVE};
        e.note_id = -1;
        e.port_index = 0;
        e.channel = data[0] & kMidiChannelMask;
        e.key = data[1];
        e.velocity = data[2] / kMidiVelocityMax;
        Count(c->note_events);
        return;
    }
    if (!c->takes_midi) return;
    clap_event_midi_t &e = list.events[list.count++].midi;
    e.header = {sizeof(clap_event_midi_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_MIDI, CLAP_EVENT_IS_LIVE};
    e.port_index = 0;
    for (uint32_t i = 0; i < kMidiMessageBytes; i++) e.data[i] = i < length ? data[i] : 0;
    Count(c->midi_events);
}

/// The block's input events: the host's queued parameter values at frame 0,
/// then the render events of the slice at their offsets.
void BuildEvents(Core *c, const AudioTimeStamp *timestamp, AUAudioFrameCount frames, const AURenderEvent *head) {
    EventList &list = c->events;
    list.count = 0;
    ParamChange change;
    while (list.count < list.capacity && c->to_plugin.Pop(change)) {
        AddParam(c, list, 0, change.id, change.value);
        Count(c->host_parameter_events);
    }
    const auto start = static_cast<AUEventSampleTime>(timestamp->mSampleTime);
    for (const AURenderEvent *e = head; e; e = e->head.next) {
        AUEventSampleTime offset = std::clamp<AUEventSampleTime>(e->head.eventSampleTime - start, 0, frames - 1);
        auto time = static_cast<uint32_t>(offset);
        switch (e->head.eventType) {
            case AURenderEventMIDI:
                Count(c->midi_render_events);
                AddMidi(c, list, time, e->MIDI.data, e->MIDI.length);
                break;
            case AURenderEventParameter:
            case AURenderEventParameterRamp:
                Count(c->parameter_render_events);
                AddParam(c, list, time, static_cast<clap_id>(e->parameter.parameterAddress), e->parameter.value);
                break;
            default:
                break;
        }
    }
}

bool PushOutputEvent(const clap_output_events_t *list, const clap_event_header_t *event) {
    auto *c = static_cast<Core *>(list->ctx);
    if (event->space_id == CLAP_CORE_EVENT_SPACE_ID && event->type == CLAP_EVENT_PARAM_VALUE) {
        auto *value = reinterpret_cast<const clap_event_param_value_t *>(event);
        Count(c->plugin_parameter_events);
        if (!c->from_plugin.Push({value->param_id, value->value})) Count(c->dropped_events);
    }
    return true;
}

// ---- Render

uint32_t ChannelTotal(const std::vector<uint32_t> &ports) {
    uint32_t total = 0;
    for (uint32_t n : ports) total += n;
    return total;
}

std::vector<clap_audio_buffer_t> PortBuffers(const std::vector<uint32_t> &ports, std::vector<float *> &channels) {
    std::vector<clap_audio_buffer_t> buffers;
    uint32_t first = 0;
    for (uint32_t n : ports) {
        buffers.push_back(clap_audio_buffer_t{channels.data() + first, nullptr, n, 0, 0});
        first += n;
    }
    return buffers;
}

/// Main thread, not rendering: every buffer and list the render block uses.
void AllocateBuffers(Core *c) {
    uint32_t ins = ChannelTotal(c->inputs);
    uint32_t outs = ChannelTotal(c->outputs);
    uint32_t channels = ins + outs + 1;
    c->samples.assign(static_cast<size_t>(channels) * c->max_frames, 0.0f);
    c->homes.resize(channels);
    for (uint32_t i = 0; i < channels; i++) c->homes[i] = c->samples.data() + static_cast<size_t>(i) * c->max_frames;
    c->input_channels.assign(c->homes.begin(), c->homes.begin() + ins);
    c->output_channels.assign(c->homes.begin() + ins, c->homes.begin() + ins + outs);
    c->silence = c->homes.back();
    c->input_buffers = PortBuffers(c->inputs, c->input_channels);
    c->output_buffers = PortBuffers(c->outputs, c->output_channels);
    uint32_t pulled = c->inputs.empty() ? 1 : c->inputs[0];
    c->pull_list = static_cast<AudioBufferList *>(calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * pulled));
    c->pull_list->mNumberBuffers = pulled;
}

void FreeBuffers(Core *c) {
    c->samples.clear();
    c->homes.clear();
    c->input_channels.clear();
    c->output_channels.clear();
    c->input_buffers.clear();
    c->output_buffers.clear();
    c->silence = nullptr;
    free(c->pull_list);
    c->pull_list = nullptr;
}

/// The first input port's channels for this slice: pulled from input bus 0,
/// or silence. Every other input port carries silence.
void PullInput(Core *c, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
               __unsafe_unretained AURenderPullInputBlock pull) {
    size_t bytes = frames * sizeof(float);
    uint32_t total = static_cast<uint32_t>(c->input_channels.size());
    for (uint32_t i = 0; i < total; i++) {
        c->input_channels[i] = c->homes[i];
        std::memset(c->homes[i], 0, bytes);
    }
    if (c->inputs.empty() || !pull) return;
    AudioBufferList *list = c->pull_list;
    for (uint32_t i = 0; i < list->mNumberBuffers; i++) {
        list->mBuffers[i] = AudioBuffer{1, static_cast<UInt32>(bytes), c->homes[i]};
    }
    AudioUnitRenderActionFlags pull_flags = 0;
    if (pull(&pull_flags, timestamp, frames, 0, list) != noErr) {
        for (uint32_t i = 0; i < list->mNumberBuffers; i++) std::memset(c->homes[i], 0, bytes);
        return;
    }
    // The upstream may have pointed the list at buffers of its own.
    for (uint32_t i = 0; i < list->mNumberBuffers; i++) {
        if (list->mBuffers[i].mData) c->input_channels[i] = static_cast<float *>(list->mBuffers[i].mData);
    }
}

/// Realtime: one slice through the plugin. Allocates nothing, takes no
/// locks, and touches no Objective-C object.
AUAudioUnitStatus Render(Core *c, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
                         AudioBufferList *output, const AURenderEvent *events,
                         __unsafe_unretained AURenderPullInputBlock pull) {
    if (!c->active.load(std::memory_order_acquire)) return kAudioUnitErr_Uninitialized;
    if (frames > c->max_frames) return kAudioUnitErr_TooManyFramesToProcess;
    c->audio_thread.store(pthread_self(), std::memory_order_release);
    size_t bytes = frames * sizeof(float);
    PullInput(c, flags, timestamp, frames, pull);
    BuildEvents(c, timestamp, frames, events);
    for (float *channel : c->output_channels) std::memset(channel, 0, bytes);
    if (!c->processing && !c->process_refused) {
        c->processing = c->plugin->start_processing(c->plugin);
        c->process_refused = !c->processing;
    }
    clap_process_status status = CLAP_PROCESS_ERROR;
    if (c->processing) {
        clap_process_t process = {
            c->steady_time,
            frames,
            nullptr,
            c->input_buffers.data(),
            c->output_buffers.data(),
            static_cast<uint32_t>(c->input_buffers.size()),
            static_cast<uint32_t>(c->output_buffers.size()),
            &c->events.list,
            &c->out_events,
        };
        status = c->plugin->process(c->plugin, &process);
        Count(c->process_calls);
    }
    c->steady_time += frames;
    // The output bus carries the first output port, or the input when bypassed.
    bool bypass = c->bypass.load(kRelaxed);
    uint32_t port = c->outputs[0];
    uint32_t inputs = c->inputs.empty() ? 0 : c->inputs[0];
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        float *source = c->silence;
        if (bypass) {
            if (inputs > 0) source = c->input_channels[std::min(i, inputs - 1)];
        } else if (status != CLAP_PROCESS_ERROR) {
            source = c->output_channels[std::min(i, port - 1)];
        }
        AudioBuffer &buffer = output->mBuffers[i];
        if (!buffer.mData) {
            // The host left the buffers to the unit: point the list at the unit's own.
            buffer.mData = source;
        } else if (buffer.mData != source) {
            std::memcpy(buffer.mData, source, bytes);
        }
        buffer.mDataByteSize = static_cast<UInt32>(bytes);
    }
    c->audio_thread.store(nullptr, std::memory_order_release);
    return noErr;
}

void ReadPorts(Core *c) {
    c->inputs.clear();
    c->outputs.clear();
    if (!c->audio_ports) return;
    for (bool input : {true, false}) {
        uint32_t count = c->audio_ports->count(c->plugin, input);
        for (uint32_t i = 0; i < count; i++) {
            clap_audio_port_info_t info{};
            uint32_t channels = c->audio_ports->get(c->plugin, i, input, &info) ? info.channel_count : 0;
            (input ? c->inputs : c->outputs).push_back(channels);
        }
    }
}

/// Main thread, active: the plugin stops processing and is deactivated.
/// `stop_processing` runs here, not on the audio thread, since rendering has
/// stopped by the time the host deallocates render resources.
void Deactivate(Core *c) {
    c->active.store(false, std::memory_order_release);
    if (c->processing) c->plugin->stop_processing(c->plugin);
    c->processing = false;
    c->plugin->deactivate(c->plugin);
    FreeBuffers(c);
}

/// Main thread: everything the unit owns, after the Objective-C object is gone.
void Teardown(Core *c) {
    if (c->plugin) {
        if (c->active.load()) Deactivate(c);
        pc_clap::DestroyPlugin(c->plugin);
    }
    FreeBuffers(c);
    delete c;
}

void RunOnMain(dispatch_block_t block) {
    if (IsMainThread()) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

AVAudioFormat *StandardFormat(double rate, uint32_t channels) {
    if (channels <= 2) return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | channels];
    return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channelLayout:layout];
}

NSError *AudioUnitError(OSStatus status) { return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]; }

// ---- Streams over NSData, for clap.state

int64_t WriteStream(const clap_ostream_t *stream, const void *buffer, uint64_t size) {
    [(__bridge NSMutableData *)stream->ctx appendBytes:buffer length:size];
    return static_cast<int64_t>(size);
}

struct Reader {
    const uint8_t *bytes;
    uint64_t size;
    uint64_t position;
};

int64_t ReadStream(const clap_istream_t *stream, void *buffer, uint64_t size) {
    auto *reader = static_cast<Reader *>(stream->ctx);
    uint64_t n = std::min(size, reader->size - reader->position);
    std::memcpy(buffer, reader->bytes + reader->position, n);
    reader->position += n;
    return static_cast<int64_t>(n);
}

}  // namespace

@interface ClapAudioUnit ()
- (void)answerCallback;
- (void)rescanParameters:(clap_param_rescan_flags)flags;
- (void)flushParameters;
- (void)readLatency;
- (BOOL)readParameter:(clap_id)id value:(double *)value;
- (BOOL)postPluginParameter:(clap_id)id value:(double)value;
- (void)readInfo:(pc_clap_unit_info *)out;
@end

namespace {

// ---- The host object the plugin holds

void HostLog(const clap_host_t *, clap_log_severity severity, const char *message) {
    NSLog(@"CLAP plugin log %d: %s", severity, message);
}

bool HostIsMainThread(const clap_host_t *) { return IsMainThread(); }
bool HostIsAudioThread(const clap_host_t *host) { return IsAudioThread(CoreOf(host)); }

void HostParamsRescan(const clap_host_t *host, clap_param_rescan_flags flags) {
    [CoreOf(host)->owner rescanParameters:flags];
}

void HostParamsClear(const clap_host_t *, clap_id, clap_param_clear_flags) {}

void HostParamsRequestFlush(const clap_host_t *host) {
    Core *c = CoreOf(host);
    // While active the next block's process call carries the flush.
    if (c->active.load()) return;
    __weak ClapAudioUnit *owner = c->owner;
    dispatch_async(dispatch_get_main_queue(), ^{
        [owner flushParameters];
    });
}

void HostStateMarkDirty(const clap_host_t *) {}

void HostLatencyChanged(const clap_host_t *host) { [CoreOf(host)->owner readLatency]; }

bool HostAudioPortsIsRescanFlagSupported(const clap_host_t *, uint32_t) { return false; }
void HostAudioPortsRescan(const clap_host_t *, uint32_t) {}

void HostGuiResizeHintsChanged(const clap_host_t *) {}
bool HostGuiRequestResize(const clap_host_t *, uint32_t, uint32_t) { return false; }
bool HostGuiRequestShow(const clap_host_t *) { return false; }
bool HostGuiRequestHide(const clap_host_t *) { return false; }
void HostGuiClosed(const clap_host_t *, bool) {}

const clap_host_log_t kHostLog = {HostLog};
const clap_host_thread_check_t kHostThreadCheck = {HostIsMainThread, HostIsAudioThread};
const clap_host_params_t kHostParams = {HostParamsRescan, HostParamsClear, HostParamsRequestFlush};
const clap_host_state_t kHostState = {HostStateMarkDirty};
const clap_host_latency_t kHostLatency = {HostLatencyChanged};
const clap_host_audio_ports_t kHostAudioPorts = {HostAudioPortsIsRescanFlagSupported, HostAudioPortsRescan};
const clap_host_gui_t kHostGui = {
    HostGuiResizeHintsChanged, HostGuiRequestResize, HostGuiRequestShow, HostGuiRequestHide, HostGuiClosed,
};

const void *HostGetExtension(const clap_host_t *, const char *id) {
    if (std::strcmp(id, CLAP_EXT_LOG) == 0) return &kHostLog;
    if (std::strcmp(id, CLAP_EXT_THREAD_CHECK) == 0) return &kHostThreadCheck;
    if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kHostParams;
    if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kHostState;
    if (std::strcmp(id, CLAP_EXT_LATENCY) == 0) return &kHostLatency;
    if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kHostAudioPorts;
    if (std::strcmp(id, CLAP_EXT_GUI) == 0) return &kHostGui;
    return nullptr;
}

void HostRequestRestart(const clap_host_t *) {}
void HostRequestProcess(const clap_host_t *) {}

/// The plugin's `on_main_thread` runs on the main queue: dispatched from
/// here off the audio thread, and from the drain timer when the request came
/// from inside a render call, where nothing may be dispatched.
void HostRequestCallback(const clap_host_t *host) {
    Core *c = CoreOf(host);
    c->callback_requested.store(true, std::memory_order_release);
    if (IsAudioThread(c)) return;
    __weak ClapAudioUnit *owner = c->owner;
    dispatch_async(dispatch_get_main_queue(), ^{
        [owner answerCallback];
    });
}

}  // namespace

@implementation ClapAudioUnit {
    Core *_core;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AUInternalRenderBlock _renderBlock;
    dispatch_source_t _drainTimer;
    /// Main thread: set while the unit itself changes tree values (values the
    /// plugin reported, a state load), which are not sent back to the plugin.
    BOOL _quietTree;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:description options:options error:outError];
    if (!self) return nil;
    _core = new Core();
    Core *c = _core;
    c->owner = self;
    c->created_on_main = IsMainThread();
    c->host = clap_host_t{
        CLAP_VERSION_INIT, c, "Plainchain", "", "", "1", HostGetExtension, HostRequestRestart, HostRequestProcess, HostRequestCallback,
    };
    c->out_events = clap_output_events_t{c, PushOutputEvent};
    InitEventList(c->events, c->event_storage, kMaxEvents);
    pc_clap_plugin entry;
    if (!pc_clap_lookup(description.componentType, description.componentSubType, description.componentManufacturer, &entry)) {
        if (outError) *outError = AudioUnitError(kAudioUnitErr_FailedInitialization);
        return nil;
    }
    __block BOOL created = NO;
    // CLAP creates, initializes, and queries a plugin on the main thread.
    RunOnMain(^{
        created = [self createPlugin:entry];
    });
    if (!created) {
        if (outError) *outError = AudioUnitError(kAudioUnitErr_FailedInitialization);
        return nil;
    }
    _renderBlock = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
                                      NSInteger, AudioBufferList *output, const AURenderEvent *events,
                                      __unsafe_unretained AURenderPullInputBlock pull) {
        return Render(c, flags, timestamp, frames, output, events, pull);
    };
    __weak ClapAudioUnit *weakSelf = self;
    _drainTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_drainTimer, dispatch_time(DISPATCH_TIME_NOW, kDrainIntervalNs), kDrainIntervalNs, kDrainLeewayNs);
    dispatch_source_set_event_handler(_drainTimer, ^{
        [weakSelf drain];
    });
    dispatch_resume(_drainTimer);
    return self;
}

/// Main thread: the plugin, its extensions, its ports, the busses, and the parameter tree.
- (BOOL)createPlugin:(const pc_clap_plugin &)entry {
    Core *c = _core;
    c->plugin = pc_clap::CreatePlugin(entry.path, entry.clap_id, &c->host);
    if (!c->plugin) return NO;
    if (!c->plugin->init(c->plugin)) {
        pc_clap::DestroyPlugin(c->plugin);
        c->plugin = nullptr;
        return NO;
    }
    c->params = Extension<clap_plugin_params_t>(c->plugin, CLAP_EXT_PARAMS);
    c->audio_ports = Extension<clap_plugin_audio_ports_t>(c->plugin, CLAP_EXT_AUDIO_PORTS);
    c->configurable_ports = Extension<clap_plugin_configurable_audio_ports_t>(c->plugin, CLAP_EXT_CONFIGURABLE_AUDIO_PORTS);
    if (!c->configurable_ports) {
        c->configurable_ports = Extension<clap_plugin_configurable_audio_ports_t>(c->plugin, CLAP_EXT_CONFIGURABLE_AUDIO_PORTS_COMPAT);
    }
    c->note_ports = Extension<clap_plugin_note_ports_t>(c->plugin, CLAP_EXT_NOTE_PORTS);
    c->state = Extension<clap_plugin_state_t>(c->plugin, CLAP_EXT_STATE);
    c->latency = Extension<clap_plugin_latency_t>(c->plugin, CLAP_EXT_LATENCY);
    clap_note_port_info_t note_port{};
    if (c->note_ports && c->note_ports->count(c->plugin, true) > 0 && c->note_ports->get(c->plugin, 0, true, &note_port)) {
        // CLAP note events when the port takes them, raw MIDI otherwise.
        c->takes_midi = note_port.supported_dialects & CLAP_NOTE_DIALECT_MIDI;
        if (note_port.supported_dialects & CLAP_NOTE_DIALECT_CLAP) {
            c->dialect = kClapNotes;
        } else if (c->takes_midi) {
            c->dialect = kMidiNotes;
        }
    }
    ReadPorts(c);
    if (c->outputs.empty() || c->outputs[0] == 0) {
        NSLog(@"CLAP: %s has no audio output", entry.clap_id);
        return NO;
    }
    AUAudioUnitBus *output = [[AUAudioUnitBus alloc] initWithFormat:StandardFormat(kDefaultSampleRate, c->outputs[0]) error:nil];
    output.supportedChannelCounts = [self channelCountsForInput:NO];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[ output ]];
    NSArray<AUAudioUnitBus *> *inputs = @[];
    if (!c->inputs.empty() && c->inputs[0] > 0) {
        AUAudioUnitBus *input = [[AUAudioUnitBus alloc] initWithFormat:StandardFormat(kDefaultSampleRate, c->inputs[0]) error:nil];
        input.supportedChannelCounts = [self channelCountsForInput:YES];
        inputs = @[ input ];
    }
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:inputs];
    self.parameterTree = [self buildParameterTree];
    return YES;
}

/// The first port's channel count, and mono and stereo besides when the
/// plugin can be configured to them (`clap.configurable-audio-ports`).
- (NSArray<NSNumber *> *)channelCountsForInput:(BOOL)input {
    Core *c = _core;
    uint32_t own = input ? c->inputs[0] : c->outputs[0];
    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithObject:@(own)];
    if (!c->configurable_ports) return counts;
    for (uint32_t channels : {1u, 2u}) {
        if (channels == own) continue;
        clap_audio_port_configuration_request_t request = {
            static_cast<bool>(input), 0, channels, channels == 1 ? CLAP_PORT_MONO : CLAP_PORT_STEREO, nullptr,
        };
        if (c->configurable_ports->can_apply_configuration(c->plugin, &request, 1)) [counts addObject:@(channels)];
    }
    return [counts sortedArrayUsingSelector:@selector(compare:)];
}

/// Main thread, inactive: whether the first ports carry the busses' channel
/// counts, configuring the plugin's ports to them when it lets the host.
- (BOOL)fitPortsToInput:(uint32_t)input output:(uint32_t)output {
    Core *c = _core;
    auto fits = [&] { return c->outputs[0] == output && (c->inputs.empty() ? input == 0 : c->inputs[0] == input); };
    if (fits()) return YES;
    if (!c->configurable_ports) return NO;
    std::vector<clap_audio_port_configuration_request_t> requests;
    requests.push_back({false, 0, output, output == 1 ? CLAP_PORT_MONO : CLAP_PORT_STEREO, nullptr});
    if (!c->inputs.empty()) requests.push_back({true, 0, input, input == 1 ? CLAP_PORT_MONO : CLAP_PORT_STEREO, nullptr});
    auto count = static_cast<uint32_t>(requests.size());
    if (!c->configurable_ports->can_apply_configuration(c->plugin, requests.data(), count)) return NO;
    if (!c->configurable_ports->apply_configuration(c->plugin, requests.data(), count)) return NO;
    ReadPorts(c);
    return !c->outputs.empty() && fits();
}

- (void)dealloc {
    if (_drainTimer) dispatch_source_cancel(_drainTimer);
    Core *c = _core;
    _core = nullptr;
    if (!c) return;
    if (IsMainThread()) {
        Teardown(c);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            Teardown(c);
        });
    }
}

// ---- Busses and render

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (AUInternalRenderBlock)internalRenderBlock { return _renderBlock; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    Core *c = _core;
    AVAudioFormat *format = _outputBusArray[0].format;
    uint32_t input = _inputBusArray.count > 0 ? _inputBusArray[0].format.channelCount : 0;
    bool rates_differ = _inputBusArray.count > 0 && _inputBusArray[0].format.sampleRate != format.sampleRate;
    if (rates_differ || ![self fitPortsToInput:input output:format.channelCount]) {
        if (outError) *outError = AudioUnitError(kAudioUnitErr_FormatNotSupported);
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    c->sample_rate = format.sampleRate;
    c->max_frames = self.maximumFramesToRender;
    AllocateBuffers(c);
    c->activating = true;
    bool activated = c->plugin->activate(c->plugin, c->sample_rate, 1, c->max_frames);
    c->activating = false;
    if (!activated) {
        FreeBuffers(c);
        [super deallocateRenderResources];
        if (outError) *outError = AudioUnitError(kAudioUnitErr_FailedInitialization);
        return NO;
    }
    c->processing = false;
    c->process_refused = false;
    c->steady_time = 0;
    c->active.store(true, std::memory_order_release);
    [self readLatency];
    return YES;
}

- (void)deallocateRenderResources {
    if (_core->active.load()) Deactivate(_core);
    [super deallocateRenderResources];
}

- (void)setShouldBypassEffect:(BOOL)shouldBypassEffect {
    [super setShouldBypassEffect:shouldBypassEffect];
    _core->bypass.store(shouldBypassEffect, kRelaxed);
}

// ---- Latency

- (NSTimeInterval)latency { return _core->latency_frames / _core->sample_rate; }

/// Main thread: the plugin's latency, while it is active or being activated.
- (void)readLatency {
    Core *c = _core;
    if (!c->latency || !(c->active.load() || c->activating)) return;
    uint32_t frames = c->latency->get(c->plugin);
    if (frames == c->latency_frames) return;
    [self willChangeValueForKey:@"latency"];
    c->latency_frames = frames;
    [self didChangeValueForKey:@"latency"];
}

// ---- Main-thread services

/// Main thread, every drain interval: the values the plugin reported go
/// into the tree, with no originator so every observer hears them, and a
/// callback the plugin asked for from the audio thread is answered.
- (void)drain {
    Core *c = _core;
    ParamChange change;
    AUParameterTree *tree = self.parameterTree;
    while (c->from_plugin.Pop(change)) {
        AUParameter *parameter = [tree parameterWithAddress:change.id];
        if (!parameter) continue;
        _quietTree = YES;
        [parameter setValue:static_cast<AUValue>(change.value) originator:nil];
        _quietTree = NO;
    }
    [self answerCallback];
}

- (void)answerCallback {
    Core *c = _core;
    if (c && c->plugin && c->callback_requested.exchange(false)) c->plugin->on_main_thread(c->plugin);
}

// ---- Parameters

- (AUParameterTree *)buildParameterTree {
    Core *c = _core;
    NSMutableArray<AUParameterNode *> *top = [NSMutableArray array];
    NSMutableArray<NSString *> *modules = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<AUParameterNode *> *> *grouped = [NSMutableDictionary dictionary];
    std::set<clap_id> seen;
    uint32_t count = c->params ? c->params->count(c->plugin) : 0;
    for (uint32_t i = 0; i < count; i++) {
        clap_param_info_t info{};
        if (!c->params->get_info(c->plugin, i, &info)) continue;
        if (!seen.insert(info.id).second) {
            NSLog(@"CLAP: parameter id %u appears twice; the tree keeps the first", info.id);
            continue;
        }
        AUParameter *parameter = [self parameterFromInfo:info];
        NSString *module = TextOf(info.module, CLAP_PATH_SIZE);
        if (module.length == 0) {
            [top addObject:parameter];
            continue;
        }
        if (!grouped[module]) {
            grouped[module] = [NSMutableArray array];
            [modules addObject:module];
        }
        [grouped[module] addObject:parameter];
    }
    // Identifiers are unique among siblings: "p" and the CLAP id for a
    // parameter, "g" and the module's position for a group; names repeat.
    [modules enumerateObjectsUsingBlock:^(NSString *module, NSUInteger index, BOOL *) {
        NSString *identifier = [NSString stringWithFormat:@"g%lu", static_cast<unsigned long>(index)];
        [top addObject:[AUParameterTree createGroupWithIdentifier:identifier name:module children:grouped[module]]];
    }];
    AUParameterTree *tree = nil;
    @try {
        tree = [AUParameterTree createTreeWithChildren:top];
    } @catch (NSException *exception) {
        NSLog(@"CLAP: the parameter tree was refused (%@: %@); the unit has no parameters", exception.name, exception.reason);
        tree = [AUParameterTree createTreeWithChildren:@[]];
    }
    __weak ClapAudioUnit *weakSelf = self;
    tree.implementorValueObserver = ^(AUParameter *parameter, AUValue value) {
        [weakSelf hostSetParameter:static_cast<clap_id>(parameter.address) value:value];
    };
    tree.implementorValueProvider = ^AUValue(AUParameter *parameter) {
        double value = parameter.minValue;
        [weakSelf readParameter:static_cast<clap_id>(parameter.address) value:&value];
        return static_cast<AUValue>(value);
    };
    tree.implementorStringFromValueCallback = ^NSString *(AUParameter *parameter, const AUValue *value) {
        ClapAudioUnit *unit = weakSelf;
        auto id = static_cast<clap_id>(parameter.address);
        double v = parameter.minValue;
        if (value) {
            v = *value;
        } else {
            [unit readParameter:id value:&v];
        }
        return [unit textForParameter:id value:v] ?: [NSString stringWithFormat:@"%g", v];
    };
    tree.implementorValueFromStringCallback = ^AUValue(AUParameter *parameter, NSString *text) {
        ClapAudioUnit *unit = weakSelf;
        Core *core = unit ? unit->_core : nullptr;
        double value = text.doubleValue;
        if (core && core->params) core->params->text_to_value(core->plugin, static_cast<clap_id>(parameter.address), text.UTF8String, &value);
        return static_cast<AUValue>(value);
    };
    return tree;
}

/// One AUParameter: the CLAP id as its address, a stepped parameter as an
/// indexed one, with value strings for a short enumeration.
- (AUParameter *)parameterFromInfo:(const clap_param_info_t &)info {
    AudioUnitParameterOptions flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_ValuesHaveStrings;
    if (!(info.flags & CLAP_PARAM_IS_READONLY)) flags |= kAudioUnitParameterFlag_IsWritable;
    bool stepped = info.flags & CLAP_PARAM_IS_STEPPED;
    NSMutableArray<NSString *> *strings = nil;
    if (stepped && (info.flags & CLAP_PARAM_IS_ENUM) && info.max_value - info.min_value < kMaxValueStrings) {
        strings = [NSMutableArray array];
        for (double v = info.min_value; v <= info.max_value; v += 1) {
            [strings addObject:[self textForParameter:info.id value:v] ?: [NSString stringWithFormat:@"%g", v]];
        }
    }
    AUParameter *parameter = [AUParameterTree createParameterWithIdentifier:[NSString stringWithFormat:@"p%u", info.id]
                                                                       name:TextOf(info.name, CLAP_NAME_SIZE)
                                                                    address:info.id
                                                                        min:info.min_value
                                                                        max:info.max_value
                                                                       unit:stepped ? kAudioUnitParameterUnit_Indexed : kAudioUnitParameterUnit_Generic
                                                                   unitName:nil
                                                                      flags:flags
                                                               valueStrings:strings
                                                        dependentParameters:nil];
    double value = info.default_value;
    [self readParameter:info.id value:&value];
    parameter.value = static_cast<AUValue>(value);
    return parameter;
}

- (BOOL)readParameter:(clap_id)id value:(double *)value {
    Core *c = _core;
    return c->params && c->params->get_value(c->plugin, id, value);
}

- (NSString *)textForParameter:(clap_id)id value:(double)value {
    Core *c = _core;
    char text[kTextCapacity] = {};
    if (!c->params || !c->params->value_to_text(c->plugin, id, value, text, kTextCapacity)) return nil;
    return TextOf(text, kTextCapacity);
}

/// A value set through the tree, on any thread: queued for the next block
/// while the plugin is active, flushed to it on the main thread otherwise.
- (void)hostSetParameter:(clap_id)id value:(AUValue)value {
    Core *c = _core;
    bool main = IsMainThread();
    if (main && _quietTree) return;
    if (c->active.load()) {
        if (!c->to_plugin.Push({id, value})) Count(c->dropped_events);
        return;
    }
    if (main) {
        [self flushParameter:id value:value];
        return;
    }
    __weak ClapAudioUnit *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf hostSetParameter:id value:value];
    });
}

/// Main thread, inactive: one value through `params.flush`.
- (void)flushParameter:(clap_id)id value:(double)value {
    Core *c = _core;
    if (!c->params) return;
    InputEvent event;
    EventList list;
    InitEventList(list, &event, 1);
    AddParam(c, list, 0, id, value);
    c->params->flush(c->plugin, &list.list, &c->out_events);
    Count(c->host_parameter_events);
}

- (void)flushParameters {
    Core *c = _core;
    if (!c->params || c->active.load()) return;
    EventList list;
    InitEventList(list, nullptr, 0);
    c->params->flush(c->plugin, &list.list, &c->out_events);
}

/// Main thread: a new tree when the plugin's parameters changed, or every
/// value re-read into the tree, so observers hear the plugin's own changes.
- (void)rescanParameters:(clap_param_rescan_flags)flags {
    if (flags & (CLAP_PARAM_RESCAN_INFO | CLAP_PARAM_RESCAN_ALL)) {
        self.parameterTree = [self buildParameterTree];
        return;
    }
    if (!(flags & CLAP_PARAM_RESCAN_VALUES)) return;
    for (AUParameter *parameter in self.parameterTree.allParameters) {
        double value = 0;
        if (![self readParameter:static_cast<clap_id>(parameter.address) value:&value]) continue;
        _quietTree = YES;
        [parameter setValue:static_cast<AUValue>(value) originator:nil];
        _quietTree = NO;
    }
}

// ---- State

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary<NSString *, id> *state = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    Core *c = _core;
    if (!c->state) return state;
    NSMutableData *bytes = [NSMutableData data];
    clap_ostream_t stream = {(__bridge void *)bytes, WriteStream};
    if (c->state->save(c->plugin, &stream)) state[kStateKey] = bytes;
    return state;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    id bytes = fullState[kStateKey];
    NSData *data = [bytes isKindOfClass:[NSData class]] ? bytes : nil;
    // With the plugin's own bytes present, the parameter values the base
    // class restores stay in the tree; the bytes are what the plugin loads.
    _quietTree = data != nil;
    [super setFullState:fullState];
    _quietTree = NO;
    Core *c = _core;
    if (!data || !c->state) return;
    Reader reader = {static_cast<const uint8_t *>(data.bytes), data.length, 0};
    clap_istream_t stream = {&reader, ReadStream};
    if (!c->state->load(c->plugin, &stream)) NSLog(@"CLAP: the plugin refused its saved state");
}

// ---- The C face's view of a unit

- (void)readInfo:(pc_clap_unit_info *)out {
    Core *c = _core;
    *out = pc_clap_unit_info{
        c->created_on_main,
        c->dialect,
        c->active.load(),
        c->inputs.empty() ? 0 : c->inputs[0],
        c->outputs[0],
        c->latency_frames,
        c->process_calls.load(),
        c->midi_render_events.load(),
        c->note_events.load(),
        c->midi_events.load(),
        c->parameter_render_events.load(),
        c->host_parameter_events.load(),
        c->plugin_parameter_events.load(),
        c->dropped_events.load(),
    };
}

- (BOOL)postPluginParameter:(clap_id)id value:(double)value {
    return _core->to_plugin.Push({id, value}) && _core->from_plugin.Push({id, value});
}

@end

namespace {

ClapAudioUnit *UnitFrom(void *unit) {
    id object = (__bridge id)unit;
    return [object isKindOfClass:[ClapAudioUnit class]] ? object : nil;
}

}  // namespace

extern "C" {

bool pc_clap_unit_read_info(void *unit, pc_clap_unit_info *out) {
    ClapAudioUnit *clap = UnitFrom(unit);
    if (!clap) return false;
    [clap readInfo:out];
    return true;
}

bool pc_clap_unit_param_value(void *unit, uint32_t param_id, double *value) {
    return [UnitFrom(unit) readParameter:param_id value:value];
}

bool pc_clap_unit_post_plugin_param(void *unit, uint32_t param_id, double value) {
    return [UnitFrom(unit) postPluginParameter:param_id value:value];
}

}  // extern "C"
