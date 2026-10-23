// Lock-free hand-off of MIDI 1.0 events from CoreMIDI's thread to the render thread.
#ifndef PC_MIDI_H
#define PC_MIDI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PC_MIDI_RING_CAPACITY 1024   /* power of two */
#define PC_MIDI_MAX_RINGS 33         /* an instrument plus 32 music effects */

/* Single-producer single-consumer ring of packed events: status << 16 | data1 << 8 | data2.
   head is written only by the producer, tail only by the consumer. */
typedef struct pc_midi_ring {
    uint32_t head;
    uint32_t tail;
    uint32_t events[PC_MIDI_RING_CAPACITY];
} pc_midi_ring;

/* Producer; drops the event when the ring is full. */
void pc_midi_ring_push(pc_midi_ring *r, uint32_t event);
/* Consumer; false when empty. */
bool pc_midi_ring_pop(pc_midi_ring *r, uint32_t *event);
/* Consumer: events pending right now (reads head once). */
uint32_t pc_midi_ring_count(pc_midi_ring *r);
/* Consumer side: discard everything pending (tail = head). */
void pc_midi_ring_reset(pc_midi_ring *r);

/* Every event received goes to rings 0..<active, one per MIDI-receiving unit. */
typedef struct pc_midi_fanout {
    uint32_t active;           /* rings in use; set by the UI thread */
    uint32_t received;         /* events received, for an activity light; wraps */
    uint32_t virtual_enabled;  /* whether the virtual destination's events are taken */
    uint32_t producer_busy;    /* spin flag serializing producers (input port vs. virtual destination) */
    pc_midi_ring rings[PC_MIDI_MAX_RINGS];
} pc_midi_fanout;

/* Zeroed; never freed while CoreMIDI may still call a receive block that holds it. */
pc_midi_fanout *pc_midi_fanout_new(void);
pc_midi_ring *pc_midi_fanout_ring(pc_midi_fanout *f, uint32_t index);
/* Producer: push one event into every active ring and count it. Producers
   (CoreMIDI threads, never the render thread) serialize on a spin flag so each
   ring keeps a single producer; consumers never touch the flag. */
void pc_midi_fanout_push(pc_midi_fanout *f, uint32_t event);

#ifdef __cplusplus
}
#endif

#endif
