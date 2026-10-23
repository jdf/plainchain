#include "pc_midi.h"
#include "pc_atomic.h"
#include <atomic>
#include <cstdlib>

extern "C" {

void pc_midi_ring_push(pc_midi_ring *r, uint32_t event) {
    uint32_t head = r->head;  // only the producer writes it
    if (head - pc_load_u32(&r->tail) >= PC_MIDI_RING_CAPACITY) return;  // full: drop
    r->events[head & (PC_MIDI_RING_CAPACITY - 1)] = event;
    pc_store_u32(&r->head, head + 1);
}

bool pc_midi_ring_pop(pc_midi_ring *r, uint32_t *event) {
    uint32_t tail = r->tail;  // only the consumer writes it
    if (tail == pc_load_u32(&r->head)) return false;
    *event = r->events[tail & (PC_MIDI_RING_CAPACITY - 1)];
    pc_store_u32(&r->tail, tail + 1);
    return true;
}

uint32_t pc_midi_ring_count(pc_midi_ring *r) { return pc_load_u32(&r->head) - r->tail; }

void pc_midi_ring_reset(pc_midi_ring *r) { pc_store_u32(&r->tail, pc_load_u32(&r->head)); }

pc_midi_fanout *pc_midi_fanout_new(void) {
    return static_cast<pc_midi_fanout *>(std::calloc(1, sizeof(pc_midi_fanout)));
}

pc_midi_ring *pc_midi_fanout_ring(pc_midi_fanout *f, uint32_t index) {
    return index < PC_MIDI_MAX_RINGS ? &f->rings[index] : nullptr;
}

void pc_midi_fanout_push(pc_midi_fanout *f, uint32_t event) {
    std::atomic_ref<uint32_t> busy(f->producer_busy);
    while (busy.exchange(1, std::memory_order_acquire)) {}
    uint32_t n = pc_load_u32(&f->active);
    if (n > PC_MIDI_MAX_RINGS) n = PC_MIDI_MAX_RINGS;
    for (uint32_t i = 0; i < n; i++) pc_midi_ring_push(&f->rings[i], event);
    pc_store_u32(&f->received, f->received + 1);
    busy.store(0, std::memory_order_release);
}

pc_midi_hub *pc_midi_hub_new(void) {
    return static_cast<pc_midi_hub *>(std::calloc(1, sizeof(pc_midi_hub)));
}

bool pc_midi_hub_add(pc_midi_hub *h, pc_midi_fanout *f) {
    uint32_t n = h->count;  // only the UI thread writes it
    if (n >= PC_MIDI_MAX_FANOUTS) return false;
    h->fanouts[n] = f;
    pc_store_u32(&h->count, n + 1);
    return true;
}

void pc_midi_hub_push(pc_midi_hub *h, uint32_t event) {
    uint32_t n = pc_load_u32(&h->count);
    for (uint32_t i = 0; i < n; i++) {
        pc_midi_fanout *f = h->fanouts[i];
        if (pc_load_u32(&f->virtual_enabled)) pc_midi_fanout_push(f, event);
    }
}

}  // extern "C"
