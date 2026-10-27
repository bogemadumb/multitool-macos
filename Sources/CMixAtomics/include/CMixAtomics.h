#ifndef CMIXATOMICS_H
#define CMIXATOMICS_H

#include <stdint.h>
#include <stdatomic.h>

static inline uint32_t mix_load_u32(const uint32_t *p) {
    return atomic_load_explicit((const _Atomic uint32_t *)p, memory_order_acquire);
}

static inline void mix_store_u32(uint32_t *p, uint32_t v) {
    atomic_store_explicit((_Atomic uint32_t *)p, v, memory_order_release);
}

static inline uint32_t mix_exchange_u32(uint32_t *p, uint32_t v) {
    return atomic_exchange_explicit((_Atomic uint32_t *)p, v, memory_order_acq_rel);
}

static inline uint32_t mix_fetch_add_u32(uint32_t *p, uint32_t v) {
    return atomic_fetch_add_explicit((_Atomic uint32_t *)p, v, memory_order_acq_rel);
}

static inline int mix_compare_exchange_u32(uint32_t *p, uint32_t expected, uint32_t desired) {
    return atomic_compare_exchange_strong_explicit((_Atomic uint32_t *)p, &expected, desired, memory_order_acq_rel, memory_order_acquire);
}

#endif
