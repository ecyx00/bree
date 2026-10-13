#include "BreeControlSocketAtomicsC.h"

void BreeControlSocketAtomicPointerInitialize(
    BreeControlSocketAtomicPointerStorage *storage,
    uintptr_t initialValue
) {
    atomic_init(&storage->value, initialValue);
}

uintptr_t BreeControlSocketAtomicPointerLoadAcquire(
    const BreeControlSocketAtomicPointerStorage *storage
) {
    return atomic_load_explicit(&storage->value, memory_order_seq_cst);
}

uintptr_t BreeControlSocketAtomicPointerExchange(
    BreeControlSocketAtomicPointerStorage *storage,
    uintptr_t value
) {
    return atomic_exchange_explicit(&storage->value, value, memory_order_seq_cst);
}

void BreeControlSocketAtomicCounterInitialize(
    BreeControlSocketAtomicCounterStorage *storage,
    uint64_t initialValue
) {
    atomic_init(&storage->value, initialValue);
}

uint64_t BreeControlSocketAtomicCounterLoad(
    const BreeControlSocketAtomicCounterStorage *storage
) {
    return atomic_load_explicit(&storage->value, memory_order_seq_cst);
}

void BreeControlSocketAtomicCounterIncrement(
    BreeControlSocketAtomicCounterStorage *storage
) {
    atomic_fetch_add_explicit(&storage->value, 1, memory_order_seq_cst);
}

void BreeControlSocketAtomicCounterDecrement(
    BreeControlSocketAtomicCounterStorage *storage
) {
    atomic_fetch_sub_explicit(&storage->value, 1, memory_order_seq_cst);
}
