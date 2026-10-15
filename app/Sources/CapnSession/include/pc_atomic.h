// Tiny atomics for handing state between the UI thread and the render thread.
#ifndef PC_ATOMIC_H
#define PC_ATOMIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void pc_store_u32(uint32_t *p, uint32_t v);   /* release */
uint32_t pc_load_u32(const uint32_t *p);      /* acquire */

#ifdef __cplusplus
}
#endif

#endif
