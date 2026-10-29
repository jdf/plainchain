#include "capn_session.h"
#include "session.capnp.h"

#include <capnp/message.h>
#include <capnp/serialize.h>
#include <kj/array.h>

#include <cstdlib>
#include <cstring>

namespace {

pc_buf toBuf(capnp::MessageBuilder &message) {
    kj::Array<capnp::word> words = capnp::messageToFlatArray(message);
    kj::ArrayPtr<const unsigned char> bytes = words.asBytes();
    pc_buf out{static_cast<uint8_t *>(std::malloc(bytes.size())), bytes.size()};
    if (out.bytes) std::memcpy(out.bytes, bytes.begin(), bytes.size());
    else out.len = 0;
    return out;
}

/// Owns a word-aligned copy of the bytes plus the reader over them, so the
/// Text and Data views handed to Swift stay valid until the handle is freed.
template <typename T>
struct Reader {
    kj::Array<capnp::word> words;
    capnp::FlatArrayMessageReader message;
    typename T::Reader root;

    explicit Reader(kj::Array<capnp::word> w)
        : words(kj::mv(w)), message(words.asPtr()), root(message.getRoot<T>()) {}

    static Reader *make(const uint8_t *bytes, size_t len) noexcept {
        if (!bytes || len == 0 || len % sizeof(capnp::word) != 0) return nullptr;
        try {
            auto words = kj::heapArray<capnp::word>(len / sizeof(capnp::word));
            std::memcpy(words.begin(), bytes, len);
            auto *r = new Reader(kj::mv(words));
            // Touch every field now so malformed input fails here, not in a getter.
            r->validate();
            return r;
        } catch (...) {
            return nullptr;
        }
    }

    void validate();
};

template <> void Reader<Endpoint>::validate() {
    root.getDeviceUid();
    root.getChannels();
    root.getMidiSource();
    root.getMidiSourceName();
}

template <> void Reader<Settings>::validate() { root.getBufferFrames(); }

template <> void Reader<ChainItem>::validate() {
    root.getId(); root.getType(); root.getSubtype(); root.getManufacturer(); root.getState();
    root.getClapId(); root.getClapPath();
}

}  // namespace

struct pc_endpoint : Reader<Endpoint> { using Reader::Reader; };
struct pc_chain_item : Reader<ChainItem> { using Reader::Reader; };

extern "C" {

void pc_buf_free(pc_buf buf) { std::free(buf.bytes); }

pc_buf pc_endpoint_encode(const char *device_uid, const uint32_t *channels, size_t channel_count,
                          const char *midi_source, const char *midi_source_name) {
    capnp::MallocMessageBuilder message;
    Endpoint::Builder e = message.initRoot<Endpoint>();
    e.setDeviceUid(device_uid ? device_uid : "");
    auto list = e.initChannels(static_cast<unsigned>(channel_count));
    for (size_t i = 0; i < channel_count; i++) list.set(static_cast<unsigned>(i), channels[i]);
    e.setMidiSource(midi_source ? midi_source : "");
    e.setMidiSourceName(midi_source_name ? midi_source_name : "");
    return toBuf(message);
}

pc_endpoint *pc_endpoint_read(const uint8_t *bytes, size_t len) {
    return static_cast<pc_endpoint *>(Reader<Endpoint>::make(bytes, len));
}
const char *pc_endpoint_device_uid(const pc_endpoint *e) { return e->root.getDeviceUid().cStr(); }
size_t pc_endpoint_channel_count(const pc_endpoint *e) { return e->root.getChannels().size(); }
uint32_t pc_endpoint_channel(const pc_endpoint *e, size_t i) { return e->root.getChannels()[static_cast<unsigned>(i)]; }
const char *pc_endpoint_midi_source(const pc_endpoint *e) { return e->root.getMidiSource().cStr(); }
const char *pc_endpoint_midi_source_name(const pc_endpoint *e) { return e->root.getMidiSourceName().cStr(); }
void pc_endpoint_free(pc_endpoint *e) { delete e; }

pc_buf pc_chain_item_encode(const char *id, const char *type, const char *subtype, const char *manufacturer,
                            bool bypass, const uint8_t *state, size_t state_len, float input_gain_db,
                            const char *clap_id, const char *clap_path) {
    capnp::MallocMessageBuilder message;
    ChainItem::Builder c = message.initRoot<ChainItem>();
    c.setId(id ? id : "");
    c.setType(type ? type : "");
    c.setSubtype(subtype ? subtype : "");
    c.setManufacturer(manufacturer ? manufacturer : "");
    c.setBypass(bypass);
    c.setInputGainDb(input_gain_db);
    if (state && state_len > 0) c.setState(kj::ArrayPtr<const kj::byte>(state, state_len));
    c.setClapId(clap_id ? clap_id : "");
    c.setClapPath(clap_path ? clap_path : "");
    return toBuf(message);
}

pc_chain_item *pc_chain_item_read(const uint8_t *bytes, size_t len) {
    return static_cast<pc_chain_item *>(Reader<ChainItem>::make(bytes, len));
}
const char *pc_chain_item_id(const pc_chain_item *c) { return c->root.getId().cStr(); }
const char *pc_chain_item_type(const pc_chain_item *c) { return c->root.getType().cStr(); }
const char *pc_chain_item_subtype(const pc_chain_item *c) { return c->root.getSubtype().cStr(); }
const char *pc_chain_item_manufacturer(const pc_chain_item *c) { return c->root.getManufacturer().cStr(); }
bool pc_chain_item_bypass(const pc_chain_item *c) { return c->root.getBypass(); }
float pc_chain_item_input_gain_db(const pc_chain_item *c) { return c->root.getInputGainDb(); }
pc_bytes pc_chain_item_state(const pc_chain_item *c) {
    auto d = c->root.getState();
    return pc_bytes{d.begin(), d.size()};
}
const char *pc_chain_item_clap_id(const pc_chain_item *c) { return c->root.getClapId().cStr(); }
const char *pc_chain_item_clap_path(const pc_chain_item *c) { return c->root.getClapPath().cStr(); }
void pc_chain_item_free(pc_chain_item *c) { delete c; }

pc_buf pc_settings_encode(uint32_t buffer_frames) {
    capnp::MallocMessageBuilder message;
    message.initRoot<Settings>().setBufferFrames(buffer_frames);
    return toBuf(message);
}

bool pc_settings_decode(const uint8_t *bytes, size_t len, uint32_t *buffer_frames) {
    Reader<Settings> *r = Reader<Settings>::make(bytes, len);
    if (!r) return false;
    *buffer_frames = r->root.getBufferFrames();
    delete r;
    return true;
}

}  // extern "C"
