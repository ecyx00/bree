#include "BreeFoundationAtomicsC.h"

void BreeAtomicBooleanInitialize(BreeAtomicBooleanStorage *storage, bool initialValue) {
    atomic_init(&storage->value, initialValue);
}

bool BreeAtomicBooleanLoadRelaxed(const BreeAtomicBooleanStorage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_relaxed);
}

bool BreeAtomicBooleanLoadAcquire(const BreeAtomicBooleanStorage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_acquire);
}

void BreeAtomicBooleanStoreRelease(BreeAtomicBooleanStorage *storage, bool value) {
    atomic_store_explicit(&storage->value, value, memory_order_release);
}

bool BreeAtomicBooleanCompareExchange(
    BreeAtomicBooleanStorage *storage,
    bool expected,
    bool desired
) {
    return atomic_compare_exchange_strong_explicit(
        &storage->value,
        &expected,
        desired,
        memory_order_acq_rel,
        memory_order_acquire);
}

void BreeAtomicUInt64Initialize(BreeAtomicUInt64Storage *storage, uint64_t initialValue) {
    atomic_init(&storage->value, initialValue);
}

uint64_t BreeAtomicUInt64LoadRelaxed(const BreeAtomicUInt64Storage *storage) {
    return atomic_load_explicit(&storage->value, memory_order_relaxed);
}

void BreeAtomicUInt64StoreRelaxed(BreeAtomicUInt64Storage *storage, uint64_t value) {
    atomic_store_explicit(&storage->value, value, memory_order_relaxed);
}

uint64_t BreeAtomicUInt64IncrementRelaxed(BreeAtomicUInt64Storage *storage) {
    return atomic_fetch_add_explicit(&storage->value, 1, memory_order_relaxed) + 1;
}

uint64_t BreeAtomicUInt64AdvanceRelaxed(BreeAtomicUInt64Storage *storage) {
    uint64_t current = atomic_load_explicit(&storage->value, memory_order_relaxed);
    while (current != UINT64_MAX) {
        uint64_t next = current + 1;
        if (atomic_compare_exchange_weak_explicit(
                &storage->value,
                &current,
                next,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return next;
        }
    }
    return UINT64_MAX;
}

bool BreeAtomicUInt64IncrementIfBelow(
    BreeAtomicUInt64Storage *storage,
    uint64_t upperBound
) {
    uint64_t current = atomic_load_explicit(&storage->value, memory_order_relaxed);
    while (current < upperBound) {
        if (atomic_compare_exchange_weak_explicit(
                &storage->value,
                &current,
                current + 1,
                memory_order_acq_rel,
                memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

bool BreeAtomicUInt64DecrementIfPositive(BreeAtomicUInt64Storage *storage) {
    uint64_t current = atomic_load_explicit(&storage->value, memory_order_relaxed);
    while (current > 0) {
        if (atomic_compare_exchange_weak_explicit(
                &storage->value,
                &current,
                current - 1,
                memory_order_acq_rel,
                memory_order_acquire)) {
            return true;
        }
    }
    return false;
}
