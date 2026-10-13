#ifndef BREE_CONTROL_SOCKET_ATOMICS_C_H
#define BREE_CONTROL_SOCKET_ATOMICS_C_H

#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    _Atomic(uintptr_t) value;
} BreeControlSocketAtomicPointerStorage;

void BreeControlSocketAtomicPointerInitialize(
    BreeControlSocketAtomicPointerStorage *storage,
    uintptr_t initialValue
);
uintptr_t BreeControlSocketAtomicPointerLoadAcquire(
    const BreeControlSocketAtomicPointerStorage *storage
);
uintptr_t BreeControlSocketAtomicPointerExchange(
    BreeControlSocketAtomicPointerStorage *storage,
    uintptr_t value
);

typedef struct {
    _Atomic(uint64_t) value;
} BreeControlSocketAtomicCounterStorage;

void BreeControlSocketAtomicCounterInitialize(
    BreeControlSocketAtomicCounterStorage *storage,
    uint64_t initialValue
);
uint64_t BreeControlSocketAtomicCounterLoad(
    const BreeControlSocketAtomicCounterStorage *storage
);
void BreeControlSocketAtomicCounterIncrement(
    BreeControlSocketAtomicCounterStorage *storage
);
void BreeControlSocketAtomicCounterDecrement(
    BreeControlSocketAtomicCounterStorage *storage
);

#endif
