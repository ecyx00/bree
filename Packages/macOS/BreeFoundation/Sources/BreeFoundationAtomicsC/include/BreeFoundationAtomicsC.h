#ifndef BREE_FOUNDATION_ATOMICS_C_H
#define BREE_FOUNDATION_ATOMICS_C_H

#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    atomic_bool value;
} BreeAtomicBooleanStorage;

void BreeAtomicBooleanInitialize(BreeAtomicBooleanStorage *storage, bool initialValue);
bool BreeAtomicBooleanLoadRelaxed(const BreeAtomicBooleanStorage *storage);
bool BreeAtomicBooleanLoadAcquire(const BreeAtomicBooleanStorage *storage);
void BreeAtomicBooleanStoreRelease(BreeAtomicBooleanStorage *storage, bool value);
bool BreeAtomicBooleanCompareExchange(
    BreeAtomicBooleanStorage *storage,
    bool expected,
    bool desired
);

typedef struct {
    _Atomic(uint64_t) value;
} BreeAtomicUInt64Storage;

void BreeAtomicUInt64Initialize(BreeAtomicUInt64Storage *storage, uint64_t initialValue);
uint64_t BreeAtomicUInt64LoadRelaxed(const BreeAtomicUInt64Storage *storage);
void BreeAtomicUInt64StoreRelaxed(BreeAtomicUInt64Storage *storage, uint64_t value);
uint64_t BreeAtomicUInt64IncrementRelaxed(BreeAtomicUInt64Storage *storage);
uint64_t BreeAtomicUInt64AdvanceRelaxed(BreeAtomicUInt64Storage *storage);
bool BreeAtomicUInt64IncrementIfBelow(
    BreeAtomicUInt64Storage *storage,
    uint64_t upperBound
);
bool BreeAtomicUInt64DecrementIfPositive(BreeAtomicUInt64Storage *storage);

#endif
