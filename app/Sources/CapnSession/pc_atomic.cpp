#include "pc_atomic.h"
#include <atomic>

extern "C" {
void pc_store_u32(uint32_t *p, uint32_t v) {
    std::atomic_ref<uint32_t>(*p).store(v, std::memory_order_release);
}
uint32_t pc_load_u32(const uint32_t *p) {
    return std::atomic_ref<uint32_t>(*const_cast<uint32_t *>(p)).load(std::memory_order_acquire);
}
}
